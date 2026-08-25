最新更新时间：2026-08-25

# Network v2 合同测试

本目录维护冻结 network v2 计划的 Phase 0 characterization 清单。测试提交的
Relay v2 fixture、帧长度、路由隔离、密文不透明边界和证据矩阵；不编辑 native、
Relay、Dart 或生成的 protocol ownership 文件。

在仓库根目录运行不修改工作树的基线检查：

```sh
bash scripts/bash/contracts/network_v2_acceptance.sh baseline
```

严格入口还会调用所属 Rust/Go 测试选择器，并在矩阵仍有 `characterized` 或
`gap` 时失败：

```sh
bash scripts/bash/contracts/network_v2_acceptance.sh strict
```

提交的矩阵是最终验收清单。基线只检查 fixture 与证据拓扑；只有所有 case 都为
`covered` 且所属 Rust/Go 选择器通过时，strict acceptance 才视为绿色。
