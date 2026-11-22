import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:native_pdf_kit/native_pdf_kit.dart';

import 'android_ocr.dart';
import 'apple_ocr.dart';
import 'ocr_result_parser.dart';
import 'ocr_types.dart';
import 'session.dart';

/// OCR and text extraction with realtime progress.
///
/// A job walks the pages in order. On Android, the PDF text layer is read once
/// with the pure-Dart extractor, in a background isolate; pages without a
/// usable text layer go through ML Kit or LiteRT. On Apple platforms the native
/// worker tries PDFKit first, then Vision, and reports Vision progress while it
/// runs.
///
/// The returned stream emits [PdfOcrProgress] while a page is in flight,
/// [PdfOcrPageEvent] as each page finishes, and a final [PdfOcrDoneEvent].
/// Cancel the subscription to stop the native job cooperatively.
abstract final class NativePdfOcr {
  /// Whether an OCR engine is available on this platform.
  static bool get isSupported =>
      Platform.isIOS || Platform.isMacOS || Platform.isAndroid;

  /// The engines the current platform can run.
  static Set<PdfOcrEngine> get availableEngines {
    if (Platform.isAndroid) return AndroidOcrPlatform.instance.engines;
    if (Platform.isIOS || Platform.isMacOS) {
      return AppleOcrPlatform.instance.engines;
    }
    return const {};
  }

  /// Languages the current OS engine advertises, best effort.
  static List<String> supportedLanguages({
    PdfOcrRecognitionLevel level = PdfOcrRecognitionLevel.accurate,
  }) {
    if (!isSupported) return const [];
    return _platform().supportedLanguages(level: level);
  }

  /// Recognizes [document], page by page.
  ///
  /// [pages] limits the job to those zero-based indexes; when null every page
  /// is processed in order.
  static Stream<PdfOcrEvent> recognizeDocument(
    NativePdfDocument document, {
    PdfOcrOptions options = const PdfOcrOptions(),
    Set<int>? pages,
  }) async* {
    options.validate();
    if (!isSupported) {
      throw const PdfOcrException(
        'OCR is supported on iOS, macOS and Android.',
      );
    }
    final platform = _platform();
    final resolvedEngine = _resolveEngine(platform, options.engine);
    final indexes = pages == null
        ? List<int>.generate(document.pageCount, (index) => index)
        : (pages.toList()..sort());
    for (final index in indexes) {
      if (index < 0 || index >= document.pageCount) {
        throw ArgumentError.value(
          index,
          'pages',
          'page index is out of range for ${document.pageCount} pages',
        );
      }
    }
    if (indexes.isEmpty) {
      throw ArgumentError.value(pages, 'pages', 'no pages selected');
    }

    final total = indexes.length;
    final started = Stopwatch()..start();
    final results = <int, PdfOcrPage>{};
    final errors = <int, String>{};
    final engines = <String>{};
    var completed = 0;

    final useDartTextLayer =
        Platform.isAndroid && options.mode != PdfOcrMode.ocrOnly;
    Map<int, PdfPageText> textLayers = const {};
    if (useDartTextLayer) {
      yield PdfOcrProgress(
        pageIndex: indexes.first,
        pageCount: total,
        completedPages: 0,
        pageProgress: 0,
        overallProgress: 0,
        stage: PdfOcrStage.textLayer,
      );
      textLayers = await _readAndroidTextLayers(document.path);
    }

    for (final index in indexes) {
      final pageStarted = Stopwatch()..start();

      if (useDartTextLayer) {
        final layer = textLayers[index];
        final usable =
            layer != null &&
            layer.characterCount >= options.minTextLayerCharacters;
        if (usable || options.mode == PdfOcrMode.textLayerOnly) {
          final size = _pageSize(document, index);
          final page = dartTextPage(
            index,
            layer?.text ?? '',
            width: size.width,
            height: size.height,
            includeLineBoxes: false,
          );
          results[index] = page;
          engines.add(page.engine);
          completed++;
          yield PdfOcrProgress(
            pageIndex: index,
            pageCount: total,
            completedPages: completed,
            pageProgress: 1,
            overallProgress: completed / total,
            stage: PdfOcrStage.textLayer,
          );
          yield PdfOcrPageEvent(page);
          continue;
        }
      }

      OcrSession session;
      try {
        session = _startPage(
          platform,
          document.path,
          index,
          options,
          resolvedEngine,
        );
      } catch (error) {
        final message = error is PdfOcrException ? error.message : '$error';
        errors[index] = message;
        final page = failedOcrPage(
          index,
          message,
          duration: pageStarted.elapsed,
          engine: resolvedEngine.nativeName,
        );
        results[index] = page;
        completed++;
        yield PdfOcrPageEvent(page);
        if (!options.continueOnError) {
          throw PdfOcrException('page $index: $message');
        }
        continue;
      }

      _Outcome? outcome;
      await for (final event in _pollSession(
        session,
        options: options,
        pageIndex: index,
        pageCount: total,
        completedPages: completed,
      )) {
        if (event is _PollProgress) {
          yield event.progress;
        } else if (event is _PollOutcome) {
          outcome = event.outcome;
        }
      }
      if (outcome == null) return; // The subscription was cancelled.
      completed++;

      if (outcome.done && outcome.resultJson != null) {
        final page = parseOcrPageJson(
          index,
          outcome.resultJson!,
          duration: pageStarted.elapsed,
          includeLineBoxes: options.includeLineBoxes,
        );
        results[index] = page;
        engines.add(page.engine);
        yield PdfOcrPageEvent(page);
      } else if (outcome.cancelled) {
        return;
      } else {
        final message = outcome.error ?? 'OCR failed';
        errors[index] = message;
        final page = failedOcrPage(
          index,
          message,
          duration: pageStarted.elapsed,
          engine: resolvedEngine.nativeName,
        );
        results[index] = page;
        yield PdfOcrPageEvent(page);
        if (!options.continueOnError) {
          throw PdfOcrException('page $index: $message');
        }
      }
      yield PdfOcrProgress(
        pageIndex: index,
        pageCount: total,
        completedPages: completed,
        pageProgress: 1,
        overallProgress: completed / total,
        stage: PdfOcrStage.done,
      );
    }

    final ordered = results.values.toList()
      ..sort((left, right) => left.index.compareTo(right.index));
    final text = ordered
        .where((page) => page.hasText)
        .map((page) => page.text.trim())
        .join('\n\n');
    final result = PdfOcrDocument(
      pages: ordered,
      text: text,
      engines: engines,
      duration: started.elapsed,
      errors: errors,
    );
    yield PdfOcrDoneEvent(result);
  }

  /// Recognizes an encoded PNG/JPEG image.
  static Stream<PdfOcrEvent> recognizeImage(
    Uint8List bytes, {
    PdfOcrOptions options = const PdfOcrOptions(),
  }) async* {
    options.validate();
    if (options.mode == PdfOcrMode.textLayerOnly) {
      throw ArgumentError(
        'PdfOcrMode.textLayerOnly is not valid for an image; use auto or '
        'ocrOnly.',
      );
    }
    if (!isSupported) {
      throw const PdfOcrException(
        'OCR is supported on iOS, macOS and Android.',
      );
    }
    if (bytes.isEmpty) {
      throw ArgumentError.value(bytes, 'bytes', 'the image is empty');
    }
    final platform = _platform();
    final resolvedEngine = _resolveEngine(platform, options.engine);
    final started = Stopwatch()..start();
    final pageStarted = Stopwatch()..start();
    final session = platform.startImage(
      bytes: bytes,
      optionsJson: jsonEncode({
        ...options.toJson(),
        'engine': resolvedEngine.nativeName,
      }),
    );

    _Outcome? outcome;
    await for (final event in _pollSession(
      session,
      options: options,
      pageIndex: 0,
      pageCount: 1,
      completedPages: 0,
    )) {
      if (event is _PollProgress) {
        yield event.progress;
      } else if (event is _PollOutcome) {
        outcome = event.outcome;
      }
    }
    if (outcome == null || outcome.cancelled) return;

    if (!outcome.done || outcome.resultJson == null) {
      final message = outcome.error ?? 'OCR failed';
      final page = failedOcrPage(
        0,
        message,
        duration: pageStarted.elapsed,
        engine: resolvedEngine.nativeName,
      );
      yield PdfOcrPageEvent(page);
      if (!options.continueOnError) {
        throw PdfOcrException(message);
      }
      yield PdfOcrDoneEvent(
        PdfOcrDocument(
          pages: [page],
          text: '',
          engines: {resolvedEngine.nativeName},
          duration: started.elapsed,
          errors: {0: message},
        ),
      );
      return;
    }

    final page = parseOcrPageJson(
      0,
      outcome.resultJson!,
      duration: pageStarted.elapsed,
      includeLineBoxes: options.includeLineBoxes,
    );
    yield PdfOcrPageEvent(page);
    yield PdfOcrDoneEvent(
      PdfOcrDocument(
        pages: [page],
        text: page.text.trim(),
        engines: {page.engine},
        duration: started.elapsed,
        errors: const {},
      ),
    );
  }

  /// Drains [recognizeDocument] and returns its result.
  static Future<PdfOcrDocument> extractDocument(
    NativePdfDocument document, {
    PdfOcrOptions options = const PdfOcrOptions(),
    Set<int>? pages,
  }) async {
    await for (final event in recognizeDocument(
      document,
      options: options,
      pages: pages,
    )) {
      if (event is PdfOcrDoneEvent) return event.document;
    }
    throw const PdfOcrException('the OCR job ended without a result');
  }

  /// Drains [recognizeImage] and returns its result.
  static Future<PdfOcrDocument> extractImage(
    Uint8List bytes, {
    PdfOcrOptions options = const PdfOcrOptions(),
  }) async {
    await for (final event in recognizeImage(bytes, options: options)) {
      if (event is PdfOcrDoneEvent) return event.document;
    }
    throw const PdfOcrException('the OCR job ended without a result');
  }

  static OcrPlatform _platform() {
    if (Platform.isIOS || Platform.isMacOS) {
      return AppleOcrPlatform.instance;
    }
    if (Platform.isAndroid) return AndroidOcrPlatform.instance;
    throw const PdfOcrException('OCR is supported on iOS, macOS and Android.');
  }

  static PdfOcrEngine _resolveEngine(
    OcrPlatform platform,
    PdfOcrEngine requested,
  ) {
    if (requested == PdfOcrEngine.auto) {
      return Platform.isAndroid ? PdfOcrEngine.mlKit : PdfOcrEngine.appleVision;
    }
    if (!platform.engines.contains(requested)) {
      throw PdfOcrException(
        '${requested.name} is not available on this platform; use '
        'auto or one of ${platform.engines.map((e) => e.name).join(', ')}.',
      );
    }
    return requested;
  }

  static OcrSession _startPage(
    OcrPlatform platform,
    String path,
    int index,
    PdfOcrOptions options,
    PdfOcrEngine engine,
  ) {
    final json = jsonEncode({...options.toJson(), 'engine': engine.nativeName});
    return platform.startPage(path: path, pageIndex: index, optionsJson: json);
  }

  static Future<Map<int, PdfPageText>> _readAndroidTextLayers(
    String path,
  ) async {
    try {
      final bytes = await File(path).readAsBytes();
      final pages = await Isolate.run(
        () => PdfTextExtractor.extractPages(bytes),
      );
      return {for (final page in pages) page.index: page};
    } catch (_) {
      // The text layer is an optimization; OCR still works without it.
      return const {};
    }
  }

  static PdfPageSize _pageSize(NativePdfDocument document, int index) {
    try {
      return document.pageSize(index);
    } catch (_) {
      return const PdfPageSize(0, 0);
    }
  }
}

/// The outcome of one native page job.
final class _Outcome {
  const _Outcome({
    required this.done,
    required this.cancelled,
    this.resultJson,
    this.error,
  });

  final bool done;
  final bool cancelled;
  final String? resultJson;
  final String? error;
}

sealed class _PollEvent {
  const _PollEvent();
}

final class _PollProgress extends _PollEvent {
  const _PollProgress(this.progress);

  final PdfOcrProgress progress;
}

final class _PollOutcome extends _PollEvent {
  const _PollOutcome(this.outcome);

  final _Outcome outcome;
}

/// Polls one native job and emits progress plus a single terminal outcome.
Stream<_PollEvent> _pollSession(
  OcrSession session, {
  required PdfOcrOptions options,
  required int pageIndex,
  required int pageCount,
  required int completedPages,
}) async* {
  var lastEmit = 0;
  var lastStage = PdfOcrStage.preparing;
  try {
    while (true) {
      final poll = session.poll();
      final now = DateTime.now().microsecondsSinceEpoch;
      final shouldEmit =
          poll.isTerminal ||
          poll.stage != lastStage ||
          now - lastEmit >= options.progressInterval.inMicroseconds;
      if (shouldEmit) {
        lastEmit = now;
        lastStage = poll.stage;
        yield _PollProgress(
          PdfOcrProgress(
            pageIndex: pageIndex,
            pageCount: pageCount,
            completedPages: completedPages,
            pageProgress: poll.progress,
            overallProgress:
                (completedPages + poll.progress) /
                (pageCount == 0 ? 1 : pageCount),
            stage: poll.isTerminal ? PdfOcrStage.done : poll.stage,
          ),
        );
      }
      if (poll.isTerminal) {
        yield _PollOutcome(
          _Outcome(
            done: poll.isDone,
            cancelled: poll.isCancelled,
            resultJson: poll.resultJson,
            error: poll.error,
          ),
        );
        return;
      }
      await Future<void>.delayed(options.progressInterval);
    }
  } finally {
    session.cancel();
    session.release();
  }
}
