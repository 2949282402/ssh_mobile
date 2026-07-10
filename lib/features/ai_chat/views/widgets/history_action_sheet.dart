import 'package:flutter/material.dart';

class HistoryActionSheet<T> extends StatelessWidget {
  final String title;
  final String emptyText;
  final String deleteTooltip;
  final List<T> items;
  final String Function(T value) labelBuilder;
  final String? selectedValue;
  final String Function(T value)? valueKeyBuilder;
  final ValueChanged<T> onSelect;
  final ValueChanged<T> onDelete;

  const HistoryActionSheet({
    super.key,
    required this.title,
    required this.emptyText,
    required this.deleteTooltip,
    required this.items,
    required this.labelBuilder,
    required this.onSelect,
    required this.onDelete,
    this.selectedValue,
    this.valueKeyBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                emptyText,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  final itemKey = valueKeyBuilder?.call(item);
                  final selected =
                      selectedValue != null &&
                      itemKey != null &&
                      itemKey == selectedValue;
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: selected
                        ? Icon(
                            Icons.check_circle_rounded,
                            color: colorScheme.primary,
                          )
                        : const Icon(Icons.history_rounded),
                    title: Text(
                      labelBuilder(item),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => onSelect(item),
                    trailing: IconButton(
                      tooltip: deleteTooltip,
                      onPressed: () => onDelete(item),
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
