import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac awake while files are being copied. A copy that stops halfway because the lid closed is the worst case.
@MainActor
final class SleepBlocker {
    private var assertion: IOPMAssertionID = 0
    private var active = false

    func start(reason: String) {
        guard !active else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &assertion
        )
        active = result == kIOReturnSuccess
    }

    func stop() {
        guard active else { return }
        IOPMAssertionRelease(assertion)
        active = false
    }
}
