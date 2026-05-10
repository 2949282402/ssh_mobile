# SSH Mobile

SSH Mobile 是一个基于 Flutter 的跨平台 SSH / SFTP 客户端，面向移动端长时间终端会话、多窗口操作、文件管理和 AI 辅助运维场景。它支持普通 SSH、SSH + tmux、多终端窗口、SFTP 文件管理、开发日志、连接历史、黑白主题、中英文界面，以及 OpenAI-compatible 大模型接入。

SSH Mobile is a Flutter-based cross-platform SSH / SFTP client for long-running terminal sessions, multi-window workflows, remote file management, and AI-assisted server operations. It supports normal SSH, SSH + tmux, multiple terminal windows, SFTP, developer logs, connection history, light/dark themes, Chinese/English UI, and OpenAI-compatible LLM integration.

> 后台网络连接受系统策略影响。应用会尽量通过前台服务、通知、WakeLock、SSH keep-alive 和 tmux 恢复机制提高稳定性，但长期后台运行仍可能受到省电策略、网络切换和进程回收影响。需要保留服务器端工作现场时，推荐使用 SSH + tmux。

## Features

- SSH 连接管理：保存多服务器配置，支持密码、私钥、私钥密码和可选跳板机。
- 多终端窗口：同一服务器可打开多个窗口，窗口名固定，用于稳定绑定 tmux 会话。
- SSH + tmux：默认推荐模式，适合 `codex`、编辑器、构建任务和长时间脚本。
- tmux 恢复与清理：断连后可回到原会话，也可配置无客户端自动清理旧会话。
- 导航顺序：AI 页、服务器页、窗口页、SFTP 页和日志页；应用启动默认进入服务器页，日志页不显示在导航栏中。
- SFTP 文件管理：支持多服务器切换、保持连接、路径记忆、上传、下载、删除确认、文本编辑和文件预览。
- 文件预览：支持文本、Markdown、HTML、PDF 等常见文档类型的查看。
- AI 大模型聊天页：通过 API Key 接入 OpenAI-compatible 接口，默认支持 DeepSeek 模型。
- AI Tools：模型可调用工具列出服务器、执行只读诊断命令、浏览 SFTP 目录、读取小文本文件；写命令必须先经过人工同意。
- 流式输出与富文本：AI 回复支持流式显示和 Markdown 富文本渲染。
- 过程详情：模型的深度思考、工具调用参数、工具执行结果和写命令审批结果会在聊天消息下方折叠展示。
- 聊天工具栏：输入框旁的 `+` 会在输入框下方展开类似微信的功能面板，只保留服务器选择和 Skills 管理入口。
- 上下文管理：AI 页显示上下文窗口用量，可选择 259K、512K、1M，长文档输出只保留精简记忆进入后续上下文，达到 90% 自动调用模型压缩上下文。
- 聊天历史与多窗口：AI 页支持多会话历史、新建聊天、切换动画和当前会话保活。
- 消息编辑与分支：用户消息可编辑后重新发送，AI 回复可重新生成，也可从某条 AI 回复创建新分支继续追问。
- 开发日志：日志页记录 SSH、SFTP、LLM、tool 调用和错误信息，日志包含来源文件/行号，支持筛选、复制、长按多选和批量删除。
- 设置面板与备份：点击设置图标展开设置面板，支持主题/语言切换，以及一键导出/导入服务器、窗口历史、AI 聊天和自定义 Skills；密码、私钥和 API Key 不会导出。
- 主题与语言：默认使用浅色主题和中文界面，支持黑白主题和中英文界面切换；全局视觉系统统一了色彩、圆角、输入框、按钮和导航样式。
- 移动端导航优化：底部导航栏可自动收起，减少屏幕占用。

## Tech Stack

| Module | Package | Description |
| --- | --- | --- |
| Flutter UI | `flutter`, `provider` | 页面、状态、主题和语言管理 |
| SSH / SFTP | `dartssh2` | 纯 Dart SSH 和 SFTP 客户端 |
| Terminal | `xterm` | ANSI 终端渲染、输入输出和滚动缓存 |
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
│   │   ├── home_screen.dart         # 主页面、导航、窗口入口
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

## Build

```powershell
flutter build apk --debug
flutter build apk --release
```

产物位置：

```text
build/app/outputs/flutter-apk/
```

macOS 桌面端需要在 macOS 设备上构建：

```bash
flutter config --enable-macos-desktop
flutter build macos
```

macOS 产物位置：

```text
build/macos/Build/Products/Release/ssh_mobile.app
```

macOS Release 包启用了沙盒权限，并允许出站网络连接以及用户选择文件的读写权限，用于 SSH/SFTP/LLM 网络请求和配置导入导出。
保存服务器密码、私钥和 AI API Key 时，应用会在 macOS 上使用普通 Keychain，
避免 Data Protection Keychain 缺少签名 entitlement 时触发 `-34018` 保存失败。

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

在服务器页新增连接，填写名称、主机、端口、用户名、认证方式、启动模式和可选跳板机。端口默认 `22`。新建配置默认使用 SSH + tmux，也可以切换为普通 SSH。

删除服务器时，应用会同步移除该服务器对应的 SSH 窗口和 SFTP 连接。

点击右上角设置图标会展开设置面板，设置面板包含语言、主题，以及完整应用数据导入/导出。备份文件会包含服务器连接配置、窗口历史、AI 设置、AI 聊天记录和自定义 Skills；SSH 密码、私钥和 API Key 会保持为空，导入后需要重新配置。

### Terminal Windows

终端页支持多窗口。每个窗口创建时需要唯一名称，创建后名称保持固定，用于绑定 tmux 会话。窗口管理页可以查看所有窗口、进入窗口、关闭窗口或批量关闭窗口。

### SFTP

SFTP 页支持：

- 多服务器切换，并尽量保持上一个服务器连接不断开。
- 断线重连后回到原目录路径。
- 上传本地文件到当前远程目录。
- 下载远程文件到本地。
- 删除文件前二次确认。
- 文本文件新页面编辑，支持保存、取消、滚动和字号缩放。
- Markdown、HTML、PDF 等常见文档查看。

### AI Assistant

AI 页通过 OpenAI-compatible API 调用大模型。模型配置统一在“大模型设置”弹窗中完成，包括 Base URL、API Key、模型选择和上下文窗口大小。默认模型列表包含：

- `deepseek-v4-flash`
- `deepseek-v4-pro`

支持从 Base URL 拉取可用模型列表。聊天页支持：

- 流式输出
- Markdown 富文本显示
- 聊天历史
- 多会话窗口
- 切换动画
- 切换页面时保活，不会因为切到 SSH/SFTP 页而中断当前回答
- AI 页位于导航栏第一位；在 AI 页从左边缘向右滑动会跟手打开左侧聊天历史面板。
- 日志页位于页面序列最右侧，可通过横向页面切换进入。
- 用户消息编辑、AI 回复重新生成、从 AI 回复创建聊天分支
- 输入框工具栏：通过加号在输入框下方展开功能页，可选择本轮默认服务器，或进入 Skills 管理页。
- 快捷上下文：工具栏选择的默认服务器会进入当前用户消息的上下文，不修改 system prompt。
- 自定义 Skills 管理：可在独立页面查看、新增、编辑、删除本地 skills，并控制是否在聊天工具栏可用；每个 skill 包含名称、说明和具体内容，具体内容支持 SKILL.md 风格 front matter、workflow、references 路径和自定义规范。
- 写命令审批：模型请求执行会修改服务器状态的命令时，聊天页会显示“同意 / 拒绝”按钮。
- 折叠执行详情：深度思考、工具调用、工具结果和审批结果默认折叠，用户需要时可逐项展开查看。
- 上下文窗口用量显示：顶部显示当前会话估算 token 用量和窗口占比。
- 记忆瘦身：聊天记录仍保留完整显示内容，但发送给模型的上下文会优先使用精简后的 `contextText`；长文档、HTML、多代码块等输出不会完整回灌。
- 自动上下文压缩：当估算用量达到所选窗口 90% 时，应用会先调用当前模型总结旧上下文，再继续当前问题；压缩摘要作为普通 assistant 记忆消息传入，保持主 system prompt 稳定以提高缓存命中率。
- 回复用量统计：每条 AI 回复下方以小字号显示 token 用量和执行耗时，不影响聊天交互。DeepSeek 流式响应会通过 `stream_options.include_usage` 在结束前回传 API 实测用量；如果兼容接口没有返回 usage，则退回本地估算并标记为 `est.`。

### AI Tools

模型可调用的工具集中定义在 `lib/services/ai_tool_service.dart`，便于维护。当前 tools 包括：

- `list_servers`：列出已保存服务器，不泄露密码、私钥或 API Key。
- `run_command`：在指定服务器执行 shell 命令。只读诊断命令可直接执行，写命令必须在聊天页由用户人工同意后才会执行。
- `sftp_list_dir`：通过 SFTP 列出远程目录。
- `sftp_read_text`：读取小型远程文本文件。

`run_command` 默认优先只读诊断。对于可能修改服务器状态的命令，LLM 服务会暂停 tool round，并在聊天页展示目标服务器、原因和完整命令。用户点击“同意”后才执行；点击“拒绝”会中断当前操作，用户可以继续手动告诉模型下一步要怎么做。涉及密码、私钥或交互式提权的命令仍会被拦截。

AI tools 执行服务器命令时使用一次性 SSH exec 连接，不会 attach 或复用 tmux 会话。tmux 只用于交互式终端窗口。

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

### LLM API Errors

- 确认 Base URL 是 OpenAI-compatible 接口地址，例如 `https://api.deepseek.com`。
- 确认 API Key 已保存。
- 确认模型名称存在并可用。
- DeepSeek thinking mode 会返回 `reasoning_content`，应用已在 tool round 中自动回传该字段。
- 错误详情会写入日志页，便于排查。

## License

当前仓库未声明开源许可证。公开发布前请补充明确的 `LICENSE` 文件。
