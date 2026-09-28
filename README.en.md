<div align="center">
  <img src="docs/images/appbox-icon.png" width="120" alt="AppBox icon" />
  <h1>AppBox</h1>
  <p>
    <strong>A full-screen launcher and app-organizing console for macOS</strong>
  </p>
  <p>
    <img alt="platform" src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple" />
    <img alt="swift" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" />
    <img alt="tests" src="https://img.shields.io/badge/tests-291%20passed-4c1?logo=googletest" />
    <img alt="version" src="https://img.shields.io/badge/version-0.1.0-blue" />
    <img alt="ui" src="https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-informational" />
  </p>
  <p><a href="README.md">中文</a> · English</p>
</div>

## What it is

macOS 26 (Tahoe) removed Launchpad. Its replacement — the "Apps" view inside Spotlight — can only lay every app out in one flat list. **There is no way to build your own groups**, and no place to rename, hide or pin an individual app. The more apps you install, the harder it becomes to see how your applications are organized.

**AppBox fills that gap.** It is a normal, resident macOS app: a global hot key raises a full-screen launcher overlay, and a separate Console window owns all configuration. AppBox only manages the **presentation layer** — grouping, aliases, hiding, ordering. It never modifies, moves or deletes an app bundle on disk.

| Surface | Responsibility | How you open it |
|---|---|---|
| **Overlay** | Browse and launch | Global hot key ⌥+Space; fills the screen the pointer is on |
| **Console** | The single place where configuration is written | Click the Dock icon |

## Screenshots

### Overlay

Groups render as *folder tiles* holding thumbnails of the first 9 apps inside them; ungrouped apps sit flat in the same grid. The blue ring is the current keyboard selection.

![Overlay top-level grid](docs/images/overlay-groups.png)

Clicking (or pressing Return on) a folder tile expands it into that group's sub-grid; click empty space or press Esc to go back.

![Overlay group expanded](docs/images/overlay-folder-expanded.png)

### Search

Just start typing and the search field takes focus, filtering live. Search spans **all apps across every group** and results are shown flat. Matching covers the real name, localized name, alias, bundle ID and **pinyin initials** — the screenshot below types `zpqy` and hits 「智谱清言」.

![Overlay pinyin search](docs/images/overlay-search-pinyin.png)

### Console

Groups with per-group counts on the left, the selected group's app grid on the right, and a bottom bar for creating a group and toggling launch-at-login.

![Console group management](docs/images/console-groups.png)

Switch the scope picker to "All" to filter across every group; each result is labelled with the group it belongs to.

![Console cross-group search](docs/images/console-search-all.png)

Clicking an app slides open the inspector: real name, bundle ID, path, owning group, plus hide / lock / alias actions.

![Console app inspector](docs/images/console-inspector.png)

## Features in detail

### Discovery and sync

- Scans `.app` bundles in `/Applications`, `/System/Applications` and `~/Applications` (one level deep), ignoring nested bundles inside app packages so helpers are never treated as apps.
- Identity key is the **bundle ID**; the rare app that declares none falls back to its absolute path.
- Duplicate bundle IDs collapse to one entry, preferring `/Applications` > `/System/Applications` > `~/Applications`.
- Newly found apps land in the reserved **Ungrouped** group.
- **FSEvents** keeps the library live: newly installed apps appear without restarting AppBox; uninstalled ones are kept in config but flagged **Missing** — gone from the overlay, visible and cleanable in the Console.
- Icons are extracted via `NSWorkspace`, cached as PNGs on disk keyed by bundle ID + package modification date, so a second launch never re-extracts them.
- "Last known path" refreshes on every scan, so an app that moved can still be launched.

### Overlay

- ⌥+Space raises it on the screen the mouse is currently on, above every window; press it again or Esc to dismiss.
- Single click launches and auto-dismisses. A running app is activated instead of re-opened.
- Arrow keys move the highlight; Return launches or expands.
- Typing goes straight into search — Chinese and English names, aliases, bundle IDs, pinyin initials.
- Drag to organize inside the overlay: reorder within a group, drop an app on a folder tile to move it in, drop it on empty space inside a group to send it back to Ungrouped, drag folder tiles to reorder groups.
- The grid scrolls vertically when entries exceed one screen; nothing is silently dropped.
- Dismissal restores focus without a visible flash.

### Console

- **Groups**: create, rename, delete, reorder. Deleting a group returns all of its apps to Ungrouped — nothing is lost. Ungrouped cannot be deleted or renamed. Empty groups are kept.
- **Per app**: set/clear alias, hide and restore, lock position (a locked app is not moved by automatic sorting), inspect real name / bundle ID / path / group / hidden & missing state.
- **Missing apps**: the "Maintenance" section only appears when there actually are missing records — quiet normally, obvious when something breaks. Records can be forgotten one at a time.
- **Search**: current group or all groups, same matching rules as the overlay (pinyin included), live hit count in the footer.
- **Launch at login**: registered through `SMAppService`; the switch reflects the system's real state and snaps back if registration fails.
- Closing the window does not quit — the hot key keeps working. Quit with ⌘Q.

### Setup wizard (first launch)

When no config file exists, the Console opens the Setup wizard: group suggestions derived from the system's `LSApplicationCategoryType`, each renameable, mergeable, deletable or skippable; apps with no declared category go to Ungrouped. **Nothing is written until you confirm** — dismissing the wizard writes nothing at all.

### Config and profiles

- Config lives in `~/Library/Application Support/AppBox/<profile>.json`, one file per profile: human-readable, hand-editable, trivially backed up.
- A `schemaVersion` (currently 2) travels with the file. New fields get defaults at decode time and do *not* bump the version; only changes that would misread an old file do. Writing is **refused** when the file on disk is newer than the running code, so downgrading plus a stray setting change cannot wipe new fields.
- Every load passes through `normalized()`: Ungrouped is guaranteed, apps pointing at a vanished group fall back to it, whitespace-only aliases are dropped.
- The icon cache sits in a sibling `icons/` directory, keeping the config file small.

## Architecture

All domain logic is quarantined in a module with zero AppKit dependency, giving tests one stable seam.

```
AppBoxCore   SwiftPM library · no AppKit
  ├── Domain model     AppRecord / Group / AppBoxConfig / ApplicationConfig
  ├── LibraryService   the single facade: snapshot queries + every mutation
  ├── LibrarySnapshot  render-ready state (folder tiles, grid, missing list)
  ├── Persistence      AppBoxConfigStore: JSON codec, schema versioning, profiles
  ├── Search           AppSearch: multi-field + pinyin initials
  ├── Overlay logic    OverlayModel / OverlayDrop / GhostDropGuard / Geometry
  ├── Setup            SetupAdvisor / SetupWizardModel
  └── Ports            AppScanning · IconProviding · Launching · Watching · LoginItemControlling
                          ↓ real implementations injected at runtime, fakes in tests
AppBox       SwiftPM executable · SwiftUI + AppKit
  ├── Overlay window   OverlayWindow / OverlayView / OverlayController (level, focus, multi-screen)
  ├── Global hot key   Carbon RegisterEventHotKey
  ├── System impls     AppScanner / IconCache / WorkspaceLauncher / FSEventsWatcher / LoginItem
  └── Console UI       ConsoleView / ApplicationInspector / MissingApplicationsView / SetupWizardView
```

**Tests target exactly one seam: `LibraryService`.** Scanning, icons, launching, watching and login items are injected ports replaced by fakes (`FakePorts.swift`), so all 291 domain tests need no AppKit, no real UI and no real filesystem — and finish in 0.7 s.

Covered by a manual checklist instead: window level and focus, hot key registration, real icon extraction, real app launching, FSEvents firing, Console interaction.

## Key decisions

| ADR | Decision | Why |
|---|---|---|
| [0001](docs/adr/0001-swiftui-swiftpm.md) | SwiftUI + SwiftPM, `.app` assembled by script, no `.xcodeproj` | Project files are hard to diff; a SwiftPM package still opens in Xcode for previews and debugging |
| [0002](docs/adr/0002-归属制分组.md) | Ownership-based groups — an app belongs to exactly one group | Unambiguous drag semantics, simpler data model |
| [0003](docs/adr/0003-bundleid-主键.md) | Bundle ID as primary key, path only as location | Config survives an app being moved or renamed |
| [0004](docs/adr/0004-控制台只管理展示层.md) | Console manages presentation only; no uninstalling | It is an organizer, not a package manager; keeps permission needs minimal |
| [0005](docs/adr/0005-配置用-json.md) | JSON files, not a database | Tens of KB never need SQLite; plain text is editable and one file per profile is free |
| [0006](docs/adr/0006-只做全局快捷键不做手势.md) | Global hot key only, no trackpad pinch | Pinch needs `CGEventTap` plus Accessibility permission and can be stolen by Dock |

Terminology: [CONTEXT.md](CONTEXT.md) (Chinese). Full requirements and acceptance criteria: [docs/specs/2026-09-26-appbox-启动台.md](docs/specs/2026-09-26-appbox-启动台.md) (Chinese).

## Status

Shipped: project skeleton and packaging, global hot key and overlay window, app scanning with dedup and icon cache, config persistence with schema checks, group model with Ungrouped protection, folder tiles and sub-grids, keyboard navigation, search with pinyin, Console with group management, per-app management and the missing list, drag-to-organize inside the overlay, FSEvents incremental sync, the setup wizard, launch at login, cross-group Console search.

Not built yet (tickets 013 / 016 / 017 under `.scratch/AppBox/tickets/`):

- A settings pane: configurable hot key, grid rows/columns, icon size and background blur (today the hot key is fixed at ⌥+Space and the grid at 7 columns × 96 pt)
- Export / import UI and profile switching UI — the store already supports one JSON file per profile; nothing surfaces it yet
- Formal performance verification (measured here: a full scan of 108 apps takes about 0.09 s)

Out of scope by design: uninstalling apps, trackpad pinch, custom icons, right-click menus in the overlay, tag-based multi-group membership, Spotlight-wide scanning, covering several screens at once, a menu bar item, batch launching, usage statistics, code signing and notarization, iOS, cloud sync.

## Getting started

### Requirements

- macOS 14 or later (developed on macOS 26 Tahoe, arm64)
- A Swift 6 toolchain — Xcode or CommandLineTools alone; no `.xcodeproj` is involved

### Build

```bash
swift build                                     # debug
swift build -c release                          # release
Configuration=release ./scripts/build-app.sh    # compile + assemble dist/AppBox.app
open dist/AppBox.app                            # launch, then press ⌥+Space
```

`scripts/build-app.sh` handles what SwiftPM does not: the bundle layout, `Info.plist`, patching the SDK field in `LC_BUILD_VERSION` (without it SwiftUI's `.draggable` never starts a drag session), and an ad-hoc code signature.

### Disk image

```bash
./scripts/build-dmg.sh        # -> dist/AppBox-0.1.0.dmg, with an Applications shortcut
```

### Test

```bash
swift test        # 291 tests in 44 suites, ~0.7 s
```

### Command-line entry points

```bash
dist/AppBox.app/Contents/MacOS/AppBox --scan            # print scanned apps, bundle IDs, roots, categories
dist/AppBox.app/Contents/MacOS/AppBox --config          # print config paths and the load outcome
dist/AppBox.app/Contents/MacOS/AppBox --show-overlay    # raise the overlay 2 s after launch
```

### Where the data lives

| Contents | Path |
|---|---|
| Config, one file per profile | `~/Library/Application Support/AppBox/default.json` |
| Icon cache | `~/Library/Application Support/AppBox/icons/` |

## Permissions

No Accessibility permission and no TCC grant of any kind: the hot key uses Carbon's `RegisterEventHotKey`, scanning only reads public directories, launching goes through `NSWorkspace`. AppBox is a regular app with a Dock icon, not an `LSUIElement` agent.
