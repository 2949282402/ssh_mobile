import 'package:app_ui/app_ui.dart';
import 'package:feature_mcp/feature_mcp.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ssh_mobile/services/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test('loads persisted core settings and normalizes values', () async {
    SharedPreferences.setMockInitialValues({
      'app_language': 'en',
      'theme_mode': 'dark',
      'sftp_download_limit_bytes': 1,
      'sftp_text_preview_limit_bytes': 3 * 1024 * 1024 * 1024,
      'sftp_rich_preview_limit_bytes': 1024 * 1024,
      'sftp_text_edit_limit_bytes': 128 * 1024,
      'rag_enabled': true,
      'rag_search_mode': 'hybrid',
      'rag_top_n': 8,
      'show_server_names_in_notifications': true,
      'mcp_server_enabled': true,
      'mcp_server_host': '127.0.0.1',
      'mcp_server_port': 44000,
      'mcp_approval_mode': 'trustedAgent',
      'mcp_secondary_review_tools': <String>[' ssh_execute ', ''],
      'mcp_exposed_tools': <String>[' list_servers ', ''],
      'mcp_enable_sse': true,
      'oled_dark': true,
      'color_palette': 'ocean',
      'terminal_theme_id': 'solarized',
      'terminal_font_family': 'JetBrains Mono',
      'server_list_layout_mode': 'grid',
      'relay_endpoint': 'https://relay.example.test:8443/',
      'developer_mode': true,
      'developer_panel_floating': true,
      'power_guide_seen': true,
      'mcp_allow_write_tools': true,
    });
    FlutterSecureStorage.setMockInitialValues({
      'mcp_server_token': 'saved-token',
      'lan_device_id': 'secure-device-id',
    });

    final settings = AppSettings();
    addTearDown(settings.dispose);
    await settings.ensureCoreLoaded();

    expect(settings.language, AppLanguage.en);
    expect(settings.isEnglish, isTrue);
    expect(settings.themeMode, ThemeMode.dark);
    expect(settings.isDarkMode, isTrue);
    expect(settings.sftpDownloadLimitBytes, AppSettings.minSftpLimitBytes);
    expect(settings.sftpTextPreviewLimitBytes, AppSettings.maxSftpLimitBytes);
    expect(settings.sftpRichPreviewLimitBytes, 1024 * 1024);
    expect(settings.sftpTextEditLimitBytes, 128 * 1024);
    expect(settings.ragEnabled, isTrue);
    expect(settings.ragSearchMode, 'hybrid');
    expect(settings.ragTopN, 8);
    expect(settings.showServerNamesInNotifications, isTrue);
    expect(settings.mcpServerEnabled, isTrue);
    expect(settings.mcpServerHost, '127.0.0.1');
    expect(settings.mcpServerPort, 44000);
    expect(settings.mcpApprovalMode, McpApprovalMode.trustedAgent);
    expect(settings.mcpSecondaryReviewTools, {'ssh_execute'});
    expect(settings.mcpExposedTools, {'list_servers'});
    expect(settings.mcpExposureToolsConfigured, isTrue);
    expect(settings.mcpEnableSse, isTrue);
    expect(settings.oledDark, isTrue);
    expect(settings.colorPalette, AppColorPalette.ocean);
    expect(settings.terminalThemeId, 'solarized');
    expect(settings.terminalFontFamily, 'JetBrains Mono');
    expect(settings.serverListLayoutMode, 'grid');
    expect(settings.relayEndpoint, 'https://relay.example.test:8443');
    expect(settings.relayHost, 'relay.example.test');
    expect(settings.relayPort, 8443);
    expect(settings.developerMode, isTrue);
    expect(settings.developerPanelFloating, isTrue);
    expect(settings.powerGuideSeen, isTrue);
    expect(
      settings.visualSettings,
      const AppVisualSettingsSnapshot(
        themeMode: ThemeMode.dark,
        oledDark: true,
        colorPalette: AppColorPalette.ocean,
      ),
    );

    await settings.ensureMcpToken();
    expect(settings.mcpServerToken, 'saved-token');
    await settings.ensureLanIdentity();
    expect(settings.lanDeviceId, 'secure-device-id');
    expect(settings.lanDeviceAlias, isNotEmpty);
    expect(settings.initialized, isFalse);
  });

  test(
    'setter APIs persist values, notify once, and remain idempotent',
    () async {
      final settings = AppSettings();
      addTearDown(settings.dispose);
      await settings.ensureCoreLoaded();
      var notifications = 0;
      settings.addListener(() => notifications++);

      await settings.toggleLanguage();
      expect(settings.language, AppLanguage.en);
      await settings.markPowerGuideSeen();
      await settings.markPowerGuideSeen();
      await settings.setLanDeviceAlias('  Workstation  ');
      await settings.setLanDeviceAlias('  Workstation  ');
      await settings.setRelayEndpoint('');
      await settings.setRelayServer(host: 'relay.example.test', port: 8443);
      await settings.setRagEnabled(true);
      await settings.setRagSearchMode('vector');
      await settings.setRagTopN(9);
      await settings.setShowServerNamesInNotifications(true);
      await settings.setMcpServerHost('localhost');
      await settings.setMcpServerPort(45000);
      await settings.setMcpApprovalMode(McpApprovalMode.trustedAgent);
      await settings.setMcpSecondaryReviewTools({' z ', '', 'a'});
      await settings.setMcpToolSecondaryReview('z', false);
      await settings.setMcpToolSecondaryReview('new_tool', true);
      await settings.setMcpExposedTools({' z ', '', 'a'});
      await settings.setMcpToolExposure(
        'a',
        false,
        availableToolNames: const {},
      );
      await settings.setMcpEnableSse(true);
      await settings.setMcpServerEnabled(true);
      await settings.setOledDark(true);
      await settings.setColorPalette(AppColorPalette.emerald);
      await settings.setTerminalThemeId('high-contrast');
      await settings.setTerminalFontFamily('  Fira Code  ');
      await settings.setServerListLayoutMode('compact');
      await settings.setDeveloperMode(true);
      await settings.setDeveloperPanelFloating(true);

      settings.toggleTheme();
      settings.setThemeMode(ThemeMode.system);
      await Future<void>.delayed(Duration.zero);

      await settings.setSftpDownloadLimitBytes(1);
      await settings.setSftpTextPreviewLimitBytes(
        AppSettings.maxSftpLimitBytes + 1,
      );
      await settings.setSftpRichPreviewLimitBytes(0);
      await settings.setSftpTextEditLimitBytes(128 * 1024);

      expect(settings.lanDeviceAlias, '  Workstation  ');
      expect(settings.relayHost, 'relay.example.test');
      expect(settings.relayPort, 8443);
      expect(settings.ragEnabled, isTrue);
      expect(settings.ragSearchMode, 'vector');
      expect(settings.ragTopN, 9);
      expect(settings.showServerNamesInNotifications, isTrue);
      expect(settings.mcpServerHost, 'localhost');
      expect(settings.mcpServerPort, 45000);
      expect(settings.mcpSecondaryReviewTools, {'a', 'new_tool'});
      expect(settings.mcpExposedTools, {'z'});
      expect(settings.mcpEnableSse, isTrue);
      expect(settings.mcpServerEnabled, isTrue);
      expect(settings.mcpServerToken, isNotEmpty);
      expect(settings.oledDark, isTrue);
      expect(settings.colorPalette, AppColorPalette.emerald);
      expect(settings.terminalThemeId, 'high-contrast');
      expect(settings.terminalFontFamily, 'Fira Code');
      expect(settings.serverListLayoutMode, 'compact');
      expect(settings.developerMode, isTrue);
      expect(settings.developerPanelFloating, isTrue);
      expect(settings.sftpDownloadLimitBytes, AppSettings.minSftpLimitBytes);
      expect(settings.sftpTextPreviewLimitBytes, AppSettings.maxSftpLimitBytes);
      expect(
        settings.sftpRichPreviewLimitBytes,
        AppSettings.defaultSftpRichPreviewLimitBytes,
      );
      expect(settings.sftpTextEditLimitBytes, 128 * 1024);
      expect(notifications, greaterThan(10));

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('relay_endpoint'),
        'https://relay.example.test:8443',
      );
      expect(prefs.getString('theme_mode'), 'system');
      expect(prefs.getBool('dark_mode'), isFalse);
      expect(prefs.getStringList('mcp_secondary_review_tools'), [
        'a',
        'new_tool',
      ]);
      expect(prefs.getStringList('mcp_exposed_tools'), ['z']);
    },
  );

  test('rejects unsafe endpoints and MCP values', () async {
    final settings = AppSettings();
    addTearDown(settings.dispose);
    await settings.ensureCoreLoaded();

    await expectLater(
      settings.setRelayEndpoint('http://relay.example.test'),
      throwsArgumentError,
    );
    await expectLater(
      settings.setRelayEndpoint('https://user@relay.example.test'),
      throwsArgumentError,
    );
    await expectLater(
      settings.setRelayServer(host: 'https://relay.example.test', port: 443),
      throwsArgumentError,
    );
    await expectLater(
      settings.setRelayServer(host: 'relay.example.test', port: 0),
      throwsArgumentError,
    );
    await expectLater(
      settings.setMcpServerHost('0.0.0.0'),
      throwsArgumentError,
    );
    await expectLater(settings.setMcpServerPort(80), throwsArgumentError);

    await settings.setMcpToolExposure(
      '  ',
      true,
      availableToolNames: {'run_command'},
    );
    expect(settings.mcpExposureToolsConfigured, isFalse);
  });

  test(
    'initializes LAN identity from preferences and generates tokens',
    () async {
      SharedPreferences.setMockInitialValues({
        'lan_device_id': 'prefs-device-id',
        'lan_device_alias': 'Saved laptop',
      });
      final settings = AppSettings();
      addTearDown(settings.dispose);

      await settings.ensureLanIdentity();
      expect(settings.lanDeviceId, 'prefs-device-id');
      expect(settings.lanDeviceAlias, 'Saved laptop');

      final token = await settings.ensureMcpServerToken();
      expect(token, isNotEmpty);
      expect(token, settings.mcpServerToken);
      expect(await settings.regenerateMcpServerToken(), isNot(token));
      expect(settings.mcpServerToken, isNotEmpty);
    },
  );

  test('falls back to safe defaults after malformed preferences', () async {
    SharedPreferences.setMockInitialValues({
      'sftp_download_limit_bytes': 'not-an-int',
    });
    final settings = AppSettings();
    addTearDown(settings.dispose);

    await settings.ensureCoreLoaded();

    expect(settings.language, AppLanguage.zh);
    expect(settings.themeMode, ThemeMode.light);
    expect(
      settings.sftpDownloadLimitBytes,
      AppSettings.defaultSftpDownloadLimitBytes,
    );
    expect(settings.ragEnabled, isFalse);
    expect(settings.mcpServerHost, McpServerSettings.defaultHost);
    expect(settings.colorPalette, AppColorPalette.monochrome);
    expect(settings.coreLoaded, isTrue);
  });
}
