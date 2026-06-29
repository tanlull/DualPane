# DualPane — project guide for AI assistants

DualPane is a native macOS dual-pane file manager built with SwiftUI + AppKit,
compiled with Swift Package Manager. Source lives in `Sources/`; the app bundle
is assembled by `./build-app.sh`.

## RULE: bump the version on EVERY bug fix

Whenever you fix a bug (or ship any user-visible change), increment the version
as part of the same change. Never fix a bug without bumping the version.

Do all three, together:

1. **`Info.plist`** — increment `CFBundleShortVersionString` (e.g. `1.7` → `1.8`)
   and bump `CFBundleVersion` by 1 (e.g. `8` → `9`).
2. **`Sources/AboutView.swift`** — add a new `Release(...)` entry at the **top**
   of `AppInfo.changelog`, with the new version, today's date (`d MMM yyyy`), and
   a short plain-language bullet for each change. Keep the fallback on the
   `static let version = ... ?? "x.y"` line in sync with the new version.
3. Use the version number in the commit message (e.g. `v1.8: fix …`).

Versioning is simple semver-ish: patch/minor bumps for fixes and small features.

## Build & run

```bash
./build-app.sh        # compiles release, builds DualPane.app, ad-hoc signs it
```

Note: `build-app.sh` signs ad-hoc (`codesign --sign -`), which changes the code
hash on every build and breaks the Full Disk Access grant DualPane needs to read
iCloud/OneDrive (`~/Library/CloudStorage`, `~/Library/Mobile Documents`). For a
grant that survives rebuilds, sign with a stable self-signed identity instead.

## Watch out for (file-operation safety)

This is a file manager — destructive operations must be fail-safe:

- A **copy must never modify or delete its source.** Compare source/destination
  by real file identity (`fileResourceIdentifierKey` / resolved paths), never by
  raw path strings — iCloud/OneDrive aliases, symlinks and firmlinks make the
  same item look like two different paths.
- When **replacing** on a name conflict, copy the new item in fully *first*, then
  trash the old one and swap — so a failed copy can't lose data.
- **Materialize online-only iCloud items** (`startDownloadingUbiquitousItem`)
  before copying, or copies are silently incomplete.

The transfer logic lives in `runTransfer` / `dpIsSameItem` / `dpMaterialize` in
`Sources/ContentView.swift`.
