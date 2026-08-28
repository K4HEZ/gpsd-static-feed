# gpsd-static-feed

Feed a fixed lat/lon/alt into [`gpsd`](https://gpsd.io/) so clients
(WSJT-X, a Winlink packet-radio repeater, `cgps`, APRS software, etc.) see
an ordinary gpsd TPV fix -- with no real GPS hardware attached. Useful for
a fixed station (home shack, repeater site) where the position never
changes but the software downstream still wants to talk to gpsd.

No gpsd source patches, no AppArmor policy edits, no custom driver code.
Swapping in real GPS hardware later (or back) is a live, one-command
operation with no service restart.

## Why this design

`gpsd`'s driver architecture (`gps_type_t` in `include/gpsd.h`) is built to
parse bytes from a real file descriptor -- there's no hook for "synthesize a
report on a timer, no I/O involved" without also patching gpsd's core
select/poll loop. That's a much bigger, more invasive change than it sounds,
and it'd need redoing on every gpsd upstream update.

Instead: `gpsd` already treats non-tty file descriptors specially --
`gpsd_serial_isatty()` in `gpsd/serial.c` skips all the termios/speed setup
when the source isn't a tty -- so an ordinary FIFO works as a device with
*zero* gpsd source changes. This is the same mechanism gpsd's own `gpsfake`
test harness relies on (see `gpsfake.py.in`), just without a pty.

The FIFO lives at **`/dev/gpsd0`** specifically because Debian/Ubuntu's
`gpsd` package ships an AppArmor profile (`/etc/apparmor.d/usr.sbin.gpsd`)
that restricts which device paths gpsd may open. It allows
`/dev/tty{,S,USB,AMA,ACM}[0-9]*`, `/dev/rfcomm*`, `/dev/pps[0-9]*`, and
`/dev/gpsd[0-9]` -- but *not* `/dev/pts/*`. That's confirmed by testing:
pointing a pty-backed source (e.g. `gpsfake`) at this gpsd produces
`apparmor="DENIED" ... name="/dev/pts/N"` in the kernel log. Using the
pre-whitelisted `/dev/gpsd0` path avoids editing AppArmor policy entirely.
(If your distro's gpsd doesn't run under AppArmor, `/dev/gpsd0` still works
fine -- it's just a plain FIFO either way.)

## Requirements

- Linux with systemd
- `gpsd` (tested against the Debian/Ubuntu 3.25 package; should work with
  any reasonably recent gpsd -- the design doesn't depend on gpsd version
  internals, just the documented non-tty behavior)
- Python 3, `sudo`

## Install

```
git clone https://github.com/<you>/gpsd-static-feed.git
cd gpsd-static-feed
sudo ./install.sh                       # installs to /opt/gpsd-static
# or: sudo ./install.sh /opt/somewhere-else
```

`install.sh`:
- copies `static-gps-feed.py`, `gpsd-static-ctl.sh`, and this README to the
  install directory,
- renders the `static-gps-feed.service`, `gpsd-static.tmpfiles.conf`, and
  `sudoers-static-gps-feed` templates (they contain `@USER@`/
  `@INSTALL_DIR@` placeholders, substituted with whoever ran `sudo` and
  where you're installing) and installs them to their real system
  locations,
- points the system gpsd at `/dev/gpsd0` (`/etc/default/gpsd`:
  `DEVICES="/dev/gpsd0"`, `GPSD_OPTIONS="-n"`, backing up the original to
  `/etc/default/gpsd.bak`),
- enables and starts the feed.

Then edit `/etc/default/static-gps-feed` to your real position and:

```
sudo systemctl restart static-gps-feed
cgps          # should show mode 3D at the configured lat/lon/alt
```

## Uninstall

```
sudo ./uninstall.sh          # stops/removes the service, tmpfiles rule,
                              # sudoers rule; offers to restore the
                              # original /etc/default/gpsd
sudo ./uninstall.sh --purge  # also deletes /etc/default/static-gps-feed
                              # and the installed copy of this repo
```

## Pieces

- `static-gps-feed.py` -- writes correctly-checksummed `$GPGGA`/`$GPRMC` at
  1 Hz (live UTC timestamps, fixed lat/lon/alt) into a FIFO, opened
  `O_RDWR` so it never blocks waiting for gpsd and survives gpsd restarts.
- `gpsd-static-ctl.sh` -- start/stop/status the feed, and hot-swap gpsd
  between it and real hardware (see below).
- `gpsd-static.tmpfiles.conf` -- template; recreates `/dev/gpsd0` on every
  boot (devtmpfs doesn't persist hand-made nodes across a reboot).
- `static-gps-feed.service` -- template; systemd unit running the feeder.
- `sudoers-static-gps-feed` -- template; narrowly-scoped NOPASSWD rule so
  `gpsd-static-ctl.sh` runs unattended from another launcher.
- `default-static-gps-feed` -- installed to `/etc/default/static-gps-feed`,
  holds `STATIC_POSITION=lat,lon[,alt]`.
- `install.sh` / `uninstall.sh` -- see above.

## Changing position later

```
sudoedit /etc/default/static-gps-feed
sudo systemctl restart static-gps-feed
```

No gpsd restart needed -- gpsd just keeps reading from the same FIFO.

## Starting/stopping around another program (e.g. Winlink)

`static-gps-feed.service` is enabled by `install.sh`, so it's already
running continuously in the background -- that's harmless to leave as-is
(gpsd just has no data to report until it's running). If you'd rather
start/stop it explicitly from another script (e.g. right before/after a
Winlink session), use the copy `install.sh` placed in your install
directory:

```
/opt/gpsd-static/gpsd-static-ctl.sh start
/opt/gpsd-static/gpsd-static-ctl.sh stop
/opt/gpsd-static/gpsd-static-ctl.sh status
```

This just wraps `systemctl <verb> static-gps-feed.service`. `install.sh`
also installs `/etc/sudoers.d/static-gps-feed`, a narrowly-scoped rule
allowing only `systemctl {start,stop,restart,status}
static-gps-feed.service` (plus the `gpsdctl` commands below) without a
password, so the control script runs unattended from another launcher.

If you want it to *not* auto-start at boot and only run when explicitly
started this way:

```
sudo systemctl disable static-gps-feed.service
```

(`gpsd` itself should stay running as a normal system service either way --
it's shared infrastructure other things may use, and with no data on
`/dev/gpsd0` it just reports no fix.)

## Switching to real GPS hardware and back

gpsd always keeps a control socket open (`/run/gpsd.sock`) and `gpsdctl` can
add/remove devices from a *running* gpsd through it -- the same mechanism
`USBAUTO="true"` in `/etc/default/gpsd` already uses to hotplug recognized
USB GPS chipsets (see `/lib/udev/rules.d/60-gpsd.rules` on Debian/Ubuntu).
So switching sources doesn't need a `gpsd.service` restart (which would drop
every client's connection) -- just:

```
gpsd-static-ctl.sh hardware /dev/ttyUSB0   # gpsd: /dev/gpsd0 -> your real GPS
...
gpsd-static-ctl.sh static                  # gpsd: back to /dev/gpsd0, feeder restarted
```

`hardware` remembers which device it attached (in
`${XDG_RUNTIME_DIR:-/tmp}/gpsd-static-ctl.hwdevice`) so `static` can detach
it again without you repeating the path.

Note the naming trap: this project's FIFO is `/dev/gpsd0` (with a "d"). A
recognized USB GPS auto-symlinks to `/dev/gps0` (no "d") via the udev rule
above -- different device, easy to mistype.

`gpsdctl` only works unprivileged against a private *test* instance
(`/tmp/gpsd.sock`, what `gpsfake` uses) -- talking to the real system gpsd
requires root, which is why every call above goes through `sudo`.

## License

MIT, see `LICENSE`.
