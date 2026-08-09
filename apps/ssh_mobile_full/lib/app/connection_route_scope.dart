import 'package:connection_core/connection_core.dart' as connection_core;
import 'package:feature_connection/feature_connection.dart'
    as feature_connection;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import '../services/app_settings.dart';
import 'connection_ui_adapters.dart';

/// Add/Edit 路由复用现有 Connection ViewModel 时使用的参数对象。
final class AppConnectionEditRouteArguments {
  /// 创建一个绑定到指定连接和 ViewModel 的编辑路由参数。
  const AppConnectionEditRouteArguments({
    required this.connectionId,
    required this.viewModel,
  });

  /// 要编辑的连接 ID。
  final String connectionId;

  /// Home 路由持有的 Connection ViewModel。
  final feature_connection.ConnectionViewModel viewModel;
}

/// Connection Feature 的路由级 Provider 边界。
///
/// AppRuntime 只持有数据库和 Repository；本 Scope 创建并释放
/// [feature_connection.ConnectionViewModel]，避免把页面状态提升到 App 根
/// Provider。Add/Edit、Home 和 SFTP 页面可以通过 [viewModel] 复用同一个路由
/// ViewModel，但传入的实例由外层 Scope 负责释放。
final class AppConnectionRouteScope extends StatelessWidget {
  /// 创建一个注入 Connection 公共契约的路由 Scope。
  const AppConnectionRouteScope({
    super.key,
    required this.connectionRepository,
    required this.credentialRepository,
    required this.hostKeyRepository,
    required this.runtimePort,
    required this.verificationPort,
    required this.child,
    this.viewModel,
  });

  /// Connection 结构 Repository 的 App Scope 适配视图。
  final connection_core.ConnectionRepository connectionRepository;

  /// Connection 凭据 Repository 的 App Scope 适配视图。
  final connection_core.CredentialRepository credentialRepository;

  /// Host Key 信任 Repository 的 App Scope 适配视图。
  final connection_core.HostKeyRepository hostKeyRepository;

  /// 连接运行时行为的 App Shell Port。
  final feature_connection.ConnectionRuntimePort runtimePort;

  /// 连接验证行为的 App Shell Port。
  final feature_connection.ConnectionVerificationPort verificationPort;

  /// 被包裹的路由内容。
  final Widget child;

  /// 可选的外层 ViewModel；用于 Home 打开 Add/Edit 时保持列表快照一致。
  final feature_connection.ConnectionViewModel? viewModel;

  @override
  Widget build(BuildContext context) {
    final connectionProvider = viewModel == null
        ? ChangeNotifierProvider<feature_connection.ConnectionViewModel>(
            create: (_) => feature_connection.ConnectionViewModel(
              connectionRepository: connectionRepository,
              credentialRepository: credentialRepository,
              hostKeyRepository: hostKeyRepository,
              runtimePort: runtimePort,
              verificationPort: verificationPort,
            )..fetchConnections(),
          )
        : ChangeNotifierProvider<feature_connection.ConnectionViewModel>.value(
            value: viewModel!,
          );

    return MultiProvider(
      providers: <SingleChildWidget>[
        connectionProvider,
        ChangeNotifierProxyProvider<
          AppSettings,
          feature_connection.ConnectionStrings
        >(
          create: (_) => feature_connection.ConnectionStrings(),
          update: (_, settings, strings) {
            final next = strings ?? feature_connection.ConnectionStrings();
            next.setLanguage(
              settings.language == AppLanguage.en
                  ? feature_connection.ConnectionLanguage.english
                  : feature_connection.ConnectionLanguage.chinese,
            );
            return next;
          },
        ),
        Provider<feature_connection.ConnectionUiAdapter>.value(
          value: AppConnectionUiAdapter(),
        ),
      ],
      child: child,
    );
  }
}
