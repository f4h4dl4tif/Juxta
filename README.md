# Juxta

A native macOS compare-and-merge tool for files, folders, tables, images and binaries.
It is built with SwiftUI plus a custom AppKit diff canvas: only visible rows are drawn and every pane scrolls in lockstep.

## Build & run

```bash
./build.sh                       # → build/Juxta.app (UNIVERSAL=1 for arm64 + x86_64)
open build/Juxta.app
cp -R build/Juxta.app /Applications/
```

Requires macOS 15+ and Xcode (the script points `DEVELOPER_DIR` at `/Applications/Xcode.app`).

Command line (`build/juxta` launcher, or `open -a Juxta --args …`):

```bash
build/juxta left.txt right.txt          # text compare
build/juxta dirA dirB                   # folder compare
build/juxta mine.txt base.txt theirs.txt  # 3-way merge
```

The session type is detected automatically: folders → folder compare, images → picture compare, CSV/TSV → table compare, binaries → hex compare, everything else → text compare.

Try the bundled samples: `build/juxta Examples/left Examples/right`.

## Features

**Sessions & workspace**: tabbed sessions, a home screen with all session types, recent sessions with filtering, drag-and-drop anywhere, path fields with recents and browse, unsaved-change prompts, Settings (font, size, tab width, whitespace display, context lines, default rules).

**Text Compare**
- Side-by-side Myers diff with similarity-based line alignment and character-level highlights
- Difference sections, orphan lines, and *unimportant* differences (ignored whitespace/case/blank lines/regex patterns)
- View filters: All / Diffs / Same / Context
- Next/previous/first/last difference with smooth animated scrolling; overview map (click/drag to jump)
- Merging: per-section copy arrows in the centre gutter, Copy to Left/Right for selections
- Inline editing (double-click / Return), insert (⌘Return) and delete lines, unlimited undo/redo, Save / Save As
- Encoding (UTF-8, UTF-8 BOM, UTF-16 LE/BE, Windows-1252) and line ending (LF/CRLF/CR) detection and conversion
- Compare clipboard text, swap sides, reload, find in both files, go to line
- Line-details pane, whitespace visualisation, HTML report and unified `.diff` patch export

**Folder Compare / Folder Sync**
- Recursive aligned trees; compare by size & time, time, size, or binary content
- Status colouring (newer / older / different / orphan), filters (All, Diffs, Same, Orphans, Newer Left/Right), quick name filter
- Include/exclude wildcards, hidden files, timestamp tolerance
- Copy to either side, move to Trash, match timestamps, reveal in Finder, open any pair in the right viewer
- Sync panel: Update Left/Right/Both, Mirror to Left/Right with an action preview; HTML report

**Text Merge (3-way)**: automatic diff3 merge, conflict detection, Take Left / Base / Right / Left+Right / Right+Left, resolve-all, editable output, conflict markers for unresolved sections, undo/redo.

**Table Compare**: CSV/TSV with delimiter detection and quoted fields; align by key column (auto-detected) or row order; cell-level highlights with a changed-cell detail strip.

**Hex Compare**: memory-mapped byte comparison, 8–32 bytes per row, differing-byte highlights in hex and ASCII, next/prev difference, go to offset.

**Picture Compare**: side-by-side (synced pan/zoom), difference map with tolerance, blend, swipe; pinch to zoom, drag to pan, pixel statistics.

## Keyboard

| Action | Shortcut |
|---|---|
| Next / previous difference | ⌥⌘↓ / ⌥⌘↑ |
| First / last difference | ⇧⌥⌘↑ / ⇧⌥⌘↓ |
| Copy to right / left | ⌥⌘→ / ⌥⌘← |
| Show All / Diffs / Same / Context | ⌃⌘1 … ⌃⌘4 |
| Find, find next / previous | ⌘F, ⌘G / ⇧⌘G |
| Go to line (hex: offset) | ⌘L |
| Save, Reload | ⌘S, ⌘R |
| New tab, close tab, next/previous tab | ⌘T, ⌘W, ⇧⌘] / ⇧⌘[ |
| Text size | ⌘+ / ⌘− / ⌘0 |

## Layout

- `Sources/JuxtaCore`: engines (linear-space Myers diff, line alignment, intraline diff, diff3 merge, text decoding, CSV, folder scan and sync planning), covered by `swift test`
- `Sources/Juxta`: the app (`DiffCanvas.swift` is the shared high-performance renderer)
- `Scripts/snap.sh`: dev helper that writes a PNG of the window (`JUXTA_SNAPSHOT=…`)
