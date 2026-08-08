// AI 模块依赖的跨边界 Capability 合约。
//
// 这些类型只描述跨模块所需的请求和结果，不包含 SSH、SFTP、数据库或
// Flutter 控件实现。具体 Feature/Infrastructure 由 App Composition Root
// 适配后注入，避免 Core 反向依赖 Feature。

/// 远程命令请求的不可变快照。
final class RemoteCommandRequest {
  const RemoteCommandRequest({
    required this.connectionId,
    required this.command,
    this.timeout = const Duration(seconds: 15),
  });

  final String connectionId;
  final String command;
  final Duration timeout;
}

/// 远程命令的脱敏前结果模型；是否展示内容由调用方的安全策略决定。
final class RemoteCommandResult {
  const RemoteCommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int? exitCode;
  final String stdout;
  final String stderr;
}

/// AI 执行远程命令所需的最小能力。
abstract interface class RemoteCommandCapability {
  Future<RemoteCommandResult> runCommand(RemoteCommandRequest request);
}

/// 文件传输能力的操作类型，避免在模块边界传递未约束的操作字符串。
enum FileTransferOperation {
  listDirectory,
  stat,
  readText,
  download,
  writeText,
  upload,
  createDirectory,
  rename,
  delete,
}

/// 文件传输操作请求；敏感内容只允许在内存中短暂存在。
final class FileTransferRequest {
  const FileTransferRequest({
    required this.operation,
    required this.connectionId,
    required this.path,
    this.newPath,
    this.text,
    this.bytes,
    this.maxBytes,
  });

  final FileTransferOperation operation;
  final String connectionId;
  final String path;
  final String? newPath;
  final String? text;
  final List<int>? bytes;
  final int? maxBytes;
}

/// 文件传输结果；结构化元数据放在 payload，正文/字节由调用方决定是否读取。
final class FileTransferResult {
  const FileTransferResult({
    this.payload = const <String, dynamic>{},
    this.bytes,
    this.text,
  });

  final Map<String, dynamic> payload;
  final List<int>? bytes;
  final String? text;
}

/// 远程文件传输的最小能力。
abstract interface class FileTransferCapability {
  Future<FileTransferResult> transfer(FileTransferRequest request);
}

/// 监控查询请求；参数由具体监控 Capability 解释，但必须保持 JSON 可审计。
final class MonitoringQuery {
  const MonitoringQuery({
    required this.operation,
    this.connectionId,
    this.arguments = const <String, dynamic>{},
  });

  final String operation;
  final String? connectionId;
  final Map<String, dynamic> arguments;
}

/// 监控查询能力，返回不包含凭据的结构化结果。
abstract interface class MonitoringCapability {
  Future<Map<String, dynamic>> query(MonitoringQuery request);
}

/// Playbook 操作请求。
final class PlaybookRequest {
  const PlaybookRequest({
    required this.operation,
    this.arguments = const <String, dynamic>{},
  });

  final String operation;
  final Map<String, dynamic> arguments;
}

/// Playbook 能力的最小边界；执行审批仍由上层 AI 安全策略负责。
abstract interface class PlaybookCapability {
  Future<Map<String, dynamic>> invoke(PlaybookRequest request);
}

/// RAG 查询请求。
final class RagQuery {
  const RagQuery({
    required this.query,
    this.limit = 3,
    this.searchMode = 'bm25',
    this.apiKey,
  });

  final String query;
  final int limit;
  final String searchMode;
  final String? apiKey;
}

/// RAG 结果的跨模块最小表示。
final class RagCapabilityChunk {
  const RagCapabilityChunk({
    required this.documentName,
    required this.text,
    this.metadata = const <String, dynamic>{},
  });

  final String documentName;
  final String text;
  final Map<String, dynamic> metadata;
}

/// AI 使用知识库所需的最小能力。
abstract interface class RagCapability {
  Future<List<RagCapabilityChunk>> retrieve(RagQuery request);
}

/// MCP 工具能力；审批绑定由具体 MCP Module 保留在进程内。
abstract interface class McpCapability {
  Future<List<Map<String, dynamic>>> toolDefinitions();

  Future<String> execute(
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  });
}
