# Third-Party Notices

less-sheet is a closed-source application. It links the third-party components below. This file must ship with the distributed application (in the bundle/package and/or on the download page). Keep it in sync as dependencies change.

> Applicability: the **GTK/GNOME** components apply to the **Linux/GTK** build only. The **macOS** build uses Apple system frameworks (AppKit/Swift runtime), which require no third-party notice. Both builds link the Zig-compiled core (our own code) whose standard-library portions are covered by the Zig notice below.

---

## GTK 4 — LGPL-2.1-or-later
Copyright © the GTK contributors. Dynamically linked (not modified, not statically bundled).
Source & license: https://gitlab.gnome.org/GNOME/gtk — GNU Lesser General Public License, version 2.1 or later.

## libadwaita — LGPL-2.1-or-later
Copyright © the libadwaita contributors. Dynamically linked (not modified).
Source & license: https://gitlab.gnome.org/GNOME/libadwaita — GNU Lesser General Public License, version 2.1 or later.

## GLib / GObject / GIO — LGPL-2.1-or-later
Copyright © the GLib contributors. Dynamically linked (not modified).
Source & license: https://gitlab.gnome.org/GNOME/glib — GNU Lesser General Public License, version 2.1 or later.

> The three components above pull in the wider GNOME/GTK stack (Pango, Cairo, GdkPixbuf, HarfBuzz, etc.), each under its own free-software license (LGPL / MPL-2.0 / MIT-style). In the shipped Flatpak these are provided dynamically by the `org.gnome.Platform` runtime and are neither modified nor statically bundled. Their full license texts are available in the runtime and in each project's repository.

## Zig standard library — MIT
Copyright © Zig contributors. Portions of the Zig standard library are compiled into the less-sheet core.
Source & license: https://github.com/ziglang/zig — MIT License.

---

### LGPL compliance summary
The LGPL-licensed libraries (GTK 4, libadwaita, GLib) are used **unmodified** and linked **dynamically**. On Linux they are supplied by the Flatpak `org.gnome.Platform` runtime (or the system), so a user can replace them with a modified version — satisfying the LGPL relink requirement without any source disclosure of less-sheet's own (closed) code. If a future build statically bundles any LGPL library, this section and the distribution method must be revisited to preserve that relink right (e.g. by providing linkable object files).

*Full license texts (LGPL-2.1, MIT) should be included alongside this file in the shipped package.*
