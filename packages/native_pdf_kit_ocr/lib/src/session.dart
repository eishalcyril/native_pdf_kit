import 'ocr_types.dart';

/// One poll of a native OCR job.
final class OcrPollResult {
  const OcrPollResult({
    required this.status,
    required this.progress,
    required this.stage,
    this.resultJson,
    this.error,
  });

  /// 1 running, 2 done, 3 cancelled, 4 failed.
  final int status;

  final double progress;
  final PdfOcrStage stage;
  final String? resultJson;
  final String? error;

  bool get isTerminal => status != 1;
  bool get isDone => status == 2;
  bool get isCancelled => status == 3;
  bool get isFailed => status == 4;
}

/// A native job that is polled from Dart.
abstract interface class OcrSession {
  OcrPollResult poll();

  void cancel();

  /// Releases the native handle. Idempotent.
  void release();
}

/// Starts native OCR jobs on one platform.
abstract interface class OcrPlatform {
  bool get isSupported;

  /// The engines this platform can run, in preference order.
  Set<PdfOcrEngine> get engines;

  OcrSession startPage({
    required String path,
    required int pageIndex,
    required String optionsJson,
  });

  OcrSession startImage({
    required List<int> bytes,
    required String optionsJson,
  });

  List<String> supportedLanguages({
    PdfOcrRecognitionLevel level = PdfOcrRecognitionLevel.accurate,
  });
}
