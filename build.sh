#!/bin/bash
# Builds ScreenFocus.app next to this script.
# Requires Xcode Command Line Tools:  xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

APP="ScreenFocus.app"
ARCH="$(uname -m)"   # arm64 or x86_64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -target "$ARCH-apple-macos13.0" \
    main.swift -o "$APP/Contents/MacOS/ScreenFocus"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                <string>ScreenFocus</string>
    <key>CFBundleDisplayName</key>         <string>ScreenFocus</string>
    <key>CFBundleExecutable</key>          <string>ScreenFocus</string>
    <key>CFBundleIdentifier</key>          <string>local.screenfocus</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>1.0</string>
    <key>CFBundleVersion</key>             <string>1</string>
    <key>LSMinimumSystemVersion</key>      <string>13.0</string>
    <key>LSUIElement</key>                 <true/>
    <key>LSAppNapIsDisabled</key>          <true/>
    <key>NSHighResolutionCapable</key>     <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP. Move it to /Applications and open it."