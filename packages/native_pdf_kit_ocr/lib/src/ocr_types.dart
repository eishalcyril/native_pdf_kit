/// Public types for `native_pdf_kit_ocr`.
library;

import 'dart:io';

/// Which on-device engine to use.
enum PdfOcrEngine {
  /// Apple Vision on iOS/macOS, ML Kit on Android.
  auto('auto'),

  /// Apple Vision (Apple platforms only).
  appleVision('vision'),

  /// Google ML Kit Text Recognition v2 (Android only).
  mlKit('mlkit'),

  /// LiteRT + PP-OCRv5 (Android only, models must be installed by the app).
  liteRt('litert');

  const PdfOcrEngine(this.nativeName);

  final String nativeName;
}

/// How a page's text is obtained.
enum PdfOcrMode {
  /// Use the PDF text layer when it is usable, otherwise OCR.
  auto('auto'),

  /// Only read the PDF text layer; never OCR.
  textLayerOnly('text'),

  /// Always OCR, even when the page has a text layer.
  ocrOnly('ocr');

  const PdfOcrMode(this.nativeName);

  final String nativeName;
}

/// Apple Vision has a fast and an accurate recognition path.
enum PdfOcrRecognitionLevel {
  fast('fast'),
  accurate('accurate');

  const PdfOcrRecognitionLevel(this.nativeName);

  final String nativeName;
}

/// Script for the Android ML Kit recognizer.
///
/// The Latin model ships with the base dependency. The other scripts need
/// their ML Kit artifact in the app (for example
/// `com.google.mlkit:text-recognition-chinese:16.0.1`); the engine falls back
/// to Latin when the model is not installed.
enum PdfOcrScript {
  latin('latin'),
  chinese('chinese'),
  devanagari('devanagari'),
  japanese('japanese'),
  korean('korean');

  const PdfOcrScript(this.nativeName);

  final String nativeName;
}

/// Model files for the LiteRT PP-OCRv5 engine.
///
/// The models are not bundled with this package. Point these at files the app
/// has downloaded, or fetch them with `tool/fetch_litert_ocr_models.sh`.
final class PdfLiteRtModels {
  /// Creates the model paths for the LiteRT PP-OCRv5 engine.
  const PdfLiteRtModels({
    required this.detectorPath,
    required this.recognizerPath,
    required this.dictionaryPath,
    this.threads = 4,
  });

  /// PP-OCRv5 text detection model (`.tflite`).
  final String detectorPath;

  /// PP-OCRv5 text recognition model (`.tflite`).
  final String recognizerPath;

  /// The CTC dictionary (UTF-8 text file).
  final String dictionaryPath;

  /// CPU threads used by LiteRT.
  final int threads;

  /// Serializes the model paths for the native bridge.
  Map<String, Object?> toJson() => {
    'detModel': detectorPath,
    'recModel': recognizerPath,
    'dictionary': dictionaryPath,
    'threads': threads,
  };
}

/// Where a page's text came from.
enum PdfOcrPageSource { textLayer, ocr }

/// A normalized box in page space, origin top-left, values in 0..1.
final class PdfOcrBox {
  /// Creates a box from normalized page coordinates.
  const PdfOcrBox(this.left, this.top, this.width, this.height);

  /// Distance from the left page edge, 0..1.
  final double left;

  /// Distance from the top page edge, 0..1.
  final double top;

  /// Box width, 0..1.
  final double width;

  /// Box height, 0..1.
  final double height;

  /// Right page edge (`left + width`).
  double get right => left + width;

  /// Bottom page edge (`top + height`).
  double get bottom => top + height;

  @override
  String toString() =>
      'PdfOcrBox(${left.toStringAsFixed(3)}, ${top.toStringAsFixed(3)}, '
      '${width.toStringAsFixed(3)}, ${height.toStringAsFixed(3)})';
}

/// One recognized line.
final class PdfOcrLine {
  /// Creates one recognized line.
  const PdfOcrLine({required this.text, required this.confidence, this.box});

  /// The recognized text.
  final String text;

  /// 0..1. Text-layer lines report 1.0.
  final double confidence;

  /// Normalized box, or null when the engine did not provide one.
  final PdfOcrBox? box;

  @override
  String toString() => 'PdfOcrLine(${confidence.toStringAsFixed(2)}: $text)';
}

/// One page of text.
final class PdfOcrPage {
  /// Creates a page result.
  const PdfOcrPage({
    required this.index,
    required this.text,
    required this.lines,
    required this.source,
    required this.engine,
    required this.width,
    required this.height,
    this.duration = Duration.zero,
    this.error,
  });

  /// Zero-based page index.
  final int index;

  /// The page text.
  final String text;

  /// Recognized lines, in engine order.
  final List<PdfOcrLine> lines;

  /// Whether the text came from the PDF text layer or OCR.
  final PdfOcrPageSource source;

  /// `apple-vision`, `pdfkit`, `mlkit`, `litert` or `dart-text`.
  final String engine;

  /// Pixel width of the image the text was measured on, or page width for the
  /// text layer.
  final double width;

  /// Pixel height of the image the text was measured on.
  final double height;

  /// Time spent on this page.
  final Duration duration;

  /// Non-null when this page failed and [text] is empty.
  final String? error;

  /// Whether the page has any non-whitespace text.
  bool get hasText => text.trim().isNotEmpty;

  /// Number of non-whitespace characters.
  int get characterCount => text.replaceAll(RegExp(r'\s'), '').length;

  @override
  String toString() => 'PdfOcrPage($index, $engine, $characterCount chars)';
}

/// The result of a document or image job.
final class PdfOcrDocument {
  /// Creates a document result.
  const PdfOcrDocument({
    required this.pages,
    required this.text,
    required this.engines,
    required this.duration,
    required this.errors,
  });

  /// Page results in document order.
  final List<PdfOcrPage> pages;

  /// All page text, separated by a blank line.
  final String text;

  /// Distinct engine names used.
  final Set<String> engines;

  /// Total job time.
  final Duration duration;

  /// Page indexes that failed, with their messages.
  final Map<int, String> errors;

  /// Whether the document has any non-whitespace text.
  bool get hasText => text.trim().isNotEmpty;

  /// Number of non-whitespace characters across all pages.
  int get characterCount => text.replaceAll(RegExp(r'\s'), '').length;

  @override
  String toString() =>
      'PdfOcrDocument(${pages.length} pages, '
      '${errors.length} errors, $characterCount chars)';
}

/// Options shared by the document and image APIs.
final class PdfOcrOptions {
  /// Creates OCR options. Defaults use the platform engine and auto mode.
  const PdfOcrOptions({
    this.mode = PdfOcrMode.auto,
    this.engine = PdfOcrEngine.auto,
    this.languages = const <String>[],
    this.recognitionLevel = PdfOcrRecognitionLevel.accurate,
    this.languageCorrection = true,
    this.detectLanguage = false,
    this.renderWidth = 2000,
    this.minTextLayerCharacters = 12,
    this.includeLineBoxes = true,
    this.script = PdfOcrScript.latin,
    this.liteRtModels,
    this.continueOnError = true,
    this.progressInterval = const Duration(milliseconds: 80),
  });

  /// Text-layer first, OCR only, or text-layer only.
  final PdfOcrMode mode;

  /// Engine preference. On Apple platforms only [PdfOcrEngine.appleVision] is
  /// available; on Android [PdfOcrEngine.auto] resolves to ML Kit.
  final PdfOcrEngine engine;

  /// BCP-47 language hints, in priority order (for example `['en-US']`).
  ///
  /// Leave empty to let the engine choose. Apple Vision uses the list directly;
  /// ML Kit selects its script model from [script].
  final List<String> languages;

  final PdfOcrRecognitionLevel recognitionLevel;

  /// Language correction is good for prose and can hurt serial numbers.
  final bool languageCorrection;

  /// Let Apple Vision detect the language automatically (iOS 16+/macOS 13+).
  final bool detectLanguage;

  /// Raster width in pixels. For images this is the maximum edge.
  final double renderWidth;

  /// A page with at least this many non-whitespace characters is treated as a
  /// born-digital page and does not go through OCR in [PdfOcrMode.auto].
  final int minTextLayerCharacters;

  /// Keep per-line boxes in [PdfOcrPage.lines].
  final bool includeLineBoxes;

  /// ML Kit script model.
  final PdfOcrScript script;

  /// Required for [PdfOcrEngine.liteRt].
  final PdfLiteRtModels? liteRtModels;

  /// Continue with the remaining pages when one page fails.
  final bool continueOnError;

  /// How often the native job is polled while it runs.
  final Duration progressInterval;

  /// Validates the combination of options.
  void validate() {
    if (renderWidth < 200 || renderWidth > 8000) {
      throw ArgumentError.value(
        renderWidth,
        'renderWidth',
        'must be between 200 and 8000',
      );
    }
    if (minTextLayerCharacters < 0) {
      throw ArgumentError.value(
        minTextLayerCharacters,
        'minTextLayerCharacters',
        'must not be negative',
      );
    }
    if (engine == PdfOcrEngine.liteRt && liteRtModels == null) {
      throw ArgumentError(
        'PdfOcrEngine.liteRt requires PdfOcrOptions.liteRtModels',
      );
    }
    if (progressInterval < const Duration(milliseconds: 16)) {
      throw ArgumentError.value(
        progressInterval,
        'progressInterval',
        'must be at least 16 ms',
      );
    }
  }

  Map<String, Object?> toJson() => {
    'mode': mode.nativeName,
    'engine': engine.nativeName,
    'languages': languages,
    'textLevel': recognitionLevel.nativeName,
    'languageCorrection': languageCorrection,
    'detectLanguage': detectLanguage,
    'renderWidth': renderWidth,
    'minTextChars': minTextLayerCharacters,
    'includeLineBoxes': includeLineBoxes,
    'script': script.nativeName,
    if (liteRtModels != null) 'liteRt': liteRtModels!.toJson(),
  };

  PdfOcrOptions copyWith({
    PdfOcrMode? mode,
    PdfOcrEngine? engine,
    List<String>? languages,
    PdfOcrRecognitionLevel? recognitionLevel,
    bool? languageCorrection,
    bool? detectLanguage,
    double? renderWidth,
    int? minTextLayerCharacters,
    bool? includeLineBoxes,
    PdfOcrScript? script,
    PdfLiteRtModels? liteRtModels,
    bool? continueOnError,
    Duration? progressInterval,
  }) {
    return PdfOcrOptions(
      mode: mode ?? this.mode,
      engine: engine ?? this.engine,
      languages: languages ?? this.languages,
      recognitionLevel: recognitionLevel ?? this.recognitionLevel,
      languageCorrection: languageCorrection ?? this.languageCorrection,
      detectLanguage: detectLanguage ?? this.detectLanguage,
      renderWidth: renderWidth ?? this.renderWidth,
      minTextLayerCharacters:
          minTextLayerCharacters ?? this.minTextLayerCharacters,
      includeLineBoxes: includeLineBoxes ?? this.includeLineBoxes,
      script: script ?? this.script,
      liteRtModels: liteRtModels ?? this.liteRtModels,
      continueOnError: continueOnError ?? this.continueOnError,
      progressInterval: progressInterval ?? this.progressInterval,
    );
  }
}

/// A progress update while a job runs.
final class PdfOcrProgress extends PdfOcrEvent {
  /// Creates a progress event.
  const PdfOcrProgress({
    required this.pageIndex,
    required this.pageCount,
    required this.completedPages,
    required this.pageProgress,
    required this.overallProgress,
    required this.stage,
  });

  /// Zero-based page currently being processed.
  final int pageIndex;

  /// Total pages in this job.
  final int pageCount;

  /// Pages already finished.
  final int completedPages;

  /// 0..1 inside the current page.
  final double pageProgress;

  /// 0..1 for the whole job.
  final double overallProgress;

  final PdfOcrStage stage;

  @override
  String toString() =>
      'PdfOcrProgress(${overallProgress.toStringAsFixed(2)}, $stage)';
}

/// The stage of the current page.
enum PdfOcrStage {
  preparing,
  textLayer,
  rendering,
  recognizing,
  done;

  static PdfOcrStage fromNative(int value) => switch (value) {
    1 => PdfOcrStage.textLayer,
    2 => PdfOcrStage.rendering,
    3 => PdfOcrStage.recognizing,
    _ => PdfOcrStage.preparing,
  };
}

/// One page finished.
final class PdfOcrPageEvent extends PdfOcrEvent {
  /// Creates a page event.
  const PdfOcrPageEvent(this.page);

  /// The page that just finished.
  final PdfOcrPage page;
}

/// The job finished.
final class PdfOcrDoneEvent extends PdfOcrEvent {
  /// Creates the terminal event.
  const PdfOcrDoneEvent(this.document);

  /// The complete result.
  final PdfOcrDocument document;
}

/// Base event type.
sealed class PdfOcrEvent {
  /// Base event.
  const PdfOcrEvent();
}

/// Thrown when the native OCR backend cannot run.
final class PdfOcrException implements Exception {
  /// Creates an exception with a human-readable [message].
  const PdfOcrException(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => 'PdfOcrException: $message';
}

/// What this package can do on the current platform.
abstract final class PdfOcrCapabilities {
  /// Whether an OCR engine is available.
  static bool get ocr =>
      (Platform.isIOS || Platform.isMacOS) || Platform.isAndroid;

  /// Whether a native PDF text layer is available (PDFKit on Apple).
  static bool get nativeTextLayer => Platform.isIOS || Platform.isMacOS;

  /// Whether the LiteRT backend can be used. It also needs model files.
  static bool get liteRt => Platform.isAndroid;

  /// Whether on-device OCR with line boxes is available.
  static bool get lineBoxes => ocr;
}
