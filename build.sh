#!/bin/zsh
# Builds ScreenVibe.app, signs it, installs it to ~/Applications and starts it.
# Signing: SIGN_ID if set, else your first Developer ID or Apple Development certificate, else ad hoc.
# With a certificate, the Screen Recording permission survives rebuilds; ad hoc, macOS asks again after each build.
set -euo pipefail
cd "$(dirname "$0")/app"

swift build -c release
APP="$HOME/Applications/ScreenVibe.app"
pkill -x ScreenVibe 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ScreenVibe "$APP/Contents/MacOS/ScreenVibe"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.slsuite.screenvibe</string>
  <key>CFBundleName</key><string>ScreenVibe</string>
  <key>CFBundleExecutable</key><string>ScreenVibe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>ScreenVibe reads the web address of the front browser tab, so Claude knows which page you marked.</string>
</dict></plist>
PLIST
cat > "$PWD/.build/ScreenVibe.entitlements" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.automation.apple-events</key><true/>
</dict></plist>
ENT
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE '"(Developer ID Application|Apple Development): [^"]+"' | head -1 | tr -d '"')}"
codesign --force --options runtime --entitlements "$PWD/.build/ScreenVibe.entitlements" --sign "${SIGN_ID:--}" "$APP"
codesign --verify --strict "$APP"
open "$APP"
echo "Installed and started $APP"
