最新更新时间：2026-08-30

# Skill、Memory 与 Agent 文档审计摘要

> 一次性治理/迁移记录，不属于日常读取链。当前事实以代码、测试、公共入口和
> 现行合同为准；本摘要只记录 Owner、路由和仍需避免的重复/过期知识。

## 审计字段与准入

对每个来源记录 Role、Canonical owner、Disposition（retain/normalize/route/
migrate/replace/retire/record-only）及 verification source。进入 Memory 必须同时
满足：当前可核验、从局部文件不易直接得到、未知会导致未来错误实现。

## Canonical ownership

| 信息 | Owner |
| --- | --- |
| Agent 工作规则/验证/完成条件 | `.agents/skills/ssh-mobile-maintenance/` |
| 任务知识路由 | `references/memory-map.md` |
| 当前高成本事实 | `memory_docs/` |
| App/Package 局部编辑、依赖、生命周期、测试合同 | 各 `AGENTS.md` |
| 包职责/API/存储/Owner/验证入口 | 各 `README.md` |
| 决策原因 | `docs/adr/` |
| 完整设计与资源/依赖模型 | `docs/architecture/` 及专题文档 |
| 当前行为/历史 | Code and tests / Git |
| 启动入口 | 根 `AGENTS.md`、薄 `CLAUDE.md` |

根入口只负责启动与不可违背边界；Skill 负责工作方法、安全、验证和交接；Map
负责按需读取；Memory 只存跨包且昂贵的当前事实；局部合同不由 Memory 替代。
`.agents/` 是唯一 Skill source；当前仓库没有 `.claude/skills` 镜像，不能反向覆盖。

## 保留与退役结论

- 21 个 Workspace Member 的 `AGENTS.md`/`README.md` 均保留为局部合同；重复的
  “Step29 标准字段”已并入每个合同，测试命令改为“代码变更验证”，不改变门禁内容。
- `AGENT_MEMORY.md` 与 `.workbuddy` 历史日志已退役；其日期流水、临时结果、机器
  路径和过期迁移描述不进入新 Memory。`README.md`/`README.zh-CN.md` 仍是用户文档。
- ADR/Architecture 仍由各自文件维护；Memory 只做摘要和精确索引。文件恢复使用
  `ADR-030-file-resume.md`，传输路由使用完整文件名
  `ADR-011-transfer-session-route-dispatch.md`，避免旧编号歧义。
- `MODULAR_REFACTOR_PLAN.md` 保留为条件性架构/历史参考，不是默认任务输入；专题
  文档（Trace、UI QA、性能、网络故障、启动、安全、发布）按 Memory Map 条件路由。

## 已确认的重复/误导来源

1. Root/Skill/Memory/局部合同曾重复 ownership、安全规则、命令和迁移状态；默认链
   现在只保留摘要，详细命令/事实回到唯一 Owner。
2. 旧 Agent 文档把根文件或 Claude 镜像当成完整权威；现在以根 → Skill → Map →
   scoped contract/Memory 为唯一读取链。
3. 旧知识把 `ssh_core` 归入 SDK、把 LAN Control V2 与 Native Network V2 混为一体，
   或保留旧 pairing/upload fallback；当前路由和局部合同已明确纠正。
4. CI 规则曾鼓励自动本地全量运行；当前本地 aggregate 仅用户明确要求，GitHub
   Actions 是用户要求 PR 的并行 CI 基准，交接后不轮询/解读/合并，合并由用户决定。

## 验收方式

Agent documentation checker 负责固定 Memory 拓扑、必需链接、日期、仓库内路径、
退役引用、单向 Skill 来源和默认上下文大小；人工仍需核对事实、Owner 和是否应进入
Memory。任何未来压缩都不得删除会影响实现正确性的知识，也不得把临时执行记录写回
current-state。
