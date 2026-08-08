part of '../storage_service.dart';

extension StorageLifecycleOps on StorageService {
  Future<void> _initialize() async {
    try {
      await initializationCheckpoint?.call();
      _prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 3),
      );
      _powerGuideSeen =
          _prefs?.getBool(StorageService._powerGuideSeenKey) ?? false;
      await _loadSecretCacheSettings();
      await _loadConnections();
    } catch (e) {
      AppLogService.instance.error(
        'Failed to initialize storage service preferences',
        error: e,
      );
      _connections = [];
      _refreshConnectionsView();
      _powerGuideSeen = false;
    } finally {
      _initialized = true;
      if (!_initCompleter.isCompleted) {
        _initCompleter.complete();
      }
      notifyListeners();

      if (_disposed) {
        if (!_driftInitCompleter.isCompleted) {
          _driftInitCompleter.complete();
        }
      } else {
        final driftInitialization = _driftInitializationFuture ??=
            _initializeDriftStorage();
        if (!kIsWeb && Platform.environment.containsKey('FLUTTER_TEST')) {
          await driftInitialization;
        } else {
          // Asynchronously initialize Drift in production without blocking
          // cold start. shutdown() still awaits this exact shared future.
          unawaited(
            driftInitialization.catchError((e) {
              AppLogService.instance.error(
                'Asynchronous Drift initialization failed',
                error: e,
              );
            }),
          );
        }
      }
    }
  }

  void _beginShutdown() {
    if (_disposed) return;
    _disposed = true;
    for (final pending in _pendingProtectedPrefWrites.values) {
      pending.timer?.cancel();
    }
  }

  Future<void> _shutdownStorage() async {
    try {
      final initialization = _initializationFuture;
      if (initialization != null) {
        await initialization;
      } else if (!_initCompleter.isCompleted) {
        _initCompleter.complete();
      }

      final driftInitialization = _driftInitializationFuture;
      if (driftInitialization != null) {
        await driftInitialization;
      } else if (!_driftInitCompleter.isCompleted) {
        _driftInitCompleter.complete();
      }

      try {
        await flushPendingWrites();
      } catch (e, stackTrace) {
        AppLogService.instance.error(
          'Failed to flush storage while shutting down',
          error: e,
          stackTrace: stackTrace,
        );
      }

      final database = _database;
      if (database != null) {
        try {
          await AppLogService.instance.detachDatabase(database);
        } catch (e, stackTrace) {
          AppLogService.instance.error(
            'Failed to detach app log database while shutting down',
            error: e,
            stackTrace: stackTrace,
          );
        }

        if (_ownsDatabase) {
          await database.close();
        }

        if (identical(_database, database)) {
          _database = null;
        }
      }
    } finally {
      _ownsDatabase = false;
      _driftReady = false;
      _driftTerminalHistoryActive = false;
      _driftPlaybooksActive = false;
      _driftSftpHistoryActive = false;
    }
  }
}
