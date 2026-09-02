import 'package:flutter/material.dart';
import 'package:app_ui/app_ui.dart';

import '../domain/sftp_models.dart';

typedef ServerSelectorTileBuilder =
    Widget Function(
      BuildContext context,
      SftpConnectionInfo connection,
      bool compact,
    );

typedef ServerSelectorPane = AppServerSelectorPane<SftpConnectionInfo>;
typedef ServerSelectorStrip = AppServerSelectorStrip<SftpConnectionInfo>;
