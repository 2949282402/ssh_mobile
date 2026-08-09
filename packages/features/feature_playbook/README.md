最新更新时间：2026-08-09

# feature_playbook

Playbook Feature Package，负责可复用运维剧本的编辑、审批绑定、顺序执行、
执行状态和历史记录。

## 边界

- 只通过 `Playbook*Port` 使用 App 的 SSH、连接目录、日志和数据保护能力。
- Module 独占 `playbook.db`、Repository 和 PlaybookService；Route Scope 只
  创建和释放 ViewModel。
- 不导入其他 Feature 实现、App 的 `/src/` 或统一存储门面；旧入口只
  作为迁移兼容表面保留在 App Shell。
- Playbook 内容、命令、输出和执行历史中的敏感文本写入数据库前必须加密；
  审批目标绑定使用 `ssh_core.SshTargetBinding` 的不可变快照。
- 公共入口提供 Playbook 路由的纯 metadata；App Shell 聚合描述并在 Route Scope 创建
  页面状态，不跨包暴露实现路径。

## 验证

在本 Package 目录执行：

```text
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test --no-pub
```

## Package contract

- 职责：提供剧本编辑、审批绑定、顺序执行、运行状态和历史记录。
- 不负责：AI 编排、SSH 实现、凭据存储或 App Shell 路由生命周期。
- Public API：`package:feature_playbook/feature_playbook.dart`，包括
  `PlaybookAutomationPort` 和路由 metadata。
- 依赖：`app_core`、`app_ui`、`connection_core`、`ssh_core`、Drift、Provider 和 Flutter。
- 数据库：`PlaybookModule` 独占 `playbook.db`；命令、输出和敏感历史字段必须加密。
- 生命周期与资源 Owner：Module 负责数据库、Repository、Service；Route Scope 负责
  ViewModel；注入的 SSH、Logger 和 Data Protection 由 AppRuntime 释放。
- 测试命令：`dart format --output=none --set-exit-if-changed lib test`、
  `flutter analyze --no-pub`、`flutter test --no-pub`。
