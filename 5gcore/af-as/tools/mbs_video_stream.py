#!/usr/bin/env python3
"""Stream an MPEG-TS file over the OCUDU MBS multicast GTP-U tunnel."""

import argparse
import bisect
import ipaddress
import os
import signal
import socket
import struct
import sys
import time

TS_PACKET_SIZE = 188
DEFAULT_TS_PACKETS_PER_DATAGRAM = 7


def parse_int(value: str) -> int:
    return int(value, 0)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Pace an MPEG-TS file into GTP-U G-PDUs for the active OCUDU MBS session."
    )
    parser.add_argument("--input", required=True, help="MPEG-TS file visible inside the AF/AS container")
    parser.add_argument("--group", required=True, help="MBS NG-U IPv4 multicast group")
    parser.add_argument("--teid", required=True, type=parse_int, help="Tunnel TEID, for example 0x32a40000")
    parser.add_argument("--port", type=int, default=2152, help="GTP-U destination port")
    parser.add_argument("--interface", help="Source/interface IPv4 address; default uses the routing table")
    parser.add_argument("--bitrate-kbps", type=float, default=180.0,
                        help="rate mode: constant payload bitrate; pcr mode: peak rate cap (never exceeded)")
    parser.add_argument("--pace", choices=("rate", "pcr"), default="rate",
                        help="rate: send at a constant --bitrate-kbps (for CBR files); pcr: follow the stream's PCR clock, "
                             "bursting up to --bitrate-kbps and idling when the content needs less (for capped-VBR files)")
    parser.add_argument("--lookahead-ms", type=float, default=1000.0,
                        help="pcr mode: how far ahead of its content time a datagram may be sent (>= encoder VBV delay)")
    parser.add_argument(
        "--ts-packets-per-datagram",
        type=int,
        default=DEFAULT_TS_PACKETS_PER_DATAGRAM,
        help="Number of 188-byte TS packets in each GTP-U payload",
    )
    parser.add_argument("--loop", action="store_true", help="Loop the video until interrupted")
    parser.add_argument("--duration", type=float, help="Stop after this many seconds")
    parser.add_argument(
        "--log-file",
        default="/tmp/mbs_video_stream.csv",
        help="CSV log for transmitted GTP-U video datagrams; use empty string to disable",
    )
    return parser.parse_args()


def validate_args(args: argparse.Namespace) -> None:
    if not os.path.isfile(args.input):
        raise ValueError(f"input file does not exist: {args.input}")
    if not ipaddress.ip_address(args.group).is_multicast:
        raise ValueError(f"group is not multicast: {args.group}")
    if not 0 < args.teid <= 0xFFFFFFFF:
        raise ValueError("TEID must be in the range 1..0xffffffff")
    if not 0 < args.port <= 65535:
        raise ValueError("port must be in the range 1..65535")
    if args.bitrate_kbps <= 0:
        raise ValueError("bitrate must be greater than zero")
    if not 1 <= args.ts_packets_per_datagram <= 7:
        raise ValueError("ts-packets-per-datagram must be between 1 and 7")


def validate_mpeg_ts(path: str) -> None:
    with open(path, "rb") as media:
        sample = media.read(TS_PACKET_SIZE * 8)
    if len(sample) < TS_PACKET_SIZE or any(
        sample[offset] != 0x47 for offset in range(0, len(sample) - TS_PACKET_SIZE + 1, TS_PACKET_SIZE)
    ):
        raise ValueError("input is not an aligned MPEG-TS file; convert it with the documented ffmpeg command")


def read_pcr_timeline(path: str):
    """Byte offsets and times (s) of every PCR in the file, with 33-bit wrap unrolled."""
    offsets, times = [], []
    with open(path, "rb") as media:
        data = media.read()
    for pos in range(0, len(data) - TS_PACKET_SIZE + 1, TS_PACKET_SIZE):
        pkt = data[pos:pos + TS_PACKET_SIZE]
        afc = (pkt[3] >> 4) & 3
        if afc in (2, 3) and pkt[4] > 0 and pkt[5] & 0x10:
            b = pkt[6:12]
            base = (b[0] << 25) | (b[1] << 17) | (b[2] << 9) | (b[3] << 1) | (b[4] >> 7)
            t = (base * 300 + (((b[4] & 1) << 8) | b[5])) / 27e6
            if times and t < times[-1] - 1000:
                t += (1 << 33) * 300 / 27e6
            offsets.append(pos)
            times.append(t)
    if len(times) < 2:
        raise ValueError("pcr pacing needs a file with PCRs")
    t0 = times[0]
    times = [t - t0 for t in times]
    # Content duration of one pass, extrapolating the last PCR segment to the end of the file.
    rate = (offsets[-1] - offsets[0]) / times[-1]
    period = times[-1] + (len(data) - offsets[-1]) / rate
    return offsets, times, period


def content_time(offsets, times, offset: int) -> float:
    j = max(0, min(bisect.bisect_right(offsets, offset) - 1, len(offsets) - 2))
    o0, o1, a, b = offsets[j], offsets[j + 1], times[j], times[j + 1]
    return a + (offset - o0) * (b - a) / (o1 - o0)


def main() -> int:
    args = parse_args()
    try:
        validate_args(args)
        validate_mpeg_ts(args.input)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
    if args.interface:
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(args.interface))

    stop = False

    def request_stop(_signum: int, _frame: object) -> None:
        nonlocal stop
        stop = True

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)

    payload_size = args.ts_packets_per_datagram * TS_PACKET_SIZE
    bitrate_bps = args.bitrate_kbps * 1000.0
    pcr_timeline = read_pcr_timeline(args.input) if args.pace == "pcr" else None
    lookahead = args.lookahead_ms / 1000.0
    late = 0
    started = time.monotonic()
    next_send = started
    packets = 0
    payload_bytes = 0
    loops = 0
    log_fh = None

    print(
        f"Streaming {args.input} to {args.group}:{args.port} "
        f"TEID=0x{args.teid:08x} bitrate={args.bitrate_kbps:.1f} kbps pace={args.pace}"
        + (f" (cap, lookahead {args.lookahead_ms:.0f} ms, content {pcr_timeline[2]:.1f} s per loop)" if pcr_timeline else "")
    )
    if args.log_file:
        log_fh = open(args.log_file, "w", encoding="utf-8")
        print("seq,loop,file_offset,tx_ns,elapsed_ms,payload_bytes,ts_packets,group,teid_hex", file=log_fh, flush=True)
        print(f"CSV log: {args.log_file}", flush=True)

    try:
        while not stop:
            with open(args.input, "rb") as media:
                while not stop:
                    file_offset = media.tell()
                    payload = media.read(payload_size)
                    if len(payload) < payload_size:
                        break

                    now = time.monotonic()
                    if args.duration is not None and now - started >= args.duration:
                        stop = True
                        break
                    if pcr_timeline:
                        # Deadline = content time of the datagram's last byte. Send no earlier than
                        # (deadline - lookahead) and never faster than the rate cap.
                        offsets, times, period = pcr_timeline
                        deadline = started + loops * period + content_time(offsets, times, file_offset + len(payload) - 1)
                        next_send = max(next_send, deadline - lookahead)
                        if next_send + len(payload) * 8.0 / bitrate_bps > deadline:
                            late += 1
                    if next_send > now:
                        time.sleep(next_send - now)

                    tx_ns = time.time_ns()
                    elapsed_ms = (time.monotonic() - started) * 1000.0
                    gtpu = struct.pack("!BBHI", 0x30, 0xFF, len(payload), args.teid) + payload
                    sock.sendto(gtpu, (args.group, args.port))
                    packets += 1
                    payload_bytes += len(payload)
                    if pcr_timeline:
                        # Space from the ACTUAL send time: no catch-up bursts after an oversleep, so the cap
                        # holds strictly; the lookahead absorbs the small delay.
                        next_send = max(next_send, time.monotonic()) + len(payload) * 8.0 / bitrate_bps
                    else:
                        next_send += len(payload) * 8.0 / bitrate_bps

                    if log_fh is not None:
                        print(
                            f"{packets},{loops},{file_offset},{tx_ns},{elapsed_ms:.3f},"
                            f"{len(payload)},{len(payload) // TS_PACKET_SIZE},{args.group},0x{args.teid:08x}",
                            file=log_fh,
                            flush=True,
                        )

                    if packets % 100 == 0:
                        elapsed = max(time.monotonic() - started, 0.001)
                        actual_kbps = payload_bytes * 8.0 / elapsed / 1000.0
                        print(f"sent={packets} payload={payload_bytes} bytes rate={actual_kbps:.1f} kbps"
                              + (f" late={late}" if pcr_timeline else ""), flush=True)

            if stop or not args.loop:
                break
            loops += 1
            print(f"loop={loops}", flush=True)
    finally:
        if log_fh is not None:
            log_fh.close()

    elapsed = max(time.monotonic() - started, 0.001)
    actual_kbps = payload_bytes * 8.0 / elapsed / 1000.0
    print(f"stopped: packets={packets} payload={payload_bytes} bytes average={actual_kbps:.1f} kbps"
          + (f" late={late}" if pcr_timeline else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
