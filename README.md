# hefty

<!-- TODO: Add banner image once HF_API_KEY is configured -->
<!-- ![hefty banner](banner.png) -->

A fast CLI disk usage analyzer inspired by [GrandPerspective](https://grandperspectiv.sourceforge.net/) for macOS. Find the hefty files hogging your disk space.

## Features

- **Fast scanning** — recursively walks directories using `walkdir`
- **Interactive TUI** — treemap visualization + scrollable file list powered by `ratatui`
- **List mode** — non-interactive output for scripting and quick checks
- **Configurable** — filter by minimum file size, limit number of results

## Install

### Homebrew

```sh
brew tap schlunsen/tap
brew install hefty
```

### Cargo

```sh
cargo install --git https://github.com/schlunsen/hefty
```

### From source

```sh
git clone https://github.com/schlunsen/hefty.git
cd hefty
cargo build --release
./target/release/hefty --help
```

## Usage

```
hefty [OPTIONS] [PATH]

Arguments:
  [PATH]  Directory to scan [default: .]

Options:
  -m, --min-size <MIN_SIZE>  Minimum file size to show [default: 1MB]
  -n, --top <TOP>            Show top N largest files [default: 100]
  -l, --list                 Print results and exit (no interactive UI)
  -h, --help                 Print help
  -V, --version              Print version
```

### Interactive TUI

```sh
hefty ~
```

Opens a terminal UI with a treemap visualization and a scrollable file list sorted by size.

**Keyboard shortcuts:**

| Key | Action |
|-----|--------|
| `↑` / `k` | Move up |
| `↓` / `j` | Move down |
| `Page Up` / `Page Down` | Scroll fast |
| `Home` / `End` | Jump to top / bottom |
| `Tab` | Toggle treemap view |
| `q` / `Esc` | Quit |

### List mode

```sh
hefty ~/projects --list -n 10 --min-size 100MB
```

```
        SIZE  PATH
────────────────────────────────────────────────────────────────────────────────
      1.5 GB  legalize-es/.index_cache/es_index.pkl
    724.0 MB  clovr-cat/desktop/clovr
    719.7 MB  clovr-cat/desktop/build/bin/clovr
    652.2 MB  clovr-cat/desktop/frontend/public/models/encoder-model.int8.onnx
    621.9 MB  legalize-dk/.index_cache/dk_index.pkl
    530.7 MB  legalize-de/.index_cache/de_index.pkl
    444.4 MB  src-tauri/target/debug/libwee_desktop_lib.a
    444.4 MB  src-tauri/target/debug/deps/libwee_desktop_lib.a
    248.6 MB  src-tauri/target/release/bundle/macos/Donna_1.0.0_aarch64.dmg
    248.5 MB  src-tauri/target/release/bundle/macos/Donna_1.0.0_aarch64.dmg
────────────────────────────────────────────────────────────────────────────────
     39.5 GB  Total scanned
```

## Development

Requires [just](https://github.com/casey/just) as a task runner.

```sh
just          # list available recipes
just build    # debug build
just release  # release build
just run ~    # run interactive TUI
just list . 20 1MB  # list mode (path, top N, min size)
just check    # fmt + clippy + tests
just fmt      # format code
just lint     # clippy lints
just test     # run tests
just clean    # clean build artifacts
```

## License

MIT
