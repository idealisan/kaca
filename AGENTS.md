# AGENTS.md — kaca 步骤记录器

给 AI 编码助手的项目说明。先读本文件，再动手改代码。

## 项目是什么

一个**客户端桌面步骤记录器（Step Recorder）**：记录用户的按键、鼠标点击、鼠标滚动操作，截取屏幕（含鼠标指针），收集窗口/进程/控件等上下文，最终生成一份**自包含 HTML 报告**（截图等全部用 Base64 Data URL 内嵌）。

- 语言：**C**（C11）。macOS 上被迫使用 Objective-C 的部分仅放在 `.m` 桥接文件里。
- 跨平台：**macOS 优先且已完整实现**；Windows 次优先；Linux 最低优先级（桌面环境不统一）。
- UI：一条**横向条状工具条**（开始 / 停止 + 状态灯 + 计时 + 截图模式下拉）。点「停止」即结束录制并弹出保存对话框（无独立「保存」按钮、不提供暂停）。窗口模式的「最小化」黄按钮可用；**关闭工具条窗口即退出进程**（小工具不应滞留）。

## 构建与测试

```bash
make          # 编译 macOS 应用 → build/kaca（要求无警告）
make test     # 无界面自测 → build/kaca_test 并运行（用桩替换依赖显示的 OS 调用）
make clean    # 清理 build/ 与 kaca.app/
make app      # 打包成 Mac 的 .app  bundle（生成 kaca.app，含占位图标 + 临时签名）
```

- 提交前必须：`make` 干净通过 且 `make test` 通过。
- **打包成品是 `kaca.app`，不是命令行工具**：`make app` 会在仓库根目录生成 `kaca.app`
  （`Contents/MacOS/kaca` + `Contents/Resources/AppIcon.icns` + `Info.plist`），并对
  其做 **ad-hoc 临时签名**（`codesign --force --deep --sign -`）。无开发者证书，
  仅本机可运行；分发给他机需正式签名公证。`.app` / `AppIcon.icns` / `AppIcon.iconset/`
  已写入 `.gitignore`，不入库。
- 占位图标由 `scripts/make_appicon.py` 生成（纯 Python 标准库 PNG 编码 → `iconutil`
  转 icns），无第三方库依赖。
- 实际运行需要「辅助功能」权限（系统设置 → 隐私与安全性 → 辅助功能）。
- **不要在本机做真实交互式录制测试**（用户明确要求）；逻辑验证一律走 `make test` 的桩。

## 目录结构与架构

```
src/
  main.c              入口：权限检查 + 工具条 + 事件接线
  recorder.c/.h       公共逻辑：步骤列表、滚动分组、HTML 生成（不含任何平台 API）
  base64.c/.h         Base64 编码
  os/os_api.h         统一抽象接口（★核心：所有平台相关能力都从这里走）
  os/macos/           macOS 实现（CGEventTap + 帧环形缓冲 CGDisplayCreateImage + libwebp + AppKit 工具条）
  os/windows/         Windows 桩（同接口，待补全）
  os/linux/           Linux 桩（最低优先级）
tests/recorder_test.c 无界面自测
```

**最重要的架构约束 —— 操作系统 API 隔离：**
- 所有依赖 OS 的能力（事件捕获、截图、光标、窗口/控件信息、系统硬件信息、工具条 UI、主线程派发）**只允许**通过 `src/os/os_api.h` 暴露。
- 平台实现放在 `src/os/<platform>/`。公共逻辑（`recorder.c`、`main.c`、`base64.c`）**不得** `#include` 任何平台头或调用平台 API。
- 新增平台：实现 `os_api.h` 里全部函数 + 在 Makefile 里选择该平台源文件。

## 关键行为约定（不要乱改）

- **焦点切换（FOCUS）**：由 0.3s 轮询检测，按**进程 PID** 去重（同一应用内窗口标题变化不记新切换，避免终端标题抖动造成重复/漏记）；切换需连续两次轮询一致才确认，生成 1 条「切换到 X」。记录器自身进程跳过。
- **滚动分组**：1 秒时间窗口内连续滚动合并为「一次」；停顿 >1 秒再滚动算新一次；连续长时间滚动仍算一次。记录方向与单位数值（累计）。横向（或零）滚动记为「用手势向左/右切换了桌面（横向滚动 N 单位）」（触控板左右滑动通常对应切换桌面/空间）；纵向记为「滚轮向上/下滚动 N 单位」。
- **文字输入合并**：没有被其他动作打断的连续按键，合并为「一次文字输入」动作（`STEP_EVENT_TYPE`），报告里显示为「用户输入了文字」+ 原文块；**只截一张截图、只记一个事件**。停顿 >3 秒**不拆段**：在原文块里就地追加「（停顿 N 秒）」一行文字（用 `typing_note_pause` 标注一次），整段输入仍是一次动作 / 一张截图，直到被其他动作打断或停止录制。非文字键（Esc/方向/F 键/纯修饰键等，`key_text` 为空）不并入，按普通按键记录，并先结束当前输入段（`finalize_typing`）。输入法场景只能捕获按键本身、无法保证拿到最终合成文字（已知限制）。
- **快捷键**：按住 Command/Control/Option 的非修饰键视为快捷键，**不并入打字**，记为「按下 ⌘V」/「按下 ⌃C」等（修饰键符号 ⌘⌃⌥⇧ + 键名）；单独按下的修饰键仍记为普通按键。仅按回车/空格等空白键、没有真实文字输入时，**不生成「用户输入了文字」步骤**（避免「激活输入框却记成空白输入」）。
- **鼠标相对位置**：鼠标点击描述除绝对坐标外，额外给出相对比例——窗口模式为「窗口内 左 X% / 上 Y%」，全屏模式为「屏幕 左 X% / 上 Y%」（0-100 钳制），方便快速定位。
- **HTML 报告**：顶部系统信息卡片（OS/CPU/核数/内存/主机名/生成时间）；每步 = 序号 + 本地时间 + 相对录制开始(0:00)的时间 + 一句话描述 + 截图；行尾 `i` 按钮点击弹出悬浮提示（pid/窗口标题/控件文本/可执行文件/光标位置），默认隐藏。
- **报告输出位置**：当前工作目录（项目目录），文件名 `step-report-YYYYMMDD-HHMMSS.html`。**不要**输出到桌面。
- **截图内容**：窗口或全屏 + 鼠标指针图标 + 指针旁操作标记（左键/右键/滚轮方向）。截图目标在**事件发生时**按所在窗口 ID 冻结，不受后续切换窗口影响（避免「在 A 输入却截到 B」）。取窗口时选**最前（最小 layer）**者，避免误选 Dock 的全屏透明窗口。

## 平台注意事项（macOS 27 SDK）

- **截图实时对齐（重要）**：不再用 `screencapture` 子进程。`CGDisplayCreateImage` / `CGWindowListCreateImage` 在当前 SDK 仍可用（旧笔记「已被移除」是误判）。后台以固定帧率（12fps）用进程内 `CGDisplayCreateImage` 持续抓整屏，每帧打 `CFAbsoluteTime` 时间戳存入**环形缓冲**（约 3 秒）；事件发生时从缓冲里挑「时间戳不晚于事件时刻」、且（FOCUS 时）前台窗口已置顶的那一帧 → 截图时间与事件时间对齐，不再「事件后很久才拍」。窗口模式按事件时冻结的 `window_id` 裁剪；多显示器立即抓对应屏。
- 帧选择/裁剪在**后台队列**完成（不阻塞事件分发）；光标与操作标记的**合成在主线程**（AppKit），最终用 **libwebp**（vendored 静态链接，`third_party/libwebp`）编码为 **WebP** 内嵌报告，体积远小于 PNG。
- 事件常量已改名：用 `kCGEventLeftMouseDown` / `kCGEventRightMouseDown` / `kCGEventOtherMouseDown`（无 `kCGEventMouseDown`）。
- 事件捕获 `CGEventTap`、窗口信息 `CGWindowListCopyWindowInfo`、控件文本 Accessibility `AXUIElement` 仍是纯 C；光标图像（`NSCursor`）与工具条（AppKit）必须 Objective-C。

## 编码规范

- C11，`-Wall -Wextra` 无警告；`.m` 用 `-fobjc-arc`。
- 修改公共逻辑时警惕互斥锁重入（曾有 `recorder_start` 内重复加锁死锁，已修）。`g_lock` 非递归，持锁时不要调用会再次加锁的函数。
- 拼 HTML 时：含字面 `%` 的静态块用 `sb_append_str`（不要用 printf 风格 `sb_append`，会吞掉 CSS 的 `%`）。

## 协作偏好（来自用户，务必遵守）

- **已实现且能工作的代码不要换成第三方库**（用户明确说过「如果你已经做了，那就算了」）。
- **新功能/未实现模块**才考虑第三方库，且优先 **vendor 单文件库源代码**（如 stb）到 `third_party/`，**不要动态链接**（为将来静态编译考虑）。
- UI 改动前先用文本画图给用户确认再实现。
