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

# The frozen cross-component ABI. include/lesssheet.h is a symlink to the single
# source of truth, ../../api/lesssheet.h (never a copy — ARCH decision, matches
# apps/macos/Sources/CLessSheet).
core_inc = include_directories('include')

# Minimal app: proves the GTK4 + libadwaita toolchain compiles and links, and
# that the core archive is a valid link input. Compiled by the gate but NOT run
# there (needs a display — that is the human GUI pass).
executable('less-sheet-gtk',
  'src/main.c',
  dependencies : [gtk_dep, adw_dep, core_dep],
  include_directories : core_inc,
  install : false,
)

# One behavior test: proves the core links and is callable over the C ABI.
# Display-free (glib only, no GTK). The fixture path is baked in at compile time
# and resolves inside the container (the repo is mounted).
fixture = meson.current_source_dir() / 'tests' / 'fixtures' / 'tiny.csv'
test_core_link = executable('test-core-link',
  'tests/test_core_link.c',
  dependencies : [glib_dep, core_dep],
  include_directories : core_inc,
  c_args : ['-DFIXTURE_PATH="' + fixture + '"'],
  install : false,
)
test('core-link', test_core_link)
