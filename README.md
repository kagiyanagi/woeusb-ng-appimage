# WoeUSB-ng AppImage

Portable, self-contained [AppImage](https://appimage.org/) of [WoeUSB-ng](https://github.com/WoeUSB/WoeUSB-ng) - create bootable Windows USB drives from ISO images on any Linux distro.

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

- **WoeUSB-ng** - the Python application
- **Python 3** interpreter and stdlib
- **wxPython + GTK3** - full GUI stack (wxGTK, Pango, Cairo, GDK, etc.)
- **System tools** - parted, grub2, ntfs-3g (mkntfs), dosfstools (mkfs.fat), p7zip

Standard system utilities (mount, lsblk, grep, etc.) are expected from the host.

## Building from source

The build script fetches Fedora RPMs with `dnf download`, so it runs in a Fedora container on any distro:

```bash
podman run --rm -v "$PWD":/build:Z -w /build fedora:latest bash -c \
  'dnf install -y git cpio file && ./build.sh'
```

`docker run` takes the same arguments. On Fedora or in a toolbox you can run `sudo dnf install -y git cpio file && ./build.sh` directly, but a clean container is safer: the library audit falls back to the build machine's own libraries, so a desktop install can hide libraries missing from the bundle.

`./build.sh` builds WoeUSB-ng v0.2.12. Pass a version (`./build.sh 0.2.12`) to build another `v<version>` tag from the [WoeUSB-ng repo](https://github.com/WoeUSB/WoeUSB-ng/tags). The AppImage lands in `build/WoeUSB-ng-<version>-x86_64.AppImage`.

### How the build works

1. Clones WoeUSB-ng at the specified git tag
2. Downloads runtime dependency RPMs from Fedora repos (single batched `dnf download`), including Python and wxPython
3. Extracts the RPMs into an AppDir and copies WoeUSB-ng into the bundled Python's site-packages
4. Compiles GLib schemas and checks that the bundled Python can import WoeUSB-ng and wxPython
5. Audits every ELF file for missing libraries
6. Packages everything into an AppImage using appimagetool

## License

WoeUSB-ng is licensed under [GPL-3.0](https://github.com/WoeUSB/WoeUSB-ng/blob/master/COPYING). This build tooling is provided under the same license.
