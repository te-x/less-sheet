#!/usr/bin/env bash
# Frontpage numbers, Linux: launch -> first data rows PAINTED, and resting memory.
#
#   tools/bench/launch_bench_linux.sh <fixture-dir> [runs]      # default 10 timed runs
#
# Drives the INSTALLED binary (LESSSHEET_GTK, default ~/.local/bin/less-sheet-gtk) in the
# CURRENT desktop session — run it from a terminal in that session, or over ssh with
# XDG_RUNTIME_DIR, WAYLAND_DISPLAY and DBUS_SESSION_BUS_ADDRESS exported (without the
# session bus libadwaita waits seconds for a portal that never answers, and that wait
# lands inside the number). `LESSSHEET_GTK_TIMING` makes the app print
# `[timing] first-rows-visible (main -> first frame): <ms>`, its own clock from process
# entry to the first frame with data rows. Interleaved runs after one warm-up round;
# median with min and max.
#
# Memory is `Pss_Anon` from /proc/<pid>/smaps_rollup at steady state (index finished),
# the analogue of the macOS physical footprint: private anonymous pages, excluding the
# clean file-backed mmap the OS can drop at will. Reported as CORE + UI, the core figure
# from tools/bench/coremem.c (LESSSHEET_COREMEM, default ./coremem-linux next to the
# fixtures) holding the same document with no window, sampled the same way. Max of 3.
set -u
dir="${1:?usage: launch_bench_linux.sh <fixture-dir> [runs]}"
runs="${2:-10}"
app="${LESSSHEET_GTK:-$HOME/.local/bin/less-sheet-gtk}"
coremem="${LESSSHEET_COREMEM:-$dir/coremem-linux}"
[ -x "$app" ] || { echo "no app at $app" >&2; exit 1; }
[ -x "$coremem" ] || { echo "no coremem at $coremem (cross-build tools/bench/coremem.c)" >&2; exit 1; }

fixtures=(c10-10KB.csv c10-10MB.csv c10-10GB.csv c2000-10MB.csv c2000-10GB.csv
          c10-10KB.csv.gz c10-10MB.csv.gz c10-10GB.csv.gz)
for f in "${fixtures[@]}"; do [ -f "$dir/$f" ] || { echo "missing fixture $dir/$f" >&2; exit 1; }; done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

stop() { kill "$1" 2>/dev/null; for _ in $(seq 1 40); do kill -0 "$1" 2>/dev/null || break; sleep 0.1; done; }

time_open() {
    local f="$1" log="$work/launch.log" ms="" pid
    : > "$log"
    LESSSHEET_GTK_TIMING=1 "$app" "$f" > /dev/null 2> "$log" &
    pid=$!
    for _ in $(seq 1 150); do
        ms="$(sed -n 's/^\[timing\] first-rows-visible (main -> first frame): \([0-9.]*\) ms$/\1/p' "$log" | head -1)"
        [ -n "$ms" ] && break
        sleep 0.1
    done
    stop "$pid"
    [ -n "$ms" ] && printf '%.0f\n' "$ms" || echo timeout
}

pss_anon_mib() { awk '/^Pss_Anon:/{printf "%.1f", $2/1024; exit}' "/proc/$1/smaps_rollup" 2>/dev/null || echo "?"; }
settle_seconds() { case "$1" in *10GB*) echo 45 ;; *) echo 8 ;; esac; }

app_mib() {
    local f="$1" best=0 pid v
    for _ in 1 2 3; do
        "$app" "$f" > /dev/null 2>&1 &
        pid=$!
        sleep "$(settle_seconds "$f")"
        v="$(pss_anon_mib "$pid")"
        stop "$pid"
        best="$(awk -v a="$best" -v b="$v" 'BEGIN{print (b>a)?b:a}')"
    done
    echo "$best"
}

core_mib() {
    local f="$1" best=0 pid v out="$work/coremem.out"
    for _ in 1 2 3; do
        : > "$out"
        "$coremem" "$f" > "$out" 2>&1 &
        pid=$!
        for _ in $(seq 1 1200); do grep -q '^READY' "$out" && break; sleep 0.1; done
        sleep 1
        v="$(pss_anon_mib "$pid")"
        stop "$pid"
        best="$(awk -v a="$best" -v b="$v" 'BEGIN{print (b>a)?b:a}')"
    done
    echo "$best"
}

median() { sort -n | awk '{a[NR]=$1} END{if(NR%2)print a[(NR+1)/2]; else printf "%.0f", (a[NR/2]+a[NR/2+1])/2}'; }

echo "less-sheet launch bench (Linux) — app $app — $(date -u +%Y-%m-%dT%H:%MZ) — $runs timed runs after 1 warm-up"
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
