// SFTP Feature 的唯一公共入口。
//
// App Shell 只能通过此文件使用 SFTP 的 Module、Route VM、模型和 Port，
// 不得直接引用 package 内部的 src 路径。
library;

export 'src/application/sftp_module.dart';
export 'src/application/sftp_viewmodel.dart';
export 'src/data/database/sftp_database.dart';
export 'src/data/repository/drift_sftp_path_history_repository.dart';
export 'src/data/sftp_service.dart';
export 'src/domain/sftp_models.dart';
export 'src/domain/sftp_ports.dart';
export 'src/domain/sftp_strings.dart';
export 'src/presentation/sftp_editor_screen.dart';
export 'src/presentation/sftp_file_viewer_screen.dart';
export 'src/presentation/sftp_screen.dart';
export 'src/presentation/sftp_settings_screen.dart';
