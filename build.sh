#!/bin/bash
set -e

APP="dist/StayAwake.app"

# Verify prerequisites
for cmd in swift codesign; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: $cmd not found" >&2
        exit 1
    fi
done

for file in Info.plist AppIcon.icns icon.png icon_inactive.png; do
    if [ ! -f "$file" ]; then
        echo "Error: missing required file: $file" >&2
        exit 1
    fi
done

rm -rf dist

echo "Building universal binary…"
swift build -c release --arch arm64 --arch x86_64

BIN_PATH=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
BINARY="$BIN_PATH/StayAwake"

mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp AppIcon.icns "$APP/Contents/Resources/"
cp icon.png icon_inactive.png "$APP/Contents/Resources/"

codesign --force --sign - "$APP"

# Preserve debug symbols
if [ -d "$BIN_PATH/StayAwake.dSYM" ]; then
    cp -R "$BIN_PATH/StayAwake.dSYM" dist/
fi

echo "Built: $APP ($(du -sh "$APP" | cut -f1))"
