part of '../ai_tool_service.dart';

extension _ServerTools on AiToolService {
  Future<String> _getServerDetails(Map<String, dynamic> arguments) async {
    final details = serverCatalogService.getServerDetails(
      _arg(arguments, 'connectionId'),
    );
    if (details == null) {
      return jsonEncode({'error': 'Connection config not found.'});
    }
    return jsonEncode(details);
  }

  Future<String> _updateServerMetadata(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Server metadata changes require user approval.',
      });
    }
    final connectionId = _arg(arguments, 'connectionId');
    final changes = Map<String, dynamic>.from(arguments)
      ..remove('connectionId');
    if (changes.isEmpty) {
      return jsonEncode({
        'updated': false,
        'error': 'No metadata fields were provided to update.',
      });
    }
    return jsonEncode(
      await serverCatalogService.updateServerMetadata(
        connectionId: connectionId,
        changes: changes,
      ),
    );
  }

  Future<String> _deleteServer(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Deleting a saved server requires user approval.',
      });
    }
    return jsonEncode(
      await serverCatalogService.deleteServer(_arg(arguments, 'connectionId')),
    );
  }

  Future<String> _reorderServers(
    Map<String, dynamic> arguments, {
    required bool approvedWrite,
  }) async {
    if (!approvedWrite) {
      return jsonEncode({
        'error': 'Reordering saved servers requires user approval.',
      });
    }
    return jsonEncode(
      await serverCatalogService.reorderServers(
        _stringList(arguments['orderedIds']),
      ),
    );
  }

  Future<String> _detectOsTool(Map<String, dynamic> arguments) async {
    return jsonEncode(
      await serverDiagnosticsService.detectOs(_arg(arguments, 'connectionId')),
    );
  }

  Future<String> _serverStatus(Map<String, dynamic> arguments) async {
    final connectionId = _arg(arguments, 'connectionId');
    final mode = _optionalString(arguments, 'mode')?.toLowerCase();
    return jsonEncode(
      await serverDiagnosticsService.getStatus(
        connectionId: connectionId,
        mode: mode,
      ),
    );
  }

  Future<String> _opsReport(Map<String, dynamic> arguments) async {
    return jsonEncode(
      await serverDiagnosticsService.generateOpsReport(
        _arg(arguments, 'connectionId'),
      ),
    );
  }
}
