# 原生实况窗 Demo（无需申请权益即可真机渲染）

## 结论（2026-09-19 实测，模拟器 API 24 / HarmonyOS 6.1.0）

**不申请实况窗权益，`liveViewManager.startLiveView` 可以直接成功**（模拟器实测
`isLiveViewEnabled = true`、`startLiveView` 返回 `resultCode 0`），系统原生渲染
状态栏胶囊 + 通知中心卡片，无需 AGC 白名单。据此截取了 `design/native/` 下的
6 张真实系统渲染截图。

注意：模拟器不校验权益不代表真机不校验。真机（API 26）未实测——若真机报
`1003500005`（权益未开通），则走 AGC 开通权益 + 调测设备白名单后同样能跑本 demo。

## 实测踩坑（重要）

| 错误 | 原因与解法 |
| --- | --- |
| 401 `layoutData.nodeIcons mustbe Array<string \| image.PixelMap>` | `LAYOUT_TYPE_PROGRESS` 模板必填 2–5 个节点图标（rawfile 文件名字符串或 PixelMap） |
| 401 `capsule.icon mustbe string \| image.PixelMap` | 胶囊必填图标（rawfile 文件名，PixelMap ≤30KB） |
| 401 `capsule.backgroundColor mustbe string` | `TextCapsule` 也必须传 `backgroundColor`（9 位 #ARGB） |
| 401 `primary.clickAction mustbe WantAgent` | 点击动作要用 `wantAgent.getWantAgent()` 生成的对象，不能传数组 |
| 1003500006 already exists | 同一 id 重复创建；实况窗记录在系统侧，应用被 force-stop 甚至重装后依然存在。创建失败改用 `updateLiveView` |
| 1003500009 does not exist | 更新/结束不存在的 id |
| 首次授权弹窗 | 重装应用后通知中心会弹「是否继续接收此应用的实况窗」，点一次"继续接收"即不再出现 |
| 热启动不触发 onCreate | `aa start --ps` 传参在热启动时走 `onNewWant`；演示脚本用 `aa force-stop` 后冷启动保证参数生效 |

## 事件流（进度型实况窗）

1. `startLiveView`（0%，胶囊「处理中/转码」）
2. `updateLiveView`（45%，胶囊「45%/转码中」——百分比文本胶囊，非 45/100）
3. `updateLiveView`（100%，胶囊「完成/已保存」，卡片进度条满格）
4. `stopLiveView`（结束；不调用则系统在超过 2 小时未更新时隐藏、4 小时清除）

## 复现命令

```bash
# 构建（DevEco 命令行，工程在 /tmp/liveview-arkui，签名复用 mediabox 调试证书）
cd /tmp/liveview-arkui
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node
node $NODE_HOME/../hvigor/bin/hvigorw.js --mode module -p module=entry@default \
  -p product=default -p buildMode=debug assembleHap --no-daemon

# 安装 + 按状态截图（模拟器 127.0.0.1:5555）
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
$HDC -t 127.0.0.1:5555 install entry/build/default/outputs/default/entry-default-signed.hap
$HDC -t 127.0.0.1:5555 shell "aa force-stop com.mediabox.app"
$HDC -t 127.0.0.1:5555 shell "aa start -b com.mediabox.app -a EntryAbility --ps state 2 --ps theme light"
# Home 后 snapshot_display 截胶囊；下拉通知中心截卡片
```

`state` 参数：1=任务开始、2=处理中(45%)、3=已完成(100%)。

## 文件

- `Index.ets` — demo 页面源码（含 `runDemo()`：WantAgent 创建、LiveView 构建、
  start/update 兜底、残留实况窗清理；页面本身用 ArkUI 画的 UX 版式）。
- 演示工程完整目录：`/tmp/liveview-arkui`（临时目录，重启后可能被清理；核心
  代码都在本文件与 Index.ets 中）。
- 节点图标 `node1/2/3.png`（24×24 白色单色 png，位于工程 rawfile）由 PIL 生成。

## 清理演示应用

```bash
$HDC -t 127.0.0.1:5555 uninstall com.mediabox.app
```
