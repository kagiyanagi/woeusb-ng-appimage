#!/bin/bash
# Smoke-test the AppImage on bare distro containers: the CLI starts, every
# bundled ELF resolves against that distro's own libraries, the bundled tools
# work, and the GUI opens its window on X11 and on Wayland.
# Usage: ./test.sh WoeUSB-ng-*.AppImage IMAGE...
set -uo pipefail

app=$(realpath "$1"); shift
engine=$(docker info >/dev/null 2>&1 && echo docker || echo podman)
tmp=$(mktemp -d)
mkdir "$tmp"/{x11,fonts,mime,xkb}
failed=()

# The sidecar runs Xvfb and Weston inside it (headless Weston has no seat,
# which crashes wxGTK), and shares what every desktop has but bare images
# lack: fonts, the MIME database (gdk-pixbuf needs it to detect PNGs) and the
# XKB keymaps.
"$engine" run -d --rm --name woeusb-xvfb -v "$tmp:/t" -v "$tmp/x11:/tmp/.X11-unix" docker.io/library/alpine sh -c '
    apk add -q xvfb xwininfo font-dejavu shared-mime-info xkeyboard-config weston weston-backend-x11 weston-shell-desktop &&
    cp -rL /usr/share/fonts/. /t/fonts && cp -rL /usr/share/mime/. /t/mime && cp -rL /usr/share/X11/xkb/. /t/xkb &&
    mkdir -m 700 /t/wl || exit
    Xvfb :99 -nolisten tcp & until [ -S /tmp/.X11-unix/X99 ]; do sleep 1; done
    DISPLAY=:99 XDG_RUNTIME_DIR=/t/wl exec weston --backend=x11 --renderer=pixman --idle-time=0 --socket=wayland-1' \
    >/dev/null || exit 1
trap '"$engine" rm -f woeusb-xvfb >/dev/null; rm -rf "$tmp"' EXIT
timeout 600 sh -c 'until "$0" exec woeusb-xvfb test -S /tmp/.X11-unix/X99 -a -S /t/wl/wayland-1; do sleep 1; done' \
    "$engine" 2>/dev/null || { echo "Xvfb or Weston did not start"; exit 1; }

opts=(-e APPIMAGE_EXTRACT_AND_RUN=1 -v "$app:/app:ro")
desktop=(-v "$tmp/fonts:/usr/share/fonts:ro" -v "$tmp/mime:/usr/share/mime:ro" -v "$tmp/xkb:/usr/share/X11/xkb:ro")
x11=(-e DISPLAY=:99 -v "$tmp/x11:/tmp/.X11-unix")
# No DISPLAY: X11 is out of reach, as it is for root under Hyprland or Sway.
wayland=(-e WAYLAND_DISPLAY=wayland-1 -e XDG_RUNTIME_DIR=/run/wl -e WAYLAND_DEBUG=client -v "$tmp/wl:/run/wl")
# Not piped: grep -q exits at the first match, and the writer's SIGPIPE would
# fail the pipe under pipefail. Weston has no window list, so the Wayland check
# looks for the title in the protocol log.
x11_up() { grep -q '"WoeUSB-ng"' < <("$engine" exec woeusb-xvfb xwininfo -root -tree -display :99); }
wayland_up() { grep -q 'set_title("WoeUSB-ng")' < <("$engine" logs "$cid" 2>&1); }

# gui NAME UP_CHECK ENGINE_OPTS...: the GUI opens its window, without warnings.
# It lists drives with lsblk and find at startup; bare openSUSE images lack
# them, real systems never do.
gui() {
    local name=$1 up=$2 cid log; shift 2
    cid=$("$engine" run -d "${opts[@]}" "${desktop[@]}" "$@" "$image" bash -c \
        'for t in lsblk find; do command -v $t >/dev/null || ln -s /bin/true /usr/bin/$t; done; exec /app')
    for _ in $(seq 90); do
        "$up" && break
        [ "$("$engine" inspect -f '{{.State.Running}}' "$cid")" = true ] || break
        sleep 1
    done
    "$up" || failed+=("$image: GUI on $name")
    log=$("$engine" logs "$cid" 2>&1 | grep -v '^\[')  # drop WAYLAND_DEBUG's protocol lines
    [ -z "$log" ] || echo "$log" | sed "s/^/  $name: /"
    grep -qE 'G[dt]k-(WARNING|CRITICAL)|undefined symbol|Failed to load module|Fontconfig' <<<"$log" && \
        failed+=("$image: GUI warnings on $name")
    # The AppImage runtime is PID 1 and ignores SIGTERM, which rm -f sends first.
    "$engine" kill "$cid" >/dev/null 2>&1; "$engine" rm -f "$cid" >/dev/null
}

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

    gui X11 x11_up "${x11[@]}"
    gui Wayland wayland_up "${wayland[@]}"
done

[ ${#failed[@]} -eq 0 ] || { printf 'FAILED %s\n' "${failed[@]}"; exit 1; }
echo "All passed"
