import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_pdf_kit/native_pdf_kit.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('native_pdf_15');
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  File write(String name, Uint8List bytes) =>
      File('${directory.path}/$name')..writeAsBytesSync(bytes);

  test('reads and rewrites xref streams, object streams and predictors', () {
    for (final hybrid in [false, true]) {
      for (final predictor in [false, true]) {
        final label = '${hybrid ? 'hybrid' : 'stream'}-'
            '${predictor ? 'png' : 'plain'}';
        final input = write('$label.pdf', _buildXrefStreamPdf(
          hybrid: hybrid,
          predictor: predictor,
        ));

        expect(
          PdfTextExtractor.extract(input.readAsBytesSync()),
          contains('XRef stream page'),
          reason: label,
        );

        final document = NativePdfDocument.open(input.path);
        expect(document.pageCount, 1, reason: label);

        final report = NativePdfOptimizer.optimize(
          input.readAsBytesSync(),
          reduceImages: false,
        );
        expect(report.changed, isTrue, reason: label);
        expect(report.pageCount, 1, reason: label);

        final output = write('$label-out.pdf', report.bytes);
        final optimized = NativePdfDocument.open(output.path);
        expect(optimized.pageCount, 1, reason: label);
        expect(
          PdfTextExtractor.extract(report.bytes),
          contains('XRef stream page'),
          reason: label,
        );
        expect(
          PdfTextExtractor.extractPages(report.bytes).single.hasText,
          isTrue,
          reason: label,
        );
      }
    }
  });

  test('applies an incremental update from the newest xref section', () {
    final original = _buildTextPdf('Original text');
    final originalStartXref = _startXref(original);
    final updated = _appendUpdate(
      original,
      objectNumber: 5,
      generation: 0,
      objectBody: _streamObject(
        const {},
        latin1.encode('BT /F1 24 Tf 40 200 Td (Updated text) Tj ET'),
      ),
      size: 6,
      previousXref: originalStartXref,
    );

    final input = write('incremental.pdf', updated);
    expect(
      PdfTextExtractor.extract(input.readAsBytesSync()),
      contains('Updated text'),
    );
    expect(
      PdfTextExtractor.extract(input.readAsBytesSync()),
      isNot(contains('Original text')),
    );

    final report = NativePdfOptimizer.optimize(
      input.readAsBytesSync(),
      reduceImages: false,
    );
    expect(report.changed, isTrue);
    expect(PdfTextExtractor.extract(report.bytes), contains('Updated text'));
    final output = write('incremental-out.pdf', report.bytes);
    expect(NativePdfDocument.open(output.path).pageCount, 1);
  });

  test('turns a Flate RGB scan into a smaller JPEG', () {
    final input = write('flate-scan.pdf', _buildFlateImagePdf());
    final document = NativePdfDocument.open(input.path);
    expect(document.pageCount, 1);

    final report = NativePdfOptimizer.optimize(
      input.readAsBytesSync(),
      maxImageDimension: 200,
      jpegQuality: 80,
    );

    expect(report.changed, isTrue);
    expect(report.imagesReduced, 1);
    expect(report.optimizedSize, lessThan(report.originalSize));
    expect(latin1.decode(report.bytes), contains('/DCTDecode'));

    final output = write('flate-scan-out.pdf', report.bytes);
    final optimized = NativePdfDocument.open(output.path);
    expect(optimized.pageCount, 1);
    expect(optimized.renderPage(0, width: 120).length, greaterThan(200));
  });

  test('survives random corruption without throwing', () {
    final source = _buildTextPdf('Fuzz baseline');
    final random = Random(20261120);

    for (var iteration = 0; iteration < 60; iteration++) {
      final input = Uint8List.fromList(source);
      final flips = 1 + random.nextInt(12);
      for (var flip = 0; flip < flips; flip++) {
        final position = random.nextInt(input.length);
        input[position] ^= 1 << random.nextInt(8);
      }

      final report = NativePdfOptimizer.optimize(input);
      expect(report.bytes, isNotEmpty);
      expect(() => PdfTextExtractor.extract(input), returnsNormally);

      if (report.changed) {
        final output = write('fuzz-$iteration.pdf', report.bytes);
        final document = NativePdfDocument.open(output.path);
        expect(document.pageCount, greaterThan(0));
      }
    }
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// PDF 1.5 builder (xref stream + object stream, optional hybrid/predictor)
// ─────────────────────────────────────────────────────────────────────────────

Uint8List _buildXrefStreamPdf({
  required bool hybrid,
  required bool predictor,
}) {
  const content =
      'BT /F1 24 Tf 40 200 Td (XRef stream page) Tj ET';
  final contentObject = _streamObject(const {}, latin1.encode(content));

  final catalog = latin1.encode(
    '<< /Type /Catalog /Pages 2 0 R >>',
  );
  final pages = latin1.encode(
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
  );
  final page = latin1.encode(
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] '
    '/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
  );
  final font = latin1.encode(
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  );

  final buffer = BytesBuilder(copy: false);
  buffer.add(latin1.encode('%PDF-1.5\n'));

  final offset4 = buffer.length;
  buffer.add(latin1.encode('4 0 obj\n'));
  buffer.add(contentObject);
  buffer.add(latin1.encode('\nendobj\n'));

  // An unreachable stream: the optimizer must drop it, which also gives the
  // rewrite a real size win on an otherwise already-compact file.
  final offset8 = buffer.length;
  final padding = Uint8List.fromList(
    List<int>.generate(20000, (index) => 0x41 + index % 23),
  );
  buffer.add(latin1.encode('8 0 obj\n<< /Length ${padding.length} >>\n'
      'stream\n'));
  buffer.add(padding);
  buffer.add(latin1.encode('\nendstream\nendobj\n'));

  final bodies = [catalog, pages, page, font];
  final bodyOffsets = <int>[];
  final bodyData = BytesBuilder(copy: false);
  for (final body in bodies) {
    bodyOffsets.add(bodyData.length);
    bodyData.add(body);
    bodyData.addByte(0x0A);
  }
  final objectData = bodyData.takeBytes();
  final header = latin1.encode(
    '1 0 2 ${bodyOffsets[1]} 3 ${bodyOffsets[2]} 5 ${bodyOffsets[3]} ',
  );
  final first = header.length;
  final objectStreamPayload = Uint8List.fromList(
    ZLibEncoder(level: 9).convert(
      Uint8List.fromList([...header, ...objectData]),
    ),
  );

  final offset6 = buffer.length;
  buffer.add(
    latin1.encode(
      '6 0 obj\n<< /Type /ObjStm /N 4 /First $first '
      '/Filter /FlateDecode /Length ${objectStreamPayload.length} >>\n'
      'stream\n',
    ),
  );
  buffer.add(objectStreamPayload);
  buffer.add(latin1.encode('\nendstream\nendobj\n'));

  final offset7 = buffer.length;
  final rows = <Uint8List>[
    _xrefRow(0, 0, 65535),
    _xrefRow(2, 6, 0),
    _xrefRow(2, 6, 1),
    _xrefRow(2, 6, 2),
    _xrefRow(1, offset4, 0),
    _xrefRow(2, 6, 3),
    _xrefRow(1, offset6, 0),
    _xrefRow(1, offset7, 0),
    _xrefRow(1, offset8, 0),
  ];
  final xrefData = predictor
      ? _pngPredictor(rows, columns: 7, bytesPerPixel: 1)
      : _concat(rows);
  final compressedXref = Uint8List.fromList(
    ZLibEncoder(level: 9).convert(xrefData),
  );

  final decodeParms = predictor
      ? ' /DecodeParms << /Predictor 12 /Columns 7 >>'
      : '';
  buffer.add(latin1.encode('7 0 obj\n<< /Type /XRef /Size 9 /W [1 4 2] '
      '/Index [0 9] /Root 1 0 R /Filter /FlateDecode$decodeParms '
      '/Length ${compressedXref.length} >>\nstream\n'));
  buffer.add(compressedXref);
  buffer.add(latin1.encode('\nendstream\nendobj\n'));

  if (!hybrid) {
    buffer.add(
      latin1.encode(
        'startxref\n$offset7\n%%EOF\n',
      ),
    );
    return buffer.takeBytes();
  }

  final classicXref = buffer.length;
  buffer.add(latin1.encode('xref\n0 9\n'));
  buffer.add(latin1.encode('0000000000 65535 f \n'));
  for (var number = 1; number <= 8; number++) {
    final offset = switch (number) {
      4 => offset4,
      6 => offset6,
      7 => offset7,
      8 => offset8,
      _ => -1,
    };
    if (offset < 0) {
      buffer.add(latin1.encode('0000000000 00000 f \n'));
    } else {
      buffer.add(
        latin1.encode('${offset.toString().padLeft(10, '0')} 00000 n \n'),
      );
    }
  }
  buffer.add(
    latin1.encode(
      'trailer\n<< /Size 9 /Root 1 0 R /XRefStm $offset7 >>\n'
      'startxref\n$classicXref\n%%EOF\n',
    ),
  );
  return buffer.takeBytes();
}

Uint8List _xrefRow(int type, int field2, int field3) {
  return Uint8List.fromList([
    type,
    (field2 >> 24) & 0xFF,
    (field2 >> 16) & 0xFF,
    (field2 >> 8) & 0xFF,
    field2 & 0xFF,
    (field3 >> 8) & 0xFF,
    field3 & 0xFF,
  ]);
}

Uint8List _pngPredictor(
  List<Uint8List> rows, {
  required int columns,
  required int bytesPerPixel,
}) {
  final out = BytesBuilder(copy: false);
  var previous = Uint8List(columns);
  for (var index = 0; index < rows.length; index++) {
    final row = rows[index];
    if (index == 0) {
      out.addByte(0);
      out.add(row);
    } else {
      out.addByte(2); // Up
      final encoded = Uint8List(row.length);
      for (var i = 0; i < row.length; i++) {
        encoded[i] = (row[i] - previous[i]) & 0xFF;
      }
      out.add(encoded);
    }
    previous = row;
  }
  return out.takeBytes();
}

Uint8List _concat(List<Uint8List> parts) {
  final out = BytesBuilder(copy: false);
  for (final part in parts) {
    out.add(part);
  }
  return out.takeBytes();
}

// ─────────────────────────────────────────────────────────────────────────────
// Flate image builder
// ─────────────────────────────────────────────────────────────────────────────

Uint8List _buildFlateImagePdf() {
  const width = 1200;
  const height = 1600;
  final pixels = Uint8List(width * height * 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final index = (y * width + x) * 3;
      final value = (x * 7 + y * 13 + (x * y) % 251) % 256;
      pixels[index] = value;
      pixels[index + 1] = (value * 3) % 256;
      pixels[index + 2] = 255 - value;
    }
  }

  final rows = <Uint8List>[];
  for (var y = 0; y < height; y++) {
    rows.add(
      Uint8List.sublistView(pixels, y * width * 3, (y + 1) * width * 3),
    );
  }
  final predicted = _pngPredictor(
    rows,
    columns: width * 3,
    bytesPerPixel: 3,
  );
  final compressed = Uint8List.fromList(
    ZLibEncoder(level: 6).convert(predicted),
  );

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
        'Filter': '/FlateDecode',
        'DecodeParms': '<< /Predictor 12 /Columns ${width * 3} >>',
      },
      compressed,
      rawDictionary: true,
    ),
  ];
  return _assemble(objects);
}

// ─────────────────────────────────────────────────────────────────────────────
// Classic PDF helpers
// ─────────────────────────────────────────────────────────────────────────────

Uint8List _buildTextPdf(String text) {
  final content = latin1.encode('BT /F1 24 Tf 40 200 Td ($text) Tj ET');
  final objects = <List<int>>[
    latin1.encode('<< /Type /Catalog /Pages 2 0 R >>'),
    latin1.encode('<< /Type /Pages /Kids [4 0 R] /Count 1 >>'),
    latin1.encode(
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    ),
    latin1.encode(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] '
      '/Resources << /Font << /F1 3 0 R >> >> /Contents 5 0 R >>',
    ),
    _streamObject(const {}, content),
  ];
  return _assemble(objects);
}

int _startXref(Uint8List bytes) {
  final text = latin1.decode(bytes);
  final marker = text.lastIndexOf('startxref');
  final rest = text.substring(marker + 'startxref'.length).trim();
  return int.parse(rest.split(RegExp(r'\s+')).first);
}

Uint8List _appendUpdate(
  Uint8List original, {
  required int objectNumber,
  required int generation,
  required List<int> objectBody,
  required int size,
  required int previousXref,
}) {
  final out = BytesBuilder(copy: false)..add(original);
  final offset = out.length;
  out.add(latin1.encode('$objectNumber $generation obj\n'));
  out.add(objectBody);
  out.add(latin1.encode('\nendobj\n'));

  final xref = out.length;
  out.add(
    latin1.encode('xref\n$objectNumber 1\n'
        '${offset.toString().padLeft(10, '0')} '
        '${generation.toString().padLeft(5, '0')} n \n'),
  );
  out.add(
    latin1.encode(
      'trailer\n<< /Size $size /Root 1 0 R /Prev $previousXref >>\n'
      'startxref\n$xref\n%%EOF\n',
    ),
  );
  return out.takeBytes();
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
