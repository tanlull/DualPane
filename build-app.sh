#!/bin/bash
# Builds DualPane.app from source.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Compiling (release)..."
swift build -c release

echo "==> Generating app icon..."
swift make_icon.swift
iconutil -c icns DualPane.iconset -o AppIcon.icns

echo "==> Assembling DualPane.app..."
APP="DualPane.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/"
cp .build/release/DualPane "$APP/Contents/MacOS/"
cp AppIcon.icns "$APP/Contents/Resources/"
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - "$APP"

echo "==> Done: $(pwd)/$APP"
