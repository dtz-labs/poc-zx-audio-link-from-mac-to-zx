#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
text="${*:-HELLO FROM A MACOS SHELL}"
python3 "$script_dir/../zx_audio_link.py" wav "$text" "test-message.wav"
