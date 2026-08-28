#!/usr/bin/env python3
"""static-gps-feed -- feed a fixed lat/lon/alt into gpsd as if it were a GPS.

Writes checksummed $GPGGA/$GPRMC sentences at a fixed cadence into a FIFO
(default /dev/gpsd0) that gpsd reads like any other serial device. See
README.md for why (AppArmor, gpsd's non-tty handling, no source patches).

Usage:
    static-gps-feed.py --lat 37.6088 --lon -77.3735 --alt 65
    static-gps-feed.py --static-position 37.6088,-77.3735,65
"""
from __future__ import annotations

import argparse
import os
import sys
import time


def nmea_checksum(sentence: str) -> str:
    """XOR checksum of everything between '$' and '*' in an NMEA sentence."""
    cs = 0
    for c in sentence:
        cs ^= ord(c)
    return "%02X" % cs


def to_dm(value: float, is_lat: bool) -> tuple[str, str]:
    """Decimal degrees -> NMEA ddmm.mmmm/dddmm.mmmm + hemisphere letter."""
    hemi = ("N" if value >= 0 else "S") if is_lat else ("E" if value >= 0 else "W")
    value = abs(value)
    deg = int(value)
    minutes = (value - deg) * 60
    width = 2 if is_lat else 3
    return "%0*d%07.4f" % (width, deg, minutes), hemi


def build_sentences(lat: float, lon: float, alt: float) -> list[str]:
    """One GGA (position+alt+fix quality) and one RMC (position+date) pair."""
    now = time.gmtime()
    hhmmss = time.strftime("%H%M%S.00", now)
    ddmmyy = time.strftime("%d%m%y", now)
    latstr, lath = to_dm(lat, True)
    lonstr, lonh = to_dm(lon, False)

    gga = ("GPGGA,%s,%s,%s,%s,%s,1,08,0.9,%.1f,M,0.0,M,,"
           % (hhmmss, latstr, lath, lonstr, lonh, alt))
    rmc = ("GPRMC,%s,A,%s,%s,%s,%s,0.0,0.0,%s,,,A"
           % (hhmmss, latstr, lath, lonstr, lonh, ddmmyy))

    return [
        "$%s*%s\r\n" % (gga, nmea_checksum(gga)),
        "$%s*%s\r\n" % (rmc, nmea_checksum(rmc)),
    ]


def parse_static_position(text: str) -> tuple[float, float, float]:
    parts = text.split(",")
    if len(parts) not in (2, 3):
        raise argparse.ArgumentTypeError(
            "expected LAT,LON[,ALT], e.g. 37.6088,-77.3735,65")
    try:
        lat, lon = float(parts[0]), float(parts[1])
        alt = float(parts[2]) if len(parts) == 3 else 0.0
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc)) from exc
    return lat, lon, alt


def main() -> None:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    pos = p.add_mutually_exclusive_group(required=True)
    pos.add_argument(
        "--static-position", metavar="LAT,LON[,ALT]", type=parse_static_position,
        help="Fixed position as LAT,LON[,ALT] (altitude in meters, default 0)")
    pos.add_argument(
        "--lat", type=float, help="Fixed latitude, decimal degrees (+N/-S)")
    p.add_argument(
        "--lon", type=float, help="Fixed longitude, decimal degrees (+E/-W)")
    p.add_argument(
        "--alt", type=float, default=0.0, help="Fixed altitude, meters [default 0]")
    p.add_argument(
        "--device", default="/dev/gpsd0",
        help="FIFO gpsd reads from [default /dev/gpsd0]")
    p.add_argument(
        "--interval", type=float, default=1.0,
        help="Seconds between fixes [default 1.0]")
    args = p.parse_args()

    if args.static_position:
        lat, lon, alt = args.static_position
    else:
        if args.lon is None:
            p.error("--lon is required when using --lat")
        lat, lon, alt = args.lat, args.lon, args.alt

    if not -90.0 <= lat <= 90.0:
        p.error("latitude must be between -90 and 90")
    if not -180.0 <= lon <= 180.0:
        p.error("longitude must be between -180 and 180")

    # O_RDWR makes us our own reader too, so open() never blocks waiting for
    # gpsd and writes survive gpsd restarts (see `man 7 fifo`).
    fd = os.open(args.device, os.O_RDWR | os.O_NONBLOCK)

    sys.stderr.write(
        "static-gps-feed: feeding %s  lat=%.6f lon=%.6f alt=%.1fm  every %.1fs\n"
        % (args.device, lat, lon, alt, args.interval))

    while True:
        for sentence in build_sentences(lat, lon, alt):
            try:
                os.write(fd, sentence.encode("ascii"))
            except BlockingIOError:
                pass  # reader (gpsd) isn't draining fast enough; drop and retry next cycle
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
