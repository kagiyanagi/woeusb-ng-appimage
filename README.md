# WoeUSB-ng AppImage

Portable, self-contained [AppImage](https://appimage.org/) of [WoeUSB-ng](https://github.com/WoeUSB/WoeUSB-ng) — create bootable Windows USB drives from ISO images on any Linux distro.

No installation required. Download, make executable, run.

## Download

Grab the latest AppImage from the [Releases](../../releases) page.

## Usage

### GUI (default)

```bash
chmod +x WoeUSB-ng-*-x86_64.AppImage
./WoeUSB-ng-*-x86_64.AppImage
```

The app will ask for root privileges via a polkit dialog automatically.

### CLI

```bash
sudo ./WoeUSB-ng-*-x86_64.AppImage --cli --device /path/to/windows.iso /dev/sdX
```

Replace `/dev/sdX` with your target USB device. **All data on the target device will be erased.**

### Help

```bash
./WoeUSB-ng-*-x86_64.AppImage --help
```

This works without root.

## What's bundled

The AppImage is self-contained. It bundles:

- **WoeUSB-ng** — the Python application
- **Python 3** interpreter and stdlib
- **wxPython + GTK3** — full GUI stack (wxGTK, Pango, Cairo, GDK, etc.)
- **System tools** — parted, grub2, ntfs-3g (mkntfs), dosfstools (mkfs.fat), p7zip

Standard system utilities (mount, lsblk, grep, etc.) are expected from the host.

## Building from source

### Requirements

- **Fedora** (or a Fedora toolbox/container) — the build script uses `dnf download` to fetch RPMs
- Build tools: `git`, `wget`, `python3`, `python3-pip`, `patchelf`, `rpm-build`, `cpio`, `file`
- `python3-wxpython4` installed on the build system (for bundling)

### Build

```bash
# Install build deps (Fedora)
sudo dnf install -y git wget python3 python3-pip python3-wxpython4 patchelf rpm-build cpio file

# Build the AppImage (defaults to WoeUSB-ng v0.2.12)
./build.sh

# Or specify a version
./build.sh 0.2.12
```

The output AppImage will be at `build/WoeUSB-ng-<version>-x86_64.AppImage`.

### Build with Docker (any distro)

You don't need Fedora installed. Use Docker to build from any Linux distro:

```bash
# One-liner
docker run --rm -v "$PWD":/build -w /build fedora:latest bash -c \
  'dnf install -y git wget python3 python3-pip python3-wxpython4 patchelf rpm-build cpio file && ./build.sh 0.2.12'

# Copy the AppImage out of build/
ls build/WoeUSB-ng-*-x86_64.AppImage
```

Or with Podman (rootless, common on Fedora/RHEL):

```bash
podman run --rm -v "$PWD":/build:Z -w /build fedora:latest bash -c \
  'dnf install -y git wget python3 python3-pip python3-wxpython4 patchelf rpm-build cpio file && ./build.sh 0.2.12'
```

### Build with Fedora Toolbox

```bash
toolbox create woeusb-build
toolbox enter woeusb-build
sudo dnf install -y git wget python3 python3-pip python3-wxpython4 patchelf rpm-build cpio file
./build.sh 0.2.12
```

### Project structure

```
.
├── build.sh                  # Main build script
├── resources/
│   ├── AppRun                # AppImage entry point / launcher
│   └── woeusb-ng.desktop     # Desktop entry for app menus
└── build/                    # Created during build (gitignored)
    ├── WoeUSB-ng/            # Cloned source
    ├── deps-rpms/            # Downloaded RPMs
    ├── AppDir/               # Assembled AppImage contents
    └── WoeUSB-ng-*.AppImage  # Final output
```

### How the build works

1. Clones WoeUSB-ng at the specified git tag
2. Downloads runtime dependency RPMs from Fedora repos (single batched `dnf download`)
3. Extracts RPMs and flattens the directory structure into an AppDir
4. Copies the host Python interpreter, stdlib, and wxPython into the AppDir
5. Patches all ELF binaries with relative RPATHs so they find bundled libraries
6. Generates GTK/GDK caches and compiles GLib schemas
7. Packages everything into an AppImage using appimagetool

### Rebuilding for a new WoeUSB-ng version

```bash
./build.sh <new-version>
```

The version must correspond to a `v<version>` git tag on the [WoeUSB-ng repo](https://github.com/WoeUSB/WoeUSB-ng/tags).

## License

WoeUSB-ng is licensed under [GPL-3.0](https://github.com/WoeUSB/WoeUSB-ng/blob/master/COPYING). This build tooling is provided under the same license.
