// SSH Client Factory 兼容层。
//
// 唯一的 `SshClientFactory` 实现在 ssh_core（含 native ReliableStream Socket 层）。
// App 侧继续通过本文件导入，避免把 ssh_core 的内部文件路径泄漏到业务层。

export 'package:ssh_core/ssh_core.dart'
    show SshClientAuthOptions, SshClientFactory, SshCredentials;
