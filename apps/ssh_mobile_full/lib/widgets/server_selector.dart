import 'package:flutter/material.dart';
import 'package:connection_core/connection_core.dart';
import 'package:app_ui/app_ui.dart';

export 'package:app_ui/app_ui.dart'
    show
        AppServerSelectorPane,
        AppServerSelectorStrip,
        AppServerSummaryBar,
        AppServerTile,
        AppServerSelectorTileBuilder;

typedef ServerSelectorTileBuilder =
    Widget Function(
      BuildContext context,
      ConnectionConfig connection,
      bool compact,
    );

typedef ServerSelectorPane = AppServerSelectorPane<ConnectionConfig>;
typedef ServerSelectorStrip = AppServerSelectorStrip<ConnectionConfig>;
