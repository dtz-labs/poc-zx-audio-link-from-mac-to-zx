"""Unit tests for the TAP/audio generator. Standard library + pytest only."""

import io
import struct
import wave

import pytest

import zx_audio_link as zal


def parse_tap(data: bytes) -> list[bytes]:
    """Split a TAP image into its blocks (checksum byte included)."""
    blocks = []
    offset = 0
    while offset < len(data):
        (length,) = struct.unpack_from("<H", data, offset)
        offset += 2
        blocks.append(data[offset : offset + length])
        offset += length
    assert offset == len(data)
    return blocks


def test_xor_checksum():
    assert zal.xor_checksum(b"") == 0
    assert zal.xor_checksum(b"\xff") == 0xFF
    assert zal.xor_checksum(b"\x0f\xf0") == 0xFF
    assert zal.xor_checksum(b"\xaa\xaa") == 0


def test_tap_data_block_has_valid_checksum():
    block = zal.make_tap_data_block(0xFF, b"HELLO")
    assert block[0] == 0xFF
    assert zal.xor_checksum(block) == 0


def test_basic_integer_rejects_out_of_range():
    with pytest.raises(ValueError):
        zal.basic_integer(-1)
    with pytest.raises(ValueError):
        zal.basic_integer(65_536)


def test_receiver_code_fits_declared_layout():
    code = zal.make_receiver_code()
    banner = b"ZX AUDIO LINK READY\r\x00"
    assert banner in code
    # Machine code + banner + receive buffer.
    assert len(code) == 0x25 + len(banner) + zal.PAYLOAD_SIZE


def test_receiver_tap_structure():
    blocks = parse_tap(zal.make_receiver_tap())
    assert len(blocks) == 4
    basic_header, basic, code_header, code = blocks
    for block in blocks:
        assert zal.xor_checksum(block) == 0
    assert basic_header[0] == 0x00 and basic_header[1] == 0
    assert b"ZXLINK    " in basic_header
    assert code_header[0] == 0x00 and code_header[1] == 3
    assert b"ZXLINKCODE" in code_header
    assert basic[0] == 0xFF
    assert code[0] == 0xFF
    # The CODE header must declare the load address 0x8000.
    (load_address,) = struct.unpack_from("<H", code_header, 14)
    assert load_address == 0x8000


def test_payloads_short_text():
    (payload,) = zal.payloads_for_text("HELLO")
    assert len(payload) == zal.PAYLOAD_SIZE
    assert payload.startswith(b"HELLO\r\x00")
    assert payload.rstrip(b"\x00") == b"HELLO\r"


def test_payloads_split_long_text():
    text = "A" * 100
    payloads = zal.payloads_for_text(text)
    assert len(payloads) == 2
    assert all(len(payload) == zal.PAYLOAD_SIZE for payload in payloads)
    # Only the final chunk carries the carriage return.
    assert b"\r" not in payloads[0]
    assert payloads[1].rstrip(b"\x00").endswith(b"\r")


def test_payloads_empty_text():
    (payload,) = zal.payloads_for_text("")
    assert payload.startswith(b"\r\x00")


def test_payloads_replace_non_ascii():
    (payload,) = zal.payloads_for_text("ZAŻÓŁĆ")
    assert payload.startswith(b"ZA????\r\x00")


def test_pulse_writer_produces_alternating_levels():
    raw = io.BytesIO()
    writer = zal.PulseWriter(raw)
    writer.pulse(zal.PILOT_PULSE)
    writer.pulse(zal.PILOT_PULSE)
    samples = struct.unpack(f"<{raw.getbuffer().nbytes // 2}h", raw.getvalue())
    assert samples
    assert set(samples) == {-zal.AMPLITUDE, zal.AMPLITUDE}
    # One pilot half-pulse at 48 kHz is 2168 / 3_500_000 s = about 30 samples.
    assert 25 <= len(samples) / 2 <= 35


def test_wav_command_writes_valid_wav(tmp_path):
    output = tmp_path / "message.wav"
    args = zal.parser().parse_args(["wav", "TEST MESSAGE", str(output)])
    args.func(args)
    with wave.open(str(output), "rb") as wav_file:
        assert wav_file.getnchannels() == 1
        assert wav_file.getsampwidth() == 2
        assert wav_file.getframerate() == zal.SAMPLE_RATE
        assert wav_file.getnframes() > zal.SAMPLE_RATE // 2


def test_demo_command_appends_message_blocks(tmp_path):
    output = tmp_path / "selftest.tap"
    args = zal.parser().parse_args(["demo", "SELF TEST OK", str(output)])
    args.func(args)
    blocks = parse_tap(output.read_bytes())
    assert len(blocks) == 5
    message_block = blocks[-1]
    assert message_block[0] == 0xFF
    assert zal.xor_checksum(message_block) == 0
    assert b"SELF TEST OK\r" in message_block
