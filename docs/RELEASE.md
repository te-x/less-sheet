# less-sheet — Build & Release Runbook

**Purpose:** how to build the app, publish the first version, and ship updates — for the author (who executes) and the orchestrator (who can later script it).

> **Status (2026-08-05):** Pre-launch. **Building and packaging are now scripted and exercised**; publishing still is not. `tools/release/make_release` builds the macOS `.zip`/`.dmg` and the Linux `.tar.gz` (aarch64 + x86_64), verifies each artifact by **running it**, and writes `SHA256SUMS` + `manifest.json`. Nothing is uploaded, notarized, or submitted anywhere, and no Developer ID is used.
>
> Two defects were found and fixed while first exercising this path:
> - **The assembled `.app` was unsealed and macOS refused to launch it** — the user-visible symptom was *"damaged and can't be opened … move it to the Trash"*, which hit the author's own installed app. Cause: `assemble-app.sh` wrapped a linker-ad-hoc-signed executable in a bundle without ever sealing the bundle, so the signature claimed sealed resources that did not exist. `assemble-app.sh` now ad-hoc-seals the bundle as its last step and verifies with `codesign --verify --strict`. See §3a.
> - **`LSMinimumSystemVersion` claimed 15.0 while the binary requires macOS 26.0** (`Package.swift` targets `.macOS("26.0")` for Liquid Glass). A macOS 15 user would have been offered the app and then got a dyld failure instead of a clean "requires macOS 26" message. Corrected to 26.0.
>
> Still open: macOS ships **ad-hoc signed, not notarized** (no Apple Developer account — §3a is now measured, not predicted). The version is not single-sourced (macOS `CFBundleShortVersionString = 0.1`, GTK `meson project version = 0.0.0` — reconcile before v1, §1). The GTK app-id in the code is **`dev.lesssheet.Gtk`**, not the `com.lesssheet.LessSheet` this doc proposes in §4b — reconcile before any Flathub submission, because a published app-id is effectively permanent. EULA not yet written (§6).

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

## 1. Versioning (do this first — it's currently inconsistent)

- Adopt **semver** `MAJOR.MINOR.PATCH`; v1 = `1.0.0` (or `0.1.0` for a beta — your call).
- **Single-source it.** Today the version lives in two places that disagree: `apps/macos/Bundle/Info.plist` (`CFBundleShortVersionString`, `CFBundleVersion`) and `apps/gtk/meson.build` (`version:`). Pick one source of truth (e.g. a `VERSION` file at repo root read by both builds, or keep the two but bump them together via a release script) and reconcile them before tagging.
- Each release is a git tag `vX.Y.Z` on the release commit.

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
```
Bundle facts: `CFBundleIdentifier = com.lesssheet.app`, `CFBundleName = less-sheet`, executable `LessSheet`, `LSMinimumSystemVersion = 15.0` (macOS 15 Sequoia).

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
one `tools/gtk/run_gtk_on` already uses:

```
# on the Mac: cross-build the core for the target and copy the tree over
cd backend && zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe --prefix /tmp/core
# ship apps/gtk (dereference include/lesssheet.h, it is a symlink to api/) plus
# /tmp/core/lib/liblesssheet.a into <stage>/.core-linux/lib/, then on the Linux box:
meson setup build --buildtype=release && meson compile -C build && strip build/less-sheet-gtk
```
Then package `less-sheet-gtk` + the `.desktop` + the icon + `install.sh` exactly as the script
does. Requires GTK4 ≥ 4.20 + libadwaita ≥ 1.8 + meson/ninja/gcc on that box (`run_gtk_on`'s
install block installs precisely this set, and carries the same floors).

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
GTK4/libadwaita/GLib are LGPL and **dynamically linked** (`dependency()` in `meson.build`). Flatpak provides them from the `org.gnome.Platform` runtime (dynamic, swappable) — which inherently satisfies LGPL's relink requirement, so a **closed-source app is compliant** as long as we ship the notices (`THIRD-PARTY-NOTICES.md`) and don't statically bundle GTK. (AppImage would bundle GTK and make LGPL compliance manual — that's why Flatpak is chosen.)

### 4b. Confirm the app-id first
Flatpak needs a reverse-DNS app-id that matches the `GApplication`/`AdwApplication` id and a `.desktop` file — e.g. **`com.lesssheet.LessSheet`** (align with the macOS `com.lesssheet.app`). Confirm/set it consistently in: the GTK `application_new(...)` id, a `com.lesssheet.LessSheet.desktop`, a `com.lesssheet.LessSheet.metainfo.xml` (AppStream — required by Flathub), and the manifest below.

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

## 5. Shipping updates

1. Land the change; **bump the version** (§1) on a release commit; tag `vX.Y.Z`.
2. Rebuild artifacts (§2) from the tag.
3. **macOS:** re-sign → re-notarize → re-staple → new DMG (§3b); update the download link + checksum on `site/`.
4. **Flatpak:**
   - *Flathub:* open a PR bumping the manifest's source tag/commit (or Flathub auto-updates from a tracked commit) → it rebuilds + users auto-update.
   - *Self-host:* rebuild the repo (`flatpak-builder --repo=repo …`), push it; installed users get the update on `flatpak update`.
5. Update the landing page (`site/index.html`): version, download links, and a short **changelog** entry.
6. Keep a `CHANGELOG.md` (recommended) so release notes are single-sourced.

---

## 6. Files that must ship / live in the repo

- **`THIRD-PARTY-NOTICES.md`** — the LGPL notices for GTK4/libadwaita/GLib + the MIT notice for the Zig standard library. **Drafted** (companion to this doc); keep it current as deps change.
- **`LICENSE` / EULA** — the terms for the free, closed-source tool. **Not written — your call + legal review.** A minimal "free to use, provided as-is, no warranty, no reverse-engineering" grant is typical; the orchestrator can draft a starter template on request, but you own the final legal text.
- **`com.lesssheet.LessSheet.metainfo.xml`** (AppStream) + `.desktop` — required for Flathub; needed for Linux desktop integration.

---

## Appendix — current gaps / TODO before a real launch
- [ ] Reconcile + single-source the version (§1).
- [ ] Confirm/set the reverse-DNS app-id consistently (§4b).
- [ ] Security hardening #41 landed (publish the hardened build).
- [ ] macOS: Apple Developer account → switch from unsigned (§3a) to signed+notarized (§3b).
- [ ] Write the EULA/LICENSE (§6) + legal review.
- [ ] Draft + Linux-test the Flatpak manifest (§4c); add metainfo + .desktop.
- [ ] Decide Flathub vs self-host (§4d).
