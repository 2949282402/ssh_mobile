import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:connection_core/connection_core.dart';
import '../../services/performance_monitor_service.dart';
import '../../services/system_admin_service.dart';
import 'viewmodels/system_admin_viewmodel.dart';
import '../performance/performance.dart';

class SystemAdminFeatureScope extends StatelessWidget {
  final Widget child;

  const SystemAdminFeatureScope({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (context) => SystemAdminService(
            connectionRepository: context.read<ConnectionRepository>(),
            credentialRepository: context.read<CredentialRepository>(),
            hostKeyRepository: context.read<HostKeyRepository>(),
          ),
        ),
        ChangeNotifierProvider(
          create: (context) => SystemAdminViewModel(
            adminService: context.read<SystemAdminService>(),
            connectionRepository: context.read<ConnectionRepository>(),
          ),
        ),
        ChangeNotifierProvider(
          create: (context) => PerformanceMonitorViewModel(
            monitorService: context.read<PerformanceMonitorService>(),
          ),
        ),
      ],
      child: child,
    );
  }
}
