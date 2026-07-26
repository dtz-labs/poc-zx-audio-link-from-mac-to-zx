#!/bin/bash
set -euo pipefail

target_device="${1:-ZX Link}"
forced_output_index="${ZX_AUDIO_DEVICE_INDEX:-}"
forced_input_index="${ZX_AUDIO_INPUT_INDEX:-}"
test_seconds="${ZX_TEST_SECONDS:-8}"
test_wav="${ZX_TEST_WAV:-/tmp/virtual-audio-loopback-test.wav}"
record_log="${TMPDIR:-/tmp}/virtual-audio-record-$$.log"
send_log="${TMPDIR:-/tmp}/virtual-audio-send-$$.log"
record_pid=""

cleanup() {
    if [[ -n "$record_pid" ]] && kill -0 "$record_pid" 2>/dev/null; then
        kill "$record_pid" 2>/dev/null || true
        wait "$record_pid" 2>/dev/null || true
    fi
    rm -f "$record_log" "$send_log"
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

echo "[1/5] Looking for output device: $target_device"
output_listing="$({
    "$ffmpeg_bin" -nostdin -hide_banner -loglevel info \
        -f lavfi -i 'anullsrc=r=48000:cl=mono' -t 0.01 \
        -f audiotoolbox -list_devices true -
} 2>&1 || true)"

if [[ -n "$forced_output_index" ]]; then
    output_index="$forced_output_index"
else
    output_line="$(printf '%s\n' "$output_listing" | grep -F "$target_device" | head -n 1 || true)"
    if [[ -z "$output_line" && ( "$target_device" == "ZX Link" || "$target_device" == Loopback* ) ]]; then
        loopback_lines="$(printf '%s\n' "$output_listing" | grep -F 'com.rogueamoeba.Loopback::' || true)"
        loopback_count="$(printf '%s\n' "$loopback_lines" | grep -c . || true)"
        if [[ "$loopback_count" -eq 1 ]]; then
            output_line="$loopback_lines"
        elif [[ "$loopback_count" -gt 1 ]]; then
            echo "ERROR: multiple Loopback outputs were found." >&2
            printf '%s\n' "$loopback_lines" >&2
            echo "Set ZX_AUDIO_DEVICE_INDEX to the index of ZX Link." >&2
            exit 1
        fi
    fi
    output_index="$(printf '%s\n' "$output_line" | grep -oE '\[[0-9]+\]' | head -n 1 | tr -d '[]' || true)"
fi

if [[ -z "$output_index" ]]; then
    echo "ERROR: output device '$target_device' was not found." >&2
    printf '%s\n' "$output_listing" >&2
    exit 1
fi
echo "      Output index: $output_index"

echo "[2/5] Looking for recording device: $target_device"
input_listing="$({
    "$ffmpeg_bin" -nostdin -hide_banner -loglevel info \
        -f avfoundation -list_devices true -i ''
} 2>&1 || true)"

audio_input_listing="$(printf '%s\n' "$input_listing" | sed -n '/AVFoundation audio devices:/,$p')"
if [[ -n "$forced_input_index" ]]; then
    input_index="$forced_input_index"
else
    input_line="$(printf '%s\n' "$audio_input_listing" | grep -F "$target_device" | head -n 1 || true)"
    input_index="$(printf '%s\n' "$input_line" | grep -oE '\[[0-9]+\]' | head -n 1 | tr -d '[]' || true)"
fi

if [[ -z "$input_index" ]]; then
    echo "ERROR: recording device '$target_device' was not found." >&2
    printf '%s\n' "$input_listing" >&2
    exit 1
fi
echo "      Input index:  $input_index"

echo "[3/5] Recording $test_seconds seconds to $test_wav"
echo "      macOS may ask Terminal for microphone permission. Allow it."
"$ffmpeg_bin" -nostdin -hide_banner -loglevel warning -y \
    -f avfoundation -i ":$input_index" \
    -t "$test_seconds" -ac 1 -ar 48000 -c:a pcm_s16le \
    "$test_wav" >"$record_log" 2>&1 &
record_pid=$!

sleep 1
if ! kill -0 "$record_pid" 2>/dev/null; then
    wait "$record_pid" 2>/dev/null || true
    echo "ERROR: recording stopped before the test started." >&2
    cat "$record_log" >&2
    exit 1
fi

echo "[4/5] Sending a plain 1 kHz diagnostic tone"
if ! "$ffmpeg_bin" -nostdin -hide_banner -loglevel warning \
    -re -f lavfi -i 'sine=frequency=1000:sample_rate=48000:duration=2' \
    -af 'volume=0.8,apad=pad_dur=1' -ac 2 -ar 48000 -c:a pcm_s16le \
    -f audiotoolbox -audio_device_index "$output_index" - \
    >"$send_log" 2>&1
then
    echo "ERROR: ffmpeg could not send audio to '$target_device'." >&2
    cat "$send_log" >&2
    exit 1
fi

if ! wait "$record_pid"; then
    record_pid=""
    echo "ERROR: recording failed." >&2
    cat "$record_log" >&2
    exit 1
fi
record_pid=""

if [[ ! -s "$test_wav" ]]; then
    echo "ERROR: no WAV file was recorded." >&2
    cat "$record_log" >&2
    exit 1
fi

echo "[5/5] Analysing the recorded signal"
if ! python3 - "$test_wav" <<'PY'
import array
import math
import sys
import wave

path = sys.argv[1]
with wave.open(path, "rb") as wav_file:
    channels = wav_file.getnchannels()
    rate = wav_file.getframerate()
    width = wav_file.getsampwidth()
    frames = wav_file.getnframes()
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

print(f"      WAV:      {channels} channel, {rate} Hz, {duration:.2f} s")
print(f"      Peak:     {peak} ({peak_db:.1f} dBFS)")
print(f"      RMS:      {rms:.0f} ({rms_db:.1f} dBFS)")

if peak < 1000 or rms < 100:
    print("FAIL: the virtual-audio recording is silent or nearly silent.", file=sys.stderr)
    raise SystemExit(3)

print("PASS: a clear signal passed through the virtual audio device.")
PY
then
    echo >&2
    echo "The loopback test failed. The WAV was kept at: $test_wav" >&2
    if [[ -s "$record_log" ]]; then
        echo >&2
        echo "Recorder messages:" >&2
        cat "$record_log" >&2
    fi
    if [[ -s "$send_log" ]]; then
        echo >&2
        echo "Sender messages:" >&2
        cat "$send_log" >&2
    fi
    echo >&2
    echo "If Peak and RMS are exactly zero:" >&2
    echo "  1. Allow Terminal/iTerm under System Settings > Privacy & Security > Microphone." >&2
    echo "  2. In Loopback make sure '$target_device' is enabled and has Pass-Thru enabled." >&2
    echo "  3. Set the device format to 48000 Hz and run this test again." >&2
    exit 1
fi

echo
echo "Playing the captured signal. You should hear a 1 kHz tone."
afplay "$test_wav"
echo
echo "Virtual audio loopback works. Test file: $test_wav"
