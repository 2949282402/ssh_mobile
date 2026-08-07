part of '../llm_chat_screen.dart';

Future<Set<String>?> showTargetServerPickerSheet({
  required BuildContext context,
  required List<ConnectionConfig> connections,
  required Set<String> initialSelection,
  required AiStrings strings,
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  return showModalBottomSheet<Set<String>?>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    elevation: 0,
    shape: const RoundedRectangleBorder(),
    builder: (sheetContext) {
      final media = MediaQuery.of(sheetContext);
      final visibleHeight = (media.size.height - media.viewInsets.bottom)
          .clamp(0.0, media.size.height)
          .toDouble();
      final preferredHeight = media.size.height * 0.7;
      final sheetHeight = preferredHeight < visibleHeight
          ? preferredHeight
          : visibleHeight;
      return AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 640, maxHeight: sheetHeight),
            child: TargetServerPickerSheet(
              connections: connections,
              initialSelection: initialSelection,
              strings: strings,
            ),
          ),
        ),
      );
    },
  );
}

class TargetServerPickerSheet extends StatefulWidget {
  final List<ConnectionConfig> connections;
  final Set<String> initialSelection;
  final AiStrings strings;

  const TargetServerPickerSheet({
    super.key,
    required this.connections,
    required this.initialSelection,
    required this.strings,
  });

  @override
  State<TargetServerPickerSheet> createState() =>
      _TargetServerPickerSheetState();
}

class _TargetServerPickerSheetState extends State<TargetServerPickerSheet> {
  late final Set<String> _selected;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    final availableIds = widget.connections
        .map((connection) => connection.id)
        .toSet();
    _selected = widget.initialSelection.where(availableIds.contains).toSet();
  }

  void _close([Set<String>? result]) {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).pop(result == null ? null : Set<String>.from(result));
  }

  void _setSelected(ConnectionConfig connection, {required bool selected}) {
    setState(() {
      if (selected) {
        _selected.add(connection.id);
      } else {
        _selected.remove(connection.id);
      }
    });
  }

  Widget _buildClearButton() {
    return SizedBox(
      key: const ValueKey('server-selector-clear'),
      height: 48,
      child: TextButton(
        onPressed: _selected.isEmpty ? null : () => setState(_selected.clear),
        child: Text(widget.strings.clearAll),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final media = MediaQuery.of(context);
    final compact =
        media.size.width < 360 ||
        media.size.height - media.viewInsets.bottom < 300;

    return Material(
      color: colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        side: BorderSide(color: colorScheme.outline),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 8 : 14,
            compact ? 4 : 8,
            compact ? 8 : 14,
            compact ? 4 : 12,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!compact) ...[
                Container(
                  width: 34,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: 6),
              ],
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        widget.strings.selectTargetServers,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: compact
                            ? theme.textTheme.titleMedium
                            : theme.textTheme.titleLarge,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      widget.strings.selectedServers(_selected.length),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (!compact) ...[
                    const SizedBox(width: 8),
                    _buildClearButton(),
                  ],
                ],
              ),
              SizedBox(height: compact ? 2 : 6),
              Flexible(
                child: ListView.builder(
                  key: const ValueKey('server-selector-list'),
                  shrinkWrap: true,
                  itemCount: widget.connections.length,
                  itemBuilder: (context, index) {
                    final connection = widget.connections[index];
                    final selected = _selected.contains(connection.id);
                    final name = connection.name.trim().isEmpty
                        ? widget.strings.serverTarget
                        : connection.name.trim();
                    final address = _targetServerAddress(connection);
                    return Semantics(
                      key: ValueKey('server-option-${connection.id}'),
                      container: true,
                      label: '$name, $address',
                      checked: selected,
                      onTap: () =>
                          _setSelected(connection, selected: !selected),
                      child: ExcludeSemantics(
                        child: CheckboxListTile(
                          value: selected,
                          visualDensity: VisualDensity.standard,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                          ),
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            address,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onChanged: (value) =>
                              _setSelected(connection, selected: value == true),
                        ),
                      ),
                    );
                  },
                ),
              ),
              SizedBox(height: compact ? 2 : 6),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (compact) _buildClearButton(),
                  SizedBox(
                    key: const ValueKey('server-selector-cancel'),
                    height: 48,
                    child: TextButton(
                      onPressed: _closing ? null : _close,
                      child: Text(widget.strings.cancel),
                    ),
                  ),
                  SizedBox(
                    key: const ValueKey('server-selector-save'),
                    height: 48,
                    child: FilledButton(
                      onPressed: _closing ? null : () => _close(_selected),
                      child: Text(widget.strings.save),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _targetServerAddress(ConnectionConfig connection) {
  final rawHost = connection.host.trim();
  final bracketed = rawHost.startsWith('[') && rawHost.endsWith(']');
  final host = rawHost.contains(':') && !bracketed ? '[$rawHost]' : rawHost;
  return '${connection.username}@$host:${connection.port}';
}
