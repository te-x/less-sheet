# less-sheet macOS app (Swift) — component brief

This is a **component** of the less-sheet workspace. The project brief lives at the workspace
root: `docs/architecture/PROJECT.md` (read that first — it holds the what/why, hard constraints,
glossary, and slice list).

Component role: a **frontend** — thin Swift/SwiftUI shell over the core's C ABI (headers frozen
in the workspace-level `api/`). Renders what the core serves; owns no parsing. Component-specific
ARCH docs land in this directory as `ARCH-<feature>.md`.
