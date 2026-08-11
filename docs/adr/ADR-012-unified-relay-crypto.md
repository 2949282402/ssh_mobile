最新更新时间：2026-08-11

# ADR-012: Unified Relay Crypto and HKDF Key Derivation

状态：Accepted

## 背景

Relay 只负责转发控制帧和不透明二进制分块。原实现将 X25519 共享秘密直接
作为 AES-256-GCM 密钥，offer 与文件分块各自维护 nonce/AAD 规则，后续难以
安全地扩展密钥用途、恢复和重连状态。

## 决策

- Relay offer 使用临时 X25519 与接收端 E2E 密钥协商，经过 HKDF-SHA256、以
  `session_id` 为 salt 派生 AES-256-GCM 密钥；不再直接使用原始共享秘密。
- 文件分块使用 offer 中传输的随机内容密钥材料，再经过独立的
  HKDF-SHA256 `info` 和 `session_id` salt 派生本次 Session 的数据密钥。
- offer 的 AAD 绑定 Relay Session；分块的 AAD 绑定协议域、Session 和 sequence。
  分块仍要求接收端严格按 sequence 顺序处理，拒绝重放和乱序。
- 加密套件标记放在已加密的 offer 元数据中。套件不匹配时必须失败关闭，避免
  新旧实现将不同的密钥派生规则误认为兼容。
- 外层 offer envelope 的布局保持为 `ephemeral_public_key + nonce + ciphertext`，
  Relay 服务端和 Flutter/Dart 客户端无需了解密钥材料或修改接口。本 Step 仅修改
  native Rust 网络核心与架构文档。

## 影响

统一层集中管理 HKDF、AEAD、nonce 和 AAD，后续 Relay resume/recovery 可以复用
同一 Session Crypto 上下文。该变更是 Relay 加密套件升级；未升级的旧 native
Relay 对端会因套件或认证失败而拒绝，而不会降级到原始共享秘密。

## 验证

- offer 正常加解密、错误 Session、错误接收端和篡改均失败。
- 分块正常加解密，错误 Session、错误 sequence 和篡改均失败。
- sequence 不允许无符号回绕。
