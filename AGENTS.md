# AGENTS.md — kaca 步骤记录器

给 AI 编码助手的项目说明。先读本文件，再动手改代码。

## 项目是什么

一个**客户端桌面步骤记录器（Step Recorder）**：记录用户的按键、鼠标点击、鼠标滚动操作，截取屏幕（含鼠标指针），收集窗口/进程/控件等上下文，最终生成一份**自包含 HTML 报告**（截图等全部用 Base64 Data URL 内嵌）。

- 语言：**C**（C11）。macOS 上被迫使用 Objective-C 的部分仅放在 `.m` 桥接文件里。
- 跨平台：**macOS 优先且已完整实现**；Windows 次优先；Linux 最低优先级（桌面环境不统一）。
- UI：一条**横向条状工具条**（开始 / 停止 / 保存 / 截图模式切换 + 状态灯 + 计时）。

## 构建与测试

```bash
make          # 编译 macOS 应用 → build/kaca（要求无警告）
make test     # 无界面自测 → build/kaca_test 并运行（用桩替换依赖显示的 OS 调用）
make clean    # 清理 build/
```

- 提交前必须：`make` 干净通过 且 `make test` 通过。
- 实际运行需要「辅助功能」权限（系统设置 → 隐私与安全性 → 辅助功能）。
- **不要在本机做真实交互式录制测试**（用户明确要求）；逻辑验证一律走 `make test` 的桩。

## 目录结构与架构

```
src/
  main.c              入口：权限检查 + 工具条 + 事件接线
  recorder.c/.h       公共逻辑：步骤列表、滚动分组、HTML 生成（不含任何平台 API）
  base64.c/.h         Base64 编码
  os/os_api.h         统一抽象接口（★核心：所有平台相关能力都从这里走）
  os/macos/           macOS 实现（CGEventTap + screencapture + AppKit 工具条）
  os/windows/         Windows 桩（同接口，待补全）
  os/linux/           Linux 桩（最低优先级）
tests/recorder_test.c 无界面自测
```

**最重要的架构约束 —— 操作系统 API 隔离：**
- 所有依赖 OS 的能力（事件捕获、截图、光标、窗口/控件信息、系统硬件信息、工具条 UI、主线程派发）**只允许**通过 `src/os/os_api.h` 暴露。
- 平台实现放在 `src/os/<platform>/`。公共逻辑（`recorder.c`、`main.c`、`base64.c`）**不得** `#include` 任何平台头或调用平台 API。
- 新增平台：实现 `os_api.h` 里全部函数 + 在 Makefile 里选择该平台源文件。

## 关键行为约定（不要乱改）

- **滚动分组**：1 秒时间窗口内连续滚动合并为「一次」；停顿 >1 秒再滚动算新一次；连续长时间滚动仍算一次。记录方向与单位数值（累计）。
- **HTML 报告**：顶部系统信息卡片（OS/CPU/核数/内存/主机名/生成时间）；每步 = 序号 + 本地时间 + 相对录制开始(0:00)的时间 + 一句话描述 + 截图；行尾 `i` 按钮点击弹出悬浮提示（pid/窗口标题/控件文本/可执行文件/光标位置），默认隐藏。
- **报告输出位置**：当前工作目录（项目目录），文件名 `step-report-YYYYMMDD-HHMMSS.html`。**不要**输出到桌面。
- **截图内容**：窗口或全屏 + 鼠标指针图标 + 指针旁操作标记（左键/右键/滚轮方向）。

## 平台注意事项（macOS 27 SDK）

- 旧的 `CGDisplayCreateImage` / `CGWindowListCreateImage` **已被移除**，截图改用系统命令 `screencapture`（`-x -t png`，窗口用 `-l <windowID>`）。
- 事件常量已改名：用 `kCGEventLeftMouseDown` / `kCGEventRightMouseDown` / `kCGEventOtherMouseDown`（无 `kCGEventMouseDown`）。
- 事件捕获 `CGEventTap`、窗口信息 `CGWindowListCopyWindowInfo`、控件文本 Accessibility `AXUIElement` 仍是纯 C；光标图像（`NSCursor`）与工具条（AppKit）必须 Objective-C。
- 截图/指针合成需在**主线程**执行：用 `os_run_on_main()`（macOS 为 dispatch 到主队列）。

## 编码规范

- C11，`-Wall -Wextra` 无警告；`.m` 用 `-fobjc-arc`。
- 修改公共逻辑时警惕互斥锁重入（曾有 `recorder_start` 内重复加锁死锁，已修）。`g_lock` 非递归，持锁时不要调用会再次加锁的函数。
- 拼 HTML 时：含字面 `%` 的静态块用 `sb_append_str`（不要用 printf 风格 `sb_append`，会吞掉 CSS 的 `%`）。

## 协作偏好（来自用户，务必遵守）

- **已实现且能工作的代码不要换成第三方库**（用户明确说过「如果你已经做了，那就算了」）。
- **新功能/未实现模块**才考虑第三方库，且优先 **vendor 单文件库源代码**（如 stb）到 `third_party/`，**不要动态链接**（为将来静态编译考虑）。
- UI 改动前先用文本画图给用户确认再实现。
