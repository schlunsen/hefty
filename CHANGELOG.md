# Changelog

# v1.3.0
## What's New
### GrandPerspective-style grouped treemap
- **Mac app**: Folders mode now renders a full hierarchical treemap of *every* scanned file — cushion-shaded blocks grouped inside their parent folder's rectangle, colored by top-level folder, with thin folder borders and labels on larger regions. Click selects (path + size in the header, Reveal in Finder), double-click descends, hover previews the path. Falls back to the flat treemap while the full map is being built during a scan.
- **CLI**: press `g` to toggle the new grouped treemap (default on) — files nest inside their folder's rectangle up to 4 levels deep, folders are colored by name and labeled, and the tree view shows dim filler blocks for below-threshold files so folder areas stay proportional.

# v1.2.0
## What's New
### CLI / TUI
- **Directory drill-down**: press `t` for a tree view with per-directory totals; `Enter` descends, `Backspace` goes up
- **Trash-safe deletes**: `d` now moves files to the system Trash (recoverable); `X` permanently deletes
- **Duplicate finder**: press `u` to find identical files (size + BLAKE3 hash) and see reclaimable space
- **Search**: press `/` to filter the file list as you type
- **File-type coloring**: treemap and list colored by category (video, archive, code, binary, ...)
- **Mouse support**: click to select in the list or treemap, scroll wheel to navigate
- **Reveal in file manager**: press `o` to reveal the selected file in Finder
- **Parallel scanning**: directory walking now uses `jwalk` for a significant speedup on large trees
- **Correctness**: hardlinks are counted once; `--du` reports allocated disk blocks instead of apparent size
- **New flags**: `--exclude <glob>` (repeatable), `--one-file-system`, `--du`, `--format json|csv` for list mode
- Permission-denied paths are counted and surfaced in the status bar
- Rendering only redraws when state changes (lower CPU when idle)

### Mac app
- **Folder drill-down view**: new Files/Folders toggle; browse per-directory totals with breadcrumb navigation, relative size bars, and a treemap of the current folder (click a folder block to descend)
- Deletes now move files to the **Trash** instead of permanently removing them
- **Reveal in Finder** and **Quick Look** (spacebar / context menu) for files in the list
- **Full Disk Access guidance**: a banner appears when items can't be read, with a shortcut to System Settings

# v1.1.0
## What's New
### Multi-File selection & batch delete ( CLI + Mac app
- **CLI**: Space to toggle mark/ current file, auto-advance with next. `d` deletes single ( marked files
- **Mac app**: new multi-select UI with checkboxes for batch delete. "Delete N selected files"

- Optimized block border animation with Metal-backed rendering for smoother transitions