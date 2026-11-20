import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:native_pdf_kit/native_pdf_kit.dart';
import 'package:native_pdf_kit_ocr/native_pdf_kit_ocr.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'native_pdf_kit OCR',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF0B6E4F),
        useMaterial3: true,
      ),
      home: const OcrDemoPage(),
    );
  }
}

class OcrDemoPage extends StatefulWidget {
  const OcrDemoPage({super.key});

  @override
  State<OcrDemoPage> createState() => _OcrDemoPageState();
}

class _OcrDemoPageState extends State<OcrDemoPage> {
  late final File _pdf;
  StreamSubscription<PdfOcrEvent>? _subscription;
  PdfOcrProgress? _progress;
  PdfOcrDocument? _result;
  final List<PdfOcrPage> _pages = [];
  String? _error;
  bool _running = false;
  bool _imageJob = false;
  PdfOcrEngine _engine = PdfOcrEngine.auto;
  PdfOcrMode _mode = PdfOcrMode.auto;
  late final List<String> _languages;

  @override
  void initState() {
    super.initState();
    _pdf = File('${Directory.systemTemp.path}/native_pdf_kit_ocr_demo.pdf')
      ..writeAsBytesSync(_buildPdf());
    _languages = NativePdfOcr.supportedLanguages();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  PdfOcrOptions _options() {
    final liteRt = _engine == PdfOcrEngine.liteRt
        ? PdfLiteRtModels(
            detectorPath:
                '${Directory.systemTemp.path}/ppocr/ppocr_det_fp16.tflite',
            recognizerPath:
                '${Directory.systemTemp.path}/ppocr/ppocr_rec_fp16.tflite',
            dictionaryPath:
                '${Directory.systemTemp.path}/ppocr/ppocrv5_dict.txt',
          )
        : null;
    return PdfOcrOptions(
      engine: _engine,
      mode: _mode,
      languages: _languages.where((code) => code.startsWith('en')).take(1)
          .toList(growable: false),
      renderWidth: 1800,
      progressInterval: const Duration(milliseconds: 60),
      liteRtModels: liteRt,
    );
  }

  Future<void> _runDocument() async {
    await _stop();
    final document = NativePdfDocument.open(_pdf.path);
    final options = _options();
    _begin();
    _subscription = NativePdfOcr.recognizeDocument(
      document,
      options: options,
    ).listen(
      _onEvent,
      onError: _onError,
      onDone: _onDone,
    );
  }

  Future<void> _runImage() async {
    await _stop();
    final document = NativePdfDocument.open(_pdf.path);
    final png = document.renderPage(
      0,
      width: 1400,
      format: NativeImageFormat.png,
    );
    final options = _options().copyWith(mode: PdfOcrMode.ocrOnly);
    _begin(image: true);
    _subscription = NativePdfOcr.recognizeImage(
      png,
      options: options,
    ).listen(
      _onEvent,
      onError: _onError,
      onDone: _onDone,
    );
  }

  void _begin({bool image = false}) {
    setState(() {
      _running = true;
      _imageJob = image;
      _progress = null;
      _result = null;
      _pages.clear();
      _error = null;
    });
  }

  void _onEvent(PdfOcrEvent event) {
    if (!mounted) return;
    setState(() {
      switch (event) {
        case PdfOcrProgress():
          _progress = event;
        case PdfOcrPageEvent():
          _pages
            ..removeWhere((page) => page.index == event.page.index)
            ..add(event.page);
        case PdfOcrDoneEvent():
          _result = event.document;
          _running = false;
      }
    });
  }

  void _onError(Object error, StackTrace stack) {
    if (!mounted) return;
    setState(() {
      _error = '$error';
      _running = false;
    });
  }

  void _onDone() {
    if (!mounted) return;
    setState(() => _running = false);
  }

  Future<void> _stop() async {
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) await subscription.cancel();
    if (mounted && _running) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final engines = <PdfOcrEngine>[
      PdfOcrEngine.auto,
      ...NativePdfOcr.availableEngines,
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('native_pdf_kit OCR'),
        actions: [
          if (_running)
            IconButton(
              tooltip: 'Cancel',
              onPressed: _stop,
              icon: const Icon(Icons.stop_circle_outlined),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'On-device OCR and text extraction',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Apple Vision + PDFKit on iOS/macOS. ML Kit or '
                    'LiteRT/PP-OCRv5 on Android. Progress below is polled '
                    'from the native worker, not a platform channel.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      DropdownButton<PdfOcrEngine>(
                        value: _engine,
                        onChanged: _running
                            ? null
                            : (value) => setState(() => _engine = value!),
                        items: [
                          for (final engine in engines)
                            DropdownMenuItem(
                              value: engine,
                              child: Text(_engineLabel(engine)),
                            ),
                        ],
                      ),
                      DropdownButton<PdfOcrMode>(
                        value: _mode,
                        onChanged: _running
                            ? null
                            : (value) => setState(() => _mode = value!),
                        items: const [
                          DropdownMenuItem(
                            value: PdfOcrMode.auto,
                            child: Text('Auto'),
                          ),
                          DropdownMenuItem(
                            value: PdfOcrMode.ocrOnly,
                            child: Text('OCR only'),
                          ),
                          DropdownMenuItem(
                            value: PdfOcrMode.textLayerOnly,
                            child: Text('Text layer only'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (_engine == PdfOcrEngine.liteRt) ...[
                    const SizedBox(height: 10),
                    Text(
                      'LiteRT needs ppocr_det_fp16.tflite, '
                      'ppocr_rec_fp16.tflite and ppocrv5_dict.txt in '
                      '${Directory.systemTemp.path}/ppocr. Fetch them with '
                      'tool/fetch_litert_ocr_models.sh.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _running ? null : _runDocument,
                        icon: const Icon(Icons.document_scanner_outlined),
                        label: const Text('Extract document'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _running ? null : _runImage,
                        icon: const Icon(Icons.image_outlined),
                        label: const Text('OCR page image'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_running || _progress != null) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _imageJob ? 'Image OCR' : 'Document OCR',
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        Text(_progress == null
                            ? 'starting…'
                            : '${(_progress!.overallProgress * 100).round()}%'),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        minHeight: 8,
                        value: _progress?.overallProgress,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _progress == null
                          ? 'Waiting for the native job'
                          : 'Page ${_progress!.pageIndex + 1} of '
                                '${_progress!.pageCount} · '
                                '${_stageLabel(_progress!.stage)}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SelectableText(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            ),
          ],
          if (_result != null) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Result', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    Text(
                      '${_result!.pages.length} pages · '
                      '${_result!.characterCount} characters · '
                      '${_result!.engines.join(', ')} · '
                      '${_result!.duration.inMilliseconds} ms',
                      style: theme.textTheme.bodySmall,
                    ),
                    if (_result!.errors.isNotEmpty)
                      Text(
                        '${_result!.errors.length} page errors',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          for (final page in _pages) ...[
            const SizedBox(height: 12),
            Card(
              child: ExpansionTile(
                initiallyExpanded: page.index == 0,
                title: Text(
                  'Page ${page.index + 1} · ${page.engine} · '
                  '${page.characterCount} chars',
                ),
                subtitle: Text(
                  page.error ??
                      '${page.source == PdfOcrPageSource.textLayer ? 'text layer' : 'OCR'}'
                          ' · ${page.duration.inMilliseconds} ms',
                ),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(
                      page.text.isEmpty ? '(no text)' : page.text,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  static String _engineLabel(PdfOcrEngine engine) => switch (engine) {
    PdfOcrEngine.auto => 'Auto',
    PdfOcrEngine.appleVision => 'Apple Vision',
    PdfOcrEngine.mlKit => 'ML Kit',
    PdfOcrEngine.liteRt => 'LiteRT PP-OCRv5',
  };

  static String _stageLabel(PdfOcrStage stage) => switch (stage) {
    PdfOcrStage.preparing => 'preparing',
    PdfOcrStage.textLayer => 'reading text layer',
    PdfOcrStage.rendering => 'rendering',
    PdfOcrStage.recognizing => 'recognizing',
    PdfOcrStage.done => 'page done',
  };
}

Uint8List _buildPdf() {
  const pages = <List<String>>[
    [
      'Quarterly report',
      'Revenue increased by 18.4% to 2,315 million.',
      'Contact: finance@example.com',
      'Phone: +1 415 555 0142',
    ],
    [
      'Shipping notice',
      'Order NPK-2026-0042',
      'Carrier: Northwind Freight',
      'Delivered to: 42 Harbour Road',
    ],
    [
      'Scanned page simulation',
      'native_pdf_kit extracts this text with OCR.',
      'The text layer is ignored in OCR-only mode.',
      'Progress is reported while Vision or ML Kit runs.',
    ],
  ];

  final objects = <String>[];
  final kids = <String>[];
  objects.add('<< /Type /Catalog /Pages 2 0 R >>');
  objects.add('');
  objects.add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');

  for (var index = 0; index < pages.length; index++) {
    final pageObject = objects.length + 1;
    final contentObject = pageObject + 1;
    kids.add('$pageObject 0 R');
    final buffer = StringBuffer();
    for (var line = 0; line < pages[index].length; line++) {
      final size = line == 0 ? 28 : 17;
      final escaped = pages[index][line]
          .replaceAll(r'\', r'\\')
          .replaceAll('(', r'\(')
          .replaceAll(')', r'\)');
      buffer.write(
        'BT /F1 $size Tf 48 ${560 - line * 46} Td ($escaped) Tj ET\n',
      );
    }
    final content = buffer.toString();
    objects.add('');
    objects[pageObject - 1] =
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 700] '
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
