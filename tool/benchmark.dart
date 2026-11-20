// A small, dependency-free benchmark for the pure-Dart parser, text extractor
// and optimizer. Run with:
//
//   dart run tool/benchmark.dart [pages]
//
// It does not need the native dylib: no images are involved.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:native_pdf_kit/native_pdf_kit.dart';

void main(List<String> args) {
  final pages = args.isEmpty ? 100 : int.parse(args.first);
  final bytes = _buildPdf(pages);
  stdout.writeln(
    'fixture: $pages pages, ${(bytes.length / 1024 / 1024).toStringAsFixed(2)} '
    'MB',
  );

  // Warm up the JIT.
  PdfTextExtractor.extract(bytes);

  final textWatch = Stopwatch()..start();
  final text = PdfTextExtractor.extract(bytes);
  textWatch.stop();
  stdout.writeln(
    'extract all: ${textWatch.elapsedMilliseconds} ms '
    '(${text.length} chars)',
  );

  final pagesWatch = Stopwatch()..start();
  final pageTexts = PdfTextExtractor.extractPages(bytes);
  pagesWatch.stop();
  stdout.writeln(
    'extractPages: ${pagesWatch.elapsedMilliseconds} ms '
    '(${pageTexts.length} pages)',
  );

  final losslessWatch = Stopwatch()..start();
  final lossless = NativePdfOptimizer.optimize(bytes, reduceImages: false);
  losslessWatch.stop();
  stdout.writeln(
    'optimize lossless: ${losslessWatch.elapsedMilliseconds} ms, '
    'changed=${lossless.changed}, '
    '${(lossless.optimizedSize / 1024).toStringAsFixed(1)} KB '
    '(from ${(lossless.originalSize / 1024).toStringAsFixed(1)} KB)',
  );

  final output = File(
    '${Directory.systemTemp.path}/native_pdf_kit_benchmark.pdf',
  )..writeAsBytesSync(lossless.bytes);
  final document = NativePdfDocument.open(output.path);
  stdout.writeln('output page count: ${document.pageCount}');
  if (document.pageCount != pages) {
    stderr.writeln('PAGE COUNT MISMATCH');
    exitCode = 1;
  }
}

Uint8List _buildPdf(int pageCount) {
  final objects = <List<int>>[];
  final kids = <String>[];

  objects.add(latin1.encode('<< /Type /Catalog /Pages 2 0 R >>'));
  objects.add(const []);
  objects.add(
    latin1.encode('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'),
  );

  for (var page = 0; page < pageCount; page++) {
    final pageObject = objects.length + 1;
    final contentObject = pageObject + 1;
    kids.add('$pageObject 0 R');

    final body = List.generate(
      40,
      (line) =>
          'Page ${page + 1} line ${line + 1}: goods received note, '
          'invoice total 12345.67, batch B-${1000 + line}.',
    ).join('\n');
    final escaped = body
        .replaceAll(r'\', r'\\')
        .replaceAll('(', r'\(')
        .replaceAll(')', r'\)');
    final content = latin1.encode(
      'BT /F1 11 Tf 20 760 Td 14 TL\n($escaped) Tj ET',
    );

    objects.add(
      latin1.encode(
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
        '/Resources << /Font << /F1 3 0 R >> >> /Contents $contentObject 0 R >>',
      ),
    );
    objects.add(
      (BytesBuilder()
            ..add(latin1.encode('<< /Length ${content.length} >>\nstream\n'))
            ..add(content)
            ..add(latin1.encode('\nendstream')))
          .takeBytes(),
    );
  }

  objects[1] = latin1.encode(
    '<< /Type /Pages /Kids [${kids.join(' ')}] /Count ${kids.length} >>',
  );

  final out = BytesBuilder();
  out.add(latin1.encode('%PDF-1.4\n'));
  final offsets = <int>[0];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    out.add(latin1.encode('${i + 1} 0 obj\n'));
    out.add(objects[i]);
    out.add(latin1.encode('\nendobj\n'));
  }
  final xref = out.length;
  out.add(latin1.encode('xref\n0 ${objects.length + 1}\n'));
  out.add(latin1.encode('0000000000 65535 f \n'));
  for (var i = 1; i <= objects.length; i++) {
    out.add(
      latin1.encode('${offsets[i].toString().padLeft(10, '0')} 00000 n \n'),
    );
  }
  out.add(
    latin1.encode(
      'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
      'startxref\n$xref\n%%EOF\n',
    ),
  );
  return out.takeBytes();
}
