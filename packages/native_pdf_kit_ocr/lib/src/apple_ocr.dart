import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'ocr_types.dart';
import 'session.dart';

/// Apple Vision + PDFKit backend, reached through the package's C surface.
final class AppleOcrPlatform implements OcrPlatform {
  AppleOcrPlatform._();

  static final AppleOcrPlatform instance = AppleOcrPlatform._();

  @override
  bool get isSupported => Platform.isIOS || Platform.isMacOS;

  @override
  Set<PdfOcrEngine> get engines => const {PdfOcrEngine.appleVision};

  AppleOcrBindings get _bindings => AppleOcrBindings.instance;

  @override
  OcrSession startPage({
    required String path,
    required int pageIndex,
    required String optionsJson,
  }) {
    final nativePath = path.toNativeUtf8();
    final nativeOptions = optionsJson.toNativeUtf8();
    try {
      final handle = _bindings.pageStart(nativePath, pageIndex, nativeOptions);
      if (handle == nullptr) {
        throw const PdfOcrException('could not start the Vision job');
      }
      return AppleOcrSession(handle);
    } finally {
      malloc
        ..free(nativePath)
        ..free(nativeOptions);
    }
  }

  @override
  OcrSession startImage({
    required List<int> bytes,
    required String optionsJson,
  }) {
    if (bytes.isEmpty) {
      throw const PdfOcrException('the image is empty');
    }
    final source = malloc<Uint8>(bytes.length);
    final nativeOptions = optionsJson.toNativeUtf8();
    try {
      source.asTypedList(bytes.length).setAll(0, bytes);
      final handle = _bindings.imageStart(source, bytes.length, nativeOptions);
      if (handle == nullptr) {
        throw const PdfOcrException('could not start the Vision job');
      }
      return AppleOcrSession(handle);
    } finally {
      malloc
        ..free(source)
        ..free(nativeOptions);
    }
  }

  @override
  List<String> supportedLanguages({
    PdfOcrRecognitionLevel level = PdfOcrRecognitionLevel.accurate,
  }) {
    final options = '{"textLevel":"${level.nativeName}"}'.toNativeUtf8();
    try {
      final pointer = _bindings.supportedLanguages(options);
      if (pointer == nullptr) return const [];
      try {
        final decoded = pointer.toDartString();
        return _decodeLanguages(decoded);
      } finally {
        _bindings.stringFree(pointer);
      }
    } finally {
      malloc.free(options);
    }
  }

  static List<String> _decodeLanguages(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is List) {
        return decoded.whereType<String>().toList(growable: false);
      }
    } catch (_) {
      // Fall through to an empty list.
    }
    return const [];
  }
}

/// A pollable Vision job.
final class AppleOcrSession implements OcrSession {
  AppleOcrSession(this._handle);

  final Pointer<Void> _handle;
  bool _released = false;

  AppleOcrBindings get _bindings => AppleOcrBindings.instance;

  @override
  OcrPollResult poll() {
    if (_released) {
      return const OcrPollResult(
        status: 3,
        progress: 1,
        stage: PdfOcrStage.done,
      );
    }
    final progress = malloc<Double>();
    final stage = malloc<Int32>();
    try {
      final status = _bindings.poll(_handle, progress, stage);
      return OcrPollResult(
        status: status,
        progress: progress.value.clamp(0.0, 1.0),
        stage: PdfOcrStage.fromNative(stage.value),
        resultJson: status == 2 ? _readString(_bindings.result(_handle)) : null,
        error: status == 4 ? _readString(_bindings.error(_handle)) : null,
      );
    } finally {
      malloc
        ..free(progress)
        ..free(stage);
    }
  }

  @override
  void cancel() {
    if (_released) return;
    _bindings.cancel(_handle);
  }

  @override
  void release() {
    if (_released) return;
    _released = true;
    _bindings.release(_handle);
  }

  static String? _readString(Pointer<Utf8> pointer) {
    if (pointer == nullptr) return null;
    final value = pointer.toDartString();
    return value.isEmpty ? null : value;
  }
}

/// Direct bindings to `libnative_pdf_kit_ocr`.
final class AppleOcrBindings {
  AppleOcrBindings._(DynamicLibrary library)
    : _pageStart = library
          .lookupFunction<
            Pointer<Void> Function(Pointer<Utf8>, Int32, Pointer<Utf8>),
            Pointer<Void> Function(Pointer<Utf8>, int, Pointer<Utf8>)
          >('npdfocr_page_start'),
      _imageStart = library
          .lookupFunction<
            Pointer<Void> Function(Pointer<Uint8>, Int32, Pointer<Utf8>),
            Pointer<Void> Function(Pointer<Uint8>, int, Pointer<Utf8>)
          >('npdfocr_image_start'),
      _poll = library
          .lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Double>, Pointer<Int32>),
            int Function(Pointer<Void>, Pointer<Double>, Pointer<Int32>)
          >('npdfocr_poll'),
      _result = library
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<Void>),
            Pointer<Utf8> Function(Pointer<Void>)
          >('npdfocr_result'),
      _error = library
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<Void>),
            Pointer<Utf8> Function(Pointer<Void>)
          >('npdfocr_error'),
      _cancel = library
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('npdfocr_cancel'),
      _release = library
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('npdfocr_release'),
      _supportedLanguages = library
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<Utf8>),
            Pointer<Utf8> Function(Pointer<Utf8>)
          >('npdfocr_supported_languages'),
      _stringFree = library
          .lookupFunction<
            Void Function(Pointer<Utf8>),
            void Function(Pointer<Utf8>)
          >('npdfocr_string_free'),
      _available = library.lookupFunction<Int32 Function(), int Function()>(
        'npdfocr_available',
      );

  static AppleOcrBindings? _instance;

  static AppleOcrBindings get instance =>
      _instance ??= AppleOcrBindings._(_openLibrary());

  static bool get isAvailable => Platform.isIOS || Platform.isMacOS;

  final Pointer<Void> Function(Pointer<Utf8>, int, Pointer<Utf8>) _pageStart;
  final Pointer<Void> Function(Pointer<Uint8>, int, Pointer<Utf8>) _imageStart;
  final int Function(Pointer<Void>, Pointer<Double>, Pointer<Int32>) _poll;
  final Pointer<Utf8> Function(Pointer<Void>) _result;
  final Pointer<Utf8> Function(Pointer<Void>) _error;
  final void Function(Pointer<Void>) _cancel;
  final void Function(Pointer<Void>) _release;
  final Pointer<Utf8> Function(Pointer<Utf8>) _supportedLanguages;
  final void Function(Pointer<Utf8>) _stringFree;
  final int Function() _available;

  Pointer<Void> pageStart(
    Pointer<Utf8> path,
    int pageIndex,
    Pointer<Utf8> options,
  ) => _pageStart(path, pageIndex, options);

  Pointer<Void> imageStart(
    Pointer<Uint8> bytes,
    int length,
    Pointer<Utf8> options,
  ) => _imageStart(bytes, length, options);

  int poll(
    Pointer<Void> handle,
    Pointer<Double> progress,
    Pointer<Int32> stage,
  ) => _poll(handle, progress, stage);

  Pointer<Utf8> result(Pointer<Void> handle) => _result(handle);

  Pointer<Utf8> error(Pointer<Void> handle) => _error(handle);

  void cancel(Pointer<Void> handle) => _cancel(handle);

  void release(Pointer<Void> handle) => _release(handle);

  Pointer<Utf8> supportedLanguages(Pointer<Utf8> options) =>
      _supportedLanguages(options);

  void stringFree(Pointer<Utf8> value) => _stringFree(value);

  bool get isAvailableAtRuntime => _available() == 1;

  static DynamicLibrary _openLibrary() {
    if (Platform.isIOS) return DynamicLibrary.process();
    if (Platform.isMacOS) {
      for (final candidate in const [
        'build/libnative_pdf_kit_ocr.dylib',
        'libnative_pdf_kit_ocr.dylib',
      ]) {
        try {
          return DynamicLibrary.open(candidate);
        } on ArgumentError {
          // Try the next location.
        }
      }
      try {
        return DynamicLibrary.process();
      } on ArgumentError {
        // Fall through.
      }
    }
    throw UnsupportedError(
      'native_pdf_kit_ocr supports iOS, macOS and Android.',
    );
  }
}
