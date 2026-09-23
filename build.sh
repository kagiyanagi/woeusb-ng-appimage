#!/bin/bash
set -uo pipefail

###############################################################################
# WoeUSB-ng AppImage Builder
# Builds a self-contained AppImage with wxPython GUI and all runtime deps
###############################################################################

SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"
BUILDDIR="$SCRIPTDIR/build"
APPDIR="$BUILDDIR/AppDir"
LIBPATH="$APPDIR/usr/lib64:$APPDIR/usr/lib"
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
for cmd in git curl dnf rpm2cpio cpio file ldd find xargs; do
    command -v "$cmd" &>/dev/null || MISSING_BUILD+=("$cmd")
done
if [ ${#MISSING_BUILD[@]} -ne 0 ]; then
    err "Missing build tools: ${MISSING_BUILD[*]}
Install with:
  sudo dnf install -y git cpio file"
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
# All packages in a single dnf download call for speed (one repo metadata load).
# No --resolve: dependency resolution fails in toolbox/container environments
# due to systemd-standalone-tmpfiles conflicts. We list all needed packages
# explicitly instead.
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
    # Linked by the stack above but missing from a bare Fedora container
    cairo-gobject
    expat
    glycin-libs
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
    liblerc
    libmspack
    libseccomp
    libsecret
    libthai
    libtiff
    libtinysparql
    libwebp
    libxcb
    lzo
    mpdecimal
    pcre2-utf32
    sdl2-compat
    # sdl2-compat dlopens SDL3, so the library audit can't see it
    SDL3
)

dnf download --arch x86_64 --arch noarch \
    --skip-unavailable \
    --disablerepo=fedora-cisco-openh264 \
    --destdir="$BUILDDIR/deps-rpms" \
    "${ALL_PACKAGES[@]}" || \
    warn "Some packages could not be downloaded (see above)"

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
mv "$APPDIR/usr/bin/grub2-install" "$APPDIR/usr/libexec/grub2-install" || \
    err "grub2-install missing from the extracted RPMs"
cat > "$APPDIR/usr/bin/grub2-install" <<'EOF'
#!/bin/sh
usr=${0%/*}/..
pkgdatadir="$usr/share/grub" exec "$usr/libexec/grub2-install" \
    --directory="$usr/lib/grub/i386-pc" "$@"
EOF
chmod +x "$APPDIR/usr/bin/grub2-install" || err "Failed to make grub2-install wrapper executable"

# --- GLib schemas ------------------------------------------------------------
log "Compiling GLib schemas..."
LD_LIBRARY_PATH="$LIBPATH" "$APPDIR/usr/bin/glib-compile-schemas" \
    "$APPDIR/usr/share/glib-2.0/schemas" 2>/dev/null || warn "Could not compile GLib schemas"

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
# GTK print backends (cups), tinysparql's ICU/libsoup modules (GTK's file
# chooser only talks to LocalSearch over D-Bus) and wx.glcanvas (host libGL).
rm -rf "$APPDIR/usr/lib64/gtk-3.0/3.0.0/printbackends" \
       "$APPDIR/usr/lib64/tinysparql-3.0" \
       "$APPDIR"/usr/lib64/python3.*/site-packages/wx/_glcanvas.*.so

# Remove non-English locales
find "$APPDIR/usr/share/locale" -mindepth 1 -maxdepth 1 ! -name "en*" \
    -exec rm -rf {} \; 2>/dev/null || true

# --- Verification ------------------------------------------------------------
verify_python_import() {
    local module_name="$1"
    local failure_output

    if ! failure_output=$(PYTHONHOME="$APPDIR/usr" \
        LD_LIBRARY_PATH="$LIBPATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "$APPDIR/usr/bin/python3" -c "import ${module_name}" 2>&1); then
        echo "$failure_output" >&2
        err "Bundled Python cannot import ${module_name}. The AppImage would fail at runtime."
    fi
}

log "Checking bundled Python imports..."
verify_python_import "termcolor"
verify_python_import "WoeUSB.core"
verify_python_import "wx"
verify_python_import "wx.adv"
log "  Bundled Python imports passed"

log "Checking bundled tools..."
for f in usr/bin/{parted,grub2-install,mkfs.fat,mkntfs,7z} usr/lib64/libgtk-3.so.0 \
         usr/lib/grub/i386-pc/normal.mod; do
    [ -e "$APPDIR/$f" ] || warn "Missing $f"
done

# --- Automated ldd audit -----------------------------------------------------
# Scan every ELF binary for missing shared libraries BEFORE packaging.
# ldd falls back to the build machine's own libraries, so this only catches
# what a clean Fedora container lacks (the workflow and README build in one).
log "Running library audit..."
MISSING_LIBS=$(find "$APPDIR" -type f -print0 | xargs -0 file 2>/dev/null | grep ELF | cut -d: -f1 \
    | tr '\n' '\0' | LD_LIBRARY_PATH="$LIBPATH" xargs -0 ldd 2>/dev/null \
    | awk '/not found/ {print $1}' | sort -u)
[ -z "$MISSING_LIBS" ] || err "Missing libraries, add their RPMs to ALL_PACKAGES:
$MISSING_LIBS"
log "  Library audit passed - all dependencies bundled."

# --- Package -----------------------------------------------------------------
log "Packaging AppImage..."
cd "$SCRIPTDIR" || err "Failed to return to source directory"
FINAL="$BUILDDIR/WoeUSB-ng-${VERSION}-x86_64.AppImage"
# APPIMAGE_EXTRACT_AND_RUN=1 lets appimagetool run without FUSE (needed in Docker)
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$BUILDDIR/appimagetool" "$APPDIR" "$FINAL" || \
    err "appimagetool failed!"
log "Built $FINAL ($(du -h "$FINAL" | cut -f1))"
