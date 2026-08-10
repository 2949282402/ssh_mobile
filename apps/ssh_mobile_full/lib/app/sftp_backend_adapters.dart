// App Shell 的 SFTP 后端适配入口。
//
// Feature 页面和 ViewModel 不得从这里反向依赖旧后端；该入口只供仍需
// 共享旧 SSH/SFTP 协议实现的 App Shell 组合测试和 AI/系统组合适配使用。

export '../services/sftp_path_history_store.dart';
export '../services/sftp/sftp_entry_parser.dart';
export '../services/sftp_service.dart';
