# Rushes

[![Release](https://img.shields.io/github/v/release/Marukiee/Rushes?label=release)](https://github.com/Marukiee/Rushes/releases/latest)
[![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white)](#install)

English | [Nederlands](README.nl.md)

**A Mac app for your memory cards and your footage disk.** Put a card in your Mac with your disk connected. Rushes recognises both, shows what is new on the card, lets you look through it fast, copies what is worth keeping (every file read back and checked), and later tells you which clips on your disk no DaVinci Resolve project uses, so you can get the space back.

Made for a Sony camera and a big external SSD, but nothing is tied to either.

## What it does

- **Recognises a card and your disk.** A small glass card appears in the corner of the screen: "SD 5 and 4TB SSD are in, 212 new, 96 GB". You choose to look through it first (the default) or to copy everything at once
- **Looks through a card quickly.** Thumbnails you skim with the pointer, frame by frame like in DaVinci, a big player with J K L and frame stepping, the camera's own LUT on log footage, stars, and Keep or Leave out per clip. Black or covered clips, very short clips, out of focus photos and near copies in a burst are suggested for leaving out
- **Copies only what you keep.** All of it, only the videos or the photos, the whole card or one day at a time. What you did not judge stays on the card for next time, and every choice and star is remembered when the card comes back
- **Copies safely.** The card is only read. A checksum is made while a file is read, the file is written under a temporary name and renamed when whole, and then it is read back from the disk and compared. A second copy to another disk can run in the same pass. Every folder gets a list of checksums, so it can be checked again a year later
- **Names folders the way you do.** `SD 1`, `SD 2`, `SD 3`, the next number by itself. The same card goes back into its own folder. Give a folder a name afterwards (`SD 5 Sweden`) and the number stays
- **Reads your DaVinci Resolve projects.** Straight from the project files of the local database, so Resolve does not have to be open. Each clip on the disk is marked: in a project (with project and timeline), in a media pool only, maybe used, or not used
- **Gets space back.** Clips that are not used go to the Trash with one key and the next clip opens by itself. A clip a project uses asks first, and Undo puts it back
- **Talks to Resolve.** With Resolve Studio open, new footage goes in a bin named with the date of shooting, and optionally a timeline in shooting order. All of it can be turned off in the settings
- **Looks after itself.** A menu bar app that starts at login, keeps the Mac awake while it copies, asks before it quits in the middle of a copy, and updates itself from GitHub with a signature check

## Install

You need macOS 26 or newer and an Apple silicon Mac.

1. Download `Rushes-macOS.zip` from the [latest release](https://github.com/Marukiee/Rushes/releases/latest), open it and move Rushes to Applications.
2. Open Rushes. macOS refuses the first time, because the app is signed with a certificate of its own and is not notarised by Apple. Right click the app and choose Open, or go to System Settings, Privacy and Security and click "Open Anyway". You only do this once.
3. The first time a card is read, macOS asks for access to removable volumes. Allow it.

After that Rushes updates itself.

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
| R | Reset the choice and the stars |
| Z | Undo |
| M, I | Sound on or off, details on or off |
| Shift click, Command click | Select several |
| Click on a day | Select the whole day (its menu copies, keeps or resets the day) |

More on how Rushes reads Resolve projects is in [docs/HOW-IT-READS-RESOLVE.md](docs/HOW-IT-READS-RESOLVE.md).

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

AGPL-3.0, see [LICENSE](LICENSE). Made by Mark Maakt Media.
