最新更新时间：2026-08-14

# Skill 与 Memory 维护规范

> 文档类型：Agent Governance
>
> 适用范围：Skill、Memory、AGENTS、CLAUDE、ADR、Architecture 与相关项目文档

## 1. 唯一 Owner

同一信息只能有一个长期 Owner：

| Information | Canonical owner |
| --- | --- |
| Agent 应该如何工作 | [Canonical Skill](../../.agents/skills/ssh-mobile-maintenance/SKILL.md) |
| 任务应读取哪些知识 | [Memory Map](../../.agents/skills/ssh-mobile-maintenance/references/memory-map.md) |
| 当前、高成本且可复用的项目知识 | [`memory_docs/`](../../memory_docs/) |
| 局部编辑、依赖、数据库、生命周期与测试合同 | 该 App/Package 的 `AGENTS.md` |
| 包责任、公共 API、存储与 Owner | 该 App/Package 的 `README.md` |
| 为什么采用某项架构决策 | [`docs/adr/`](../adr/) |
| 完整系统设计 | [`docs/architecture/`](../architecture/) 与专题架构文档 |
| 当前真实行为 | Code and tests |
| 历史 | Git |
| Agent 启动入口 | 根 `AGENTS.md` 与 `CLAUDE.md` |

其他文件可以保留必要摘要，但必须引用 Owner，不得长期维护完整副本。

## 2. Canonical Skill

`.agents/skills/ssh-mobile-maintenance/` 是唯一 Skill source of truth。

Skill 负责：

- 任务范围、安全边界与强制工作规则；
- 读取 Memory、ADR、Architecture 与局部合同的入口；
- 验证选择、文档同步、Git 提交与完成条件。

Skill 不保存：

- 完整项目架构或 Feature 百科；
- 当前迁移状态或长篇模块事实；
- 历史 Bug、完成流水或某次测试结果；
- 已由 ADR、Architecture、Package README/AGENTS 维护的完整内容。

较长但稳定的执行细节可放入 `references/`：

- `memory-map.md`：路径/任务到按需知识的路由；
- `workflow.md`：通用执行流程；
- `validation.md`：按变更类型选择验证。

`.agents/skills/*/SKILL.md` 是唯一 Skill source of truth，没有 `.claude` mirror；Claude Code 直接从 `.agents/skills/` 加载。

## 3. Project Memory

Memory 位于 [`memory_docs/`](../../memory_docs/)，一级按稳定 Domain 分为：

- `client`：Flutter Apps、Core/Feature packages 与 SSH client infrastructure；
- `sdk`：Dart network contracts、native binding、Rust network runtime 与 wire protocol；
- `backend`：Go control plane 与 Relay；
- `front`：React Admin UI。

Domain 可按实际需要包含：

- `overview.md`：稳定责任、主要路径与边界；
- `architecture.md`：Agent 高频需要的架构摘要与正式文档索引；
- `current-state.md`：经代码/测试/现行合同核对的当前状态；
- `lessons.md`：容易重复踩坑、长期有效且会影响正确性的经验。

只有当 Domain 内容已明显复杂、Feature 经常被独立修改，且不拆会持续加载大量无关上下文时，才创建 `features/<feature>.md`。不为目录对称或每个代码 Feature 机械创建 Memory。

## 4. Memory 迁入与更新门槛

一条知识只能在同时满足以下条件时进入 Memory：

1. 已由当前代码、测试、公共 API 或现行合同核验；
2. 并非从一个局部文件就能显而易见地获得，重新发现成本高；
3. 未来 Agent 不知道它可能导致错误实现。

不进入 Memory 的内容：

- 某天、某个 commit 或某个 Step 完成了什么；
- 一次性编译错误、临时 Bug 过程、测试通过率和机器本地路径；
- 完整 ADR 分析、完整 Architecture 或 Package 合同副本；
- 容易从当前代码或单个 README 重新获得的事实。

旧状态失效后直接替换或删除，不追加时间线。无法确认的旧知识记入迁移审计，不进入新 Memory。

## 5. 加载规则

禁止任务默认读取全部 Memory。标准顺序是：

1. 从用户需求和只读搜索确认真实 owning paths；
2. 读取目标路径到根目录之间的 `AGENTS.md` 和 Workspace Member `README.md`；
3. 根据 Memory Map 读取命中 Domain 的 overview/current-state；
4. 只在 ownership、lifecycle、dependency、storage 或 public API 变化时读 architecture；
5. 只在排障、回归或性能问题时读 matching lessons；
6. 命中复杂 Feature 或架构决策时再读 Feature Memory、ADR 或 Architecture。

只修拼写、格式或不改变事实的链接时，可跳过 Domain Memory；文档改变项目事实时，必须反向路由到该事实的 Owner。

## 6. ADR 与 Architecture

ADR 负责“为什么”。涉及以下内容时必须检查精确相关 ADR：

- module ownership、Session/Connection/Route lifecycle；
- transport/path selection、reconnect/resume/recovery/delivery ordering；
- protocol/wire semantics、crypto/key lifecycle、Relay/direct 选择；
- WebRTC media/data plane 与 native task ownership。

Accepted ADR 是架构约束。代码与 ADR 冲突时记录 architecture drift，不为迎合当前代码而改写历史决策。

Architecture Docs 负责完整、系统性设计。Memory 仅保留高频摘要和索引。

## 7. 更新判断

任务完成时，只更新真正改变的 Owner：

- Agent 工作方式变化 → Skill/reference；
- 未来 Agent 需要知道的当前项目事实变化 → relevant Memory；
- 架构决策变化 → ADR；
- 完整系统设计变化 → Architecture Doc；
- Package ownership、public API、storage、lifecycle 或必须测试变化 → package README/AGENTS；
- 历史 → Git。

局部 UI 微调、typo、变量重命名、普通 Bug 修复或常规测试补充通常不需要更新 Memory。

## 8. 文档与安全

- 受维护 Markdown 必须在 YAML front matter 后的首个非空位置放置日期标记；English-first 使用 `Last updated`，中文治理/审计使用 `最新更新时间`。
- 项目引用使用仓库内相对路径，不记录机器本地、`file:`、绝对或逃出仓库的路径。
- 密码、私钥、API Key、Token、服务器凭据与用户私密数据不得进入 Skill、Memory、日志、测试、截图或文档。
- 文档链路、retired references 与默认上下文体积由轻量 Agent documentation checker 守卫；内容真实性和是否应该进入 Memory 仍需要人工审查。

## 9. 禁止事项

1. 在 Skill、Memory、AGENTS、CLAUDE 中长期并行维护同一份完整信息。
2. 任务默认加载全部 Domain 或全部 Feature Memory。
3. 为目录整齐而创建空 Memory 或为每个 Feature 建 Memory。
4. 将 Git 流水、临时结果或过期状态追加到 current-state。
5. 人工维护两份等价 Skill 或从 `.claude` 反向覆盖 canonical `.agents` Skill。
6. 为减少 Token 而删除仍会影响正确性的关键知识。

## 10. 结果原则

> Skill 管工作方式，Memory 管当前项目知识，ADR 管决策原因，Architecture 管完整设计，Code/Tests 管真实行为，Git 管历史，AGENTS/CLAUDE 管启动入口。

> 一个信息，一个 Owner；按需读取，不全部加载。
