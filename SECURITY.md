# Security

less-sheet opens files and URLs it does not trust: CSV, gzipped CSV, and CSV streamed over HTTP(S). The
parsing core is Zig and ships in ReleaseSafe mode, so a memory-safety bug is a clean abort rather than an
exploitable one; the fuzzers under `tools/fuzz/` exist to keep it that way. If you have found something
that gets past that — a crash, a hang, wrong data shown silently, a network request the app should not
make — please report it privately.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository: **Security → Report a vulnerability**.
That opens a private thread with the maintainer; please do not open a public issue for a security
problem until a fix has shipped.

Include what you opened (a minimal file or URL that reproduces it, if you can share one), the platform
and version (`less-sheet --version`, or the About dialog), and what you observed.

## What to expect

You get an acknowledgement in the report thread, a fix in a new release, and credit in the release
notes if you want it. There is no bug bounty.

## Scope

In scope: the Zig core (`backend/`), both frontends (`apps/`), the release artifacts and the install
routes documented on the landing page. Out of scope: the content of files you choose to open, and
formula injection in spreadsheets you paste copied cells into — less-sheet neutralises leading
formula characters on copy, but the pasting application decides what to execute.
