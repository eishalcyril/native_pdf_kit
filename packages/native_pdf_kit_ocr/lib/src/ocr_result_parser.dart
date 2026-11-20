import 'dart:convert';

import 'ocr_types.dart';

/// Parses the JSON contract shared by the Apple and Android backends.
PdfOcrPage parseOcrPageJson(
  int index,
  String json, {
  required Duration duration,
  bool includeLineBoxes = true,
}) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map) {
      return _failedPage(
        index,
        'the native engine returned an invalid result',
        duration,
      );
    }
    final source = decoded['source'] == 'text-layer'
        ? PdfOcrPageSource.textLayer
        : PdfOcrPageSource.ocr;
    final engine = decoded['engine'] is String
        ? decoded['engine'] as String
        : 'native';
    final text = decoded['text'] is String ? decoded['text'] as String : '';
    final lines = <PdfOcrLine>[];
    final rawLines = decoded['lines'];
    if (rawLines is List) {
      for (final raw in rawLines) {
        if (raw is! Map) continue;
        final lineText = raw['text'];
        if (lineText is! String || lineText.isEmpty) continue;
        final confidence = _asDouble(raw['confidence']) ?? 1.0;
        PdfOcrBox? box;
        if (includeLineBoxes) {
          final rawBox = raw['box'];
          if (rawBox is List && rawBox.length >= 4) {
            box = PdfOcrBox(
              _asDouble(rawBox[0]) ?? 0,
              _asDouble(rawBox[1]) ?? 0,
              _asDouble(rawBox[2]) ?? 0,
              _asDouble(rawBox[3]) ?? 0,
            );
          }
        }
        lines.add(
          PdfOcrLine(
            text: lineText,
            confidence: confidence.clamp(0.0, 1.0),
            box: box,
          ),
        );
      }
    }
    final resolvedText = text.isEmpty
        ? lines.map((line) => line.text).join('\n')
        : text;
    if (resolvedText.isEmpty) {
      return _failedPage(
        index,
        'the native engine found no text',
        duration,
      );
    }
    return PdfOcrPage(
      index: index,
      text: resolvedText,
      lines: lines,
      source: source,
      engine: engine,
      width: _asDouble(decoded['width']) ?? 0,
      height: _asDouble(decoded['height']) ?? 0,
      duration: duration,
    );
  } catch (error) {
    return _failedPage(index, 'could not read the native result: $error', duration);
  }
}

/// A page produced by the pure-Dart text-layer extractor (Android fallback).
PdfOcrPage dartTextPage(
  int index,
  String text, {
  required double width,
  required double height,
  bool includeLineBoxes = true,
}) {
  final trimmed = text.trim();
  return PdfOcrPage(
    index: index,
    text: trimmed,
    lines: trimmed.isEmpty
        ? const []
        : [
            PdfOcrLine(
              text: trimmed,
              confidence: 1,
              box: includeLineBoxes
                  ? const PdfOcrBox(0, 0, 1, 1)
                  : null,
            ),
          ],
    source: PdfOcrPageSource.textLayer,
    engine: 'dart-text',
    width: width,
    height: height,
  );
}

PdfOcrPage failedOcrPage(
  int index,
  String message, {
  required Duration duration,
  String engine = 'native',
}) => _failedPage(index, message, duration, engine: engine);

PdfOcrPage _failedPage(
  int index,
  String message,
  Duration duration, {
  String engine = 'native',
}) {
  return PdfOcrPage(
    index: index,
    text: '',
    lines: const [],
    source: PdfOcrPageSource.ocr,
    engine: engine,
    width: 0,
    height: 0,
    duration: duration,
    error: message,
  );
}

double? _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}
