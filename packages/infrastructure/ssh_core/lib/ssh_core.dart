// ssh_core 的公共入口。
//
// App 和 Feature 只能依赖这里导出的契约；禁止跨 Package 引用 lib/src。
library;

export 'src/client/ssh_client_factory.dart';
export 'src/client/ssh_command_executor.dart';
export 'src/client/ssh_host_key_policy.dart';
export 'src/model/ssh_credentials.dart';
export 'src/model/ssh_runtime_event.dart';
export 'src/model/ssh_session.dart';
export 'src/model/ssh_session_metadata.dart';
export 'src/model/ssh_target_binding.dart';
export 'src/pool/ssh_session_lease.dart';
export 'src/pool/ssh_session_pool.dart';
export 'src/runtime/desktop_ssh_runtime.dart';
export 'src/runtime/mobile_background_ssh_runtime.dart';
export 'src/runtime/ssh_runtime_adapter.dart';
export 'src/session/ssh_session_manager.dart';
export 'src/session/ssh_session_manager_impl.dart';
export 'src/terminal/ssh_terminal_capability.dart';
