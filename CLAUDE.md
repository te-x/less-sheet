# less-sheet — workspace guide for agents

Polyglot aidev workspace (pipeline reference: `~/.claude/aidev/README.md`). Project brief:
`docs/architecture/PROJECT.md` — read it before designing or planning anything.

## Map
- `api/` — frozen, language-neutral C headers: the cross-component contract. Root planner only.
- `backend/` — Zig 0.16.0 core (static library). Nested aidev project.
- `apps/macos/` — Swift 6 / SwiftPM frontend. Nested aidev project.
- Component gates: `bash backend/.aidev/gate.sh backend` · `bash apps/macos/.aidev/gate.sh apps/macos`
- Root gate (api/ integrity + chains every component gate): `bash .aidev/gate.sh`

## Zig 0.16.0 — docs first, memory last (MANDATORY)
Zig is pinned to **0.16.0** (the backend gate asserts the exact version) and the language churns
faster than training data — pre-0.16 idioms (build API, ArrayList, io reader/writer, mem …) are
often wrong now. Before writing or reviewing ANY Zig:
1. **Grep the installed std source** at `/opt/homebrew/opt/zig/lib/zig/std/` — the authoritative
   0.16.0 API (e.g. `grep -n "pub fn addLibrary" /opt/homebrew/opt/zig/lib/zig/std/Build.zig`).
2. `zig std` serves the std docs locally; `zig build --help` lists current build options.
3. Language reference for exactly this version: https://ziglang.org/documentation/0.16.0/
4. Still unsure? Compile a tiny probe — the compiler is the final word.

## Cold-start budget
Every frontend must go launch → first rows visible in **< 500 ms**; open is O(viewport), never
O(file). Treat any change that reads a whole file before first paint as a performance bug.
