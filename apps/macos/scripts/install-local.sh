#!/bin/bash
# Build and install a local macOS test copy. No sudo or Homebrew required.
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$repo_dir"
exec > >(tee "$repo_dir/install-macos.log") 2>&1
trap 'printf "\nInstallation stopped at line %s. See %s/install-macos.log\n" "$LINENO" "$repo_dir" >&2' ERR
fail() { printf '\n%s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || fail 'Run this installer on your Mac.'
os_version="$(sw_vers -productVersion)"
[[ "${os_version%%.*}" -ge 26 ]] || fail 'less-sheet requires macOS 26 or later.'
if ! xcrun --find swift >/dev/null 2>&1; then
    fail 'Install Xcode 26 or later, open it once to finish setup, then rerun this installer.'
fi
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
[[ "${sdk_version%%.*}" -ge 26 ]] || fail 'Select Xcode 26 or later in Xcode > Settings > Locations > Command Line Tools, then rerun.'
export PATH="$(dirname "$(xcrun --find swift)"):$PATH"
xcrun swift --version

# Pin the engine compiler. Checksums are from ziglang.org/download/index.json.
if ! command -v zig >/dev/null 2>&1 || [[ "$(zig version)" != 0.16.0 ]]; then
    case "$(uname -m)" in
        arm64)
            zig_arch=aarch64
            zig_sha=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489
            ;;
        x86_64)
            zig_arch=x86_64
            zig_sha=0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7
            ;;
        *) fail 'Unsupported Mac architecture.' ;;
    esac
    tool_dir="$HOME/Library/Caches/less-sheet/build-tools"
    zig_name="zig-$zig_arch-macos-0.16.0"
    mkdir -p "$tool_dir"
    if [[ ! -x "$tool_dir/$zig_name/zig" ]]; then
        archive="$tool_dir/$zig_name.tar.xz"
        printf '\nDownloading Zig 0.16.0…\n'
        curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
            "https://ziglang.org/download/0.16.0/$zig_name.tar.xz" -o "$archive"
        actual_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
        [[ "$actual_sha" == "$zig_sha" ]] || fail 'Zig download checksum mismatch. Nothing was installed.'
        tar -xJf "$archive" -C "$tool_dir"
    fi
    export PATH="$tool_dir/$zig_name:$PATH"
fi
[[ "$(zig version)" == 0.16.0 ]] || fail 'Could not activate Zig 0.16.0.'

printf '\nBuilding less-sheet %s…\n' "$(cat VERSION)"
printf 'Preferences source: '
shasum -a 256 apps/macos/Sources/LessSheetApp/AppPreferencesView.swift
bash apps/macos/scripts/assemble-app.sh
printf '\nTesting saved appearance settings…\n'
(cd apps/macos && swift test -c release --filter AppearanceSettingsTests)
bin_dir="$(cd apps/macos && swift build -c release --show-bin-path)"
source_app="$bin_dir/less-sheet.app"
[[ -x "$source_app/Contents/MacOS/LessSheet" ]] || fail 'The app bundle was not produced.'
codesign --verify --strict "$source_app"

if pgrep -x LessSheet >/dev/null; then
    fail 'Quit the running less-sheet app, then rerun this installer. The build is cached.'
fi
install_dir="$HOME/Applications"
cli_dir="$HOME/.local/bin"
mkdir -p "$install_dir" "$cli_dir"
destination="$install_dir/less-sheet.app"
stamp="$(date +%Y%m%d-%H%M%S)-$$"
# Stage and verify the whole bundle before touching an installed copy.
staged="$install_dir/.less-sheet-install-$stamp.app"
ditto "$source_app" "$staged"
codesign --verify --strict "$staged"
if [[ -e "$destination" || -L "$destination" ]]; then
    backup="$install_dir/less-sheet.backup-$stamp.app"
    mv "$destination" "$backup"
    printf 'Previous app saved to %s\n' "$backup"
fi
mv "$staged" "$destination"
cli_link="$cli_dir/less-sheet"
if [[ -e "$cli_link" || -L "$cli_link" ]]; then
    mv "$cli_link" "$cli_link.backup-$stamp"
fi
ln -s "$destination/Contents/MacOS/LessSheet" "$cli_link"
"$cli_link" --version
printf '\nInstalled: %s\nCLI: %s\nBuild log: %s/install-macos.log\n' "$destination" "$cli_link" "$repo_dir"
printf 'Open App preferences with Command-comma.\n'
# Launch this installed copy, even if Launch Services knows another bundle
# with the same application identifier elsewhere on the Mac.
open -n "$destination"
