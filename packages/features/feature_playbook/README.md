最新更新时间：2026-08-24

# feature_playbook

Playbook Feature Package，负责可复用运维剧本的编辑、审批绑定、顺序执行、
执行状态和历史记录。

## 边界

- 只通过 `Playbook*Port` 使用 App 的 SSH、连接目录、日志和数据保护能力。
- Module 独占 `playbook.db`、Repository 和 PlaybookService；Route Scope 只
  创建和释放 ViewModel。
- 不导入其他 Feature 实现、App 的 `/src/` 或统一存储门面；旧 App
  Playbook UI/service 已删除，App Shell 只保留 Port 适配器。
- Playbook 内容、命令、输出和执行历史中的敏感文本写入数据库前必须加密；
  审批目标绑定使用 `ssh_core.SshTargetBinding` 的不可变快照。
- `playbooks.revision` 是数据库原子并发令牌。审批快照携带读取时 revision，执行侧
  每次状态写入使用单条条件 `UPDATE` 推进 revision；并发编辑先提交后，旧执行
  写入返回失败且不得覆盖编辑内容。v2 迁移清空旧版 `name/description` 明文副本，
  展示元数据只从加密 `content_json` 读取。
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
- 数据库：`PlaybookModule` 独占 `playbook.db`；命令、名称、描述、输出和敏感历史
  字段必须加密，审批执行通过数据库 revision CAS 防止覆盖并发编辑。
- 生命周期与资源 Owner：Module 负责数据库、Repository、Service；Route Scope 负责
  ViewModel；注入的 SSH、Logger 和 Data Protection 由 AppRuntime 释放。
- 测试命令：`dart format --output=none --set-exit-if-changed lib test`、
  `flutter analyze --no-pub`、`flutter test --no-pub`。
