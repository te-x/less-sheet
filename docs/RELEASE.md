# less-sheet — Build & Release Runbook

**Purpose:** how to build the app, publish the first version, and ship updates — for the author (who executes) and the orchestrator (who can later script it).

> **Status (2026-08-05):** Pre-launch. **Building and packaging are now scripted and exercised**; publishing still is not. `tools/release/make_release` builds the macOS `.zip`/`.dmg` and the Linux `.tar.gz` (aarch64 + x86_64), verifies each artifact by **running it**, and writes `SHA256SUMS` + `manifest.json`. Nothing is uploaded, notarized, or submitted anywhere, and no Developer ID is used.
>
> Two defects were found and fixed while first exercising this path:
> - **The assembled `.app` was unsealed and macOS refused to launch it** — the user-visible symptom was *"damaged and can't be opened … move it to the Trash"*, which hit the author's own installed app. Cause: `assemble-app.sh` wrapped a linker-ad-hoc-signed executable in a bundle without ever sealing the bundle, so the signature claimed sealed resources that did not exist. `assemble-app.sh` now ad-hoc-seals the bundle as its last step and verifies with `codesign --verify --strict`. See §3a.
> - **`LSMinimumSystemVersion` claimed 15.0 while the binary requires macOS 26.0** (`Package.swift` targets `.macOS("26.0")` for Liquid Glass). A macOS 15 user would have been offered the app and then got a dyld failure instead of a clean "requires macOS 26" message. Corrected to 26.0.
>
> Settled since (2026-08-05):
> - **The version is single-sourced** to `VERSION` at the workspace root (§1). The GTK build reads it; the macOS bundle and `tools/release/make_release` still hold their own copies and are the last two consumers to convert — §1 specifies exactly how.
> - **The GTK app-id is `com.lesssheet.LessSheet`** (the author's decision), matching what §4b proposes. It was `dev.lesssheet.Gtk`; the id, the embedded icon's filename, the GResource path and the `icon-name` lookup were renamed together and the icon was re-verified as resolving.
>
> Still open: macOS ships **ad-hoc signed, not notarized** (no Apple Developer account — §3a is now measured, not predicted). The licence is MIT (`LICENSE`; the v0.1.0 EULA is preserved at `docs/EULA-v0.1.0.md`).

---

## 0. Prerequisites

**Build (both platforms):**
- **Zig 0.16.0** (exact — the backend gate asserts it).
- The workspace builds the shared core (`backend/`, a static lib) once per platform, then each frontend links it.

**macOS build:** Xcode / Swift 6 toolchain. `bash apps/macos/scripts/assemble-app.sh` produces the `.app`.

**Linux/GTK build:** GTK4 ≥ 4.20 + libadwaita ≥ 1.8 (Flatpak provides these via the GNOME runtime; the CI gate uses a pinned `fedora:43` container). For Flatpak: a Linux box with `flatpak` + `flatpak-builder` and the `org.gnome.Platform`/`org.gnome.Sdk` runtimes installed.

**macOS publishing (NOT set up — required before a wide release):**
- Apple Developer account (~$99/yr) + a **"Developer ID Application"** certificate in the login keychain.
- Notarization credentials: Apple ID + app-specific password + Team ID (or a `notarytool` keychain profile).

**Linux publishing:** either a **Flathub** account + GitHub (for the Flathub submission), **or** web hosting to self-serve a `.flatpakref`/repo (the landing page at `site/index.html` can host it).

---

## 1. Versioning

**The version has exactly one home: `VERSION` at the workspace root.** One line, **semver**
`MAJOR.MINOR.PATCH`, currently `0.1.0` (the semver spelling of the `0.1` the macOS bundle
already claimed; change it to `1.0.0` when v1 ships — it is a one-line edit, which is the point).
Bumping a release means editing that one file and nothing else.

Every consumer *reads* it; none re-types it:

| Consumer | How it reads `VERSION` | State |
|---|---|---|
| GTK build (`apps/gtk/meson.build`) | `project(version : files('VERSION'))`, where `apps/gtk/VERSION` is a **symlink** to the root file — the same pointer-never-a-copy idiom as `apps/gtk/include/lesssheet.h` → `api/lesssheet.h`. `meson.project_version()` is then the single resolver inside that build. | **Done** |
| GTK About dialog | `meson.build` passes the resolved version to `main.c` as `-DLSG_VERSION`; nothing is typed in C. | **Done** |
| macOS bundle (`apps/macos/Bundle/Info.plist`) | Still a hand-typed `CFBundleShortVersionString`. | **To do** — below |
| `tools/release/make_release` | Still reconciles the plist against `meson.build` and warns when they disagree (`resolve_version`). | **To do** — below |
| Git tag / download URLs | The release tag is `v$(cat VERSION)`; every GitHub Releases URL on the landing page derives from that tag (`ARCH-frontpage` §6) — never hand-typed. | Applies at publish |

Each release is a git tag `vX.Y.Z` on the release commit, where `X.Y.Z` is `VERSION`'s content.

### 1a. The two remaining consumers (specified, not yet done)

Both live outside `apps/gtk` and are deliberately left to a separate pass; until they land,
`make_release` will keep printing its "version is not single-sourced" warning, which is **true**
(the plist still says `0.1`, the root file says `0.1.0`) and should stay until it isn't.

1. **macOS bundle.** Put a placeholder in `Info.plist` — `CFBundleShortVersionString` =
   `__LESSSHEET_VERSION__` — and have `apps/macos/scripts/assemble-app.sh` substitute
   `$(cat "$REPO/VERSION")` into the copy it lays into the bundle (it already copies the plist, so
   this is one `sed` on the copy; the in-repo file must keep the placeholder or the number is
   duplicated again). Leave `CFBundleVersion` (the build counter, `1`) alone — it is a different
   fact from the marketing version. Note `apps/macos` is its own aidev component with its own
   frozen paths: route this through that component's planner.
2. **`make_release`.** Replace `resolve_version()`'s two-place reconciliation with a read of the
   root `VERSION` (still honouring `--version` as an override), and delete the disagreement
   warning along with it — there is nothing left to disagree. It should fail loudly if `VERSION`
   is missing or is not `MAJOR.MINOR.PATCH`, rather than defaulting to `0.0.0`.

Renaming the artifacts is a consequence worth expecting: the built files become
`less-sheet-0.1.0-…` rather than the `less-sheet-0.1-…` recorded in `ARCH-frontpage` §2. Nothing
is published yet, so no URL breaks.

---

## 2. Build the release artifacts

**Scripted path (use this):**
```
tools/release/make_release                       # everything this host can build
tools/release/make_release --platform mac
tools/release/make_release --platform linux --arch x86_64
```
It builds the ReleaseSafe core, assembles + seals the macOS `.app`, cross-builds and
container-builds the Linux binaries, packages all of it into `dist/`, writes `SHA256SUMS` +
`manifest.json` (which records each artifact's runtime requirements), and **verifies every
artifact by running it** — the macOS app through the `LESSSHEET_*` probe harness, the Linux
tarball inside a clean `fedora:43` container that has only the app's runtime dependencies and
no compiler. It never uploads, notarizes, or submits anything. `dist/` is gitignored.

Two guards worth knowing about, because both have bitten this project:
- **Stale core:** SwiftPM does not track `liblesssheet.a`, so a green build is not evidence the
  binary contains the current core. The script asserts `backend/src/*.zig` → `liblesssheet.a` →
  app-binary mtime ordering and fails loudly rather than shipping a stale link.
- **Seal-invalidating packaging:** it re-verifies `codesign --verify --strict` on the app
  *unpacked from the finished artifact*, not on the build tree, because anything that writes into
  a bundle after signing silently breaks it.

The manual steps below remain accurate and are what the script automates.

### 2a. Shared core (built once per platform, linked by both frontends)
Ship mode is **ReleaseSafe** (per `docs/architecture/PROJECT.md` Build & gate — safety on; `@setRuntimeSafety(false)` only on bench-justified hot loops). After #41 lands, the frontends' build scripts build ReleaseSafe automatically; to build by hand:
```
cd backend && zig build -Doptimize=ReleaseSafe
```

### 2b. macOS `.app`
```
bash apps/macos/scripts/assemble-app.sh
# → apps/macos/.build/<triple>/release/less-sheet.app
#   (rebuilds the ReleaseSafe core, force-relinks it — avoids the stale-.a hazard — and lays out the bundle)
# → apps/macos/.build/<triple>/release/less-sheet.dSYM
#   (the executable ships stripped of local symbols; this symbolicates its crash reports.
#    It embeds the build machine's source paths: keep it, never ship it — make_release
#    files it under private/dsyms/<version>/)
```
Bundle facts: `CFBundleIdentifier = com.lesssheet.app`, `CFBundleName = less-sheet`, executable `LessSheet`, `LSMinimumSystemVersion = 26.0` (macOS 26 — corrected from 15.0 on 2026-08-05, see the note at the top of this doc).

### 2c. GTK/Linux
`make_release --platform linux` handles this: it cross-builds the core with Zig (native, no
container) and builds the GTK frontend in an arch-suffixed copy of the gate's `fedora:43`
toolchain image, then verifies the tarball in a clean container.

**Architecture note.** The Zig core cross-compiles to any target from any host, but the *GTK
frontend* links the system GTK4/libadwaita and so needs a real userland of the target
architecture. On an Apple Silicon Mac the x86_64 leg therefore runs under emulation — which
turned out to be cheap, not the feared multi-hour wait: the x86_64 toolchain image built in
about 7 minutes (vs ~5 native for aarch64), and `meson setup` inside it resolves GTK 4.20.4 /
libadwaita 1.8.6 normally. Emulation is a viable route.

> **BLOCKER — x86_64 Linux cannot be built today (found 2026-08-05).** Not an emulation problem.
> The x86_64 core archive references `__zig_probe_stack` without defining it (`nm`: 1 undefined,
> 0 defined), so linking the GTK app with gcc/`ld.bfd` fails. **aarch64 is unaffected** — it
> emits no stack probes, so the symbol is neither referenced nor needed (`nm`: 0 and 0), which is
> why this never surfaced before: the gate and the GUI runs only ever built aarch64, and
> `ARCH-backend-linux-portability`'s verified Linux path was musl + lld, which does not expose it.
> **Fix:** bundle compiler-rt into the static library in `backend/build.zig` (confirmed:
> `zig build-lib -fcompiler-rt` *defines* the symbol, `-fno-compiler-rt` does not).
> `backend/build.zig` is a frozen `DEPENDENCY_PATH`, so this needs a **CHANGE-REQUEST** through
> the planner — it is deliberately not patched here. `make_release` pre-flights the archive and
> skips the arch with this explanation rather than emitting a wall of linker errors.

To produce the x86_64 tarball natively in minutes on an x86_64 Linux box instead, do there what
the script does in the container — the recipe is identical because the staging layout is the same
one `make_release` stages:

```
# on the Mac: cross-build the core for the target and copy the tree over
cd backend && zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe --prefix /tmp/core
# ship apps/gtk (dereference include/lesssheet.h, it is a symlink to api/) plus
# /tmp/core/lib/liblesssheet.a into <stage>/.core-linux/lib/, then on the Linux box:
meson setup build --buildtype=release && meson compile -C build && strip build/less-sheet-gtk
```
Then package `less-sheet-gtk` + the `.desktop` + the icon + `install.sh` exactly as the script
does. Requires GTK4 ≥ 4.20 + libadwaita ≥ 1.8 + meson/ninja/gcc on that box (the same floors
`apps/gtk/.ci/Dockerfile` pins).

For distribution, §4's Flatpak is still the better answer for Linux than any tarball.

---

## 3. Publish v1 — macOS

### 3a. Current path (AD-HOC SIGNED, NOT NOTARIZED — measured 2026-08-05)

`tools/release/make_release --platform mac` produces the `.zip` and `.dmg`, and proves the
packaged app runs. There are **three distinct states** here; keeping them apart matters,
because two of them look like "the app is broken" and only one is actually a Gatekeeper issue.

| State | What happens | Fixed? |
|---|---|---|
| **Unsealed bundle** (before 2026-08-05) | macOS refuses to launch it *even locally, with no download involved*: **"damaged and can't be opened … move it to the Trash"**. `spctl --assess` reports `code has no resources but signature indicates they must be present`; `syspolicy_check distribution` grades it **Fatal**. | **Yes** — `assemble-app.sh` now seals the bundle. |
| **Ad-hoc sealed, not quarantined** (today, local builds) | Launches and runs normally. `codesign --verify --strict` → *valid on disk*, *satisfies its Designated Requirement*. | n/a — this is the working state. |
| **Ad-hoc sealed, quarantined** (today, a real download) | **Gatekeeper blocks it.** `spctl --assess` → `rejected`; `syspolicy_check distribution` → *Notary Ticket Missing* (Fatal) + *adhoc signed … not suitable for distribution* (Warning). Directly exec'ing the binary is SIGKILLed. | **No** — needs §3b. |

**What a first-time downloader sees, and what they must do.** The app is quarantined, ad-hoc
signed and unnotarized, so Gatekeeper blocks the first launch and offers no in-dialog override.
The user has to open **System Settings → Privacy & Security**, find the blocked app, and press
**"Open Anyway"**. Note the old **right-click → Open** trick that this doc used to recommend
**no longer works**: Apple removed that bypass in macOS 15 Sequoia, and our floor is now macOS 26,
so every user is past that change. `xattr -dr com.apple.quarantine <app>` also works but asking
people to run a Terminal command to open a spreadsheet viewer is a worse first impression than
the Settings route.

> Ad-hoc signing needs no certificate, no Apple account and no network — it is a *packaging
> correctness* step, not a distribution step. It fixes the "damaged" failure and nothing else.
> It does **not** get a downloaded app past Gatekeeper; only §3b does.

If shipping unsigned anyway, the download page must say plainly that the app is not yet
notarized and give the Privacy & Security steps — the frontpage's no-dead-links rule extends to
no-dead-ends.

### 3b. Signed + notarized path (recommended — needs the Apple Developer account)
Once you have a Developer ID Application cert + notarytool creds:
```
APP="apps/macos/.build/<triple>/release/less-sheet.app"
# 1. Sign with hardened runtime (Developer ID)
codesign --force --deep --options runtime --timestamp \
  --sign "Developer ID Application: <NAME> (<TEAMID>)" "$APP"
# 2. Package (DMG via create-dmg or hdiutil, or a zip for notarization)
ditto -c -k --keepParent "$APP" less-sheet.zip
# 3. Notarize + wait
xcrun notarytool submit less-sheet.zip \
  --apple-id "<APPLE_ID>" --team-id "<TEAMID>" --password "<APP_SPECIFIC_PW>" --wait
# 4. Staple the ticket to the .app, then re-package as the DMG you ship
xcrun stapler staple "$APP"
# 5. Build the shippable DMG (hdiutil create / create-dmg) and staple the DMG too
```
- Verify before shipping: `codesign -dv --verbose=4 "$APP"` (Authority = Developer ID) and `spctl -a -vvv "$APP"` (accepted).
- When ready, ask the orchestrator to generate a parameterized `apps/macos/scripts/package-macos.sh` that wraps steps 1–5 (identity + creds via env/args). **Not written yet — nothing is signed here.**

---

## 4. Publish v1 — Linux (Flatpak → Flathub)

### 4a. LGPL note (why Flatpak)
GTK4/libadwaita/GLib are LGPL and **dynamically linked** (`dependency()` in `meson.build`). Flatpak provides them from the `org.gnome.Platform` runtime (dynamic, swappable) — which inherently satisfies LGPL's relink requirement, so **the app is compliant** as long as we ship the notices (`THIRD-PARTY-NOTICES.md`) and don't statically bundle GTK. (AppImage would bundle GTK and make LGPL compliance manual — that's why Flatpak is chosen.)

### 4b. The app-id (settled 2026-08-05)
The app-id is **`com.lesssheet.LessSheet`** (the author's decision; aligns with the macOS
`com.lesssheet.app`). Flatpak requires that the `GApplication`/`AdwApplication` id, the `.desktop`
file name and the AppStream metainfo file name all agree with it.

Already consistent in the GTK component: `adw_application_new(LSG_APP_ID, …)`, the window and
About `icon-name`, the embedded icon `data/com.lesssheet.LessSheet.svg`, and the GResource path
`/com/lesssheet/LessSheet/icons/scalable/apps`. `main.c` holds the id as a single `#define
LSG_APP_ID` (plus `LSG_ICON_RESOURCE_PATH`, the same string with `.` → `/`), so these cannot drift
apart; `data/lesssheet.gresource.xml` is the one place that must be renamed in step, because XML
cannot read a `#define`, and it says so in a comment. **Watch out:** an id/icon-name/resource-path
mismatch produces no build error at all — the window icon just silently disappears.

Still to create (§6): `com.lesssheet.LessSheet.desktop` and
`com.lesssheet.LessSheet.metainfo.xml`. `make_release` already generates a `.desktop` for the
Linux tarball, but from its own `GTK_APP_ID` constant, which still reads `dev.lesssheet.Gtk` —
**it must be updated to `com.lesssheet.LessSheet` before any Linux artifact ships**, or the
installed desktop entry points `Icon=` at a name the app no longer provides.

### 4c. Flatpak build (local)
A manifest `com.lesssheet.LessSheet.yaml` roughly:
- `runtime: org.gnome.Platform`, `runtime-version: '49'` (matches libadwaita 1.8 / GNOME 49), `sdk: org.gnome.Sdk`.
- An `org.freedesktop.Sdk.Extension.ziglang` (or a bundled Zig) to build the core, then meson-build the GTK app and link the core.
- `finish-args`: `--filesystem=host:ro` (open local CSVs read-only), `--share=network` (network URLs), `--socket=wayland`/`--socket=fallback-x11`.
Build + test locally:
```
flatpak-builder --force-clean --repo=repo build-dir com.lesssheet.LessSheet.yaml
flatpak-builder --run build-dir com.lesssheet.LessSheet.yaml less-sheet   # smoke-run
flatpak build-bundle repo less-sheet.flatpak com.lesssheet.LessSheet       # self-host artifact
```
> The orchestrator can draft this manifest, but it must be **built + smoke-tested on your Linux box** (flatpak-builder isn't available on the macOS dev host). **Not written yet.**

### 4d. Publish
- **Flathub (recommended, widest reach + auto-updates):** fork `flathub/flathub`, add `com.lesssheet.LessSheet.yaml` + the metainfo, open a PR, pass their review. After merge it's published and auto-built on updates. Needs your GitHub/Flathub account.
- **Self-host:** host the `repo/` (or the `.flatpak` bundle + a `.flatpakref`) from `site/`; users add the remote + install.

---

## 5. Shipping updates — two commands

A bugfix release is two scripts, one push and one rsync. Everything below §5 describes
what they do; you should not need to perform those steps by hand.

```sh
# on the Mac — builds, verifies, stamps, commits, tags. Publishes nothing.
tools/release/cut 0.1.1
git push origin master --tags

# dist/ is gitignored, so the artifacts do NOT travel with the repo
rsync -av dist/ <linux-box>:~/Projects/less-sheet/dist/   # into the clone: publish.sh reads ./dist

# on the Linux box (a plain clone of the repository) — releases, builds the
# Flatpak bundle, updates the tap, and verifies all of it logged out. The page
# deploys itself from the push (.github/workflows/deploy-site.yml).
cd ~/Projects/less-sheet && git pull --tags && tools/release/publish.sh
```

**Why two scripts.** The Mac is the only machine with the Swift toolchain (and it
runs the Linux build in podman), and it deliberately has no GitHub remote. The
Arch box talks to GitHub and cannot build the macOS app. One script would have
to pretend a single machine does both.

**What `cut` does:** refuses a dirty tree or an existing tag → runs the root gate
→ bumps `VERSION` → `make_release` (which runs every artifact it builds) →
`tools/release/stamp` → commits and tags. All local, all revertible.

**What `stamp` does, and why it exists.** `VERSION` is single-sourced for
everything that can *read* it at build time. It cannot serve what carries a
literal: download URLs on a static page, digests in a cask, Flatpak manifests
fetched by a stranger's machine. That is 21 literals across three files plus six
digest/size pairs per build. `stamp` rewrites them **and then greps for the old
version and fails if any survived** — the check is the point, because a missed
link 404s for everyone except you and nothing else complains. The metainfo is
append-only and handled separately: its `<release>` entries are a changelog, so
0.1.0 must still say 0.1.0 after 0.1.1 ships.

**What `publish.sh` does:** verifies `dist/` actually arrived and its bytes match
`SHA256SUMS` (a stale rsync is the quiet failure this split invites) → pushes
source and tag → creates the release → builds and uploads the Flatpak bundle →
updates the tap → checks **logged out** that every asset returns 200 → polls
until the live page names the new version.

**Still manual, by choice:** release notes (`dist/NOTES-<ver>.md`, else a
one-liner is generated), and Flathub, which is a PR against `flathub/flathub`.

Keep a `CHANGELOG.md` (recommended) so release notes are single-sourced.

---

## 6. Files that must ship / live in the repo

- **`THIRD-PARTY-NOTICES.md`** — the LGPL notices for GTK4/libadwaita/GLib + the MIT notice for the Zig standard library. **Drafted** (companion to this doc); keep it current as deps change.
- **`LICENSE`** — MIT, copyright te-x. The macOS bundle ships it in `Contents/Resources`; the Flatpak metainfo declares it. The v0.1.0 EULA that preceded it is preserved at `docs/EULA-v0.1.0.md` for the record.
- **`com.lesssheet.LessSheet.metainfo.xml`** (AppStream) + `.desktop` — required for Flathub; needed for Linux desktop integration.

---

## 7. GitHub: one public repository — a walkthrough

Everything lives in **`te-x/less-sheet`**: the source, the Releases (every download URL), the Issues,
and the landing page (GitHub Pages, deployed from `site/` by `.github/workflows/deploy-site.yml`).
Two small satellites: **`te-x/homebrew-tap`** holds the cask (§7.5), and **`te-x/less-sheet-site`**
exists only to forward the old page address — see `tools/release/site-redirect/README.md`.

### 7.1 Why one repository, and why public

Repository visibility is **one switch that governs Releases, Issues and Pages together**. A private
repository serves release assets from temporary *authenticated* URLs (`brew` and the `curl` one-liner
cannot authenticate, so both install routes in §3a break by construction), lets only collaborators file
issues, and on a Free account does not publish Pages at all — GitHub's own wording: *"If the account that
owns the repository uses GitHub Free or GitHub Free for organizations, the repository must be public."*

The source is MIT, so there is nothing a second repository would protect, and one repository means one
place for downloads, bug reports and the page: the name a user sees in a download URL is the repository
they can read. The whole development record — `.aidev/`, `review/`, `docs/architecture/` — is published
with it, on purpose; write those files knowing that.

### 7.2 Settings, once

- Visibility **public**. **Settings → Pages → Source: GitHub Actions** — the workflow deploys `site/` on
  every push that touches it (and on manual dispatch). The page appears at
  `https://te-x.github.io/less-sheet/`.
- **Issues on; Wikis and Projects off**, so feedback has exactly one place to land.
- The tap repository must be public too: `brew` fetches it unauthenticated.

### 7.3 A release — build locally, publish by script

`tools/release/cut` on the Mac, `tools/release/publish.sh` on the Linux box (§5). What `publish.sh`
does, in order: pushes the release commit and tag, runs `gh release create vX.Y.Z --repo te-x/less-sheet`
with the macOS dmg/tar.gz/zip, the Linux tarballs and `SHA256SUMS`, builds and uploads the Flatpak
bundle, updates the tap, then **proves the URLs are public** — the failure that silently breaks Homebrew
and the one-liner for everyone but you:

```sh
curl -fsSLI -o /dev/null -w '%{http_code}\n' \
  "https://github.com/te-x/less-sheet/releases/download/v$(cat VERSION)/SHA256SUMS"
# 200 = public. 404 while logged out = the release is still a draft, or the repo is private.
```

Check it **logged out** (a private browser window, or `curl` with no credentials). A logged-in check
passes even when the asset is private.

### 7.4 The landing page on Pages

`site/index.html` is the page, committed with its real download URLs (they point at this repository's
Releases; `tools/release/stamp` moves the version across the page, the manifests and the cask together,
then proves nothing was missed — §1's rule, never hand-typed). The workflow uploads `site/` as the Pages
artifact and deploys it; there is no copy step and no deploy token. A custom domain would go in the Pages
settings plus a `CNAME` file in `site/`.

### 7.5 The Homebrew tap

Full steps are in `packaging/homebrew/README.md`. Two things that matter here: the tap repo must be
**public** (brew fetches it unauthenticated), and the cask's `sha256` must come from `dist/SHA256SUMS`
via `make_release --cask-base`, never typed. A wrong digest still installs fine for you — your Homebrew
has the file cached — and fails for every user after you.

### 7.6 If you later want CI to build

Not first, and here is the honest reason: `make_release` already builds **and verifies by running** —
macOS launches the unpacked app headlessly and requires the real rows-are-visible marker, and Linux runs
inside a clean `fedora:43` container carrying only the declared runtime deps, which proves the binary
works on a machine that never built it. A GitHub runner does not check anything stronger.

A public repository's Actions minutes are free, so cost is not the argument it was; correctness is. When
you do add CI, add the **Linux** leg first — it is the platform you cannot conveniently build on the Mac
anyway. A release job in this repository needs no personal token: the workflow's own `GITHUB_TOKEN` with
`contents: write` can create releases and upload assets.

### 7.7 Things that will bite

- **A draft or private release asset is not a download link.** If `curl` on the release URL returns 404
  while logged out, Homebrew and the one-liner are broken for everyone, and you will not notice, because
  you are logged in.
- **Pages needs a public repo on Free** (quoted above). The old address forwards only once the new page
  is live — flip `less-sheet-site` to the redirect files *after* `https://te-x.github.io/less-sheet/`
  answers, not before.
- **Old direct download links cannot be forwarded.** GitHub Pages has no HTTP redirects, and release
  URLs are not Pages. Links to `github.com/te-x/less-sheet-site/releases/...` keep working only while
  that repository still carries the release; the page itself points at this repository.
- **LGPL: stay compliant.** GTK and libadwaita are LGPL and **dynamically linked** — the Linux build
  uses the *system* libraries ("no bundled GTK" is in the release README) and the Flatpak takes them
  from the `org.gnome.Platform` runtime. Bundling GTK into the binary to simplify distribution would be
  the change that creates a licence problem. §4a has the longer note.

---

## Appendix — current gaps / TODO before a real launch
- [x] Single-source the version — root `VERSION`, read by the GTK build (§1).
- [ ] Convert the last two version consumers: the macOS `Info.plist` and `make_release` (§1a).
- [x] Confirm/set the reverse-DNS app-id: `com.lesssheet.LessSheet` (§4b).
- [ ] Update `make_release`'s `GTK_APP_ID` to the new id before any Linux artifact ships (§4b).
- [ ] Security hardening #41 landed (publish the hardened build).
- [ ] macOS: Apple Developer account → switch from unsigned (§3a) to signed+notarized (§3b).
- [x] Licence: MIT (`LICENSE`); the v0.1.0 EULA preserved at `docs/EULA-v0.1.0.md` (§6).
- [ ] Draft + Linux-test the Flatpak manifest (§4c); add metainfo + .desktop.
- [ ] Decide Flathub vs self-host (§4d).
- [x] The ARCH non-goal "Never publish this workspace" was amended; the workspace has a remote and is published in full (§7.1).
- [ ] One public repository: visibility public, Pages from GitHub Actions, Issues on (§7.2); `less-sheet-site` reduced to the forwarding files (`tools/release/site-redirect/`).
- [ ] First release published, and the asset URL verified **logged out** (§7.3).
- [ ] Pages serving `site/` from this repository via the workflow; the old address forwards (§7.4, §7.7).
- [ ] Homebrew tap published, digest taken from `SHA256SUMS` (§7.5).
