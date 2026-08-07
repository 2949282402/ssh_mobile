part of '../sftp_editor_screen.dart';

class _EditorToolbar extends StatelessWidget {
  const _EditorToolbar({
    required this.strings,
    required this.fontSize,
    required this.wrapLines,
    required this.enabled,
    required this.onDecreaseFont,
    required this.onIncreaseFont,
    required this.onFontSizeChanged,
    required this.onToggleLineWrap,
  });

  final AppStrings strings;
  final double fontSize;
  final bool wrapLines;
  final bool enabled;
  final VoidCallback onDecreaseFont;
  final VoidCallback onIncreaseFont;
  final ValueChanged<double> onFontSizeChanged;
  final VoidCallback onToggleLineWrap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final wrapTooltip = wrapLines
        ? strings.disableLineWrap
        : strings.enableLineWrap;

    return Card(
      key: const ValueKey('sftp-editor-toolbar'),
      margin: EdgeInsets.zero,
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        label: strings.editorControls,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final showLabel = constraints.maxWidth >= 560;
              return Row(
                children: [
                  if (showLabel) ...[
                    Icon(
                      Icons.format_size_rounded,
                      size: 20,
                      color: colors.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      strings.editorFontSize,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(width: 8),
                  ],
                  IconButton(
                    key: const ValueKey('sftp-editor-font-decrease'),
                    tooltip: strings.smallerFont,
                    constraints: const BoxConstraints.tightFor(
                      width: 48,
                      height: 48,
                    ),
                    onPressed: enabled && fontSize > 10 ? onDecreaseFont : null,
                    icon: const Icon(Icons.text_decrease_rounded),
                  ),
                  Expanded(
                    child: Semantics(
                      key: const ValueKey('sftp-editor-font-slider'),
                      label: strings.editorFontSize,
                      value: strings.fontSizeValue(fontSize.round()),
                      child: Slider(
                        min: 10,
                        max: 28,
                        divisions: 18,
                        label: fontSize.toStringAsFixed(0),
                        value: fontSize,
                        onChanged: enabled ? onFontSizeChanged : null,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 38,
                    child: Text(
                      fontSize.toStringAsFixed(0),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('sftp-editor-font-increase'),
                    tooltip: strings.largerFont,
                    constraints: const BoxConstraints.tightFor(
                      width: 48,
                      height: 48,
                    ),
                    onPressed: enabled && fontSize < 28 ? onIncreaseFont : null,
                    icon: const Icon(Icons.text_increase_rounded),
                  ),
                  const SizedBox(width: 4),
                  Semantics(
                    key: const ValueKey('sftp-editor-line-wrap'),
                    container: true,
                    label: wrapTooltip,
                    button: true,
                    enabled: enabled,
                    toggled: wrapLines,
                    onTap: enabled ? onToggleLineWrap : null,
                    child: ExcludeSemantics(
                      child: IconButton(
                        tooltip: wrapTooltip,
                        constraints: const BoxConstraints.tightFor(
                          width: 48,
                          height: 48,
                        ),
                        style: IconButton.styleFrom(
                          backgroundColor: wrapLines
                              ? colors.primaryContainer
                              : Colors.transparent,
                          foregroundColor: wrapLines
                              ? colors.onPrimaryContainer
                              : colors.onSurfaceVariant,
                        ),
                        onPressed: enabled ? onToggleLineWrap : null,
                        icon: Icon(
                          wrapLines
                              ? Icons.wrap_text_rounded
                              : Icons.notes_rounded,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
