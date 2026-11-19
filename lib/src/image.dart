import 'dart:io';
import 'dart:typed_data';

import 'android_backend.dart';
import 'bindings.dart';

/// Native image resizing and encoding through ImageIO.
abstract final class NativeImageCompressor {
  /// Decodes [bytes], scales it so the longest edge is at most
  /// [maxDimension], and re-encodes it.
  ///
  /// JPEG uses [quality] (1–100); PNG is lossless and ignores `quality`.
  /// EXIF orientation is applied before resizing.
  static NativeImageResult compress(
    Uint8List bytes, {
    double maxDimension = 2048,
    int quality = 82,
    NativeImageFormat format = NativeImageFormat.jpeg,
  }) {
    if (bytes.isEmpty) {
      throw const NativePdfException('the image data is empty');
    }
    if (!maxDimension.isFinite || maxDimension <= 0) {
      throw const NativePdfException('maxDimension must be positive');
    }
    if (quality < 1 || quality > 100) {
      throw const NativePdfException('quality must be between 1 and 100');
    }

    if (Platform.isAndroid) {
      final result = AndroidPdfBackend.compressImage(
        bytes,
        maxDimension: maxDimension,
        quality: quality,
        format: format,
      );
      return NativeImageResult._(
        bytes: result.bytes,
        width: result.width,
        height: result.height,
      );
    }

    final result = NativePdfBindings.instance.compressImage(
      bytes,
      maxDimension: maxDimension,
      quality: quality,
      format: format,
    );
    return NativeImageResult._(
      bytes: result.bytes,
      width: result.width,
      height: result.height,
    );
  }
}

/// Encoded image bytes with their pixel dimensions.
final class NativeImageResult {
  const NativeImageResult._({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;

  int get byteLength => bytes.length;
}
