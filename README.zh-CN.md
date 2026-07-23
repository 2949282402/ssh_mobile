<p align="center">
  <img src="assets/app_icon_1024.png" alt="SSH Mobile 图标" width="112" />
</p>

<h1 align="center">SSH Mobile</h1>

<p align="center">
  面向长时间远程会话的跨平台 SSH / SFTP、服务器监控与 AI 辅助运维客户端
</p>

<p align="center">
  <a href="./README.md">English</a> | <strong>简体中文</strong>
</p>

<p align="center">
  <a href="https://github.com/hejulian2004/ssh_mobile/actions/workflows/flutter.yml"><img src="https://github.com/hejulian2004/ssh_mobile/actions/workflows/flutter.yml/badge.svg" alt="Flutter CI" /></a>
</p>

SSH Mobile 是一个基于 Flutter 的跨平台 SSH / SFTP 客户端，覆盖 Android、iOS、macOS、Windows 和 Web。它把多窗口终端、远程文件管理、服务器监控、安全存储和 OpenAI-compatible AI tools 整合为一个移动端与桌面端运维工作台。

项目最初源于一台只有 2 核 CPU 和 1 GB 内存的服务器。完整 AI Agent 无法在这类低配置服务器上稳定运行，因此 SSH Mobile 将模型推理和 Agent 编排放在客户端，再通过 SSH 和 SFTP 检查、维护远程服务器，从而避免占用服务器有限的内存。

> 移动系统的省电策略、网络切换和进程回收仍可能影响后台连接。需要长期保留远程工作现场时，推荐配合 `SSH + tmux` 使用。

## 核心亮点

- **SSH 连接管理**：支持密码、私钥、私钥密码、跳板机、服务器平台选择和 SSH Host Key 首次信任校验。
- **多终端窗口**：同一服务器可创建多个固定名称的终端窗口，并稳定绑定 tmux 会话。
- **SFTP 文件管理**：支持目录浏览、最近与收藏路径、上传、下载、编辑、预览和输入完整名称确认删除。
- **局域网快传**：支持 mDNS/UDP 发现、扫码或设备列表发起配对邀请、双向 PIN 确认和加密设备间传输；应用在前台时可全局唤起对端配对页，并合并双方同时发起的邀请。
- **服务器监控**：查看性能、端口、应用进程、服务、用户和活动会话。
- **AI Chat 与 Agent 执行**：支持流式输出、Plan Mode、审批式工具调用、聊天历史、消息分支、上下文压缩、RAG、Skills 和执行 Trace。
- **本地 MCP Server**：桌面端可生成 Codex、Claude Code 和 Gemini CLI 配置。
- **安全存储**：使用平台 Secure Storage、加密 Drift 字段、加密预览缓存、敏感信息脱敏和不可变审批目标。
- **自适应界面**：覆盖手机、平板和桌面环境，并提供专门的 1.5K 与 2K Android 测试配置。
- **备份与恢复**：可导入导出服务器、终端历史、AI 设置、聊天、Playbook、运行指标和路径记录，但不会导出密码、私钥或 API Key。

## 安装与运行

### 环境要求

- Flutter `>=3.44.0`，CI 固定使用 Flutter `3.44.2`。
- Dart SDK `>=3.12.0 <4.0.0`。
- Android Studio、Android SDK 或对应目标平台的开发工具链。
- Windows 构建需要 Visual Studio 的 `Desktop development with C++`。
- iOS 与 macOS 构建需要 macOS 和 Xcode。
- iOS 14.0 或更高版本。

### 安装依赖

```bash
git clone https://github.com/hejulian2004/ssh_mobile.git
cd ssh_mobile
flutter pub get
```

### 运行项目

```bash
flutter devices
flutter run -d <device-id>
```

示例：

```bash
flutter run -d android
flutter run -d windows
flutter run -d macos
flutter run -d chrome
```

应用在没有真实服务器或 AI 凭据时也可以启动。终端、SFTP 和监控的集成测试需要一台可访问的 SSH 服务器；只有 AI Chat 与 Agent 执行功能需要配置模型服务。

### 各平台构建

```bash
# Android
flutter build apk --debug
flutter build apk --release
flutter build appbundle --release

# macOS
flutter config --enable-macos-desktop
flutter build macos

# iOS，仅能在 macOS 上执行
flutter build ios --release --no-codesign
```

```powershell
# Windows
flutter config --enable-windows-desktop
flutter build windows
powershell -ExecutionPolicy Bypass -File .\scripts\build_windows_msi.ps1
```

Android CI 默认使用 Google、Maven Central 和 Flutter 官方制品仓库。国内本地环境需要阿里云镜像时，可设置环境变量 `USE_ALIYUN_MAVEN=true`，或使用 Gradle 参数 `-PuseAliyunMaven=true` 显式开启。

## 设置说明

SSH Mobile 将应用设置、服务器凭据和 LLM 设置分开管理，便于独立检查各自的安全边界。

### 1. 应用设置

桌面端可从导航轨底部进入应用设置；移动端可从 Servers 页面进入。AI 页面顶部的设置按钮只打开 LLM 设置，不会与应用设置混合。

重要默认值：

| 设置项 | 默认值 | 说明 |
| --- | --- | --- |
| 语言 | 中文 | 支持中文和英文。 |
| 主题 | 浅色 | 可切换深色和 OLED 深色主题。 |
| 服务器列表 | 列表 | 只有视口宽度足够时才允许使用网格。 |
| 通知隐私 | 隐藏服务器名 | 后台通知默认不展示服务器名称。 |
| RAG | 关闭 | 默认使用 BM25，Top-N 为 3。 |
| MCP Server | 关闭 | 开启后只绑定本机回环地址。 |
| MCP 写入工具 | 关闭 | 写入操作仍必须经过应用审批。 |
| SFTP 下载上限 | 512 MB | 可配置范围为 64 KB 至 2 GB。 |
| 文本预览上限 | 2 MB | 超过上限时需要先下载。 |
| 富媒体预览上限 | 20 MB | 用于受支持图片和富预览。 |
| 文本编辑上限 | 512 KB | 防止超大远程文件耗尽移动端内存。 |

### 2. SSH 服务器配置

在 Servers 页面新增服务器，并填写：

- 显示名称；
- 主机名或 IP 地址；
- SSH 端口，通常为 `22`；
- 用户名；
- 密码或私钥认证；
- Linux 或 Windows 平台；
- 普通 SSH 或 `SSH + tmux` 启动模式；
- 可选的跳板机信息。

应用会在保存前验证 SSH 登录信息。首次连接时需要检查并确认 SSH Host Key 指纹；如果后续指纹发生变化，应用会阻止连接，而不是静默信任新指纹。

### 3. LLM 与 GPT-5.6 设置

进入 AI 页面并打开 LLM Settings，需要配置：

- 模型服务 Base URL；
- API 格式：OpenAI Chat Completions、OpenAI Responses、Anthropic Messages、Gemini Native 或 Gemini OpenAI-compatible；
- 主模型；
- 可选的辅助模型和审计模型；
- API Key；
- 上下文窗口；
- 推理参数；
- Tool Call Budget 和 Agent Loop 模式；
- 可选的 Web Search、RAG、多 Agent 协作和自定义 Prompt。

GPT-5.6 并未写死在项目中。当模型服务提供兼容的模型 ID 时，可以把 GPT-5.6 设置为主模型、辅助模型或审计模型。每次 Agent 执行都会在内存中捕获不可变的服务地址、API 格式、模型角色和凭据快照，防止已经批准的操作在执行途中被新的设置重定向。

### 4. 本地 MCP Server

桌面端可以提供：

```text
http://127.0.0.1:<port>/mcp
```

MCP Server 使用自动生成的 Bearer Token，拒绝未认证请求和非本地请求，并确保危险工具或写入工具无法绕过应用内审批界面。

## 演示运行所需的样本数据

仓库不会包含真实生产凭据或密钥。以下占位数据是完成端到端演示所需的最小数据集。

### SSH 测试配置

| 字段 | 示例 |
| --- | --- |
| 名称 | `Demo Linux Server` |
| 主机 | `<reachable-server-host>` |
| 端口 | `22` |
| 用户名 | `<test-user>` |
| 认证方式 | 密码或私钥 |
| 平台 | `Linux` |
| 启动模式 | 已安装 tmux 时选择 `SSH + tmux`，否则选择 `SSH` |

建议使用独立的非生产测试账号，并只授予演示所需的最低权限。

### SFTP 演示文件

连接测试 Linux 服务器后，可创建以下小型数据集：

```bash
mkdir -p ~/ssh-mobile-demo
printf '# SSH Mobile Demo\nThis file is safe to edit through SFTP.\n' \
  > ~/ssh-mobile-demo/readme.md
printf '{"service":"ssh-mobile-demo","status":"ok"}\n' \
  > ~/ssh-mobile-demo/status.json
printf 'alpha\nbeta\ngamma\n' \
  > ~/ssh-mobile-demo/notes.txt
```

这些文件足以演示目录浏览、Markdown 与文本预览、编辑、下载、重命名和删除确认。

### AI 模型服务样本配置

| 字段 | 示例 |
| --- | --- |
| Base URL | `<provider-base-url>` |
| API 格式 | `OpenAI Responses` 或其他支持的格式 |
| 主模型 | `gpt-5.6` 或模型服务提供的兼容模型 ID |
| 辅助模型 | 可选的低成本模型 |
| 审计模型 | 可选的审查模型 |
| API Key | 只在应用的安全设置界面中输入 |

建议使用以下只读提示词完成第一次演示：

```text
检查当前选中的服务器，总结 CPU、内存、磁盘和 SSH 服务状态；
在执行任何写入操作前必须先请求我的批准。
```

## 测试指南

### 快速本地验证

```bash
flutter pub get
dart format --output=none --set-exit-if-changed lib test tool
flutter analyze
flutter test
```

### 完整质量门禁

```bash
flutter pub get
dart run tool/generate_app_icons.dart
dart run build_runner build
dart format --output=none --set-exit-if-changed lib test tool
flutter analyze
flutter test --coverage --reporter expanded
dart run tool/check_coverage.dart --minimum=35
```

检查生成文件和 Agent Skill：

```bash
git diff --exit-code -- assets android ios macos web windows/runner/resources/app_icon.ico
git diff --exit-code -- lib/data/database/app_database.g.dart
```

```powershell
.\scripts\sync_agent_skills.ps1 -Mode Check
```

### 平台构建验证

```bash
flutter build apk --debug --no-pub
flutter build macos
flutter build ios --release --no-codesign --no-pub
```

```powershell
flutter test --reporter expanded
flutter build windows
```

### 人工集成测试清单

1. 保存测试服务器，并确认错误凭据会被拒绝。
2. 首次连接时批准 SSH Host Key，再验证指纹变化后连接会被阻止。
3. 打开多个终端窗口，并在启用 tmux 时测试断线恢复。
4. 通过 SFTP 浏览和编辑 `~/ssh-mobile-demo` 中的样本文件。
5. 启动性能监控，并检查端口、进程、服务、用户和会话。
6. 配置模型服务，创建 Plan Mode 请求，并确认写入工具必须显式审批。
7. 在审批界面打开时修改目标服务器或模型服务设置，确认旧审批不会执行。
8. 测试取消执行、网络中断、应用后台运行、语言切换、大字体和横屏键盘布局。
9. 按照 [docs/MOBILE_UI_QA.md](docs/MOBILE_UI_QA.md) 完成 1.5K 与 2K Android 专项视觉测试。

自动化测试使用 Fake、Mock 和受控 Fixture，不需要真实 SSH 凭据或 API Key。真实凭据不得提交到源代码、测试 Fixture、截图、日志、Agent Memory 或文档中。

## Codex 与 GPT-5.6 如何参与开发

Codex 和 GPT-5.6 是本项目开发流程中的重要工具，但产品范围、架构、安全边界、验收标准和最终审查仍由项目维护者负责。

### Codex 如何加速工作流程

Codex 主要用于：

- 搜索整个仓库的依赖关系和调用路径；
- 同时修改 Flutter UI、Service、测试、文档和平台配置文件；
- 在修复问题的同时生成回归测试；
- 执行结构化代码审查，定位旧状态覆盖、并发竞争和安全边界绕过问题；
- 通过 `.agents/skills/ssh-mobile-maintenance/SKILL.md` 固化维护规则；
- 使用 `AGENT_MEMORY.md` 保存非敏感的跨会话架构决策；
- 在保留修改前执行可复现的格式化、代码生成、静态分析、测试、覆盖率和构建检查。

### GPT-5.6 实现阶段：2026 年 7 月 10 日起

固定审查区间从 2026 年 7 月 10 日的 [`3ac2b73`](https://github.com/hejulian2004/ssh_mobile/commit/3ac2b7314930c6340200af1ab581e6d919d9ad5a) 开始，到 2026 年 7 月 16 日的 [`aecbf92`](https://github.com/hejulian2004/ssh_mobile/commit/aecbf924eda2e1d28c2f86e07dfbf7b4518b1742) 结束，**包含首尾共 81 个提交**。根据项目开发记录，这个固定区间内的全部提交都由 GPT-5.6 辅助实现，并由项目维护者提出需求、选择方案和完成审查。

完整对比：[`3ac2b73...aecbf92`](https://github.com/hejulian2004/ssh_mobile/compare/3ac2b7314930c6340200af1ab581e6d919d9ad5a...aecbf924eda2e1d28c2f86e07dfbf7b4518b1742)

| 工作方向 | GPT-5.6 辅助完成的主要内容 | 代表性提交 |
| --- | --- | --- |
| 设计系统与自适应 UI | 建立共用页面外壳与导航；引入 `MobileUiMetrics`；适配 1.5K 与 2K 手机；重构 Servers、Settings、AI Chat、审批、Tools、Logs、SFTP 和 System Administration，并处理键盘、安全区、大字体与 48 dp 可访问性要求。 | [`3ac2b73`](https://github.com/hejulian2004/ssh_mobile/commit/3ac2b7314930c6340200af1ab581e6d919d9ad5a)、[`e05f7ef`](https://github.com/hejulian2004/ssh_mobile/commit/e05f7ef07eb23b4702fd64cd6e36139296fb0de4)、[`33d5f63`](https://github.com/hejulian2004/ssh_mobile/commit/33d5f63e77381fe1c94b6feaf9967abb5926b4fb) |
| AI Chat 与 Agent 交互 | 重构输入框、Slash Commands、历史记录、附件、Trace Viewer、TODO 面板、执行摘要、Prompt 定制、工具选择器、目标服务器选择器和运行健康检查界面。 | [`275c1c3`](https://github.com/hejulian2004/ssh_mobile/commit/275c1c3ec751b9c6577c2211b760ad7650454bec)、[`64baeeb`](https://github.com/hejulian2004/ssh_mobile/commit/64baeeba2322b23491cacaefcc1679837f7e9eb5)、[`1c1c6cb`](https://github.com/hejulian2004/ssh_mobile/commit/1c1c6cb0b8fe35a8a1a10d1196c4595eecf6bb8e) |
| Plan Mode 与执行安全 | 实现单飞式 Plan 审批、不可变模型服务与服务器目标快照、运行前健康检查、取消与聊天修改锁、Compare-and-Swap 资源保护、过期目标拒绝和持久化 TODO/运行状态协调。 | [`f3abce3`](https://github.com/hejulian2004/ssh_mobile/commit/f3abce32ed54ebc83917e5db1dd4f0b5a2e6718c)、[`857c637`](https://github.com/hejulian2004/ssh_mobile/commit/857c637b5045d114630467c2abc6a438a2b5e49a)、[`a202779`](https://github.com/hejulian2004/ssh_mobile/commit/a202779a4aa02422a4b130652db9552b94602241) |
| SFTP 与附件安全 | 加入有界读取、加密且绑定目标的缓存、安全图片与文本预览、富预览外部导航阻断、PDF 外部打开策略、缓存刷新修复，以及编辑器、查看器、文件浏览器和服务器选择器重构。 | [`669262f`](https://github.com/hejulian2004/ssh_mobile/commit/669262f3311c13992e21e72bb4488af1212caedd)、[`d61b8b4`](https://github.com/hejulian2004/ssh_mobile/commit/d61b8b400208156eb3894a5cf65bed2a50b51bb8)、[`982b56e`](https://github.com/hejulian2004/ssh_mobile/commit/982b56e02c4edc1d4b7eb651bc18eded521f3927) |
| 终端与服务器运维 | 重构实时终端、终端历史、复制模式、窗口管理、服务器卡片、监控健康面板、服务器选择器，并修复账户与会话加载问题。 | [`1dc2702`](https://github.com/hejulian2004/ssh_mobile/commit/1dc2702050cc174d3ac74a7f548b64c2ee4314fe)、[`24b43af`](https://github.com/hejulian2004/ssh_mobile/commit/24b43af8df9918b7c598bc839ebf2a8af97dab18)、[`77bc0d3`](https://github.com/hejulian2004/ssh_mobile/commit/77bc0d376c794144cce8415b62fbf63f26ced376) |
| 架构与性能 | 推进 feature-first MVVM 迁移；抽取共用组件；缓存主题、图表和列表计算；缩小 Provider 监听范围；保留延迟加载；把远程输出解码和大型解析任务移到后台 isolate。 | [`9ffd48e`](https://github.com/hejulian2004/ssh_mobile/commit/9ffd48e2bc26fd3a3c6fc2cb83973076a7e01902)、[`3d2ceda`](https://github.com/hejulian2004/ssh_mobile/commit/3d2ceda56aba01be8f4452c492913b9f9fa11079)、[`1e587bf`](https://github.com/hejulian2004/ssh_mobile/commit/1e587bf3d521fd9007cd2636d86ad69cc26b2320)、[`833256a`](https://github.com/hejulian2004/ssh_mobile/commit/833256ab73134d474daea8aa9790678976f9c70b) |
| 测试、文档与 CI | 扩充 Widget、ViewModel、Parser、安全、Plan Mode、SFTP、终端、启动页、响应式和系统管理测试；记录移动端 QA Matrix；建立双语 README；修复 Android 制品仓库配置；统一 iOS 14 构建要求。 | [`7d17380`](https://github.com/hejulian2004/ssh_mobile/commit/7d1738078e9be026582245a9a7b496982e1872b8)、[`0e83eac`](https://github.com/hejulian2004/ssh_mobile/commit/0e83eacdf8e55251c444453603f64f2c0c0c8d02)、[`9d33194`](https://github.com/hejulian2004/ssh_mobile/commit/9d33194af6c05308b7dbadbe1accf4dd4f923e12) |

### 项目维护者作出的关键决策

影响项目最终实现的关键决策包括：

- 将 Agent 放在客户端运行，使 1 GB 服务器只需要提供 SSH/SFTP 能力；
- 采用 feature-first MVVM 和明确的 Service 边界，避免把 Agent 编排逻辑堆在 Screen 中；
- 以设备物理短边为高密度手机适配依据，同时保留系统文字缩放；
- 远程写入和敏感操作必须经过显式审批；
- 将审批绑定到不可变的服务器、模型服务、Playbook、Skill 和监控目标快照，防止异步状态变化重定向操作；
- 直接阻断破坏性 Shell 删除和敏感路径读取，而不是只依赖模型 Prompt；
- 凭据只进入平台 Secure Storage，持续增长的敏感数据在写入 Drift 前加密；
- MCP 只允许本机访问、必须认证，并复用同一套审批策略；
- AI 生成的修改必须经过自动化测试和确定性质量门禁。

### 审查与责任

GPT-5.6 和 Codex 提高了实现速度，但 AI 生成内容不会被直接视为正确结果。项目维护者负责检查行为、选择技术取舍、制定验收标准、拒绝不安全方案，并对每个合并修改承担最终责任。Gemini 也被用于对部分实现方案和文档内容进行交叉检查。

## 架构

SSH Mobile 采用 feature-first MVVM 架构，通过 Provider 和 Selector 管理状态，并将 UI 组合、协议适配、持久化存储、监控和 AI 编排拆分为可独立测试的层。

```mermaid
flowchart LR
  Views[Feature Views] --> ViewModels[Feature ViewModels]
  ViewModels --> Services[SSH / SFTP / Monitor / AI Services]
  Services --> Protocols[SSH / SFTP / HTTP / WebView Adapters]
  Services --> Storage[StorageService Facade]
  Storage --> Drift[Encrypted Drift Repositories]
  Storage --> Secure[Platform Secure Storage]
  AI[AI Orchestration] --> Services
  AI --> Safety[Approval and Secret Policies]
```

### 项目结构

- `lib/main.dart`：应用启动和依赖装配。
- `lib/features/`：各 Feature 自有的 Model、ViewModel、Service、View 和
  Feature 内部 Widget。当前 Feature 根目录包括 `connection`、`terminal`、
  `sftp`、`ai_chat`、`ai_skills`、`client_webview`、`performance`、
  `system_admin`、`lan_share`、`playbook`、`rag`、`settings`、`startup`、
  `home` 和 `developer_log`。
- `lib/services/`：跨 Feature 的 SSH/SFTP/LLM/AI Tool、监控、存储、局域网
  快传、MCP 和平台适配基础设施。
- `lib/data/`：Drift 数据库、DAO 和 Repository 实现。
- `lib/core/services/`：跨 Feature 的底层安全与协议工厂，包括 Host Key
  策略和数据保护。
- `lib/theme/`、`lib/widgets/`、`lib/utils/`：设计系统、复用组件和工具。
- `lib/models/`：仅保留小型的历史兼容共享模型；新增 Feature 模型放在所属的
  `lib/features/<feature>/models/`。
- `lib/screens/`：历史兼容目录；不要继续在此新增应用 UI。
- `test/`：单元测试和 Widget 测试。
- `docs/`：架构、安全、性能、验证和发布文档。
- `scripts/`、`tool/`：构建、生成、同步和质量检查脚本。
- `third_party/xterm/`：仓库内维护的终端组件。

`main.dart` 通过 `MultiProvider` 组合应用生命周期的服务和共享 ViewModel。
路由或页面范围的 Feature 状态保持局部：例如 AI Chat 运行时由
`AiChatRuntimeFactory` 创建并由聊天页提供，终端页创建聚焦的会话、历史和窗口
ViewModel。View 只持有布局与短生命周期展示状态；校验、异步编排和 Repository
协调由 ViewModel 与 Service 负责。

## AI Agent Runtime

AI Agent 运行在客户端，而不是被管理服务器上。SSH Mobile 负责构建模型上下文、调用已配置的模型服务、控制工具循环，并通过 SSH 和 SFTP 访问远程系统。

当前运行时包括：

- 主模型、辅助模型、审计模型和回退策略；
- SSE 流式输出、聊天持久化、消息分支和上下文压缩；
- 根据 Plan Mode、已批准计划、目标服务器和 WebView 可用性动态暴露工具；
- Tool Call Budget、独立 Agent Loop 限制和预算扩容前安全审计；
- 用于一次性任务的可审批 `todoSteps`，以及用户明确保存的可复用 Playbook；
- 由 RAG、AI Skills、有价值 Trace 和历史成功计划组成的运维记忆；
- 对网络、电池优化、通知权限和设备温度的客户端运行前检查；
- 每次操作独立的不可变运行设置与目标绑定；
- 服务健康检查、事故上下文收集和服务器状态对比等复合诊断工具。

### 工具安全边界

- 远程写入、上传、重命名、删除、敏感读取和下载必须显式审批。
- 破坏性 Shell 删除命令会被阻断。
- 环境变量整体导出、云 Metadata Endpoint 和敏感文件路径受到限制。
- `.ssh`、`.env`、私钥、Token、云凭据等内容不会进入预览缓存。
- 工具参数、结果和 Trace 会经过 `ToolSecretPolicy` 过滤或阻断。
- 危险 MCP 工具返回 `approval_required`，无法绕过应用审批界面。
- SSH 会话变更、tmux 恢复、终端历史删除、日志清空和监控状态变更仍在同一审批边界内。
- 如果模型服务、服务器、资源或服务器集合快照已变化，原审批操作会被拒绝。

## SSH 与终端会话

Servers 页面负责保存连接配置、验证认证信息和管理终端窗口。首次看到 Host Key 时，用户必须确认指纹；后续指纹发生变化时，应用会阻断连接。

Linux 服务器推荐配合 `SSH + tmux` 使用。Windows 服务器默认使用普通 SSH，除非目标实际是 WSL 或其他类 Linux Shell。固定的终端窗口名使重连和 tmux 会话恢复更可预测。

## SFTP 安全与性能

SFTP 支持目录浏览、路径历史、收藏、上传、下载、文本编辑，以及文本、Markdown、图片和沙箱 HTML 预览。

Markdown 和 HTML 预览会阻断外部资源和导航。远程 PDF 不在应用内解析，而是要求下载后使用可信阅读器打开。删除文件或目录前必须输入完整目标名称。

内存读取会在分配前执行硬上限和分块校验。大型目录构建与排序、远程输出解码和监控数据解析在后台 isolate 中运行，避免阻塞 UI。

## 服务器监控

监控工作区包含四个主要分区：

- `Performance`：手动进行多服务器采样，并保留约 10 分钟内存历史。
- `Ports`：单服务器端口快照和管理操作。
- `Applications`：应用进程快照。
- `Services`：服务状态快照和管理操作。

Linux 监控读取 `/proc`、`df -P` 等数据；Windows 监控使用 PowerShell JSON。快照模式不需要 Root，只有管理操作才会按需请求提升权限。

## 数据与存储

AI 聊天、Agent 指标、终端历史元数据、Playbook 和 SFTP 路径记录等持续增长的结构化数据存储在 Drift 中；小型偏好设置仍使用 SharedPreferences；密码、私钥、API Key 和 MCP Token 只保存在平台 Secure Storage 中。

AI 消息正文、上下文、附件、工具 Trace、TODO Steps 和 Playbook 内容等敏感 Drift 字段会在写入 SQLite 前加密。启动迁移会按可重试批次重加密历史敏感字段，并且只记录行数，不记录字段内容。

生产数据库打开失败时不会静默回退到内存数据库，避免看似写入成功的数据在应用重启后消失。

## 工程质量

### 7 月 10 日起始验证基线

GPT-5.6 实现阶段开始时，项目使用 Flutter 3.44.2 和 Dart 3.12.2 完成了本地验证：

- `flutter analyze`：无问题。
- `flutter test --coverage`：568 个测试通过。
- 非生成代码行覆盖率为 39.3%（`12690/32302`），CI 最低门槛为 35%。
- Android Debug 与未签名 Release APK 构建成功。
- Windows Release 构建成功。
- 图标生成、Drift 生成、共享 Agent Skill 同步、格式化和差异检查均可复现。

此后又增加了大量测试。要获取当前检出提交的实际结果，请执行[测试指南](#测试指南)中的命令。

原始验证范围和仍需真机完成的项目见 [docs/VALIDATION_REPORT.md](docs/VALIDATION_REPORT.md)。

## Agent 协作文件

- Codex 维护 Skill：`.agents/skills/ssh-mobile-maintenance/SKILL.md`
- Claude Code 维护 Skill：`.claude/skills/ssh-mobile-maintenance/SKILL.md`
- 跨会话非敏感项目记忆：`AGENT_MEMORY.md`

修改共享 Skill 后执行：

```powershell
.\scripts\sync_agent_skills.ps1 -Mode Check
.\scripts\sync_agent_skills.ps1 -Mode Link -Force
```

不要在 Agent Skill、项目记忆、日志、测试、截图或文档中保存密码、私钥、API Key、Token 或服务器凭据。

## 相关文档

- [移动端 UI QA Matrix](docs/MOBILE_UI_QA.md)
- [发布检查清单](docs/RELEASE_CHECKLIST.md)
- [验证报告](docs/VALIDATION_REPORT.md)
- [工程基线 ADR](docs/ADR_ENGINEERING_BASELINE.md)
- [性能验收标准](docs/PERFORMANCE_ACCEPTANCE.md)
- [安全人工回归](docs/security_manual_regression.md)
- [Android 原生重写指南](docs/ANDROID_NATIVE_REWRITE_GUIDE.md)

## 运行注意事项

- 系统后台策略、网络切换和进程回收可能中断长时间连接。
- Android Release 默认禁用 Cleartext；Debug 和 Profile 仅用于测试本地模型服务。
- macOS 凭据使用普通 Keychain 配置，以避免 Entitlement 相关错误。
- Linux 服务器建议安装 tmux，使远程会话在客户端断开后继续运行。
- iOS 构建要求 iOS 14.0 或更高版本。

## License

当前仓库尚未声明开源许可证。公开分发或接受外部贡献前，应添加明确的 `LICENSE` 文件。
