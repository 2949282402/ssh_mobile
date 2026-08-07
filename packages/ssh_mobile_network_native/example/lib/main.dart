/// 演示 v1 原生网络 package 的 ABI 冒烟检查。
library;

import 'package:flutter/material.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

/// 启动原生网络 package 示例应用。
void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  static const _native = SshMobileNetworkNative();
  int _abiVersion = 0;

  /// 在组件挂载后读取原生 ABI 版本。
  @override
  void initState() {
    super.initState();
    _abiVersion = _native.getAbiVersion();
  }

  /// 构建 ABI 冒烟检查页面。
  @override
  Widget build(BuildContext context) {
    const textStyle = TextStyle(fontSize: 20);
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Network Native Example')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [Text('ABI Version: $_abiVersion', style: textStyle)],
          ),
        ),
      ),
    );
  }
}
