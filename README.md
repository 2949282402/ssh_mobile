# SSH Mobile

SSH Mobile 是一个基于 Flutter 的移动端 SSH 客户端，重点面向 Android 手机上的长时间 SSH 会话使用场景。它支持多窗口连接、后台前台服务保活、终端快捷键、复制粘贴辅助层、暗色/亮色主题和中英文界面切换。

> 说明：移动系统对后台网络连接有严格限制。应用会尽量通过前台服务、通知、WakeLock、SSH keep-alive 等方式保持连接，但是否能长期不断开仍会受到手机厂商后台策略、电池优化、网络切换和系统内存回收影响。首次使用建议按照应用引导允许后台耗电无限制。

## 主要功能

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

## 技术栈

| 模块 | 依赖 | 说明 |
| --- | --- | --- |
| Flutter UI | `flutter` / `provider` | 页面、状态管理、主题与本地化状态 |
| SSH 协议 | `dartssh2` | 纯 Dart SSH 客户端实现 |
| 终端渲染 | `xterm` | ANSI 终端模拟与输入输出处理 |
| 后台服务 | `flutter_background_service` | Android 前台服务与后台 SSH 会话保活 |
| 通知 | `flutter_local_notifications` | 前台服务常驻通知 |
| 安全存储 | `flutter_secure_storage` | 密码和私钥等敏感信息存储 |
| 本地配置 | `shared_preferences` | 主题、语言、快捷命令等轻量配置 |
| 权限 | `permission_handler` | 通知、电池优化等权限处理 |

## 项目结构

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

## Android 权限说明

Android 端会用到以下权限：

- `INTERNET`：建立 SSH 网络连接。
- `ACCESS_NETWORK_STATE` / `ACCESS_WIFI_STATE`：感知网络状态。
- `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_DATA_SYNC`：运行前台服务保活 SSH。
- `POST_NOTIFICATIONS`：显示前台服务通知，Android 13+ 需要用户授权。
- `WAKE_LOCK`：尽量避免后台任务被过早挂起。
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`：引导用户关闭电池优化，提升后台长连接稳定性。

如果希望 SSH 在切到后台后尽量不断开，请在手机系统设置中允许：

- 后台耗电无限制
- 自启动或关联启动
- 锁屏后继续运行
- 通知权限
- VPN/数据/Wi-Fi 切换时允许应用后台联网

不同品牌手机的设置名称会有差异，尤其是 vivo、OPPO、小米、华为等系统会更积极地限制后台任务。

## 开发环境

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

## 获取依赖

使用仓库内 Flutter：

```powershell
.\.tools\flutter\bin\flutter.bat pub get
```

如果遇到 Git safe directory 提示，可以执行：

```powershell
git config --global --add safe.directory D:/coding/ssh_mobile/.tools/flutter
```

## 运行到手机

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

## 构建 APK

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

## 常用开发命令

格式化代码：

```powershell
.\.tools\flutter\bin\dart.bat format lib test
```

静态检查：

```powershell
.\.tools\flutter\bin\flutter.bat analyze
```

运行测试：

```powershell
.\.tools\flutter\bin\flutter.bat test
```

清理构建缓存：

```powershell
.\.tools\flutter\bin\flutter.bat clean
```

重新获取依赖：

```powershell
.\.tools\flutter\bin\flutter.bat pub get
```

## 使用说明

### 添加 SSH 连接

在主页点击新增连接，填写：

- 名称
- 主机地址
- 端口，默认 `22`
- 用户名
- 认证方式：密码、私钥或私钥加密码
- 可选跳板机信息

保存后即可从主页发起连接。

### 多窗口

进入终端后：

- 点击标题旁边的 `+` 可以基于当前服务器创建新的终端窗口。
- 点击窗口切换按钮可以查看全部窗口。
- 在窗口列表中点击某一项可以切换窗口。
- 在窗口列表中点击右侧关闭按钮可以关闭对应窗口。
- 点击编辑按钮可以修改当前窗口名称。

### 后台保活

连接 SSH 后，Android 会启动前台服务并显示通知。应用进入后台时，服务会继续维护 SSH 会话并发送 keep-alive。

为了提高稳定性：

- 保持前台服务通知开启。
- 将应用设置为后台耗电无限制。
- 不要从最近任务列表中划掉应用。
- 网络切换期间尽量保持 Wi-Fi/数据网络稳定。

如果系统强制回收应用进程，SSH 连接仍可能断开。这是移动系统限制，不是 SSH 协议本身可以完全绕过的问题。

### 复制与粘贴

- 长按终端区域可打开菜单。
- 选择复制层后，可以拖动选择文本并复制。
- 粘贴会把剪贴板内容发送到当前 SSH 会话。
- 多行文本建议使用底部复杂输入框，确认无误后点击发送。

### 快捷键与命令

底部快捷键栏提供常用按键：

- `TAB`、`ESC`、`ENTER`、`BKSP`
- `↑`、`↓`、`←`、`→`
- `HOME`、`END`、`PGUP`、`PGDN`
- `CTRL+C`、`CTRL+D`、`CTRL+L`

可以添加自定义快捷命令。自定义命令会按使用频率排序，常用命令会自动靠前。

## 已知限制

- Android 厂商后台策略可能导致长时间后台后断连，需要用户手动放开后台限制。
- 网络从 Wi-Fi、数据、VPN 之间切换时，底层 TCP 连接通常会失效，应用只能检测断连并提示或重连，无法保证原 SSH 会话无缝迁移。
- iOS 后台长连接限制更严格，当前项目主要优化目标是 Android。
- 终端复制使用 Flutter 文本选择层辅助实现，不是系统原生 TextView 终端。

## 故障排查

### `detected dubious ownership`

如果运行仓库内 Flutter 时出现 Git 所有权警告：

```powershell
git config --global --add safe.directory D:/coding/ssh_mobile/.tools/flutter
```

### 设备找不到

```powershell
.\.tools\flutter\bin\flutter.bat devices
```

如果没有手机：

- 检查 USB 调试是否开启。
- 检查手机是否弹出授权确认。
- 重新插拔 USB。
- 确认 Android SDK platform-tools 可用。

### 后台很快断连

- 确认通知权限已允许。
- 确认应用后台耗电设置为无限制。
- 确认没有开启会清理后台的系统管家策略。
- 确认服务器端 `ClientAliveInterval`、`ClientAliveCountMax` 等 SSH 配置没有主动踢掉连接。
- 检查网络是否在后台切换、休眠或断开。

## 许可证

当前仓库未声明开源许可证。如需公开发布，请先补充明确的 `LICENSE` 文件。
