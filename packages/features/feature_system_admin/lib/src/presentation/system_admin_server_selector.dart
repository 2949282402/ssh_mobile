// System Admin 的连接选择器 UI。
//
// 组件只接收 Connection 公共模型和回调，不读取 Storage 或创建连接。

import 'package:flutter/material.dart';
import 'package:connection_core/connection_core.dart';
import 'package:app_ui/app_ui.dart';

typedef ServerSelectorTileBuilder =
    Widget Function(
      BuildContext context,
      ConnectionConfig connection,
      bool compact,
    );

typedef ServerSelectorPane = AppServerSelectorPane<ConnectionConfig>;
typedef ServerSelectorStrip = AppServerSelectorStrip<ConnectionConfig>;
