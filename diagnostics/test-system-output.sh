#!/bin/bash
set -euo pipefail

target_device="${1:-ZX Link}"
test_wav="${ZX_NATIVE_TEST_WAV:-/tmp/virtual-audio-native-loopback.wav}"
tone_wav="${TMPDIR:-/tmp}/virtual-audio-native-tone-$$.wav"
record_log="${TMPDIR:-/tmp}/virtual-audio-native-record-$$.log"
record_pid=""

# shellcheck disable=SC2317  # invoked indirectly via trap
cleanup() {
    if [[ -n "$record_pid" ]] && kill -0 "$record_pid" 2>/dev/null; then
        kill "$record_pid" 2>/dev/null || true
        wait "$record_pid" 2>/dev/null || true
    fi
    rm -f "$tone_wav" "$record_log"
}
trap cleanup EXIT INT TERM

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
audio_input_listing="$(printf '%s\n' "$input_listing" | sed -n '/AVFoundation audio devices:/,$p')"
input_line="$(printf '%s\n' "$audio_input_listing" | grep -F "$target_device" | head -n 1 || true)"
input_index="$(printf '%s\n' "$input_line" | grep -oE '\[[0-9]+\]' | head -n 1 | tr -d '[]' || true)"

if [[ -z "$input_index" ]]; then
    echo "ERROR: recording device '$target_device' was not found." >&2
    printf '%s\n' "$input_listing" >&2
    exit 1
fi

"$ffmpeg_bin" -nostdin -hide_banner -loglevel error -y \
    -f lavfi -i 'sine=frequency=1000:sample_rate=48000:duration=2' \
    -af 'volume=0.8' -ac 2 -ar 48000 -c:a pcm_s16le "$tone_wav"

echo "Native virtual-audio loopback test"
echo "  Recording input: $target_device (index $input_index)"
echo
echo "Before continuing, open System Settings > Sound > Output"
echo "and select '$target_device' as the macOS output device."
echo "Silence from the Mac speakers during the test is expected."
echo
read -r -p "Press Return when '$target_device' is selected as Output... "

"$ffmpeg_bin" -nostdin -hide_banner -loglevel warning -y \
    -f avfoundation -i ":$input_index" \
    -t 6 -ac 1 -ar 48000 -c:a pcm_s16le "$test_wav" \
    >"$record_log" 2>&1 &
record_pid=$!

sleep 1
if ! kill -0 "$record_pid" 2>/dev/null; then
    wait "$record_pid" 2>/dev/null || true
    record_pid=""
    echo "ERROR: recording stopped before playback." >&2
    cat "$record_log" >&2
    exit 1
fi

echo "Playing the tone through macOS afplay..."
afplay "$tone_wav"

if ! wait "$record_pid"; then
    record_pid=""
    echo "ERROR: recording failed." >&2
    cat "$record_log" >&2
    exit 1
fi
record_pid=""

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
duration = frames / rate if rate else 0

print(f"WAV:  {rate} Hz, {duration:.2f} s")
print(f"Peak: {peak} ({peak_db:.1f} dBFS)")
print(f"RMS:  {rms:.0f} ({rms_db:.1f} dBFS)")

if peak < 1000 or rms < 100:
    print("FAIL: native macOS playback produced silence in the virtual device.", file=sys.stderr)
    raise SystemExit(3)

print("PASS: the virtual device works with native macOS playback.")
PY
then
    status=0
else
    status=$?
fi

echo
echo "You can now restore MacBook Speakers under System Settings > Sound > Output."
echo "Captured file: $test_wav"
exit "$status"
