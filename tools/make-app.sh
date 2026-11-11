#!/usr/bin/env bash
# Wraps the built executable in a minimal .app bundle.
#
# A bare SPM executable has no bundle, so macOS treats it as a background tool:
# `NSApplication` starts, but no window is ever shown and the process does not
# appear in the Dock. `LSUIElement` absent plus a real Info.plist is what makes
# it a foreground app.
set -euo pipefail
cd "$(dirname "$0")"

swift build --configuration "${1:-debug}" >&2
BIN="$(swift build --configuration "${1:-debug}" --show-bin-path)/pagent-preview"
APP="$(pwd)/PAgent Preview.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/PAgent Preview"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>PAgent Preview</string>
  <key>CFBundleIdentifier</key><string>com.example.PAgent.Preview</string>
  <key>CFBundleName</key><string>PAgent Preview</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- The harness talks to http://127.0.0.1 by default. -->
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

echo "$APP"
