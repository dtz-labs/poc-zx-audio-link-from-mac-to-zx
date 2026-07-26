#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
ffmpeg_bin="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"
if [[ ! -x "$ffmpeg_bin" ]]; then
    ffmpeg_bin="$(command -v ffmpeg || true)"
fi
if [[ -z "$ffmpeg_bin" ]]; then
    echo "ffmpeg is required." >&2
    exit 1
fi

device_index="${ZX_AUDIO_DEVICE_INDEX:-}"
device_uid_match="${ZX_AUDIO_DEVICE_UID_MATCH:-com.rogueamoeba.Loopback::}"
device_args=()
if [[ -z "$device_index" ]]; then
    output_listing="$({
        "$ffmpeg_bin" -nostdin -hide_banner -loglevel info \
            -f lavfi -i 'anullsrc=r=48000:cl=mono' -t 0.01 \
            -f audiotoolbox -list_devices true -
    } 2>&1 || true)"
    matching_lines="$(printf '%s\n' "$output_listing" | grep -F "$device_uid_match" || true)"
    match_count="$(printf '%s\n' "$matching_lines" | grep -c . || true)"

    if [[ "$match_count" -eq 1 ]]; then
        device_index="$(printf '%s\n' "$matching_lines" | grep -oE '\[[0-9]+\]' | head -n 1 | tr -d '[]')"
        echo "Using Loopback output index: $device_index" >&2
    elif [[ "$match_count" -gt 1 ]]; then
        echo "ERROR: multiple Loopback output devices were found:" >&2
        printf '%s\n' "$matching_lines" >&2
        echo "Set ZX_AUDIO_DEVICE_INDEX to the index of ZX Link." >&2
        exit 1
    else
        echo "ERROR: no Loopback output device was found." >&2
        echo "Run ./list-audio-devices.sh or set ZX_AUDIO_DEVICE_INDEX manually." >&2
        exit 1
    fi
fi
device_args=(-audio_device_index "$device_index")

python3 "$script_dir/zx_audio_link.py" stream "$@" | \
    "$ffmpeg_bin" -hide_banner -loglevel warning \
        -re -f s16le -ar 48000 -ac 1 -i pipe:0 \
        -af 'apad=pad_dur=1' -ac 2 -ar 48000 -c:a pcm_s16le \
        -f audiotoolbox "${device_args[@]}" -
