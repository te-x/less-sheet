project('less-sheet-gtk', 'c',
  version : '0.0.0',
  meson_version : '>= 1.0',
  default_options : ['c_std=c11', 'warning_level=2', 'werror=true'],
)

cc = meson.get_compiler('c')

# GNOME stack. Minimum versions are the ARCH decision-7 floor (GTK 4.16 /
# libadwaita 1.6 — the AdwStyleManager accent-color API). include_type:'system'
# emits -isystem for these third-party headers so their own warnings do not
# trip -Werror on our code.
gtk_dep  = dependency('gtk4',         version : '>= 4.16', include_type : 'system')
adw_dep  = dependency('libadwaita-1', version : '>= 1.6',  include_type : 'system')
glib_dep = dependency('glib-2.0',                          include_type : 'system')

# The Zig core, cross-built to this container's arch (glibc target) and placed
# under .core-linux/lib/ by the gate (see .aidev/profile.sh) BEFORE meson runs.
# Linked here as a prebuilt static archive.
core_dir = meson.current_source_dir() / '.core-linux' / 'lib'
core_dep = cc.find_library('lesssheet', dirs : [core_dir], static : true)

# The frozen cross-component ABI (include/lesssheet.h — a symlink to the single
# source of truth ../../api/lesssheet.h, never a copy) AND the frontend's own
# frozen module headers (include/lsg_*.h) both live under include/.
core_inc = include_directories('include')

# ---------------------------------------------------------------------------
# Slice 1 frontend logic modules (contract in include/lsg_*.h). Display-free C
# built once into a static library and linked into the app + every test binary.
# Compiling this under -Werror is the CONFORMANCE gate: the module sources must
# match the frozen headers exactly or the build fails.
# ---------------------------------------------------------------------------
lsg_sources = files(
  'src/lsg_document.c',
  'src/lsg_net_open.c',
  'src/lsg_formatter.c',
  'src/lsg_grid_geometry.c',
  'src/lsg_window_poll.c',
)
lsgkit = static_library('lsgkit',
  lsg_sources,
  dependencies : [glib_dep],
  include_directories : core_inc,
  install : false,
)

# App: hosts the slice-1 modules over the GTK4 + libadwaita toolchain and links
# the core archive. Compiled by the gate but NOT run there (needs a display —
# that is the human GUI pass). The real grid/chrome is authored during build.
executable('less-sheet-gtk',
  'src/main.c',
  dependencies : [gtk_dep, adw_dep, glib_dep, core_dep],
  link_with : lsgkit,
  include_directories : core_inc,
  install : false,
)

# Behavior tests: display-free g_test binaries (glib only, no GTK) linked
# against the modules and the core archive. Run in-container by `meson test`.
test_deps = [glib_dep, core_dep]

# Bootstrap linkage test (kept): proves the core links and is callable over the
# C ABI. The fixture path is baked in and resolves inside the container.
fixture = meson.current_source_dir() / 'tests' / 'fixtures' / 'tiny.csv'
test_core_link = executable('test-core-link',
  'tests/test_core_link.c',
  dependencies : test_deps,
  include_directories : core_inc,
  c_args : ['-DFIXTURE_PATH="' + fixture + '"'],
  install : false,
)
test('core-link', test_core_link)

# Document session (over the real core; needs the tiny fixture path).
test_document = executable('test-document',
  'tests/test_document.c',
  dependencies : test_deps,
  link_with : lsgkit,
  include_directories : core_inc,
  c_args : ['-DFIXTURE_PATH="' + fixture + '"'],
  install : false,
)
test('document', test_document)

# Network-open reducer + drive (synthetic snapshots + real-ABI scheme reject).
test_net_open = executable('test-net-open',
  'tests/test_net_open.c',
  dependencies : test_deps,
  link_with : lsgkit,
  include_directories : core_inc,
  install : false,
)
test('net-open', test_net_open)

# Cell formatter engine (pure; kind gate + lossless decimal + locale glyphs).
test_formatter = executable('test-formatter',
  'tests/test_formatter.c',
  dependencies : test_deps,
  link_with : lsgkit,
  include_directories : core_inc,
  install : false,
)
test('formatter', test_formatter)

# Grid geometry / window math (pure; row/column windows + scrollbar mapping).
test_grid_geometry = executable('test-grid-geometry',
  'tests/test_grid_geometry.c',
  dependencies : test_deps,
  link_with : lsgkit,
  include_directories : core_inc,
  install : false,
)
test('grid-geometry', test_grid_geometry)

# Window-poll decision (pure).
test_window_poll = executable('test-window-poll',
  'tests/test_window_poll.c',
  dependencies : test_deps,
  link_with : lsgkit,
  include_directories : core_inc,
  install : false,
)
test('window-poll', test_window_poll)
