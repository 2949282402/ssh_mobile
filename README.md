# SSH Mobile

SSH Mobile 是一个基于 Flutter 的跨平台 SSH 客户端，重点面向长时间 SSH 会话使用场景。它支持多窗口连接、后台服务保活、终端快捷键、复制粘贴辅助层、暗色/亮色主题和中英文界面切换。

SSH Mobile is a Flutter-based cross-platform SSH client designed for long-running SSH sessions. It supports multiple terminal windows, background keep-alive, terminal shortcuts, copy/paste helpers, light/dark themes, and Chinese/English UI switching.

> 说明：不同系统对后台网络连接有不同限制。应用会尽量通过后台服务、通知、WakeLock、SSH keep-alive 等方式保持连接，但长期后台不断开仍会受到系统后台策略、省电限制、网络切换和内存回收影响。首次使用建议按照应用引导放宽后台运行限制。

> Note: Operating systems place different limits on background networking. The app tries to keep sessions alive with a background service, notification, WakeLock, and SSH keep-alive, but long-running background stability still depends on system background policies, power-saving restrictions, network switching, and process reclaiming. On first launch, relax background-running restrictions when prompted.

## 主要功能 / Features

中文：

- SSH 连接管理：保存多个服务器配置，支持密码、私钥、私钥加密码三种认证方式。
- 多终端窗口：同一个服务器可以并行打开多个 SSH 窗口，每个窗口可自定义名称。
- 后台保活：应用通过后台服务和 SSH keep-alive 尽量维持 SSH 会话，减少切到后台后的断连。
- SSH + tmux 模式：可选择普通 SSH 或 SSH + tmux。tmux 模式会在服务器上绑定当前窗口名的会话，断线或 App 重启后可重新 attach 回原会话。
- tmux 自动清理：支持配置“无连接自动删除等待时间”，单位为分钟。无人重新连接超过该时间后，服务器端 tmux 会话会自动删除。
- tmux 安装引导：如果服务器未安装 tmux，应用会先征求用户同意再尝试安装；自动安装失败时会提示用户手动登录服务器安装 tmux 后再重试。
- 断连处理：断开后终端窗口不会自动刷新清空，保留用户查看输出的时间，并提供手动重连按钮。
- 终端体验：基于 `xterm` 渲染 ANSI 终端，支持 256 色、光标定位、终端尺寸同步。
- 字号缩放：终端支持双指缩放，也提供 `+` / `-` 按钮调节字号。
- 复制粘贴：长按终端可打开复制/粘贴菜单，并提供基于 `SelectableText` 的可选中文本复制层。
- 快捷键栏：内置 TAB、ESC、Enter、Backspace、方向键、Home/End、PageUp/PageDown、Ctrl 组合键等快捷输入。
- 自定义快捷命令：可添加常用命令，快捷命令会根据使用频率自动靠前。
- 复杂输入框：支持粘贴或手动输入多行文本，点击发送后一次性写入终端，输入框内回车只换行。
- 主题与语言：主页支持中英文切换和黑白主题切换，终端页组件会跟随主题变化。
- 安全存储：敏感凭据通过 `flutter_secure_storage` 存储到系统安全区域。

English:

- SSH connection management: Save multiple server profiles with password, private key, or private key plus password authentication.
- Multiple terminal windows: Open several SSH windows for the same server in parallel, with custom names per window.
- Background keep-alive: The app uses a background service and SSH keep-alive to reduce disconnects after it goes to the background.
- SSH + tmux mode: Choose normal SSH or SSH + tmux. In tmux mode, the app attaches to a server-side tmux session bound to the current window name, so it can reconnect after disconnects or app restarts.
- tmux auto cleanup: Configure the no-client auto-delete delay in minutes. If no client reconnects before the delay expires, the server-side tmux session is removed automatically.
- tmux install guidance: If tmux is missing on the server, the app asks for user approval before trying to install it. If automatic installation fails, the user is told to install tmux manually on the server and retry.
- Disconnect handling: Disconnected terminal windows stay open, preserving output and offering a manual reconnect button.
- Terminal experience: ANSI terminal rendering is powered by `xterm`, including 256 colors, cursor positioning, and terminal size sync.
- Font scaling: Pinch to zoom the terminal font or use the `+` / `-` controls.
- Copy and paste: Long press the terminal to open copy/paste actions, with a `SelectableText` copy layer for range selection.
- Shortcut bar: Built-in shortcuts include TAB, ESC, Enter, Backspace, arrow keys, Home/End, PageUp/PageDown, and Ctrl combinations.
- Custom shortcuts: Add frequent commands, which are automatically reordered by usage frequency.
- Advanced input box: Paste or type multiline text, then send it as one batch. Enter inside the box inserts a newline.
- Theme and language: The home page supports Chinese/English switching and light/dark theme switching. Terminal UI components follow the selected theme.
- Secure storage: Sensitive credentials are stored with `flutter_secure_storage`.

## 技术栈 / Tech Stack

| 模块 / Module | 依赖 / Package | 说明 / Description |
| --- | --- | --- |
| Flutter UI | `flutter` / `provider` | 页面、状态管理、主题与本地化状态 / Screens, state management, themes, and localization state |
| SSH 协议 / SSH protocol | `dartssh2` | 纯 Dart SSH 客户端实现 / Pure Dart SSH client implementation |
| 终端渲染 / Terminal rendering | `xterm` | ANSI 终端模拟与输入输出处理 / ANSI terminal emulation and I/O handling |
| 后台服务 / Background service | `flutter_background_service` | 后台 SSH 会话保活 / Background SSH session keep-alive |
| 通知 / Notifications | `flutter_local_notifications` | 前台服务常驻通知 / Persistent foreground-service notification |
| 安全存储 / Secure storage | `flutter_secure_storage` | 密码和私钥等敏感信息存储 / Storage for passwords, private keys, and other sensitive data |
| 本地配置 / Local settings | `shared_preferences` | 主题、语言、快捷命令等轻量配置 / Lightweight settings such as theme, language, and shortcuts |
| 权限 / Permissions | `permission_handler` | 通知、电池优化等权限处理 / Permission handling for notifications, battery optimization, and related flows |
| 服务器会话保持 / Server session persistence | `tmux` | 可选依赖。用于服务器端会话保持、断线恢复和 App 重启后重连 / Optional server-side dependency for session persistence, reconnects, and app-restart recovery |

## 项目结构 / Project Structure

中文：

```text
ssh_mobile/
├── android/                         # Android 工程与权限配置
│   └── app/src/main/AndroidManifest.xml
├── ios/                             # iOS 工程
├── lib/
│   ├── main.dart                    # 应用入口、Provider、路由
│   ├── models/
│   │   └── connection.dart          # SSH 连接配置模型
│   ├── screens/
│   │   ├── terminal/                # 终端页拆分组件
│   │   ├── startup_screen.dart      # 启动页与初始化
│   │   ├── home_screen.dart         # 连接列表、语言/主题切换
│   │   ├── add_edit_screen.dart     # 新增/编辑连接配置
│   │   └── terminal_screen.dart     # 终端窗口状态与生命周期
│   ├── services/
│   │   ├── app_settings.dart        # 语言、主题和界面文案
│   │   ├── background_service.dart  # 后台服务中的 SSH 会话维护
│   │   ├── shortcut_command_service.dart
│   │   ├── ssh_service.dart         # 多 SSH 会话状态管理
│   │   └── storage_service.dart     # 连接配置与凭据存储
│   └── theme/
│       └── app_theme.dart           # 亮色/暗色主题
├── pubspec.yaml                     # Flutter 依赖声明
└── README.md
```

English:

```text
ssh_mobile/
├── android/                         # Android project and permission configuration
│   └── app/src/main/AndroidManifest.xml
├── ios/                             # iOS project
├── lib/
│   ├── main.dart                    # App entry, providers, and routes
│   ├── models/
│   │   └── connection.dart          # SSH connection model
│   ├── screens/
│   │   ├── terminal/                # Split terminal screen components
│   │   ├── startup_screen.dart      # Startup and initialization screen
│   │   ├── home_screen.dart         # Connection list, language/theme switches
│   │   ├── add_edit_screen.dart     # Add/edit connection form
│   │   └── terminal_screen.dart     # Terminal window state and lifecycle
│   ├── services/
│   │   ├── app_settings.dart        # Language, theme, and UI strings
│   │   ├── background_service.dart  # SSH session maintenance inside the background service
│   │   ├── shortcut_command_service.dart
│   │   ├── ssh_service.dart         # Multi-session SSH state management
│   │   └── storage_service.dart     # Connection profiles and credential storage
│   └── theme/
│       └── app_theme.dart           # Light/dark themes
├── pubspec.yaml                     # Flutter dependency manifest
└── README.md
```

## 后台权限 / Background Permissions

中文：

应用在支持的平台上可能会用到以下后台相关权限：

- `INTERNET`：建立 SSH 网络连接。
- `ACCESS_NETWORK_STATE` / `ACCESS_WIFI_STATE`：感知网络状态。
- `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_DATA_SYNC`：运行前台服务保活 SSH。
- `POST_NOTIFICATIONS`：显示后台保活通知，部分系统需要用户授权。
- `WAKE_LOCK`：尽量避免后台任务被过早挂起。
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`：引导用户关闭电池优化，提升后台长连接稳定性。

如果希望 SSH 在切到后台后尽量不断开，请在系统设置中允许后台运行、通知权限和后台联网，并放宽可能中断后台网络的省电限制。不同系统的设置名称会有差异。

English:

The app may use these background-related permissions on supported platforms:

- `INTERNET`: Establish SSH network connections.
- `ACCESS_NETWORK_STATE` / `ACCESS_WIFI_STATE`: Observe network state.
- `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_DATA_SYNC`: Run a foreground service to keep SSH sessions alive.
- `POST_NOTIFICATIONS`: Show the background keep-alive notification. Some systems require user approval.
- `WAKE_LOCK`: Reduce the chance of background work being suspended too early.
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`: Guide users to disable battery optimization for better long-running stability.

For better background stability, allow background running, notifications, and background networking in system settings, and relax power-saving restrictions that may interrupt background networking. The exact setting names vary by system.

## 开发环境 / Development Environment

中文：

本项目不提交 Flutter SDK。请先在本机安装 Flutter，并确保 `flutter` 和 `dart` 命令可用：

```powershell
flutter --version
dart --version
```

如果你想在项目目录下放一个本地 SDK，例如 `.tools/flutter`，可以自己配置，但该目录属于本地环境文件，不应提交到 Git。

English:

This project does not commit the Flutter SDK. Install Flutter on your machine first, and make sure the `flutter` and `dart` commands are available:

```powershell
flutter --version
dart --version
```

If you prefer to keep a local SDK under the project directory, for example `.tools/flutter`, you can configure it yourself. That directory is local environment data and should not be committed to Git.

推荐环境 / Recommended environment:

- Flutter 3.x
- Dart SDK `>=3.2.0 <4.0.0`
- Flutter 支持的目标平台工具链 / Toolchain for your Flutter target platform
- 至少一个可运行的 Flutter 目标设备或模拟器 / At least one runnable Flutter target device or emulator

## 获取依赖 / Install Dependencies

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

示例：

```powershell
flutter run -d V2309A
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

Example:

```powershell
flutter run -d V2309A
```

## 构建 APK / Build APK

中文：

Debug APK：

```powershell
flutter build apk --debug
```

Release APK：

```powershell
flutter build apk --release
```

构建产物通常位于：

```text
build/app/outputs/flutter-apk/
```

English:

Debug APK:

```powershell
flutter build apk --debug
```

Release APK:

```powershell
flutter build apk --release
```

Build artifacts are usually generated under:

```text
build/app/outputs/flutter-apk/
```

## 常用开发命令 / Common Development Commands

中文：

```powershell
# 格式化代码
dart format lib test

# 静态检查
flutter analyze

# 运行测试
flutter test

# 清理构建缓存
flutter clean

# 重新获取依赖
flutter pub get
```

English:

```powershell
# Format code
dart format lib test

# Static analysis
flutter analyze

# Run tests
flutter test

# Clean build cache
flutter clean

# Reinstall dependencies
flutter pub get
```

## 使用说明 / Usage

### 添加 SSH 连接 / Add an SSH Connection

中文：

在主页点击新增连接，填写名称、主机地址、端口、用户名、认证方式和可选跳板机信息。端口默认是 `22`。保存后即可从主页发起连接。

English:

Tap add connection on the home page, then fill in the name, host, port, username, authentication method, and optional jump-host information. The default port is `22`. After saving, start the connection from the home page.

### 多窗口 / Multiple Windows

中文：

进入终端后，点击标题旁边的 `+` 可以基于当前服务器创建新的终端窗口。点击窗口切换按钮可以查看全部窗口，点击列表项切换窗口，点击列表项右侧的关闭按钮可关闭对应窗口。点击编辑按钮可以修改当前窗口名称。

English:

Inside the terminal, tap the `+` next to the title to create another terminal window for the current server. Use the window switcher to view all windows, tap a list item to switch, or tap the close button on the right side of a list item to close that window. Use the edit button to rename the current window.

### 后台保活 / Background Keep-Alive

中文：

连接 SSH 后，应用会启动后台保活服务并显示必要通知。应用进入后台时，服务会继续维护 SSH 会话并发送 keep-alive。为了提高稳定性，请保持通知开启，允许应用后台运行，并尽量保持网络稳定。

如果系统强制回收应用进程，SSH 连接仍可能断开。这是移动系统限制，不是 SSH 协议本身可以完全绕过的问题。

English:

After SSH connects, the app starts a background keep-alive service and shows any required notification. When the app goes to the background, the service continues maintaining SSH sessions and sending keep-alive packets. For better stability, keep notifications enabled, allow background running, and keep the network stable.

If the system forcibly kills the app process, the SSH connection may still drop. This is a mobile OS limitation, not something the SSH protocol can fully bypass.

### SSH + tmux 模式 / SSH + tmux Mode

中文：

在连接配置中可以选择普通 SSH 或 SSH + tmux。普通 SSH 会直接打开交互式 shell；SSH + tmux 会先登录服务器，然后 attach 到与当前终端窗口绑定的 tmux 会话。

tmux 模式适合运行 `codex`、编辑器、编译任务、长时间脚本等需要断线后继续保留状态的场景。应用切到后台、网络切换、系统回收进程或 App 重启后，原始 TCP/SSH 连接可能已经断开，但只要服务器端 tmux 会话还在，重新打开 App 后可以重新连接并回到同一个 tmux 会话。

English:

Connection profiles can use normal SSH or SSH + tmux. Normal SSH opens an interactive shell directly. SSH + tmux logs in first and then attaches to a tmux session bound to the current terminal window.

tmux mode is useful for `codex`, editors, build tasks, long-running scripts, and other workflows that should survive disconnects. When the app goes to the background, the network changes, the system reclaims the process, or the app restarts, the original TCP/SSH connection may be gone. As long as the server-side tmux session still exists, reopening the app can reconnect and return to the same tmux session.

### tmux 自动删除 / tmux Auto Delete

中文：

SSH + tmux 模式支持“无连接自动删除等待时间”，单位为分钟。客户端断开后，如果没有任何客户端在等待时间内重新连接，服务器上的 tmux 会话会自动删除。

这个时间不是“后台多久后主动断开”的时间，而是“断开后服务器端会话保留多久”的时间。比如设置为 10 分钟，表示断线后 10 分钟内重新连接可以回到原会话；超过 10 分钟无人连接，tmux 会话会被清理。

English:

SSH + tmux mode supports a no-client auto-delete delay, configured in minutes. After the client disconnects, if no client reconnects before the delay expires, the server-side tmux session is deleted automatically.

This is not a "disconnect after N minutes in the background" timer. It is a server-side retention timer after disconnect. For example, a 10-minute value means you can reconnect to the same session within 10 minutes; if nobody reconnects after 10 minutes, the tmux session is cleaned up.

### tmux 安装 / tmux Installation

中文：

如果选择 SSH + tmux，但服务器没有安装 tmux，应用会先提示用户确认。用户同意后，应用会尝试通过服务器上的 `apt-get`、`dnf`、`yum`、`pacman`、`zypper`、`apk` 或 `pkg` 安装 tmux。

自动安装可能因为没有 root 权限、没有免密 `sudo`、包管理器不可用、软件源不可达或下载失败而失败。失败时应用会提示用户手动登录服务器安装 tmux 后再重试。

English:

If SSH + tmux is selected but tmux is missing on the server, the app asks for confirmation first. After approval, it tries to install tmux using `apt-get`, `dnf`, `yum`, `pacman`, `zypper`, `apk`, or `pkg` on the server.

Automatic installation can fail if the user lacks root privileges, passwordless `sudo` is unavailable, no supported package manager exists, package repositories are unreachable, or downloads fail. In that case, the app tells the user to install tmux manually on the server and retry.

### 复制与粘贴 / Copy and Paste

中文：

长按终端区域可打开菜单。选择复制层后，可以拖动选择文本并复制。粘贴会把剪贴板内容发送到当前 SSH 会话。多行文本建议使用底部复杂输入框，确认无误后点击发送。

English:

Long press the terminal area to open the menu. Choose the copy layer to select and copy text. Paste sends clipboard content to the current SSH session. For multiline text, use the advanced input box at the bottom and send it after reviewing the content.

### 快捷键与命令 / Shortcuts and Commands

中文：

底部快捷键栏提供常用按键：`TAB`、`ESC`、`ENTER`、`BKSP`、`↑`、`↓`、`←`、`→`、`HOME`、`END`、`PGUP`、`PGDN`、`CTRL+C`、`CTRL+D`、`CTRL+L`。也可以添加自定义快捷命令，自定义命令会按使用频率排序，常用命令会自动靠前。

English:

The bottom shortcut bar includes common keys: `TAB`, `ESC`, `ENTER`, `BKSP`, `↑`, `↓`, `←`, `→`, `HOME`, `END`, `PGUP`, `PGDN`, `CTRL+C`, `CTRL+D`, and `CTRL+L`. You can also add custom shortcut commands. Custom commands are sorted by usage frequency so frequently used commands move forward.

## 已知限制 / Known Limitations

中文：

- 系统后台策略可能导致长时间后台后断连，需要用户手动放开后台限制。
- 网络从 Wi-Fi、数据、VPN 之间切换时，底层 TCP 连接通常会失效，应用只能检测断连并提示或重连，无法保证原 SSH 会话无缝迁移。
- SSH + tmux 可以保留服务器端会话并支持 App 重启后重连，但前提是服务器上的 tmux 会话尚未被自动删除。
- App 重启恢复 tmux 窗口时不会恢复本地终端缓冲区的全部显示内容，进入后会回到 tmux 当前画面，历史输出取决于 tmux 自身 scrollback。
- 自动安装 tmux 需要服务器支持常见包管理器，并且当前用户拥有 root 或免密 sudo 权限；否则需要用户手动安装。
- 不同系统对后台长连接的支持程度不同，应用会尽量保活，但无法绕过系统级限制。
- 终端复制使用 Flutter 文本选择层辅助实现，不依赖平台原生终端文本控件。

English:

- System background policies may disconnect sessions after a long time in the background. Users need to relax background restrictions manually.
- When the network switches between Wi-Fi, mobile data, and VPN, the underlying TCP connection usually becomes invalid. The app can detect the disconnect and prompt or reconnect, but it cannot guarantee seamless migration of the original SSH session.
- SSH + tmux can preserve the server-side session and reconnect after app restarts, but only while the server-side tmux session still exists and has not been auto-deleted.
- App-restart recovery does not restore the full local terminal buffer. It returns to the current tmux screen, while history depends on tmux scrollback.
- Automatic tmux installation requires a supported server package manager and root or passwordless sudo privileges. Otherwise, users need to install tmux manually.
- Background long-running connection support varies by system. The app tries to keep sessions alive but cannot bypass system-level limits.
- Terminal copying is implemented with a Flutter text-selection helper layer, not a platform-native terminal text view.

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

确认通知权限已允许，应用后台耗电设置为无限制，没有开启会清理后台的系统管家策略。也需要确认服务器端 `ClientAliveInterval`、`ClientAliveCountMax` 等 SSH 配置没有主动踢掉连接，并检查网络是否在后台切换、休眠或断开。

English:

Make sure notification permission is allowed, battery usage is unrestricted, and no system manager policy is cleaning background apps. Also confirm that server-side SSH settings such as `ClientAliveInterval` and `ClientAliveCountMax` are not actively dropping the connection, and check whether the network is switching, sleeping, or disconnecting in the background.

### tmux 安装失败 / tmux Installation Failed

中文：

如果 SSH + tmux 模式提示自动安装失败，请手动登录服务器安装 tmux，然后回到应用重试。常见命令如下：

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

如果服务器没有 `sudo` 权限，请联系服务器管理员安装，或使用已经安装 tmux 的账号/环境。

English:

If SSH + tmux reports that automatic installation failed, log in to the server manually, install tmux, and then retry in the app. Common commands:

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

If the account does not have `sudo` privileges, ask the server administrator to install tmux or use an account/environment where tmux is already available.

## 许可证 / License

中文：

当前仓库未声明开源许可证。如需公开发布，请先补充明确的 `LICENSE` 文件。

English:

This repository does not currently declare an open-source license. Add a clear `LICENSE` file before public release.
