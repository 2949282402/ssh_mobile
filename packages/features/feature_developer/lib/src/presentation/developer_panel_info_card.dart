part of 'developer_panel_screen.dart';

final class _DeveloperPanelInfoCard extends StatelessWidget {
  const _DeveloperPanelInfoCard({required this.vm});

  final DeveloperPanelViewModel vm;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 20),
                SizedBox(width: 8),
                Text(
                  'Build & Platform',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _developerInfoRow(context, 'Build Mode', vm.buildMode),
            _developerInfoRow(context, 'Platform', vm.platformName),
            _developerInfoRow(context, 'Dart', vm.dartVersion),
            if (vm.flutterVersion != '—')
              _developerInfoRow(context, 'Flutter', vm.flutterVersion),
          ],
        ),
      ),
    );
  }
}
