import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final packageName = input.packageName;

    final cBuilder = CBuilder.library(
      name: packageName,

      // 对应 lib/ssh_mobile_quic_native.dart
      assetName: '$packageName.dart',

      sources: [
        'src/$packageName.c',
      ],
    );

    await cBuilder.run(
      input: input,
      output: output,
    );
  });
}