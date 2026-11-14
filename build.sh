#!/bin/bash
# Membangun mac-everything.app dari main.swift. Hanya butuh Command Line Tools (tanpa Xcode).
set -euo pipefail
cd "$(dirname "$0")"

APP="mac-everything.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"

swiftc -Ounchecked -wmo main.swift -o "$APP/Contents/MacOS/mac-everything"
strip -x "$APP/Contents/MacOS/mac-everything"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>mac-everything</string>
    <key>CFBundleDisplayName</key><string>mac-everything</string>
    <key>CFBundleIdentifier</key><string>local.mac-everything</string>
    <key>CFBundleExecutable</key><string>mac-everything</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Selesai: $APP ($(du -sh "$APP" | cut -f1))"
