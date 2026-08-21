#!/usr/bin/env python3
"""Summarize Pocket 3 RAW-IP PCAP lifecycle evidence without third-party modules."""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import pathlib
import socket
import struct


def packets(path: pathlib.Path):
    with path.open("rb") as handle:
        header = handle.read(24)
        if len(header) != 24:
            raise ValueError("truncated PCAP header")
        magic = header[:4]
        formats = {
            b"\xd4\xc3\xb2\xa1": ("<", 1_000_000),
            b"\xa1\xb2\xc3\xd4": (">", 1_000_000),
            b"\x4d\x3c\xb2\xa1": ("<", 1_000_000_000),
            b"\xa1\xb2\x3c\x4d": (">", 1_000_000_000),
        }
        if magic not in formats:
            raise ValueError(f"unsupported PCAP magic {magic.hex()}")
        endian, scale = formats[magic]
        while True:
            record = handle.read(16)
            if not record:
                return
            if len(record) != 16:
                raise ValueError("truncated PCAP record header")
            seconds, fraction, included, _original = struct.unpack(endian + "IIII", record)
            data = handle.read(included)
            if len(data) != included:
                raise ValueError("truncated PCAP packet")
            yield seconds + fraction / scale, data


def parse_ip(data: bytes):
    if len(data) < 20 or data[0] >> 4 != 4:
        return None
    header_len = (data[0] & 0x0F) * 4
    if header_len < 20 or len(data) < header_len:
        return None
    protocol = data[9]
    source = socket.inet_ntoa(data[12:16])
    destination = socket.inet_ntoa(data[16:20])
    body = data[header_len:]
    if protocol == 17 and len(body) >= 8:
        source_port, destination_port, length, _checksum = struct.unpack("!HHHH", body[:8])
        return ("UDP", source, source_port, destination, destination_port, body[8:length])
    if protocol == 6 and len(body) >= 20:
        source_port, destination_port = struct.unpack("!HH", body[:4])
        offset = (body[12] >> 4) * 4
        return ("TCP", source, source_port, destination, destination_port, body[offset:], body[13])
    return None


def u16le(data: bytes, offset: int) -> int:
    return data[offset] | data[offset + 1] << 8


def crc8(data: bytes, initial: int = 0x77, polynomial: int = 0x8C) -> int:
    value = initial
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = ((value >> 1) ^ polynomial) if value & 1 else value >> 1
    return value & 0xFF


def crc16(data: bytes, initial: int = 0x3692, polynomial: int = 0x8408) -> int:
    value = initial
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = ((value >> 1) ^ polynomial) if value & 1 else value >> 1
    return value & 0xFFFF


def scan_duml(data: bytes):
    for index in range(max(0, len(data) - 12)):
        if data[index] != 0x55 or index + 13 > len(data):
            continue
        packed = data[index + 1] | data[index + 2] << 8
        length = packed & 0x03FF
        version = data[index + 2] >> 2
        if version != 1 or length < 13 or index + length > len(data):
            continue
        frame = data[index:index + length]
        if crc8(frame[:3]) != frame[3] or crc16(frame[:-2]) != u16le(frame, length - 2):
            continue
        yield {
            "offset": index,
            "length": length,
            "target": u16le(frame, 4),
            "id": u16le(frame, 6),
            "flags": frame[8],
            "set": frame[9],
            "cmd": frame[10],
            "payload": frame[11:-2],
        }


def stamp(value: float) -> str:
    return dt.datetime.fromtimestamp(value).isoformat(sep=" ", timespec="microseconds")


def direction(source: str, destination: str) -> str:
    if destination in {"192.168.2.1", "192.168.4.1"}:
        return "app>camera"
    if source in {"192.168.2.1", "192.168.4.1"}:
        return "camera>app"
    return f"{source}>{destination}"


def describe(event, first: float) -> str:
    fields = [f"+{event['time'] - first:10.6f}s", event["direction"]]
    if event["protocol"] == "TCP":
        fields += [f"TCP/{event['port']}", event["flags"]]
    else:
        fields += [f"pkt={event['packet_type']:02X}", f"seq={event['sequence']:04X}"]
        if event["channel"] is not None:
            fields.append(f"ch={event['channel']:04X}")
        if event["commands"]:
            fields.append("DUML=" + ",".join(
                f"{item['set']:02X}/{item['cmd']:02X}"
                f"(f={item['flags']:02X},p={item['payload'][:64].hex()}"
                f"{'…' if len(item['payload']) > 64 else ''})"
                for item in event["commands"]
            ))
    return " ".join(fields)


def edge_relevant(event) -> bool:
    if event["protocol"] == "TCP" or event.get("packet_type") == 0x00:
        return True
    lifecycle_commands = {(0x00, 0x81), (0x00, 0x88), (0x03, 0xDA),
                          (0x04, 0x50), (0x04, 0x01), (0x01, 0x01)}
    return any((item["set"], item["cmd"]) in lifecycle_commands for item in event.get("commands", ()))


def analyze(path: pathlib.Path, edge_seconds: float, selected_command: tuple[int, int] | None):
    events = []
    packet_types = collections.Counter()
    commands = collections.Counter()
    directions = collections.Counter()
    tcp_flags = collections.Counter()
    all_first = None
    all_last = None

    for timestamp, raw in packets(path):
        all_first = timestamp if all_first is None else all_first
        all_last = timestamp
        parsed = parse_ip(raw)
        if parsed is None:
            continue
        protocol, source, source_port, destination, destination_port, body, *extra = parsed
        relevant_port = destination_port if destination_port in {7001, 9004} else source_port
        if relevant_port not in {7001, 9004}:
            continue
        event = {
            "time": timestamp,
            "protocol": protocol,
            "direction": direction(source, destination),
            "port": relevant_port,
        }
        directions[event["direction"]] += 1
        if protocol == "TCP":
            flags_value = extra[0]
            names = "".join(name for bit, name in ((0x02, "S"), (0x10, "A"), (0x01, "F"), (0x04, "R")) if flags_value & bit)
            event["flags"] = names or f"0x{flags_value:02X}"
            tcp_flags[(event["direction"], event["flags"])] += 1
        else:
            if len(body) < 8:
                continue
            event["packet_type"] = body[6]
            event["sequence"] = u16le(body, 4)
            event["channel"] = u16le(body, 8) if len(body) >= 10 else None
            event["commands"] = list(scan_duml(body))
            packet_types[(event["direction"], event["packet_type"])] += 1
            for item in event["commands"]:
                commands[(event["direction"], item["set"], item["cmd"], item["flags"])] += 1
        events.append(event)

    print(f"# {path}")
    print(f"capture_start: {stamp(all_first)}")
    print(f"capture_end:   {stamp(all_last)}")
    print(f"capture_duration_s: {all_last - all_first:.6f}")
    if not events:
        print("No TCP/7001 or UDP/9004 events")
        return
    first = events[0]["time"]
    last = events[-1]["time"]
    print(f"relevant_start: {stamp(first)}")
    print(f"relevant_end:   {stamp(last)}")
    print(f"relevant_duration_s: {last - first:.6f}")
    print("packet_types:")
    for (flow, kind), count in sorted(packet_types.items()):
        print(f"  {flow} {kind:02X}: {count}")
    print("duml_commands:")
    for (flow, command_set, command, flags), count in sorted(commands.items()):
        print(f"  {flow} {command_set:02X}/{command:02X} flags={flags:02X}: {count}")
    print("tcp_flags:")
    for (flow, flags), count in sorted(tcp_flags.items()):
        print(f"  {flow} {flags}: {count}")
    if selected_command is not None:
        print(f"selected_command_{selected_command[0]:02X}/{selected_command[1]:02X}:")
        for event in events:
            matching = [item for item in event.get("commands", ())
                        if (item["set"], item["cmd"]) == selected_command]
            if matching:
                copy = dict(event)
                copy["commands"] = matching
                print("  " + describe(copy, first))
    print(f"first_{edge_seconds:g}s:")
    for event in events:
        if event["time"] - first <= edge_seconds and edge_relevant(event):
            print("  " + describe(event, first))
    print(f"last_{edge_seconds:g}s:")
    for event in events:
        if last - event["time"] <= edge_seconds and edge_relevant(event):
            print("  " + describe(event, first))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("pcap", type=pathlib.Path)
    parser.add_argument("--edge-seconds", type=float, default=5.0)
    parser.add_argument("--command", help="also list every matching DUML set/id, e.g. 01/01")
    args = parser.parse_args()
    selected = None
    if args.command:
        command_set, command = args.command.split("/", 1)
        selected = (int(command_set, 16), int(command, 16))
    analyze(args.pcap, args.edge_seconds, selected)


if __name__ == "__main__":
    main()
