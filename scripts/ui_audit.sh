#!/bin/bash
# 模拟器 UI 验收脚本 — 截图 + 布局 dump，减少手点。
# 用法: bash scripts/ui_audit.sh [target]
set -euo pipefail
HDC="${HDC:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc}"
TARGET="${1:-127.0.0.1:8710}"
OUT="${OUT:-/tmp/mediabox_ui}"
mkdir -p "$OUT"
TS=$(date +%H%M%S)

echo "== targets =="
"$HDC" -s "$TARGET" list targets || true

echo "== screenshot =="
"$HDC" -s "$TARGET" shell "snapshot_display -f /data/local/tmp/ui_$TS.jpeg"
"$HDC" -s "$TARGET" file recv "/data/local/tmp/ui_$TS.jpeg" "$OUT/ui_$TS.jpeg"
echo "saved $OUT/ui_$TS.jpeg"

echo "== layout dump =="
"$HDC" -s "$TARGET" shell "uitest dumpLayout -p /data/local/tmp/layout_$TS.json" || true
"$HDC" -s "$TARGET" file recv "/data/local/tmp/layout_$TS.json" "$OUT/layout_$TS.json" || true

echo "== app foreground =="
"$HDC" -s "$TARGET" shell "aa dump -a" | grep -A2 mediabox || true

echo "done: $OUT/ui_$TS.jpeg"
