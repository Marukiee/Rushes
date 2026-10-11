# Rushes

Put a memory card in your Mac with your disk connected. Rushes recognises both, shows what is new on the card, lets you
look through it fast, copies what is worth keeping (every file read back and checked), and later tells you which
clips on your disk no DaVinci Resolve project uses, so you can get the space back.

Made for a Sony camera and a big external SSD, but nothing is tied to either.

## What it does

**Recognises a card and your disk.** A small glass card appears in the corner of the screen: "SD 5 and 4TB SSD are in,
212 new, 96 GB". You choose to look through it first (the default) or to copy everything at once. Both can be set.

**Looks through a card quickly.** Thumbnails you can scrub with the pointer, a big player with J K L and frame
stepping, the camera's own LUT on log footage, stars, and Keep or Leave out per clip. Black or covered clips, very short
clips, out of focus photos and near copies in a burst are suggested for leaving out. Only what you keep is copied.

**Copies safely.** The card is only read. A checksum is made while a file is read, the file is written under a
temporary name and renamed when whole, and then it is read back from the disk and compared. A second copy to another disk
can run in the same pass. Every folder gets a list of checksums, so it can be checked again a year later.

**Names folders the way you do.** `SD 1`, `SD 2`, `SD 3`, the next number by itself. The same card goes back into its own
folder, a card that was formatted gets a new one. Give a folder a name afterwards (`SD 5 Sweden`) and the number stays.

**Reads your DaVinci Resolve projects.** Straight from the project files of the local database, so Resolve does not
have to be open and is never disturbed. Each clip on the disk is marked: in a project (with project and timeline),
in a media pool only, maybe used, or not used. Paths from another system (a Linux mount) or from before a folder was
renamed still match, because the card number and the path inside the card are what count.

**Gets space back.** Not used clips go to the Trash with one key and the next clip opens by itself. A clip a project
uses asks first. Undo puts it back. A clean up button takes everything no project uses, in one go, after a question.

**Talks to Resolve.** With Resolve Studio open (External scripting set to Local), new footage goes in a bin named with
the date of shooting, one bin for each day, and optionally a timeline in shooting order. Rename a folder and Rushes
points the clips in Resolve at the new name. All of it can be turned on or off in the settings.

**Looks after itself.** A menu bar app that starts at login, keeps the Mac awake while it copies, asks before it quits in
the middle of a copy, and updates itself from GitHub with a signature check.

## Install

Download `Rushes-macOS.zip` from the [latest release](https://github.com/Marukiee/Rushes/releases/latest), open it and move
Rushes to Applications. It needs macOS 26 and an Apple silicon Mac. It is signed with a certificate of its own, not by
Apple, so the first time you right click it and choose Open. After that it updates itself.

The first time a card is read, macOS asks for access to removable volumes. Allow it.

## Keys in the review

| Key | Does |
| --- | --- |
| Arrow keys | Move through the clips |
| Return | Keep (in the library: protect from suggestions) |
| X or Delete | Leave out (in the library: move to the Trash) |
| 1 to 5 | Stars |
| Space | Play or pause |
| J K L | Back, stop, forward, again for faster |
| , and . | One frame back or forward |
| [ and ] | Five seconds back or forward |
| Tab | The next one not judged |
| Z | Undo |
| M, I | Sound on or off, details on or off |
| Shift click, Command click | Select several |

## How it reads Resolve

A project of the local disk database is a SQLite file. The clips on a timeline have their path in plain text. The
media pool has it in a small protobuf message. Rushes copies the file first, reads the copy, and matches by card number
and path inside the card instead of by the whole path. If you use a PostgreSQL database, the projects cannot be read
this way. Clips you used since the last time you saved the project show as unused until you save it (Cmd S).

## Build

Only the Command Line Tools are needed, not Xcode.

```sh
swift build                       # the app
swift run RushesChecks            # the checks (Swift Testing and XCTest need a full Xcode)
./scripts/build-macos.sh debug    # dist/Rushes Dev.app, a separate app with its own data
```

`CLAUDE.md` has the working notes: design language, signing, releasing, and the environment variables the debug build
understands (a folder can stand in for a card and another for the disk).

## License

AGPL-3.0, see `LICENSE`. Made by Mark Maakt Media.

---

**Nederlands, kort:** Steek een geheugenkaart in je Mac met je schijf eraan. Rushes herkent allebei, laat zien wat er nieuw
is, laat je snel door de beelden kijken, kopieert wat je houdt (elk bestand teruggelezen en gecontroleerd) en vertelt
later welke clips op je schijf in geen enkel DaVinci Resolve-project zitten, zodat je ruimte terugkrijgt. De app staat
in het Nederlands en het Engels.
