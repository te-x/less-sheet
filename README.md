# less-sheet

A no-nonsense viewer for very large CSV files: a Zig engine behind a frozen
C ABI, with native frontends for macOS (Swift 6 / AppKit) and Linux
(C / GTK4 + libadwaita). Opening is O(viewport), never O(file) — first rows
are on screen in well under 500 ms regardless of file size, for local files
and for files streamed over HTTP(S).

Website, screenshots and downloads: <https://te-x.github.io/less-sheet-site/>

## Layout

| Path         | What it is                                                    |
| ------------ | ------------------------------------------------------------- |
| `api/`       | The frozen, language-neutral C ABI between engine and frontends |
| `backend/`   | The engine — Zig 0.16.0, builds a static library               |
| `apps/macos/`| The macOS app — Swift 6, SwiftPM                               |
| `apps/gtk/`  | The Linux app — C, GTK4 + libadwaita                           |
| `packaging/` | Flatpak manifest, Homebrew cask, desktop entry                 |
| `site/`      | The landing page (deployed by the GitHub Action)               |

## Building

**Engine** — needs zig 0.16.0 exactly:

```sh
cd backend
zig build        # → zig-out/lib/liblesssheet.a
zig build test   # behavior tests
```

**macOS app** — build the engine first, then:

```sh
cd apps/macos
swift build -c release
bash scripts/assemble-app.sh   # assembles + ad-hoc-seals LessSheet.app
```

**Linux app** — needs GTK ≥ 4.20 and libadwaita ≥ 1.8 (see
`apps/gtk/.ci/Dockerfile` for the reference build environment). Meson expects
the engine archive under `apps/gtk/.core-linux/lib/`:

```sh
cd backend && zig build
mkdir -p apps/gtk/.core-linux/lib
cp backend/zig-out/lib/liblesssheet.a apps/gtk/.core-linux/lib/
cd apps/gtk && meson setup build && meson compile -C build
```

## License

MIT — see [LICENSE](LICENSE). Binaries of v0.1.0 were distributed under an
earlier proprietary EULA; releases after it ship under MIT.
