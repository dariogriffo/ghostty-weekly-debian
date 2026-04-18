ARG DEBIAN_DIST=bookworm
FROM debian:$DEBIAN_DIST

ARG DEBIAN_DIST
# Commit SHA checked out from ghostty-org/ghostty (usually the `tip` rolling tag).
ARG GHOSTTY_SHA
# Debian-compatible upstream version (starts with a digit, uses `~` for prerelease).
# Example: 1.3.2~dev.ca7516be
ARG UPSTREAM_VERSION
# Valid SemVer passed to `-Dversion-string` (upstream parses it with std.SemanticVersion).
# Example: 1.3.2-dev+ca7516be
ARG ZIG_VERSION_STRING
ARG BUILD_VERSION
ARG FULL_VERSION
# libghostty-vt has its own SemVer (`lib_version` in upstream build.zig, currently
# "0.1.0-dev"). Override so the SONAME/filename are clean for packaging. Bump here
# if upstream bumps lib_version major/minor.
ARG LIBGHOSTTY_VT_VERSION=0.1.0

RUN apt update && apt install -y git curl gpg gnupg lsb-release build-essential \
        debhelper devscripts pandoc libonig-dev libbz2-dev libgtk-4-dev \
        libadwaita-1-dev libgtk4-layer-shell-dev blueprint-compiler minisign \
        libxml2-utils
RUN curl -sS https://debian.griffo.io/EA0F721D231FDD3A0A17B9AC7808B4DD62C41256.asc \
        | gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/debian.griffo.io.gpg \
    && echo "deb https://debian.griffo.io/apt $(lsb_release -sc) main" \
        | tee /etc/apt/sources.list.d/debian.griffo.io.list \
    && apt-get update \
    && apt-get install -y zig-oldstable

RUN git config --global --add advice.detachedHead false
RUN git clone https://github.com/ghostty-org/ghostty.git
WORKDIR "ghostty"
RUN git checkout $GHOSTTY_SHA

# Some Debian base images ship bzip2 only as `libbz2.so`; upstream links via `bzip2`.
# sed is a no-op if upstream has already fixed this.
RUN sed -i 's/linkSystemLibrary2("bzip2", dynamic_link_opts)/linkSystemLibrary2("bz2", dynamic_link_opts)/' build.zig

RUN zig build --summary all --prefix ./zig-out/usr \
    -Doptimize=ReleaseFast -Dcpu=baseline -Dpie=true -Demit-docs \
    -Dversion-string="$ZIG_VERSION_STRING" \
    -Dlib-version-string=$LIBGHOSTTY_VT_VERSION

# ---------------------------------------------------------------------------
# Stage package: ghostty-tip (binary + resources; excludes libghostty-vt artifacts)
# ---------------------------------------------------------------------------
RUN mkdir -p /pkg/ghostty-tip/DEBIAN /pkg/ghostty-tip/usr/share/doc/ghostty-tip/
COPY output/ghostty-tip/DEBIAN/control /pkg/ghostty-tip/DEBIAN/
COPY output/changelog.Debian /pkg/ghostty-tip/usr/share/doc/ghostty-tip/changelog.Debian
COPY output/copyright /pkg/ghostty-tip/usr/share/doc/ghostty-tip/copyright
RUN cp -R ./zig-out/usr /pkg/ghostty-tip/
RUN rm -f /pkg/ghostty-tip/usr/lib/libghostty-vt.so* \
          /pkg/ghostty-tip/usr/lib/libghostty-vt.a && \
    rm -rf /pkg/ghostty-tip/usr/include/ghostty && \
    rm -f /pkg/ghostty-tip/usr/share/pkgconfig/libghostty-vt*.pc && \
    rmdir --ignore-fail-on-non-empty \
          /pkg/ghostty-tip/usr/lib \
          /pkg/ghostty-tip/usr/include \
          /pkg/ghostty-tip/usr/share/pkgconfig 2>/dev/null || true

# ---------------------------------------------------------------------------
# Stage package: libghostty-vt0-tip (versioned shared library only)
# ---------------------------------------------------------------------------
RUN mkdir -p /pkg/libghostty-vt0-tip/DEBIAN \
             /pkg/libghostty-vt0-tip/usr/lib \
             /pkg/libghostty-vt0-tip/usr/share/doc/libghostty-vt0-tip
COPY output/libghostty-vt0-tip/DEBIAN/control  /pkg/libghostty-vt0-tip/DEBIAN/
COPY output/libghostty-vt0-tip/DEBIAN/triggers /pkg/libghostty-vt0-tip/DEBIAN/
COPY output/libghostty-vt0-tip/DEBIAN/shlibs   /pkg/libghostty-vt0-tip/DEBIAN/
COPY output/changelog.Debian /pkg/libghostty-vt0-tip/usr/share/doc/libghostty-vt0-tip/changelog.Debian
COPY output/copyright        /pkg/libghostty-vt0-tip/usr/share/doc/libghostty-vt0-tip/copyright
RUN cp -a ./zig-out/usr/lib/libghostty-vt.so.* /pkg/libghostty-vt0-tip/usr/lib/

# ---------------------------------------------------------------------------
# Stage package: libghostty-vt-dev-tip (headers, static lib, .so symlink, .pc)
# ---------------------------------------------------------------------------
RUN mkdir -p /pkg/libghostty-vt-dev-tip/DEBIAN \
             /pkg/libghostty-vt-dev-tip/usr/lib/pkgconfig \
             /pkg/libghostty-vt-dev-tip/usr/include/ghostty \
             /pkg/libghostty-vt-dev-tip/usr/share/doc/libghostty-vt-dev-tip
COPY output/libghostty-vt-dev-tip/DEBIAN/control /pkg/libghostty-vt-dev-tip/DEBIAN/
COPY output/changelog.Debian /pkg/libghostty-vt-dev-tip/usr/share/doc/libghostty-vt-dev-tip/changelog.Debian
COPY output/copyright        /pkg/libghostty-vt-dev-tip/usr/share/doc/libghostty-vt-dev-tip/copyright
RUN cp -a ./zig-out/usr/lib/libghostty-vt.so /pkg/libghostty-vt-dev-tip/usr/lib/ && \
    cp -a ./zig-out/usr/lib/libghostty-vt.a  /pkg/libghostty-vt-dev-tip/usr/lib/ && \
    cp -a ./zig-out/usr/include/ghostty/.    /pkg/libghostty-vt-dev-tip/usr/include/ghostty/ && \
    cp -a ./zig-out/usr/share/pkgconfig/libghostty-vt.pc \
          ./zig-out/usr/share/pkgconfig/libghostty-vt-static.pc \
          /pkg/libghostty-vt-dev-tip/usr/lib/pkgconfig/

# ---------------------------------------------------------------------------
# Substitute version placeholders in control/changelog/shlibs for all packages
# ---------------------------------------------------------------------------
RUN set -eux; \
    for f in /pkg/ghostty-tip/DEBIAN/control \
             /pkg/libghostty-vt0-tip/DEBIAN/control \
             /pkg/libghostty-vt-dev-tip/DEBIAN/control \
             /pkg/ghostty-tip/usr/share/doc/ghostty-tip/changelog.Debian \
             /pkg/libghostty-vt0-tip/usr/share/doc/libghostty-vt0-tip/changelog.Debian \
             /pkg/libghostty-vt-dev-tip/usr/share/doc/libghostty-vt-dev-tip/changelog.Debian; do \
        sed -i "s/DIST/$DEBIAN_DIST/g; s|GHOSTTY_VERSION|$UPSTREAM_VERSION|g; s/BUILD_VERSION/$BUILD_VERSION/g" "$f"; \
    done; \
    sed -i "s|GHOSTTY_VERSION|$UPSTREAM_VERSION|g" /pkg/libghostty-vt0-tip/DEBIAN/shlibs

# ---------------------------------------------------------------------------
# Rewrite hard-coded `./zig-out` paths baked into desktop/service files by
# upstream's `zig build`. Without this the .desktop Exec= points at
# ./zig-out/usr/bin/ghostty and GNOME Shell silently drops the entry from
# the applications menu (no icon visible).
# ---------------------------------------------------------------------------
RUN sed -i 's|\./zig-out||g' \
        /pkg/ghostty-tip/usr/share/systemd/user/app-com.mitchellh.ghostty.service \
        /pkg/ghostty-tip/usr/share/applications/com.mitchellh.ghostty.desktop \
        /pkg/ghostty-tip/usr/share/dbus-1/services/com.mitchellh.ghostty.service

# ---------------------------------------------------------------------------
# Post-process ghostty resources (compress docs/man, move zsh completions)
# ---------------------------------------------------------------------------
RUN gzip -n -9 /pkg/ghostty-tip/usr/share/doc/ghostty-tip/changelog.Debian \
               /pkg/libghostty-vt0-tip/usr/share/doc/libghostty-vt0-tip/changelog.Debian \
               /pkg/libghostty-vt-dev-tip/usr/share/doc/libghostty-vt-dev-tip/changelog.Debian \
               /pkg/ghostty-tip/usr/share/man/man1/ghostty.1 \
               /pkg/ghostty-tip/usr/share/man/man5/ghostty.5
RUN mv /pkg/ghostty-tip/usr/share/zsh/site-functions /pkg/ghostty-tip/usr/share/zsh/vendor-completions
RUN [ "$DEBIAN_DIST" != "bookworm" ] && rm -fRd /pkg/ghostty-tip/usr/share/terminfo/g || true

# ---------------------------------------------------------------------------
# Build the three .deb files
# ---------------------------------------------------------------------------
RUN ls -la /pkg/ghostty-tip/usr /pkg/libghostty-vt0-tip/usr/lib /pkg/libghostty-vt-dev-tip/usr/lib /pkg/libghostty-vt-dev-tip/usr/include/ghostty
RUN dpkg-deb --build /pkg/ghostty-tip          /ghostty-tip_${FULL_VERSION}.deb
RUN dpkg-deb --build /pkg/libghostty-vt0-tip   /libghostty-vt0-tip_${FULL_VERSION}.deb
RUN dpkg-deb --build /pkg/libghostty-vt-dev-tip /libghostty-vt-dev-tip_${FULL_VERSION}.deb
