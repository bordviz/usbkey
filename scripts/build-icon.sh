#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -f Resources/AppIcon.icns && Resources/AppIcon.icns -nt Resources/AppIcon-source.png ]]; then exit 0; fi
iconset="$PWD/.build/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" Resources/AppIcon-source.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    /usr/bin/sips -z "$retina" "$retina" Resources/AppIcon-source.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o Resources/AppIcon.icns
