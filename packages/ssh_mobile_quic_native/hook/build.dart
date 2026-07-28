import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {

    /*
     * 当前构建如果不需要 Code Assets，
     * 就不做 native 编译。
     */
    if (!input.config.buildCodeAssets) {
      return;
    }

    final packageName = input.packageName;

    final targetOS =
        input.config.code.targetOS;

    final targetArchitecture =
        input.config.code.targetArchitecture;

    /*
     * package 根目录：
     *
     * packages/ssh_mobile_quic_native/
     */
    final packageRoot =
        input.packageRoot;

    /*
     * MsQuic headers：
     *
     * third_party/msquic/include/
     */
    final msquicInclude =
        packageRoot.resolve(
      'third_party/msquic/include/',
    );

    /*
     * 根据目标平台选择对应 MsQuic runtime。
     */
    late final Uri msquicRuntime;

    /*
     * linker 搜索目录。
     */
    late final Uri msquicLibraryDirectory;


    if (targetOS == OS.windows) {

      /*
       * 目前我们只有 Windows x64。
       */
      if (targetArchitecture != Architecture.x64) {
        throw UnsupportedError(
          'MsQuic Windows currently only supports x64 in ssh_mobile.',
        );
      }

      msquicLibraryDirectory =
          packageRoot.resolve(
        'third_party/msquic/windows/x64/',
      );

      msquicRuntime =
          msquicLibraryDirectory.resolve(
        'msquic.dll',
      );

      /*
       * .lib 是 link-time dependency。
       *
       * dll 是 runtime dependency。
       */
      final importLibrary =
          msquicLibraryDirectory.resolve(
        'msquic.lib',
      );

      output.dependencies.add(
        importLibrary,
      );

    } else if (targetOS == OS.android) {

      /*
       * 目前你的 Android MsQuic
       * 只有 arm64-v8a。
       */
      if (targetArchitecture != Architecture.arm64) {
        throw UnsupportedError(
          'MsQuic Android currently only supports arm64-v8a in ssh_mobile.',
        );
      }

      msquicLibraryDirectory =
          packageRoot.resolve(
        'third_party/msquic/android/arm64-v8a/',
      );

      msquicRuntime =
          msquicLibraryDirectory.resolve(
        'libmsquic.so',
      );

    } else {

      throw UnsupportedError(
        'MsQuic is not configured for $targetOS yet.',
      );
    }


    /*
     * 编译我们的 wrapper。
     */
    final builder = CBuilder.library(
      name: packageName,

      /*
       * 对应：
       *
       * lib/ssh_mobile_quic_native.dart
       */
      assetName:
          '$packageName.dart',

      sources: [
        'src/ssh_mobile_quic_native.c',
      ],

      /*
       * 让：
       *
       * #include <msquic.h>
       *
       * 能找到。
       */
      includes: [
        msquicInclude.toFilePath(),
      ],

      /*
       * Windows：
       *
       * msquic
       * ↓
       * msquic.lib
       *
       * Android：
       *
       * msquic
       * ↓
       * -lmsquic
       * ↓
       * libmsquic.so
       */
      libraries: [
        'msquic',
      ],

      libraryDirectories: [
        msquicLibraryDirectory
            .toFilePath(),
      ],
    );

    await builder.run(
      input: input,
      output: output,
    );


    /*
     * 非常重要。
     *
     * 上面只是让 linker 能找到 MsQuic。
     *
     * 这里才告诉 Flutter/Dart：
     *
     * “最终应用运行时，也必须把这个动态库带上。”
     */
    output.assets.code.add(
      CodeAsset(
        package: packageName,

        /*
         * 这是 Native Asset 的逻辑名称。
         *
         * Dart不会直接用它 lookup MsQuic，
         * 但是 bundler 会知道这个库属于应用。
         */
        name: 'msquic_runtime',

        linkMode:
            DynamicLoadingBundled(),

        file: msquicRuntime,
      ),
    );

    /*
     * 告诉 hook：
     *
     * 如果 MsQuic runtime 变化，
     * native build 需要重新执行。
     */
    output.dependencies.add(
      msquicRuntime,
    );
  });
}