import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/sftp_service.dart';
import 'viewmodels/sftp_viewmodel.dart';

class SftpFeatureScope extends StatelessWidget {
  final Widget child;

  const SftpFeatureScope({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) =>
          SftpViewModel(sftpService: context.read<SftpService>()),
      child: child,
    );
  }
}
