#!/usr/bin/env python3
"""Rushes talks to DaVinci Resolve Studio through this script.

It reads one JSON command from stdin and prints one JSON answer. Nothing here is a daemon: Rushes starts it
for a single job and it ends. Resolve has to be running, and Preferences > General > External scripting using
has to be set to Local.

Commands (field "command"):
  status                          who is open
  usage                           every clip of the open project with the number of times it is on a timeline
  send                            put files in bins (and optionally a timeline) of the open project
  relink                          point clips at a folder that was renamed or moved
"""
import json
import os
import sys
import traceback

API = os.environ.get("RESOLVE_SCRIPT_API") or "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"
LIB = os.environ.get("RESOLVE_SCRIPT_LIB") or "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so"


def answer(payload):
    sys.stdout.write(json.dumps(payload))
    sys.stdout.flush()


def fail(code, message):
    answer({"ok": False, "error": code, "message": message})
    sys.exit(0)


def connect():
    os.environ["RESOLVE_SCRIPT_API"] = API
    os.environ["RESOLVE_SCRIPT_LIB"] = LIB
    sys.path.append(os.path.join(API, "Modules"))
    try:
        import DaVinciResolveScript as dvr
    except Exception as error:  # noqa: BLE001
        fail("no_module", "The scripting module of Resolve could not be loaded: %s" % error)
    resolve = dvr.scriptapp("Resolve")
    if resolve is None:
        fail("not_connected", "Resolve did not answer. Is it running, and is External scripting set to Local?")
    return resolve


def walk(folder):
    yield folder
    for sub in folder.GetSubFolderList() or []:
        for inner in walk(sub):
            yield inner


def file_path(clip):
    value = clip.GetClipProperty("File Path")
    return value if isinstance(value, str) else ""


def find_or_create(media_pool, parent, name):
    for sub in parent.GetSubFolderList() or []:
        if sub.GetName() == name:
            return sub
    return media_pool.AddSubFolder(parent, name)


def unique_timeline_name(project, name):
    existing = set()
    for index in range(1, (project.GetTimelineCount() or 0) + 1):
        timeline = project.GetTimelineByIndex(index)
        if timeline:
            existing.add(timeline.GetName())
    if name not in existing:
        return name
    counter = 2
    while "%s %d" % (name, counter) in existing:
        counter += 1
    return "%s %d" % (name, counter)


def command_status(resolve, request):
    manager = resolve.GetProjectManager()
    project = manager.GetCurrentProject() if manager else None
    timeline = project.GetCurrentTimeline() if project else None
    answer({
        "ok": True,
        "version": resolve.GetVersionString(),
        "project": project.GetName() if project else None,
        "timeline": timeline.GetName() if timeline else None,
    })


def command_usage(resolve, request):
    project = resolve.GetProjectManager().GetCurrentProject()
    if not project:
        fail("no_project", "No project is open in Resolve.")
    rows = []
    for folder in walk(project.GetMediaPool().GetRootFolder()):
        for clip in folder.GetClipList() or []:
            path = file_path(clip)
            if not path:
                continue
            try:
                usage = int(clip.GetClipProperty("Usage") or 0)
            except (TypeError, ValueError):
                usage = 0
            rows.append({"path": path, "usage": usage})
    answer({"ok": True, "project": project.GetName(), "clips": rows})


def command_send(resolve, request):
    project = resolve.GetProjectManager().GetCurrentProject()
    if not project:
        fail("no_project", "No project is open in Resolve.")
    media_pool = project.GetMediaPool()
    root = media_pool.GetRootFolder()
    parent = find_or_create(media_pool, root, request["parent"]) if request.get("parent") else root

    timeline_clips = []
    imported = 0
    existing_count = 0
    bins_used = []
    for entry in request.get("bins", []):
        folder = find_or_create(media_pool, parent, entry["name"])
        if folder is None:
            fail("bin_failed", "The bin %s could not be made." % entry["name"])
        media_pool.SetCurrentFolder(folder)
        present = {}
        for clip in folder.GetClipList() or []:
            present[file_path(clip)] = clip
        wanted = entry.get("files", [])
        new_files = [path for path in wanted if path not in present]
        existing_count += len(wanted) - len(new_files)
        made = media_pool.ImportMedia(new_files) if new_files else []
        imported += len(made or [])
        by_path = dict(present)
        for clip in made or []:
            by_path[file_path(clip)] = clip
        videos = set(entry.get("videos", []))
        for path in wanted:
            if path in videos and path in by_path:
                timeline_clips.append(by_path[path])
        bins_used.append(entry["name"])

    timeline_name = None
    if request.get("timeline") and timeline_clips:
        timeline_name = unique_timeline_name(project, request["timeline"])
        if not media_pool.CreateTimelineFromClips(timeline_name, timeline_clips):
            timeline_name = None
    answer({
        "ok": True,
        "project": project.GetName(),
        "imported": imported,
        "alreadyThere": existing_count,
        "bins": bins_used,
        "timeline": timeline_name,
    })


def relink_open_project(project, old, new):
    media_pool = project.GetMediaPool()
    groups = {}
    for folder in walk(media_pool.GetRootFolder()):
        for clip in folder.GetClipList() or []:
            path = file_path(clip)
            if path == old or path.startswith(old.rstrip("/") + "/"):
                directory = os.path.dirname(path)
                groups.setdefault(new + directory[len(old):], []).append(clip)
    count = 0
    for directory, clips in groups.items():
        if media_pool.RelinkClips(clips, directory):
            count += len(clips)
    return count


def all_projects(manager):
    """Every project of the database as (folder names, project name), walking the project folders."""
    found = []

    def visit(path):
        for name in manager.GetProjectListInCurrentFolder() or []:
            found.append((list(path), name))
        for folder in manager.GetFolderListInCurrentFolder() or []:
            if manager.OpenFolder(folder):
                visit(path + [folder])
                manager.GotoParentFolder()

    manager.GotoRootFolder()
    visit([])
    manager.GotoRootFolder()
    return found


def command_relink(resolve, request):
    manager = resolve.GetProjectManager()
    old, new = request["from"], request["to"]
    current = manager.GetCurrentProject()
    if not current:
        fail("no_project", "No project is open in Resolve.")
    if not request.get("allProjects"):
        answer({"ok": True, "relinked": relink_open_project(current, old, new), "projects": [current.GetName()]})
        return

    original = current.GetName()
    manager.SaveProject()
    touched = []
    total = 0
    for path, name in all_projects(manager):
        manager.GotoRootFolder()
        for folder in path:
            manager.OpenFolder(folder)
        project = manager.LoadProject(name)
        if not project:
            continue
        count = relink_open_project(project, old, new)
        if count:
            manager.SaveProject()
            touched.append(name)
            total += count
    manager.GotoRootFolder()
    for path, name in all_projects(manager):
        if name == original:
            manager.GotoRootFolder()
            for folder in path:
                manager.OpenFolder(folder)
            manager.LoadProject(name)
            break
    answer({"ok": True, "relinked": total, "projects": touched})


COMMANDS = {
    "status": command_status,
    "usage": command_usage,
    "send": command_send,
    "relink": command_relink,
}


def main():
    try:
        request = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        fail("bad_request", "The command was not valid JSON.")
    handler = COMMANDS.get(request.get("command"))
    if handler is None:
        fail("unknown_command", "Unknown command.")
    resolve = connect()
    try:
        handler(resolve, request)
    except SystemExit:
        raise
    except Exception as error:  # noqa: BLE001
        answer({"ok": False, "error": "exception", "message": "%s\n%s" % (error, traceback.format_exc(limit=3))})


if __name__ == "__main__":
    main()
