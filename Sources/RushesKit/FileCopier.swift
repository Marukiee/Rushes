import CryptoKit
import Darwin
import Foundation

public struct CopyTask: Sendable, Hashable {
    public let source: URL
    public let entry: FileEntry
    /// Path below the destination root, normally the same as the path on the card.
    public let destinationRel: String

    public init(source: URL, entry: FileEntry, destinationRel: String) {
        self.source = source
        self.entry = entry
        self.destinationRel = destinationRel
    }
}

public struct CopiedFile: Sendable {
    public let task: CopyTask
    public let hash: String
    public let destination: URL
    public let backupDestination: URL?
}

public struct FailedFile: Sendable {
    public let task: CopyTask
    public let message: String
}

public struct CopyProgress: Sendable {
    public var bytesTotal: UInt64
    /// Bytes read from the card and written.
    public var bytesCopied: UInt64
    /// Bytes read back from the disk and compared.
    public var bytesVerified: UInt64
    public var filesTotal: Int
    public var filesDone: Int
    public var currentName: String
    public var bytesPerSecond: Double
    public var verifying: Bool

    public var fraction: Double {
        guard bytesTotal > 0 else { return 1 }
        return min(1, Double(bytesCopied + bytesVerified) / Double(bytesTotal * 2))
    }

    public var remaining: TimeInterval? {
        guard bytesPerSecond > 1_000_000 else { return nil }
        let left = Double(bytesTotal * 2) - Double(bytesCopied + bytesVerified)
        return max(0, left / (bytesPerSecond * 2))
    }
}

public struct CopyReport: Sendable {
    public var copied: [CopiedFile] = []
    public var failed: [FailedFile] = []
    public var cancelled = false
    public var bytes: UInt64 = 0
    public var duration: TimeInterval = 0
    /// True when every copied file was read back and its checksum matched the source.
    public var verified: Bool { failed.isEmpty && !cancelled }
}

/// Copies files and proves they arrived intact.
///
/// The card is only ever read. Each file is read once; the checksum is made on the way, and the same
/// bytes are written to the disk and, if wanted, to a second disk. Afterwards every copy is read back
/// from the disk itself (not from the cache) and compared with the checksum of the card. A file is
/// written under a temporary name and renamed when it is whole, so a pulled cable never leaves a
/// half file that looks like a real one.
public final class FileCopier: @unchecked Sendable {
    public static let chunk = 8 * 1024 * 1024

    private let tasks: [CopyTask]
    private let destination: URL
    private let backup: URL?
    private let onProgress: @Sendable (CopyProgress) -> Void
    private let onFileDone: @Sendable (CopiedFile) -> Void
    private let isCancelled: @Sendable () -> Bool

    private let stateLock = NSLock()
    private var progress: CopyProgress
    private let speed = SpeedMeter()
    private var lastReport = Date.distantPast

    public init(
        tasks: [CopyTask], destination: URL, backup: URL? = nil,
        onProgress: @escaping @Sendable (CopyProgress) -> Void = { _ in },
        onFileDone: @escaping @Sendable (CopiedFile) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.tasks = tasks
        self.destination = destination
        self.backup = backup
        self.onProgress = onProgress
        self.onFileDone = onFileDone
        self.isCancelled = isCancelled
        let copies: UInt64 = backup == nil ? 1 : 2
        progress = CopyProgress(
            bytesTotal: tasks.reduce(0) { $0 + $1.entry.size } * copies, bytesCopied: 0, bytesVerified: 0,
            filesTotal: tasks.count, filesDone: 0, currentName: "", bytesPerSecond: 0, verifying: false
        )
    }

    /// Blocks until done, so call it from a background thread.
    public func run() -> CopyReport {
        let start = Date()
        var report = CopyReport()
        let verifyQueue = DispatchQueue(label: "rushes.verify")
        let backlog = DispatchSemaphore(value: 2)
        let group = DispatchGroup()
        let reportLock = NSLock()

        for task in tasks {
            if isCancelled() { report.cancelled = true; break }
            backlog.wait()
            if isCancelled() { backlog.signal(); report.cancelled = true; break }
            update { $0.currentName = task.entry.name }
            do {
                let hash = try copy(task)
                let main = destination.appendingPathComponent(task.destinationRel)
                let second = backup?.appendingPathComponent(task.destinationRel)
                let copied = CopiedFile(task: task, hash: hash, destination: main, backupDestination: second)
                group.enter()
                verifyQueue.async { [self] in
                    defer { backlog.signal(); group.leave() }
                    var problem: String?
                    for target in [main] + (second.map { [$0] } ?? []) {
                        do {
                            let actual = try Self.hashFile(target, noCache: true) { [self] read in
                                update { $0.bytesVerified += UInt64(read); $0.verifying = true }
                                speed.add(UInt64(read))
                            }
                            if actual != hash { problem = String(localized: "Checksum does not match on \(target.deletingLastPathComponent().lastPathComponent)") }
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                    reportLock.lock()
                    if let problem {
                        report.failed.append(FailedFile(task: task, message: problem))
                    } else {
                        report.copied.append(copied)
                        report.bytes += task.entry.size
                        onFileDone(copied)
                    }
                    reportLock.unlock()
                    update { $0.filesDone += 1 }
                }
            } catch is CancellationError {
                backlog.signal()
                report.cancelled = true
                break
            } catch {
                backlog.signal()
                reportLock.lock()
                report.failed.append(FailedFile(task: task, message: error.localizedDescription))
                reportLock.unlock()
                update { $0.filesDone += 1 }
            }
        }
        group.wait()
        report.duration = Date().timeIntervalSince(start)
        report.cancelled = report.cancelled || isCancelled()
        report.copied.sort { $0.task.destinationRel < $1.task.destinationRel }
        publish(force: true)
        return report
    }

    // MARK: Copy

    private func copy(_ task: CopyTask) throws -> String {
        let targets = [destination] + (backup.map { [$0] } ?? [])
        var outputs: [(final: URL, temp: URL, fd: Int32)] = []
        defer { for output in outputs where output.fd >= 0 { close(output.fd) } }

        for root in targets {
            let final = root.appendingPathComponent(task.destinationRel)
            try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temp = final.appendingPathExtension("rushes-part")
            unlink(temp.path)
            let fd = open(temp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            guard fd >= 0 else { throw POSIXError(from: errno, path: temp.path) }
            _ = fcntl(fd, F_NOCACHE, 1)
            outputs.append((final, temp, fd))
        }

        let input = open(task.source.path, O_RDONLY)
        guard input >= 0 else {
            let code = errno
            for output in outputs { unlink(output.temp.path) }
            throw POSIXError(from: code, path: task.source.path)
        }
        defer { close(input) }
        _ = fcntl(input, F_NOCACHE, 1)
        _ = fcntl(input, F_RDAHEAD, 1)

        var hasher = SHA256()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.chunk, alignment: 4096)
        defer { buffer.deallocate() }

        do {
            while true {
                if isCancelled() { throw CancellationError() }
                let count = read(input, buffer, Self.chunk)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(from: errno, path: task.source.path)
                }
                if count == 0 { break }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
                for output in outputs {
                    var written = 0
                    while written < count {
                        let step = write(output.fd, buffer + written, count - written)
                        if step < 0 {
                            if errno == EINTR { continue }
                            throw POSIXError(from: errno, path: output.temp.path)
                        }
                        written += step
                    }
                }
                update { $0.bytesCopied += UInt64(count) * UInt64(outputs.count) }
                speed.add(UInt64(count) * UInt64(outputs.count))
            }
            for output in outputs { _ = fsync(output.fd) }
        } catch {
            for output in outputs { close(output.fd); unlink(output.temp.path) }
            outputs = outputs.map { ($0.final, $0.temp, -1) }
            throw error
        }

        for index in outputs.indices {
            close(outputs[index].fd)
            outputs[index].fd = -1
            let final = outputs[index].final
            try? FileManager.default.setAttributes(
                [.modificationDate: task.entry.modified, .creationDate: task.entry.created ?? task.entry.modified],
                ofItemAtPath: outputs[index].temp.path
            )
            if FileManager.default.fileExists(atPath: final.path) { try? FileManager.default.removeItem(at: final) }
            guard rename(outputs[index].temp.path, final.path) == 0 else {
                throw POSIXError(from: errno, path: final.path)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Progress

    private func update(_ change: (inout CopyProgress) -> Void) {
        stateLock.lock()
        change(&progress)
        stateLock.unlock()
        publish(force: false)
    }

    private func publish(force: Bool) {
        stateLock.lock()
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) > 0.15 else { stateLock.unlock(); return }
        lastReport = now
        progress.bytesPerSecond = speed.perSecond
        let snapshot = progress
        stateLock.unlock()
        onProgress(snapshot)
    }

    // MARK: Hashing

    /// SHA-256 of a file. `noCache` reads from the disk itself, which is what a verification needs.
    public static func hashFile(_ url: URL, noCache: Bool = false, progress: ((Int) -> Void)? = nil) throws -> String {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(from: errno, path: url.path) }
        defer { close(fd) }
        if noCache { _ = fcntl(fd, F_NOCACHE, 1) }
        _ = fcntl(fd, F_RDAHEAD, 1)
        var hasher = SHA256()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 4096)
        defer { buffer.deallocate() }
        while true {
            let count = read(fd, buffer, chunk)
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(from: errno, path: url.path)
            }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
            progress?(count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension POSIXError {
    init(from code: Int32, path: String) {
        self.init(POSIXErrorCode(rawValue: code) ?? .EIO)
        _ = path
    }
}

/// Bytes per second over the last few seconds, so the number follows the real speed without jumping.
final class SpeedMeter {
    private var samples: [(time: TimeInterval, bytes: UInt64)] = []
    private var total: UInt64 = 0
    private let lock = NSLock()

    func add(_ bytes: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        total += bytes
        let now = ProcessInfo.processInfo.systemUptime
        samples.append((now, total))
        samples.removeAll { now - $0.time > 6 }
    }

    var perSecond: Double {
        lock.lock()
        defer { lock.unlock() }
        guard let first = samples.first, let last = samples.last, last.time - first.time > 0.5 else { return 0 }
        return Double(last.bytes - first.bytes) / (last.time - first.time)
    }
}

public enum DiskSpace {
    public static func available(at url: URL) -> UInt64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return UInt64(important) }
        if let plain = values?.volumeAvailableCapacity, plain > 0 { return UInt64(plain) }
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        return UInt64(info.f_bavail) * UInt64(info.f_bsize)
    }
}
