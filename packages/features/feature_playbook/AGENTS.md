最新更新时间：2026-08-08

# Playbook Package Guidelines

- `PlaybookModule` 是 `playbook.db`、Repository 和执行 Service 的唯一 Owner。
- SSH、连接目录、日志和加密能力只能通过 `Playbook*Port` 注入；不要在
  Feature 内创建全局 Service 或直接访问旧 App 实现。
- approved execution 必须使用不可变的 `SshTargetBinding` 和 action fingerprint；
  目标或命令发生变化时停止执行并等待重新审批。
- 远端命令限制、审批状态、目标绑定和 secret filtering 保持在 Service/Port
  层，UI 只负责展示状态和触发用户操作。
- 修改 Dart 后必须在 Package 目录运行 format、analyze 和 test。
