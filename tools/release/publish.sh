#!/usr/bin/env bash
#
# Publish a release FROM THE ARCH BOX. Pushes the source, creates the GitHub
# release, uploads every artifact, builds and uploads the Flatpak bundle,
# updates the Homebrew tap, and then verifies the lot LOGGED OUT.
#
#   tools/release/publish.sh
#   tools/release/publish.sh --dry-run        # every check, no pushes
#
# Configure once (or export in your shell):
#   LESSSHEET_RELEASE_REPO=te-x/less-sheet        # releases live on the main repo
#   LESSSHEET_TAP_DIR=$HOME/Projects/homebrew-tap
#   LESSSHEET_SITE_URL=https://te-x.github.io/less-sheet/
#
# THIS SCRIPT DOES NOT BUILD THE APP. `tools/release/cut` does that on the Mac,
# which is the only machine with the Swift toolchain. This one assumes dist/
# arrived by rsync and CHECKS THAT IT DID — a stale dist/ is the quiet failure
# this split invites, and it would publish last release's binaries under this
# release's version.
#
# WHAT IT REFUSES TO DO, each because it has bitten this project or would:
#   * publish from a dirty tree, or without the tag `cut` made;
#   * publish artifacts whose bytes disagree with SHA256SUMS;
#   * skip the LOGGED-OUT check. A private asset 404s for everyone but you, and
#     you will be logged in when you look. That one mistake breaks Homebrew and
#     the curl one-liner at the same time.
set -uo pipefail

say()  { printf '\n== %s\n' "$1"; }
die()  { printf 'error: %s\n' "$1" >&2; exit 1; }
ask()  { printf '%s ' "$1" >&2; read -r REPLY </dev/tty; }

cd "$(git rev-parse --show-toplevel)" || die "not inside the repo"

DRY=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        *) die "unknown option '$a'" ;;
    esac
done

RELEASE_REPO="${LESSSHEET_RELEASE_REPO:-te-x/less-sheet}"
TAP_DIR="${LESSSHEET_TAP_DIR:-$HOME/Projects/homebrew-tap}"
# Written into the bundle so `flatpak install ./x.flatpak` can offer to add the remote
# that carries the GNOME runtime. Without it, a machine with no Flathub configured
# (stock Ubuntu) fails with "runtime org.gnome.Platform/x86_64/49 not found".
RUNTIME_REPO="${LESSSHEET_RUNTIME_REPO:-https://dl.flathub.org/repo/flathub.flatpakrepo}"
SITE_URL="${LESSSHEET_SITE_URL:-https://te-x.github.io/less-sheet/}"
FLATPAK_DIR="packaging/flatpak"

# ---------------------------------------------------------------- preflight --
command -v gh >/dev/null || die "gh not found (pacman -S github-cli)"
gh auth status >/dev/null 2>&1 || die "gh is not logged in — run: gh auth login"
git remote get-url origin >/dev/null 2>&1 \
    || die "no 'origin' remote. Clone this repository from GitHub (git clone), do not copy it."

VER="$(cat VERSION)"
TAG="v$VER"
BRANCH="$(git branch --show-current)"
BASE="https://github.com/$RELEASE_REPO/releases/download/$TAG"

[ -z "$(git status --porcelain)" ] || die "the working tree is dirty — this copy should be exactly what cut produced"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
    || die "no local tag $TAG. Run tools/release/cut $VER on the Mac, then re-transfer."
gh release view "$TAG" --repo "$RELEASE_REPO" >/dev/null 2>&1 \
    && die "release $TAG already exists in $RELEASE_REPO — a released version is immutable"

echo "less-sheet — publishing $TAG"
echo "  source        origin/$BRANCH"
echo "  release repo  $RELEASE_REPO"
echo "  tap           $TAP_DIR"

# ------------------------------------------------------------ dist is fresh --
# The whole point of this check: dist/ crosses machines by rsync, outside git,
# so nothing else can tell you it is last release's build.
say "checking dist/ arrived and matches its digests"
[ -f dist/SHA256SUMS ] || die "dist/SHA256SUMS missing — rsync dist/ from the Mac"
ARTIFACTS=()
while IFS= read -r f; do ARTIFACTS+=("$f"); done < <(ls dist/less-sheet-"$VER"-* 2>/dev/null || true)
[ "${#ARTIFACTS[@]}" -gt 0 ] \
    || die "no artifacts named for $VER in dist/ — the rsync is stale or never ran"
grep -q -- "-$VER-" dist/SHA256SUMS \
    || die "dist/SHA256SUMS does not mention $VER — it belongs to another build"
( cd dist && sha256sum -c --quiet SHA256SUMS ) \
    || die "an artifact's bytes disagree with SHA256SUMS — the transfer is corrupt or partial"
echo "  ${#ARTIFACTS[@]} artifacts, all digests verified"

ARTIFACTS+=(dist/SHA256SUMS)
for a in "${ARTIFACTS[@]}"; do printf '    %8s  %s\n' "$(du -h "$a" | cut -f1)" "$(basename "$a")"; done

# ------------------------------------------------------------------ confirm --
if [ "$DRY" = 1 ]; then
    say "--dry-run: every check passed, nothing was pushed"
    exit 0
fi

say "about to publish — this is the irreversible part"
echo "  push      $BRANCH + $TAG -> origin"
echo "  release   $TAG in $RELEASE_REPO (${#ARTIFACTS[@]} files)"
echo "  deploy    the frontpage, via the push (site/** triggers the workflow)"
ask "  type the version to confirm:"
[ "$REPLY" = "$VER" ] || die "confirmation did not match — nothing was published"

# ------------------------------------------------------------------- source --
say "pushing source + tag"
git push origin "$BRANCH" || die "push failed"
git push origin "$TAG"    || die "tag push failed"

# ------------------------------------------------------------------ release --
say "creating the release"
NOTES="dist/NOTES-$VER.md"
[ -f "$NOTES" ] || printf 'less-sheet %s\n' "$VER" > "$NOTES"
gh release create "$TAG" --repo "$RELEASE_REPO" \
   --title "less-sheet $VER" --notes-file "$NOTES" "${ARTIFACTS[@]}" \
   || die "gh release create failed"

# ------------------------------------------------------------------ flatpak --
# Built here because flatpak-builder does not run on macOS. It uses the BUNDLE
# manifest: a .flatpak cannot carry extra-data (see packaging/flatpak/README.md),
# so the payload is embedded. The manifest names the release URL of the tarball,
# but --extra-sources points flatpak-builder at the local dist/ copy first: same
# file, same digest, and the build does not register as a download of the
# asset (the release counts stay meaningful). It runs after the release exists
# so a fallback fetch, if the local copy were missing, would still succeed.
if command -v flatpak-builder >/dev/null; then
    say "building the Flatpak bundle"
    ARCH="$(uname -m)"
    BUNDLE="less-sheet-$VER-$ARCH.flatpak"
    DIST_ABS="$PWD/dist"
    ( cd "$FLATPAK_DIR" \
      && flatpak-builder --force-clean --repo=repo-bundle bundle-dir \
           --extra-sources="$DIST_ABS" com.lesssheet.LessSheet.Bundle.yaml \
      && flatpak build-bundle --runtime-repo="$RUNTIME_REPO" repo-bundle "$BUNDLE" com.lesssheet.LessSheet ) \
      || die "the Flatpak bundle failed to build"
    gh release upload "$TAG" --repo "$RELEASE_REPO" "$FLATPAK_DIR/$BUNDLE" \
      || die "uploading the bundle failed"
    ARTIFACTS+=("$FLATPAK_DIR/$BUNDLE")
    echo "  uploaded $BUNDLE"
else
    printf '\n  WARNING: flatpak-builder not found; no bundle was built.\n' >&2
    printf '  The page links one. Install it and re-run, or the Linux button 404s.\n' >&2
fi

# ---------------------------------------------------------------------- tap --
if [ -d "$TAP_DIR/Casks" ] && [ -f dist/less-sheet.rb ]; then
    say "updating the Homebrew tap"
    cp dist/less-sheet.rb "$TAP_DIR/Casks/less-sheet.rb"
    ( cd "$TAP_DIR" && git add Casks/less-sheet.rb \
      && TZ=UTC git commit -q -m "less-sheet $VER" && git push ) \
      || die "the tap did not update — brew still serves the previous version"
    echo "  tap now serves $VER"
else
    printf '\n  WARNING: no tap at %s, or dist/less-sheet.rb missing.\n' "$TAP_DIR" >&2
    printf '  brew will keep installing the previous version.\n' >&2
fi

# ------------------------------------------------------------------- verify --
say "verifying every asset is PUBLIC and complete"
# Through the UNAUTHENTICATED REST API on purpose, and never through the asset
# URLs: gh and a browser carry your credentials (a private asset looks perfect
# to you and 404s for everyone else), and GitHub counts every request on an
# asset URL as a download — a HEAD included — which would make the release's
# first "downloads" our own check. The API answers only for a public release
# and lists each asset with its size, which is compared to the file we uploaded.
LISTING="$(curl -sS "https://api.github.com/repos/$RELEASE_REPO/releases/tags/$TAG" 2>/dev/null || true)"
FAIL=0
for a in "${ARTIFACTS[@]}"; do
    name="$(basename "$a")"
    want="$(stat -c %s "$a" 2>/dev/null || stat -f %z "$a")"
    have="$(printf '%s' "$LISTING" | python3 -c '
import json, sys
name = sys.argv[1]
try:
    for asset in json.load(sys.stdin).get("assets", []):
        if asset["name"] == name:
            print(asset["size"]); break
except Exception:
    pass' "$name")"
    if [ "$have" = "$want" ]; then printf '  ok   %s (%s bytes)\n' "$name" "$want"
    else printf '  MISSING or wrong size: %s (uploaded %s, listed %s)\n' "$name" "$want" "${have:-none}"; FAIL=1; fi
done
[ "$FAIL" = 0 ] || die "the public release listing does not match dist/ — Homebrew and the curl install are broken until this is fixed"

say "waiting for the frontpage to deploy"
# The push triggers the workflow; Pages then lags it. Poll rather than guess.
OK=0
for _ in $(seq 1 20); do
    if curl -sL "$SITE_URL" | grep -q -- "$VER"; then OK=1; break; fi
    sleep 15
done
if [ "$OK" = 1 ]; then
    echo "  the live page names $VER"
else
    printf '  the page still does not mention %s after 5 minutes.\n' "$VER" >&2
    printf '  Check the Actions tab; the release itself is published and fine.\n' >&2
fi

say "published $TAG"
echo "  assets, tap and page are live. Install it somewhere you have not, and open a file."
