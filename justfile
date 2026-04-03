# hefty — find the hefty files hogging your disk space

default:
    @just --list

# Build in debug mode
build:
    cargo build

# Build in release mode
release:
    cargo build --release

# Run in interactive TUI mode
run *args:
    cargo run --release -- {{args}}

# Run in list mode (non-interactive)
list path="." n="20" min="1MB":
    cargo run --release -- {{path}} --list -n {{n}} --min-size {{min}}

# Run tests
test:
    cargo test

# Run clippy lints
lint:
    cargo clippy -- -D warnings

# Format code
fmt:
    cargo fmt

# Check formatting without modifying
fmt-check:
    cargo fmt -- --check

# Run all checks (fmt, lint, test)
check: fmt-check lint test

# Clean build artifacts
clean:
    cargo clean

# Install binary to ~/.cargo/bin
install:
    cargo install --path .

# Preview GitHub Pages site locally
preview:
    open docs/index.html
