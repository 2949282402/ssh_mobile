import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/app_settings.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/app_surface.dart';

class TerminalSettingsScreen extends StatefulWidget {
  const TerminalSettingsScreen({super.key});

  @override
  State<TerminalSettingsScreen> createState() => _TerminalSettingsScreenState();
}

class _TerminalSettingsScreenState extends State<TerminalSettingsScreen> {
  final TextEditingController _fontController = TextEditingController();
  final FocusNode _fontFocusNode = FocusNode();
  Timer? _fontDebounce;
  String? _lastFont;

  @override
  void dispose() {
    _fontDebounce?.cancel();
    _fontController.dispose();
    _fontFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final strings = AppStrings(settings.language);
    if (_lastFont != settings.terminalFontFamily) {
      _lastFont = settings.terminalFontFamily;
      if (!_fontFocusNode.hasFocus) {
        _fontController.text = settings.terminalFontFamily;
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.terminalAppearance),
        leading: IconButton(
          tooltip: strings.close,
          onPressed: () => Navigator.maybePop(context),
          icon: const Icon(Icons.close_rounded),
        ),
      ),
      body: AppPageSurface(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(AppTheme.compactPagePadding),
            children: [
              AppSectionCard(
                title: strings.terminalTheme,
                child: DropdownButtonFormField<String>(
                  initialValue: settings.terminalThemeId,
                  decoration: InputDecoration(labelText: strings.terminalTheme),
                  items: [
                    DropdownMenuItem(
                      value: 'default',
                      child: Text(strings.defaultOption),
                    ),
                    const DropdownMenuItem(
                      value: 'monokai',
                      child: Text('Monokai'),
                    ),
                    const DropdownMenuItem(value: 'nord', child: Text('Nord')),
                    const DropdownMenuItem(
                      value: 'gruvbox',
                      child: Text('Gruvbox'),
                    ),
                    const DropdownMenuItem(
                      value: 'solarized',
                      child: Text('Solarized Dark'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      unawaited(settings.setTerminalThemeId(value));
                    }
                  },
                ),
              ),
              const SizedBox(height: 14),
              AppSectionCard(
                title: strings.customTerminalFont,
                subtitle: strings.customTerminalFontHint,
                child: TextField(
                  controller: _fontController,
                  focusNode: _fontFocusNode,
                  decoration: InputDecoration(
                    labelText: strings.customTerminalFont,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (value) {
                    _fontDebounce?.cancel();
                    _fontDebounce = Timer(
                      const Duration(milliseconds: 400),
                      () {
                        unawaited(settings.setTerminalFontFamily(value));
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
