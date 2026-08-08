最新更新时间：2026-08-08

# LAN Share Package Guidelines

- 业务、协议和安全行为迁移自旧 LAN Quick Share 实现，修改时优先保持兼容。
- Package 不得导入 SSH、其他 Feature 实现或 App 的 `/src/`；跨边界能力必须
  通过 `LanShare*Port` 注入。
- `LanShareModule` 是 `lan_share.db`、Repository、Receiver 和 Route Service
  的 Owner；Route Scope 只负责 ViewModel 生命周期。
- 不把密钥、PIN、Bearer Token、Relay credential 或远端 localPath 写入明文
  数据库；接收文件必须经过 LAN sandbox 校验。
- 修改 Dart 文件后运行本 Package 的 format、analyze 和 test；Drift 输入变化
  后重新生成并确认 `*.g.dart` 与输入一致。
