#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP=KeepAwake.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 KeepAwake.swift -o "$APP/Contents/MacOS/KeepAwake"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.keepawake</string>
  <key>CFBundleName</key><string>KeepAwake</string>
  <key>CFBundleExecutable</key><string>KeepAwake</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"

echo "Built $APP"
echo "1) One time:  sudo ./install-sudoers.sh"
echo "2) Run:       open $APP"
