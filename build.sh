#!/bin/bash
set -uo pipefail

###############################################################################
# WoeUSB-ng AppImage Builder
# Builds a self-contained AppImage with wxPython GUI and all runtime deps
###############################################################################

SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"
BUILDDIR="$SCRIPTDIR/build"
APPDIR="$BUILDDIR/AppDir"
VERSION="${1:-0.2.12}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}==> $1${NC}"; }
warn() { echo -e "${YELLOW}==> WARNING: $1${NC}"; }
err()  { echo -e "${RED}==> ERROR: $1${NC}"; exit 1; }

log "Building WoeUSB-ng AppImage v${VERSION}"

# --- Preflight ---------------------------------------------------------------
log "Checking build dependencies..."
MISSING_BUILD=()
for cmd in git curl dnf rpm2cpio cpio file patchelf ldd find xargs; do
    command -v "$cmd" &>/dev/null || MISSING_BUILD+=("$cmd")
done
if [ ${#MISSING_BUILD[@]} -ne 0 ]; then
    err "Missing build tools: ${MISSING_BUILD[*]}
Install with:
  dnf install -y epel-release && dnf install -y dnf-plugins-core git cpio file patchelf"
fi

# --- Clean -------------------------------------------------------------------
rm -rf "$BUILDDIR"
mkdir -p "$BUILDDIR/deps-rpms" || err "Failed to create build directory"

# --- Clone WoeUSB-ng ---------------------------------------------------------
log "Cloning WoeUSB-ng v${VERSION}..."
git clone --branch "v${VERSION}" --depth 1 \
    https://github.com/WoeUSB/WoeUSB-ng.git "$BUILDDIR/WoeUSB-ng" || \
    err "Failed to clone WoeUSB-ng v${VERSION} (does the tag exist?)"

# --- Download appimagetool ---------------------------------------------------
log "Downloading appimagetool..."
curl -fsSL -o "$BUILDDIR/appimagetool" \
    https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage || \
    err "Failed to download appimagetool"
chmod +x "$BUILDDIR/appimagetool" || err "Failed to make appimagetool executable"

# --- Build AppDir skeleton ---------------------------------------------------
log "Creating AppDir structure..."
mkdir -p "$APPDIR"/usr/share/{applications,icons/hicolor/256x256/apps} || \
    err "Failed to create AppDir structure"

# --- Download runtime dependency RPMs ----------------------------------------
# Packages come from AlmaLinux 9 + EPEL: glibc isn't bundled, so its 2.34 is
# the oldest glibc the AppImage runs on (checked by the audit below). A newer
# base raises that floor: Fedora's broke AlmaLinux 9 and openSUSE Leap.
# All packages in a single dnf download call for speed (one repo metadata load).
# No --resolve: we list all needed packages explicitly instead.
log "Downloading runtime dependency RPMs..."

ALL_PACKAGES=(
    # System tools WoeUSB-ng calls via subprocess
    parted
    grub2-tools
    grub2-common
    grub2-pc-modules
    ntfs-3g
    ntfs-3g-libs
    ntfsprogs
    dosfstools
    p7zip
    p7zip-plugins

    # Python interpreter and stdlib
    python3
    python3-libs

    # GUI: wxPython + wxGTK + GTK3 stack
    python3-wxpython4
    python3-termcolor
    wxBase
    wxGTK
    gtk3
    glib2
    gdk-pixbuf2
    # SVG loader for GTK's theme assets and symbolic icons (PNG/JPEG are built in)
    librsvg2
    pango
    cairo
    at-spi2-core
    atk
    at-spi2-atk
    harfbuzz
    fribidi
    fontconfig
    freetype
    libepoxy
    libX11
    libXext
    libXrender
    libXcomposite
    libXdamage
    libXfixes
    libXrandr
    libXcursor
    libXi
    libXinerama
    libxkbcommon
    libwayland-client
    libwayland-cursor
    libwayland-egl
    dbus-libs
    adwaita-icon-theme
    hicolor-icon-theme
    gsettings-desktop-schemas
    libpng
    libjpeg-turbo
    pixman
    # Non-SELinux hosts: wxPython's _core.so links libselinux at runtime
    libselinux
    # GTK/Pango chain requires libxml2
    libxml2
    # parted + all grub2 tools link libdevmapper.so.1.02
    device-mapper-libs
    # Linked by the stack above
    cairo-gobject
    expat
    graphite2
    jbigkit-libs
    json-glib
    lcms2
    libICE
    libSM
    libXau
    libXft
    libXtst
    libcloudproviders
    libdatrie
    libmspack
    libseccomp
    libsecret
    libthai
    libtiff
    libwebp
    libxcb
    lzo
    pcre2-utf32
    SDL2
    # freetype links brotli
    libbrotli
    # GTK's file chooser search links libtracker-sparql, which links ICU
    libtracker-sparql
    libicu
    libstemmer
    # Base libraries the build container has but a user's machine may not
    # (the audit only lets glibc and the GCC runtime come from the host)
    bzip2-libs
    gdbm-libs
    gnutls
    keyutils-libs
    krb5-libs
    libblkid
    libcap
    libcom_err
    libcurl-minimal
    libffi
    libgcrypt
    libgpg-error
    libidn2
    libmount
    libnghttp2
    libtasn1
    libunistring
    libuuid
    libverto
    libxcrypt
    libzstd
    lz4-libs
    ncurses-libs
    nettle
    openssl-libs
    p11-kit
    pcre
    pcre2
    readline
    sqlite-libs
    systemd-libs
    xz-libs
    zlib
)

dnf download --arch x86_64 --arch noarch \
    --destdir="$BUILDDIR/deps-rpms" \
    "${ALL_PACKAGES[@]}" || \
    err "Failed to download RPMs (see above). Build in almalinux:9 with EPEL, see README."

RPM_COUNT=$(find "$BUILDDIR/deps-rpms" -maxdepth 1 -type f -name "*.rpm" | wc -l)
log "Downloaded $RPM_COUNT RPMs total"

if [ "$RPM_COUNT" -eq 0 ]; then
    err "No RPMs downloaded! Check your dnf configuration."
fi

# --- Extract RPMs into AppDir ------------------------------------------------
log "Extracting RPMs into AppDir..."
cd "$APPDIR" || err "Failed to enter AppDir"
for rpm_file in "$BUILDDIR/deps-rpms"/*.rpm; do
    rpm2cpio "$rpm_file" | cpio -idm --quiet 2>/dev/null || true
done

# --- Install WoeUSB-ng -------------------------------------------------------
# WoeUSB-ng's setup.py has custom install commands that try to write to
# /usr/local/bin during wheel build, breaking pip --target installs.
# Since it's pure Python, just copy the package into the bundled Python's
# site-packages.
log "Installing WoeUSB-ng Python package..."
SITE_PACKAGES=$(echo "$APPDIR"/usr/lib/python3.*/site-packages)
cp -a "$BUILDDIR/WoeUSB-ng/WoeUSB" "$SITE_PACKAGES/WoeUSB" || \
    err "Failed to copy WoeUSB-ng package"

# --- GRUB --------------------------------------------------------------------
# grub2-install only reads modules from its compiled-in /usr/lib/grub, so wrap
# it to use the bundled i386-pc ones (the only target WoeUSB-ng installs).
mv "$APPDIR/usr/sbin/grub2-install" "$APPDIR/usr/libexec/grub2-install" || \
    err "grub2-install missing from the extracted RPMs"
cat > "$APPDIR/usr/sbin/grub2-install" <<'EOF'
#!/bin/sh
usr=${0%/*}/..
pkgdatadir="$usr/share/grub" exec "$usr/libexec/grub2-install" \
    --directory="$usr/lib/grub/i386-pc" "$@"
EOF
chmod +x "$APPDIR/usr/sbin/grub2-install" || err "Failed to make grub2-install wrapper executable"

# p7zip's 7z/7za are scripts that exec /usr/libexec/p7zip on the host.
sed -i 's|"/usr/libexec/|"${0%/*}/../libexec/|' "$APPDIR"/usr/bin/7z "$APPDIR"/usr/bin/7za || \
    err "Failed to relocate the 7z wrappers"

# --- Copy resources ----------------------------------------------------------
log "Installing launcher and metadata..."
cp "$SCRIPTDIR/resources/AppRun" "$APPDIR/AppRun" || err "Failed to copy AppRun"
cp "$SCRIPTDIR/resources/woeusb-ng.desktop" "$APPDIR/woeusb-ng.desktop" || err "Failed to copy desktop file"
cp "$SCRIPTDIR/resources/woeusb-ng.desktop" "$APPDIR/usr/share/applications/woeusb-ng.desktop" || \
    err "Failed to install desktop file"
chmod +x "$APPDIR/AppRun" || err "Failed to make AppRun executable"

# Icon
cp "$BUILDDIR/WoeUSB-ng/WoeUSB/data/woeusb-logo.png" \
    "$APPDIR/usr/share/icons/hicolor/256x256/apps/woeusb-ng.png" || err "Failed to copy icon"
ln -sf usr/share/icons/hicolor/256x256/apps/woeusb-ng.png "$APPDIR/woeusb-ng.png"

# --- Cleanup to reduce size --------------------------------------------------
log "Cleaning up to reduce AppImage size..."
rm -rf "$APPDIR/usr/share/doc" \
       "$APPDIR/usr/share/man" \
       "$APPDIR/usr/share/info" \
       "$APPDIR/usr/share/bash-completion" \
       "$APPDIR/usr/share/zsh" \
       "$APPDIR/usr/share/fish" \
       "$APPDIR/usr/include" \
       "$APPDIR"/usr/lib64/python3.*/unittest \
       "$APPDIR"/usr/lib64/python3.*/ensurepip \
       2>/dev/null || true

# Plugins whose dependencies aren't bundled and that WoeUSB-ng never uses:
# GTK print backends (cups), tracker's libsoup module (GTK's file chooser
# only talks to the tracker daemon over D-Bus) and wx.glcanvas (host libGL).
rm -rf "$APPDIR/usr/lib64/gtk-3.0/3.0.0/printbackends" \
       "$APPDIR/usr/lib64/tracker-3.0" \
       "$APPDIR"/usr/lib64/python3.*/site-packages/wx/_glcanvas.*.so

# Remove non-English locales
find "$APPDIR/usr/share/locale" -mindepth 1 -maxdepth 1 ! -name "en*" \
    -exec rm -rf {} \; 2>/dev/null || true

# gdk-pixbuf's loaders.cache holds absolute paths, which change with the mount
# point, so the loader moves next to the libraries and is listed by bare name
# below: dlopen then finds it through libgmodule's RPATH.
mv "$APPDIR"/usr/lib64/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader-svg.so "$APPDIR/usr/lib64/" || \
    err "SVG pixbuf loader missing from the extracted RPMs"

# --- RPATH -------------------------------------------------------------------
# Point every bundled ELF at usr/lib64 instead of having AppRun export
# LD_LIBRARY_PATH, which leaked the bundled libs into the host tools WoeUSB-ng
# runs (mount, lsblk, grep...) and broke those needing newer versions.
log "Setting RPATHs..."
mapfile -t ELF_FILES < <(find "$APPDIR" -type f -print0 | xargs -0 file 2>/dev/null \
    | grep -E 'ELF.*dynamically linked' | cut -d: -f1)
for f in "${ELF_FILES[@]}"; do
    patchelf --set-rpath "\$ORIGIN/$(realpath --relative-to="${f%/*}" "$APPDIR/usr/lib64")" "$f" || \
        err "patchelf failed on $f"
done

log "Compiling GLib schemas..."
"$APPDIR/usr/bin/glib-compile-schemas" "$APPDIR/usr/share/glib-2.0/schemas" || \
    err "Could not compile GLib schemas"

PIXBUF_CACHE="$APPDIR/usr/lib64/gdk-pixbuf-2.0/2.10.0/loaders.cache"
"$APPDIR/usr/bin/gdk-pixbuf-query-loaders-64" "$APPDIR/usr/lib64/libpixbufloader-svg.so" \
    | sed "s|\"$APPDIR/usr/lib64/|\"|" > "$PIXBUF_CACHE"
grep -q '^"libpixbufloader-svg.so"$' "$PIXBUF_CACHE" || err "Could not register the SVG pixbuf loader"

# --- Automated ldd audit -----------------------------------------------------
# Everything must resolve inside the AppDir except glibc and the GCC runtime,
# which every distro ships. Anything else the build host happens to have is
# not on every user's machine (bare Debian 13 lacks libcurl, libffi, PCRE1...).
log "Running library audit..."
HOST_LIBS='^(ld-linux-x86-64|libc|libm|libdl|libpthread|librt|libresolv|libutil|libanl|libmvec|libstdc\+\+|libgcc_s)\.so'
NOT_BUNDLED=$(printf '%s\0' "${ELF_FILES[@]}" | xargs -0 ldd 2>/dev/null \
    | awk -v dir="$APPDIR/" '/=>/ && index($3, dir) != 1 {print $1}' | grep -vE "$HOST_LIBS" | sort -u)
[ -z "$NOT_BUNDLED" ] || err "Libraries not bundled, add their RPMs to ALL_PACKAGES:
$NOT_BUNDLED"
# glibc itself isn't bundled, so nothing may need a newer one than EL9's.
TOO_NEW=$(grep -aoE 'GLIBC_(ABI_[A-Z0-9_]+|2\.(3[5-9]|[4-9][0-9]))' "${ELF_FILES[@]}" | sort -u)
[ -z "$TOO_NEW" ] || err "Binaries need a newer glibc than the 2.34 floor (wrong build base?):
$TOO_NEW"
log "  Library audit passed - all dependencies bundled."

# --- Verification ------------------------------------------------------------
# Run Python the way AppRun does. The build host has its own Python 3.9 (dnf
# needs it), so also check that nothing was picked up from outside the AppDir.
log "Checking bundled Python imports..."
"$APPDIR/usr/bin/python3" -I -c '
import sys, encodings, termcolor, WoeUSB.core, wx, wx.adv
outside = [m.__name__ for m in (encodings, termcolor, WoeUSB, wx)
           if not m.__file__.startswith(sys.argv[1])]
sys.exit(f"imported from outside the AppDir: {outside}" if outside else 0)
' "$APPDIR/" || err "Bundled Python is broken. The AppImage would fail at runtime."
log "  Bundled Python imports passed"

log "Checking bundled tools..."
for f in usr/sbin/{parted,grub2-install,mkfs.fat,mkntfs} usr/bin/7z usr/lib64/libgtk-3.so.0 \
         usr/lib/grub/i386-pc/normal.mod; do
    [ -e "$APPDIR/$f" ] || err "Missing $f"
done

# --- Package -----------------------------------------------------------------
log "Packaging AppImage..."
cd "$SCRIPTDIR" || err "Failed to return to source directory"
FINAL="$BUILDDIR/WoeUSB-ng-${VERSION}-x86_64.AppImage"
# APPIMAGE_EXTRACT_AND_RUN=1 lets appimagetool run without FUSE (needed in Docker)
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$BUILDDIR/appimagetool" "$APPDIR" "$FINAL" || \
    err "appimagetool failed!"
log "Built $FINAL ($(du -h "$FINAL" | cut -f1))"
