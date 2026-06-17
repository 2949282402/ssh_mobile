part of '../system_admin_screen.dart';

class _ServicesTab extends StatefulWidget {
  final AppStrings strings;
  final ColorScheme colorScheme;
  final SystemAdminViewModel viewModel;

  const _ServicesTab({
    required this.strings,
    required this.colorScheme,
    required this.viewModel,
  });

  @override
  State<_ServicesTab> createState() => _ServicesTabState();
}

class _ServicesTabState extends State<_ServicesTab>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _serviceSearchController =
      TextEditingController();
  List<SystemdService> _filteredServices = [];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _serviceSearchController.addListener(_filterServices);
    _filteredServices = List.from(widget.viewModel.services);
  }

  @override
  void didUpdateWidget(covariant _ServicesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.viewModel.services != oldWidget.viewModel.services) {
      _filterServices();
    }
  }

  @override
  void dispose() {
    _serviceSearchController.dispose();
    super.dispose();
  }

  void _filterServices() {
    if (!mounted) return;
    final query = _serviceSearchController.text.trim().toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filteredServices = List.from(widget.viewModel.services);
      } else {
        _filteredServices = widget.viewModel.services
            .where((s) =>
                s.name.toLowerCase().contains(query) ||
                s.description.toLowerCase().contains(query))
            .toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final viewModel = widget.viewModel;
    if (viewModel.loadingServices) {
      return const Center(child: CircularProgressIndicator());
    }

    final id = viewModel.connectionId;
    if (id == null) return const SizedBox.shrink();

    return RefreshIndicator(
      onRefresh: () => viewModel.fetchServices(id),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _serviceSearchController,
              decoration: InputDecoration(
                hintText: widget.strings.searchService,
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              ),
            ),
          ),
          Expanded(
            child: _filteredServices.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 100),
                      Center(child: Text('No services found.')),
                    ],
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: _filteredServices.length,
                    itemBuilder: (context, index) {
                      final service = _filteredServices[index];
                      return Card(
                        child: ListTile(
                          leading: Icon(
                            service.isRunning
                                ? Icons.play_circle
                                : Icons.stop_circle,
                            color: service.isRunning
                                ? widget.colorScheme.secondary
                                : widget.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.5),
                          ),
                          title: OverflowScrollText(
                            service.name,
                            selectable: false,
                            maxLines: 1,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: OverflowScrollText(
                            '${service.activeState} (${service.subState}) • ${service.description}',
                            selectable: false,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: 12,
                              color: widget.colorScheme.onSurface
                                  .withValues(alpha: 0.58),
                            ),
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (action) =>
                                _manageService(service.name, action),
                            itemBuilder: (context) => [
                              PopupMenuItem(
                                  value: 'start',
                                  child: Text(widget.strings.serviceStart)),
                              PopupMenuItem(
                                  value: 'stop',
                                  child: Text(widget.strings.serviceStop)),
                              PopupMenuItem(
                                  value: 'restart',
                                  child: Text(widget.strings.serviceRestart)),
                              PopupMenuItem(
                                  value: 'enable',
                                  child: Text(widget.strings.serviceEnable)),
                              PopupMenuItem(
                                  value: 'disable',
                                  child: Text(widget.strings.serviceDisable)),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _manageService(String name, String action) async {
    final language = context.read<AppSettings>().language;
    final strings = AppStrings(language);

    // Double confirmation for stopping or disabling service
    if (action == 'stop' || action == 'disable') {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(strings.actionConfirm),
          content: Text('Are you sure you want to $action service "$name"?'),
          actions: [
            TextButton(
              child: Text(strings.cancel),
              onPressed: () => Navigator.pop(context, false),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (confirm != true) return;
    }

    try {
      await widget.viewModel.manageSystemdService(name, action);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Action failed: $e')));
    }
  }
}
