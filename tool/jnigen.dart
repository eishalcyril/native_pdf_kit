import 'dart:io';

import 'package:jnigen/jnigen.dart';

Future<void> main(List<String> args) async {
  final packageRoot = Platform.script.resolve('../');
  final sdkRoot =
      Platform.environment['ANDROID_HOME'] ??
      Platform.environment['ANDROID_SDK_ROOT'];
  if (sdkRoot == null || sdkRoot.isEmpty) {
    stderr.writeln(
      'Set ANDROID_HOME (or ANDROID_SDK_ROOT) before generating bindings.',
    );
    exit(64);
  }
  final generator = JniGenerator(
    input: Input(
      classes: [
        'android.graphics.pdf.PdfRenderer',
        'android.graphics.Bitmap',
        'android.graphics.BitmapFactory',
        'android.graphics.Matrix',
        'android.os.ParcelFileDescriptor',
        'java.io.ByteArrayOutputStream',
        'java.io.File',
      ],
      androidSdk: AndroidSdk(
        versions: const [36],
        sdkRoot: Uri.directory(sdkRoot),
      ),
    ),
    output: Output(
      dart: DartOutput(
        path: packageRoot.resolve('lib/src/android.g.dart'),
        structure: OutputStructure.singleFile,
      ),
    ),
  );
  await generator.generate();
}
