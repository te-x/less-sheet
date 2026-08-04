#!/usr/bin/env bash
# tools/fuzz/fuzz.sh — run a fuzz campaign and produce the AC-c1 coverage report.
#
#   bash tools/fuzz/fuzz.sh [iterations-per-target] [--fresh] [--regen <csvgen-out>]
#
# Defaults to a short smoke campaign (20000 iterations per target). This ONE
# command builds the harness, runs the campaign, locates the instrumented binary,
# decodes the coverage map, prints the per-module report, and appends everything
# to a campaign log under tools/fuzz/campaign/.
#
# Exit status: 0 = campaign clean AND every AC-c1 hotspot module entered.
#              non-zero = a crash/leak/abort, or a module never entered.
#
# `--fresh` wipes the fuzzer's accumulated corpus + coverage state
# (.zig-cache/f, .zig-cache/v) so the run starts from the committed seeds only —
# use it for a reproducible from-scratch campaign; omit it to CONTINUE a campaign
# (Zig accumulates both the corpus and the coverage bitmap across runs).
#
# `--regen <dir>` regenerates the seed packs first: it runs tools/csvgen into
# <dir> (with --gzip) and rebuilds all four packs. Only needed when the csvgen
# catalog changed — the packs are committed.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
cd "$here"

iters=20000
fresh=0
regen=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fresh) fresh=1 ;;
    --regen) regen="${2:?--regen needs an output dir}"; shift ;;
    --*) echo "unknown flag: $1" >&2; exit 64 ;;
    *) iters="$1" ;;
  esac
  shift
done

[ "$(zig version)" = "0.16.0" ] || { echo "zig 0.16.0 required, found $(zig version)" >&2; exit 1; }

mkdir -p campaign
log="campaign/campaign-$(hostname -s)-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$log") 2>&1

echo "=== less-sheet fuzz campaign (security-hardening wave (c)) ==="
echo "date        : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "host        : $(hostname -s) $(uname -sm)"
echo "zig         : $(zig version)"
echo "repo tip    : $(git -C "$repo" rev-parse --short HEAD) ($(git -C "$repo" rev-parse --abbrev-ref HEAD))"
echo "tree        : $(if [ -z "$(git -C "$repo" status --porcelain)" ]; then echo clean; else echo DIRTY; fi)"
echo "iterations  : $iters per fuzz target"
echo "mode        : ReleaseSafe (the shipped mode — a safety panic counts as a crash)"
echo "log         : $here/$log"
echo

if [ -n "$regen" ]; then
  echo "--- regenerating the seed corpus ---"
  rm -rf "$regen"
  python3 "$repo/tools/csvgen/gen.py" --all --gzip --seed 1337 --size 64KB --out "$regen" >/dev/null
  zig build seedgen
  ./zig-out/bin/seedgen pack seeds \
    --csv $(find "$regen" -name '*.csv' | sort) \
    --gz  $(find "$regen" -name '*.csv.gz' | sort)
  echo
fi

if [ "$fresh" = 1 ]; then
  echo "--- wiping accumulated fuzzer state (.zig-cache/f, .zig-cache/v) ---"
  rm -rf .zig-cache/f .zig-cache/v
fi

echo "--- quarantines in force ---"
grep -nE '^const quarantine_[a-z0-9_]+ = (true|false);' harness.zig || echo "  (none declared)"
echo

echo "--- corpus ---"
for p in seeds/*.pack; do
  printf '  %-22s %8d bytes\n' "$(basename "$p")" "$(wc -c <"$p")"
done
echo

echo "--- seed replay (deterministic, every committed entry once) ---"
# Note: `zig build test --fuzz=N` below re-runs this replay itself (the build
# runner only discovers fuzz tests from a run step that actually executed), so a
# corpus that cannot replay clean can never start a campaign either.
set +e
zig build test
replay_status=$?
set -e
echo "replay exit status: $replay_status"
echo

echo "--- campaign ---"
# A marker file dates the fuzz-mode rebuild: `--fuzz` recompiles the test binary
# with -ffuzz into .zig-cache/o/<hash>/lsfuzz, and covreport must resolve PCs
# against THAT binary (a different build has a different PC table).
marker="$(mktemp)"
# A fresh --seed each run: `zig build test --fuzz=N` only discovers fuzz tests
# from a run step that actually EXECUTED, and the test run step is cacheable, so
# an identical argv would cache-hit and report "no fuzz tests found".
# `set -e` must NOT abort here: a campaign that FINDS something exits non-zero,
# and that is exactly when the coverage report and the triage hint below matter
# most. Capture the status and keep going.
set +e
zig build test --fuzz="$iters" --seed "$(( RANDOM * 65536 + RANDOM ))"
status=$?
set -e
echo "campaign exit status: $status"
echo

echo "--- coverage report ---"
set +e
zig build covreport
bin="$(find .zig-cache/o -name lsfuzz -type f -newer "$marker" -print 2>/dev/null | head -1)"
rm -f "$marker"
if [ -z "$bin" ]; then
  # Nothing was rebuilt this run (cached fuzz-mode binary): fall back to the
  # newest one, which is still the binary whose PC table the coverage file keys.
  bin="$(find .zig-cache/o -name lsfuzz -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1)"
fi
cov="$(find .zig-cache/v -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1)"
echo "instrumented binary : ${bin:-<not found>}"
echo "coverage map        : ${cov:-<not found>}"
echo
if [ -z "$bin" ] || [ -z "$cov" ]; then
  echo "coverage report UNAVAILABLE (missing binary or coverage map)"
  exit 1
fi
./zig-out/bin/covreport "$bin" "$cov"
cov_status=$?
set -e

echo
echo "--- triage (AC-c2) ---"
if [ -f .zig-cache/f/crash ]; then
  echo "A CRASHING INPUT WAS SAVED: .zig-cache/f/crash ($(wc -c <.zig-cache/f/crash) bytes)"
  echo "It is a Smith replay blob for the target that crashed. To make it a"
  echo "permanent regression seed (and a deterministic replay case):"
  echo "    ./zig-out/bin/seedgen append seeds/<target>.pack .zig-cache/f/crash"
  echo "    zig build test        # replays it; must be clean after the fix"
else
  echo "no crashing input saved"
fi

exit $(( replay_status != 0 ? replay_status : (status != 0 ? status : cov_status) ))
