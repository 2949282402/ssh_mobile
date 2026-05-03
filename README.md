# SSH Mobile

SSH Mobile 是一个基于 Flutter 的移动端 SSH 客户端，重点面向 Android 手机上的长时间 SSH 会话使用场景。它支持多窗口连接、后台前台服务保活、终端快捷键、复制粘贴辅助层、暗色/亮色主题和中英文界面切换。

SSH Mobile is a Flutter-based mobile SSH client designed especially for long-running SSH sessions on Android phones. It supports multiple terminal windows, foreground-service keep-alive, terminal shortcuts, copy/paste helpers, light/dark themes, and Chinese/English UI switching.

> 说明：移动系统对后台网络连接有严格限制。应用会尽量通过前台服务、通知、WakeLock、SSH keep-alive 等方式保持连接，但长期后台不断开仍会受到手机厂商策略、电池优化、网络切换和系统内存回收影响。首次使用建议按照应用引导允许后台耗电无限制。

> Note: Mobile operating systems place strict limits on background networking. The app tries to keep sessions alive with a foreground service, notification, WakeLock, and SSH keep-alive, but long-running background stability still depends on vendor background policies, battery optimization, network switching, and process reclaiming. On first launch, allow unrestricted background battery usage when prompted.

## 主要功能 / Features

中文：

- SSH 连接管理：保存多个服务器配置，支持密码、私钥、私钥加密码三种认证方式。
- 多终端窗口：同一个服务器可以并行打开多个 SSH 窗口，每个窗口可自定义名称。
- 后台保活：Android 使用前台服务维持 SSH 会话，后台时发送 keep-alive，尽量减少息屏或切应用后的断连。
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
- Background keep-alive: Android uses a foreground service and SSH keep-alive to reduce disconnects after the app goes to the background.
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
| 后台服务 / Background service | `flutter_background_service` | Android 前台服务与后台 SSH 会话保活 / Android foreground service and session keep-alive |
| 通知 / Notifications | `flutter_local_notifications` | 前台服务常驻通知 / Persistent foreground-service notification |
| 安全存储 / Secure storage | `flutter_secure_storage` | 密码和私钥等敏感信息存储 / Storage for passwords, private keys, and other sensitive data |
| 本地配置 / Local settings | `shared_preferences` | 主题、语言、快捷命令等轻量配置 / Lightweight settings such as theme, language, and shortcuts |
| 权限 / Permissions | `permission_handler` | 通知、电池优化等权限处理 / Permission handling for notifications, battery optimization, and related flows |

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
│   │   ├── startup_screen.dart      # 启动页与初始化
│   │   ├── home_screen.dart         # 连接列表、语言/主题切换
│   │   ├── add_edit_screen.dart     # 新增/编辑连接配置
│   │   └── terminal_screen.dart     # 终端窗口、多窗口、快捷键、复制层
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
│   │   ├── startup_screen.dart      # Startup and initialization screen
│   │   ├── home_screen.dart         # Connection list, language/theme switches
│   │   ├── add_edit_screen.dart     # Add/edit connection form
│   │   └── terminal_screen.dart     # Terminal window, multi-window UI, shortcuts, copy layer
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

## Android 权限 / Android Permissions

中文：

Android 端会用到以下权限：

- `INTERNET`：建立 SSH 网络连接。
- `ACCESS_NETWORK_STATE` / `ACCESS_WIFI_STATE`：感知网络状态。
- `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_DATA_SYNC`：运行前台服务保活 SSH。
- `POST_NOTIFICATIONS`：显示前台服务通知，Android 13+ 需要用户授权。
- `WAKE_LOCK`：尽量避免后台任务被过早挂起。
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`：引导用户关闭电池优化，提升后台长连接稳定性。

如果希望 SSH 在切到后台后尽量不断开，请在手机系统设置中允许后台耗电无限制、自启动、锁屏后继续运行、通知权限和后台联网。不同品牌手机的设置名称会有差异，尤其是 vivo、OPPO、小米、华为等系统会更积极地限制后台任务。

English:

The Android app uses these permissions:

- `INTERNET`: Establish SSH network connections.
- `ACCESS_NETWORK_STATE` / `ACCESS_WIFI_STATE`: Observe network state.
- `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_DATA_SYNC`: Run a foreground service to keep SSH sessions alive.
- `POST_NOTIFICATIONS`: Show the foreground-service notification. Android 13+ requires user approval.
- `WAKE_LOCK`: Reduce the chance of background work being suspended too early.
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`: Guide users to disable battery optimization for better long-running stability.

For better background stability, allow unrestricted battery usage, autostart, running after screen lock, notifications, and background networking in system settings. The exact setting names vary by device brand, and systems such as vivo, OPPO, Xiaomi, and Huawei may restrict background tasks more aggressively.

## 开发环境 / Development Environment

中文：

本项目仓库内可以使用本地 Flutter SDK：

```powershell
.\.tools\flutter\bin\flutter.bat --version
```

也可以使用系统已安装的 Flutter：

```powershell
flutter --version
```

推荐环境：

- Flutter 3.x
- Dart SDK `>=3.2.0 <4.0.0`
- Android Studio 或 Android SDK
- 一台已开启 USB 调试的 Android 手机

English:

This repository can use the bundled local Flutter SDK:

```powershell
.\.tools\flutter\bin\flutter.bat --version
```

You can also use a system-installed Flutter SDK:

```powershell
flutter --version
```

Recommended environment:

- Flutter 3.x
- Dart SDK `>=3.2.0 <4.0.0`
- Android Studio or Android SDK
- An Android phone with USB debugging enabled

## 获取依赖 / Install Dependencies

中文：

使用仓库内 Flutter 获取依赖：

```powershell
.\.tools\flutter\bin\flutter.bat pub get
```

如果遇到 Git safe directory 提示，可以执行：

```powershell
git config --global --add safe.directory D:/coding/ssh_mobile/.tools/flutter
```

English:

Install dependencies with the bundled Flutter SDK:

```powershell
.\.tools\flutter\bin\flutter.bat pub get
```

If Git reports a safe-directory warning, run:

```powershell
git config --global --add safe.directory D:/coding/ssh_mobile/.tools/flutter
```

## 运行到手机 / Run on a Phone

中文：

1. 手机开启开发者选项和 USB 调试。
2. 使用 USB 连接电脑，并在手机上允许调试授权。
3. 查看设备：

```powershell
.\.tools\flutter\bin\flutter.bat devices
```

4. 运行到指定设备：

```powershell
.\.tools\flutter\bin\flutter.bat run -d <device-id>
```

示例：

```powershell
.\.tools\flutter\bin\flutter.bat run -d V2309A
```

English:

1. Enable Developer Options and USB debugging on the phone.
2. Connect the phone via USB and approve the debugging prompt.
3. List available devices:

```powershell
.\.tools\flutter\bin\flutter.bat devices
```

4. Run the app on a specific device:

```powershell
.\.tools\flutter\bin\flutter.bat run -d <device-id>
```

Example:

```powershell
.\.tools\flutter\bin\flutter.bat run -d V2309A
```

## 构建 APK / Build APK

中文：

Debug APK：

```powershell
.\.tools\flutter\bin\flutter.bat build apk --debug
```

Release APK：

```powershell
.\.tools\flutter\bin\flutter.bat build apk --release
```

构建产物通常位于：

```text
build/app/outputs/flutter-apk/
```

English:

Debug APK:

```powershell
.\.tools\flutter\bin\flutter.bat build apk --debug
```

Release APK:

```powershell
.\.tools\flutter\bin\flutter.bat build apk --release
```

Build artifacts are usually generated under:

```text
build/app/outputs/flutter-apk/
```

## 常用开发命令 / Common Development Commands

中文：

```powershell
# 格式化代码
.\.tools\flutter\bin\dart.bat format lib test

# 静态检查
.\.tools\flutter\bin\flutter.bat analyze

# 运行测试
.\.tools\flutter\bin\flutter.bat test

# 清理构建缓存
.\.tools\flutter\bin\flutter.bat clean

# 重新获取依赖
.\.tools\flutter\bin\flutter.bat pub get
```

English:

```powershell
# Format code
.\.tools\flutter\bin\dart.bat format lib test

# Static analysis
.\.tools\flutter\bin\flutter.bat analyze

# Run tests
.\.tools\flutter\bin\flutter.bat test

# Clean build cache
.\.tools\flutter\bin\flutter.bat clean

# Reinstall dependencies
.\.tools\flutter\bin\flutter.bat pub get
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

连接 SSH 后，Android 会启动前台服务并显示通知。应用进入后台时，服务会继续维护 SSH 会话并发送 keep-alive。为了提高稳定性，请保持前台服务通知开启，将应用设置为后台耗电无限制，不要从最近任务列表中划掉应用，并尽量保持网络稳定。

如果系统强制回收应用进程，SSH 连接仍可能断开。这是移动系统限制，不是 SSH 协议本身可以完全绕过的问题。

English:

After SSH connects, Android starts a foreground service and shows a notification. When the app goes to the background, the service continues maintaining SSH sessions and sending keep-alive packets. For better stability, keep the foreground-service notification enabled, set the app to unrestricted battery usage, avoid swiping it away from recent apps, and keep the network stable.

If the system forcibly kills the app process, the SSH connection may still drop. This is a mobile OS limitation, not something the SSH protocol can fully bypass.

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

- Android 厂商后台策略可能导致长时间后台后断连，需要用户手动放开后台限制。
- 网络从 Wi-Fi、数据、VPN 之间切换时，底层 TCP 连接通常会失效，应用只能检测断连并提示或重连，无法保证原 SSH 会话无缝迁移。
- iOS 后台长连接限制更严格，当前项目主要优化目标是 Android。
- 终端复制使用 Flutter 文本选择层辅助实现，不是系统原生 TextView 终端。

English:

- Android vendor background policies may disconnect sessions after a long time in the background. Users need to relax background restrictions manually.
- When the network switches between Wi-Fi, mobile data, and VPN, the underlying TCP connection usually becomes invalid. The app can detect the disconnect and prompt or reconnect, but it cannot guarantee seamless migration of the original SSH session.
- iOS background long-running connections are more restricted. The current project mainly optimizes Android.
- Terminal copying is implemented with a Flutter text-selection helper layer, not a native Android TextView terminal.

## 故障排查 / Troubleshooting

### `detected dubious ownership`

中文：

如果运行仓库内 Flutter 时出现 Git 所有权警告：

```powershell
git config --global --add safe.directory D:/coding/ssh_mobile/.tools/flutter
```

English:

If Git reports an ownership warning when running the bundled Flutter SDK:

```powershell
git config --global --add safe.directory D:/coding/ssh_mobile/.tools/flutter
```

### 设备找不到 / Device Not Found

中文：

```powershell
.\.tools\flutter\bin\flutter.bat devices
```

如果没有手机，请检查 USB 调试是否开启、手机是否弹出授权确认、USB 连接是否稳定，以及 Android SDK platform-tools 是否可用。

English:

```powershell
.\.tools\flutter\bin\flutter.bat devices
```

If the phone does not appear, check whether USB debugging is enabled, whether the phone has shown an authorization prompt, whether the USB connection is stable, and whether Android SDK platform-tools are available.

### 后台很快断连 / Background Disconnects Quickly

中文：

确认通知权限已允许，应用后台耗电设置为无限制，没有开启会清理后台的系统管家策略。也需要确认服务器端 `ClientAliveInterval`、`ClientAliveCountMax` 等 SSH 配置没有主动踢掉连接，并检查网络是否在后台切换、休眠或断开。

English:

Make sure notification permission is allowed, battery usage is unrestricted, and no system manager policy is cleaning background apps. Also confirm that server-side SSH settings such as `ClientAliveInterval` and `ClientAliveCountMax` are not actively dropping the connection, and check whether the network is switching, sleeping, or disconnecting in the background.

## 许可证 / License

中文：

当前仓库未声明开源许可证。如需公开发布，请先补充明确的 `LICENSE` 文件。

English:

This repository does not currently declare an open-source license. Add a clear `LICENSE` file before public release.
