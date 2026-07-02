# MacPhotoMaster (Swift)

A from-scratch Swift/SwiftUI reimplementation of [MacPhotoMaster](https://github.com/BrianSmithPhotos/phototags)
(a Python/PySide6 app), taken on as a way to learn both Swift and SwiftUI. Not a port — see
`docs/SPEC.md` for the product spec this is building toward, and `docs/ARCHITECTURE.md` for how
code should be organized. Both are self-contained; you don't need the Python sibling repo to work
in this one.

## Requirements

- macOS 14+
- Xcode (recommended, for SwiftUI Previews and eventual entitlements/signing) or the Swift toolchain
  via Xcode Command Line Tools (`xcode-select --install`) if working from another editor.
- [`exiftool`](https://exiftool.org/) on `PATH` (`brew install exiftool`) — all metadata read/write
  goes through it, same as the Python sibling app.

## Getting started

Open `Package.swift` directly in Xcode, or from the command line:

```sh
swift build
swift run
swift test
```

`swift run` launches the app as a plain process (no `.app` bundle yet — no custom icon/Dock
identity). That's fine for early development; packaging as a proper signed `.app` is a later step,
likely via an actual Xcode project once there's entitlements (sandboxed file access, network) to
configure.

## Status

Skeleton stage: a three-pane `NavigationSplitView` shell (source / preview / metadata, matching
`docs/SPEC.md` §1) and one working service (`ExifToolClient`, wrapping the `exiftool` binary) to
prove out the Process/async I/O pattern described in `docs/ARCHITECTURE.md`. Everything else in
`docs/SPEC.md` is still to build.
