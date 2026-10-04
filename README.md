# less-sheet

A viewer for very large CSV and local Parquet files, with native frontends for
macOS (Swift 6 / AppKit) and Linux (GTK4 + libadwaita) over a Zig engine.
Cold open through the first visible table has a target of **under 200 ms**.
Parquet opens from footer metadata and decodes only pages needed by the viewport;
CSV and CSV.gz also support HTTP(S).

Parquet supports flat scalar schemas, nullable values, dictionary and plain
encoding, data pages V1/V2, and Snappy, Zstandard, gzip, Brotli and LZ4 compression.
Schema names supply the headers. Nested/repeated schemas, encrypted files and
remote Parquet are not supported in this first implementation. Metadata and
page allocations are bounded; files exceeding those limits fail cleanly.

Website, screenshots and downloads: <https://te-x.github.io/less-sheet/>

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

Run build, format and test checks with `tools/check`. Select a component with
`tools/check backend`, `tools/check macos` or `tools/check gtk`. The core needs
Zig 0.16.0; macOS checks also need Swift and SwiftLint. GTK checks use a native
toolchain on Linux or the Fedora container through Docker/Podman.

**Engine** — needs zig 0.16.0 exactly:

```sh
cd backend
zig build        # → zig-out/lib/liblesssheet.a
zig build test   # behavior tests
zig build test-parquet-data # independent Parquet fixtures
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
