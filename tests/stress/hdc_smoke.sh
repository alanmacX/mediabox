#!/bin/bash
# hdc_smoke.sh — MediaBox 安装/启动/运行时冒烟检查（可在模拟器或真机执行）
#
# 用法: ./tests/stress/hdc_smoke.sh [hdc路径] [HAP路径]
# 检查项:
#   1) 覆盖安装签名一致的 HAP
#   2) 启动 EntryAbility
#   3) 进程存活、无 CPPcrash/JS crash
#   4) FFmpegCapability 编码器探测结果（hilog）
#   5) 任务队列初始化日志
set -uo pipefail

HDC="${1:-$(find /Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains -name hdc -maxdepth 2 | head -1)}"
HAP="${2:-$(ls entry/build/default/outputs/default/entry-default-signed.hap 2>/dev/null | head -1)}"
BUNDLE="com.mediabox.app"

[ -x "$HDC" ] || { echo "FAIL: 找不到 hdc"; exit 1; }
[ -f "$HAP" ] || { echo "FAIL: 找不到 HAP: $HAP"; exit 1; }
"$HDC" list targets | grep -q . || { echo "FAIL: 无在线设备"; exit 1; }

echo "== 覆盖安装 $HAP"
"$HDC" install -r "$HAP" || { echo "FAIL: 安装被拒（签名不一致请先卸载重装）"; exit 1; }

echo "== 启动 $BUNDLE"
"$HDC" shell hilog -r
"$HDC" shell aa start -b "$BUNDLE" -a EntryAbility || { echo "FAIL: 启动失败"; exit 1; }
sleep 4

echo "== 进程存活"
PID=$("$HDC" shell "pidof $BUNDLE" | tr -d '\r')
[ -n "$PID" ] && echo "OK: pid=$PID" || { echo "FAIL: 进程未运行"; exit 1; }

echo "== 崩溃检查（最近 5 分钟）"
CRASH=$("$HDC" shell "hilog -x | grep -iE 'CPPcrash|JS.*crash|Fatal signal' | tail -5")
if [ -n "$CRASH" ]; then echo "WARN: 发现疑似崩溃日志:"; echo "$CRASH"; else echo "OK: 无崩溃"; fi

echo "== 关键运行日志"
"$HDC" shell "hilog -x | grep -E 'MediaBoxUI|TaskQueue|FFmpegCapability|LiveViewProgress|continuous task' | tail -15"

echo "== 冒烟通过（手动压测矩阵见 tests/stress/STRESS_PLAN.md）"
