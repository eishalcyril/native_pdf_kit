import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:native_pdf_kit/native_pdf_kit.dart';
import 'package:native_pdf_kit_ocr/native_pdf_kit_ocr.dart';

void main() => runApp(const OcrExampleApp());

class OcrExampleApp extends StatelessWidget {
  const OcrExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'native_pdf_kit OCR example',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF0B6E4F),
        useMaterial3: true,
      ),
      home: const OcrExamplePage(),
    );
  }
}

class OcrExamplePage extends StatefulWidget {
  const OcrExamplePage({super.key});

  @override
  State<OcrExamplePage> createState() => _OcrExamplePageState();
}

class _OcrExamplePageState extends State<OcrExamplePage> {
  double _progress = 0;
  String _text = '';
  String _meta = '';
  String? _error;
  bool _running = false;

  Future<void> _run() async {
    setState(() {
      _running = true;
      _progress = 0;
      _text = '';
      _meta = '';
      _error = null;
    });

    final file = File(
      '${Directory.systemTemp.path}/native_pdf_kit_ocr_example.pdf',
    )..writeAsBytesSync(_buildPdf());

    try {
      final document = NativePdfDocument.open(file.path);
      final stopwatch = Stopwatch()..start();
      await for (final event in NativePdfOcr.recognizeDocument(
        document,
        options: const PdfOcrOptions(
          mode: PdfOcrMode.ocrOnly,
          languages: ['en-US'],
          renderWidth: 1800,
        ),
      )) {
        if (!mounted) return;
        switch (event) {
          case PdfOcrProgress():
            setState(() => _progress = event.overallProgress);
          case PdfOcrPageEvent():
            setState(() => _text = event.page.text);
          case PdfOcrDoneEvent():
            setState(() {
              _progress = 1;
              _text = event.document.text;
              _meta =
                  '${event.document.engines.join(', ')} · '
                  '${event.document.characterCount} chars · '
                  '${stopwatch.elapsedMilliseconds} ms';
            });
        }
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('native_pdf_kit_ocr')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('OCR a generated PDF', style: theme.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            'This example forces OCR-only mode. On Apple it runs Vision; on '
            'Android it runs ML Kit (or LiteRT when configured).',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _running ? null : _run,
            icon: const Icon(Icons.document_scanner_outlined),
            label: const Text('Run OCR'),
          ),
          const SizedBox(height: 16),
          LinearProgressIndicator(
            value: _running ? _progress : (_text.isEmpty ? 0 : 1),
            minHeight: 8,
          ),
          const SizedBox(height: 8),
          Text(
            _running
                ? '${(_progress * 100).round()}%'
                : (_text.isEmpty ? 'Not run yet' : 'Done'),
            style: theme.textTheme.bodySmall,
          ),
          if (_meta.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(_meta, style: theme.textTheme.bodySmall),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          if (_text.isNotEmpty) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: SelectableText(_text),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

Uint8List _buildPdf() {
  const lines = <String>[
    'native_pdf_kit OCR example',
    'This text was recognized on the device.',
    'Progress is reported while Vision or ML Kit runs.',
    'Contact: example@native-pdf-kit.dev',
  ];
  final content = StringBuffer();
  for (var index = 0; index < lines.length; index++) {
    final size = index == 0 ? 26 : 16;
    final escaped = lines[index]
        .replaceAll(r'\', r'\\')
        .replaceAll('(', r'\(')
        .replaceAll(')', r'\)');
    content.write(
      'BT /F1 $size Tf 48 ${560 - index * 44} Td '
      '($escaped) Tj ET\n',
    );
  }

  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 700] '
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
