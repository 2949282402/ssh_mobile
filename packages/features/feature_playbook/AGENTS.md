最新更新时间：2026-08-30

# feature_playbook 维护约束

- `PlaybookModule` alone owns `playbook.db`, Repository, and execution Service.
  SSH, connection catalogue, logging, and encryption arrive through
  `Playbook*Port`; never create global Services or use old App implementations.
- Approved execution binds immutable `SshTargetBinding` + action fingerprint;
  target/command change stops execution and requires new approval. Remote command
  limits, approval state, target binding, and secret filtering remain in
  Service/Port; UI only displays state and starts user actions.
- Contract: allowed playbook models/Repository/Module/Service/approval Port/pages/
  tests; no other Feature/App `/src/`, unified storage, or un-injected SSH/credential
  service. Public API changes sync `PlaybookAutomationPort`, App adapters, AI
  callers, and security tests. Sensitive DB fields are encrypted; Module releases
  DB/Repository/Service and AppRuntime releases injected resources.

## 验证（代码变更）

`dart format --output=none --set-exit-if-changed lib test`、`flutter analyze`、
`flutter test`；local aggregate CI 仅按用户明确要求运行。
