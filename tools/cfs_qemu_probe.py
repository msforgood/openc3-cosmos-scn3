#!/usr/bin/env python3
"""Send standard cFS telecommands to the QEMU cFS and decode the telemetry.

Verifies the TC/TM path without the cFS OpenC3 plugin. Run it inside the
OpenC3 operator container, which owns 172.21.0.2 on cfs-telemetry-link where
the QEMU TO_LAB sends telemetry:

  docker cp tools/cfs_qemu_probe.py openc3-cosmos-scn3-openc3-operator-1:/tmp/
  docker exec -it openc3-cosmos-scn3-openc3-operator-1 python3 /tmp/cfs_qemu_probe.py

Telecommands sent (cFE/cFS default message IDs, override with the options):
  TO_LAB_CMD_ENABLE_OUTPUT (DEST_IP) -> telemetry starts arriving on UDP 1236
  CFE_ES_CMD_NOOP                    -> CFE_ES_HK COMMAND_COUNTER + 1
  CFE_ES_SEND_HK_CMD                 -> fresh CFE_ES_HK packet
  CFE_EVS_CMD_NOOP                   -> "No-op command" event message

Only the standard no-op / housekeeping / TO output commands are sent. The UDP
telemetry port must be free: stop the cFS plugin interface first if installed.
"""

import argparse
import socket
import struct
import time
from collections import Counter

CMD_HDR = 8   # CCSDS primary (6) + cFE command secondary header (function code, checksum)
TLM_HDR = 12  # CCSDS primary (6) + cFE telemetry secondary header (6 byte time)


def command(mid, function_code, payload=b""):
    """Build a cFE command packet: big endian CCSDS header, cFE XOR checksum."""
    length = CMD_HDR + len(payload) - 7
    packet = bytearray(struct.pack(">HHHBB", mid, 0xC000, length, function_code, 0) + payload)
    checksum = 0xFF
    for byte in packet:
        checksum ^= byte
    packet[7] = checksum
    return bytes(packet)


def describe(mid, data, args):
    if mid == args.es_hk_mid and len(data) >= TLM_HDR + 2:
        cmd_cnt, err_cnt = data[TLM_HDR], data[TLM_HDR + 1]
        return f"CFE_ES_HK COMMAND_COUNTER={cmd_cnt} COMMAND_ERROR_COUNTER={err_cnt}"
    if mid == args.evs_long_event_mid and len(data) >= TLM_HDR + 32:
        app = data[TLM_HDR:TLM_HDR + 20].split(b"\0")[0].decode(errors="replace")
        event_id, event_type = struct.unpack_from("<HH", data, TLM_HDR + 20)
        message = data[TLM_HDR + 32:].split(b"\0")[0].decode(errors="replace")
        return f"EVS EVENT {app} id={event_id} type={event_type}: {message}"
    return f"len={len(data)} payload={data[TLM_HDR:TLM_HDR + 16].hex()}"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--host", default="qemu-cfs", help="cFS CI_LAB host (default qemu-cfs)")
    parser.add_argument("--cmd-port", type=int, default=1234, help="CI_LAB UDP port (default 1234)")
    parser.add_argument("--tlm-port", type=int, default=1236, help="TO_LAB UDP port to listen on (default 1236)")
    parser.add_argument("--dest-ip", default="172.21.0.2", help="DEST_IP for TO_LAB_CMD_ENABLE_OUTPUT")
    parser.add_argument("--listen", type=float, default=10.0, help="seconds to listen for telemetry")
    parser.add_argument("--no-enable", action="store_true", help="do not send TO_LAB_CMD_ENABLE_OUTPUT")
    parser.add_argument("--to-lab-cmd-mid", type=lambda v: int(v, 0), default=0x1880)
    parser.add_argument("--es-cmd-mid", type=lambda v: int(v, 0), default=0x1806)
    parser.add_argument("--es-send-hk-mid", type=lambda v: int(v, 0), default=0x1808)
    parser.add_argument("--evs-cmd-mid", type=lambda v: int(v, 0), default=0x1801)
    parser.add_argument("--es-hk-mid", type=lambda v: int(v, 0), default=0x0800)
    parser.add_argument("--evs-long-event-mid", type=lambda v: int(v, 0), default=0x0808)
    args = parser.parse_args()

    tlm = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        tlm.bind(("0.0.0.0", args.tlm_port))
    except OSError as error:
        raise SystemExit(f"UDP {args.tlm_port} is in use ({error}); stop the cFS plugin interface first")
    tlm.settimeout(0.5)

    target = (socket.gethostbyname(args.host), args.cmd_port)
    cmd = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sends = []
    if not args.no_enable:
        dest = args.dest_ip.encode().ljust(16, b"\0")[:16]
        sends.append(("TO_LAB_CMD_ENABLE_OUTPUT", command(args.to_lab_cmd_mid, 6, dest)))
    sends += [
        ("CFE_ES_CMD_NOOP", command(args.es_cmd_mid, 0)),
        ("CFE_ES_SEND_HK_CMD", command(args.es_send_hk_mid, 0)),
        ("CFE_EVS_CMD_NOOP", command(args.evs_cmd_mid, 0)),
    ]
    print(f"TC -> {args.host} {target[0]}:{args.cmd_port}, TM <- UDP {args.tlm_port}")
    for name, packet in sends:
        cmd.sendto(packet, target)
        print(f"  sent {name:26s} {packet.hex()}")
        time.sleep(0.5)

    counts = Counter()
    end = time.time() + args.listen
    while time.time() < end:
        try:
            data, source = tlm.recvfrom(65535)
        except socket.timeout:
            continue
        if len(data) < 6:
            continue
        mid = struct.unpack_from(">H", data)[0]
        counts[mid] += 1
        print(f"  TM {source[0]} MID=0x{mid:04X} {describe(mid, data, args)}")

    print("Summary (MID: packets):", ", ".join(f"0x{mid:04X}: {n}" for mid, n in sorted(counts.items())) or "no telemetry")
    if not counts:
        print("No telemetry: check that qemu-cfs is OPERATIONAL and the TO_LAB/CI_LAB message IDs")


if __name__ == "__main__":
    main()
