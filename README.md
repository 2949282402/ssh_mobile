# SSH Mobile — Flutter 跨平台 SSH 客户端

移动端 SSH 客户端，**支持后台长连接不中断**。

## 🏗 架构

| 层 | 技术 | 说明 |
|---|---|---|
| SSH 连接 | `dartssh2` | 纯 Dart 实现，零原生依赖 |
| 终端渲染 | `xterm` | ANSI 转义码完整终端模拟 |
| Android 保活 | `flutter_background_service` | 前台服务 + 通知，进程不被杀 |
| iOS 保活 | Background Fetch + 智能重连 | iOS 限制严格，断线自动恢复 |
| 安全存储 | `flutter_secure_storage` | 密码/私钥存 Keychain/Keystore |
| 状态管理 | `provider` | 轻量级 ChangeNotifier |

## 🔒 后台保活原理

### Android
```
用户连接 SSH → 启动前台服务 → 系统通知栏显示"SSH 已连接"
→ App 进入后台 → 前台服务保持进程存活 → SSH 长连接继续
→ SSH 心跳 30s/次 → 连接永不断
```

### iOS
```
用户连接 SSH → 进入后台 → 申请后台任务延长执行
→ 30s 内维持连接 → 超时后连接断开
→ App 回到前台 → 自动重连 → 恢复会话
```

## 🚀 构建

```bash
# 1. 安装 Flutter SDK（你本地机器）
#    https://docs.flutter.dev/get-started/install

# 2. 克隆/拷贝项目到本地
#    (从服务器下载整个 ssh_mobile 目录)

# 3. 获取依赖
cd ssh_mobile
flutter pub get

# 4. 构建 Android APK
flutter build apk --release

# 5. 构建 iOS（需要 macOS + Xcode）
flutter build ios --release
```

## 📁 项目结构

```
ssh_mobile/
├── lib/
│   ├── main.dart                  # 入口 + 路由
│   ├── models/
│   │   └── connection.dart        # 连接配置模型
│   ├── services/
│   │   ├── ssh_service.dart       # SSH 连接管理（核心）
│   │   ├── storage_service.dart   # 配置 + 密码存储
│   │   └── background_service.dart # 后台保活服务
│   ├── screens/
│   │   ├── home_screen.dart       # 连接列表
│   │   ├── add_edit_screen.dart   # 添加/编辑连接
│   │   └── terminal_screen.dart   # 终端界面（xterm）
│   └── theme/
│       └── app_theme.dart         # 暗色终端主题
├── android/
│   └── app/src/main/
│       └── AndroidManifest.xml    # 前台服务权限
├── ios/
│   └── Runner/
│       └── Info.plist             # 后台模式配置
└── pubspec.yaml
```

## ✨ 功能

- ✅ 密码 & 私钥认证
- ✅ Android 后台长连接不中断（前台服务）
- ✅ iOS 断线自动重连
- ✅ 完整 ANSI 终端（256 色、光标定位）
- ✅ 跳板机支持
- ✅ 密码加密存储（Keychain/Keystore）
- ✅ 快捷功能键（TAB/ESC/CTRL+C 等）
- ✅ 终端大小自适应 + 手动调整
- ✅ SSH 心跳保活
- ✅ 暗色终端主题
