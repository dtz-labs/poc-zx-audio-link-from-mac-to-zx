#!/usr/bin/env python3
"""Build and transmit a tiny Mac -> Timex audio terminal demo.

Only Python's standard library is required.  The receiver uses the regular
Spectrum/TC2048 ROM tape decoder.  Every line is sent as a headerless,
fixed-size CODE block with flag 0xff.
"""

from __future__ import annotations

import argparse
import io
import struct
import sys
import wave
from pathlib import Path


SAMPLE_RATE = 48_000
ZX_CLOCK_HZ = 3_500_000
AMPLITUDE = 24_000
PAYLOAD_SIZE = 64

PILOT_PULSE = 2_168
SYNC_1 = 667
SYNC_2 = 735
ZERO_PULSE = 855
ONE_PULSE = 1_710
DATA_PILOT_PULSES = 3_223
HEADER_PILOT_PULSES = 8_063


class PulseWriter:
    def __init__(self, output: io.BufferedWriter, sample_rate: int = SAMPLE_RATE):
        self.output = output
        self.sample_rate = sample_rate
        self.level = -AMPLITUDE
        self.sample_position = 0.0

    def silence(self, seconds: float) -> None:
        count = round(seconds * self.sample_rate)
        self.output.write(struct.pack("<h", 0) * count)

    def pulse(self, tstates: int) -> None:
        exact_end = self.sample_position + tstates * self.sample_rate / ZX_CLOCK_HZ
        count = max(1, round(exact_end) - round(self.sample_position))
        self.output.write(struct.pack("<h", self.level) * count)
        self.sample_position = exact_end
        self.level = -self.level

    def tape_block(self, block: bytes, *, header: bool = False) -> None:
        pilot_count = HEADER_PILOT_PULSES if header else DATA_PILOT_PULSES
        for _ in range(pilot_count):
            self.pulse(PILOT_PULSE)
        self.pulse(SYNC_1)
        self.pulse(SYNC_2)
        for byte in block:
            for shift in range(7, -1, -1):
                width = ONE_PULSE if byte & (1 << shift) else ZERO_PULSE
                self.pulse(width)
                self.pulse(width)


def xor_checksum(data: bytes) -> int:
    value = 0
    for byte in data:
        value ^= byte
    return value


def tap_block(data: bytes) -> bytes:
    return struct.pack("<H", len(data)) + data


def make_tap_data_block(flag: int, body: bytes) -> bytes:
    block_without_checksum = bytes([flag]) + body
    return block_without_checksum + bytes([xor_checksum(block_without_checksum)])


def basic_integer(value: int) -> bytes:
    if not 0 <= value <= 65_535:
        raise ValueError("only non-negative 16-bit BASIC integers are supported")
    return b"\x0e\x00\x00" + struct.pack("<H", value) + b"\x00"


def make_basic_loader(load_address: int) -> bytes:
    # 10 LOAD "" CODE: RANDOMIZE USR 32768
    body = (
        b"\xef\x20\x22\x22\x20\xaf\x3a\x20\xf9\x20\xc0\x20"
        + str(load_address).encode("ascii")
        + basic_integer(load_address)
        + b"\x0d"
    )
    return b"\x00\x0a" + struct.pack("<H", len(body)) + body


def make_receiver_code(origin: int = 0x8000) -> bytes:
    # ROM calls used here are compatible with the ZX Spectrum 48K/TC2048 ROM:
    # RST 10h prints one character; CALL 0556h is LD-BYTES.
    banner = b"ZX AUDIO LINK READY\r\x00"
    code_len = 0x25
    banner_address = origin + code_len
    buffer_address = banner_address + len(banner)

    code = bytearray(
        [
            0x21,
            banner_address & 0xFF,
            banner_address >> 8,  # LD HL,banner
            0x7E,  # print_banner: LD A,(HL)
            0x23,  # INC HL
            0xB7,  # OR A
            0x28,
            0x03,  # JR Z,receive
            0xD7,  # RST 10h
            0x18,
            0xF8,  # JR print_banner
            0xDD,
            0x21,
            buffer_address & 0xFF,
            buffer_address >> 8,  # receive: LD IX,buffer
            0x11,
            PAYLOAD_SIZE,
            0x00,  # LD DE,64
            0x3E,
            0xFF,  # LD A,ffh
            0x37,  # SCF (LOAD, not VERIFY)
            0xCD,
            0x56,
            0x05,  # CALL LD-BYTES
            0x30,
            0xF1,  # JR NC,receive
            0x21,
            buffer_address & 0xFF,
            buffer_address >> 8,  # LD HL,buffer
            0x7E,  # print: LD A,(HL)
            0x23,  # INC HL
            0xB7,  # OR A
            0x28,
            0xE9,  # JR Z,receive
            0xD7,  # RST 10h
            0x18,
            0xF8,  # JR print
        ]
    )
    assert len(code) == code_len
    return bytes(code) + banner + bytes(PAYLOAD_SIZE)


def make_receiver_tap() -> bytes:
    origin = 0x8000
    basic = make_basic_loader(origin)
    code = make_receiver_code(origin)

    basic_header_body = (
        bytes([0])
        + b"ZXLINK    "
        + struct.pack("<H", len(basic))
        + struct.pack("<H", 10)
        + struct.pack("<H", len(basic))
    )
    code_header_body = (
        bytes([3])
        + b"ZXLINKCODE"
        + struct.pack("<H", len(code))
        + struct.pack("<H", origin)
        + struct.pack("<H", 0x8000)
    )

    blocks = [
        make_tap_data_block(0x00, basic_header_body),
        make_tap_data_block(0xFF, basic),
        make_tap_data_block(0x00, code_header_body),
        make_tap_data_block(0xFF, code),
    ]
    return b"".join(tap_block(block) for block in blocks)


def payloads_for_text(text: str) -> list[bytes]:
    encoded = text.encode("ascii", errors="replace")
    # Leave room for CR and the zero terminator.
    chunk_size = PAYLOAD_SIZE - 2
    chunks = [
        encoded[i : i + chunk_size] for i in range(0, len(encoded), chunk_size)
    ] or [b""]
    payloads: list[bytes] = []
    for index, chunk in enumerate(chunks):
        suffix = b"\r" if index == len(chunks) - 1 else b""
        content = chunk + suffix + b"\x00"
        payloads.append(content.ljust(PAYLOAD_SIZE, b"\x00"))
    return payloads


def write_payload_audio(writer: PulseWriter, payload: bytes) -> None:
    writer.silence(0.20)
    writer.tape_block(make_tap_data_block(0xFF, payload), header=False)
    writer.silence(0.20)


def command_build(args: argparse.Namespace) -> None:
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(make_receiver_tap())
    print(f"Wrote receiver tape: {output}", file=sys.stderr)


def command_wav(args: argparse.Namespace) -> None:
    raw = io.BytesIO()
    writer = PulseWriter(raw)
    for payload in payloads_for_text(args.text):
        write_payload_audio(writer, payload)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(output), "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(SAMPLE_RATE)
        wav_file.writeframes(raw.getvalue())
    print(f"Wrote message audio: {output}", file=sys.stderr)


def command_demo(args: argparse.Namespace) -> None:
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    data = bytearray(make_receiver_tap())
    for payload in payloads_for_text(args.text):
        data.extend(tap_block(make_tap_data_block(0xFF, payload)))
    output.write_bytes(data)
    print(f"Wrote receiver self-test tape: {output}", file=sys.stderr)


def command_stream(args: argparse.Namespace) -> None:
    output = sys.stdout.buffer
    writer = PulseWriter(output)

    if args.text:
        lines = args.text
    else:
        if sys.stdin.isatty():
            print("Type text and press Return; Ctrl-D finishes.", file=sys.stderr)
        lines = (line.rstrip("\n") for line in sys.stdin)

    for line in lines:
        for payload in payloads_for_text(line):
            write_payload_audio(writer, payload)
        output.flush()


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subparsers = result.add_subparsers(dest="command", required=True)

    build = subparsers.add_parser("build", help="build the autostart receiver TAP")
    build.add_argument("output")
    build.set_defaults(func=command_build)

    wav = subparsers.add_parser(
        "wav", help="create a finite WAV containing one message"
    )
    wav.add_argument("text")
    wav.add_argument("output")
    wav.set_defaults(func=command_wav)

    demo = subparsers.add_parser(
        "demo", help="build a TAP containing the receiver and a test message"
    )
    demo.add_argument("text")
    demo.add_argument("output")
    demo.set_defaults(func=command_demo)

    stream = subparsers.add_parser(
        "stream", help="write live signed 16-bit mono PCM to stdout"
    )
    stream.add_argument("text", nargs="*")
    stream.set_defaults(func=command_stream)
    return result


def main() -> None:
    args = parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
