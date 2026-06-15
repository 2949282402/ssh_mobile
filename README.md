# SSH Mobile

SSH Mobile 是一个基于 Flutter 的跨平台 SSH / SFTP 客户端，面向移动端长时间终端会话、多窗口操作、文件管理和 AI 辅助运维场景。项目覆盖 Android、iOS、macOS 和 Windows，核心能力围绕 SSH、SFTP、性能监控、日志和 OpenAI-compatible 大模型工具化运维展开。

SSH Mobile is a Flutter-based cross-platform SSH / SFTP client for long-running terminal work, remote file management, server monitoring, logs, and AI-assisted operations through OpenAI-compatible models.

> 后台网络连接仍会受到系统省电、网络切换和进程回收影响。需要尽量保留服务器端工作现场时，推荐使用 `SSH + tmux`。

## Related Docs

- [docs/ANDROID_NATIVE_REWRITE_GUIDE.md](docs/ANDROID_NATIVE_REWRITE_GUIDE.md)
- [docs/ADR_ENGINEERING_BASELINE.md](docs/ADR_ENGINEERING_BASELINE.md)
- [docs/PERFORMANCE_ACCEPTANCE.md](docs/PERFORMANCE_ACCEPTANCE.md)
- [AGENT_MEMORY.md](AGENT_MEMORY.md)

## Highlights

<<<<<<< HEAD
- SSH 连接管理：支持密码、私钥、私钥密码、跳板机和服务器平台选择。
- 多终端窗口：同一服务器可创建多个窗口，窗口名固定，用于稳定绑定 tmux 会话。
- SFTP：支持目录浏览、上传、下载、文本编辑、文件预览和输入名称确认删除。
- 性能监控：包含 Performance、Ports、Applications、Services 四个分区。
- AI 聊天：支持流式输出、Markdown、聊天历史、消息编辑、重新生成、分支和上下文压缩。
- AI tools：支持服务器诊断、SFTP 路径操作、客户端信息、WebView 搜索与读取、日志与备份操作。
- 日志：集中记录 SSH、SFTP、LLM、AI tools 和异常信息。
- 设置与备份：支持语言、主题、字体、AI 设置、聊天和窗口历史导入导出，但不导出密码、私钥或 API Key。
- 附加页面：包含系统管理、Playbook、RAG 知识库、AI Skills、终端历史和客户端 WebView。
=======
The current maintenance baseline is documented in
[`docs/ADR_ENGINEERING_BASELINE.md`](docs/ADR_ENGINEERING_BASELINE.md). Release
Android builds disable cleartext traffic by default; debug and profile builds
keep cleartext enabled for local OpenAI-compatible provider testing.

Performance-sensitive changes should be checked against
[`docs/PERFORMANCE_ACCEPTANCE.md`](docs/PERFORMANCE_ACCEPTANCE.md), especially
terminal large output, AI long streaming replies, SFTP large directories, and
multi-server monitor sampling.

Core SSH, SFTP, LLM, AI tool, chat storage, terminal-history, and backup flows
now expose lightweight Dart interfaces so tests and future feature controllers
can inject fake implementations without real network or platform credentials.
Backup import/export remains credential-free: passwords, private keys, and AI
API keys are never restored from backup JSON and must be reconfigured manually.

## Features

- SSH 连接管理：保存多服务器配置，支持密码、私钥、私钥密码和可选跳板机。
- 多终端窗口：同一服务器可打开多个窗口，窗口名固定，用于稳定绑定 tmux 会话。
- SSH + tmux：默认推荐模式，适合 `codex`、编辑器、构建任务和长时间脚本。
- tmux 恢复与清理：断连后可回到原会话，也可配置无客户端自动清理旧会话。
- 导航顺序：AI 页、服务器页、SFTP 页、性能监控页和日志页；窗口管理合并到服务器页，应用启动默认进入服务器页，日志页不显示在导航栏中。
- SFTP 文件管理：支持多服务器切换、保持连接、路径记忆、目录列表缓存（30秒 TTL）、下载预览与缩略图 SHA-256 临时缓存（自动比对大小与修改时间校验）、上传、下载、输入名称确认删除、文本编辑和文件预览。
- 性能监控：可多选服务器，点击开始后实时绘制 CPU、内存、磁盘 IO 和网络折线图，默认 10 秒刷新一次，最多保留本轮监控启动后的近 10 分钟数据，历史采样超过 5 分钟的数据自动进行 10 秒分组降采样平均处理，并给出健康评分与内存告警。
- 文件预览：支持文本、Markdown、HTML、PDF 等常见文档类型的查看。
- AI 大模型聊天页：通过 API Key 接入 OpenAI-compatible 接口，默认支持 DeepSeek 模型。
- AI Tools：模型可调用工具列出服务器、执行只读诊断命令、浏览 SFTP 目录、读取小文本文件、生成服务器运维报告，也可调用客户端工具查看本机时间/设备/网络/电池状态、打开应用设置、复制文本和设置客户端提醒；写命令必须先经过人工同意。
- 流式输出与富文本：AI 回复支持流式显示和 Markdown 富文本渲染。
- 过程详情：模型的深度思考、工具调用参数、工具执行结果和写命令审批结果会在聊天消息下方折叠展示。
- 聊天工具栏：输入框旁的 `+` 会在输入框下方展开类似微信的功能面板，提供服务器选择、Skills 管理和当前会话绑定的 WebView 入口。
- 上下文管理：AI 页显示上下文窗口用量，可选择 259K、512K、1M，长文档输出只保留精简记忆进入后续上下文，达到 90% 自动调用模型压缩上下文。
- 聊天历史与多窗口：AI 页支持多会话历史、新建聊天、切换动画和当前会话保活。
- 消息编辑与分支：用户消息可编辑后重新发送，AI 回复可重新生成，也可从某条 AI 回复创建新分支继续追问。
- 开发日志：日志页记录 SSH、SFTP、LLM、tool 调用和错误信息，日志包含来源文件/行号，支持筛选、复制、长按多选和批量删除。日志写入使用异步队列，并实施大小自动轮转（单个日志上限 5MB，最多保留 3 个历史归档，共 20MB 上限）。
- 辅助页面：服务器新增/编辑、系统管理、Playbook、RAG 知识（采用分区存储结构：轻量级 metadata 与独立文档 JSON，并在后台 Isolate 中进行向量相似度和 BM25 检索计算）、AI Skills、终端历史、客户端 WebView 和启动页都保留为独立页面，供主流程复用而不是塞进底部导航。
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
retry with a fresh one-shot SSH connection after transient interruptions. RAG storage is optimized through JSON database partitioning, and heavy calculations (cosine similarity, BM25 indexing, and JSON encoding/decoding) are offloaded to background Isolates via `compute()`. SFTP directory lists are cached in-memory with a 30s TTL, while file previews/thumbnails are temporarily cached with SHA-256 keys and validated against remote size and timestamp metadata. Performance Monitor history data points older than 5 minutes are grouped and averaged into 10-second intervals to prevent UI rendering lag. Developer logs are managed via an asynchronous queue with auto-rotation capped at 5MB per file (max 3 archive files).
LLM settings include DeepSeek-only thinking controls. For DeepSeek API hosts the
client can send `thinking.enabled/disabled` and `reasoning_effort` (`high` or
`max`); generic OpenAI-compatible providers are left untouched. Local web search
is enabled by default as a client-side `web_search` function tool backed by the
current chat's WebView, and users can disable it in LLM settings. The assistant
prompt tells enabled models to call it before answering current/latest/news or
other external-information questions, and the tool definition embeds the
current per-call result count setting. OpenAI hosted web search belongs in a
separate Responses API adapter.
Automatic multi-agent collaboration is enabled by default for complex AI chat
requests such as troubleshooting, implementation planning, audits, performance
work, reports, and multi-server operations. Helper agents run in parallel before
the main assistant response, but they do not receive tool definitions and cannot
execute SSH, SFTP, or client tools directly. Their redacted advisory summary is
added as normal assistant memory, while the primary assistant remains
responsible for tool calls, approval gates, cancellation, and the final answer.
Users can disable this mode or choose the maximum helper-agent count in LLM
settings.

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
>>>>>>> 4b1dcc59f0cd32d1daff6a438b0c1d8810e30ef2

## Project Structure

大型页面和服务普遍使用 Dart `part` 文件拆分，维护时优先沿用现有特征目录结构。

- `lib/screens/`: 页面入口和对应的 `home/`、`llm_chat/`、`performance_monitor/`、`sftp/`、`terminal/` 等拆分目录
- `lib/services/`: SSH、SFTP、LLM、AI tools、监控、存储及配套子目录 `ai_tool/`、`llm_chat/`、`storage/`
- `lib/models/`: 连接等核心数据模型
- `lib/theme/`, `lib/utils/`, `lib/widgets/`: 主题、工具和复用组件
- `assets/`: 静态资源
- `docs/`: 设计与维护文档
- `scripts/`: 构建和维护脚本
- `test/`: 单元和组件测试
- `third_party/xterm/`: vendored terminal package

## Agent Collaboration

Codex 使用 `.agents/skills/ssh-mobile-maintenance/SKILL.md`，Claude Code 使用 `.claude/skills/ssh-mobile-maintenance/SKILL.md`。修改 skill 后请同步检查：

```powershell
.\scripts\sync_agent_skills.ps1 -Mode Check
.\scripts\sync_agent_skills.ps1 -Mode Link -Force
```

`AGENT_MEMORY.md` 用于保存跨会话的非敏感项目记忆，不要写入密码、私钥、API Key、token 或服务器凭据。

## Development

### Environment

- Flutter 3.x
- Dart SDK `>=3.2.0 <4.0.0`
- Android Studio / Android SDK 或对应平台工具链
- Windows 桌面构建需要 Visual Studio 的 `Desktop development with C++`
- iOS / macOS 构建需要 macOS 和 Xcode

如国内网络访问 `pub.dev` 不稳定，可临时使用：

```powershell
$env:PUB_HOSTED_URL='https://pub.flutter-io.cn'
flutter pub get
```

### Common Commands

```powershell
flutter pub get
dart format lib test
flutter analyze
flutter test
flutter devices
flutter run -d <device-id>
flutter build apk --debug
flutter build windows
powershell -ExecutionPolicy Bypass -File .\scripts\build_windows_msi.ps1
```

### Run

```powershell
flutter devices
flutter run -d <device-id>
```

如果安装 Android APK 时出现 `INSTALL_FAILED_USER_RESTRICTED`，通常是手机系统拦截了 USB 安装或用户取消了安装确认。

### Build

Android:

```powershell
flutter pub get
flutter build apk --debug
flutter build apk --release
flutter build appbundle --release
```

输出目录：

- `build/app/outputs/flutter-apk/`
- `build/app/outputs/bundle/release/app-release.aab`

Windows:

```powershell
flutter config --enable-windows-desktop
flutter pub get
flutter build windows
powershell -ExecutionPolicy Bypass -File .\scripts\build_windows_msi.ps1
```

输出目录：

- `build/windows/x64/runner/Release/`
- `build/windows_msi/out/SSH_Mobile_Windows_v1.0.0_setup.msi`

MSI 脚本使用 WiX Toolset v3；若本机未安装，脚本会下载到 `build/wix` 后直接使用。

macOS:

```bash
flutter config --enable-macos-desktop
flutter pub get
flutter build macos
```

输出目录：

- `build/macos/Build/Products/Release/ssh_mobile.app`

iOS:

```bash
flutter pub get
flutter build ios --debug
flutter build ios --release
open ios/Runner.xcworkspace
```

iOS 和 macOS 只能在 macOS 上构建。

## Usage Overview

### Servers and Terminal

服务器页负责保存连接、选择启动模式和管理终端窗口。保存或编辑服务器时，应用会先尝试用当前 host、port、username 和认证信息验证 SSH 登录。Linux 服务器默认适合 `SSH + tmux`，Windows 服务器使用 plain SSH，除非用户明确连接到 WSL 或其他 Linux-like shell。

终端窗口管理已经嵌入服务器页。每台服务器卡片下方都有默认折叠的窗口区域，窗口名创建后保持固定，用于绑定 tmux 会话。连接历史入口位于服务器窗口总览区域。

### SFTP

SFTP 页支持多服务器切换、路径记忆、上传、下载、文本编辑和常见文档预览。删除文件或目录前必须输入完整目标名称。客户端可在设置中调整普通下载、文本预览、富预览和文本编辑的大小限制，以避免大文件在移动端占用过多内存。

### Performance Monitor

性能监控页包含四个分区：

- `Performance`: 多服务器、手动开始、保留近 10 分钟内存样本
- `Ports`: 单服务器端口快照
- `Applications`: 单服务器进程快照
- `Services`: 单服务器服务状态快照

Linux 监控使用 `/proc` 和 `df -P`，Windows 监控使用 `ServerStatusProbe` 中的 PowerShell JSON 采样路径。监控服务会维护内存中的健康分和最近告警，服务器页可展示轻量健康状态。

### AI Chat

AI 页负责聊天、历史、WebView、Skills 和 LLM 设置。当前聊天支持：

- SSE 流式回复和 Markdown 渲染
- 聊天历史侧边覆盖层
- 用户消息编辑后重发
- AI 回复重新生成和从指定回复创建分支
- 工具调用、工具结果、审批和 reasoning 的折叠详情
- 上下文窗口 `259K` / `512K` / `1M`
- 上下文达到 90% 时自动压缩旧历史
- 页面切换时保活

LLM 设置集中在单独的设置页中，包含 Base URL、API Key 历史、模型、上下文窗口、DeepSeek / OpenAI 推理参数、Web 搜索、多代理、上传大小等配置。AI 聊天回复、上下文压缩、多代理辅助和工具回合不设置固定请求超时；如果发送时遇到可重试网络错误，会自动重试三次，失败后再显示错误。

### AI Tools

AI tools 以能力分组维护在 `lib/services/ai_tool/` 中，而不是把逻辑散在聊天页里。当前主要包括：

- 服务器与诊断：`list_servers`、`run_command`、`get_server_status`、`generate_ops_report`
- SFTP 路径操作：目录列表、元数据、文本读取、下载，以及写入、上传、创建目录、重命名、删除
- 客户端工具：时间、设备、网络、电池、权限、剪贴板、提醒、日志、备份、应用设置
- WebView / 搜索：`web_search`、当前聊天 WebView 读取和导航
- 技能记忆：如 `client_save_experience_skill`

约束规则：

- `client_*` tools 运行在 SSH Mobile 客户端，不连接服务器。
- `run_command` 会强制遵守保存的 `serverPlatform`。
- 远程写入、本地导入、日志删除/清空、监控状态变更等操作必须经过统一审批。
- AI destructive shell delete/remove 命令会被拦截；SFTP 变更工具需显式审批。
- 所有 tool 参数、结果和 trace 都经过 `ToolSecretPolicy` 过滤或拦截，避免暴露凭据和敏感路径内容。

### Logs, Settings, Backup

日志页记录开发日志、SSH/SFTP 状态、LLM 请求、AI tool 调用和异常。应用设置从 AI 页顶部按钮打开，与 LLM 设置分离。导出备份包含服务器、窗口恢复信息、终端历史、AI 设置、AI 聊天和自定义 Skills，但密码、私钥和 API Key 会保持为空，导入后需要重新配置。

## Operational Notes

- 系统后台策略、网络切换和进程回收仍可能影响长时间连接。
- Android release 默认禁用 cleartext；debug/profile 仅用于本地 OpenAI-compatible provider 测试。
- macOS 端保存密码、私钥和 API Key 时，保持普通 Keychain 配置，避免 `-34018` entitlement 错误。

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

请在手机上允许 USB 安装、允许当前电脑调试、关闭系统安装限制，或手动确认安装弹窗。

### tmux Missing

如果服务器提示没有安装 tmux，请手动登录服务器安装：

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

- 确认 Base URL 是正确的 OpenAI-compatible 接口地址
- 确认 API Key 已保存且未被显式清空
- 确认模型名称可用
- DeepSeek `reasoning_content` 已在 tool round 中自动回传
- 详细错误会写入日志页，便于排查

## License

当前仓库未声明开源许可证。公开发布前请补充明确的 `LICENSE` 文件。
