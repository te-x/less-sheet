# less-sheet GTK frontend — pinned CI/gate image.
#
# aidev decision 6 + the 2026-07-17 ARCH amendment: the WHOLE gate (compile-level
# conformance AND behavior) runs inside a Linux GNOME container, because the dev
# Mac has no GTK/Meson toolchain. This image is that container.
#
# fedora:43 ships GTK 4.20 / libadwaita 1.8 / meson 1.8 / gcc 15 (GNOME 49) —
# the ARCH-gtk-a11y decision-7 floor (GTK 4.20 / libadwaita 1.8), required by
# AdwShortcutsDialog. Bumped fedora:42 -> fedora:43 by the gtk-a11y slice
# (ARCH-gtk-a11y decision 1, author-signed 2026-07-21); fedora:42 shipped only
# libadwaita 1.7, where AdwShortcutsDialog is absent. Explicit tag, NOT a
# floating 'latest'. Digest observed at authoring time (2026-07-21):
#   registry.fedoraproject.org/fedora@sha256:2ce3fd0750ad94453e589fcd48338217defa6e7de2fa5dede5b5be95182eea21
FROM fedora:43

RUN dnf -y install --setopt=install_weak_deps=False \
        gtk4-devel \
        libadwaita-devel \
        glib2-devel \
        meson \
        ninja-build \
        gcc \
        pkgconf-pkg-config \
 && dnf clean all
