import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:app_ui/app_ui.dart';

import '../../domain/lan_share_ports.dart';
import 'services/lan_receiver_coordinator.dart';
import 'viewmodels/lan_share_viewmodel.dart';

/// Provides the shared, lazily-created LAN page runtime to LAN routes.
///
/// The receiver coordinator owns the HTTPS/mDNS runtime for the application
/// lifetime. This scope only exposes its single page ViewModel, so routes do
/// not bind a second listener or dispose the shared receiver.
class LanShareFeatureScope extends StatefulWidget {
  final Widget child;

  const LanShareFeatureScope({super.key, required this.child});

  @override
  State<LanShareFeatureScope> createState() => _LanShareFeatureScopeState();
}

class _LanShareFeatureScopeState extends State<LanShareFeatureScope> {
  LanShareViewModel? _inheritedViewModel;
  LanReceiverCoordinator? _coordinator;
  Future<LanShareViewModel>? _viewModelFuture;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    try {
      _inheritedViewModel = context.read<LanShareViewModel>();
      return;
    } on ProviderNotFoundException {
      _inheritedViewModel = null;
    }

    final coordinator = context.read<LanReceiverCoordinator>();
    if (!identical(_coordinator, coordinator)) {
      _coordinator = coordinator;
      _viewModelFuture = coordinator.ensureViewModel();
    }
  }

  void _retry() {
    setState(() {
      _viewModelFuture = _coordinator!.ensureViewModel();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_inheritedViewModel != null) return widget.child;
    final strings = context.select<LanShareSettingsPort, LanShareStrings>(
      (settings) => settings.strings,
    );

    return FutureBuilder<LanShareViewModel>(
      future: _viewModelFuture,
      builder: (context, snapshot) {
        final viewModel = snapshot.data;
        if (viewModel != null) {
          return ChangeNotifierProvider<LanShareViewModel>.value(
            value: viewModel,
            child: widget.child,
          );
        }
        if (snapshot.hasError) {
          return Scaffold(
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.wifi_off_rounded, size: 40),
                      const SizedBox(height: 12),
                      Text(
                        strings.lanShareInitializationFailed,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: _retry,
                        child: Text(strings.retry),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
        return Scaffold(
          body: AppSkeletonizer.zone(
            enabled: true,
            semanticsLabel: strings.lanShare,
            child: const AppSkeletonList(hasLeading: true, itemCount: 6),
          ),
        );
      },
    );
  }
}
