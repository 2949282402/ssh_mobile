最新更新时间：2026-08-30

# Skill 与 Memory 维护规范

适用：Skill、Memory、AGENTS、CLAUDE、ADR、Architecture 及项目 Agent 文档。

## 唯一 Owner

| 信息 | 长期 Owner |
| --- | --- |
| Agent 工作规则、验证选择、完成条件 | `.agents/skills/ssh-mobile-maintenance/` |
| 任务知识路由 | `references/memory-map.md` |
| 当前且高成本的可复用事实 | `memory_docs/` |
| 局部编辑/依赖/API/存储/生命周期/测试合同 | 对应 App/Package `AGENTS.md` |
| 包职责、公共 API、存储、Owner、测试入口 | 对应 App/Package `README.md` |
| 架构原因 | `docs/adr/` |
| 完整设计/资源/依赖模型 | `docs/architecture/` 及专题 Architecture |
| 当前真实行为 | Code and tests |
| 历史执行 | Git |
| 启动入口 | 根 `AGENTS.md` + `CLAUDE.md` |

其他文件只能保留短摘要并指向 Owner，不维护完整副本。

## Canonical Skill

`.agents/skills/ssh-mobile-maintenance/` 是唯一 Skill source of truth（无
`.claude` 镜像）。Skill 只维护工作规则、安全边界、读取入口、验证/文档同步、
PR/提交完成条件；详细路由、流程、验证分别在 `references/memory-map.md`、
`workflow.md`、`validation.md`。不把项目百科、Feature 状态、历史流水、测试结果
或 ADR/Architecture 全文放入 Skill。

## Memory 内容与准入

`memory_docs/` 按稳定 Domain：`client`、`sdk`、`backend`、`front`。每个 Domain
可有 `overview`（责任/路径）、`architecture`（高频架构索引）、`current-state`
（核对后的当前事实）、`lessons`（长期有效的坑）。仅在 Feature 复杂、独立修改且
不拆会加载大量无关上下文时创建 `features/<feature>.md`。

进入 Memory 的事实必须：已由代码/测试/公共 API/现行合同核验；从局部文件不易
直接得到；且未知时会导致未来错误实现。不要写一次性错误、测试结果/通过率、机器
路径、日期流水、完整正式文档副本、显而易见事实；旧状态直接替换，无法确认的内容
留在迁移审计而非新 Memory。

## 读取与更新

禁止默认读取全部 Memory。按 Skill → Map → 目标路径间 `AGENTS.md`/README →
命中的 Domain overview/current → 条件性 architecture/lessons/Feature/ADR/Architecture
加载。只修拼写、格式或无事实变化的链接可停在入口链；治理任务另读本文件和
[Memory README](../../memory_docs/README.md)。

任务完成只更新事实真正改变的 Owner。跨 Owner 的摘要必须链接原 Owner，不能复制
完整内容。Accepted ADR 是决策约束；若与代码冲突，记录 drift，不改写历史 ADR。

## 文档、安全与禁止项

- 每个受维护 Markdown 在 YAML front matter 后首个非空位置放日期：English 用
  `Last updated: YYYY-MM-DD`，中文治理/审计用 `最新更新时间：YYYY-MM-DD`。
- 只使用仓库内相对路径；密码、私钥、API Key、Token、凭据和用户私密数据不得进入
  Skill、Memory、日志、测试、截图或文档。
- 禁止在 Skill/Memory/AGENTS/CLAUDE 中长期维护同一完整信息、默认加载全部 Domain/
  Feature、为目录对称创建空 Memory、把 Git 流水/临时结果追加到 current-state，或
  为省 Token 删除仍影响正确性的知识。
- 文档 checker 守护拓扑、日期、链接、退役路径、Skill 单向来源和上下文上限；人工
  仍需核对事实和 Owner。

## CI 交接约束

本地 aggregate CI 仅在用户明确提及时运行；普通改动按 Owner 做必要 focused
检查。用户要求发起 PR 时，最小 format/diff/focused 门禁后可提交、推送、发起 PR，
由 GitHub Actions 并行 jobs 作为 CI 基准。GAP、超时、失败、遗漏或未执行都不是
PASS；发起 PR/CI 后不主动观察或解读 GitHub，不批准或合并，合并权仅用户拥有。

## 结果原则

> 一个信息，一个 Owner；按需读取，不全部加载。Skill 管工作方式，Memory 管当前
> 知识，ADR 管原因，Architecture 管完整设计，Code/Tests 管行为，Git 管历史，
> AGENTS/CLAUDE 管启动入口。
