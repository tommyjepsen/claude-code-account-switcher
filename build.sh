#!/bin/zsh
# Builds ClaudeSwitcher.app into ./build. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/ClaudeSwitcher"

APP=build/ClaudeSwitcher.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeSwitcher"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Claude Switcher</string>
    <key>CFBundleDisplayName</key><string>Claude Switcher</string>
    <key>CFBundleIdentifier</key><string>com.tommyjepsen.claude-switcher</string>
    <key>CFBundleExecutable</key><string>ClaudeSwitcher</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x ClaudeSwitcher || true
    rm -rf /Applications/ClaudeSwitcher.app
    cp -R "$APP" /Applications/
    open /Applications/ClaudeSwitcher.app
    echo "Installed to /Applications/ClaudeSwitcher.app"
fi
