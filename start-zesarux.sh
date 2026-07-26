#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
app_dir="${ZESARUX_APP:-/Applications/ZEsarUX.app}"
binary="$app_dir/Contents/MacOS/zesarux"
resources="$app_dir/Contents/Resources"
receiver="$script_dir/receiver.tap"

if [[ ! -x "$binary" ]]; then
    echo "ZEsarUX was not found at: $app_dir" >&2
    echo "Set ZESARUX_APP if the application is installed elsewhere." >&2
    exit 1
fi

python3 "$script_dir/zx_audio_link.py" build "$receiver"

cd "$resources"
exec "$binary" \
    --noconfigfile \
    --machine TC2048 \
    --tape "$receiver" \
    --fastautoload \
    --audiovolume 0 \
    --nowelcomemessage \
    --no-saveconf-on-exit \
    --def-f-function F1 OpenWindow \
    --def-f-function-parameters F1 externalaudiosource
