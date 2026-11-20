import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:native_pdf_kit/native_pdf_kit.dart';
import 'package:native_pdf_kit_ocr/native_pdf_kit_ocr.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('extracts a document with the platform engine', (tester) async {
    final directory = Directory.systemTemp.createTempSync('npdf_ocr_device');
    addTearDown(() => directory.deleteSync(recursive: true));
    final pdf = File('${directory.path}/fixture.pdf')
      ..writeAsBytesSync(_buildPdf());

    final document = NativePdfDocument.open(pdf.path);
    final events = <PdfOcrEvent>[];
    await for (final event in NativePdfOcr.recognizeDocument(
      document,
      options: const PdfOcrOptions(
        mode: PdfOcrMode.ocrOnly,
        renderWidth: 1600,
        progressInterval: Duration(milliseconds: 40),
      ),
    )) {
      events.add(event);
    }

    final result = events.whereType<PdfOcrDoneEvent>().single.document;
    expect(result.pages, hasLength(2));
    expect(result.text.toLowerCase(), contains('native'));
    expect(result.text.toLowerCase(), contains('page'));
    expect(result.errors, isEmpty);
    expect(result.engines, isNotEmpty);
    expect(events.whereType<PdfOcrProgress>(), isNotEmpty);
    expect(
      events.whereType<PdfOcrProgress>().last.overallProgress,
      closeTo(1, 0.001),
    );
    // ignore: avoid_print
    print('device OCR: ${result.engines} in ${result.duration.inMilliseconds} ms');
  });

  testWidgets('runs the optional LiteRT PP-OCRv5 engine', (tester) async {
    var directory = '${Directory.systemTemp.path}/ppocr';
    if (!File('$directory/ppocr_det_fp16.tflite').existsSync() &&
        Directory('/data/local/tmp/ppocr').existsSync()) {
      directory = '/data/local/tmp/ppocr';
    }
    final models = PdfLiteRtModels(
      detectorPath: '$directory/ppocr_det_fp16.tflite',
      recognizerPath: '$directory/ppocr_rec_fp16.tflite',
      dictionaryPath: '$directory/ppocrv5_dict.txt',
    );
    if (!File(models.detectorPath).existsSync() ||
        !File(models.recognizerPath).existsSync() ||
        !File(models.dictionaryPath).existsSync()) {
      markTestSkipped('PP-OCRv5 models are not installed');
      return;
    }

    final work = Directory.systemTemp.createTempSync('npdf_ocr_litert');
    addTearDown(() => work.deleteSync(recursive: true));
    final pdf = File('${work.path}/fixture.pdf')
      ..writeAsBytesSync(_buildPdf());
    final document = NativePdfDocument.open(pdf.path);
    final png = document.renderPage(
      0,
      width: 1400,
      format: NativeImageFormat.png,
    );

    final result = await NativePdfOcr.extractImage(
      png,
      options: PdfOcrOptions(
        engine: PdfOcrEngine.liteRt,
        mode: PdfOcrMode.ocrOnly,
        liteRtModels: models,
        renderWidth: 1600,
      ),
    );

    // ignore: avoid_print
    print('LiteRT text: ${result.text}');
    expect(result.pages, hasLength(1));
    expect(result.pages.single.engine, 'litert');
    expect(result.text.toLowerCase(), contains('native'));
    expect(result.errors, isEmpty);
  });

  testWidgets('recognizes a rendered page image', (tester) async {
    final directory = Directory.systemTemp.createTempSync('npdf_ocr_image');
    addTearDown(() => directory.deleteSync(recursive: true));
    final pdf = File('${directory.path}/fixture.pdf')
      ..writeAsBytesSync(_buildPdf());
    final document = NativePdfDocument.open(pdf.path);
    final png = document.renderPage(
      0,
      width: 1400,
      format: NativeImageFormat.png,
    );

    final result = await NativePdfOcr.extractImage(
      png,
      options: const PdfOcrOptions(
        mode: PdfOcrMode.ocrOnly,
        renderWidth: 3000,
      ),
    );

    expect(result.pages, hasLength(1));
    expect(result.text.toLowerCase(), contains('native'));
    expect(result.errors, isEmpty);
  });
}

Uint8List _buildPdf() {
  final objects = <String>[];
  final kids = <String>[];
  objects.add('<< /Type /Catalog /Pages 2 0 R >>');
  objects.add('');
  objects.add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');

  for (var page = 0; page < 2; page++) {
    final pageObject = objects.length + 1;
    final contentObject = pageObject + 1;
    kids.add('$pageObject 0 R');
    final content =
        'BT /F1 32 Tf 40 220 Td (Native PDF page ${page + 1}) Tj '
        '0 -46 Td (native_pdf_kit OCR 2026) Tj ET';
    objects.add('');
    objects[pageObject - 1] =
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] '
        '/Resources << /Font << /F1 3 0 R >> >> /Contents $contentObject 0 R >>';
    objects.add('<< /Length ${content.length} >>\nstream\n$content\nendstream');
  }

  objects[1] =
      '<< /Type /Pages /Kids [${kids.join(' ')}] /Count ${kids.length} >>';

  final buffer = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[0];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(buffer.length);
    buffer.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = buffer.length;
  buffer.write('xref\n0 ${objects.length + 1}\n');
  buffer.write('0000000000 65535 f \n');
  for (var i = 1; i <= objects.length; i++) {
    buffer.write('${offsets[i].toString().padLeft(10, '0')} 00000 n \n');
  }
  buffer.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF\n',
  );
  return Uint8List.fromList(ascii.encode(buffer.toString()));
}
