/// Playbook Feature 的唯一公共入口；调用方不得导入本 Package 的 `src/`。
library;

export 'src/application/playbook_module.dart';
export 'src/application/playbook_service.dart';
export 'src/data/database/playbook_database.dart' hide Playbook;
export 'src/data/repositories/playbook_repository.dart';
export 'src/domain/playbook_models.dart';
export 'src/domain/playbook_ports.dart';
export 'src/features/playbook/models/playbook.dart';
export 'src/features/playbook/viewmodels/playbook_viewmodel.dart';
export 'src/features/playbook/views/playbook_screen.dart';
export 'src/presentation/playbook_feature_scope.dart';
