import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class AppBreakpoints {
  static const double desktop = 900;
  static const double wideDesktop = 1280;

  const AppBreakpoints._();
}

bool isDesktopLayout(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  return width >= AppBreakpoints.desktop ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;
}
