# SSH Mobile

SSH Mobile 是一个基于 Flutter 的跨平台 SSH / SFTP 客户端，面向移动端长时间终端会话、多窗口操作、文件管理和 AI 辅助运维场景。它支持普通 SSH、SSH + tmux、多终端窗口、SFTP 文件管理、开发日志、连接历史、黑白主题、中英文界面，以及 OpenAI-compatible 大模型接入。

SSH Mobile is a Flutter-based cross-platform SSH / SFTP client for long-running terminal sessions, multi-window workflows, remote file management, and AI-assisted server operations. It supports normal SSH, SSH + tmux, multiple terminal windows, SFTP, developer logs, connection history, light/dark themes, Chinese/English UI, and OpenAI-compatible LLM integration.

> 后台网络连接受系统策略影响。应用会尽量通过前台服务、通知、WakeLock、SSH keep-alive 和 tmux 恢复机制提高稳定性，但长期后台运行仍可能受到省电策略、网络切换和进程回收影响。需要保留服务器端工作现场时，推荐使用 SSH + tmux。

## Android Native Rewrite Guide

For a feature-by-feature Kotlin / Jetpack Compose rewrite roadmap, see
[`docs/ANDROID_NATIVE_REWRITE_GUIDE.md`](docs/ANDROID_NATIVE_REWRITE_GUIDE.md).

## Engineering Baseline

The current maintenance baseline is documented in
[`docs/ADR_ENGINEERING_BASELINE.md`](docs/ADR_ENGINEERING_BASELINE.md). Release
Android builds disable cleartext traffic by default; debug and profile builds
keep cleartext enabled for local OpenAI-compatible provider or SearXNG testing.

Performance-sensitive changes should be checked against
[`docs/PERFORMANCE_ACCEPTANCE.md`](docs/PERFORMANCE_ACCEPTANCE.md), especially
terminal large output, AI long streaming replies, SFTP large directories, and
multi-server monitor sampling.

## Features

- SSH 连接管理：保存多服务器配置，支持密码、私钥、私钥密码和可选跳板机。
- 多终端窗口：同一服务器可打开多个窗口，窗口名固定，用于稳定绑定 tmux 会话。
- SSH + tmux：默认推荐模式，适合 `codex`、编辑器、构建任务和长时间脚本。
- tmux 恢复与清理：断连后可回到原会话，也可配置无客户端自动清理旧会话。
- 导航顺序：AI 页、服务器页、SFTP 页、性能监控页和日志页；窗口管理合并到服务器页，应用启动默认进入服务器页，日志页不显示在导航栏中。
- SFTP 文件管理：支持多服务器切换、保持连接、路径记忆、上传、下载、输入名称确认删除、文本编辑和文件预览。
- 性能监控：可多选服务器，点击开始后实时绘制 CPU、内存、磁盘 IO 和网络折线图，默认 10 秒刷新一次，最多保留本轮监控启动后的近 10 分钟数据，并给出健康评分与内存告警。
- 文件预览：支持文本、Markdown、HTML、PDF 等常见文档类型的查看。
- AI 大模型聊天页：通过 API Key 接入 OpenAI-compatible 接口，默认支持 DeepSeek 模型。
- AI Tools：模型可调用工具列出服务器、执行只读诊断命令、浏览 SFTP 目录、读取小文本文件、生成服务器运维报告，也可调用客户端工具查看本机时间/设备/网络/电池状态、打开应用设置、复制文本和设置客户端提醒；写命令必须先经过人工同意。
- 流式输出与富文本：AI 回复支持流式显示和 Markdown 富文本渲染。
- 过程详情：模型的深度思考、工具调用参数、工具执行结果和写命令审批结果会在聊天消息下方折叠展示。
- 聊天工具栏：输入框旁的 `+` 会在输入框下方展开类似微信的功能面板，提供服务器选择、Skills 管理和当前会话绑定的 WebView 入口。
- 上下文管理：AI 页显示上下文窗口用量，可选择 259K、512K、1M，长文档输出只保留精简记忆进入后续上下文，达到 90% 自动调用模型压缩上下文。
- 聊天历史与多窗口：AI 页支持多会话历史、新建聊天、切换动画和当前会话保活。
- 消息编辑与分支：用户消息可编辑后重新发送，AI 回复可重新生成，也可从某条 AI 回复创建新分支继续追问。
- 开发日志：日志页记录 SSH、SFTP、LLM、tool 调用和错误信息，日志包含来源文件/行号，支持筛选、复制、长按多选和批量删除。
- 设置面板与备份：在 AI 页顶部点击“应用设置”按钮打开设置抽屉，支持主题/语言/全局字体切换，以及一键导出/导入服务器、窗口历史、AI 聊天和自定义 Skills；密码、私钥和 API Key 不会导出。
- 主题与语言：默认使用浅色主题和中文界面，支持黑白主题和中英文界面切换；全局视觉系统统一了色彩、圆角、输入框、按钮和导航样式。
- 移动端导航优化：底部导航栏默认常驻显示；手机端会按 1.5K 到 2K 物理短边做轻量字号和组件密度适配，避免低分辨率机型 UI 过大。

## UI Density Note

Mobile layout uses Flutter logical pixels first, following Android dp/sp and
iOS point-style density independence. For phone-class devices that still render
too large because of OEM density buckets, the app applies a narrow correction:
2K-class short edges (about 1440 physical px and above) use `1.0`, while
1.5K-class short edges (about 1240 physical px and below) use about `0.88`,
with interpolation between the two.

Main navigation pages are deferred: AI, Servers, SFTP, Performance Monitor, and
Logs stay
blank until selected. During activation the app shows only the shared loading
indicator, then mounts that page's data subscriptions and UI.

The AI page does not load saved chat history during activation. On first open it
creates an unsaved draft, then keeps the active draft/chat state alive when the
user switches to another navigation page. Saved history is loaded only when the
history drawer is opened; the drawer shows a blank loading state while reading
history.

Performance-sensitive UI paths are batched: terminal output writes are capped
per frame, SSH shortcut keys use a saved manual order instead of LRU resorting,
and shortcut usage stats are persisted without rebuilding the shortcut
bar on every key press. Log/SFTP notifications are coalesced during noisy
diagnostics or file operations. During AI streaming, context-token estimation,
bottom-scroll updates, and chat-list resorting are throttled so Markdown
rendering stays responsive while text is arriving; the history drawer animates
through local value updates rather than rebuilding the full chat page. Server
overview cards listen to compact session summaries instead of full
terminal-window objects, and log-level filters are cached in the log service.
High-frequency debug/background logs skip expensive source stack lookup, and
the embedded terminal windows list listens to immutable value snapshots instead
of raw session objects. AI chats, AI skills, tmux restore records, and terminal history
metadata are cached in memory so single-record saves avoid repeatedly decoding
full JSON lists; those high-frequency list writes are debounced and flushed
when the app backgrounds. The interactive xterm scrollback is bounded for
mobile smoothness, while the full raw stream remains available through
encrypted terminal history.
Port/Application monitor refresh controls are disabled while a fetch is in
flight, port detail rows stay collapsed by default, and performance probes
retry with a fresh one-shot SSH connection after transient interruptions.
LLM settings include DeepSeek-only thinking controls. For DeepSeek API hosts the
client can send `thinking.enabled/disabled` and `reasoning_effort` (`high` or
`max`); generic OpenAI-compatible providers are left untouched. Future web
search is available as an optional client-side `web_search` function tool backed
by a user-configured SearXNG instance, while OpenAI hosted web search belongs in
a separate Responses API adapter.

## Tech Stack

| Module | Package | Description |
| --- | --- | --- |
| Flutter UI | `flutter`, `provider` | 页面、状态、主题和语言管理 |
| SSH / SFTP | `dartssh2` | 纯 Dart SSH 和 SFTP 客户端 |
| Terminal | `xterm` | ANSI 终端渲染、输入输出和滚动缓存 |
| Charts | `fl_chart` | 性能监控折线图 |
| Background | `flutter_background_service` | 后台 SSH 会话维护 |
| Notifications | `flutter_local_notifications` | 前台服务通知 |
| Secure storage | `flutter_secure_storage` | 密码、私钥、API Key 等敏感信息 |
| Local settings | `shared_preferences` | 主题、语言、连接配置和聊天记录 |
| Files | `file_picker`, `path_provider`, `path` | 本地文件选择、下载和缓存 |
| Markdown | `flutter_markdown` | AI 回复和文档 Markdown 渲染 |
| Preview | `webview_flutter`, `printing` | HTML / PDF 等文档预览 |
| Permissions | `permission_handler` | 通知、电池优化等权限处理 |

## Project Structure

```text
ssh_mobile/
├── android/                         # Android 工程和权限配置
├── ios/                             # iOS 工程
├── macos/                           # macOS 桌面工程和沙盒权限配置
├── windows/                         # Windows 工程
├── assets/                          # 静态资源
├── lib/
│   ├── main.dart                    # 应用入口、Provider、路由
│   ├── models/
│   │   └── connection.dart          # SSH 连接配置模型
│   ├── screens/
│   │   ├── home_screen.dart         # 主页面、导航、服务器与窗口合并入口
│   │   ├── llm_chat_screen.dart     # AI 聊天、历史、多会话、设置
│   │   ├── ai_skills_screen.dart    # 自定义 AI Skills 管理
│   │   ├── sftp_screen.dart         # SFTP 文件管理
│   │   ├── sftp_editor_screen.dart  # 远程文本编辑
│   │   ├── sftp_viewer_screen.dart  # 文件预览
│   │   ├── terminal_screen.dart     # 终端窗口状态和生命周期
│   │   ├── terminal_windows_screen.dart
│   │   ├── terminal_history_screen.dart
│   │   └── developer_log_screen.dart
│   ├── services/
│   │   ├── ssh_service.dart         # 多 SSH 会话管理
│   │   ├── sftp_service.dart        # SFTP 连接、缓存和文件操作
│   │   ├── llm_chat_service.dart    # OpenAI-compatible 聊天、流式输出、tools
│   │   ├── ai_tool_service.dart     # AI 可调用工具定义与执行
│   │   ├── storage_service.dart     # 配置、凭据、历史和 AI 设置
│   │   ├── app_log_service.dart     # 应用日志
│   │   └── app_settings.dart        # 主题、语言和界面文案
│   └── theme/
│       └── app_theme.dart
├── pubspec.yaml
└── README.md
```

## Agent Collaboration

Codex uses `.agents/skills/ssh-mobile-maintenance/SKILL.md`; Claude Code uses
`.claude/skills/ssh-mobile-maintenance/SKILL.md`. Keep them synchronized with:

```powershell
.\scripts\sync_agent_skills.ps1 -Mode Check
.\scripts\sync_agent_skills.ps1 -Mode Link -Force
```

Use `AGENT_MEMORY.md` for shared durable project notes between Codex and Claude
Code. This is repository-backed memory rather than live model memory, so keep it
short and never store passwords, private keys, API keys, tokens, or server
credentials there.

## Development Environment

本项目不提交 Flutter SDK，也不依赖仓库内固定 SDK 路径。请先在本机安装 Flutter，并确保命令可用：

```powershell
flutter --version
dart --version
```

推荐环境：

- Flutter 3.x
- Dart SDK `>=3.2.0 <4.0.0`
- Android Studio / Android SDK 或对应目标平台工具链
- 至少一个 Flutter 可运行设备、模拟器或桌面目标

如果国内网络访问 pub.dev 不稳定，可以临时使用镜像：

```powershell
$env:PUB_HOSTED_URL='https://pub.flutter-io.cn'
flutter pub get
```

## Install

```powershell
flutter pub get
```

## Run

查看设备：

```powershell
flutter devices
```

运行到指定设备：

```powershell
flutter run -d <device-id>
```

例如运行到 Android 设备：

```powershell
flutter run -d 22011211C
```

如果安装时报 `INSTALL_FAILED_USER_RESTRICTED`，通常是手机系统拦截了 USB 安装，需要在手机上允许 USB 安装、关闭安装限制或确认安装弹窗。

## Build / 构建

Different targets require different host systems and toolchains. Android and
Windows can be built on Windows; iOS and macOS must be built on macOS with
Xcode installed.

不同目标平台需要不同的宿主系统和工具链。Android 和 Windows 可以在 Windows
上构建；iOS 和 macOS 必须在安装了 Xcode 的 macOS 上构建。

### Android / 安卓

Prerequisites / 前置条件：

- Install Flutter and Android Studio / Android SDK.
- 安装 Flutter 和 Android Studio / Android SDK。
- Run `flutter doctor` and make sure the Android toolchain is healthy.
- 运行 `flutter doctor`，确认 Android toolchain 正常。
- For physical devices, enable USB debugging and USB installation on the phone.
- 如需真机安装，请在手机上开启 USB 调试和 USB 安装权限。

Commands / 构建命令：

```powershell
flutter pub get
flutter build apk --debug
flutter build apk --release
```

APK output / APK 产物位置：

```text
build/app/outputs/flutter-apk/
```

Optional App Bundle build / 可选 App Bundle 构建：

```powershell
flutter build appbundle --release
```

App Bundle output / App Bundle 产物位置：

```text
build/app/outputs/bundle/release/app-release.aab
```

### iOS / 苹果移动端

iOS must be built on macOS.

iOS 必须在 macOS 上构建。

Prerequisites / 前置条件：

- Install Xcode and complete the first-launch component setup.
- 安装 Xcode，并完成首次启动时的组件安装。
- Run `flutter doctor` and make sure the iOS toolchain is healthy.
- 运行 `flutter doctor`，确认 iOS toolchain 正常。
- For device or release builds, configure Apple Developer Team, Bundle
  Identifier, signing certificate, and Provisioning Profile in Xcode.
- 如需真机或发布构建，请在 Xcode 中配置 Apple Developer Team、Bundle
  Identifier、签名证书和 Provisioning Profile。

Commands / 构建命令：

```bash
flutter pub get
flutter build ios --debug
flutter build ios --release
```

iOS build output / iOS 构建产物位置：

```text
build/ios/iphoneos/
```

For App Store submission, open the Xcode workspace and archive from Xcode:

如需提交 App Store，请打开 Xcode workspace 并在 Xcode 中归档：

```bash
open ios/Runner.xcworkspace
```

Then use `Product > Archive`.

然后选择 `Product > Archive`。

### Windows / Windows 桌面端

Windows desktop must be built on Windows.

Windows 桌面端必须在 Windows 上构建。

Prerequisites / 前置条件：

- Install Flutter.
- 安装 Flutter。
- Install Visual Studio with the `Desktop development with C++` workload.
- 安装 Visual Studio，并勾选 `Desktop development with C++` 工作负载。
- Enable Flutter Windows desktop support.
- 启用 Flutter Windows 桌面支持。

Commands / 构建命令：

```powershell
flutter config --enable-windows-desktop
flutter pub get
flutter build windows
```

Windows output / Windows 产物位置：

```text
build/windows/x64/runner/Release/
```

To create a traditional Windows MSI installer / 生成传统 Windows MSI 安装包：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_windows_msi.ps1
```

The MSI script uses WiX Toolset v3 to package the Flutter Windows release
folder. If WiX is not installed, the script downloads the WiX v3 NuGet package
into `build/wix` and uses it without changing the system environment.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build_windows_msi.ps1
```

MSI output / MSI 产物位置：

```text
build/windows_msi/out/SSH_Mobile_Windows_v1.0.0_setup.msi
```

MSI 脚本使用 WiX Toolset v3 打包 Flutter Windows release 目录。如果本机没有
安装 WiX，脚本会自动下载 WiX v3 NuGet 包到 `build/wix` 并直接使用，不会修改
系统环境。传统 MSI 不像 MSIX 一样强制要求发布者证书才能安装，但正式公开分发
仍建议做代码签名，以减少 SmartScreen 或杀毒软件提示。

### macOS / macOS 桌面端

macOS desktop must be built on macOS.

macOS 桌面端必须在 macOS 上构建。

Prerequisites / 前置条件：

- Install Xcode.
- 安装 Xcode。
- Run `flutter doctor` and make sure the macOS desktop toolchain is healthy.
- 运行 `flutter doctor`，确认 macOS desktop toolchain 正常。
- Enable Flutter macOS desktop support.
- 启用 Flutter macOS 桌面支持。

Commands / 构建命令：

```bash
flutter config --enable-macos-desktop
flutter pub get
flutter build macos
```

macOS output / macOS 产物位置：

```text
build/macos/Build/Products/Release/ssh_mobile.app
```

The macOS target enables sandbox entitlements for outbound network access and
user-selected file read/write access. The app stores server passwords, private
keys, and AI API keys through the regular macOS Keychain to avoid Data
Protection Keychain entitlement error `-34018`.

macOS 目标启用了沙盒权限，允许出站网络连接以及用户选择文件的读写权限，用于
SSH/SFTP/LLM 网络请求和配置导入导出。保存服务器密码、私钥和 AI API Key
时，应用会使用普通 macOS Keychain，避免 Data Protection Keychain 缺少签名
entitlement 时触发 `-34018` 保存失败。

## Common Commands

```powershell
dart format lib test
flutter analyze
flutter test
flutter clean
flutter pub get
```

## Usage

### SSH Connections

在服务器页新增连接，填写名称、主机、端口、用户名、认证方式、服务器系统、启动模式和可选跳板机。端口默认 `22`，服务器系统默认 Linux。Linux 服务器默认使用 SSH + tmux，也可以切换为普通 SSH；Windows OpenSSH 使用普通 SSH，原生 Windows 不支持 tmux，只有连接到 WSL/Linux-like shell 且安装了 tmux 时才应按 Linux 使用。

新增或修改服务器时，保存前会先用当前主机、端口、用户名、密码或私钥发起 SSH 登录验证；验证失败会停留在表单并提示检查连接信息，避免保存不可用凭据。

删除服务器时，应用会同步移除该服务器对应的 SSH 窗口和 SFTP 连接。

在 AI 页顶部点击“应用设置”按钮会展开设置抽屉，设置面板包含语言、主题、全局字体，以及完整应用数据导入/导出。字体选择会作用于整个应用，项目不内置或重新分发字体文件；Noto / Source Han / Roboto 等选项使用系统已安装字体或开源字体名称回退，Microsoft YaHei、PingFang SC、Segoe UI 等只调用平台自带字体。备份文件会包含服务器连接配置、窗口历史、AI 设置、AI 聊天记录和自定义 Skills；SSH 密码、私钥和 AI API Key 会保持为空，导入后需要重新配置。

### Terminal Windows

终端页支持多窗口。每个窗口创建时需要唯一名称，创建后名称保持固定，用于绑定 tmux 会话。窗口列表合并在服务器页中，每台服务器下方都有默认折叠的窗口区，可展开查看、进入或关闭该服务器对应窗口；连接历史按钮位于服务器窗口总览栏右侧。

SSH 输入快捷键条支持长按拖拽调整命令位置，顺序会保存在本机，不再根据最近使用频次自动重排；自定义快捷命令仍可新增和删除。终端字号最小值放宽到极小显示档，便于在小屏幕上尽量展示更多内容。

### SFTP

SFTP 页支持：

- 多服务器切换，并尽量保持上一个服务器连接不断开。
- 选中服务器后可折叠服务器列表，桌面端收成窄栏，移动端收成紧凑服务器条，给文件列表留出更多空间。
- 断线重连后回到原目录路径。
- 上传本地文件到当前远程目录。
- 下载远程文件到本地。
- 删除文件或目录前需要输入完整目标名称进行校验，名称不匹配不会执行删除。
- 文本文件新页面编辑，支持保存、取消、滚动和字号缩放。
- Markdown、HTML、PDF 等常见文档查看。
- 设置页可调整客户端下载、文本预览、图片/PDF 预览和文本编辑的大小限制，避免大文件在移动端一次性占用过多内存。

### Performance Monitor

性能监控页使用与 SFTP 页一致的服务器选择和折叠交互，最顶部居中显示“性能监控 / 端口监控 / 应用监控”三个分区导航。性能监控支持多选服务器，点击开始后会冻结本轮选择并自动折叠服务器选择区；端口监控和应用监控各自只允许选择一台服务器，三种监控的服务器选择互不影响。未点击开始监控前不会采样；点击开始监控后，应用会根据服务器配置的 Linux/Windows 类型通过只读 SSH exec 采集状态：Linux 使用 `/proc` 和 `df`，Windows 使用 PowerShell 诊断命令，并绘制四个实时折线图：

- CPU 使用率
- 内存使用率
- 磁盘 IO 吞吐
- 网络吞吐

性能监控还会随采样刷新硬盘使用情况卡片，并基于最近一次采样、磁盘使用率和采样错误计算服务器健康评分。监控页会显示健康摘要和最近告警，服务器页也会在每台服务器卡片上显示健康分；告警只保留本轮内存事件，不写入数据库。配置区可折叠，开始监控后会默认收起并显示监控时长；刷新间隔、显示范围和每张图展示的服务器数量提供预设与自定义输入。硬盘使用情况和每张折线图都可以单独折叠；多服务器监控时可以按每图 1、3、5 台或自定义数量分组显示。监控数据不写入数据库，只保留当前启动监控后的内存数据，最多保留近 10 分钟。采样失败或网络卡顿时会自动退避并延长有效刷新间隔，成功后逐步恢复。端口监控和应用监控不自动常驻采样，只在打开对应分区或点击刷新时读取当前端口/进程状态。监控服务注册在应用级 Provider 中，离开性能监控页后不会停止；开始监控时会启动现有前台后台服务和电源锁，尽量保证应用退至后台时仍可继续采样。

### AI Assistant

AI 页通过 OpenAI-compatible API 调用大模型。模型配置统一在“大模型设置”页面中完成，包括 Base URL、API Key、模型选择、上下文窗口大小和请求超时时间。请求超时默认 60 秒，可在 30 秒到 300 秒之间选择；超时后聊天页会保留错误消息，并提供“继续”按钮，让用户从当前上下文继续而不是重新生成。默认模型列表包含：

- `deepseek-v4-flash`
- `deepseek-v4-pro`

支持从 Base URL 拉取可用模型列表。聊天页支持：

- 流式输出
- Markdown 富文本显示
- 聊天历史
- 多会话窗口
- 桌面端快捷键：Windows / macOS 上 Enter 发送，Ctrl+Enter 换行；移动端保持系统键盘的多行输入体验。
- 切换动画
- 切换页面时保活，不会因为切到 SSH/SFTP 页而中断当前回答
- AI 页位于导航栏第一位，并保留左右滑动切换页面；应用设置通过顶部“应用设置”按钮打开，聊天历史只能通过左上角历史按钮打开。
- 日志页位于页面序列最右侧，可通过横向页面切换进入。
- 每次进入 AI 页默认打开一个新的未保存草稿聊天；只有用户真正发送消息后才写入聊天历史。
- 生成过程中发送按钮会切换为停止按钮，可中途终止当前 LLM 流式请求并保留已生成内容。
- 用户消息编辑、AI 回复重新生成、从 AI 回复创建聊天分支
- 输入框工具栏：通过加号在输入框下方展开功能页，可选择本轮默认服务器、进入 Skills 管理页，或打开与当前聊天 session 绑定的 WebView。
- WebView 阅读：WebView 入口会跳转到独立窗口，返回后回到 AI 聊天页；再次点击同一聊天的 WebView 会恢复上次打开的页面。删除聊天历史时会同步删除该聊天绑定的 WebView 状态。
- 快捷上下文：工具栏选择的默认服务器会进入当前用户消息的上下文，不修改 system prompt。
- 自定义 Skills 管理：可在独立页面查看、新增、编辑、删除本地 skills，并控制是否在聊天工具栏可用；每个 skill 包含名称、说明和具体内容，具体内容支持 SKILL.md 风格 front matter、workflow、references 路径和自定义规范。
- 写命令审批：模型请求执行会修改服务器状态的命令时，聊天页会显示“同意 / 拒绝”按钮。
- 折叠执行详情：深度思考、工具调用、工具结果和审批结果默认折叠，用户需要时可逐项展开查看。
- 上下文窗口用量显示：顶部显示当前会话估算 token 用量和窗口占比。
- 记忆瘦身：聊天记录仍保留完整显示内容，但发送给模型的上下文会优先使用精简后的 `contextText`；长文档、HTML、多代码块等输出不会完整回灌。LLM 思考、tool 调用、tool 结果和通过 SFTP 读取的小文本文件内容会写入 assistant 执行记忆，方便后续排查服务器状态。
- 自动上下文压缩：当估算用量达到所选窗口 90% 时，应用会先调用当前模型总结旧上下文，再继续当前问题；压缩摘要作为普通 assistant 记忆消息传入，保持主 system prompt 稳定以提高缓存命中率。
- 回复用量统计：每条 AI 回复下方以小字号显示 token 用量和执行耗时，不影响聊天交互。DeepSeek 流式响应会通过 `stream_options.include_usage` 在结束前回传 API 实测用量；如果兼容接口没有返回 usage，则退回本地估算并标记为 `est.`。

### AI Tools

模型可调用的工具集中定义在 `lib/services/ai_tool_service.dart`，便于维护。当前 tools 包括：

- `list_servers`：列出已保存服务器，不泄露密码、私钥或 API Key。
- `client_get_time`：在客户端执行，读取手机/当前设备系统时间、UTC、时区和语言环境。
- `client_get_device_info`：在客户端执行，读取当前设备平台、系统版本、语言环境、时区等非敏感信息。
- `client_get_network_info`：在客户端执行，读取当前设备网络连通、网络类型、VPN/代理/DNS 和 Wi-Fi 粗略信息；Android 信息更完整。
- `client_get_battery_status`：在客户端执行，读取电量、充电状态、省电模式和电池优化状态，帮助排查 SSH 保活和监控后台采样。
- `client_open_app_settings`：在客户端执行，打开系统里的 SSH Mobile 应用设置页，方便用户调整通知、后台、电池等权限。
- `client_set_clipboard`：在客户端执行，把文本复制到当前设备剪贴板，方便用户粘贴命令、报告或配置片段。
- `client_set_alarm`：在客户端执行，设置本地提醒；Android 会尝试调用系统 Clock 创建闹钟，其他平台使用应用内本地通知提醒。
- `client_list_alarms` / `client_cancel_alarm`：在客户端执行，查看或取消本次应用进程内创建的提醒。
- `client_webview_get_page_text`：在客户端执行，读取当前聊天 session 绑定 WebView 的可见纯文本内容，不读取图片、隐藏 DOM、密码字段或跨域 iframe 内容。
- `run_command`：在指定服务器执行 shell 命令。只读诊断命令可直接执行，写命令必须在聊天页由用户人工同意后才会执行。
- `sftp_list_dir`：通过 SFTP 列出远程目录。
- `sftp_read_text`：读取小型远程文本文件。
- `get_server_status`：通过只读 SSH exec 获取服务器性能、端口和应用进程状态，支持 `performance`、`ports`、`applications` 和 `all` 模式。
- `generate_ops_report`：通过只读 SSH exec 汇总性能、磁盘、端口和应用进程状态，返回健康评分、风险点和建议排查方向，供 AI 生成运维报告。

`run_command` 默认优先只读诊断。对于可能修改服务器状态的命令，LLM 服务会暂停 tool round，并在聊天页展示目标服务器、原因和完整命令。用户点击“同意”后才执行；点击“拒绝”会中断当前操作，用户可以继续手动告诉模型下一步要怎么做。涉及密码、私钥或交互式提权的命令仍会被拦截。

工具 round 不再设置固定次数上限；模型可以连续调用工具直到自然给出最终回复，用户可通过停止按钮中断异常循环。

AI tools 执行服务器命令时使用一次性 SSH exec 连接，不会 attach 或复用 tmux 会话。tmux 只用于交互式终端窗口。

`client_*` tools 明确运行在客户端，也就是运行 SSH Mobile 的手机/桌面端，不会连接任何 SSH 服务器。网络和电池工具用于排查客户端侧导致的 SSH/SFTP 卡顿、后台断连和监控采样中断；剪贴板工具只写入客户端剪贴板。客户端提醒默认会创建应用内本地通知；Android 系统闹钟由系统 Clock 应用接收，部分厂商系统可能弹出确认界面或拒绝后台设置。

### Logs

日志页记录开发日志、SSH/SFTP 状态、LLM 请求、tool 调用和异常。日志页不在导航栏中显示，可以通过页面切换进入；进入日志页时导航栏选中状态会消失。

## Background Permissions

Android 端可能用到：

- `INTERNET`：建立 SSH/SFTP/LLM 网络连接。
- `ACCESS_NETWORK_STATE` / `ACCESS_WIFI_STATE`：感知网络状态。
- `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_DATA_SYNC`：运行前台服务维护会话。
- `POST_NOTIFICATIONS`：显示后台保活通知。
- `WAKE_LOCK`：降低后台任务过早挂起概率。
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`：引导用户放宽电池优化。

## Known Limitations

- 系统后台策略仍可能断开长期后台连接。
- Wi-Fi、移动数据、VPN 切换时，底层 TCP 连接通常会失效；应用可以重连，但不能无缝迁移原 TCP 连接。
- SSH + tmux 能恢复服务器端会话，但前提是 tmux 会话仍存在且未被自动清理。
- AI tools 默认以安全只读操作为主；写命令需要人工审批，且不适合执行需要交互式密码或私钥输入的命令。
- 大文件和二进制文件不适合直接通过 AI tool 读取。

## Troubleshooting

### Device Not Found

```powershell
flutter devices
```

如果目标设备未出现，请检查 USB 调试、授权弹窗、数据线、驱动和目标平台工具链。

### APK Install Failed

如果出现：

```text
INSTALL_FAILED_USER_RESTRICTED: Install canceled by user
```

说明手机系统取消或限制了安装。请在手机上允许 USB 安装、允许当前电脑调试、关闭系统安装限制，或手动确认安装弹窗。

### tmux Is Missing

如果 SSH + tmux 提示服务器没有安装 tmux，请手动登录服务器安装：

```bash
# Debian / Ubuntu
sudo apt-get update && sudo apt-get install -y tmux

# Fedora
sudo dnf install -y tmux

# CentOS / RHEL
sudo yum install -y tmux

# Arch Linux
sudo pacman -Sy --noconfirm tmux

# Alpine Linux
sudo apk add tmux
```

### AI Tools Notes

- SFTP normal download, text preview, rich preview, and text edit limits are
  configurable from the app settings drawer; defaults stay conservative to
  protect mobile memory.
- AI tools include `detect_os` and use the saved server platform when available
  before running OS-specific diagnostics. Linux servers only accept Linux/POSIX
  diagnostics; Windows servers require explicit `cmd /c` or PowerShell/pwsh
  commands. Delete/remove commands are blocked for AI tools, even when a write
  command would otherwise be eligible for user approval.
- When Windows commands return access-denied or elevation-required errors, the
  tool result explicitly reports that the current account lacks permission and
  asks the user to use an Administrator/elevated account or grant the required
  access.
- Client-side tools are named with the `client_` prefix and return
  `execution: client`. They run on the SSH Mobile client device, not on a saved
  SSH server. Current client tools include time/device/network/battery info,
  app settings, clipboard write, in-app reminders, and current-chat WebView
  visible text reading; Android also attempts a system Clock alarm via
  `ACTION_SET_ALARM`.

### LLM API Errors

- 确认 Base URL 是 OpenAI-compatible 接口地址，例如 `https://api.deepseek.com`。
- 确认 API Key 已保存。
- 确认模型名称存在并可用。
- DeepSeek thinking mode 会返回 `reasoning_content`，应用已在 tool round 中自动回传该字段。
- 错误详情会写入日志页，便于排查。

## License

当前仓库未声明开源许可证。公开发布前请补充明确的 `LICENSE` 文件。
