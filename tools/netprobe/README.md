# netprobe — Linux network / TLS runtime check

Human-runtime verification for **ARCH-backend-linux-portability, acceptance
criterion H3**: on a real Linux host, a real HTTPS CSV / `.csv.gz` open via the
`ls_open_url_*` ABI succeeds — the system CA / cert store loads, `std.crypto.tls`
verifies against a real range-serving host, and the first rows are returned.

This is **not gate-verifiable**: real HTTP is a fake-seam-only path in the gate
on every OS, and a cross-compiled binary is not executable on the build host. The
gate asserts only that the network Zig code (`net.zig`) **cross-compiles** into
the static library (G1/G2); whether TLS actually verifies on Linux is a runtime
property, checked here on real hardware.

## Files
- `netprobe.c` — thin C harness over the frozen C ABI (`api/lesssheet.h`): starts
  an `ls_open_url_start` job, polls to a terminal state, and prints the first rows
  (or the `ls_net_status` error + HTTP status on failure).
- `netprobe_on` — cross-compiles the musl-static backend + links the harness, then
  scp's and runs the single static binary on a remote Linux host. Same
  cross-compile-and-ship mechanism as `tools/bench/bench_lesssheet_on`.

## Usage
Requires zig 0.16.0 on THIS machine; the remote needs only a shell.

```
./netprobe_on user@host https://host/path/data.csv [max_rows] [max_cols]
./netprobe_on user@arm-box https://example.org/big.csv.gz 20
```

A run that reaches `[netprobe] DONE` and prints rows satisfies H3 for that host's
architecture (verify on both aarch64 and x86_64 where reachable; at minimum one).
`FAILED error=UNREACHABLE (DNS/TCP/TLS handshake)` on a host that a normal client
(e.g. `curl`) can reach points at the Linux trust-store path.

## Local (macOS) smoke test
The macOS net path works today, so the harness can be built and run natively
before any Linux port — this checks the C/ABI usage, not the Linux trust store:

```
cd backend && zig build                       # produces zig-out/lib/liblesssheet.a
zig cc -I api tools/netprobe/netprobe.c \
    backend/zig-out/lib/liblesssheet.a -o /tmp/netprobe
/tmp/netprobe https://host/path/data.csv
```
