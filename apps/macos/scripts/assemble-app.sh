#!/usr/bin/env bash
# Assemble LessSheet.app from the SwiftPM release binary + Bundle/Info.plist.
# Bundle assembly lives OUTSIDE SwiftPM (ARCH-walking-skeleton functional req 6):
# it links the Zig core (release) then wraps the executable in a .app declaring
# the CSV file-type association. Prints the bundle path on success.
#
# Usage: bash apps/macos/scripts/assemble-app.sh
set -euo pipefail

macos_dir="$(cd "$(dirname "$0")/.." && pwd)"   # apps/macos
cd "$macos_dir"

# 1) Build the statically-linked core (release), then the app (release).
(cd ../../backend && zig build -Doptimize=ReleaseFast)
# SwiftPM doesn't track liblesssheet.a as a build input (it's linked via -L), so a stale link product can keep the previous archive; drop only the link products (not object caches) to force a relink against the fresh core.
rm -f .build/*/release/LessSheet
rm -rf .build/*/release/*.xctest
swift build -c release

bin_dir="$(swift build -c release --show-bin-path)"
# The installed app is named "less-sheet" (bundle file + CFBundleName/DisplayName);
# the executable inside stays "LessSheet" (the SwiftPM product / CFBundleExecutable).
rm -rf "$bin_dir/LessSheet.app"   # drop the pre-rename bundle if present
app="$bin_dir/less-sheet.app"

# 2) Generate the app icon from the shared source (branding/icon.svg -> AppIcon.icns).
bash "$macos_dir/../../branding/generate-icons.sh"

# 3) Lay out the bundle: Contents/{MacOS,Resources,Info.plist,Resources/AppIcon.icns}.
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/LessSheet" "$app/Contents/MacOS/LessSheet"
cp "$macos_dir/Bundle/Info.plist" "$app/Contents/Info.plist"
cp "$macos_dir/../../branding/generated/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

# 4) SwiftPM copies target resources (the empty-bundle case has none) next to
#    the binary; mirror any LessSheet_*.bundle so the app finds them at runtime.
for res in "$bin_dir"/*.bundle; do
    [ -e "$res" ] && cp -R "$res" "$app/Contents/MacOS/" || true
done

echo "Assembled $app"
