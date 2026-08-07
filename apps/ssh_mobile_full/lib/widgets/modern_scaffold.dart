import 'package:flutter/material.dart';

import 'package:app_ui/app_ui.dart';

class ModernScaffold extends StatelessWidget {
  final String? title;
  final PreferredSizeWidget? appBar;
  final Widget body;
  final EdgeInsetsGeometry padding;
  final bool useSafeArea;
  final List<Widget>? actions;
  final Widget? floatingActionButton;
  final Widget? bottomNavigationBar;

  const ModernScaffold({
    super.key,
    this.title,
    this.appBar,
    required this.body,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    this.useSafeArea = true,
    this.actions,
    this.floatingActionButton,
    this.bottomNavigationBar,
  });

  @override
  Widget build(BuildContext context) {
    final content = AppPageSurface(
      child: Padding(padding: padding, child: body),
    );

    return Scaffold(
      appBar:
          appBar ??
          (title == null
              ? null
              : AppBar(title: Text(title!), actions: actions)),
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: bottomNavigationBar,
      body: useSafeArea ? SafeArea(child: content) : content,
    );
  }
}
