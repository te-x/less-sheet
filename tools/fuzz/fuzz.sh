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

# The ONE definition of "the instrumented binary": the lsfuzz build CARRYING THE
# FUZZER RUNTIME. Presence/absence of the `-ffuzz` runtime symbols, never
# recency and never a ranking — see ARTIFACT IDENTITY below for the three wrong
# reports that guessing produced. Two callers share it: the campaign watchdog
# (to learn when fuzzing could first have begun) and the coverage report (to
# name the binary it decodes), so the two can never disagree about which build
# this campaign is talking about. Prints one path per line, nothing if none.
#
# `grep -c`, never `grep -q`, and the `|| true` is load-bearing. This script
# runs under `set -o pipefail` (line 40). `grep -q` exits the INSTANT it
# matches, closing the pipe while `nm` is still writing megabytes of symbols;
# `nm` then dies of SIGPIPE (141), pipefail adopts that as the pipeline's
# status, and the `if` reads a successful match as a FAILURE. Deterministic on
# a binary this size, not a race — which is why the coverage report was not
# merely broken but STRUCTURALLY IMPOSSIBLE: it reported "found 0 instrumented
# binaries" while the correct binary sat in the cache carrying 44 of them.
# `grep -c` drains its input, so nothing gets SIGPIPEd; it exits 1 on zero
# matches, which `|| true` absorbs so `set -e` does not kill the run.
instrumented_binaries() {
  local cand syms
  for cand in $(find .zig-cache/o -name lsfuzz -type f 2>/dev/null); do
    syms=$(nm "$cand" 2>/dev/null | grep -c "__sanitizer_cov\|fuzzer" || true)
    if [ "${syms:-0}" -gt 0 ]; then
      printf '%s\n' "$cand"
    fi
  done
}

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
log="campaign/campaign-$(uname -s | tr '[:upper:]' '[:lower:]')-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$log") 2>&1

echo "=== less-sheet fuzz campaign (security-hardening wave (c)) ==="
echo "date        : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "platform    : $(uname -sm)"
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
echo "log         : tools/fuzz/$log"
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
  # Also drop the COMPILED cache, so exactly one instrumented lsfuzz exists
  # afterwards and the ARTIFACT IDENTITY assertions below hold by construction.
  # Deleting build outputs while leaving their manifests behind poisons the cache
  # ("failed to spawn ...: FileNotFound"), so o/ and h/ go together.
  echo "    + .zig-cache/o, .zig-cache/h (one instrumented binary, deterministically)"
  rm -rf .zig-cache/f .zig-cache/v .zig-cache/o .zig-cache/h
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
# Note: the campaign below re-runs the harness replay itself (the build runner
# only discovers fuzz tests from a run step that actually executed), so a corpus
# that cannot replay clean can never start a campaign either. This step uses the
# `test` step, which ALSO runs both diff oracles' deterministic sweeps; the
# campaign deliberately does not (see ARTIFACT IDENTITY).
set +e
zig build test
replay_status=$?
set -e
echo "replay exit status: $replay_status"
echo

echo "--- campaign ---"
# `--fuzz` recompiles the test binary with -ffuzz into .zig-cache/o/<hash>/lsfuzz,
# and covreport must resolve PCs against THAT binary — a different build has a
# different PC table. It is identified below by an exact predicate, not by date.
marker="$(mktemp)"
# A fresh --seed each run: `zig build --fuzz=N` only discovers fuzz tests from a
# run step that actually EXECUTED, and the run step is cacheable, so an identical
# argv would cache-hit and report "no fuzz tests found".
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
  zig build --fuzz="$iters" --seed "$(( RANDOM * 65536 + RANDOM ))" &
  fuzz_pid=$!
  set +m
  trap 'kill -TERM -'"$fuzz_pid"' 2>/dev/null || true' EXIT INT TERM
  deadline=$(( $(date +%s) + minutes * 60 ))
  budget_hit=0
  # WHEN the instrumented binary appeared, i.e. when fuzzing could first have
  # started. `--fuzz` COMPILES before it fuzzes, and that compile is inside the
  # budget: a campaign whose budget expires mid-build never executes a single
  # iteration, yet is otherwise indistinguishable from a clean one — same
  # "stopped by the WALL-CLOCK BUDGET" line, same forced status 0, no crash.
  # That is how a 10-minute run reported a clean campaign having fuzzed for
  # zero seconds (2026-08-05, 19:19:13). Time is not evidence; only the fuzzer
  # having actually been on CPU is, so the transition is recorded here.
  build_done_at=""
  while kill -0 "$fuzz_pid" 2>/dev/null; do
    if [ -z "$build_done_at" ] && [ -n "$(instrumented_binaries)" ]; then
      build_done_at=$(date +%s)
    fi
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
    if [ -z "$build_done_at" ]; then
      echo
      echo "campaign NEVER FUZZED: the ${minutes}-minute budget expired while the"
      echo "instrumented binary was STILL BUILDING, so zero iterations ran. This is"
      echo "NOT a clean campaign — it is no campaign. Re-run with a longer --minutes"
      echo "(the -ffuzz build alone costs ~1 min from a cold cache), or warm the"
      echo "build first so the whole budget is spent fuzzing."
      status=1
    else
      echo "  instrumented build ready $(( build_done_at - (deadline - minutes * 60) ))s in;"
      echo "  ACTUALLY FUZZED for ~$(( deadline - build_done_at ))s of the ${minutes}-minute budget"
      status=0
    fi
  fi
else
  zig build --fuzz="$iters" --seed "$(( RANDOM * 65536 + RANDOM ))"
  status=$?
fi
set -e
echo "campaign exit status: $status"
echo

echo "--- coverage report ---"
set +e
zig build covreport
rm -f "$marker"

# ---------------------------------------------------------------------------
# ARTIFACT IDENTITY — NEVER BY RECENCY, NEVER BY RANKING.
#
# "Take the newest/best candidate" produced three confidently WRONG coverage
# reports in this one script in one day, each of which looked like a real result:
#
#   1. newest BINARY by timestamp -> a completed 22-minute campaign reported
#      `window NOT ENTERED 0/138` when the truth was 215/376. A wrong-binary
#      report can FAIL the AC-c1 gate on a perfectly healthy run.
#   2. highest `attributed` BINARY -> better, still a guess.
#   3. most-runs MAP -> picked `lsdiff`, whose tiny in-memory iterations reach
#      67,989,382 runs against the harness's 408,316, and reported ALL SEVEN
#      hotspot modules NOT ENTERED at 0.31% coverage.
#
# So identity is now established by EXACT PREDICATES with an asserted cardinality,
# and anything else is a hard failure. A campaign that refuses to report is
# recoverable; a campaign that reports another target's numbers under this
# heading is not.
#
#   MAP: the campaign phase runs `zig build --fuzz` — the DEFAULT step, which
#        depends on the harness run step ALONE (build.zig:82). The diff oracles
#        hang off `test`/`diff` (build.zig:108,128) and are deliberately not in
#        the campaign, so the harness writes EXACTLY ONE map. Any other count
#        means the assumption broke: stop.
#   BIN: the instrumented build is the one CARRYING THE FUZZER RUNTIME. That is
#        presence/absence, not a score: 44 `__sanitizer_cov`/`fuzzer` symbols in
#        the `-ffuzz` rebuild, 0 in the plain test binary.
# ---------------------------------------------------------------------------
shopt -s nullglob
maps=( .zig-cache/v/* )
shopt -u nullglob
if [ "${#maps[@]}" -ne 1 ]; then
  echo "coverage report UNAVAILABLE: expected EXACTLY ONE coverage map under"
  echo ".zig-cache/v (the campaign runs the harness alone), found ${#maps[@]}:"
  # `${a[@]+"${a[@]}"}`, not `"${a[@]}"`: this is bash 3.2 (what macOS ships and
  # what `env bash` finds here), where expanding an EMPTY array under `set -u`
  # is itself an "unbound variable" error. Listing the offenders is the failure
  # path, so the naive form crashed exactly when it was needed — the count-is-0
  # case — and buried the real message under a bash error.
  for m in ${maps[@]+"${maps[@]}"}; do echo "    $m"; done
  echo "Refusing to guess which map belongs to this campaign — see ARTIFACT IDENTITY"
  echo "in this script. Re-run with --fresh to start from a known-empty state."
  exit 1
fi
cov="${maps[0]}"

instrumented=()
while IFS= read -r cand; do
  [ -n "$cand" ] && instrumented+=( "$cand" )
done <<EOF
$(instrumented_binaries)
EOF
if [ "${#instrumented[@]}" -ne 1 ]; then
  echo "coverage report UNAVAILABLE: expected EXACTLY ONE instrumented lsfuzz"
  echo "binary in .zig-cache/o, found ${#instrumented[@]}:"
  for b in ${instrumented[@]+"${instrumented[@]}"}; do echo "    $b"; done
  echo "Stale -ffuzz builds from an earlier harness version cannot be told apart"
  echo "from this campaign's without guessing. Re-run with --fresh (which clears"
  echo "them) — see ARTIFACT IDENTITY in this script."
  exit 1
fi
bin="${instrumented[0]}"

echo "instrumented binary : $bin"
echo "                      (sole build carrying the fuzzer runtime)"
echo "coverage map        : $cov"
echo "                      (sole map written by the harness-only campaign step)"
echo
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
