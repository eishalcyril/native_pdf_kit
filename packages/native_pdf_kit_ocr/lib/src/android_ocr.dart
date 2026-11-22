import 'dart:convert';
import 'dart:io';

import 'package:jni/jni.dart' as jni;

import 'ocr_types.dart';
import 'session.dart';

/// Android backend: ML Kit Text Recognition v2 or LiteRT + PP-OCRv5.
///
/// The Java bridge owns the worker thread, renders pages with PdfRenderer and
/// exposes a pollable session, so the Dart isolate never blocks on OCR.
final class AndroidOcrPlatform implements OcrPlatform {
  AndroidOcrPlatform._();

  static final AndroidOcrPlatform instance = AndroidOcrPlatform._();

  static jni.JClass? _cachedClass;

  @override
  bool get isSupported => Platform.isAndroid;

  @override
  Set<PdfOcrEngine> get engines => const {
    PdfOcrEngine.mlKit,
    PdfOcrEngine.liteRt,
  };

  static jni.JClass get _class {
    final cached = _cachedClass;
    if (cached != null) return cached;
    try {
      return _cachedClass = jni.JClass.forName(
        'com/eishal/native_pdf_kit_ocr/OcrBridge',
      );
    } catch (error) {
      throw PdfOcrException('the Android OCR bridge is not available: $error');
    }
  }

  @override
  OcrSession startPage({
    required String path,
    required int pageIndex,
    required String optionsJson,
  }) {
    final id = _call(
      'startPage',
      '(Ljava/lang/String;ILjava/lang/String;)Ljava/lang/String;',
      [path.toJString(), jni.JValueInt(pageIndex), optionsJson.toJString()],
    );
    if (id == null || id.isEmpty) {
      throw const PdfOcrException('could not start the Android OCR job');
    }
    return AndroidOcrSession(id);
  }

  @override
  OcrSession startImage({
    required List<int> bytes,
    required String optionsJson,
  }) {
    if (bytes.isEmpty) {
      throw const PdfOcrException('the image is empty');
    }
    final data = jni.JByteArray.of(bytes);
    final options = optionsJson.toJString();
    try {
      final id = _call(
        'startImage',
        '([BLjava/lang/String;)Ljava/lang/String;',
        [data, options],
      );
      if (id == null || id.isEmpty) {
        throw const PdfOcrException('could not start the Android OCR job');
      }
      return AndroidOcrSession(id);
    } finally {
      data.release();
      options.release();
    }
  }

  @override
  List<String> supportedLanguages({
    PdfOcrRecognitionLevel level = PdfOcrRecognitionLevel.accurate,
  }) {
    final options = '{"textLevel":"${level.nativeName}"}'.toJString();
    try {
      final json = _call(
        'supportedLanguages',
        '(Ljava/lang/String;)Ljava/lang/String;',
        [options],
      );
      if (json == null || json.isEmpty) return const [];
      final decoded = jsonDecode(json);
      if (decoded is List) {
        return decoded.whereType<String>().toList(growable: false);
      }
    } catch (_) {
      // Fall through.
    } finally {
      options.release();
    }
    return const [];
  }

  String? _call(String name, String signature, List<Object?> args) {
    try {
      final id = _class.staticMethodId(name, signature);
      final result = id.callNullable(_class, jni.JString.type, args);
      if (result == null) return null;
      try {
        return result.toDartString();
      } finally {
        result.release();
      }
    } on PdfOcrException {
      rethrow;
    } catch (error) {
      throw PdfOcrException('Android OCR call $name failed: $error');
    }
  }
}

/// A pollable Android OCR job identified by its Java session id.
final class AndroidOcrSession implements OcrSession {
  AndroidOcrSession(this._id);

  final String _id;
  bool _released = false;

  @override
  OcrPollResult poll() {
    if (_released) {
      return const OcrPollResult(
        status: 3,
        progress: 1,
        stage: PdfOcrStage.done,
      );
    }
    final id = _id.toJString();
    try {
      final json = AndroidOcrPlatform.instance._call(
        'poll',
        '(Ljava/lang/String;)Ljava/lang/String;',
        [id],
      );
      if (json == null || json.isEmpty) {
        return const OcrPollResult(
          status: 4,
          progress: 0,
          stage: PdfOcrStage.preparing,
          error: 'the Android OCR job returned no status',
        );
      }
      final decoded = jsonDecode(json);
      if (decoded is! Map) {
        return OcrPollResult(
          status: 4,
          progress: 0,
          stage: PdfOcrStage.preparing,
          error: 'invalid Android OCR status: $json',
        );
      }
      return OcrPollResult(
        status: _asInt(decoded['status']) ?? 4,
        progress: (_asDouble(decoded['progress']) ?? 0).clamp(0.0, 1.0),
        stage: PdfOcrStage.fromNative(_asInt(decoded['stage']) ?? 0),
        resultJson: decoded['result'] is String
            ? decoded['result'] as String
            : null,
        error: decoded['error'] is String ? decoded['error'] as String : null,
      );
    } catch (error) {
      return OcrPollResult(
        status: 4,
        progress: 0,
        stage: PdfOcrStage.preparing,
        error: 'could not poll the Android OCR job: $error',
      );
    } finally {
      id.release();
    }
  }

  @override
  void cancel() {
    if (_released) return;
    _callWithoutResult('cancel');
  }

  @override
  void release() {
    if (_released) return;
    _released = true;
    _callWithoutResult('release');
  }

  void _callWithoutResult(String name) {
    final id = _id.toJString();
    try {
      AndroidOcrPlatform.instance._call(
        name,
        '(Ljava/lang/String;)Ljava/lang/String;',
        [id],
      );
    } catch (_) {
      // Cancellation and release must never throw on a closing stream.
    } finally {
      id.release();
    }
  }

  static int? _asInt(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static double? _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}
