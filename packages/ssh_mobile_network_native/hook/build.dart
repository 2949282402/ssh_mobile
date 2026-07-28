import 'dart:io';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }

    final packageName = input.packageName;
    final targetOS = input.config.code.targetOS;
    final targetArch = input.config.code.targetArchitecture;

    // Resolve path to native/network_core
    // input.packageRoot is packages/ssh_mobile_network_native/
    final repoRoot = Directory.fromUri(input.packageRoot).parent.parent;
    final rustWorkspaceDir = Directory('${repoRoot.path}/native/network_core');

    if (!rustWorkspaceDir.existsSync()) {
      throw StateError('Rust workspace not found at ${rustWorkspaceDir.path}');
    }

    String cargoTargetTriple;
    String libFilename;

    if (targetOS == OS.windows) {
      if (targetArch != Architecture.x64) {
        throw UnsupportedError('Only x64 is currently supported for Windows');
      }
      cargoTargetTriple = 'x86_64-pc-windows-msvc';
      libFilename = 'network_ffi.dll';
    } else if (targetOS == OS.android) {
      if (targetArch != Architecture.arm64) {
        throw UnsupportedError(
          'Only arm64-v8a is currently supported for Android',
        );
      }
      cargoTargetTriple = 'aarch64-linux-android';
      libFilename = 'libnetwork_ffi.so';
    } else if (targetOS == OS.macOS) {
      cargoTargetTriple = targetArch == Architecture.arm64
          ? 'aarch64-apple-darwin'
          : 'x86_64-apple-darwin';
      libFilename = 'libnetwork_ffi.dylib';
    } else if (targetOS == OS.linux) {
      cargoTargetTriple = 'x86_64-unknown-linux-gnu';
      libFilename = 'libnetwork_ffi.so';
    } else {
      throw UnsupportedError('Target OS $targetOS is not supported yet');
    }

    final cargoExecutable =
        File('C:\\Users\\admin\\.cargo\\bin\\cargo.exe').existsSync()
        ? 'C:\\Users\\admin\\.cargo\\bin\\cargo.exe'
        : (Platform.environment['CARGO'] ?? 'cargo');

    final cargoArgs = [
      'build',
      '--package',
      'network-ffi',
      '--target',
      cargoTargetTriple,
      '--release',
    ];

    final processResult = await Process.run(
      cargoExecutable,
      cargoArgs,
      workingDirectory: rustWorkspaceDir.path,
      environment: {
        ...Platform.environment,
        'PATH':
            'C:\\Users\\admin\\.cargo\\bin;${Platform.environment['PATH'] ?? ''}',
      },
    );

    if (processResult.exitCode != 0) {
      throw StateError(
        'Cargo build failed with exit code ${processResult.exitCode}:\n'
        'STDOUT: ${processResult.stdout}\n'
        'STDERR: ${processResult.stderr}',
      );
    }

    final targetLibFile = File(
      '${rustWorkspaceDir.path}/target/$cargoTargetTriple/release/$libFilename',
    );

    if (!targetLibFile.existsSync()) {
      throw StateError('Compiled library not found at ${targetLibFile.path}');
    }

    output.assets.code.add(
      CodeAsset(
        package: packageName,
        name: '$packageName.dart',
        linkMode: DynamicLoadingBundled(),
        file: targetLibFile.uri,
      ),
    );

    output.dependencies.add(targetLibFile.uri);
  });
}
