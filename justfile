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

# Build the macOS app and create a DMG
dmg:
    #!/usr/bin/env bash
    set -euo pipefail
    APP_NAME="hefty"
    SCHEME="hefty"
    PROJECT="mac_app/hefty/hefty.xcodeproj"
    BUILD_DIR="build/mac_app"
    DMG_DIR="build/dmg"
    DMG_NAME="${APP_NAME}.dmg"

    echo "🔨 Building ${APP_NAME} in release mode..."
    xcodebuild -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -derivedDataPath "$BUILD_DIR" \
        -destination 'generic/platform=macOS' \
        clean build

    APP_PATH=$(find "$BUILD_DIR" -name "${APP_NAME}.app" -type d | head -1)
    if [ -z "$APP_PATH" ]; then
        echo "❌ Could not find ${APP_NAME}.app"
        exit 1
    fi
    echo "✅ Built: $APP_PATH"

    echo "📦 Creating DMG..."
    rm -rf "$DMG_DIR"
    mkdir -p "$DMG_DIR"
    cp -R "$APP_PATH" "$DMG_DIR/"
    ln -s /Applications "$DMG_DIR/Applications"

    rm -f "build/${DMG_NAME}"
    hdiutil create -volname "$APP_NAME" \
        -srcfolder "$DMG_DIR" \
        -ov -format UDZO \
        "build/${DMG_NAME}"

    rm -rf "$DMG_DIR"
    echo "✅ DMG created: build/${DMG_NAME}"

# Preview GitHub Pages site locally
preview:
    open docs/index.html
