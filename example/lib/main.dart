import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:native_pdf_kit/native_pdf_kit.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'native_pdf_kit',
      home: Scaffold(
        appBar: AppBar(title: const Text('native_pdf_kit')),
        body: Center(
          child: FutureBuilder<String>(
            future: _runExample(),
            builder: (context, snapshot) {
              final text = snapshot.hasError
                  ? 'ERROR\n${snapshot.error}'
                  : snapshot.data ?? 'Rendering natively…';
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Text(text, textAlign: TextAlign.center),
              );
            },
          ),
        ),
      ),
    );
  }
}

Future<String> _runExample() async {
  final file = File('${Directory.systemTemp.path}/native_pdf_kit_example.pdf')
    ..writeAsBytesSync(_buildPdf());

  final document = NativePdfDocument.open(file.path);
  final size = document.pageSize(0);
  final jpeg = document.renderPage(0, width: 600);

  final stopwatch = Stopwatch()..start();
  for (var i = 0; i < 10; i++) {
    document.renderPage(0, width: 600);
  }
  stopwatch.stop();
  final average = stopwatch.elapsedMicroseconds / 10 / 1000;
  final png = document.renderPage(0, width: 300, format: NativeImageFormat.png);
  final compressed = NativeImageCompressor.compress(
    png,
    maxDimension: 150,
    quality: 75,
  );

  return 'Native engine OK\n'
      'pages: ${document.pageCount}\n'
      'page: ${size.width.toStringAsFixed(0)} × '
      '${size.height.toStringAsFixed(0)} pt\n'
      'JPEG: ${jpeg.length} bytes  PNG: ${png.length} bytes\n'
      'render 600px: ${average.toStringAsFixed(1)} ms avg\n'
      'native resize: ${compressed.width} × ${compressed.height}, '
      '${compressed.byteLength} bytes';
}

Uint8List _buildPdf() {
  const content = 'BT /F1 28 Tf 40 200 Td (native_pdf_kit on device) Tj ET';
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] '
        '/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
    '<< /Length ${content.length} >>\nstream\n$content\nendstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
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
