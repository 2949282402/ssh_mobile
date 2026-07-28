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
      cargoTargetTriple = switch (targetArch) {
        Architecture.x64 => 'x86_64-pc-windows-msvc',
        Architecture.arm64 => 'aarch64-pc-windows-msvc',
        _ => throw UnsupportedError(
          'Unsupported Windows architecture: $targetArch',
        ),
      };
      libFilename = 'network_ffi.dll';
    } else if (targetOS == OS.android) {
      cargoTargetTriple = switch (targetArch) {
        Architecture.arm64 => 'aarch64-linux-android',
        Architecture.x64 => 'x86_64-linux-android',
        Architecture.arm => 'armv7-linux-androideabi',
        _ => throw UnsupportedError(
          'Unsupported Android architecture: $targetArch',
        ),
      };
      libFilename = 'libnetwork_ffi.so';
    } else if (targetOS == OS.iOS) {
      cargoTargetTriple = switch ((
        targetArch,
        input.config.code.iOS.targetSdk,
      )) {
        (Architecture.arm64, IOSSdk.iPhoneOS) => 'aarch64-apple-ios',
        (Architecture.arm64, IOSSdk.iPhoneSimulator) => 'aarch64-apple-ios-sim',
        (Architecture.x64, IOSSdk.iPhoneSimulator) => 'x86_64-apple-ios',
        _ => throw UnsupportedError(
          'Unsupported iOS architecture/SDK: '
          '$targetArch/${input.config.code.iOS.targetSdk}',
        ),
      };
      libFilename = 'libnetwork_ffi.dylib';
    } else if (targetOS == OS.macOS) {
      cargoTargetTriple = targetArch == Architecture.arm64
          ? 'aarch64-apple-darwin'
          : 'x86_64-apple-darwin';
      libFilename = 'libnetwork_ffi.dylib';
    } else if (targetOS == OS.linux) {
      cargoTargetTriple = switch (targetArch) {
        Architecture.x64 => 'x86_64-unknown-linux-gnu',
        Architecture.arm64 => 'aarch64-unknown-linux-gnu',
        _ => throw UnsupportedError(
          'Unsupported Linux architecture: $targetArch',
        ),
      };
      libFilename = 'libnetwork_ffi.so';
    } else {
      throw UnsupportedError('Target OS $targetOS is not supported yet');
    }

    final cargoExecutable = Platform.environment['CARGO'] ?? 'cargo';

    final cargoArgs = [
      'build',
      '--package',
      'network-ffi',
      '--target',
      cargoTargetTriple,
      '--release',
      '--locked',
    ];

    final buildEnvironment = <String, String>{...Platform.environment};
    if (targetOS == OS.android) {
      final ndkRoot = _findAndroidNdk(buildEnvironment);
      if (ndkRoot == null) {
        throw StateError(
          'Android NDK not found. Set ANDROID_NDK_HOME, ANDROID_NDK_ROOT, '
          'ANDROID_NDK_LATEST_HOME, ANDROID_HOME, or ANDROID_SDK_ROOT.',
        );
      }
      final hostTag = switch (Platform.operatingSystem) {
        'windows' => 'windows-x86_64',
        'macos' => 'darwin-x86_64',
        'linux' => 'linux-x86_64',
        _ => throw UnsupportedError(
          'Unsupported Android build host: ${Platform.operatingSystem}',
        ),
      };
      final clangPrefix = switch (targetArch) {
        Architecture.arm64 => 'aarch64-linux-android',
        Architecture.x64 => 'x86_64-linux-android',
        Architecture.arm => 'armv7a-linux-androideabi',
        _ => throw UnsupportedError(
          'Unsupported Android architecture: $targetArch',
        ),
      };
      final executableSuffix = Platform.isWindows ? '.cmd' : '';
      final linker = File(
        '$ndkRoot/toolchains/llvm/prebuilt/$hostTag/bin/'
        '$clangPrefix${input.config.code.android.targetNdkApi}-clang'
        '$executableSuffix',
      );
      if (!linker.existsSync()) {
        throw StateError('Android NDK linker not found at ${linker.path}');
      }
      final cargoTargetKey = cargoTargetTriple.toUpperCase().replaceAll(
        '-',
        '_',
      );
      buildEnvironment['CARGO_TARGET_${cargoTargetKey}_LINKER'] = linker.path;
    }

    final processResult = await Process.run(
      cargoExecutable,
      cargoArgs,
      workingDirectory: rustWorkspaceDir.path,
      environment: buildEnvironment,
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
    final targetSegment =
        '${Platform.pathSeparator}target${Platform.pathSeparator}';
    for (final entity in rustWorkspaceDir.listSync(recursive: true)) {
      if (entity is! File || entity.path.contains(targetSegment)) continue;
      final name = entity.uri.pathSegments.last;
      if (name.endsWith('.rs') ||
          name == 'Cargo.toml' ||
          name == 'Cargo.lock' ||
          name == 'rust-toolchain.toml') {
        output.dependencies.add(entity.uri);
      }
    }
  });
}

String? _findAndroidNdk(Map<String, String> environment) {
  final directCandidates = <String?>[
    environment['ANDROID_NDK_HOME'],
    environment['ANDROID_NDK_ROOT'],
    environment['ANDROID_NDK_LATEST_HOME'],
  ];
  for (final candidate in directCandidates) {
    if (candidate != null &&
        candidate.isNotEmpty &&
        Directory(candidate).existsSync()) {
      return candidate;
    }
  }

  final sdkRoot =
      environment['ANDROID_HOME'] ?? environment['ANDROID_SDK_ROOT'];
  if (sdkRoot == null || sdkRoot.isEmpty) {
    return null;
  }

  final ndkDirectory = Directory('$sdkRoot/ndk');
  if (ndkDirectory.existsSync()) {
    final installed =
        ndkDirectory
            .listSync()
            .whereType<Directory>()
            .where(
              (directory) =>
                  File('${directory.path}/source.properties').existsSync(),
            )
            .toList()
          ..sort((left, right) => right.path.compareTo(left.path));
    if (installed.isNotEmpty) {
      return installed.first.path;
    }
  }

  final legacyNdk = Directory('$sdkRoot/ndk-bundle');
  return legacyNdk.existsSync() ? legacyNdk.path : null;
}
