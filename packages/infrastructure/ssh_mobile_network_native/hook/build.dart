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

    // Workspace 迁移后，native package 位于 packages/infrastructure 下；
    // 向上三级才能回到仓库根，Rust workspace 仍由根目录的 native/network_core 持有。
    final workspaceRoot = Directory.fromUri(
      input.packageRoot,
    ).parent.parent.parent;
    final rustWorkspaceDir = Directory(
      '${workspaceRoot.path}/native/network_core',
    );

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

    final cargoBinDirectory = _locateCargoBinDirectory();
    final cargoExecutable =
        Platform.environment['CARGO'] ??
        (cargoBinDirectory != null
            ? File(
                '${cargoBinDirectory.path}${Platform.pathSeparator}${Platform.isWindows ? "cargo.exe" : "cargo"}',
              ).path
            : 'cargo');

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
    _ensureRustupHome(buildEnvironment);
    if (targetOS == OS.android) {
      final ndkRoot = _findAndroidNdk(
        buildEnvironment,
        workspaceRoot: workspaceRoot.path,
      );
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
      final toolchainBin = '$ndkRoot/toolchains/llvm/prebuilt/$hostTag/bin';
      final linker = File(
        '$toolchainBin/'
        '$clangPrefix${input.config.code.android.targetNdkApi}-clang'
        '$executableSuffix',
      );
      if (!linker.existsSync()) {
        throw StateError('Android NDK linker not found at ${linker.path}');
      }
      // The NDK ships llvm-ar as an .exe on Windows (clang uses .cmd), so it
      // needs its own suffix.
      final archiver = File(
        '$toolchainBin/llvm-ar${Platform.isWindows ? '.exe' : ''}',
      );
      if (!archiver.existsSync()) {
        throw StateError('Android NDK archiver not found at ${archiver.path}');
      }
      final cargoTargetKey = cargoTargetTriple.toUpperCase().replaceAll(
        '-',
        '_',
      );
      buildEnvironment['CARGO_TARGET_${cargoTargetKey}_LINKER'] = linker.path;
      // The `cc` build-script crate looks up the C compiler and archiver by the
      // raw target triple (CC_<triple> / AR_<triple>). Without them, any crate
      // that compiles C in a build script fails with "failed to find tool
      // <clangPrefix>-clang" even though the final linker is configured above.
      buildEnvironment['CC_$cargoTargetTriple'] = linker.path;
      buildEnvironment['AR_$cargoTargetTriple'] = archiver.path;
    }
    if ((targetOS == OS.macOS || targetOS == OS.iOS) && Platform.isMacOS) {
      _configureAppleToolchain(buildEnvironment, cargoTargetTriple);
    }

    final processResult = await Process.run(
      cargoExecutable,
      cargoArgs,
      workingDirectory: rustWorkspaceDir.path,
      environment: buildEnvironment,
    );

    if (processResult.exitCode != 0) {
      // Surface the toolchain location: a missing target resolves against
      // RUSTUP_HOME, so it is the first thing worth checking on failure.
      throw StateError(
        'Cargo build failed with exit code ${processResult.exitCode} '
        'for target $cargoTargetTriple\n'
        'RUSTUP_HOME: ${buildEnvironment['RUSTUP_HOME'] ?? '<unset>'}\n'
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

/// Flutter native-asset hooks can run with a reduced PATH that does not expose
/// Xcode's compiler aliases. Pin the stable system tool paths so Rust build
/// scripts such as `ring` can compile C/assembly for Apple targets.
void _configureAppleToolchain(
  Map<String, String> environment,
  String cargoTargetTriple,
) {
  final clang = File('/usr/bin/clang');
  final archiver = File('/usr/bin/ar');
  if (!clang.existsSync() || !archiver.existsSync()) {
    throw StateError(
      'Apple toolchain is unavailable: expected ${clang.path} and '
      '${archiver.path}.',
    );
  }

  final cargoTargetKey = cargoTargetTriple.toUpperCase().replaceAll('-', '_');
  environment['CARGO_TARGET_${cargoTargetKey}_LINKER'] = clang.path;
  environment['CC_$cargoTargetTriple'] = clang.path;
  environment['AR_$cargoTargetTriple'] = archiver.path;
}

/// Restores `RUSTUP_HOME`/`CARGO_HOME` when the surrounding build tool drops
/// them from the environment.
///
/// Gradle launches `flutter` (and therefore this hook) from a long-lived daemon
/// whose environment can predate — or simply not inherit — user-level variables.
/// On Windows this regularly leaves `RUSTUP_HOME` unset, so the rustup proxy
/// falls back to `%USERPROFILE%\.rustup`. When the real toolchain lives
/// elsewhere, that fallback has no cross-compilation targets installed and
/// cargo fails with the misleading `can't find crate for 'core'` (E0463).
///
/// `cargo` itself is still resolvable (via `CARGO` or `PATH`), so its location
/// identifies the intended installation: rustup provisions `<root>/.cargo` and
/// `<root>/.rustup` side by side. Only fills in values that are missing and
/// verified to exist; never overrides an explicit configuration.
void _ensureRustupHome(Map<String, String> environment) {
  final configuredHome = environment['RUSTUP_HOME'];
  if (configuredHome != null &&
      configuredHome.isNotEmpty &&
      Directory(configuredHome).existsSync()) {
    return;
  }

  final cargoBinDirectory = _locateCargoBinDirectory();
  if (cargoBinDirectory == null) {
    return;
  }

  // <root>/.cargo/bin -> <root>/.cargo -> <root>
  final cargoHome = cargoBinDirectory.parent;
  final installRoot = cargoHome.parent;
  final rustupHome = Directory(
    '${installRoot.path}${Platform.pathSeparator}.rustup',
  );
  if (!Directory(
    '${rustupHome.path}${Platform.pathSeparator}toolchains',
  ).existsSync()) {
    return;
  }

  environment['RUSTUP_HOME'] = rustupHome.path;
  final configuredCargoHome = environment['CARGO_HOME'];
  if (configuredCargoHome == null || configuredCargoHome.isEmpty) {
    environment['CARGO_HOME'] = cargoHome.path;
  }
}

/// Resolves the directory holding the `cargo` executable, preferring an
/// explicit `CARGO` override and otherwise scanning `PATH`.
///
/// Reads from [Platform.environment] directly because it is case-insensitive on
/// Windows, where the variable is spelled `Path`.
Directory? _locateCargoBinDirectory() {
  final explicitCargo = Platform.environment['CARGO'];
  if (explicitCargo != null &&
      explicitCargo.isNotEmpty &&
      File(explicitCargo).existsSync()) {
    return File(explicitCargo).parent;
  }

  final candidateEntries = <String>[];
  final pathValue = Platform.environment['PATH'];
  if (pathValue != null && pathValue.isNotEmpty) {
    final separator = Platform.isWindows ? ';' : ':';
    candidateEntries.addAll(pathValue.split(separator));
  }

  final userHome =
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  if (userHome != null && userHome.isNotEmpty) {
    candidateEntries.add(
      '$userHome${Platform.pathSeparator}.cargo${Platform.pathSeparator}bin',
    );
  }

  final executableNames = Platform.isWindows
      ? const ['cargo.exe', 'cargo.bat']
      : const ['cargo'];
  for (final rawEntry in candidateEntries) {
    final entry = rawEntry.trim();
    if (entry.isEmpty) continue;
    for (final executableName in executableNames) {
      final candidate = File('$entry${Platform.pathSeparator}$executableName');
      if (candidate.existsSync()) {
        return candidate.parent;
      }
    }
  }
  return null;
}

String? _findAndroidNdk(
  Map<String, String> environment, {
  required String workspaceRoot,
}) {
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

  var sdkRoot = environment['ANDROID_HOME'] ?? environment['ANDROID_SDK_ROOT'];
  String? ndkRoot;

  // Fall back to android/local.properties (sdk.dir / ndk.dir), which Gradle
  // reads to locate the SDK when ANDROID_HOME is not exported from the shell.
  if (sdkRoot == null || sdkRoot.isEmpty) {
    final properties = File(
      '$workspaceRoot/apps/ssh_mobile_full/android/local.properties',
    );
    if (properties.existsSync()) {
      for (final rawLine in properties.readAsLinesSync()) {
        final line = rawLine.trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        final separator = line.indexOf('=');
        if (separator <= 0) continue;
        final key = line.substring(0, separator).trim();
        var value = line.substring(separator + 1).trim();
        if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) {
          value = value.substring(1, value.length - 1);
        }
        value = value.replaceAll(r'\\', r'\');
        if (key == 'sdk.dir' && (sdkRoot == null || sdkRoot.isEmpty)) {
          sdkRoot = value;
        } else if (key == 'ndk.dir') {
          ndkRoot = value;
        }
      }
    }
  }

  if (ndkRoot != null &&
      ndkRoot.isNotEmpty &&
      Directory(ndkRoot).existsSync()) {
    return ndkRoot;
  }

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
