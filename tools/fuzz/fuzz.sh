#!/usr/bin/env bash
# tools/fuzz/fuzz.sh — run a fuzz campaign and produce the AC-c1 coverage report.
#
#   bash tools/fuzz/fuzz.sh [iterations-per-target] [--minutes M] [--fresh]
#                           [--regen <csvgen-out>]
#
# Defaults to a short smoke campaign (20000 iterations per target). This ONE
# command builds the harness, runs the campaign, locates the instrumented binary,
# decodes the coverage map, prints the per-module report, and appends everything
# to a campaign log under tools/fuzz/campaign/.
#
# BUDGET UNIT — READ THIS BEFORE COMPARING TWO CAMPAIGN LOGS.
# An iteration is NOT a constant amount of work, and it is not comparable across
# harness versions. The csv target draws synthesized document shapes at a
# measured, capped share (see `oneCsv`): most iterations handle a few KiB, while
# the `deep` shape writes and scans >8 MiB to force the off-main filtered
# navigation. Measured on an M-series mac: an ordinary iteration is ~1-5 ms, a
# `deep` one ~82 ms.
#
# So there are two budget units and the log always states which one was used:
#   * iterations (the default, and what wave (c) recorded) — reproducible, but
#     only comparable between runs of the SAME harness version.
#   * `--minutes M` wall clock — the right unit for comparing two harness
#     versions, because it holds the machine and the budget fixed while the work
#     per iteration changes. AC-c2 explicitly permits a time/plateau criterion.
# Either way the log prints "budget" and the per-shape mix, so a later reader
# cannot silently compare 200k of one harness against 200k of another.
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
minutes=""
fresh=0
regen=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fresh) fresh=1 ;;
    --minutes) minutes="${2:?--minutes needs a number}"; shift ;;
    --regen) regen="${2:?--regen needs an output dir}"; shift ;;
    --*) echo "unknown flag: $1" >&2; exit 64 ;;
    *) iters="$1" ;;
  esac
  shift
done
# Under a time budget the iteration cap must not be what stops the run.
[ -n "$minutes" ] && iters=100000000

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
if [ -n "$minutes" ]; then
  echo "budget      : WALL CLOCK, $minutes minute(s) (iteration cap lifted)"
  echo "              comparable across harness versions; iteration counts are NOT"
else
  echo "budget      : ITERATIONS, $iters per fuzz target"
  echo "              comparable only between runs of the SAME harness version"
fi
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

echo "--- document shapes (csv target) — why iterations are not a constant unit ---"
grep -nE '^const (deep_shape|many_rows_shape_min|base_rows) = ' harness.zig || true
echo "  ordinary  <=1 MiB (rep amplifier)          ~1-5 ms/iteration"
echo "  many_rows >2048 rows, ~166 KiB             8/64 of draws, 15/219 csv seeds"
echo "  deep      >8 MiB, forces off-main nav      1/64 of draws,  2/219 csv seeds, ~82 ms"
echo "  Sentinels are NON-ZERO on purpose: 93 of the 219 csv seeds carry w0 == 0,"
echo "  so a zero-valued shape selector would make the >8 MiB shape the default."
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
if [ -n "$minutes" ]; then
  # Wall-clock budget. `zig build` runs the test binary as a CHILD, so the
  # watchdog has to signal the whole process GROUP or the fuzzer outlives the
  # build runner: `set -m` gives the job its own group (pgid == the job's pid),
  # which is what `kill -TERM -$pid` then addresses.
  #
  # The coverage map survives the kill by construction — the fuzzer mmaps it and
  # updates it live, so it is already on disk when the signal lands.
  #
  # A watchdog kill must NOT read as a finding, and a finding must not read as a
  # budget expiry, so the watchdog leaves a flag file and only its absence lets a
  # non-zero status count as a real failure.
  # `set -m` puts the campaign in its OWN process group so the deadline can signal
  # the whole tree (`kill -- -$pid`) rather than just the build runner, which would
  # leave the actual fuzzer running.
  #
  # That same isolation is a hazard, so the deadline is enforced by THIS shell in a
  # polling loop plus an EXIT trap, not by a detached `sleep` subshell. A separate
  # watchdog dies with this shell while the campaign — in its own group — survives
  # as an orphan running `--fuzz=100000000`, i.e. forever, with nothing left to
  # stop it. That happened here once. The trap guarantees the campaign cannot
  # outlive its supervisor however this script ends.
  set -m
  zig build test --fuzz="$iters" --seed "$(( RANDOM * 65536 + RANDOM ))" &
  fuzz_pid=$!
  set +m
  trap 'kill -TERM -'"$fuzz_pid"' 2>/dev/null || true' EXIT INT TERM
  deadline=$(( $(date +%s) + minutes * 60 ))
  budget_hit=0
  while kill -0 "$fuzz_pid" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      budget_hit=1
      kill -TERM -"$fuzz_pid" 2>/dev/null || true
      break
    fi
    sleep 5
  done
  wait "$fuzz_pid"; status=$?
  trap - EXIT INT TERM
  # A budget expiry must never read as a finding, nor a finding as an expiry.
  if [ "$budget_hit" = 1 ]; then
    echo "campaign stopped by the $minutes-minute WALL-CLOCK BUDGET (raw status $status)"
    status=0
  fi
else
  zig build test --fuzz="$iters" --seed "$(( RANDOM * 65536 + RANDOM ))"
  status=$?
fi
set -e
echo "campaign exit status: $status"
echo

echo "--- coverage report ---"
set +e
zig build covreport
rm -f "$marker"
cov="$(find .zig-cache/v -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1)"

# Pick the instrumented binary whose PC table actually MATCHES the coverage map,
# by asking covreport which candidate ATTRIBUTES THE MOST PCs to project files.
#
# Timestamp heuristics are not enough and fail silently, which is the worst way
# to fail: the cache can hold several `lsfuzz` builds (a `-Donly` triage build, a
# previous campaign, the plain non-instrumented test binary), `find -newer` can
# match more than one, and handing covreport the wrong one resolves almost
# nothing — every module then reads as a near-zero count, which looks like a
# catastrophic coverage collapse instead of the binary mismatch it is. This bit
# a real run in this tree: a 22-minute campaign reported `window NOT ENTERED
# 0/138` when the true figure was 215/376.
#
# `unresolved` is NOT a usable discriminator — 316 vs 323 between a matching and a
# non-matching binary on the same map, i.e. noise. The count of PCs ATTRIBUTED to
# project files is: 5901 vs 3492 vs 1605 on that same map, a margin no near-miss
# closes. So maximize `attributed`, and log it as the audit trail.
bin=""
best_attr=-1
if [ -n "$cov" ]; then
  for cand in $(find .zig-cache/o -name lsfuzz -type f 2>/dev/null); do
    a="$(./zig-out/bin/covreport "$cand" "$cov" 2>&1 | awk '/^attributed /{print $3; exit}')"
    case "$a" in ''|*[!0-9]*) continue ;; esac
    if [ "$a" -gt "$best_attr" ]; then
      best_attr="$a"
      bin="$cand"
    fi
  done
fi
echo "binary match        : attributed=${best_attr} project PCs (best of the cached lsfuzz builds)"
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
