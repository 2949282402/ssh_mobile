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

  test(
    'loads invalid and legacy persisted values with safe fallbacks',
    () async {
      SharedPreferences.setMockInitialValues({
        'app_language': 'unknown',
        'theme_mode': 'unknown',
        'dark_mode': true,
        'sftp_download_limit_bytes': 0,
        'sftp_text_preview_limit_bytes': -1,
        'sftp_rich_preview_limit_bytes': AppSettings.maxSftpLimitBytes,
        'sftp_text_edit_limit_bytes': AppSettings.minSftpLimitBytes,
        'mcp_server_host': '0.0.0.0',
        'mcp_server_port': -10,
        'mcp_approval_mode': 'not-a-mode',
        'mcp_allow_write_tools': false,
        'mcp_require_approval_for_write_tools': true,
        'mcp_secondary_review_tools': <String>[' first ', '', 'second'],
        'mcp_exposed_tools': <String>[],
        'color_palette': 'not-a-palette',
        'relay_endpoint': 'http://insecure.test/path',
        'server_list_layout_mode': 'grid',
      });
      final settings = AppSettings();
      addTearDown(settings.dispose);

      await settings.ensureCoreLoaded();
      await settings.ensureCoreLoaded();
      expect(settings.language, AppLanguage.zh);
      expect(settings.themeMode, ThemeMode.dark);
      expect(settings.mcpServerHost, McpServerSettings.defaultHost);
      expect(settings.mcpServerPort, McpServerSettings.defaultPort);
      expect(settings.mcpApprovalMode, McpApprovalMode.reviewConfiguredTools);
      expect(settings.mcpSecondaryReviewTools, {'first', 'second'});
      expect(settings.mcpExposedTools, isEmpty);
      expect(settings.mcpExposureToolsConfigured, isTrue);
      expect(settings.colorPalette, AppColorPalette.monochrome);
      expect(settings.relayEndpoint, isEmpty);
      expect(settings.relayHost, isEmpty);
      expect(settings.relayPort, 443);
      expect(settings.serverListLayoutMode, 'grid');
    },
  );

  test(
    'loads valid persisted values and exposes the complete settings snapshot',
    () async {
      SharedPreferences.setMockInitialValues({
        'app_language': 'en',
        'theme_mode': 'dark',
        'mcp_server_host': 'LOCALHOST',
        'mcp_server_port': 45000,
        'relay_endpoint': 'https://relay.example.test///',
        'oled_dark': true,
        'color_palette': 'ocean',
        'terminal_theme_id': 'solarized',
        'terminal_font_family': 'Fira Code',
        'show_server_names_in_notifications': true,
        'sftp_rich_preview_limit_bytes': 2 * 1024 * 1024,
        'mcp_server_enabled': true,
      });
      FlutterSecureStorage.setMockInitialValues({'mcp_server_token': 'saved'});

      final settings = AppSettings();
      addTearDown(settings.dispose);
      await settings.ensureCoreLoaded();
      await settings.ensureMcpToken();

      expect(settings.isEnglish, isTrue);
      expect(settings.isDarkMode, isTrue);
      expect(settings.showServerNamesInNotifications, isTrue);
      expect(settings.sftpRichPreviewLimitBytes, 2 * 1024 * 1024);
      expect(settings.mcpServerEnabled, isTrue);
      expect(settings.mcpServerHost, 'localhost');
      expect(settings.mcpServerPort, 45000);
      expect(settings.mcpServerToken, 'saved');
      expect(settings.oledDark, isTrue);
      expect(settings.colorPalette, AppColorPalette.ocean);
      expect(settings.terminalThemeId, 'solarized');
      expect(settings.terminalFontFamily, 'Fira Code');
      expect(
        settings.visualSettings,
        const AppVisualSettingsSnapshot(
          themeMode: ThemeMode.dark,
          oledDark: true,
          colorPalette: AppColorPalette.ocean,
        ),
      );
      expect(
        settings.visualSettings.hashCode,
        const AppVisualSettingsSnapshot(
          themeMode: ThemeMode.dark,
          oledDark: true,
          colorPalette: AppColorPalette.ocean,
        ).hashCode,
      );
    },
  );

  test(
    'all setting APIs preserve state on no-op and persist transitions',
    () async {
      final settings = AppSettings();
      addTearDown(settings.dispose);
      await settings.ensureCoreLoaded();
      await settings.ensureLanIdentity();
      await settings.init();
      expect(settings.initialized, isTrue);
      await settings.initFuture;
      await settings.markPowerGuideSeen();
      await settings.setMcpExposedTools(const {});

      final initialNotifications = <int>[0];
      settings.addListener(() => initialNotifications[0]++);

      await settings.setLanDeviceAlias(settings.lanDeviceAlias);
      await settings.setLanDeviceAlias('workstation');
      expect(settings.lanDeviceAlias, 'workstation');
      await settings.markPowerGuideSeen();
      await settings.setRelayEndpoint('');
      await settings.setRagEnabled(false);
      await settings.setRagSearchMode('bm25');
      await settings.setRagTopN(3);
      await settings.setShowServerNamesInNotifications(false);
      await settings.setMcpServerHost(McpServerSettings.defaultHost);
      await settings.setMcpServerPort(McpServerSettings.defaultPort);
      await settings.setMcpApprovalMode(McpApprovalMode.reviewConfiguredTools);
      await settings.setMcpSecondaryReviewTools(
        settings.mcpSecondaryReviewTools,
      );
      await settings.setMcpExposedTools(const {});
      await settings.setMcpEnableSse(false);
      await settings.setMcpServerEnabled(false);
      await settings.setOledDark(false);
      await settings.setColorPalette(AppColorPalette.monochrome);
      await settings.setTerminalThemeId('default');
      await settings.setTerminalFontFamily('');
      await settings.setServerListLayoutMode('list');
      await settings.setDeveloperMode(false);
      await settings.setDeveloperPanelFloating(false);
      await settings.setSftpDownloadLimitBytes(
        AppSettings.defaultSftpDownloadLimitBytes,
      );
      await settings.setSftpTextPreviewLimitBytes(
        AppSettings.defaultSftpTextPreviewLimitBytes,
      );
      await settings.setSftpRichPreviewLimitBytes(
        AppSettings.defaultSftpRichPreviewLimitBytes,
      );
      await settings.setSftpTextEditLimitBytes(
        AppSettings.defaultSftpTextEditLimitBytes,
      );
      expect(initialNotifications[0], 1);

      await settings.setRelayEndpoint('  https://relay.example.test///  ');
      expect(settings.relayEndpoint, 'https://relay.example.test');
      await settings.setRelayServer(host: '[::1]', port: 9443);
      expect(settings.relayHost, '::1');
      expect(settings.relayPort, 9443);
      await settings.setRagEnabled(true);
      await settings.setRagSearchMode('hybrid');
      await settings.setRagTopN(10);
      await settings.setShowServerNamesInNotifications(true);
      await settings.setMcpServerHost('localhost');
      expect(settings.mcpServerHost, 'localhost');
      await settings.setMcpServerPort(45000);
      await settings.setMcpApprovalMode(McpApprovalMode.trustedAgent);
      await settings.setMcpSecondaryReviewTools({' z ', 'a'});
      await settings.setMcpExposedTools({'tool-a'});
      await settings.setMcpToolExposure(
        'tool-b',
        true,
        availableToolNames: {'tool-a', ' tool-b ', ''},
      );
      await settings.setMcpToolExposure(
        'tool-a',
        false,
        availableToolNames: const {},
      );
      await settings.setMcpToolSecondaryReview('review-me', true);
      await settings.setMcpToolSecondaryReview('review-me', false);
      await settings.setMcpEnableSse(true);
      await settings.setMcpServerEnabled(true);
      await settings.setOledDark(true);
      await settings.setColorPalette(AppColorPalette.ocean);
      await settings.setTerminalThemeId('solarized');
      await settings.setTerminalFontFamily('  Fira Code  ');
      await settings.setServerListLayoutMode('compact');
      await settings.setDeveloperMode(true);
      await settings.setDeveloperPanelFloating(true);
      await settings.setSftpDownloadLimitBytes(1);
      await settings.setSftpTextPreviewLimitBytes(
        AppSettings.maxSftpLimitBytes + 1,
      );
      await settings.setSftpRichPreviewLimitBytes(0);
      await settings.setSftpTextEditLimitBytes(AppSettings.minSftpLimitBytes);

      settings.toggleTheme();
      settings.setThemeMode(ThemeMode.system);
      await Future<void>.delayed(Duration.zero);

      expect(settings.relayEndpoint, 'https://[::1]:9443');
      expect(settings.ragSearchMode, 'hybrid');
      expect(settings.mcpExposedTools, {'tool-b'});
      expect(settings.mcpSecondaryReviewTools, {'a', 'z'});
      expect(settings.mcpEnableSse, isTrue);
      expect(settings.developerMode, isTrue);
      expect(settings.sftpDownloadLimitBytes, AppSettings.minSftpLimitBytes);
      expect(settings.sftpTextPreviewLimitBytes, AppSettings.maxSftpLimitBytes);
    },
  );

  test(
    'validates relay and MCP input before touching persisted settings',
    () async {
      final settings = AppSettings();
      addTearDown(settings.dispose);
      await settings.ensureCoreLoaded();

      for (final endpoint in [
        'http://relay.test',
        'https://user@relay.test',
        'https://relay.test/path',
        'https://relay.test?token=secret',
      ]) {
        await expectLater(
          settings.setRelayEndpoint(endpoint),
          throwsArgumentError,
        );
      }
      for (final args in [
        (host: '', port: 443),
        (host: 'relay.test/path', port: 443),
        (host: 'https://relay.test', port: 443),
        (host: 'relay.test', port: 0),
        (host: 'relay.test', port: 65536),
      ]) {
        await expectLater(
          settings.setRelayServer(host: args.host, port: args.port),
          throwsArgumentError,
        );
      }
      await expectLater(
        settings.setMcpServerHost('0.0.0.0'),
        throwsArgumentError,
      );
      await expectLater(settings.setMcpServerPort(0), throwsArgumentError);
      await expectLater(settings.setMcpServerPort(65536), throwsArgumentError);
      expect(settings.relayEndpoint, isEmpty);
    },
  );

  test('reads secure and preference LAN identity sources', () async {
    SharedPreferences.setMockInitialValues({
      'lan_device_id': 'prefs-id',
      'lan_device_alias': 'saved-name',
    });
    FlutterSecureStorage.setMockInitialValues({'lan_device_id': 'secure-id'});
    final settings = AppSettings();
    addTearDown(settings.dispose);
    await settings.ensureLanIdentity();
    expect(settings.lanDeviceId, 'secure-id');
    expect(settings.lanDeviceAlias, 'saved-name');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('lan_device_id'), 'secure-id');
  });

  test('migrates a preference LAN id into secure storage', () async {
    SharedPreferences.setMockInitialValues({
      'lan_device_id': 'prefs-only-id',
      'lan_device_alias': 'saved-name',
    });
    final settings = AppSettings();
    addTearDown(settings.dispose);

    await settings.ensureLanIdentity();

    expect(settings.lanDeviceId, 'prefs-only-id');
    expect(settings.lanDeviceAlias, 'saved-name');
    final secure = const FlutterSecureStorage();
    expect(await secure.read(key: 'lan_device_id'), 'prefs-only-id');
  });
}
