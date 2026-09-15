# Taction

Touchscreen support for the ASUS ZenScreen Touch MB16AMT on
MacOS. Built on MacOS 26, should work back to about MacOS 13
(untested).

MacOS has no built-in touchscreen support: the panel enumerates as a
standard HID multitouch digitizer, ignored by MacOS. Taction
reads the panel's HID reports through the public `IOHIDManager` API,
maps them onto the display, runs a small gesture engine, and posts
pointer, scroll, and keyboard events.

Taction is free, MIT licensed, and honor-system shareware: nothing is
locked. If you like it, please consider [supporting it on
Ko-fi](https://ko-fi.com/jorjbauer) to cover the annual costs of
hosting and ongoing developer programs to sign the binaries.

## Install

1. Download `Taction-<version>.dmg` from the
   [latest release](https://github.com/JorjBauer/Taction/releases/latest),
   open it, and drag Taction to Applications.
2. Open Taction. It appears in the menu bar and registers itself to
   open at login (System Settings > General > Login Items, if you
   want that off).
3. Grant the two permissions it asks for under System Settings > Privacy &
   Security: **Input Monitoring** (to receive touches) and **Accessibility**
   (to move the pointer and click). If Taction is not listed, use the plus
   button and pick it from Applications. It should notice the grants within
   a few seconds.

Taction checks once a day for updates; with the switch on it installs
a new version and reopens by itself, otherwise it asks first.

The Preferences window shows both permissions with a green check or a
red cross, refreshed live; "Not granted" is a link to the right System
Settings pane. Taction also writes a plain log to
`~/Library/Logs/Taction.log`.

## Gestures

| Fingers | Motion | Result |
|---|---|---|
| 1 | tap | left click (double taps register as double clicks) |
| 1 | drag | drag with the left button held |
| 1 | hold still 500 ms | right click |
| 2 | tap | right click |
| 2 | drag | scroll, locked to the dominant axis, with inertia after a flick |
| 2 | pinch | zoom in or out (Cmd+= and Cmd+-, honored by browsers, Preview, Maps) |
| 3 | swipe left or right | next or previous Space |
| 3 | swipe up or down | Mission Control or App Exposé |

Space and Mission Control swipes use whatever keyboard shortcuts are enabled in
System Settings > Keyboard > Keyboard Shortcuts > Mission Control. When none is
enabled for Mission Control or App Exposé, Taction launches Mission Control
directly instead.

## Configuration

`~/Library/Application Support/Taction/config.json`, created with defaults on
first run and reloaded when the app receives `SIGHUP`
(`kill -HUP $(pgrep -x Taction)`).

| Key | Default | Meaning |
|---|---|---|
| `gestures.scrollGain` | 1.0 | Scroll speed multiplier |
| `gestures.scrollDeadZonePt` | 6 | Movement before a two-finger touch becomes a scroll |
| `gestures.naturalScrolling` | true | Content follows the fingers |
| `gestures.momentumFrictionPerSec` | 4.0 | Higher stops inertia sooner; `momentumEnabled` turns it off |
| `gestures.longPressRightClick` | true | Still one-finger press is a right click |
| `gestures.pinchStepPt` | 40 | Separation change per zoom keystroke; `pinchZoomEnabled` turns it off |
| `gestures.threeFingerSwipeEnabled` | true | Space and Mission Control swipes |
| `gestures.multiFingerArbitrationMs` | 40 | How long a gesture waits for late fingers before committing |
| `gestures.twoFingerMaxSeparationPt` | 600 | Contacts farther apart than this are a palm |
| `calibration.edgeRejectFraction` | 0.008 | Bezel margin for palm rejection; 0 disables |
| `calibration.rawMin/Max X/Y`, `swapXY`, `invertX/Y` | full range | Linear correction if the pointer lands off the finger |
| `display.vendor`, `display.model`, `display.nameFallback` | 1715, 5729, "MB16A" | How the panel's display is found among the online displays |
| `seize` | false | Open the HID device exclusively; not needed on MacOS 26 |
| `logLevel` | "info" | `debug` logs every frame and every posted event |

## Building from source

Requirements: MacOS 13 or later, Swift 5.9 or later. I build with
command line tools; the unit tests need Xcode's toolchain
(`scripts/test.sh` selects it without changing `xcode-select`).

```
make                # everything, debug (swift build)
make test           # unit tests (scripts/test.sh)
make app            # dist/Taction.app for this Mac (scripts/bundle.sh --native)
make universal      # universal dist/Taction.app, arm64 + x86_64 (scripts/bundle.sh)
make release        # dist/Taction-<version>.zip and .dmg, notarized (scripts/release.sh)
make publish        # release, then upload both to a draft GitHub release (scripts/publish.sh)
make install        # copy dist/Taction.app to Applications and open it
make replay         # every synthetic gesture through the pipeline
make help           # the full list
```

Releasing: bump `VERSION`, commit, push `main` to GitHub, then `make publish`.
It builds and notarizes, creates (or repairs) the draft release for
`v<version>` on the repository named in `Resources/Taction-Info.plist`,
and uploads the zip and DMG. Review the draft on GitHub and publish it there;
the updater looks for the asset named `Taction-<version>.zip`. The GitHub
token comes from `GH_TOKEN`, `~/.config/taction/publish.env`, or 1Password;
see the Makefile header.

`bundle.sh` signs with the first Developer ID Application identity in your
keychain (or `$TACTION_SIGN_IDENTITY`), with the hardened runtime. Ad hoc
signing is used as a last resort and disables the updater, which refuses
unsigned builds. `release.sh` notarizes when `TACTION_NOTARY_PROFILE` names a
`notarytool` keychain profile.

### The Pieces

| Target | What it is |
|---|---|
| `TactionKit` | Report parser, contact tracker, display mapper, gesture engine, config, fixture format. |
| `TactionHID` | `IOHIDManager` glue: find the panel, open it, send the mode report, stream input reports. |
| `TactionDaemon` | The daemon: device, display binding, event posting, status. Shared by the app and the CLI. |
| `Taction` | The menu bar app. |
| `tactiond` | Headless CLI form of the daemon for debugging (`--foreground --debug --record FILE`). |
| `taction-probe` | Diagnostics: `list`, `descriptor`, `features`, `capture`, `watch-cursor`, `permissions`. |
| `taction-replay` | Runs a recorded or synthetic report stream through the exact pipeline the daemon uses and prints the actions. |

```
swift run taction-replay --synthetic three-finger-swipe-left --verbose
swift run taction-probe capture --seconds 20 --out ~/gesture.bin
swift run taction-replay ~/gesture.bin
```

## License

MIT. Copyright (c) 2026 Jorj Bauer. See `LICENSE`.
