import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_pdf_kit/native_pdf_kit.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('native_pdf_opt');
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  File write(String name, Uint8List bytes) =>
      File('${directory.path}/$name')..writeAsBytesSync(bytes);

  test('recompresses a text PDF and keeps its pages', () {
    final input = write('text.pdf', _buildTextPdf(pages: 20));
    final report = NativePdfOptimizer.optimize(
      input.readAsBytesSync(),
      reduceImages: false,
    );

    expect(report.changed, isTrue);
    expect(report.optimizedSize, lessThan(report.originalSize));
    expect(report.pageCount, 20);

    final output = write('text-optimized.pdf', report.bytes);
    final document = NativePdfDocument.open(output.path);
    expect(document.pageCount, 20);
    expect(document.renderPage(0, width: 100).length, greaterThan(100));
  });

  test('downsamples embedded JPEG images', () {
    final source = write('source.pdf', _buildTextPdf(pages: 1));
    final jpeg = NativePdfDocument.open(
      source.path,
    ).renderPage(0, width: 1200, quality: 92);

    final input = write('scan.pdf', _buildImagePdf(jpeg, 1200, 1600));
    final report = NativePdfOptimizer.optimize(
      input.readAsBytesSync(),
      maxImageDimension: 120,
      jpegQuality: 80,
    );

    expect(report.changed, isTrue);
    expect(report.imagesReduced, 1);
    expect(report.optimizedSize, lessThan(report.originalSize));

    final output = write('scan-optimized.pdf', report.bytes);
    final document = NativePdfDocument.open(output.path);
    expect(document.pageCount, 1);
    expect(document.renderPage(0, width: 60).length, greaterThan(100));
  });

  test('extracts text from the text layer', () {
    final input = write('text.pdf', _buildTextPdf(pages: 2));
    final all = PdfTextExtractor.extract(input.readAsBytesSync());
    expect(all, contains('Page 1 line 1'));
    expect(all, contains('Page 2 line 1'));

    final first = PdfTextExtractor.extract(
      input.readAsBytesSync(),
      page: 0,
    );
    expect(first, contains('Page 1'));
    expect(first, isNot(contains('Page 2')));
  });

  test('rotates pages and keeps the document valid', () {
    final input = write('rotate.pdf', _buildTextPdf(pages: 2));
    final result = PdfPageEditor.rotate(
      input.readAsBytesSync(),
      degrees: 90,
      pages: {0},
    );

    expect(result.changed, isTrue);
    expect(result.pageCount, 2);

    final output = write('rotated.pdf', result.bytes);
    final document = NativePdfDocument.open(output.path);
    expect(document.pageCount, 2);
    expect(document.renderPage(0, width: 80).length, greaterThan(100));
    expect(document.renderPage(1, width: 80).length, greaterThan(100));
  });

  test('reorders, removes and extracts pages', () {
    final input = write('pages.pdf', _buildTextPdf(pages: 3));
    final bytes = input.readAsBytesSync();

    final reordered = reorderPdfPages(bytes, [2, 0]);
    expect(reordered.changed, isTrue);
    expect(reordered.pageCount, 2);

    final text = PdfTextExtractor.extract(reordered.bytes);
    expect(text.indexOf('Page 3'), lessThan(text.indexOf('Page 1')));
    expect(text, isNot(contains('Page 2')));

    final single = reorderPdfPages(bytes, [1]);
    expect(single.pageCount, 1);
    final only = PdfTextExtractor.extract(single.bytes);
    expect(only, contains('Page 2'));
    expect(only, isNot(contains('Page 1')));
  });

  test('merges documents and preserves both texts', () {
    final first = write(
      'alpha.pdf',
      _buildTextPdf(pages: 1, prefix: 'Alpha'),
    );
    final second = write(
      'beta.pdf',
      _buildTextPdf(pages: 1, prefix: 'Beta'),
    );

    final result = mergePdfs([
      first.readAsBytesSync(),
      second.readAsBytesSync(),
    ]);
    expect(result.changed, isTrue);
    expect(result.pageCount, 2);

    final output = write('merged.pdf', result.bytes);
    final document = NativePdfDocument.open(output.path);
    expect(document.pageCount, 2);
    expect(document.renderPage(0, width: 80).length, greaterThan(100));
    expect(document.renderPage(1, width: 80).length, greaterThan(100));

    final text = PdfTextExtractor.extract(result.bytes);
    expect(text, contains('Alpha 1'));
    expect(text, contains('Beta 1'));
  });

  test('reads and writes document metadata', () {
    final input = write('meta.pdf', _buildTextPdf(pages: 1));
    final result = PdfMetadataEditor.write(
      input.readAsBytesSync(),
      const PdfMetadata(
        title: 'GRN scan',
        author: 'Eishal Cyril',
        creator: 'native_pdf_kit',
      ),
    );
    expect(result.changed, isTrue);
    expect(result.pageCount, 1);

    final metadata = PdfMetadataEditor.read(result.bytes);
    expect(metadata.title, 'GRN scan');
    expect(metadata.author, 'Eishal Cyril');
    expect(metadata.creator, 'native_pdf_kit');
  });

  test('returns the input unchanged for unsupported data', () {
    final input = Uint8List.fromList(latin1.encode('not a pdf'));
    final report = NativePdfOptimizer.optimize(input);

    expect(report.changed, isFalse);
    expect(report.bytes, same(input));
    expect(report.optimizedSize, input.length);
  });
}

Uint8List _buildTextPdf({required int pages, String prefix = 'Page'}) {
  final objects = <List<int>>[];
  final kids = <String>[];

  objects.add(latin1.encode('<< /Type /Catalog /Pages 2 0 R >>'));
  objects.add(const []);
  objects.add(
    latin1.encode('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'),
  );

  for (var i = 0; i < pages; i++) {
    final pageObject = objects.length + 1;
    final contentObject = pageObject + 1;
    kids.add('$pageObject 0 R');

    final text = List.generate(
      40,
      (line) =>
          '$prefix ${i + 1} line ${line + 1}: goods received note repeated '
          'content for the optimizer regression test.',
    ).join('\n');
    final escaped = text
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
    objects.add(_streamObject(const {}, content));
  }

  objects[1] = latin1.encode(
    '<< /Type /Pages /Kids [${kids.join(' ')}] /Count ${kids.length} >>',
  );
  return _assemble(objects);
}

Uint8List _buildImagePdf(Uint8List jpeg, int width, int height) {
  final content = latin1.encode('q 300 0 0 400 0 0 cm /Im0 Do Q');
  final objects = <List<int>>[
    latin1.encode('<< /Type /Catalog /Pages 2 0 R >>'),
    latin1.encode('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
    latin1.encode(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] '
      '/Resources << /XObject << /Im0 5 0 R >> >> /Contents 4 0 R >>',
    ),
    _streamObject(const {}, content),
    _streamObject(
      {
        'Type': '/XObject',
        'Subtype': '/Image',
        'Width': '$width',
        'Height': '$height',
        'ColorSpace': '/DeviceRGB',
        'BitsPerComponent': '8',
        'Filter': '/DCTDecode',
      },
      jpeg,
      rawDictionary: true,
    ),
  ];
  return _assemble(objects);
}

List<int> _streamObject(
  Map<String, String> entries,
  List<int> data, {
  bool rawDictionary = false,
}) {
  final dictionary = entries.entries
      .map((entry) => '/${entry.key} ${entry.value}')
      .join(' ');
  final bytes = BytesBuilder()
    ..add(latin1.encode('<< $dictionary /Length ${data.length} >>\nstream\n'))
    ..add(data)
    ..add(latin1.encode('\nendstream'));
  return bytes.takeBytes();
}

Uint8List _assemble(List<List<int>> objects) {
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
