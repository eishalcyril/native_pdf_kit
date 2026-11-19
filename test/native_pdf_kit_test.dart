import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_pdf_kit/native_pdf_kit.dart';

void main() {
  late File pdf;

  setUpAll(() {
    pdf = File('${Directory.systemTemp.path}/native_pdf_kit_fixture.pdf')
      ..writeAsBytesSync(_buildPdf(pages: 2));
  });

  tearDownAll(() {
    if (pdf.existsSync()) pdf.deleteSync();
  });

  test('reads the page count and media box', () {
    final document = NativePdfDocument.open(pdf.path);

    expect(document.pageCount, 2);
    final size = document.pageSize(0);
    expect(size.width, closeTo(300, 0.01));
    expect(size.height, closeTo(400, 0.01));
    expect(size.aspectRatio, closeTo(0.75, 0.0001));
  });

  test('rejects an out-of-range page', () {
    final document = NativePdfDocument.open(pdf.path);
    expect(() => document.pageSize(5), throwsA(isA<NativePdfException>()));
    expect(() => document.renderPage(5), throwsA(isA<NativePdfException>()));
  });

  test('renders JPEG and PNG pages', () {
    final document = NativePdfDocument.open(pdf.path);

    final jpeg = document.renderPage(0, width: 150);
    expect(jpeg.length, greaterThan(500));
    expect(jpeg[0], 0xFF);
    expect(jpeg[1], 0xD8);

    final png = document.renderPage(
      0,
      width: 150,
      format: NativeImageFormat.png,
    );
    expect(png.length, greaterThan(500));
    expect(png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
  });

  test('compresses an image natively', () {
    final document = NativePdfDocument.open(pdf.path);
    final png = document.renderPage(
      0,
      width: 600,
      format: NativeImageFormat.png,
    );

    final result = NativeImageCompressor.compress(
      png,
      maxDimension: 120,
      quality: 70,
      format: NativeImageFormat.jpeg,
    );

    expect(result.width, lessThanOrEqualTo(120));
    expect(result.height, lessThanOrEqualTo(120));
    expect(result.byteLength, greaterThan(100));
    expect(result.bytes[0], 0xFF);
    expect(result.bytes[1], 0xD8);
  });
}

Uint8List _buildPdf({required int pages}) {
  final objects = <String>[];
  final kids = <String>[];

  // 1: catalog, 2: page tree, 3: Helvetica.
  objects.add('<< /Type /Catalog /Pages 2 0 R >>');
  objects.add('');
  objects.add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');

  for (var i = 0; i < pages; i++) {
    final pageObject = objects.length + 1;
    final contentObject = pageObject + 1;
    kids.add('$pageObject 0 R');

    final content = 'BT /F1 24 Tf 40 200 Td (Native PDF page ${i + 1}) Tj ET';
    objects.add(''); // page, filled below once content number is known
    objects[pageObject - 1] =
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] '
        '/Resources << /Font << /F1 3 0 R >> >> /Contents $contentObject 0 R >>';
    objects.add('<< /Length ${content.length} >>\nstream\n$content\nendstream');
  }

  objects[1] =
      '<< /Type /Pages /Kids [${kids.join(' ')}] '
      '/Count ${kids.length} >>';

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
