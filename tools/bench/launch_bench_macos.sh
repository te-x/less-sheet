#!/usr/bin/env bash
# Frontpage numbers, macOS: launch -> first data row PAINTED, and resting memory.
#
#   tools/bench/launch_bench_macos.sh <fixture-dir> [runs]      # default 10 timed runs
#
# Drives the INSTALLED app bundle (LESSSHEET_APP, default /Applications/less-sheet.app)
# the way a user launches it, and reads the app's own clock: `LESSSHEET_LAUNCH_PHASES`
# makes it print `lesssheet.phase.first_row_pixels=<ms since process start>` when the
# first real data row is drawn. That is the number the page calls "open". Runs are
# interleaved across fixtures, after one untimed warm-up round; the median is reported
# with the min and max.
#
# Memory is sampled at steady state with the index scan finished — never at first
# paint, which measures page-cache warmth — as `Physical footprint` from `vmmap`, the
# metric Activity Monitor calls Memory. Reported as CORE + UI: the core figure comes
# from tools/bench/coremem.c holding the same document with no window, sampled with
# the same tool, so the two can be subtracted. The maximum of three runs is kept: the
# footprint is bimodal with the display's backing scale (1x vs 2x), and Retina users
# see the 2x figure.
set -u
dir="${1:?usage: launch_bench_macos.sh <fixture-dir> [runs]}"
runs="${2:-10}"
app="${LESSSHEET_APP:-/Applications/less-sheet.app}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
bin="$app/Contents/MacOS/LessSheet"
[ -x "$bin" ] || { echo "no app at $app" >&2; exit 1; }

fixtures=(c10-10KB.csv c10-10MB.csv c10-10GB.csv c2000-10MB.csv c2000-10GB.csv
          c10-10KB.csv.gz c10-10MB.csv.gz c10-10GB.csv.gz)
for f in "${fixtures[@]}"; do [ -f "$dir/$f" ] || { echo "missing fixture $dir/$f" >&2; exit 1; }; done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
( cd "$repo/backend" && zig build -Doptimize=ReleaseSafe ) || exit 1
cc -O2 -I "$repo/api" "$repo/tools/bench/coremem.c" "$repo/backend/zig-out/lib/liblesssheet.a" -o "$work/coremem" || exit 1

kill_app() {  # the newest instance of the bundle's executable
    local pid; pid="$(pgrep -n -f "$bin" || true)"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    for _ in $(seq 1 40); do pgrep -f "$bin" >/dev/null || break; sleep 0.1; done
}

# One launch; prints the first-pixels millisecond value or "timeout".
time_open() {
    local f="$1" log="$work/launch.log" ms=""
    : > "$log"
    open -n --stderr "$log" --env LESSSHEET_LAUNCH_PHASES=1 -a "$app" "$f"
    for _ in $(seq 1 150); do
        ms="$(sed -n 's/^lesssheet\.phase\.first_row_pixels=\([0-9]*\)$/\1/p' "$log" | head -1)"
        [ -n "$ms" ] && break
        sleep 0.1
    done
    kill_app
    echo "${ms:-timeout}"
}

footprint_mib() {  # vmmap "Physical footprint" of a pid, in MiB
    local v; v="$(vmmap --summary "$1" 2>/dev/null | awk '/^Physical footprint:/{print $3; exit}')"
    case "$v" in
        *G) awk -v x="${v%G}" 'BEGIN{printf "%.1f", x*1024}' ;;
        *M) awk -v x="${v%M}" 'BEGIN{printf "%.1f", x}' ;;
        *K) awk -v x="${v%K}" 'BEGIN{printf "%.1f", x/1024}' ;;
        *) echo "?" ;;
    esac
}

settle_seconds() { case "$1" in *10GB*) echo 45 ;; *) echo 8 ;; esac; }

# The app's resting footprint with the document open, index finished (max of 3).
app_mib() {
    local f="$1" best=0 pid v
    for _ in 1 2 3; do
        open -n -a "$app" "$f"; sleep 1
        pid="$(pgrep -n -f "$bin")"
        sleep "$(settle_seconds "$f")"
        v="$(footprint_mib "$pid")"
        kill_app
        best="$(awk -v a="$best" -v b="$v" 'BEGIN{print (b>a)?b:a}')"
    done
    echo "$best"
}

# The core alone holding the same document, same sampler (max of 3).
core_mib() {
    local f="$1" best=0 pid v out="$work/coremem.out"
    for _ in 1 2 3; do
        : > "$out"
        "$work/coremem" "$f" > "$out" 2>&1 &
        pid=$!
        for _ in $(seq 1 1200); do grep -q '^READY' "$out" && break; sleep 0.1; done
        sleep 1
        v="$(footprint_mib "$pid")"
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
        best="$(awk -v a="$best" -v b="$v" 'BEGIN{print (b>a)?b:a}')"
    done
    echo "$best"
}

median() { sort -n | awk '{a[NR]=$1} END{if(NR%2)print a[(NR+1)/2]; else printf "%.0f", (a[NR/2]+a[NR/2+1])/2}'; }

echo "less-sheet launch bench (macOS) — app $app — $(date -u +%Y-%m-%dT%H:%MZ) — $runs timed runs after 1 warm-up"
echo "warm-up..."
for f in "${fixtures[@]}"; do time_open "$dir/$f" >/dev/null; done
# one samples file per fixture: macOS ships bash 3.2, which has no associative arrays
for r in $(seq 1 "$runs"); do
    for f in "${fixtures[@]}"; do
        ms="$(time_open "$dir/$f")"
        echo "$ms" >> "$work/samples.$f"
    done
    echo "  round $r done"
done
printf '\n%-18s %8s %14s   %8s %8s %8s\n' fixture open_ms "min-max" core_MiB app_MiB ui_MiB
for f in "${fixtures[@]}"; do
    vals="$(grep -E '^[0-9]+$' "$work/samples.$f")"
    med="$(median <<<"$vals")"; mn="$(sort -n <<<"$vals" | head -1)"; mx="$(sort -n <<<"$vals" | tail -1)"
    core="$(core_mib "$dir/$f")"; total="$(app_mib "$dir/$f")"
    ui="$(awk -v t="$total" -v c="$core" 'BEGIN{printf "%.1f", t-c}')"
    printf '%-18s %8s %14s   %8s %8s %8s\n' "$f" "$med" "$mn-$mx" "$core" "$total" "$ui"
    echo "    samples:$(tr '\n' ' ' <<<"$vals")" >&2
done
