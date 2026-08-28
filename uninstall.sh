#!/bin/bash
# uninstall.sh -- remove everything install.sh set up.
#
# Usage: sudo ./uninstall.sh [--purge]
#   --purge   also delete the configured position and the installed copy.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "uninstall.sh: must be run as root (sudo ./uninstall.sh)" >&2
    exit 1
fi

PURGE=false
if [ "${1:-}" = "--purge" ]; then
    PURGE=true
fi

echo "==> Stopping and disabling static-gps-feed.service"
systemctl disable --now static-gps-feed.service 2>/dev/null || true

echo "==> Removing systemd unit"
rm -f /etc/systemd/system/static-gps-feed.service
systemctl daemon-reload

echo "==> Removing tmpfiles rule and /dev/gpsd0"
rm -f /etc/tmpfiles.d/gpsd-static.conf
rm -f /dev/gpsd0

echo "==> Removing sudoers rule"
rm -f /etc/sudoers.d/static-gps-feed

if [ -f /etc/default/gpsd.bak ]; then
    echo "==> /etc/default/gpsd was backed up at install time. Diff (backup vs. current):"
    diff -u /etc/default/gpsd.bak /etc/default/gpsd || true
    read -r -p "    Restore /etc/default/gpsd from that backup? [y/N] " ans
    if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        cp /etc/default/gpsd.bak /etc/default/gpsd
        rm -f /etc/default/gpsd.bak
        echo "    Restored. Run 'systemctl restart gpsd.service' to apply it."
    else
        echo "    Left /etc/default/gpsd as-is -- edit DEVICES/GPSD_OPTIONS manually if needed."
    fi
else
    echo "==> No /etc/default/gpsd.bak found (already restored, or install.sh never ran here)."
fi

if $PURGE; then
    echo "==> --purge: removing /etc/default/static-gps-feed"
    rm -f /etc/default/static-gps-feed

    if [ -f /etc/gpsd-static-feed.installdir ]; then
        installdir="$(cat /etc/gpsd-static-feed.installdir)"
        if [ -n "$installdir" ] && [ -d "$installdir" ]; then
            echo "==> --purge: removing installed copy at $installdir"
            rm -rf "$installdir"
        fi
        rm -f /etc/gpsd-static-feed.installdir
    fi
else
    echo "==> Leaving /etc/default/static-gps-feed and the installed copy in place."
    echo "    Re-run with --purge to remove those too."
fi

echo "==> Done."
