#!/bin/bash
set -euo pipefail

test_wav="${ZX_MIC_TEST_WAV:-/tmp/macbook-microphone-test.wav}"
ffmpeg_bin="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"

if [[ ! -x "$ffmpeg_bin" ]]; then
    ffmpeg_bin="$(command -v ffmpeg || true)"
fi
if [[ -z "$ffmpeg_bin" ]]; then
    echo "ERROR: ffmpeg was not found." >&2
    exit 1
fi

input_listing="$({
    "$ffmpeg_bin" -nostdin -hide_banner -loglevel info \
        -f avfoundation -list_devices true -i ''
} 2>&1 || true)"
audio_inputs="$(printf '%s\n' "$input_listing" | sed -n '/AVFoundation audio devices:/,$p')"
input_line="$(printf '%s\n' "$audio_inputs" | grep -Ei 'Mikrofon.*MacBook|MacBook.*Microphone|MacBook.*Mic' | head -n 1 || true)"

if [[ -z "$input_line" ]]; then
    # Skip virtual audio devices when falling back to the first available input.
    input_line="$(printf '%s\n' "$audio_inputs" | grep -E '\[[0-9]+\]' | grep -viE 'BlackHole|Loopback|ZX Link' | head -n 1 || true)"
fi

input_index="$(printf '%s\n' "$input_line" | grep -oE '\[[0-9]+\]' | head -n 1 | tr -d '[]' || true)"
input_name="$(printf '%s\n' "$input_line" | sed -E 's/^.*\[[0-9]+\][[:space:]]*//')"

if [[ -z "$input_index" ]]; then
    echo "ERROR: the built-in microphone was not found." >&2
    printf '%s\n' "$input_listing" >&2
    exit 1
fi

echo "Recording input: $input_name (index $input_index)"
echo "Speak, clap or tap near the MacBook for the next 5 seconds..."

"$ffmpeg_bin" -nostdin -hide_banner -loglevel warning -y \
    -f avfoundation -i ":$input_index" -t 5 \
    -ac 1 -ar 48000 -c:a pcm_s16le "$test_wav"

if python3 - "$test_wav" <<'PY'
import array
import math
import sys
import wave

path = sys.argv[1]
with wave.open(path, "rb") as wav_file:
    rate = wav_file.getframerate()
    frames = wav_file.getnframes()
    width = wav_file.getsampwidth()
    raw = wav_file.readframes(frames)

if width != 2:
    print(f"ERROR: expected 16-bit PCM, got sample width {width}", file=sys.stderr)
    raise SystemExit(2)

samples = array.array("h")
samples.frombytes(raw)
if sys.byteorder != "little":
    samples.byteswap()

peak = max((abs(sample) for sample in samples), default=0)
rms = math.sqrt(sum(sample * sample for sample in samples) / max(1, len(samples)))
peak_db = 20 * math.log10(peak / 32768) if peak else float("-inf")
rms_db = 20 * math.log10(rms / 32768) if rms else float("-inf")

print(f"Peak: {peak} ({peak_db:.1f} dBFS)")
print(f"RMS:  {rms:.0f} ({rms_db:.1f} dBFS)")

if peak < 1000 or rms < 100:
    print("FAIL: FFmpeg did not receive a useful microphone signal.", file=sys.stderr)
    raise SystemExit(3)

print("PASS: FFmpeg can record from a physical microphone.")
PY
then
    status=0
else
    status=$?
fi

echo "Recorded file: $test_wav"
exit "$status"
