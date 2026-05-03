import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/background_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import 'home_screen.dart';

class StartupScreen extends StatelessWidget {
  const StartupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final storage = context.watch<StorageService>();

    if (!storage.initialized) {
      return const Scaffold(
        body: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (!storage.powerGuideSeen) {
      return const PowerGuideScreen();
    }

    return const HomeScreen();
  }
}

class PowerGuideScreen extends StatefulWidget {
  const PowerGuideScreen({super.key});

  @override
  State<PowerGuideScreen> createState() => _PowerGuideScreenState();
}

class _PowerGuideScreenState extends State<PowerGuideScreen> {
  bool _isExempt = false;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    try {
      final exempt =
          await BackgroundServiceManager.isIgnoringBatteryOptimizations()
              .timeout(const Duration(seconds: 2));
      if (mounted) {
        setState(() => _isExempt = exempt);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isExempt = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('后台保活设置')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Icon(
              Icons.battery_saver_outlined,
              size: 56,
              color: AppTheme.terminalGreen,
            ),
            const SizedBox(height: 20),
            const Text(
              '开启后台耗电无限制',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Text(
              'SSH 连接需要在后台持续运行前台服务和保活心跳。请把 SSH Mobile 设置为允许后台运行、后台耗电无限制，并允许忽略电池优化。',
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: Colors.grey[300],
              ),
            ),
            const SizedBox(height: 24),
            _StatusTile(isExempt: _isExempt),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () async {
                await BackgroundServiceManager
                        .requestBatteryOptimizationExemption()
                    .timeout(const Duration(seconds: 2), onTimeout: () {});
                await _refreshStatus();
              },
              icon: const Icon(Icons.power_settings_new),
              label: const Text('允许忽略电池优化'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: BackgroundServiceManager.openAppSettings,
              icon: const Icon(Icons.settings_outlined),
              label: const Text('打开应用设置'),
            ),
            const SizedBox(height: 20),
            Text(
              'vivo 手机通常还需要：设置 > 电池 > 后台耗电管理 > SSH Mobile > 允许后台高耗电。',
              style: TextStyle(
                fontSize: 13,
                height: 1.45,
                color: Colors.grey[400],
              ),
            ),
            const SizedBox(height: 28),
            TextButton(
              onPressed: () async {
                await context.read<StorageService>().markPowerGuideSeen();
              },
              child: const Text('我已设置，进入应用'),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusTile extends StatelessWidget {
  final bool isExempt;

  const _StatusTile({required this.isExempt});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF30363D)),
      ),
      child: Row(
        children: [
          Icon(
            isExempt ? Icons.check_circle_outline : Icons.info_outline,
            color: isExempt ? AppTheme.terminalGreen : AppTheme.terminalAmber,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              isExempt ? '已允许忽略电池优化' : '尚未确认电池优化豁免',
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}
