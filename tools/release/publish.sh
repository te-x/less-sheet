#!/usr/bin/env bash
#
# Cut a release: pick a version, build everything, verify it, tag it, and
# publish the artifacts as a GitHub Release.
#
#   tools/release/publish.sh
#   tools/release/publish.sh --dry-run          # everything except the pushes
#   tools/release/publish.sh --version 0.2.0    # skip the prompt
#
# Configure once (or pass the flags every time):
#   LESSSHEET_SOURCE_REMOTE=origin                       # private repo, holds the code
#   LESSSHEET_RELEASE_REPO=<you>/less-sheet              # PUBLIC repo, holds the downloads
#
# WHY A TAG AND NOT A PUSH TO MASTER. Releases are deliberate acts. Building on
# every push publishes half-finished work and buries the real releases in noise;
# the runbook (docs/RELEASE.md §1) already says each release is a tag vX.Y.Z on
# the release commit. This script is that act, written down.
#
# WHAT IT REFUSES TO DO, and why each one has bitten this project or would:
#   * publish from a DIRTY tree — the artifacts would not correspond to the tag,
#     and nothing downstream could ever tell;
#   * publish without the gate passing — a green build is not a correct one here;
#   * reuse an existing tag — that silently changes what a version means;
#   * skip the LOGGED-OUT check on the published asset. A private release asset
#     404s for everyone who is not you, and you will be logged in when you look.
#     That single mistake breaks Homebrew and the curl one-liner at once.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

DRY=0
WANT_VERSION=""
SKIP_GATE=0
SOURCE_REMOTE="${LESSSHEET_SOURCE_REMOTE:-origin}"
RELEASE_REPO="${LESSSHEET_RELEASE_REPO:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)      DRY=1 ;;
        --version)      WANT_VERSION="${2:?--version needs a number}"; shift ;;
        --release-repo) RELEASE_REPO="${2:?--release-repo needs owner/name}"; shift ;;
        --source-remote) SOURCE_REMOTE="${2:?--source-remote needs a remote}"; shift ;;
        --skip-gate)    SKIP_GATE=1 ;;
        -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
ask()  { printf '%s ' "$1" >&2; read -r REPLY </dev/tty; }

# ---------------------------------------------------------------- preflight --
say "preflight"

command -v gh >/dev/null || die "gh CLI not found (brew install gh)"
gh auth status >/dev/null 2>&1 || die "gh is not logged in — run: gh auth login"

[ -n "$RELEASE_REPO" ] || die "set LESSSHEET_RELEASE_REPO=<owner>/<name> (the PUBLIC repo) or pass --release-repo"
# Cheapest and most likely first: a dirty tree is the everyday mistake, and
# reporting it before a missing-remote complaint tells you the thing you can
# actually act on.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    git status --short --untracked-files=no >&2
    die "the working tree is dirty. Artifacts built from it would not match the tag."
fi

git remote get-url "$SOURCE_REMOTE" >/dev/null 2>&1 \
    || die "no git remote named '$SOURCE_REMOTE' — add the private source repo first"

BRANCH="$(git branch --show-current)"
CURRENT="$(cat VERSION)"
echo "  repo branch     : $BRANCH"
echo "  source remote   : $SOURCE_REMOTE -> $(git remote get-url "$SOURCE_REMOTE")"
echo "  release repo    : $RELEASE_REPO (public)"
echo "  current version : $CURRENT"

# ------------------------------------------------------------------ version --
if [ -z "$WANT_VERSION" ]; then
    ask "  new version (blank to keep $CURRENT):"
    WANT_VERSION="${REPLY:-$CURRENT}"
fi
case "$WANT_VERSION" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) die "version must be MAJOR.MINOR.PATCH, got '$WANT_VERSION'" ;;
esac
TAG="v$WANT_VERSION"

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
    && die "tag $TAG already exists — a released version is immutable; pick a new number"
if gh release view "$TAG" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
    die "release $TAG already exists in $RELEASE_REPO"
fi

if [ "$WANT_VERSION" != "$CURRENT" ]; then
    say "bumping VERSION $CURRENT -> $WANT_VERSION"
    printf '%s\n' "$WANT_VERSION" > VERSION
    # ONE file changes. Everything else reads it: the GTK build via meson, the
    # macOS bundle via assemble-app.sh's substitution, the artifact names via
    # make_release. If this commit ever touches a second file carrying the
    # number, the single-source rule has been broken somewhere.
    git add VERSION
    git commit -q -m "release $WANT_VERSION"
    echo "  committed $(git rev-parse --short HEAD)"
fi

# --------------------------------------------------------------------- gate --
if [ "$SKIP_GATE" = 1 ]; then
    echo
    echo "  WARNING: --skip-gate given. Publishing code whose gate has not run." >&2
else
    say "gate (root: api integrity + backend + macOS + GTK)"
    bash .aidev/gate.sh || die "the gate failed — nothing was published"
fi

# -------------------------------------------------------------------- build --
say "building + verifying artifacts"
BASE="https://github.com/$RELEASE_REPO/releases/download/$TAG"
# make_release does not merely produce files: it unpacks each one and RUNS it —
# the macOS app must emit its real rows-are-visible marker, the Linux binary must
# start in a clean container that has only the declared runtime deps.
python3 tools/release/make_release --cask-base "$BASE"

ARTIFACTS=()
while IFS= read -r f; do ARTIFACTS+=("$f"); done < <(
    ls dist/less-sheet-"$WANT_VERSION"-* 2>/dev/null || true
)
[ "${#ARTIFACTS[@]}" -gt 0 ] || die "no artifacts named for $WANT_VERSION in dist/"
[ -f dist/SHA256SUMS ] || die "dist/SHA256SUMS missing"
ARTIFACTS+=(dist/SHA256SUMS)

echo
echo "  to publish as $TAG -> $RELEASE_REPO:"
for a in "${ARTIFACTS[@]}"; do printf '    %8s  %s\n' "$(du -h "$a" | cut -f1)" "$(basename "$a")"; done

# ------------------------------------------------------------------ confirm --
if [ "$DRY" = 1 ]; then
    say "--dry-run: stopping before anything is pushed"
    echo "  nothing was tagged, pushed or published."
    exit 0
fi

say "about to publish — this is the irreversible part"
echo "  tag           $TAG on $(git rev-parse --short HEAD)"
echo "  push branch   $BRANCH -> $SOURCE_REMOTE"
echo "  release       $RELEASE_REPO ($(printf '%s' "${#ARTIFACTS[@]}") files)"
ask "  type the version to confirm:"
[ "$REPLY" = "$WANT_VERSION" ] || die "confirmation did not match — nothing was published"

# ------------------------------------------------------------------ publish --
say "tagging + pushing source"
git tag -a "$TAG" -m "less-sheet $WANT_VERSION"
git push "$SOURCE_REMOTE" "$BRANCH"
git push "$SOURCE_REMOTE" "$TAG"

say "creating the release"
NOTES="dist/NOTES-$WANT_VERSION.md"
[ -f "$NOTES" ] || printf 'less-sheet %s\n' "$WANT_VERSION" > "$NOTES"
gh release create "$TAG" --repo "$RELEASE_REPO" \
   --title "less-sheet $WANT_VERSION" --notes-file "$NOTES" \
   "${ARTIFACTS[@]}"

# -------------------------------------------------------------------- verify --
say "verifying the published assets are PUBLIC"
# Logged out on purpose: `gh` and a browser session both carry your credentials,
# so a private asset looks fine to you and 404s for everybody else.
FAIL=0
for a in "${ARTIFACTS[@]}"; do
    url="$BASE/$(basename "$a")"
    code="$(curl -fsSLI -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo 000)"
    if [ "$code" = "200" ]; then
        printf '  200  %s\n' "$(basename "$a")"
    else
        printf '  %-4s %s   <-- NOT PUBLIC\n' "$code" "$(basename "$a")"
        FAIL=1
    fi
done
[ "$FAIL" = 0 ] || die "some assets are not publicly reachable — Homebrew and the curl install are broken until this is fixed"

# ---------------------------------------------------------------------- next --
say "published $TAG"
cat <<EOF
  Two things this script deliberately does NOT do, because both change what
  other people see and neither is recoverable by re-running:

    1. Update the Homebrew tap. dist/less-sheet.rb is written with this
       release's real sha256 — copy it into your homebrew-tap repo and push.
    2. Deploy the frontpage. See docs/RELEASE.md §7.4: it substitutes the
       download URLs from this tag and refuses to publish with a placeholder
       left in.
EOF
