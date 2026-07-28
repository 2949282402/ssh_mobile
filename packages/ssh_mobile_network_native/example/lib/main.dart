import 'package:flutter/material.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

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
  int _sdkVersion = 0;

  @override
  void initState() {
    super.initState();
    _abiVersion = _native.getAbiVersion();
    _sdkVersion = _native.getSdkVersion();
  }

  @override
  Widget build(BuildContext context) {
    const textStyle = TextStyle(fontSize: 20);
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Network Native Example')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('ABI Version: $_abiVersion', style: textStyle),
              const SizedBox(height: 10),
              Text('SDK Version: $_sdkVersion', style: textStyle),
            ],
          ),
        ),
      ),
    );
  }
}
