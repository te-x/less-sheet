# ARCH — frontpage redesign (`site/index.html`)

Status: **AGREED — signed off by the author (2026-07-30); ready for the planner**
Date: 2026-07-30 · Role: architect (interactive, relayed)
Sign-off record: §7.3 accepted (system theme only, no manual toggle); §7.4 stands as specced;
§3.3 approved in full (5 shots × 4 variants = 20 files), capture automated per §7.7.
Supersedes the 2026-07-15 landing page (`0354be9`) in place — same file, same assets directory.

---

## Amendment — 2026-08-16 (publication decision; the author sign-off)

the author decided on 2026-08-16 to publish, and the repositories now exist. The §1 non-goal
**"Never publish this workspace"** is amended in place: it barred the git remote that publishing
requires, and a signed document forbidding what the project is now doing is precisely what sends
future roles to re-open a settled decision. Affected passages carry an *(amended 2026-08-16)* tag.

**Now permitted.** One `origin` remote on this workspace, pointing at a **private** source
repository. Publishing release artifacts and the built landing page to **public** repositories.

**Still forbidden, unchanged and without exception.** Source of any kind — `backend/`, `apps/`,
`api/`, `.aidev/`, `review/`, `docs/` — reaching a public repository. A leaked push is
irreversible: GitHub retains forks and caches. Adding, retargeting or force-pushing a remote
remains the author's action alone; no role does it.

**The shape as built, which this records rather than proposes:**

| repository | visibility | contents |
| --- | --- | --- |
| `te-x/less-sheet` | **private** | the workspace: source, `.aidev/`, `review/`, `docs/`, `site/` |
| the site repo (target of `deploy-site.yml`) | public | the built landing page only; Pages serves it |
| `homebrew-tap` | public | the cask — not yet created |

The separation is enforced by machinery, not discipline: `.github/workflows/deploy-site.yml` runs
on push to `master` and copies `site/` into the public site repo via
`cpina/github-action-push-to-another-repository`, so **the page publishes without the source repo
ever being public**. `master` is the sole branch and the default; `main` was deleted 2026-08-16.

**Verified 2026-08-16: `te-x/less-sheet` is Private** (confirmed by the author). This is the check
that matters — a public source repo is the exact irreversible failure this non-goal was written
to prevent — and it must be re-confirmed before that repository's visibility is ever changed.
Treat flipping it as a decision, not a setting.

**Consequence for §9.1:** step (a) of its ordered list is done.

---

## 1. Problem & scope

The landing page is wrong in ways that precede taste: it names one platform when the product has
two at feature parity; it shows benchmark figures measured on a build we no longer ship
(pre-ReleaseSafe); it sells a payment that no longer exists; both download links are dead; it is
light-mode-only while its hero image sells dark mode; and it weighs ~5 MB in PNGs — a page about
opening things instantly that is itself slow to open.

Scope: a full redesign of `site/index.html` and its screenshot assets, per the author's direction:

- **Layout**: two-column throughout — prose on the left, imagery on the right, the image cell
  horizontally scrollable where one shot won't do. This replaces the alternating
  text/image/text/image vertical stack entirely.
- **Register**: plain, technical, direct.
- **Frame**: the concrete differences from Excel and LibreOffice, in this claim order:
  (1) speed, (2) how easily the parsing can be changed (separator, quote), (3) fidelity.
- **Positioning**: a viewer for tabular/spreadsheet data — not "a CSV tool" — while making
  unmistakably clear that CSV (plain, gzipped, over the network) is all it reads.
- **Compactness**: an existing requirement, not revisited.
- **Free app, download only**: Buy and the pay-what-you-want line are removed. Settled.

### Non-goals

- No pricing, licence, or purchase content of any kind.
- No source-code link (closed source). A ticket tracker link is planned, see §7.
- No framework, build pipeline, CMS, or site generator — one static HTML file remains the product.
- No analytics, tracking, or third-party requests of any origin.
- No blog, docs site, changelog page, or localization.
- No measured head-to-head benchmark bars against Excel/LibreOffice (would require a versioned
  methodology to defend; our own numbers carry the proof). The contrast stays qualitative and
  architectural.
- No video or animated demos in this revision.
- No claims of: xlsx/ods support (xlsx dropped, ods deprioritised — no "coming soon" cover),
  Parquet (prioritised but not built), or accessibility (the GTK screen-reader pass is recorded
  as unverified). The page itself is still *built* accessibly (alt text, focus, contrast) — we
  simply claim nothing about the app.
- **Never publish SOURCE.** *(amended 2026-08-16 — see the Amendment above. This bullet
  originally read "Never publish this workspace" and barred any remote at all.)* Hosting (§9.1)
  forces a public repo, and the code is closed: the public repos carry ONLY the site, the release
  assets, and the issue tracker — never source. This workspace may carry one `origin` pointing at
  a **private** repo; **no role may add, retarget or force-push it, and no source may reach a
  public repo** — a leaked push is irreversible (GitHub retains forks and caches) and is the
  highest-consequence action this feature could trigger. Creating repositories, enabling Pages,
  and pushing are the author's actions alone.

---

## 2. Inputs / Outputs

**Inputs (dependencies — the page does not publish until all are real):**

| Input | Source | State |
|---|---|---|
| Screenshot set (§3.3: 5 shots × 2 platforms × 2 themes = 20 files) | Deterministic capture tool (§7.7); residual manual steps: one-time macOS Screen Recording grant, hero composition choice, review of outputs (the author) | Not started |
| Benchmark figures re-measured on the shipped ReleaseSafe build | Queued measurement task; needs a quiet machine | Queued |
| Download artifacts | Built & launch-verified 2026-07-30: `less-sheet-0.1-macos-arm64.dmg` 3.34 MB (macOS 26.0+, arm64); `less-sheet-0.1-linux-aarch64.tar.gz` 0.65 MB (glibc ≥ 2.34, GTK4 ≥ 4.20, libadwaita ≥ 1.8); `SHA256SUMS` + `manifest.json`. The zip is a build byproduct, never offered. Linux x86_64 blocked on a core link fix (`__zig_probe_stack`), planner pass in flight | Exist; unhosted |
| Hosting | **Decided 2026-07-30: GitHub Releases (artifacts + `SHA256SUMS`) + GitHub Pages (page)**, from a public site-only repo (§9.1). Repo creation, Pages enablement, and pushes are the author's actions alone | Repo not yet created |
| Release tag / version | Single-sourcing task in flight (macOS `Info.plist` says 0.1, `apps/gtk/meson.build` says 0.0.0); the tag drives every download URL, so page links derive from the one version — never hand-typed | In flight |
| Ticket-tracker URL (GitHub, issues-only) | Not created; no git remote exists today | Planned, not live |

**Outputs:**

- `site/index.html` — rewritten in place. Single self-contained file: inline `<style>`, no external CSS/JS/fonts.
- `site/assets/` — `logo.svg` kept; the eight PNGs replaced by the AVIF screenshot set (§8.2).
- `tools/` gains the capture tool (§7.7) — the one artifact outside `site/`.

**Ordering (hard dependency):** the frontpage ships together with, or after, the download
binaries — never before. The binaries now exist and are launch-verified (2026-07-30), so the
remaining blocker is **hosting**: the artifacts live nowhere a link can point yet (§9.1). The
verification timings (197 ms to first rows from the unpacked `.dmg`; 120.3 ms cold start in a
clean container) are input evidence that the artifacts work — not page copy; published figures
still come exclusively from the bench task (AC-10).

---

## 3. Functional requirements

### 3.1 Page structure — the band model

Every content unit is a **band**: one CSS-grid row, prose in the left cell, media in the right
cell. On viewports below the collapse breakpoint a band stacks (prose, then media). No band is a
full-width text block followed by a full-width image. A slim masthead precedes the bands; a footer
follows them.

```
┌──────────────────────────────────────────────────────────────┐
│ masthead: logo · name            nav: Benchmarks · Download  │
├───────────────────────────┬──────────────────────────────────┤
│ B1 HERO                   │  [ macOS ◉ | Linux ○ ]  ← toggle │
│  H1 claim                 │  ┌────────────────────────────┐  │
│  category+constraint      │  │  hero shot (per platform,  │  │
│  sentence (one sentence)  │  │  per system theme)         │  │
│  proof pair (signature)   │  └────────────────────────────┘  │
│  [Download] → B6          │                                  │
├───────────────────────────┼──────────────────────────────────┤
│ B2 SPEED                  │  jump-to-row shot                │
├───────────────────────────┼──────────────────────────────────┤
│ B3 DIALECT, LIVE          │  dialect-controls shot           │
├───────────────────────────┼──────────────────────────────────┤
│ B4 FIDELITY               │  contrast table (typographic —   │
│                           │  no screenshot in this band)     │
├───────────────────────────┼──────────────────────────────────┤
│ B5 FIND / FILTER          │  ← horizontally scrollable strip │
│                           │    (search · filter+predicate)   │
├───────────────────────────┼──────────────────────────────────┤
│ B6 BENCHMARKS             │  HTML/CSS bars (no images)       │
├───────────────────────────┼──────────────────────────────────┤
│ B7 DOWNLOAD + FORMATS     │  artifact list · "Reads:" line   │
├───────────────────────────┴──────────────────────────────────┤
│ footer: tagline · platform line · tracker/contact (§7)       │
└──────────────────────────────────────────────────────────────┘
```

The left-column narrative order is fixed (the author's claim order): **opens instantly regardless of
size → change how it's parsed, live, without reopening → never rewrites your data.** Find/filter
and benchmarks follow as supporting depth.

### 3.2 Band content

- **B1 Hero.** App name; H1 claim; then **one sentence that names the category and the constraint
  together** — the visitor cannot read "viewer for spreadsheet-sized tabular data" without reading
  "reads CSV — plain, gzipped, or streamed from a URL — and nothing else" in the same sentence,
  with the constraint framed as the mechanism of the speed. Directly under it, the **proof pair**
  (the page's design signature, §8.5): cold-open figures for two file sizes an order of magnitude
  apart showing flat cost (target material: ~100 ms at 500 MB vs ~103 ms at 2 GB on a 7200 rpm
  disk; ~15 ms on NVMe — placeholders until re-measured, §5.4). A Download button links to B7.
  Right cell: the platform toggle and the hero shot.
- **B2 Speed.** O(viewport) explained plainly: shows the part you're looking at, reads nothing
  else; no import step, no progress bar before first rows; jump to row 100,000,000 and it lands,
  with honest progress on the way. Network streaming folds in here: point it at a URL and only
  the bytes you look at are fetched; `.csv.gz` inflates on the fly. Contrast (in-prose, factual):
  Excel and LibreOffice read the whole file before showing anything. Right cell: jump shot.
- **B3 Dialect, live.** Separator, quote, header row, encoding are detected from the file; the
  data appears immediately; every one of them is a live control that re-renders the open document
  — no reload, no re-import. Contrast: the one-shot modal import wizard that runs *before* you see
  the data, where a wrong guess means closing and starting over. Right cell: dialect-controls shot.
- **B4 Fidelity.** Read-only, period: bytes shown as they are; dates, leading zeros, and long
  numbers survive untouched; formatting is display-only; copy and search always use original
  values; no row ceiling (Excel stops at 1,048,576 rows — a documented fact). Right cell: a small
  typographic contrast table (opening the same CSV in each program), **not** a screenshot —
  deliberate variety, one fewer capture. The comparison is always about *what those programs do to
  a CSV you open in them* — never about reading their formats. No xlsx/ods filename, icon, or
  artifact appears anywhere on the page.
- **B5 Find / filter.** Incremental search with live match counts; typed column predicates;
  filtered views keeping original row numbers; anything non-instant shows progress and can be
  cancelled. Right cell: scrollable strip of two shots (search; filter+predicate).
- **B6 Benchmarks.** HTML/CSS bars, no images. Plain-file figures lead. `.csv.gz` is presented
  honestly: opening is floored by inflation (~420–580 ms on a realistic file) — **no copy may
  state or imply gz opens like plain CSV.** All figures are absolute measurements on the shipped
  build; **no self-relative multipliers** ("1.9× faster than before" is changelog material, not
  landing-page material). Methodology line kept (median, cold, machine, footprint).
- **B7 Download + formats.** Settled 2026-07-30: **one link per platform** — the `.dmg` for
  macOS, the `.tar.gz` for Linux; the zip byproduct is never offered. Each link sits with its
  requirements line in the same visual group — macOS: "macOS 26.0 or later · Apple silicon ·
  3.3 MB"; Linux: arch label per the two-state rule below, "glibc 2.34+ · GTK 4.20 /
  libadwaita 1.8 (GNOME 49-generation: Fedora 43+, current Arch) · 0.7 MB". A `SHA256SUMS`
  link accompanies the artifacts. Beside the links, in the same visual group: **"Reads: CSV ·
  CSV.GZ · http(s) URLs"** — the constraint restated at the point of commitment. Formats pills
  stay: CSV (on), CSV.GZ (on), "more formats coming" (generic — no format named).

  **First launch on macOS — a designed element, not a footnote.** The `.dmg` is ad-hoc signed,
  not notarized, so Gatekeeper blocks the first open of a downloaded copy. Directly beneath the
  macOS link, visible without any interaction (no accordion, tooltip, or hover reveal), two or
  three lines in the plain-technical register: the why (the app is signed but not notarized
  through Apple's paid developer program — it is a free app), then the exact path — open the
  app once, then **System Settings → Privacy & Security → "Open Anyway"** — stated as a
  property of how macOS treats unnotarized downloads, not an apology. A visitor who hits the
  block with no explanation concludes the app is unsafe; a visitor told before downloading
  reads it as a distribution fact. The page must never contain the old right-click /
  control-click → Open instruction: Apple removed it in macOS 15 and the floor here is 26, so
  that copy would be wrong (AC-14). The `SHA256SUMS` link doubles as the integrity affordance
  for the visitor this note makes cautious.

  **Linux reach, honestly — two shippable states.** (a) If the x86_64 tarball lands before
  publication (the `__zig_probe_stack` fix is in flight): two artifact links under the Linux
  label — x86_64 and aarch64 — sharing one requirements line. (b) If not: the label reads
  "Linux · aarch64" and the band states plainly that x86_64 is not yet available — explicit
  absence, never silence, because a silently aarch64-only link reads as broken Linux support
  to the majority-arch visitor. One short clause naming Flatpak as the planned channel for
  wider distro reach is permitted (the author's committed channel decision) — the page's only
  forward-looking distribution statement, distinct from the format-promise ban.
- **Footer.** Tagline; platform line mirroring the download band's labels — "macOS 26.0+
  (Apple silicon) · Linux aarch64 (GNOME 49-generation)", gaining x86_64 if that artifact ships
  (§3.2 B7 two-state rule); tracker/contact per §6 and §9 (OQ 2–3).

### 3.3 Screenshot inventory — 5 distinct shots (hard cap 6)

| # | Shot | Band | Content spec (capture checklist details at planning) |
|---|---|---|---|
| 1 | `hero` | B1 | Main window over a visibly large file; the money shot |
| 2 | `jump` | B2 | Jump-to-row control at a very large row number |
| 3 | `dialect` | B3 | Live separator/quote controls open over the grid |
| 4 | `search` | B5 | Text find with live match count, matches highlighted |
| 5 | `filter` | B5 | Filtered view with a typed predicate visible, original row numbers kept |

Each shot exists in **4 variants**: {macOS, Linux/GNOME} × {light, dark} = **20 files**. All
variants of one shot share **identical pixel dimensions** (the platform toggle must not cause
layout shift), and the whole rail shares one aspect ratio. A visitor loads at most 5 files (their
theme, chosen platform, lazy-loaded); first paint loads 1–2. **Approved by the author (2026-07-30):**
all five shots, both platforms, both themes. Capture is scripted, not manual — the deterministic
capture tool (§7.7) regenerates each platform's ten files with one command; what stays human is
the one-time macOS Screen Recording grant, the hero's composition choice (encoded once as tool
parameters), and a review of the 20 outputs before they ship. The existing eight PNGs are
retired; none match the new composition/dimension spec.

### 3.4 Copy rules (register)

Plain, technical, direct. Active voice; specific over clever; no marketing superlatives; every
claim either an architectural fact of this codebase or a measured number from the shipped build.
Excel and LibreOffice are named as programs and contrasted factually, never disparaged loosely.
The `less` heritage ("does for tabular data what `less` does for text") is available material,
not required copy.

---

## 4. Non-functional constraints

1. **The page meets the product's own bar.** A landing page for a tool obsessed with cold start
   must itself be near-instant: budgets in AC-8. Zero third-party requests, zero webfonts, zero
   required JavaScript.
2. **Works or fails gracefully, no JS required.** All content, the theme, and the platform toggle
   function with JavaScript disabled. Any script present is progressive enhancement only (§8.4).
3. **Honesty is structural.** The CSV constraint appears in the hero sentence and beside the
   download control; nothing on the page implies xlsx/ods/Parquet support or app accessibility;
   no dead links — the page ships only when its download links resolve (it lands together with
   the binaries).
4. **No number without a measurement.** Every published figure is re-measured on the shipped
   ReleaseSafe build (the pre-`376abb9` figures are void). The hero proof pair is drafted with
   placeholder-marked values and blocked from publication until the bench task lands.
5. **Responsive**: bands collapse cleanly on narrow viewports; the B5 strip stays horizontally
   scrollable within its own cell; the body never scrolls horizontally.

---

## 5. Component decomposition & data flow

Existing components touched:

- `site/index.html` — **rewritten**. Remains a single self-contained static file (inline CSS; the
  one optional enhancement script inline too, if kept).
- `site/assets/logo.svg` — **reused unchanged**. The brand identity (2.5D logo, aqua→lavender
  wash) is kept; this is a refinement, not a rebrand. The wash palette gains dark-scheme values.
- `site/assets/shot-*.png` (8 files, ~5 MB) — **deleted**, replaced by the 20-file AVIF set named
  `shot-<name>-<platform>-<theme>.avif`.

Outside `site/`, two things may change: `tools/` gains the capture tool (§7.7), and — where a
state knob is missing — the existing probe-harness pattern in `apps/macos` (and the GTK CLI
equivalent) gains it, in the established style: state setup for capture only, never a
user-visible behavior change. No backend or `api/` involvement. Data flow is one-way: captures +
measured figures + artifact URLs (inputs, §2) are baked into the static file; the page computes
nothing at runtime beyond CSS state (theme media queries, one radio group).

**Publishing split (hosting decided, §9.1):** this workspace stays the sole authoring ground —
`site/index.html`, the AVIF set, the capture tool, and fixtures live and evolve here. The public
site-only repo is a **publish target, never an editing surface**: a prepared one-command step
copies `site/` into it **byte-identical** (a copy, not a re-export — so the human-reviewed
capture outputs of AC-13 are exactly the bytes that ship). Binaries and `SHA256SUMS` go to
GitHub Releases, not the Pages tree. Nothing else of the workspace ever crosses over (§1
non-goals).

---

## 6. External interfaces

- **Download artifacts** (settled 2026-07-30): one link per platform — the `.dmg` (macOS 26.0+,
  Apple silicon) and the `.tar.gz` (Linux) — plus `SHA256SUMS`. The zip byproduct is never
  offered. B7 stays flexible on exactly one axis: one or two Linux arch links per the two-state
  rule (§3.2 B7). Placeholder URLs exist only in the draft; publication requires hosted URLs
  (AC-10, §9.1). The GTK app id (`com.lesssheet.LessSheet`; rename from `dev.lesssheet.Gtk` is a
  separate task) is not referenced anywhere on the page — not a page dependency.
- **Ticket tracker** (planned, not live): closed source, GitHub presence for issues only — a
  normal arrangement. The footer carries "Report a bug / request a feature → tracker" **only once
  the tracker exists**; the page must be complete and honest without it (the footer line is
  omitted, not stubbed). Because filing a GitHub issue requires a GitHub account, I recommend a
  plain `mailto:` contact alongside it — the analyst audience in the brief won't all have
  accounts. The *principle* is a recommendation; the *address* is the author's call (§9, OQ 2).
- **Hosting**: **GitHub Releases + GitHub Pages** (the author, 2026-07-30). Release assets get
  stable direct-download URLs — `https://github.com/<owner>/<repo>/releases/download/<tag>/<file>`,
  no interstitial, no JavaScript — exactly what §9.1 required; `SHA256SUMS` uploads alongside as
  a release asset, so B7's integrity link is a plain href. The page is served by Pages from the
  public site-only repo (§5 publishing split). The `<tag>` is the single-sourced version (§2):
  every baked URL derives from it, never hand-typed.

---

## 7. Technology decisions

Each: decision · alternatives · rationale · scope.

### 7.1 Zero-build static single file — *kept*
- **Alternatives**: static-site generator (Eleventy/Astro), CSS framework.
- **Rationale**: one page, no shared templates, no dependency surface, trivially auditable;
  matches the project's single-digit-MB, no-runtime-deps ethos. Screenshots are pre-encoded
  offline (one documented `avifenc`/ImageMagick invocation in the capture checklist), which is a
  step, not a build.
- **Scope**: feature-local (it's the whole site).

### 7.2 Screenshot format: AVIF, lazy-loaded
- **Alternatives**: PNG (status quo — 5 MB, rejected), WebP (fine, ~30–50% larger than AVIF at
  this quality), JPEG (fringing on UI text).
- **Rationale**: AVIF is universally supported in current browsers (Safari 16.4+, all evergreen —
  and the target audience runs current browsers); UI screenshots compress extremely well; per-file
  budget ≤ 150 KB is comfortably achievable at visually lossless quality. `loading="lazy"` on all
  below-fold shots; hidden platform variants are not fetched until revealed. Only deployed AVIFs
  are committed; captures are cheap to redo, so originals are not stored in the repo.
- **Scope**: feature-local.

### 7.3 Theming: system-scheme only — **advising against the manual dark/light toggle**
- **Decision**: the page declares `color-scheme: light dark`; palette via CSS custom properties
  under `prefers-color-scheme`; **screenshots follow the page theme automatically** via
  `<picture>`/`media` sources. Page and shots are always coherent — one theme, decided by the
  visitor's system. There is **no separate screenshot-theme control and no manual page toggle**:
  one axis, zero controls.
- **This answers the author's "maybe the user should be able to toggle dark/mode"** — his "maybe"
  invited advice, and my advice is no: the OS already gives every visitor the theme they chose,
  for the page *and* the shots, with zero JavaScript; a manual override duplicates that OS
  control and forces either JS or a CSS-radio workaround that fights the native `<picture>`
  mechanism. Two theme controls (page vs screenshots) would be worse still — a light shot on a
  dark page is exactly the incoherence the current page suffers from.
- **Reversibility**: both theme variants of every shot are produced regardless (system-dark
  visitors need them), so adding a manual toggle later is an additive change, not a redesign.
- **Signed off**: accepted by the author, 2026-07-30 — "system theme only".
- **Scope**: feature-local.

### 7.4 Platform toggle: macOS/Linux, CSS-only, whole rail
- **Decision**: one radio pair (styled as a segmented control in the hero's right cell) scoped so
  it switches **every** shot on the page between the macOS and GNOME variant sets. Default:
  macOS (the first/authoritative frontend). Pure CSS state — works with JS disabled. An optional
  ≤10-line inline script may pre-select the visitor's platform from the UA as progressive
  enhancement; without it, the default simply stands.
- **Alternatives**: hero-only toggle (rejected: a rail mixing GNOME and macOS windows after a
  toggle is incoherent); JS-driven swap (rejected: violates no-JS-required); separate pages per
  platform (rejected: duplicates the story, fights compactness).
- **Rationale**: platform is the axis with no trustworthy native signal and a real visitor
  motive ("show me *my* platform" — or a colleague's). Unlike theme, a visible control earns
  its place here.
- **Signed off**: stands as specced (the author, 2026-07-30).
- **Scope**: feature-local.

### 7.5 Typography: system UI stack + `ui-monospace` accents; the proof pair as the signature
- **Decision**: body/display in the platform's system UI stack (zero webfont bytes); numerals,
  the proof pair, band eyebrows, and the "Reads:" line in `ui-monospace` with tabular numerals.
  The **design signature** is the hero proof pair: two file sizes an order of magnitude apart,
  two near-identical times, set large in monospace — the scaling law *is* the visual. Structure
  encodes information: the one bold element on the page is the product's thesis, demonstrated.
- **Alternatives**: a characterful webfont display face (rejected: bytes + against
  native-and-current house style); keeping the numbers small in a bench section (rejected: that
  is the template habit this redesign discards).
- **Rationale**: a native viewer whose page is set in each platform's own native face makes the
  positioning literal; the monospace accents carry the plain-technical register.
- **Scope**: feature-local.

### 7.6 Competitive band: qualitative-architectural facts only — *confirmed*
- Whole-file-import behavior, one-shot import wizard, Excel's documented 1,048,576-row ceiling,
  silent value rewriting (dates, leading zeros), memory scaling with file size. No measured
  competitor timings (no versioned methodology to defend), no loose disparagement.
- **Scope**: feature-local.

### 7.7 Screenshot capture: deterministic tool, not manual work
- **Decision**: a capture tool under `tools/` (beside `csvgen`, `bench`, `run_gtk_on`) —
  **one command per platform** regenerates that platform's ten files. Per shot it guarantees:
  fixed window geometry; the same deterministic fixture (a `csvgen`-produced catalog file);
  identical document state across all four variants (same file, same position, same control
  open — driven through the app's real UI paths); theme set per launch (no system-settings
  changes between shots); outputs named `shot-<name>-<platform>-<theme>.avif`; and a post-check
  that all four variants of every shot have identical pixel dimensions — AC-7's no-layout-shift
  requirement made true by construction rather than by hand-matching 20 files.
- **Mechanics — existing patterns, no new machinery**: on macOS the env-var probe harness
  already drives real UI paths headlessly (`LESSSHEET_FIND` performs a find "identical to
  typing"; wrap/step/scroll/fetch/overscroll knobs; `LESSSHEET_DUMP_EXIT`;
  `apps/macos/Sources/LessSheetApp/*Probe.swift`) — missing knobs (window size, a filter
  predicate, the dialect panel open) are added in the same pattern. Capture via `screencapture`
  after a **one-time** Screen Recording grant. On Linux (Hyprland/wlroots), the GTK app's
  documented CLI parity sets state and `grim` captures fully unattended, no prompt.
- **Not automated — stated honestly**: the one-time macOS permission grant (the author's; agents
  never trigger the TCC dialog — standing rule); the composition judgment (which fixture region
  makes the hero compelling is a human call, encoded once as tool parameters); and a final human
  review of the 20 outputs before they ship — a real step, and far cheaper than 20 manual
  captures.
- **Alternatives**: manual capture against a checklist (rejected: pixel-identity across 20 files
  drifts silently by hand, and every future UI change re-imposes the full capture cost);
  AppleScript/Accessibility GUI automation (rejected: triggers TCC prompts — standing rule).
- **Rationale**: §3.3's dimension-identity requirement is load-bearing for the platform toggle;
  a script makes it structural, and keeps the shot set refreshable after any future UI change.
- **Scope**: feature-local tool; probe-harness additions follow each app's existing conventions.

---

## 8. Acceptance criteria

Each verifiable on the built page with grep, a browser, and devtools — no judgment calls.

1. **Two-column bands**: at ≥ 900 px viewport width, every content band renders prose-left /
   media-right in one grid row; no full-width text block is followed by a full-width image.
   Below the breakpoint, bands stack without horizontal body scroll at 375 px.
2. **Hero sentence**: the first prose block contains, in a single sentence, both the category
   ("viewer" + tabular/spreadsheet framing) and the constraint (CSV, gzipped, URL/network) —
   verifiable by reading one sentence, not assembling fragments.
3. **Constraint at commitment**: the download band renders a "Reads: CSV · CSV.GZ · http(s)"
   line inside the same visual group as the artifact links.
4. **No format overclaim**: case-insensitive grep of the deployed HTML for `xlsx`, `ods`,
   `parquet` yields zero hits; no asset depicts an xlsx/ods file; "Excel" and "LibreOffice"
   appear only as program names in contrast copy.
5. **No dead promises**: zero `href="#"`; zero pricing/Buy/pay-what-you-want text; zero
   accessibility claims about the app; grep-verifiable.
6. **Theme coherence**: with `prefers-color-scheme` forced to each value, the page palette AND
   every visible screenshot match that theme (no light shot on the dark page or vice versa);
   achieved with zero JavaScript.
7. **Platform toggle**: with JavaScript disabled, switching the control swaps every screenshot
   on the page between macOS and GNOME variants; default is macOS; no layout shift (all variants
   of a shot are pixel-identical in dimensions).
8. **Weight budget**: cold first load (HTML + inline CSS + above-fold images, one platform/theme
   path) ≤ 500 KB transfer; every screenshot file ≤ 150 KB; full single-path load (all bands
   scrolled, one platform, one theme) ≤ 1.5 MB; zero requests to any third-party origin; zero
   font files.
9. **No-JS completeness**: with JavaScript disabled, all content, navigation, theme, and toggle
   behavior work; any inline script is ≤ 10 lines and only pre-selects the platform default.
10. **Publication gate**: the published page's benchmark and proof figures each trace to a bench
    record measured on the shipped ReleaseSafe build (record path cited in an HTML comment
    beside the figures); download links resolve to real artifacts; the tracker link is present
    only if the tracker is live. Draft state (placeholders) never deploys.
11. **gz honesty**: no sentence states or implies `.csv.gz` opens as fast as plain CSV; gz
    figures appear with the inflate note; no self-relative multipliers ("N× faster than
    before") anywhere.
12. **Band order**: left-column claims read speed → live dialect → fidelity, in that order,
    before find/filter and benchmarks.
13. **Reproducible captures**: every shipped screenshot is an output of the capture tool (§7.7)
    — one command per platform, committed fixture, fixed window geometry; the tool's post-check
    passes (all four variants of each shot pixel-identical in dimensions); the 20 outputs get a
    recorded human review before publication.
14. **Gatekeeper element**: the download band renders the macOS first-launch explanation in the
    same visual group as the macOS link, visible without any interaction; its text contains
    "Privacy & Security" and "Open Anyway"; case-insensitive grep of the deployed HTML for
    `right-click`, `right click`, `control-click`, and `ctrl-click` yields zero hits.
15. **Reach honesty**: every download link is adjacent to its requirements line (macOS: contains
    "26.0" and "Apple silicon"; Linux: contains the GTK/libadwaita floor or its distro
    translation); arch labels match the artifacts actually offered; if no x86_64 Linux artifact
    is offered, the band contains an explicit statement that x86_64 is not yet available;
    case-insensitive grep for `.zip` yields zero hits.

---

## 9. Open Questions

1. **Hosting and deploy** — **resolved (the author, 2026-07-30): GitHub Releases + GitHub Pages.**
   Releases provides stable, interstitial-free direct-download URLs and hosts `SHA256SUMS` as an
   asset; Pages serves the page from a public **site-only** repo — closed source stands, see the
   §1 non-goal barring any source in a public repo *(amended 2026-08-16)*. AC-8 stands: download
   links are user-initiated navigations; the release origin does not count against the
   zero-third-party *resource* budget. **What publication still needs, in order:** (a) the author
   creates the public repo and enables Pages — his actions alone; (b) the release is uploaded
   under the single-sourced version tag (§2); (c) the baked `<owner>/<repo>/<tag>` URLs are
   substituted and resolve; (d) the capture set is produced and human-reviewed (AC-13); (e) the
   re-measured figures land (OQ 6). Then AC-10 gates the deploy.
2. **Contact fallback address** — I recommend a `mailto:` beside the tracker link for
   non-GitHub-account visitors; *which* address (and its spam exposure) is the author's call.
3. **Tracker URL** — the issues-only GitHub repo does not exist; name/org TBD; footer line omitted
   until live.
4. **Artifact list** — **resolved 2026-07-30**: one link per platform (`.dmg` / `.tar.gz`,
   `SHA256SUMS` alongside; the zip byproduct never offered). Only the Linux arch count stays
   two-state until publication (§3.2 B7).
5. **Footer Linux wording** — **resolved**: the footer platform line mirrors the download
   band's labels — "macOS 26.0+ (Apple silicon) · Linux aarch64 (GNOME 49-generation)" —
   gaining x86_64 if that artifact ships (§3.2 B7 two-state rule).
6. **Published figures** — all numbers await the re-measurement task on the shipped build; the
   hero proof pair (the 3-tier flat-cost result) must be re-verified on that build before it is
   the signature. The artifact-verification timings (197 ms / 120.3 ms, §2) are evidence the
   binaries work, not page figures.
