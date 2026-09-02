// app_ui 的公开入口。
//
// 该包只提供跨 Feature 的视觉主题、响应式布局工具和通用 Widget；
// 不依赖任何具体 Feature、业务模型或应用级服务。

export 'src/theme/app_motion.dart';
export 'src/theme/app_spacing.dart';
export 'src/theme/app_theme.dart';
export 'src/theme/app_typography.dart';
export 'src/utils/responsive.dart';
export 'src/widgets/app_dialog.dart';
export 'src/widgets/app_loading.dart';
export 'src/widgets/app_server_selector.dart';
export 'src/widgets/app_skeletonizer.dart';
export 'src/widgets/app_surface.dart';
export 'src/widgets/app_terminal_skeleton.dart';
export 'src/widgets/app_toolbar.dart';
export 'src/widgets/connection_progress_dialog.dart';
export 'src/widgets/destructive_confirm_dialog.dart';
export 'src/widgets/overflow_scroll_text.dart';
export 'src/widgets/tactile_feedback.dart';
export 'package:skeletonizer/skeletonizer.dart' show Bone;
