#!/bin/bash
# Compatibility entry point: all production FFmpeg builds use the LGPL recipe.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SCRIPT_DIR/rebuild_ffmpeg_encoders.sh" "$@"
