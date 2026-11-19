import 'dart:io';
import 'dart:typed_data';

import 'android_backend.dart';
import 'bindings.dart';

/// A PDF opened with the native system renderer.
///
/// The document keeps only its path and page count; each operation reopens the
/// file natively, so instances are cheap and safe to recreate.
final class NativePdfDocument {
  NativePdfDocument._(this.path, this.pageCount);

  /// Opens [path] and reads its page count.
  ///
  /// Throws [NativePdfException] when the file is missing, unreadable or not a
  /// PDF, and [UnsupportedError] on platforms this version does not support.
  factory NativePdfDocument.open(String path) {
    if (path.trim().isEmpty) {
      throw const NativePdfException('the PDF path is empty');
    }
    final count = Platform.isAndroid
        ? AndroidPdfBackend.pageCount(path)
        : NativePdfBindings.instance.pageCount(path);
    if (count <= 0) {
      throw NativePdfException(
        count < 0 ? 'could not open the PDF' : 'the PDF has no pages',
      );
    }
    return NativePdfDocument._(path, count);
  }

  /// Absolute path of the document.
  final String path;

  /// Number of pages.
  final int pageCount;

  /// Media box of [index] in PDF points (1/72 inch).
  PdfPageSize pageSize(int index) {
    _checkIndex(index);
    if (Platform.isAndroid) {
      final size = AndroidPdfBackend.pageSize(path, index);
      return PdfPageSize(size.width, size.height);
    }
    final size = NativePdfBindings.instance.pageSize(path, index);
    return PdfPageSize(size.width, size.height);
  }

  /// Rasterizes [index] at [width] pixels wide.
  ///
  /// [format] defaults to JPEG at [quality] 85; use [NativeImageFormat.png] for
  /// lossless output. The returned bytes are freshly allocated.
  Uint8List renderPage(
    int index, {
    double width = 1240,
    NativeImageFormat format = NativeImageFormat.jpeg,
    int quality = 85,
  }) {
    _checkIndex(index);
    if (!width.isFinite || width <= 0) {
      throw const NativePdfException('the render width must be positive');
    }
    if (Platform.isAndroid) {
      return AndroidPdfBackend.renderPage(
        path,
        index,
        targetWidth: width,
        quality: quality,
        format: format,
      );
    }
    return NativePdfBindings.instance.renderPage(
      path,
      index,
      targetWidth: width,
      quality: quality,
      format: format,
    );
  }

  void _checkIndex(int index) {
    if (index < 0 || index >= pageCount) {
      throw NativePdfException(
        'page $index is out of range (the document has $pageCount pages)',
      );
    }
  }
}

/// A page's media box in PDF points.
final class PdfPageSize {
  const PdfPageSize(this.width, this.height);

  final double width;
  final double height;

  /// Aspect ratio (`width / height`), or null for a degenerate page.
  double? get aspectRatio => height <= 0 ? null : width / height;

  @override
  bool operator ==(Object other) =>
      other is PdfPageSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() =>
      'PdfPageSize(${width.toStringAsFixed(1)} × '
      '${height.toStringAsFixed(1)} pt)';
}

/// What this version can do on the current platform.
abstract final class NativePdfCapabilities {
  /// Whether the native PDF engine is available.
  static bool get isSupported =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  /// Page count, page size and rasterization.
  static bool get rendering => isSupported;

  /// Native image resizing and JPEG/PNG encoding.
  static bool get imageCompression => isSupported;

  /// Best-effort text-layer extraction (no font CMaps).
  static bool get textExtraction => isSupported;

  /// Page rotate, reorder, remove and split.
  static bool get pageEditing => isSupported;

  /// In-house optimizer (lossless + JPEG downsampling).
  static bool get optimization => isSupported;

  /// Cross-document merge.
  static bool get merge => isSupported;

  /// Document info dictionary read/write.
  static bool get metadata => isSupported;
}
