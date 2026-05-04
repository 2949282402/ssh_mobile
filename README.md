# SSH Mobile

SSH Mobile 是一个基于 Flutter 的跨平台 SSH 客户端，面向长时间终端会话、多窗口操作和移动端后台恢复场景。它支持普通 SSH、SSH + tmux、多终端窗口、快捷键、复制粘贴辅助层、开发日志、连接历史、黑白主题和中英文界面切换。

SSH Mobile is a Flutter-based cross-platform SSH client for long-running terminal sessions, multi-window workflows, and background recovery. It supports normal SSH, SSH + tmux, multiple terminal windows, shortcuts, copy/paste helpers, developer logs, connection history, light/dark themes, and Chinese/English UI switching.

> 说明：不同平台对后台网络连接有不同限制。应用会尽量通过后台服务、通知、WakeLock 和 SSH keep-alive 维持连接，但长期后台稳定性仍会受到系统后台策略、省电限制、网络切换和进程回收影响。需要长期保留工作现场时，推荐使用 SSH + tmux。

> Note: Background networking policies differ by platform. The app tries to keep sessions alive with a background service, notification, WakeLock, and SSH keep-alive, but long-running background stability still depends on system policies, power-saving rules, network changes, and process reclaiming. Use SSH + tmux when you need the working session to survive disconnects.

## 主要功能 / Features

中文：

- SSH 连接管理：保存多个服务器配置，支持密码、私钥、私钥加密码认证，也支持可选跳板机。
- 多终端窗口：同一个服务器可以并行打开多个窗口，每个窗口创建时输入唯一名称，创建后名称保持固定，便于绑定 tmux 会话。
- 默认 SSH + tmux：新连接默认使用 SSH + tmux，适合运行 `codex`、编辑器、编译任务和长时间脚本。
- tmux 恢复：应用断线、重启或网络变化后，只要服务器端 tmux 会话还存在，就可以重新连接回原会话。
- tmux 自动清理：可配置“无连接自动删除等待时间”，单位为分钟。断开后无人重新连接，服务器端 tmux 会话会在等待时间后自动删除。
- tmux 缺失处理：应用只检查服务器是否安装 tmux；如果缺失，会提示用户手动在服务器安装，不会主动下载或安装。
- 窗口管理页：集中查看所有打开的窗口，支持进入、关闭、长按多选批量关闭，并显示创建时间、预计销毁时间和本地终端缓存内存估算。
- 连接历史：关闭或断开的窗口会留下历史记录，并提供对应的服务器端 tmux 清理命令，便于手动处理异常残留会话。
- 本地历史缓存：SSH 输出会写入本地历史文件，窗口恢复时可加载最近输出，方便排查和回看。
- 开发日志页：从服务器页向右滑可打开隐藏日志页，支持日志等级筛选、折叠长日志、长按复制、复制筛选结果和清空日志。
- 终端体验：基于 `xterm` 渲染 ANSI 终端，支持 256 色、光标定位、终端尺寸同步和右侧历史滚动条。
- 字号缩放：终端支持双指缩放，也提供 `+` / `-` 按钮调节字号。
- 复制粘贴：长按终端可打开复制/粘贴菜单，并提供基于 `SelectableText` 的选择复制页。
- 快捷键与复杂输入：底部快捷键栏提供方向键、TAB、ESC、Ctrl 组合键等；复杂输入框支持粘贴或输入多行文本后一次性发送。
- 主题与语言：主页和终端页均支持黑白主题切换；界面文案支持中文和英文切换。
- 后台权限引导：在支持的平台上检测后台省电限制，引导用户放宽后台运行限制，提高长连接稳定性。

English:

- SSH connection management: Save multiple server profiles with password, private key, private key plus password authentication, and optional jump-host settings.
- Multiple terminal windows: Open multiple windows for the same server. Each window gets a unique name at creation time and keeps it fixed for tmux binding.
- SSH + tmux by default: New connections default to SSH + tmux, which is useful for `codex`, editors, build tasks, and long-running scripts.
- tmux recovery: After disconnects, app restarts, or network changes, the app can reconnect to the original tmux session as long as it still exists on the server.
- tmux auto cleanup: Configure a no-client auto-delete delay in minutes. If nobody reconnects after disconnecting, the server-side tmux session is deleted after the delay.
- tmux missing handling: The app only checks whether tmux is installed. If tmux is missing, it asks the user to install it manually on the server. It does not download or install tmux automatically.
- Window manager: View all open windows, enter or close a window, long press for multi-select batch close, and see creation time, expected cleanup time, and estimated local terminal-cache memory.
- Connection history: Closed or disconnected windows leave history records with server-side tmux cleanup commands for manual abnormal-session cleanup.
- Local history cache: SSH output is written to local history files, and recent output can be loaded when a window is restored.
- Developer logs: Swipe right from the server page to open the hidden log page. It supports level filters, long-log folding, long-press copy, copying filtered results, and clearing logs.
- Terminal experience: ANSI terminal rendering is powered by `xterm`, with 256 colors, cursor positioning, terminal size sync, and a right-side history scrollbar.
- Font scaling: Pinch to zoom the terminal font or use the `+` / `-` controls.
- Copy and paste: Long press the terminal to open copy/paste actions, with a `SelectableText` copy page for selectable text.
- Shortcuts and advanced input: The bottom shortcut bar includes arrows, TAB, ESC, Ctrl combinations, and more. The advanced input box supports multiline paste/type and batch send.
- Theme and language: Both home and terminal pages support light/dark theme switching; UI strings support Chinese and English.
- Background permission guide: On supported platforms, the app checks power restrictions and guides users to relax background limits for better long-running stability.

## 技术栈 / Tech Stack

| 模块 / Module | 依赖 / Package | 说明 / Description |
| --- | --- | --- |
| Flutter UI | `flutter` / `provider` | 页面、状态管理、主题与语言状态 / Screens, state management, themes, and language state |
| SSH 协议 / SSH protocol | `dartssh2` | 纯 Dart SSH 客户端实现 / Pure Dart SSH client implementation |
| 终端渲染 / Terminal rendering | `xterm` | ANSI 终端模拟和输入输出处理 / ANSI terminal emulation and I/O handling |
| 后台服务 / Background service | `flutter_background_service` | 后台 SSH 会话维护 / Background SSH session maintenance |
| 通知 / Notifications | `flutter_local_notifications` | 前台服务通知 / Foreground-service notifications |
| 安全存储 / Secure storage | `flutter_secure_storage` | 密码和私钥等敏感信息存储 / Storage for passwords, private keys, and sensitive data |
| 本地配置 / Local settings | `shared_preferences` | 主题、语言、快捷命令等轻量配置 / Lightweight settings such as theme, language, and shortcuts |
| 权限 / Permissions | `permission_handler` | 通知、电池优化等权限处理 / Permission handling for notifications, battery optimization, and related flows |
| 本地历史 / Local history | `path_provider` / local files | 终端输出历史缓存 / Terminal output history cache |
| 服务器会话保持 / Server persistence | `tmux` | 可选但推荐的服务器依赖，用于断线恢复和应用重启后重连 / Optional but recommended server dependency for reconnects and app-restart recovery |

## 项目结构 / Project Structure

中文：

```text
ssh_mobile/
├── android/                         # Android 工程与权限配置
├── ios/                             # iOS 工程
├── lib/
│   ├── main.dart                    # 应用入口、Provider、路由
│   ├── models/
│   │   └── connection.dart          # SSH 连接配置模型
│   ├── screens/
│   │   ├── terminal/                # 终端页拆分组件
│   │   ├── startup_screen.dart      # 启动页与后台权限引导
│   │   ├── home_screen.dart         # 服务器页、窗口页、隐藏日志页
│   │   ├── add_edit_screen.dart     # 新增/编辑连接配置
│   │   ├── developer_log_screen.dart
│   │   ├── terminal_history_screen.dart
│   │   ├── terminal_windows_screen.dart
│   │   └── terminal_screen.dart     # 终端窗口状态与生命周期
│   ├── services/
│   │   ├── app_log_service.dart
│   │   ├── app_settings.dart        # 语言、主题和界面文案
│   │   ├── background_service.dart  # 后台服务中的 SSH 会话维护
│   │   ├── ssh_service.dart         # 多 SSH 会话状态管理
│   │   ├── storage_service.dart     # 连接配置、凭据、历史记录
│   │   └── terminal_history_service*.dart
│   └── theme/
│       └── app_theme.dart
├── pubspec.yaml
└── README.md
```

English:

```text
ssh_mobile/
├── android/                         # Android project and permission configuration
├── ios/                             # iOS project
├── lib/
│   ├── main.dart                    # App entry, providers, and routes
│   ├── models/
│   │   └── connection.dart          # SSH connection model
│   ├── screens/
│   │   ├── terminal/                # Split terminal screen components
│   │   ├── startup_screen.dart      # Startup and background-permission guide
│   │   ├── home_screen.dart         # Server page, window page, hidden log page
│   │   ├── add_edit_screen.dart     # Add/edit connection form
│   │   ├── developer_log_screen.dart
│   │   ├── terminal_history_screen.dart
│   │   ├── terminal_windows_screen.dart
│   │   └── terminal_screen.dart     # Terminal window state and lifecycle
│   ├── services/
│   │   ├── app_log_service.dart
│   │   ├── app_settings.dart        # Language, theme, and UI strings
│   │   ├── background_service.dart  # SSH session maintenance in the background service
│   │   ├── ssh_service.dart         # Multi-session SSH state management
│   │   ├── storage_service.dart     # Profiles, credentials, and history records
│   │   └── terminal_history_service*.dart
│   └── theme/
│       └── app_theme.dart
├── pubspec.yaml
└── README.md
```

## 开发环境 / Development Environment

中文：

本项目不提交 Flutter SDK，也不依赖仓库内的 `.tools` 目录。请先在本机安装 Flutter，并确保命令可用：

```powershell
flutter --version
dart --version
```

如果你希望在项目目录下放一个本地 SDK，例如 `.tools/flutter`，可以自行配置，但 `.tools/` 属于本地环境目录，不应提交到 Git，也不应写死在构建脚本里。README 中的命令默认使用系统 PATH 中的 `flutter`。

English:

This project does not commit the Flutter SDK and does not depend on a repository-tracked `.tools` directory. Install Flutter locally first and make sure the commands are available:

```powershell
flutter --version
dart --version
```

If you prefer a local SDK under the project directory, for example `.tools/flutter`, configure it yourself. The `.tools/` directory is local environment data, should not be committed to Git, and should not be hardcoded in build scripts. Commands in this README assume `flutter` is available from PATH.

推荐环境 / Recommended environment:

- Flutter 3.x
- Dart SDK `>=3.2.0 <4.0.0`
- 对应目标平台的 Flutter 工具链 / Flutter toolchain for your target platform
- 至少一个可运行的 Flutter 目标设备或模拟器 / At least one runnable Flutter target device or emulator

## 安装依赖 / Install Dependencies

中文：

```powershell
flutter pub get
```

English:

```powershell
flutter pub get
```

## 运行项目 / Run the App

中文：

1. 准备一个 Flutter 支持的目标设备、模拟器或桌面运行环境。
2. 确认目标设备已连接并允许调试或开发运行。
3. 查看设备：

```powershell
flutter devices
```

4. 运行到指定设备：

```powershell
flutter run -d <device-id>
```

English:

1. Prepare a Flutter-supported target device, emulator, or desktop runtime.
2. Make sure the target is connected and allows debug/development runs.
3. List available devices:

```powershell
flutter devices
```

4. Run the app on a specific device:

```powershell
flutter run -d <device-id>
```

## 构建 APK / Build APK

中文：

```powershell
flutter build apk --debug
flutter build apk --release
```

构建产物通常位于：

```text
build/app/outputs/flutter-apk/
```

English:

```powershell
flutter build apk --debug
flutter build apk --release
```

Build artifacts are usually generated under:

```text
build/app/outputs/flutter-apk/
```

## 常用开发命令 / Common Development Commands

中文：

```powershell
dart format lib test
flutter analyze
flutter test
flutter clean
flutter pub get
```

English:

```powershell
dart format lib test
flutter analyze
flutter test
flutter clean
flutter pub get
```

## 使用说明 / Usage

### 添加 SSH 连接 / Add an SSH Connection

中文：

在主页点击新增连接，填写名称、主机地址、端口、用户名、认证方式、启动模式和可选跳板机信息。端口默认是 `22`。新建配置默认使用 SSH + tmux，可按需切换为普通 SSH。

English:

Tap add connection on the home page, then fill in the name, host, port, username, authentication method, launch mode, and optional jump-host information. The default port is `22`. New profiles default to SSH + tmux, but you can switch to normal SSH if needed.

### 多窗口 / Multiple Windows

中文：

进入终端后，点击标题旁边的 `+` 可以基于当前服务器创建新窗口。创建时需要输入窗口名称，默认名称基于服务器域名或 IP 加序号生成，且必须唯一。窗口名称创建后保持固定，用于稳定绑定 tmux 会话。

English:

Inside a terminal, tap the `+` next to the title to create a new window for the current server. A window name is required at creation time. The default name is based on the server host/IP plus an index and must be unique. The name stays fixed after creation so it can bind tmux sessions reliably.

### 窗口管理页 / Window Manager

中文：

窗口页会显示所有打开的终端窗口。每张卡片包含窗口名、连接名、连接状态、创建时间、tmux 预计销毁时间和本地终端缓存内存估算。可以点击进入窗口，点击关闭按钮关闭窗口，也可以长按进入多选模式批量关闭。

English:

The window page lists all open terminal windows. Each card shows the window name, connection name, state, creation time, expected tmux cleanup time, and estimated local terminal-cache memory. You can enter a window, close it, or long press to enter multi-select mode and batch close windows.

### SSH + tmux 模式 / SSH + tmux Mode

中文：

SSH + tmux 会先正常 SSH 登录服务器，然后检查 `tmux` 是否存在。如果存在，应用会创建或 attach 到与当前窗口名对应的 tmux 会话。如果缺失，应用会提示用户先手动安装 tmux，然后再重试。

English:

SSH + tmux logs in over SSH first, then checks whether `tmux` exists. If available, the app creates or attaches to the tmux session matching the current window name. If missing, the app asks the user to install tmux manually and retry.

### tmux 自动删除 / tmux Auto Delete

中文：

“无连接自动删除等待时间”不是后台多久后主动断开的时间，而是断开后服务器端 tmux 会话保留多久的时间。比如设置为 10 分钟，表示断线后 10 分钟内重新连接可以回到原会话；超过 10 分钟无人连接，tmux 会话会被服务器端自动清理。

English:

The no-client auto-delete delay is not a timer for disconnecting in the background. It is the retention time for the server-side tmux session after disconnect. For example, 10 minutes means you can reconnect to the same session within 10 minutes; if nobody reconnects after that, the tmux session is cleaned up on the server.

### 连接历史 / Connection History

中文：

窗口关闭或断开后会保留历史记录。历史页会显示窗口名称、连接信息、状态、更新时间和可复制的 tmux 清理命令。关闭窗口后如果服务器上仍有异常残留 tmux 会话，可以复制该命令并手动执行。

English:

Closed or disconnected windows leave history records. The history page shows the window name, connection info, state, update time, and a copyable tmux cleanup command. If an abnormal tmux session remains on the server, copy and run the command manually.

### 开发日志 / Developer Logs

中文：

在服务器页从左向右滑动可以打开隐藏的开发日志页。日志页按时间倒序显示，支持按等级筛选、折叠长日志、长按复制单条日志、复制当前筛选结果和清空日志。

English:

Swipe right from the server page to open the hidden developer log page. Logs are shown in reverse chronological order and support level filtering, long-log folding, long-press copy, copying filtered results, and clearing logs.

### 复制与粘贴 / Copy and Paste

中文：

长按终端区域可打开复制/粘贴菜单。选择复制层后，会进入可选择文本的复制页，并自动滚动到底部，方便从最新输出开始选择。多行输入建议使用底部复杂输入框，确认无误后点击发送。

English:

Long press the terminal area to open copy/paste actions. The copy layer opens a selectable-text page and automatically scrolls to the bottom so you can start from the latest output. For multiline input, use the advanced input box at the bottom and send after reviewing.

## 后台权限 / Background Permissions

中文：

应用在支持的平台上可能会用到以下后台相关权限：

- `INTERNET`：建立 SSH 网络连接。
- `ACCESS_NETWORK_STATE` / `ACCESS_WIFI_STATE`：感知网络状态。
- `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_DATA_SYNC`：运行前台服务维护 SSH。
- `POST_NOTIFICATIONS`：显示后台保活通知，部分系统需要用户授权。
- `WAKE_LOCK`：尽量避免后台任务被过早挂起。
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`：引导用户放宽电池优化。

English:

The app may use these background-related permissions on supported platforms:

- `INTERNET`: Establish SSH network connections.
- `ACCESS_NETWORK_STATE` / `ACCESS_WIFI_STATE`: Observe network state.
- `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_DATA_SYNC`: Run a foreground service to maintain SSH.
- `POST_NOTIFICATIONS`: Show background keep-alive notifications. Some systems require user approval.
- `WAKE_LOCK`: Reduce the chance of background work being suspended too early.
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`: Guide users to relax battery optimization.

## 已知限制 / Known Limitations

中文：

- 系统后台策略可能导致长时间后台后断连，需要用户手动放宽后台限制。
- Wi-Fi、移动数据、VPN 之间切换时，底层 TCP 连接通常会失效。应用可以检测断连并重连，但无法保证原 SSH TCP 连接无缝迁移。
- SSH + tmux 可以保留服务器端会话并支持应用重启后重连，但前提是服务器上的 tmux 会话还没有被自动删除。
- 应用重启恢复 tmux 窗口时，主要恢复服务器端当前画面；完整历史取决于 tmux scrollback 和本地历史缓存。
- 当前内存占用显示的是每个窗口本地终端输出缓存的估算值，不是系统级进程内存。
- 终端复制使用 Flutter 文本选择辅助层，不依赖平台原生终端 TextView。

English:

- System background policies may disconnect sessions after a long time in the background. Users may need to relax background restrictions manually.
- When switching between Wi-Fi, mobile data, and VPN, the underlying TCP connection usually becomes invalid. The app can detect and reconnect, but cannot guarantee seamless migration of the original SSH TCP connection.
- SSH + tmux can preserve the server-side session and reconnect after app restarts, but only while the tmux session still exists and has not been auto-deleted.
- App-restart tmux recovery mainly restores the current server-side tmux screen. Full history depends on tmux scrollback and the local history cache.
- The memory usage shown per window is an estimate of local terminal output cache, not system-level process memory.
- Terminal copying is implemented with a Flutter text-selection helper layer, not a platform-native terminal TextView.

## 故障排查 / Troubleshooting

### 设备找不到 / Device Not Found

中文：

```powershell
flutter devices
```

如果目标设备没有出现，请检查设备是否已连接、是否允许调试或开发运行、连接是否稳定，以及目标平台工具链是否可用。

English:

```powershell
flutter devices
```

If the target device does not appear, check whether it is connected, whether it allows debug/development runs, whether the connection is stable, and whether the target platform toolchain is available.

### 后台很快断连 / Background Disconnects Quickly

中文：

确认通知权限已允许，应用后台耗电设置为无限制，没有系统管理策略清理后台。也需要确认服务器端 `ClientAliveInterval`、`ClientAliveCountMax` 等 SSH 配置没有主动断开连接，并检查网络是否在后台切换、休眠或断开。需要强恢复能力时，请使用 SSH + tmux。

English:

Make sure notification permission is allowed, battery usage is unrestricted, and no system policy is cleaning background apps. Also check server-side SSH settings such as `ClientAliveInterval` and `ClientAliveCountMax`, and whether the network switches, sleeps, or disconnects in the background. Use SSH + tmux when strong recovery is required.

### tmux 未安装 / tmux Is Missing

中文：

如果 SSH + tmux 提示服务器没有安装 tmux，请手动登录服务器安装后再回到应用重试。常见命令如下：

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

English:

If SSH + tmux reports that tmux is missing, log in to the server manually, install tmux, and retry in the app. Common commands:

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

## 许可 / License

中文：

当前仓库未声明开源许可证。如需公开发布，请先补充明确的 `LICENSE` 文件。

English:

This repository does not currently declare an open-source license. Add a clear `LICENSE` file before public release.
