# Contract Change Request — security-hardening (sec_w2b2) / ARCH AC-e1 connect deadline + AC-e2 "refused" wording

(The previous CR — sec_w2b, the (d)/(f) frozen-test contradictions — was APPROVED and is
recorded in full at `.aidev/DECISION-2.md`. This supersedes the file contents; it does not
reopen anything adjudicated there.)

Signed:  [x] implementer   [ ] reviewer
(both required; the reviewer's signature also certifies the evidence below was independently re-checked)

## Grounds (tick at least one)
- [x] A. Infeasible within the current contract
- [ ] B. Substantial, quantified improvement

## Summary

Two ARCH statements about the (e) real network transport claim enforcement the code cannot
deliver through `std.http.Client` in Zig 0.16.0. Round 1 shipped both as written; the round-1
reviewer proved both wrong against the installed std source, and I re-verified both
independently. Neither is a coding defect that more effort fixes — both are false premises
about the std API the signed amendment assumed. Per the standing bar I have removed the
inert knob rather than leave a named control that reads as enforced and is not, and I am
asking the architect to correct the two ARCH statements.

**No frozen test asserts either behavior** (`grep -n "connect_timeout\|timeout" tests/`,
`contracts/`: the only timeout coverage is the hermetic FAKE taxonomy `NetFault.timeout ->
LS_NET_ERROR_TIMEOUT`, which is unaffected and still GREEN). So this needs no test change —
only ARCH wording. 273/273 tests pass with the changes below.

---

## Item 1 — AC-e1: there is NO connect deadline available (infeasible)

**ARCH/AC-e1 promises a connect deadline on the real transport. It cannot be delivered.**

`std.http.Client.ConnectTcpOptions.timeout` is **declared and never read**:

```
$ grep -n "timeout" /opt/homebrew/opt/zig/lib/zig/std/http/Client.zig
1442:    timeout: Io.Timeout = .none,
```

One occurrence in the entire file — the field declaration. `connectTcpOptions` (Client.zig:1445)
ignores it and calls `host.connect(io, port, .{ .mode = .stream })`, a literal with no
`.timeout`. It compiles, it reads as wired, and it does nothing: a non-responding host still
hangs the fetch thread indefinitely, which is precisely the scenario AC-e1 exists for.

### Attempts (>=2), each with the specific reason it failed
1. **`Client.connectTcpOptions(.{ … .timeout = … })`** (what round 1 shipped). Fails: the
   field is never read (evidence above), so the deadline is inert. Worse, reaching it required
   dialing *before* `client.request(...)` and passing `.connection`, which **skipped the TLS
   prelude that populates `client.now`** (Client.zig:1705-1723, the only assignment at :1721,
   running before `options.connection orelse …` at :1725) — `Connection.Tls.create` then
   unwraps `client.now.?` (:357; documented `/// Asserts that 'client.now' is non-null.` at
   :303) → **ReleaseSafe panic on every https open**, and a TLS handshake against an unscanned
   CA bundle. Reverted in this round (finding 1): `request()` must own connect.
2. **Reach the layer that does honor a deadline.** `Io.net.IpAddress.ConnectOptions.timeout`
   (`Io/net.zig:335`) is real and `HostName.connect` (`Io/net/HostName.zig:274`) threads it
   through `connectMany` → `enqueueConnection`. But `std.http.Client` exposes no path to it:
   using it means owning socket setup, TLS handshake, CA-bundle scan, `client.now`, and pool
   registration ourselves — i.e. reimplementing the exact sequence whose hand-rolling produced
   attempt 1's crash. Rejected as unacceptable reimplementation on the one path the gate
   cannot exercise.
3. **Idle-read deadline as a substitute** — already deferred by the signed amendment for the
   same reason (no per-read hook on the blocking response reader); it would not bound a
   connect anyway.

### Minimal change (architect — ARCH wording only, no test/contract change)
Amend AC-e1 to state the truth, in the same register the amendment already used for the
idle-read timeout:

> **AC-e1 (amended).** v1 has **no connect deadline and no idle-read deadline** on the real
> network transport: Zig 0.16's `std.http.Client` honors neither (`ConnectTcpOptions.timeout`
> is declared and never read; the response reader has no per-read deadline hook), and the
> layer that does (`Io.net.IpAddress.ConnectOptions.timeout`) is not reachable without owning
> connection/TLS setup. A hung or non-responding host is bounded instead by the cancellable
> fetch model + user cancel (`ls_net_open_cancel` / `ls_close`). The timeout **taxonomy**
> (`LS_NET_ERROR_TIMEOUT`) remains contractual and hermetically tested via the fake
> (`NetFault.timeout`); only real-transport enforcement is out of scope for v1.

Code already matches this: `net_source.connect_timeout_secs` and `RealTransport.dial` are
**deleted**, with the evidence recorded at `src/net_source.zig:38-52` so no one re-adds them.

---

## Item 2 — AC-e2: the downgrade is DETECTED AND DISCARDED, not PREVENTED (wording)

The ARCH says an https→http redirect is **refused**. What the code can do is detect it after
the fact. `std`'s `Request.redirect` (Client.zig:1211-1277) releases the old connection, calls
`client.connect(...)` on the new scheme and re-sends — **all inside `receiveHead`**, before it
returns. So when we compare `uri.scheme` against `req.uri.scheme`, the plaintext GET has
already been issued and answered; we discard the response and fail the open with
`LS_NET_ERROR_INSECURE_REDIRECT`. Our `Range` header rides in `extra_headers`, which std keeps
across a cross-domain redirect (only `privileged_headers` are stripped), so it does travel over
plaintext. Range is not sensitive, and the round-1 reviewer explicitly did not call this
blocking — but the doc must not claim more than the code does.

### Why true prevention was not implemented (evidence, for the architect's choice)
- `.redirect_behavior = .not_allowed` does **not** hand us the hop: `receiveHead` discards the
  body and returns `error.TooManyHttpRedirects` (Client.zig:1182-1191) **without exposing
  `head.location`**, so we cannot inspect the target scheme, and we would also lose AC12's
  redirect-following entirely.
- The only route to real prevention is `.redirect_behavior = .unhandled` (Client.zig:1182
  returns the 3xx response to us), then re-implementing `Request.redirect` by hand: Location
  resolution (`Uri.resolveInPlace`), relative-URI merging, body discard, 303/POST method
  rewriting, connection release and per-hop cap accounting — roughly the whole of
  Client.zig:1211-1277, on the one code path the gate cannot execute. Given that hand-rolling
  std's connection sequencing is exactly what produced the finding-1 crash, I judged this the
  wrong trade for a non-sensitive header, and am escalating the wording instead of shipping
  the reimplementation unasked.

### Minimal change (architect — pick one)
- **(a) preferred, wording only.** AC-e2: "an https→http redirect is **detected and the
  response discarded**; the open fails with `LS_NET_ERROR_INSECURE_REDIRECT`. std follows the
  hop internally before returning control, so the plaintext request (carrying only `Range`) is
  issued; no response data is used." No code change — this is what ships now
  (`src/net_source.zig` probe/`fetchInto`).
- **(b)** Require true prevention → authorize the `.unhandled` hand-rolled redirect loop above
  as scoped work, with the reimplementation risk accepted.

## Cost / blast radius
- Item 1: ARCH AC-e1 text. Code change already made (dead knob + `dial` removed; the
  `.connection` inversion that crashed https is reverted). No `api/`, contract or test change.
- Item 2: ARCH AC-e2 text under option (a); a scoped `src/net_source.zig` change under (b).
- Frozen tests affected: **none** (verified by grep; the fake timeout/downgrade taxonomy tests
  `sec_e2`, `sec_e3`, `sec_e3_post_open` are untouched and GREEN).
- Changes EXTERNAL I/O?   [x] no — `api/lesssheet.h` is byte-identical. But both items touch a
  SIGNED architecture decision (the 2026-07-24 security amendment), so this goes to the
  ARCHITECT + the author, not the planner.
