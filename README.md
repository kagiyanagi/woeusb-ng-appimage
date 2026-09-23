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
- **Every library they link** except glibc and the GCC runtime

It runs on any x86_64 distro with glibc 2.34 or newer: RHEL/AlmaLinux/Rocky 9+, Debian 12+, Ubuntu 22.04+, openSUSE Leap 15.6+ and Tumbleweed, Fedora, Arch. Standard system utilities (mount, lsblk, grep, etc.), fonts and the MIME database are expected from the host.

## Building from source

The build script bundles AlmaLinux 9 + EPEL RPMs fetched with `dnf download`, so it runs in an AlmaLinux 9 container on any distro:

```bash
podman run --rm -v "$PWD":/build:Z -w /build almalinux:9 bash -c \
  'dnf install -y epel-release && dnf install -y dnf-plugins-core git cpio file patchelf && ./build.sh'
```

`docker run` takes the same arguments. Build on EL9, not something newer: glibc isn't bundled, so the build's glibc is the oldest one the AppImage runs on, and the build fails if any binary needs a newer one.

`./build.sh` builds WoeUSB-ng v0.2.12. Pass a version (`./build.sh 0.2.12`) to build another `v<version>` tag from the [WoeUSB-ng repo](https://github.com/WoeUSB/WoeUSB-ng/tags). The AppImage lands in `build/WoeUSB-ng-<version>-x86_64.AppImage`.

### How the build works

1. Clones WoeUSB-ng at the specified git tag
2. Downloads runtime dependency RPMs from AlmaLinux 9 and EPEL (single batched `dnf download`), including Python and wxPython
3. Extracts the RPMs into an AppDir and copies WoeUSB-ng into the bundled Python's site-packages
4. Points every ELF file's RPATH at the bundled libraries, so nothing leaks into host tools through `LD_LIBRARY_PATH`
5. Audits every ELF file: all libraries except glibc and the GCC runtime must resolve inside the AppDir, and nothing may need a glibc newer than 2.34
6. Checks that the bundled Python imports WoeUSB-ng and wxPython from the AppDir, not the build host
7. Packages everything into an AppImage using appimagetool

### Testing

The build machine has its own libraries and Python, which can hide what a user's machine lacks, so test the AppImage on other distros:

```bash
./test.sh build/WoeUSB-ng-*-x86_64.AppImage docker.io/library/debian:13 docker.io/opensuse/leap:15.6
```

For each image it checks that the CLI starts, that every bundled ELF file resolves against that distro's own libraries, and that the GUI opens its window on a virtual X display. It needs podman or docker; the CI workflow runs it on nine distros.

## License

WoeUSB-ng is licensed under [GPL-3.0](https://github.com/WoeUSB/WoeUSB-ng/blob/master/COPYING). This build tooling is provided under the same license.
