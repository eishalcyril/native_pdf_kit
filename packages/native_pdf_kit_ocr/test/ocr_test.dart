import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_pdf_kit/native_pdf_kit.dart';
import 'package:native_pdf_kit_ocr/native_pdf_kit_ocr.dart';

void main() {
  late Directory directory;
  late File pdf;

  setUpAll(() {
    directory = Directory.systemTemp.createTempSync('native_pdf_ocr');
    pdf = File('${directory.path}/fixture.pdf')
      ..writeAsBytesSync(_buildPdf(pages: 2));
  });

  tearDownAll(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  test('reports capabilities and languages', () {
    expect(NativePdfOcr.isSupported, isTrue);
    expect(PdfOcrCapabilities.ocr, isTrue);
    expect(NativePdfOcr.availableEngines, contains(PdfOcrEngine.appleVision));
    final languages = NativePdfOcr.supportedLanguages();
    expect(languages, isNotEmpty);
    expect(languages.any((value) => value.startsWith('en')), isTrue);
  });

  test('reads the PDF text layer with PDFKit', () async {
    final document = NativePdfDocument.open(pdf.path);
    final events = <PdfOcrEvent>[];
    await for (final event in NativePdfOcr.recognizeDocument(document)) {
      events.add(event);
    }

    final done = events.whereType<PdfOcrDoneEvent>().single.document;
    expect(done.pages, hasLength(2));
    expect(done.text, contains('Native PDF page 1'));
    expect(done.text, contains('Native PDF page 2'));
    expect(done.pages.first.engine, 'pdfkit');
    expect(done.pages.first.source, PdfOcrPageSource.textLayer);
    expect(done.pages.first.lines, isNotEmpty);
    expect(done.pages.first.lines.first.box, isNotNull);

    final progress = events.whereType<PdfOcrProgress>().toList();
    expect(progress, isNotEmpty);
    expect(progress.last.overallProgress, closeTo(1, 0.0001));
    expect(progress.every((event) => event.overallProgress <= 1.0001), isTrue);
  });

  test('OCRs a rendered page with Vision', () async {
    final document = NativePdfDocument.open(pdf.path);
    final png = document.renderPage(
      0,
      width: 1200,
      format: NativeImageFormat.png,
    );

    final events = <PdfOcrEvent>[];
    await for (final event in NativePdfOcr.recognizeImage(
      png,
      options: const PdfOcrOptions(
        mode: PdfOcrMode.ocrOnly,
        recognitionLevel: PdfOcrRecognitionLevel.accurate,
        languages: ['en-US'],
        renderWidth: 3000,
      ),
    )) {
      events.add(event);
    }

    final done = events.whereType<PdfOcrDoneEvent>().single.document;
    expect(done.pages, hasLength(1));
    expect(done.pages.single.engine, 'apple-vision');
    expect(done.pages.single.source, PdfOcrPageSource.ocr);
    final normalized = done.text.toLowerCase().replaceAll(' ', '');
    expect(normalized, contains('nativepdfpage1'));
    expect(done.pages.single.lines, isNotEmpty);
    expect(done.pages.single.lines.first.confidence, greaterThan(0));
    expect(done.pages.single.width, greaterThan(0));
  });

  test('OCR mode ignores a usable text layer', () async {
    final document = NativePdfDocument.open(pdf.path);
    final result = await NativePdfOcr.extractDocument(
      document,
      options: const PdfOcrOptions(mode: PdfOcrMode.ocrOnly, renderWidth: 1600),
    );

    expect(result.pages, hasLength(2));
    expect(result.pages.first.engine, 'apple-vision');
    expect(result.text.toLowerCase(), contains('native'));
  });

  test('text-layer-only mode never rasterizes', () async {
    final document = NativePdfDocument.open(pdf.path);
    final result = await NativePdfOcr.extractDocument(
      document,
      options: const PdfOcrOptions(mode: PdfOcrMode.textLayerOnly),
    );

    expect(result.pages, hasLength(2));
    expect(result.text, contains('Native PDF page 2'));
    expect(result.engines, everyElement('pdfkit'));
  });

  test('blank pages are empty pages, not errors', () async {
    final blank = File('${directory.path}/blank.pdf')
      ..writeAsBytesSync(_buildBlankPdf());
    final result = await NativePdfOcr.extractDocument(
      NativePdfDocument.open(blank.path),
      options: const PdfOcrOptions(mode: PdfOcrMode.textLayerOnly),
    );

    expect(result.pages, hasLength(1));
    expect(result.pages.single.text, isEmpty);
    expect(result.errors, isEmpty);
  });

  test('cancelling the subscription stops the job', () async {
    final source = File('${directory.path}/many.pdf')
      ..writeAsBytesSync(_buildPdf(pages: 12));
    final document = NativePdfDocument.open(source.path);
    final completer = Completer<void>();
    var pages = 0;
    late StreamSubscription<PdfOcrEvent> subscription;

    subscription =
        NativePdfOcr.recognizeDocument(
          document,
          options: const PdfOcrOptions(
            mode: PdfOcrMode.ocrOnly,
            renderWidth: 1600,
          ),
        ).listen(
          (event) {
            if (event is PdfOcrPageEvent) {
              pages++;
              if (pages == 1) {
                subscription.cancel().whenComplete(completer.complete);
              }
            }
          },
          onError: completer.completeError,
          onDone: () {
            if (!completer.isCompleted) completer.complete();
          },
        );

    await completer.future.timeout(const Duration(seconds: 20));
    expect(pages, 1);
  });
}

Uint8List _buildBlankPdf() {
  const content = 'q Q';
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] '
        '/Contents 4 0 R >>',
    '<< /Length ${content.length} >>\nstream\n$content\nendstream',
  ];

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

Uint8List _buildPdf({required int pages}) {
  final objects = <String>[];
  final kids = <String>[];

  objects.add('<< /Type /Catalog /Pages 2 0 R >>');
  objects.add('');
  objects.add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');

  for (var i = 0; i < pages; i++) {
    final pageObject = objects.length + 1;
    final contentObject = pageObject + 1;
    kids.add('$pageObject 0 R');

    final content =
        'BT /F1 32 Tf 40 220 Td (Native PDF page ${i + 1}) Tj '
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

  final xrefOffset = buffer.length;
  buffer.write('xref\n0 ${objects.length + 1}\n');
  buffer.write('0000000000 65535 f \n');
  for (var i = 1; i <= objects.length; i++) {
    buffer.write('${offsets[i].toString().padLeft(10, '0')} 00000 n \n');
  }
  buffer.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
    'startxref\n$xrefOffset\n%%EOF\n',
  );

  return Uint8List.fromList(ascii.encode(buffer.toString()));
}
