#!/bin/bash
# install.sh -- deploy gpsd-static-feed: renders the templates in this repo,
# installs them, points gpsd at /dev/gpsd0, enables the feed.
#
# Usage: sudo ./install.sh [INSTALL_DIR]   # default /opt/gpsd-static
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${1:-${INSTALL_DIR:-/opt/gpsd-static}}"

if [ "$(id -u)" -ne 0 ]; then
    echo "install.sh: must be run as root (sudo ./install.sh)" >&2
    exit 1
fi

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    echo "install.sh: can't determine the non-root user to install for." >&2
    echo "            Run this via 'sudo ./install.sh' as that user, not as root directly." >&2
    exit 1
fi
echo "==> Installing to $INSTALL_DIR for user $TARGET_USER"

render() {
    sed -e "s|@USER@|$TARGET_USER|g" -e "s|@INSTALL_DIR@|$INSTALL_DIR|g" "$1"
}

install_templated() {
    # install_templated <source> <dest> <mode>
    local rendered
    rendered="$(mktemp)"
    render "$1" > "$rendered"
    install -m "$3" "$rendered" "$2"
    rm -f "$rendered"
}

echo "==> Copying runtime files to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp -a "$HERE/static-gps-feed.py" "$HERE/gpsd-static-ctl.sh" "$HERE/README.md" "$INSTALL_DIR/"
chown -R "$TARGET_USER:$TARGET_USER" "$INSTALL_DIR"

echo "==> Installing tmpfiles.d rule and creating /dev/gpsd0"
install_templated "$HERE/gpsd-static.tmpfiles.conf" /etc/tmpfiles.d/gpsd-static.conf 0644
systemd-tmpfiles --create /etc/tmpfiles.d/gpsd-static.conf
ls -l /dev/gpsd0

echo "==> Installing static-gps-feed.service"
install_templated "$HERE/static-gps-feed.service" /etc/systemd/system/static-gps-feed.service 0644

if [ ! -f /etc/default/static-gps-feed ]; then
    install -m 0644 "$HERE/default-static-gps-feed" /etc/default/static-gps-feed
    echo "    Installed /etc/default/static-gps-feed with a placeholder position."
    echo "    Edit STATIC_POSITION in that file to your real lat,lon[,alt]."
else
    echo "    /etc/default/static-gps-feed already exists, leaving it alone."
fi

echo "==> Pointing gpsd at /dev/gpsd0 (backing up /etc/default/gpsd -> .bak)"
cp -n /etc/default/gpsd /etc/default/gpsd.bak
sed -i \
    -e 's|^DEVICES=.*|DEVICES="/dev/gpsd0"|' \
    -e 's|^GPSD_OPTIONS=.*|GPSD_OPTIONS="-n"|' \
    /etc/default/gpsd
grep -E '^(DEVICES|GPSD_OPTIONS)=' /etc/default/gpsd

echo "==> Reloading systemd and enabling services"
systemctl daemon-reload
systemctl enable --now static-gps-feed.service
systemctl restart gpsd.service

echo "==> Installing sudoers rule so gpsd-static-ctl.sh can start/stop without a password prompt"
sudoers_rendered="$(mktemp)"
render "$HERE/sudoers-static-gps-feed" > "$sudoers_rendered"
visudo -c -f "$sudoers_rendered"
install -m 0440 "$sudoers_rendered" /etc/sudoers.d/static-gps-feed
rm -f "$sudoers_rendered"

# So uninstall.sh doesn't need INSTALL_DIR repeated.
echo "$INSTALL_DIR" > /etc/gpsd-static-feed.installdir

echo "==> Done. Check with:"
echo "      systemctl status static-gps-feed.service gpsd.service"
echo "      cgps    # should show a 3D fix at the configured position"
echo "      $INSTALL_DIR/gpsd-static-ctl.sh {start|stop|restart|status}"
