#!/bin/bash
# Smoke-test the AppImage on bare distro containers: the CLI starts, every
# bundled ELF resolves against that distro's own libraries, the bundled tools
# work, and the GUI opens its window on a virtual X display.
# Usage: ./test.sh WoeUSB-ng-*.AppImage IMAGE...
set -uo pipefail

app=$(realpath "$1"); shift
engine=$(docker info >/dev/null 2>&1 && echo docker || echo podman)
tmp=$(mktemp -d)
mkdir "$tmp"/{x11,fontconf,fonts,mime}
failed=()

# The sidecar runs Xvfb and shares what every desktop has but bare images
# lack: fonts and the MIME database (gdk-pixbuf needs it to detect PNGs).
"$engine" run -d --rm --name woeusb-xvfb -v "$tmp:/t" -v "$tmp/x11:/tmp/.X11-unix" docker.io/library/alpine sh -c '
    apk add -q xvfb xwininfo fontconfig font-dejavu shared-mime-info &&
    cp -rL /etc/fonts/. /t/fontconf && cp -rL /usr/share/fonts/. /t/fonts && cp -rL /usr/share/mime/. /t/mime &&
    exec Xvfb :99 -nolisten tcp' >/dev/null || exit 1
trap '"$engine" rm -f woeusb-xvfb >/dev/null; rm -rf "$tmp"' EXIT
timeout 600 sh -c 'until [ -S "$0/X99" ]; do sleep 1; done' "$tmp/x11" || { echo "Xvfb did not start"; exit 1; }

opts=(-e APPIMAGE_EXTRACT_AND_RUN=1 -e DISPLAY=:99 -v "$tmp/x11:/tmp/.X11-unix" -v "$app:/app:ro")
desktop=(-v "$tmp/fontconf:/etc/fonts:ro" -v "$tmp/fonts:/usr/share/fonts:ro" -v "$tmp/mime:/usr/share/mime:ro")
for image in "$@"; do
    echo "=== $image"
    "$engine" run --rm "${opts[@]}" "$image" /app --version || { failed+=("$image: CLI"); continue; }

    missing=$("$engine" run --rm "${opts[@]}" "$image" bash -c '
        cd /tmp && /app --appimage-extract >/dev/null &&
        find /tmp/squashfs-root -type f \( -name "*.so*" -o -perm -u+x \) -exec ldd {} + 2>/dev/null' \
        | awk '/:$/ {f = $1} /not found/ {print "  " $1 " <- " f}')
    [ -z "$missing" ] || { echo "Missing libraries:"; echo "$missing"; failed+=("$image: libraries"); }

    # The tools WoeUSB-ng runs must work from the AppImage, not only load.
    out=$("$engine" run --rm "${opts[@]}" "$image" bash -c '
        cd /tmp && /app --appimage-extract >/dev/null && u=squashfs-root/usr &&
        truncate -s 64M disk fat ntfs &&
        $u/sbin/parted -s disk mklabel msdos mkpart primary 1MiB 100% &&
        $u/sbin/mkfs.fat -F 32 fat && $u/sbin/mkntfs -FQq ntfs &&
        $u/bin/7z a t.7z /etc/hostname && $u/bin/7z t t.7z' 2>&1) || \
        { echo "$out"; failed+=("$image: tools"); }

    # The GUI lists drives with lsblk and find at startup; bare openSUSE images
    # lack them, real systems never do.
    cid=$("$engine" run -d "${opts[@]}" "${desktop[@]}" "$image" bash -c \
        'for t in lsblk find; do command -v $t >/dev/null || ln -s /bin/true /usr/bin/$t; done; exec /app')
    for _ in $(seq 90); do
        "$engine" exec woeusb-xvfb xwininfo -root -tree -display :99 | grep -q '"WoeUSB-ng"' && break
        [ "$("$engine" inspect -f '{{.State.Running}}' "$cid")" = true ] || break
        sleep 1
    done
    "$engine" exec woeusb-xvfb xwininfo -root -tree -display :99 | grep -q '"WoeUSB-ng"' || \
        failed+=("$image: GUI")
    log=$("$engine" logs "$cid" 2>&1)
    [ -z "$log" ] || echo "$log" | sed 's/^/  gui: /'
    grep -qE 'Gtk-(WARNING|CRITICAL)|undefined symbol|Failed to load module' <<<"$log" && \
        failed+=("$image: GUI warnings")
    "$engine" rm -f "$cid" >/dev/null
done

[ ${#failed[@]} -eq 0 ] || { printf 'FAILED %s\n' "${failed[@]}"; exit 1; }
echo "All passed"
