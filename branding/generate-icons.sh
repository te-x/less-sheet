#!/usr/bin/env bash
# Generate platform icon artifacts from the single source of truth branding/icon.svg.
#
#   branding/icon.svg  ->  branding/generated/AppIcon.icns   (macOS app icon)
#                          branding/generated/icon-<px>.png  (raster sizes, reused by other platforms)
#
# The SVG is the ONE file to edit; every platform artifact is generated from it.
# Rasterizer preference: rsvg-convert > resvg > cairosvg > inkscape > qlmanage
# (macOS Quick Look) — so it works with zero extra installs on macOS, and crisply
# if a real SVG rasterizer is present. Downscales to each size from a 1024 master.
#
# Usage: bash branding/generate-icons.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"       # branding/
src="$here/icon.svg"
out="$here/generated"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

[ -f "$src" ] || { echo "error: $src not found" >&2; exit 1; }
mkdir -p "$out"

# --- rasterize the SVG to a 1024x1024 master PNG (best available tool) ----------
master="$work/master.png"
if command -v rsvg-convert >/dev/null 2>&1; then
    rsvg-convert -w 1024 -h 1024 -o "$master" "$src"
elif command -v resvg >/dev/null 2>&1; then
    resvg -w 1024 -h 1024 "$src" "$master"
elif command -v cairosvg >/dev/null 2>&1; then
    cairosvg -W 1024 -H 1024 -o "$master" "$src"
elif command -v inkscape >/dev/null 2>&1; then
    inkscape "$src" --export-type=png -w 1024 -h 1024 -o "$master" >/dev/null 2>&1
elif command -v qlmanage >/dev/null 2>&1; then
    qlmanage -t -s 1024 -o "$work" "$src" >/dev/null 2>&1
    mv "$work/$(basename "$src").png" "$master"
else
    echo "error: no SVG rasterizer found (rsvg-convert/resvg/cairosvg/inkscape/qlmanage)" >&2
    exit 1
fi
[ -f "$master" ] || { echo "error: rasterization produced no master.png" >&2; exit 1; }

# --- macOS .iconset -> .icns ----------------------------------------------------
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
# name:size pairs required by iconutil
for entry in \
    icon_16x16.png:16 icon_16x16@2x.png:32 \
    icon_32x32.png:32 icon_32x32@2x.png:64 \
    icon_128x128.png:128 icon_128x128@2x.png:256 \
    icon_256x256.png:256 icon_256x256@2x.png:512 \
    icon_512x512.png:512 icon_512x512@2x.png:1024
do
    name="${entry%%:*}"; size="${entry##*:}"
    sips -z "$size" "$size" "$master" --out "$iconset/$name" >/dev/null
    # keep a copy of each unique raster size for non-macOS platforms
    cp "$iconset/$name" "$out/icon-${size}.png" 2>/dev/null || true
done
iconutil -c icns "$iconset" -o "$out/AppIcon.icns"

echo "Generated $out/AppIcon.icns (+ icon-*.png raster sizes from branding/icon.svg)"
