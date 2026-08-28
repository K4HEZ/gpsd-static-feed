#!/bin/bash
# gpsd-static-ctl.sh -- control the static-position gpsd feed, and swap
# gpsd between it and real GPS hardware without restarting gpsd itself.
# Needs the sudoers rule install.sh installs, for unattended use.
#
# Usage:
#   gpsd-static-ctl.sh {start|stop|restart|status}
#   gpsd-static-ctl.sh hardware /dev/ttyUSB0   # switch gpsd to real hardware
#   gpsd-static-ctl.sh static                  # switch gpsd back to /dev/gpsd0
set -euo pipefail

UNIT=static-gps-feed.service
SYSTEMCTL=/usr/bin/systemctl
GPSDCTL=/usr/sbin/gpsdctl
STATIC_DEVICE=/dev/gpsd0

# Remembers which hardware device `hardware` last attached, so `static` can
# cleanly detach it without you having to repeat the device path.
STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/gpsd-static-ctl.hwdevice"

usage() {
    echo "usage: $(basename "$0") {start|stop|restart|status}" >&2
    echo "       $(basename "$0") hardware /dev/ttyUSB0" >&2
    echo "       $(basename "$0") static" >&2
    exit 2
}

cmd_service() {
    exec sudo "$SYSTEMCTL" "$1" "$UNIT"
}

cmd_hardware() {
    local dev="${1:-}"
    [ -n "$dev" ] || { echo "usage: $(basename "$0") hardware /dev/ttyUSB0" >&2; exit 2; }

    echo "==> stopping static feed"
    sudo "$SYSTEMCTL" stop "$UNIT"

    echo "==> gpsd: $STATIC_DEVICE -> $dev (no gpsd restart, existing clients stay connected)"
    sudo "$GPSDCTL" remove "$STATIC_DEVICE" || true
    sudo "$GPSDCTL" add "$dev"

    echo "$dev" > "$STATE_FILE"
    echo "gpsd-static-ctl: gpsd is now reading real hardware at $dev"
}

cmd_static() {
    if [ -f "$STATE_FILE" ]; then
        local dev
        dev="$(cat "$STATE_FILE")"
        echo "==> gpsd: $dev -> $STATIC_DEVICE"
        sudo "$GPSDCTL" remove "$dev" || true
        rm -f "$STATE_FILE"
    fi

    sudo "$GPSDCTL" add "$STATIC_DEVICE"
    sudo "$SYSTEMCTL" start "$UNIT"
    echo "gpsd-static-ctl: gpsd is back on the static position feed"
}

case "${1:-}" in
    start|stop|restart|status)
        cmd_service "$1"
        ;;
    hardware)
        cmd_hardware "${2:-}"
        ;;
    static)
        cmd_static
        ;;
    *)
        usage
        ;;
esac
