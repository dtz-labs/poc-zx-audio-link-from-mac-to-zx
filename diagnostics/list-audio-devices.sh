#!/bin/bash
set -euo pipefail

ffmpeg_bin="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"
if [[ ! -x "$ffmpeg_bin" ]]; then
    ffmpeg_bin="$(command -v ffmpeg || true)"
fi
if [[ -z "$ffmpeg_bin" ]]; then
    echo "ffmpeg is required." >&2
    exit 1
fi

echo "=== OUTPUT DEVICES (AudioToolbox) ==="
# AudioToolbox prints the device table before it tries to start playback.
"$ffmpeg_bin" -hide_banner -loglevel info \
    -f lavfi -i 'anullsrc=r=48000:cl=mono' -t 0.01 \
    -f audiotoolbox -list_devices true - 2>&1 || true

echo
echo "=== INPUT DEVICES (AVFoundation) ==="
"$ffmpeg_bin" -nostdin -hide_banner -loglevel info \
    -f avfoundation -list_devices true -i '' 2>&1 || true
