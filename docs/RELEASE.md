# less-sheet — Build & Release Runbook

**Purpose:** how to build the app, publish the first version, and ship updates — for the author (who executes) and the orchestrator (who can later script it). **Nothing here has been run.** No artifact is signed, notarized, packaged, or uploaded yet.

> **Status (2026-07-23):** Pre-launch. macOS ships **unsigned** (no Apple Developer account yet). The security-hardening program (#41) is in flight — **publish the hardened build, not today's.** The version is not yet single-sourced (macOS `CFBundleShortVersionString = 0.1`, GTK `meson project version = 0.0.0` — reconcile before v1, see §1). GTK/Flatpak app-id must be confirmed (see §4). EULA not yet written (§6).

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
Built via Meson (see the CI gate for the container recipe), or — preferred for distribution — via the Flatpak manifest in §4.

---

## 3. Publish v1 — macOS

### 3a. Current path (UNSIGNED — interim, until the Apple account exists)
- Zip the `.app` (or make a plain DMG) and put it on the download page.
- **Document the Gatekeeper bypass** for users (an unsigned app won't open by double-click on macOS 15):
  - Right-click the app → **Open** → **Open** in the dialog; **or**
  - `xattr -dr com.apple.quarantine /Applications/less-sheet.app`
- This is a rough first impression — treat it as interim; prioritize the signed path for any real launch.

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
