> 最新更新时间：2026-08-24

# 跨域项目审查 TODO

本文记录项目审查第 3 阶段的可执行事项与验收证据。审查严格按
Front → Backend → Client → SDK 的顺序推进；进入一个 Domain 后才展开其完整
TODO，修复并通过该 Domain 门禁后再进入下一个 Domain。

状态说明：`[x]` 已修复并验证，`[ ]` 尚未进入或尚未完成。代码与测试是当前
行为的权威证据，本文件不复制 Domain Memory 或架构文档。

## Front

- [x] **F-01 管理员会话状态 fail-closed**：修复登出后仍停留在控制台、连接恢复
  后残留旧错误、登出后旧会话探测迟到复活登录态，以及受保护请求返回 401、会话
  复查又失败时继续保留旧登录态。
- [x] **F-02 通用 API 响应边界**：204 响应仍经过 endpoint schema 校验；调用方
  已取消时，即使底层 `fetch` 无视 AbortSignal 并迟到成功，也拒绝该响应。
- [x] **F-03 Enrollment Token 生命周期**：30 秒到期会重置 active observer；轮换
  会取消旧读取；卸载后的迟到响应不能回填；明文轮换结果不进入 MutationCache；
  复制、展示和 QueryCache 仍保持短时、内存内、明确操作后访问。
- [x] **F-04 过期快照与撤销一致性**：Overview/Devices 刷新失败时明确标为旧数据；
  撤销成功会先从本地快照移除设备，再尝试权威刷新。
- [x] **F-05 部署语义文案**：移除硬编码的 memory-only、重启必然清空设备及含混的
  Protocol v1 文案；改为存储配置中立表述，并明确浏览器使用 Admin API v1。
- [x] **F-06 键盘与 CSP 边界**：移动导航支持焦点进入、焦点约束、Escape、焦点恢复
  和关闭态不可聚焦；设备撤销操作包含设备 ID；剪贴板 fallback 不再产生被生产
  CSP 禁止的 inline style，并保证临时明文节点最终清理。
- [x] **F-07 Front 回归与覆盖率**：61 项测试通过；aggregate statements/lines
  96.01%、branches 85.58%、functions 90%，通过 80% Domain 门禁。

Front 验收命令：

```bash
cd front
npm run typecheck
npm run lint
npm run test:run
npm run build
cd ..
bash scripts/front_coverage.sh
bash scripts/full_test.sh --only front-quality --no-bootstrap
```

## Backend（进行中）

- [ ] **B-01 完整 Backend 审查**：按 Backend Memory、Relay README、Go 实现、测试、
  配置和部署边界展开问题清单并逐项修复。
- [x] **B-02 Network V2 管理指标**：管理概览改为读取真实、并发安全的 RelayData
  活动配对数；pending 单端不计数，配对释放后立即归零，并有生命周期回归测试。
- [x] **B-03 Front↔Relay 契约门禁**：真实 Go handler 在私有临时目录生成已脱敏
  响应，Front 生产请求客户端与 Zod schema 验证路径、方法、状态码、204、401 和
  JSON 字段；门禁已接入 `full_test.sh` 与独立 GitHub Actions job。

B-02/B-03 验收命令：

```bash
bash scripts/admin_api_contract.sh
bash scripts/full_test.sh --only admin-api-contract --no-bootstrap
dart run test/tool/ci_workflow_test.dart
cd relay
go test ./internal/relay -run 'TestRelayDataRegistryRejectsDuplicateRoleAndConsumesPair|TestAdminOverviewCountsActiveRelayDataPairs' -count=1
```

## Client（待 Backend 完成后展开）

- [ ] **C-AUDIT 完整 Client 审查、TODO、修复与 Domain 验收**。

## SDK（待 Client 完成后展开）

- [ ] **S-AUDIT 完整 SDK 审查、TODO、修复与 Domain 验收**。

## 最终跨域验收

- [ ] 复核所有 TODO、架构边界、文件规模报告和未提交用户改动。
- [ ] 运行 `scripts/full_test.sh` 与 Front/Backend/Client/SDK 四个覆盖率门禁。
- [ ] 检查最终 `git diff --check`、状态、提交边界、生成物和文档日期标记。
