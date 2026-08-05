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
# ReleaseSafe, NOT ReleaseFast: the security ARCH's wave (a) makes ReleaseSafe the
# SHIPPED mode (the backend gate certifies it and a frozen mode-guard test asserts
# it), because this app ingests untrusted files and URLs and runtime safety checks
# are what turn a memory-safety bug into a clean abort instead of an exploitable
# one. Measured cost, accepted when that wave was signed: ~19% index, ~10%
# search/filter, ~20% copy; cold-start is ~40x under the 500 ms budget and
# unaffected. Do not "optimize" this back.
(cd ../../backend && zig build -Doptimize=ReleaseSafe)
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

# 5) SEAL THE BUNDLE. This must be the LAST step: codesign hashes the bundle's
# contents into Contents/_CodeSignature/CodeResources, so ANY write into the
# bundle after this point (copying a resource, touching Info.plist, an editor
# writing .DS_Store) invalidates the signature again.
#
# Why this exists: the linker ad-hoc-signs the executable ONLY. Wrapping that
# executable in a .app produced a bundle whose signature says "I have sealed
# resources" while Contents/_CodeSignature did not exist, so macOS refused to
# launch it and told the user the app was "damaged and can't be opened - move it
# to the Trash". The app was never damaged; the bundle was just unsealed. This
# bit the author on his own installed app (2026-08-05), and `syspolicy_check
# distribution` grades the unsealed bundle a FATAL error:
#   "Code has no resources but signature indicates they must be present."
# Ad-hoc signing (identity "-") needs no certificate, no Apple account and no
# network, and it fixes exactly that. It does NOT make the app distributable:
# a DOWNLOADED copy still carries the quarantine attribute and Gatekeeper still
# demands a Developer ID signature + notarization (see docs/RELEASE.md).
#
# When a Developer ID exists, set LESSSHEET_CODESIGN_IDENTITY to it (e.g.
# "Developer ID Application: Name (TEAMID)"); notarization stays a separate,
# deliberate publishing step and is intentionally NOT done here.
identity="${LESSSHEET_CODESIGN_IDENTITY:--}"
if [ "$identity" = "-" ]; then
    # Ad-hoc: a secure timestamp is not available for it, and --timestamp=none
    # keeps this build step offline.
    codesign --force --sign - --timestamp=none "$app"
else
    # Real identity: notarization REQUIRES a secure timestamp (so this one does
    # reach Apple's timestamp server) and the hardened runtime. Signing here
    # still does not submit anything — notarization remains a separate step.
    codesign --force --sign "$identity" --timestamp --options runtime "$app"
fi
# Verify rather than assume: --strict catches the unsealed-resources case that
# a bare `codesign -dv` reports as "Sealed Resources=none" without failing.
codesign --verify --strict --verbose=2 "$app"

echo "Assembled $app"
