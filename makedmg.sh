#!/bin/bash
# Membungkus mac-everything.app menjadi mac-everything.dmg (seret ke Applications untuk memasang).
set -euo pipefail
cd "$(dirname "$0")"

APP="mac-everything.app"
DMG="mac-everything.dmg"
VOL="mac-everything"

# Bangun ulang bila .app belum ada atau main.swift lebih baru.
if [ ! -x "$APP/Contents/MacOS/mac-everything" ] || [ main.swift -nt "$APP/Contents/MacOS/mac-everything" ]; then
  ./build.sh
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
echo "Selesai: $DMG ($(du -sh "$DMG" | cut -f1))"
echo "SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)  (perbarui juga di index.html)"
