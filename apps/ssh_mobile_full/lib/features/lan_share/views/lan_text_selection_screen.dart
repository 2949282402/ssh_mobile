import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/app_settings.dart';
import 'package:app_ui/app_ui.dart';

class LanTextSelectionScreen extends StatelessWidget {
  const LanTextSelectionScreen({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final strings = AppStrings(settings.language);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.lanShareSelectToCopy),
        centerTitle: true,
      ),
      body: AppPageSurface(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: SizedBox(
            width: double.infinity,
            child: SelectableText(
              text,
              style: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
            ),
          ),
        ),
      ),
    );
  }
}
