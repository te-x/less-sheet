# Flatpak — how to build and publish it

The manifest is `com.lesssheet.LessSheet.yaml`. It must be built on Linux;
`flatpak-builder` does not run on macOS, so this is the one release artifact the
Mac cannot produce.

## Why this manifest downloads a binary

The app needs Zig 0.16.0 exactly, which no Flathub SDK carries, and the release
pipeline already builds the tarball and verifies it by running it. So the
manifest ships that binary rather than rebuilding it: `extra-data` carries only
metadata, and the **user's machine** fetches the tarball from the release page
at install time, refusing to proceed unless the `sha256` and `size` match
exactly. The source is MIT, so a from-source manifest (a Zig SDK extension plus
this repository as the source) is possible later; it has not been written.

That means the Flatpak we self-host today and a future Flathub submission are
**the same manifest**. There is no throwaway step here.

## Why a Flatpak at all

The plain tarball needs GTK 4.20 and libadwaita 1.8 *from the distribution*,
which is why it cannot run on Debian 13. `org.gnome.Platform` 49 carries exactly
that pair, so the Flatpak runs regardless of what the host ships. That is the
whole reason it exists.

GTK and libadwaita come from the runtime, dynamically, and are not bundled —
which is what keeps the binary LGPL-compliant (`docs/RELEASE.md`
§4a). Do not "simplify" the manifest by vendoring them.

## Build and test

```sh
# once per machine
sudo pacman -S flatpak flatpak-builder            # Arch
flatpak remote-add --if-not-exists --user flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user flathub org.gnome.Platform//49 org.gnome.Sdk//49

# build, install into the user's own flatpak, and run
cd packaging/flatpak
flatpak-builder --force-clean --user --install build-dir com.lesssheet.LessSheet.yaml
flatpak run com.lesssheet.LessSheet
```

The runtime and SDK are a couple of gigabytes on first install and are shared
with every other Flatpak on the machine afterwards.

## What to check once it starts

The build proving nothing about the binary is the trap here — `extra-data` is
downloaded and unpacked at **install** time, so a manifest can build perfectly
and still install an app that cannot start.

- it launches at all (the runtime's GTK is a different build than the one it was
  compiled against)
- open a local `.csv`, and a `.csv.gz`
- open an `https://` URL — this exercises `--share=network`
- the window carries its icon, and the app appears in the desktop's launcher
  with a name rather than as a raw app id

## Publishing without Flathub — use the Bundle manifest

**`com.lesssheet.LessSheet.yaml` cannot produce a bundle.** `flatpak
build-bundle` needs `xa.extra-data-sources` in the commit's *detached* metadata
and nothing produces it: the built app has an `[Extra Data]` section, the ostree
commit carries it as well, and the bundle still fails with

```
error: Failed to install bundle com.lesssheet.LessSheet: Extra data missing in detached metadata
```

Verified on flatpak 1.18.1. It stands to reason — extra-data is a promise to
download at install time, and a bundle exists so that nothing needs downloading.

So the bundle comes from **`com.lesssheet.LessSheet.Bundle.yaml`**, which embeds
the binary instead of promising it:

```sh
flatpak-builder --force-clean --repo=repo-bundle bundle-dir \
  com.lesssheet.LessSheet.Bundle.yaml
flatpak build-bundle repo-bundle less-sheet-<ver>-x86_64.flatpak com.lesssheet.LessSheet
```

Bundles are per-architecture: the file you get is for the machine you built on.

It installs with `flatpak install ./less-sheet-<ver>-x86_64.flatpak`, works
offline, and carries no auto-update — that is what Flathub buys.

## Which manifest for which channel

| channel | manifest | payload |
| --- | --- | --- |
| Flathub | `com.lesssheet.LessSheet.yaml` | `extra-data`, fetched by the user's machine |
| download button | `com.lesssheet.LessSheet.Bundle.yaml` | embedded at build time |

Flathub does not host binaries it did not build, so a prebuilt payload there
must be `extra-data`, fetched by the user's machine. A bundle **cannot** use it. Neither manifest
can serve the other channel, which is why both exist. Both pull the same tarball
by the same digest, so the two channels ship an identical binary, and the
`.desktop`, icon and metainfo are shared files that cannot drift.

## Updating for a new release

The payload is pinned by digest, so a new version is three edits: the `url`,
`sha256` and `size` of each `extra-data` block (both architectures), plus a new
`<release>` entry in the metainfo. `dist/SHA256SUMS` has the digests and
`stat -c %s` the sizes.
