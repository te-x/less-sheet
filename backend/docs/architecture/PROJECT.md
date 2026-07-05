# less-sheet core (Zig) — component brief

This is a **component** of the less-sheet workspace. The project brief lives at the workspace
root: `docs/architecture/PROJECT.md` (read that first — it holds the what/why, hard constraints,
glossary, and slice list).

Component role: the **core** — a Zig static library exposing a C ABI (headers frozen in the
workspace-level `api/`). The only component that touches files. Component-specific ARCH docs
land in this directory as `ARCH-<feature>.md`.

**Zig 0.16.0 pinned (gate-enforced) — docs first.** The language churns faster than training
data: verify every API against the installed std source (`/opt/homebrew/opt/zig/lib/zig/std/`)
or a tiny compiled probe before authoring. Never write Zig from memory.
