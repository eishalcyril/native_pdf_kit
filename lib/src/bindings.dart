import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Encoding used for rendered pages and compressed images.
enum NativeImageFormat {
  jpeg(0, 'image/jpeg'),
  png(1, 'image/png');

  const NativeImageFormat(this.nativeValue, this.mimeType);

  final int nativeValue;
  final String mimeType;
}

/// Thrown when a native PDF or image operation fails.
final class NativePdfException implements Exception {
  const NativePdfException(this.message);

  final String message;

  @override
  String toString() => 'NativePdfException: $message';
}

/// Direct bindings to the package's narrow C surface.
///
/// The symbols live in the app binary on iOS (CocoaPods/SPM link this
/// package's C source). Tests and desktop development load a local dylib
/// built by `tool/build_native_test_lib.sh`.
final class NativePdfBindings {
  NativePdfBindings._(DynamicLibrary library)
    : _pageCount = library
          .lookupFunction<
            Int32 Function(Pointer<Utf8>),
            int Function(Pointer<Utf8>)
          >('npdf_page_count'),
      _pageSize = library
          .lookupFunction<
            Int32 Function(
              Pointer<Utf8>,
              Int32,
              Pointer<Double>,
              Pointer<Double>,
            ),
            int Function(Pointer<Utf8>, int, Pointer<Double>, Pointer<Double>)
          >('npdf_page_size'),
      _renderPage = library
          .lookupFunction<
            Pointer<Uint8> Function(
              Pointer<Utf8>,
              Int32,
              Double,
              Int32,
              Int32,
              Pointer<Int32>,
            ),
            Pointer<Uint8> Function(
              Pointer<Utf8>,
              int,
              double,
              int,
              int,
              Pointer<Int32>,
            )
          >('npdf_render_page'),
      _compressImage = library
          .lookupFunction<
            Pointer<Uint8> Function(
              Pointer<Uint8>,
              Int32,
              Double,
              Int32,
              Int32,
              Pointer<Int32>,
              Pointer<Int32>,
              Pointer<Int32>,
            ),
            Pointer<Uint8> Function(
              Pointer<Uint8>,
              int,
              double,
              int,
              int,
              Pointer<Int32>,
              Pointer<Int32>,
              Pointer<Int32>,
            )
          >('npdf_compress_image'),
      _free = library
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('npdf_free'),
      _lastError = library
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'npdf_last_error',
          );

  static NativePdfBindings? _instance;

  static NativePdfBindings get instance =>
      _instance ??= NativePdfBindings._(_openLibrary());

  static bool get isSupported => Platform.isIOS || Platform.isMacOS;

  final int Function(Pointer<Utf8>) _pageCount;
  final int Function(Pointer<Utf8>, int, Pointer<Double>, Pointer<Double>)
  _pageSize;
  final Pointer<Uint8> Function(
    Pointer<Utf8>,
    int,
    double,
    int,
    int,
    Pointer<Int32>,
  )
  _renderPage;
  final Pointer<Uint8> Function(
    Pointer<Uint8>,
    int,
    double,
    int,
    int,
    Pointer<Int32>,
    Pointer<Int32>,
    Pointer<Int32>,
  )
  _compressImage;
  final void Function(Pointer<Void>) _free;
  final Pointer<Utf8> Function() _lastError;

  int pageCount(String path) {
    final nativePath = path.toNativeUtf8();
    try {
      return _pageCount(nativePath);
    } finally {
      malloc.free(nativePath);
    }
  }

  ({double width, double height}) pageSize(String path, int index) {
    final nativePath = path.toNativeUtf8();
    final width = malloc<Double>();
    final height = malloc<Double>();
    try {
      final result = _pageSize(nativePath, index, width, height);
      if (result != 0) {
        throw NativePdfException(_errorOr('could not read the page size'));
      }
      return (width: width.value, height: height.value);
    } finally {
      malloc
        ..free(nativePath)
        ..free(width)
        ..free(height);
    }
  }

  Uint8List renderPage(
    String path,
    int index, {
    required double targetWidth,
    required int quality,
    required NativeImageFormat format,
  }) {
    final nativePath = path.toNativeUtf8();
    final length = malloc<Int32>();
    try {
      final pointer = _renderPage(
        nativePath,
        index,
        targetWidth,
        quality,
        format.nativeValue,
        length,
      );
      if (pointer == nullptr) {
        throw NativePdfException(_errorOr('could not render the page'));
      }
      try {
        return Uint8List.fromList(pointer.asTypedList(length.value));
      } finally {
        _free(pointer.cast());
      }
    } finally {
      malloc
        ..free(nativePath)
        ..free(length);
    }
  }

  ({Uint8List bytes, int width, int height}) compressImage(
    Uint8List input, {
    required double maxDimension,
    required int quality,
    required NativeImageFormat format,
  }) {
    final source = malloc<Uint8>(input.length);
    final width = malloc<Int32>();
    final height = malloc<Int32>();
    final length = malloc<Int32>();
    try {
      source.asTypedList(input.length).setAll(0, input);
      final pointer = _compressImage(
        source,
        input.length,
        maxDimension,
        quality,
        format.nativeValue,
        width,
        height,
        length,
      );
      if (pointer == nullptr) {
        throw NativePdfException(_errorOr('could not compress the image'));
      }
      try {
        return (
          bytes: Uint8List.fromList(pointer.asTypedList(length.value)),
          width: width.value,
          height: height.value,
        );
      } finally {
        _free(pointer.cast());
      }
    } finally {
      malloc
        ..free(source)
        ..free(width)
        ..free(height)
        ..free(length);
    }
  }

  String _errorOr(String fallback) {
    final pointer = _lastError();
    if (pointer == nullptr) return fallback;
    final message = pointer.toDartString();
    return message.isEmpty ? fallback : message;
  }

  static DynamicLibrary _openLibrary() {
    if (Platform.isIOS) {
      return DynamicLibrary.process();
    }
    if (Platform.isMacOS) {
      for (final candidate in const [
        'build/libnative_pdf_kit.dylib',
        'libnative_pdf_kit.dylib',
      ]) {
        try {
          return DynamicLibrary.open(candidate);
        } on ArgumentError {
          // Try the next location.
        }
      }
      return DynamicLibrary.process();
    }
    throw UnsupportedError(
      'native_pdf_kit 0.1.0 supports iOS and macOS. '
      'Android support is planned for 0.2.0.',
    );
  }
}
