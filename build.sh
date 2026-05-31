#!/bin/bash
set -uo pipefail
# NOTE: not using set -e because patchelf/strip can fail on some binaries
# and we don't want the script to die silently. We handle errors manually.

###############################################################################
# WoeUSB-ng AppImage Builder
# Builds a self-contained AppImage with wxPython GUI and all runtime deps
###############################################################################

SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"
BUILDDIR="$SCRIPTDIR/build"
APPDIR="$BUILDDIR/AppDir"
SITE_PACKAGES="$APPDIR/usr/lib/python3/site-packages"
DEFAULT_VERSION="0.2.12"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}==> $1${NC}"; }
warn() { echo -e "${YELLOW}==> WARNING: $1${NC}"; }
err()  { echo -e "${RED}==> ERROR: $1${NC}"; exit 1; }

usage() {
    cat <<EOF
Usage: $0 [version] [--no-clean]

Build WoeUSB-ng v<version> into build/WoeUSB-ng-<version>-x86_64.AppImage.
Defaults to version ${DEFAULT_VERSION}.
EOF
}

VERSION="$DEFAULT_VERSION"
VERSION_SET=0
NO_CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --no-clean)
            NO_CLEAN=1
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -*)
            err "Unknown option: $arg"
            ;;
        *)
            if [ "$VERSION_SET" -eq 1 ]; then
                err "Unexpected extra argument: $arg"
            fi
            VERSION="$arg"
            VERSION_SET=1
            ;;
    esac
done

log "Building WoeUSB-ng AppImage v${VERSION}"

# --- Preflight ---------------------------------------------------------------
log "Checking build dependencies..."
MISSING_BUILD=()
for cmd in git wget python3 dnf rpm rpm2cpio patchelf file cpio pip3 strip ldd find xargs; do
    command -v "$cmd" &>/dev/null || MISSING_BUILD+=("$cmd")
done
if [ ${#MISSING_BUILD[@]} -ne 0 ]; then
    err "Missing build tools: ${MISSING_BUILD[*]}
Install with:
  sudo dnf install -y git wget python3 python3-pip patchelf rpm-build cpio file findutils binutils"
fi

if ! dnf download --help &>/dev/null; then
    err "'dnf download' is unavailable. Install dnf-plugins-core or use a Fedora image with download support."
fi

# --- Clean -------------------------------------------------------------------
if [ "$NO_CLEAN" -eq 1 ]; then
    log "Skipping full clean (--no-clean). Reusing downloaded RPMs."
    log "  Wiping AppDir and source clone only..."
    rm -rf "$APPDIR" "$BUILDDIR/WoeUSB-ng"
else
    rm -rf "$BUILDDIR"
fi
mkdir -p "$BUILDDIR/deps-rpms" || err "Failed to create build directory"

# --- Clone WoeUSB-ng ---------------------------------------------------------
log "Cloning WoeUSB-ng v${VERSION}..."
git clone --branch "v${VERSION}" --depth 1 \
    https://github.com/WoeUSB/WoeUSB-ng.git "$BUILDDIR/WoeUSB-ng" || \
    err "Failed to clone WoeUSB-ng v${VERSION} (does the tag exist?)"

# --- Download appimagetool ---------------------------------------------------
log "Downloading appimagetool..."
wget -q -O "$BUILDDIR/appimagetool" \
    https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage || \
    err "Failed to download appimagetool"
chmod +x "$BUILDDIR/appimagetool" || err "Failed to make appimagetool executable"

# --- Build AppDir skeleton ---------------------------------------------------
log "Creating AppDir structure..."
mkdir -p "$APPDIR"/usr/{bin,lib} || err "Failed to create AppDir binaries"
mkdir -p "$APPDIR"/usr/share/{grub,applications,glib-2.0,locale} || err "Failed to create AppDir shares"
mkdir -p "$APPDIR"/usr/share/icons/hicolor/256x256/apps || err "Failed to create icon directory"
mkdir -p "$APPDIR"/etc/gtk-3.0 || err "Failed to create GTK config directory"

# --- Install WoeUSB-ng -------------------------------------------------------
# WoeUSB-ng's setup.py has custom install commands that try to write to
# /usr/local/bin during wheel build, breaking pip --target installs.
# Since it's pure Python, just copy the package directly.
log "Installing WoeUSB-ng Python package..."
mkdir -p "$SITE_PACKAGES" || err "Failed to create Python site-packages"
cp -a "$BUILDDIR/WoeUSB-ng/WoeUSB" "$SITE_PACKAGES/WoeUSB" || \
    err "Failed to copy WoeUSB-ng package"

# Install termcolor (WoeUSB-ng dependency)
pip3 install --target="$SITE_PACKAGES" \
    termcolor --break-system-packages --quiet || \
    warn "Failed to install termcolor"

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
    grub2-tools-extra
    grub2-tools-minimal
    grub2-common
    grub2-pc-modules
    ntfs-3g
    ntfs-3g-libs
    ntfsprogs
    dosfstools
    p7zip
    p7zip-plugins

    # GUI: wxPython + wxGTK + GTK3 stack
    python3-wxpython4
    python3-termcolor
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
    mesa-libEGL
    mesa-libGL
    dbus-libs
    adwaita-icon-theme
    hicolor-icon-theme
    gsettings-desktop-schemas
    librsvg2
    libpng
    libjpeg-turbo
    pixman
    # Non-SELinux hosts: wxPython's _core.so links libselinux at runtime
    libselinux
    # GTK/Pango chain requires libxml2
    libxml2
    # Mesa Gallium driver (libgallium-*.so)
    mesa-libgallium
    # FUSE3 runtime
    fuse3-libs
    # Image quantization (Pillow dep)
    libimagequant
    # parted + all grub2 tools link libdevmapper.so.1.02
    device-mapper-libs
)

cd "$BUILDDIR/deps-rpms" || err "Failed to enter RPM cache directory"

CACHED_RPM_COUNT=$(find "$BUILDDIR/deps-rpms" -maxdepth 1 -type f -name "*.rpm" | wc -l)
if [ "$NO_CLEAN" -eq 1 ] && [ "$CACHED_RPM_COUNT" -gt 0 ]; then
    log "Reusing $CACHED_RPM_COUNT cached RPMs (--no-clean)"
else
    dnf download --arch x86_64 --arch noarch \
        --skip-unavailable \
        --disablerepo=fedora-cisco-openh264 \
        --destdir="$BUILDDIR/deps-rpms" \
        "${ALL_PACKAGES[@]}" || \
        warn "Some packages could not be downloaded (see above)"
fi

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

# --- Flatten directory structure ---------------------------------------------
log "Organizing bundled files..."

# sbin -> bin
for dir in "$APPDIR/usr/sbin" "$APPDIR/sbin" "$APPDIR/bin"; do
    if [ -d "$dir" ]; then
        cp -an "$dir"/* "$APPDIR/usr/bin/" 2>/dev/null || true
    fi
done

# Consolidate all libraries into usr/lib
for libdir in "$APPDIR/lib" "$APPDIR/lib64" "$APPDIR/usr/lib64"; do
    if [ -d "$libdir" ]; then
        find "$libdir" -type f \( -name "*.so" -o -name "*.so.*" \) \
            -exec cp -an {} "$APPDIR/usr/lib/" \; 2>/dev/null || true
        find "$libdir" -type l \( -name "*.so" -o -name "*.so.*" \) \
            -exec cp -an {} "$APPDIR/usr/lib/" \; 2>/dev/null || true
    fi
done

# GRUB modules - preserve directory structure under usr/lib/grub
if [ -d "$APPDIR/usr/lib/grub" ]; then
    # Already in the right place
    true
elif [ -d "$APPDIR/usr/share/grub" ]; then
    cp -rn "$APPDIR/usr/share/grub" "$APPDIR/usr/lib/" 2>/dev/null || true
fi
# Also copy share/grub content (grub.cfg templates etc.)
for grubdir in "$APPDIR/usr/lib/grub" "$APPDIR/lib/grub"; do
    if [ -d "$grubdir" ] && [ "$grubdir" != "$APPDIR/usr/lib/grub" ]; then
        cp -rn "$grubdir"/* "$APPDIR/usr/lib/grub/" 2>/dev/null || true
    fi
done

# GDK pixbuf loaders
PIXBUF_DIR=$(find "$APPDIR" -path "*/gdk-pixbuf-2.0/*/loaders" -type d 2>/dev/null | head -1)
if [ -n "$PIXBUF_DIR" ]; then
    mkdir -p "$APPDIR/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders"
    cp -an "$PIXBUF_DIR"/* "$APPDIR/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders/" 2>/dev/null || true
fi

# --- Bundle Python interpreter -----------------------------------------------
log "Bundling Python interpreter..."
PYTHON_BIN=$(readlink -f "$(command -v python3)")
PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PYTHONPATH_BUNDLED="$SITE_PACKAGES:$APPDIR/usr/lib/python${PYTHON_VERSION}:$APPDIR/usr/lib/python${PYTHON_VERSION}/lib-dynload"

cp "$PYTHON_BIN" "$APPDIR/usr/bin/python3" || err "Failed to copy Python interpreter"

# Python stdlib
PYTHON_LIBDIR=$(python3 -c "import sysconfig; print(sysconfig.get_path('stdlib'))")
mkdir -p "$APPDIR/usr/lib/python${PYTHON_VERSION}" || err "Failed to create Python stdlib directory"
cp -a "$PYTHON_LIBDIR"/* "$APPDIR/usr/lib/python${PYTHON_VERSION}/" 2>/dev/null || true

# Python lib-dynload
PYTHON_DYNLOAD=$(python3 -c "import sysconfig; print(sysconfig.get_path('platstdlib'))")
if [ -d "$PYTHON_DYNLOAD/lib-dynload" ]; then
    cp -a "$PYTHON_DYNLOAD/lib-dynload" "$APPDIR/usr/lib/python${PYTHON_VERSION}/" 2>/dev/null || true
fi

# libpython shared library
for searchdir in /usr/lib /usr/lib64; do
    find "$searchdir" -maxdepth 1 -name "libpython${PYTHON_VERSION}*.so*" \
        -exec cp -an {} "$APPDIR/usr/lib/" \; 2>/dev/null || true
done

patchelf --set-rpath "\$ORIGIN/../lib" "$APPDIR/usr/bin/python3" 2>/dev/null || true

# --- Bundle wxPython ---------------------------------------------------------
log "Bundling wxPython..."

copy_python_tree_from_appdir() {
    local module_name="$1"
    local destination="$SITE_PACKAGES/$module_name"
    local source_path

    [ -e "$destination" ] && return 0

    source_path=$(find "$APPDIR" -path "*/site-packages/$module_name" -type d -print -quit 2>/dev/null || true)
    if [ -n "$source_path" ]; then
        log "  Copying $module_name from extracted RPM: $source_path"
        mkdir -p "$SITE_PACKAGES" || err "Failed to create Python site-packages"
        cp -a "$source_path" "$destination" || err "Failed to copy $module_name from extracted RPMs"
    fi
}

verify_python_import() {
    local module_name="$1"
    local failure_output

    if ! failure_output=$(PYTHONHOME="$APPDIR/usr" \
        PYTHONPATH="$PYTHONPATH_BUNDLED" \
        LD_LIBRARY_PATH="$APPDIR/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "$APPDIR/usr/bin/python3" -c "import ${module_name}" 2>&1); then
        echo "$failure_output" >&2
        err "Bundled Python cannot import ${module_name}. The AppImage would fail at runtime."
    fi
}

# Primary: copy from system install
SYSTEM_WX=$(python3 -c "import wx; print(wx.__path__[0])" 2>/dev/null || echo "")
if [ -n "$SYSTEM_WX" ] && [ -d "$SYSTEM_WX" ]; then
    log "  Copying system wxPython from $SYSTEM_WX"
    mkdir -p "$SITE_PACKAGES" || err "Failed to create Python site-packages"
    cp -a "$SYSTEM_WX" "$SITE_PACKAGES/wx" || err "Failed to copy system wxPython"
    # Copy dist-info/egg-info if present
    WX_DIST=$(find "$(dirname "$SYSTEM_WX")" -maxdepth 1 -name "wx*info" -type d 2>/dev/null | head -1)
    if [ -n "$WX_DIST" ]; then
        cp -a "$WX_DIST" "$SITE_PACKAGES/" 2>/dev/null || true
    fi
else
    # Fallback: extract from the downloaded RPM
    warn "System wxPython not found, checking extracted RPMs..."
    copy_python_tree_from_appdir wx
fi

if [ ! -d "$SITE_PACKAGES/wx" ]; then
    err "wxPython not available. Install python3-wxpython4 in the build environment or build in the documented Fedora container."
fi

copy_python_tree_from_appdir termcolor

# Copy wxGTK native .so files
for searchdir in /usr/lib /usr/lib64; do
    find "$searchdir" -maxdepth 1 -name "libwx_*.so*" \
        -exec cp -an {} "$APPDIR/usr/lib/" \; 2>/dev/null || true
done

# --- GTK/GDK configuration ---------------------------------------------------
log "Setting up GTK configuration..."

# Generate GDK pixbuf loader cache
GDK_PIXBUF_QUERY=$(find "$APPDIR" -name "gdk-pixbuf-query-loaders*" -type f 2>/dev/null | head -1)
if [ -n "$GDK_PIXBUF_QUERY" ]; then
    chmod +x "$GDK_PIXBUF_QUERY"
    mkdir -p "$APPDIR/usr/lib/gdk-pixbuf-2.0/2.10.0"
    LOADERS_DIR="$APPDIR/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders"
    if [ -d "$LOADERS_DIR" ] && ls "$LOADERS_DIR"/*.so 1>/dev/null 2>&1; then
        LD_LIBRARY_PATH="$APPDIR/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
            "$GDK_PIXBUF_QUERY" "$LOADERS_DIR"/*.so \
            > "$APPDIR/usr/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache" 2>/dev/null || \
            warn "Could not generate pixbuf loader cache"
    fi
fi

# Compile GLib schemas
GLIB_COMPILE=$(find "$APPDIR" -name "glib-compile-schemas" -type f 2>/dev/null | head -1)
if [ -n "$GLIB_COMPILE" ]; then
    chmod +x "$GLIB_COMPILE"
    while IFS= read -r schema_dir; do
        if [ -d "$schema_dir/schemas" ]; then
            LD_LIBRARY_PATH="$APPDIR/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
                "$GLIB_COMPILE" "$schema_dir/schemas" 2>/dev/null || true
        fi
    done < <(find "$APPDIR" -name "glib-2.0" -type d 2>/dev/null)
fi

# GTK settings
cat > "$APPDIR/etc/gtk-3.0/settings.ini" <<'GTKEOF'
[Settings]
gtk-theme-name=Adwaita
gtk-icon-theme-name=Adwaita
gtk-fallback-icon-theme=hicolor
gtk-font-name=Sans 10
GTKEOF

# --- Patch ELF binaries ------------------------------------------------------
log "Patching ELF binaries..."

PATCH_COUNT=0
PATCH_FAIL=0

# Patch binaries in usr/bin
for binary in "$APPDIR/usr/bin"/*; do
    [ -f "$binary" ] || continue
    [ -x "$binary" ] || continue
    if file "$binary" 2>/dev/null | grep -q "ELF"; then
        if patchelf --set-rpath "\$ORIGIN/../lib" "$binary" 2>/dev/null; then
            PATCH_COUNT=$((PATCH_COUNT + 1))
        else
            PATCH_FAIL=$((PATCH_FAIL + 1))
        fi
    fi
done

# Patch shared libraries in usr/lib (top level only)
for lib in "$APPDIR/usr/lib"/*.so "$APPDIR/usr/lib"/*.so.*; do
    [ -f "$lib" ] || continue
    if file "$lib" 2>/dev/null | grep -q "ELF"; then
        if patchelf --set-rpath "\$ORIGIN" "$lib" 2>/dev/null; then
            PATCH_COUNT=$((PATCH_COUNT + 1))
        else
            PATCH_FAIL=$((PATCH_FAIL + 1))
        fi
    fi
done

log "  Patched $PATCH_COUNT ELF files ($PATCH_FAIL skipped)"

# --- Copy resources ----------------------------------------------------------
log "Installing launcher and metadata..."
cp "$SCRIPTDIR/resources/AppRun" "$APPDIR/AppRun" || err "Failed to copy AppRun"
cp "$SCRIPTDIR/resources/woeusb-ng.desktop" "$APPDIR/woeusb-ng.desktop" || err "Failed to copy desktop file"
cp "$SCRIPTDIR/resources/woeusb-ng.desktop" "$APPDIR/usr/share/applications/woeusb-ng.desktop" || \
    err "Failed to install desktop file"
chmod +x "$APPDIR/AppRun" || err "Failed to make AppRun executable"

# Icon
if [ -f "$BUILDDIR/WoeUSB-ng/WoeUSB/data/woeusb-logo.png" ]; then
    cp "$BUILDDIR/WoeUSB-ng/WoeUSB/data/woeusb-logo.png" \
        "$APPDIR/usr/share/icons/hicolor/256x256/apps/woeusb-ng.png" || err "Failed to copy upstream icon"
elif [ -f "$SCRIPTDIR/resources/woeusb-ng.png" ]; then
    cp "$SCRIPTDIR/resources/woeusb-ng.png" \
        "$APPDIR/usr/share/icons/hicolor/256x256/apps/woeusb-ng.png" || err "Failed to copy local icon"
else
    warn "No icon found -- add resources/woeusb-ng.png for best results"
fi
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
       "$APPDIR/usr/lib/python${PYTHON_VERSION}/test" \
       "$APPDIR/usr/lib/python${PYTHON_VERSION}/unittest" \
       "$APPDIR/usr/lib/python${PYTHON_VERSION}/tkinter" \
       "$APPDIR/usr/lib/python${PYTHON_VERSION}/idlelib" \
       "$APPDIR/usr/lib/python${PYTHON_VERSION}/ensurepip" \
       "$APPDIR/usr/lib/python${PYTHON_VERSION}/distutils" \
       "$APPDIR/usr/lib/python${PYTHON_VERSION}/lib2to3" \
       2>/dev/null || true

# Remove non-English locales
find "$APPDIR/usr/share/locale" -mindepth 1 -maxdepth 1 ! -name "en*" \
    -exec rm -rf {} \; 2>/dev/null || true

# Strip debug symbols
log "Stripping debug symbols..."
STRIP_COUNT=0
while IFS= read -r -d '' f; do
    strip --strip-unneeded "$f" 2>/dev/null && STRIP_COUNT=$((STRIP_COUNT + 1))
done < <(find "$APPDIR" -type f \( -name "*.so" -o -name "*.so.*" \) -print0 2>/dev/null)
for f in "$APPDIR/usr/bin"/*; do
    [ -f "$f" ] && [ -x "$f" ] || continue
    if file "$f" 2>/dev/null | grep -q "ELF"; then
        strip --strip-unneeded "$f" 2>/dev/null && STRIP_COUNT=$((STRIP_COUNT + 1))
    fi
done
log "  Stripped $STRIP_COUNT files"

log "Checking bundled Python imports..."
verify_python_import "termcolor"
verify_python_import "WoeUSB.core"
verify_python_import "wx"
verify_python_import "wx.adv"
log "  Bundled Python imports passed"

# --- Verification ------------------------------------------------------------
echo ""
log "========== VERIFICATION =========="

check_appdir_tool() {
    local label="$1"
    shift
    local tool
    local alt

    for tool in "$@"; do
        if [ -f "$APPDIR/usr/bin/$tool" ]; then
            if [ "$label" = "$tool" ]; then
                echo "  [OK]      $label"
            else
                echo "  [OK]      $label (as $tool)"
            fi
            return 0
        fi
    done

    for tool in "$@"; do
        alt=$(find "$APPDIR/usr/bin" -name "${tool}*" -print -quit 2>/dev/null)
        if [ -n "$alt" ]; then
            echo "  [OK]      $label (as $(basename "$alt"))"
            return 0
        fi
    done

    echo "  [MISSING] $label"
}

log "System tools:"
check_appdir_tool parted parted
check_appdir_tool grub-install grub-install grub2-install
check_appdir_tool mkfs.fat mkfs.fat
check_appdir_tool mkntfs mkntfs
check_appdir_tool 7z 7z 7za 7zr
check_appdir_tool python3 python3

log "GRUB modules:"
if find "$APPDIR/usr/lib/grub" -name "*.mod" -print -quit 2>/dev/null | grep -q .; then
    GRUB_ARCH=$(find "$APPDIR/usr/lib/grub" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | head -3 | tr '\n' ' ')
    echo "  [OK]      GRUB modules (${GRUB_ARCH})"
else
    echo "  [MISSING] GRUB modules"
fi

log "GUI libraries:"
if [ -d "$APPDIR/usr/lib/python3/site-packages/wx" ]; then
    echo "  [OK]      wxPython"
else
    WX_FOUND=$(find "$APPDIR" -type d -name "wx" -path "*/site-packages/wx" 2>/dev/null | head -1)
    if [ -n "$WX_FOUND" ]; then
        echo "  [OK]      wxPython (at $WX_FOUND)"
    else
        echo "  [MISSING] wxPython -- GUI WILL NOT WORK"
    fi
fi

if find "$APPDIR/usr/lib" -name "libgtk-3.so*" -print -quit 2>/dev/null | grep -q .; then
    echo "  [OK]      GTK3"
else
    echo "  [MISSING] GTK3 -- GUI WILL NOT WORK"
fi

if find "$APPDIR/usr/lib" -name "libwx_gtk*.so*" -print -quit 2>/dev/null | grep -q .; then
    echo "  [OK]      wxGTK3 native libs"
else
    echo "  [MISSING] wxGTK3 native libs"
fi

echo ""

# --- Automated ldd audit -----------------------------------------------------
# Scan every ELF binary for missing shared libraries BEFORE packaging.
# Two-phase check to eliminate false positives from patchelf $ORIGIN RPATHs:
#   Phase 1: ldd reports "not found" with LD_LIBRARY_PATH pointing at usr/lib
#   Phase 2: confirm the lib genuinely isn't anywhere in the AppDir on disk
#            (libs like libntfs-3g.so live in usr/lib/ntfs-3g/ subdirs, which
#             ldd can't resolve via LD_LIBRARY_PATH but patchelf RPATH handles)
log "Running library audit..."

TRULY_MISSING=()
while IFS= read -r binary; do
    while IFS= read -r libname; do
        # Phase 2: search the entire AppDir tree, not just usr/lib flat
        if ! find "$APPDIR" -name "${libname}*" -print -quit 2>/dev/null | grep -q .; then
            TRULY_MISSING+=("$libname")
        fi
    done < <(
        LD_LIBRARY_PATH="$APPDIR/usr/lib" ldd "$binary" 2>/dev/null \
        | grep "not found" \
        | grep -oP '^\s+\K\S+(?= =>)'
    )
done < <(find "$APPDIR" -type f -print0 | xargs -0 file 2>/dev/null | grep ELF | cut -d: -f1)

# Deduplicate
MISSING_UNIQUE=$(printf '%s\n' "${TRULY_MISSING[@]}" | sort -u | grep -v '^$')

if [ -n "$MISSING_UNIQUE" ]; then
    echo ""
    warn "============================================================"
    warn "  MISSING LIBRARIES DETECTED - AppImage may crash at runtime"
    warn "  Add the corresponding RPM packages to ALL_PACKAGES in"
    warn "  build.sh and rebuild."
    warn ""
    warn "  Missing libs:"
    echo "$MISSING_UNIQUE" | while read -r lib; do
        warn "    $lib"
    done
    warn "============================================================"
    echo ""
    err "Aborting: fix missing libraries before packaging."
fi

log "  Library audit passed - all dependencies bundled."

# --- Package -----------------------------------------------------------------
log "Packaging AppImage..."
cd "$SCRIPTDIR" || err "Failed to return to source directory"
# APPIMAGE_EXTRACT_AND_RUN=1 lets appimagetool run without FUSE (needed in Docker)
if ! ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$BUILDDIR/appimagetool" "$APPDIR" \
    "$BUILDDIR/WoeUSB-ng-${VERSION}-x86_64.AppImage"; then
    err "appimagetool failed!"
fi

FINAL="$BUILDDIR/WoeUSB-ng-${VERSION}-x86_64.AppImage"

if [ ! -f "$FINAL" ]; then
    err "AppImage file not created!"
fi

SIZE=$(du -h "$FINAL" | cut -f1)

echo ""
log "============================================================"
log "  SUCCESS! WoeUSB-ng AppImage built."
log ""
log "  Output: build/WoeUSB-ng-${VERSION}-x86_64.AppImage"
log "  Size:   ${SIZE}"
log ""
log "  Launch GUI:"
log "    chmod +x WoeUSB-ng-${VERSION}-x86_64.AppImage"
log "    sudo ./WoeUSB-ng-${VERSION}-x86_64.AppImage"
log ""
log "  CLI mode:"
log "    sudo ./WoeUSB-ng-${VERSION}-x86_64.AppImage \\"
log "      --cli --device windows.iso /dev/sdX"
log "============================================================"
