import 'dart:math' as math;
import 'dart:typed_data';

import 'package:jni/jni.dart' as jni;

import 'android.g.dart';
import 'bindings.dart';

/// Android backend built on the platform's own PDF and bitmap classes.
///
/// Uses JNIgen's generated bindings directly. There is no platform channel and
/// no third-party native engine.
abstract final class AndroidPdfBackend {
  static int pageCount(String path) {
    final renderer = _open(path);
    try {
      return renderer.pageCount;
    } finally {
      _close(renderer);
    }
  }

  static ({double width, double height}) pageSize(String path, int index) {
    final renderer = _open(path);
    PdfRenderer$Page? page;
    try {
      page = _openPage(renderer, index);
      return (width: page.width.toDouble(), height: page.height.toDouble());
    } finally {
      page?.close();
      page?.release();
      _close(renderer);
    }
  }

  static Uint8List renderPage(
    String path,
    int index, {
    required double targetWidth,
    required int quality,
    required NativeImageFormat format,
  }) {
    final renderer = _open(path);
    PdfRenderer$Page? page;
    Matrix? matrix;
    Bitmap? bitmap;
    try {
      page = _openPage(renderer, index);
      final scale = targetWidth / page.width;
      final width = math.max(1, targetWidth.round());
      final height = math.max(1, (page.height * scale).round());

      bitmap = Bitmap.createBitmap$10(width, height, Bitmap$Config.ARGB_8888);
      if (bitmap == null) {
        throw const NativePdfException('could not allocate the page bitmap');
      }
      bitmap.eraseColor(0xFFFFFFFF);

      matrix = Matrix()..setScale(scale, scale);
      page.render$1(
        bitmap,
        null,
        matrix,
        PdfRenderer$Page.RENDER_MODE_FOR_PRINT,
      );

      return _encode(bitmap, format, quality);
    } finally {
      matrix?.release();
      bitmap?.recycle();
      bitmap?.release();
      page?.close();
      page?.release();
      _close(renderer);
    }
  }

  static ({Uint8List bytes, int width, int height}) compressImage(
    Uint8List input, {
    required double maxDimension,
    required int quality,
    required NativeImageFormat format,
  }) {
    jni.JByteArray? source;
    Bitmap? decoded;
    Bitmap? scaled;
    try {
      source = jni.JByteArray.of(input);
      decoded = BitmapFactory.decodeByteArray(source, 0, input.length);
      if (decoded == null) {
        throw const NativePdfException('could not decode the image');
      }

      var target = decoded;
      final longest = math.max(decoded.width, decoded.height);
      if (longest > maxDimension) {
        final scale = maxDimension / longest;
        final width = math.max(1, (decoded.width * scale).round());
        final height = math.max(1, (decoded.height * scale).round());
        scaled = Bitmap.createScaledBitmap(decoded, width, height, true);
        if (scaled == null) {
          throw const NativePdfException('could not resize the image');
        }
        target = scaled;
      }

      return (
        bytes: _encode(target, format, quality),
        width: target.width,
        height: target.height,
      );
    } finally {
      source?.release();
      scaled?.recycle();
      scaled?.release();
      decoded?.recycle();
      decoded?.release();
    }
  }

  static Uint8List _encode(
    Bitmap bitmap,
    NativeImageFormat format,
    int quality,
  ) {
    final stream = ByteArrayOutputStream();
    jni.JByteArray? bytes;
    try {
      final encoder = format == NativeImageFormat.jpeg
          ? Bitmap$CompressFormat.JPEG
          : Bitmap$CompressFormat.PNG;
      final ok = bitmap.compress(encoder, quality, stream);
      if (!ok) {
        throw const NativePdfException('could not encode the image');
      }
      bytes = stream.toByteArray();
      if (bytes == null) {
        throw const NativePdfException('the encoder produced no data');
      }
      return Uint8List.fromList(bytes.getRange(0, bytes.length));
    } finally {
      bytes?.release();
      stream.release();
    }
  }

  static PdfRenderer _open(String path) {
    final file = File.new$1(path.toJString());
    ParcelFileDescriptor? descriptor;
    try {
      descriptor = ParcelFileDescriptor.open(
        file,
        ParcelFileDescriptor.MODE_READ_ONLY,
      );
      if (descriptor == null) {
        throw const NativePdfException('could not open the PDF file');
      }
      return PdfRenderer(descriptor);
    } finally {
      file.release();
      descriptor?.release();
    }
  }

  static PdfRenderer$Page _openPage(PdfRenderer renderer, int index) {
    if (index < 0 || index >= renderer.pageCount) {
      throw NativePdfException('page $index is out of range');
    }
    final page = renderer.openPage(index);
    if (page == null) {
      throw NativePdfException('could not open page $index');
    }
    return page;
  }

  static void _close(PdfRenderer renderer) {
    try {
      renderer.close();
    } finally {
      renderer.release();
    }
  }
}
