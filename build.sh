#!/bin/zsh
# Builds UandI.app, signs it with the Developer ID (so the Screen Recording permission
# survives rebuilds), installs it to ~/Applications and starts it.
set -euo pipefail
cd "$(dirname "$0")/app"

swift build -c release
APP="$HOME/Applications/UandI.app"
pkill -x UandI 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/UandI "$APP/Contents/MacOS/UandI"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.slsuite.uandi</string>
  <key>CFBundleName</key><string>UandI</string>
  <key>CFBundleExecutable</key><string>UandI</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>UandI reads the web address of the front browser tab, so Claude knows which page you marked.</string>
</dict></plist>
PLIST
cat > "$PWD/.build/UandI.entitlements" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.automation.apple-events</key><true/>
</dict></plist>
ENT
codesign --force --options runtime --entitlements "$PWD/.build/UandI.entitlements" --sign "Developer ID Application: Hanaan Rosenthal (467NFKHC5S)" "$APP"
codesign --verify --strict "$APP"
open "$APP"
echo "Installed and started $APP"
