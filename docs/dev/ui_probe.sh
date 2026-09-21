#!/bin/bash
# ui_probe.sh — 模拟器 UI 快检 hook
# 用法: bash docs/dev/ui_probe.sh [home|tasks|workbench]
# 高效路径：直接 push 样例 + share 启动，避免手点选择器
set -euo pipefail
HDC="${HDC:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc}"
TARGET="${TARGET:-127.0.0.1:5555}"
OUT="${OUT:-/tmp/mb_ui}"
PKG=com.mediabox.app
mkdir -p "$OUT"

h() { "$HDC" -t "$TARGET" "$@"; }

shot() {
  local name="$1"
  h shell "snapshot_display -f /data/local/tmp/${name}.jpeg" >/dev/null
  h file recv "/data/local/tmp/${name}.jpeg" "$OUT/${name}.jpeg" >/dev/null
  echo "shot -> $OUT/${name}.jpeg"
}

dump() {
  local name="$1"
  h shell "uitest dumpLayout -p /data/local/tmp/${name}.json" >/dev/null
  h file recv "/data/local/tmp/${name}.json" "$OUT/${name}.json" >/dev/null
  echo "layout -> $OUT/${name}.json"
}

case "${1:-home}" in
  home)
    h shell "aa force-stop $PKG" >/dev/null || true
    h shell "aa start -a EntryAbility -b $PKG" >/dev/null
    sleep 2
    shot home
    dump home
    ;;
  workbench)
    # 用系统分享把样例 PNG 直接送进工作台（免选择器）
    h shell "aa force-stop $PKG" >/dev/null || true
    sleep 0.3
    h shell "aa start -a EntryAbility -b $PKG -U file://data/local/tmp/sample.png -t image/png \
      -A ohos.want.action.sendData" 2>/dev/null || \
    h shell "aa start -b $PKG -a EntryAbility --pi file://data/local/tmp/sample.png" 2>/dev/null || true
    sleep 2.5
    shot workbench
    dump workbench
    ;;
  tasks)
    h shell "aa start -a EntryAbility -b $PKG" >/dev/null
    sleep 1.5
    # 侧边栏第二个页签约在 x=96,y=1000
    h shell "uitest uiInput click 96 1020" >/dev/null || true
    sleep 0.8
    shot tasks
    dump tasks
    ;;
  *)
    echo "usage: $0 home|workbench|tasks"; exit 1;;
esac
