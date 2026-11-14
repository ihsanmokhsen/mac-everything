#!/bin/bash
# Membuat AppIcon.icns dari makeicon.swift.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf AppIcon.iconset
swift makeicon.swift
cd AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s icon_512x512@2x.png --out icon_${s}x${s}.png >/dev/null
  if [ $s != 512 ]; then d=$((s*2)); sips -z $d $d icon_512x512@2x.png --out icon_${s}x${s}@2x.png >/dev/null; fi
done
cd ..
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rm -rf AppIcon.iconset
echo "Selesai: AppIcon.icns"
