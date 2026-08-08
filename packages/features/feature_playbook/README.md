最新更新时间：2026-08-08

# feature_playbook

Playbook Feature Package，负责可复用运维剧本的编辑、审批绑定、顺序执行、
执行状态和历史记录。

## 边界

- 只通过 `Playbook*Port` 使用 App 的 SSH、连接目录、日志和数据保护能力。
- Module 独占 `playbook.db`、Repository 和 PlaybookService；Route Scope 只
  创建和释放 ViewModel。
- 不导入其他 Feature 实现、App 的 `/src/` 或旧 `StorageService`；旧入口只
  作为迁移兼容表面保留在 App Shell。
- Playbook 内容、命令、输出和执行历史中的敏感文本写入数据库前必须加密；
  审批目标绑定使用 `ssh_core.SshTargetBinding` 的不可变快照。

## 验证

在本 Package 目录执行：

```text
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test --no-pub
```
