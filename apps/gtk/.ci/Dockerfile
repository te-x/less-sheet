# less-sheet GTK frontend — pinned CI/gate image.
#
# aidev decision 6 + the 2026-07-17 ARCH amendment: the WHOLE gate (compile-level
# conformance AND behavior) runs inside a Linux GNOME container, because the dev
# Mac has no GTK/Meson toolchain. This image is that container.
#
# fedora:42 ships GTK 4.18 / libadwaita 1.7 / meson 1.7 / gcc 15 — comfortably
# above the ARCH decision-7 floor (GTK 4.16 / libadwaita 1.6). Explicit tag, NOT
# a floating 'latest'. Digest observed at authoring time (2026-07-17):
#   registry.fedoraproject.org/fedora@sha256:83205934094144b56f645f86c42b84f81083f423b0bea9cb233f91c21bab0919
FROM fedora:42

RUN dnf -y install --setopt=install_weak_deps=False \
        gtk4-devel \
        libadwaita-devel \
        glib2-devel \
        meson \
        ninja-build \
        gcc \
        pkgconf-pkg-config \
 && dnf clean all
