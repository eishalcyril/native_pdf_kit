import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:native_pdf_kit/native_pdf_kit.dart';
import 'package:native_pdf_kit_ocr/native_pdf_kit_ocr.dart';

const _pdfType = XTypeGroup(
  label: 'PDF documents',
  extensions: ['pdf'],
  mimeTypes: ['application/pdf'],
  uniformTypeIdentifiers: ['com.adobe.pdf'],
);

const _imageType = XTypeGroup(
  label: 'Images',
  extensions: ['png', 'jpg', 'jpeg'],
  mimeTypes: ['image/png', 'image/jpeg'],
  uniformTypeIdentifiers: ['public.png', 'public.jpeg'],
);

const _autoRun = bool.fromEnvironment('OCR_DEMO_AUTORUN');

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
  File? _pdf;
  Uint8List? _image;
  String _sourceName = 'Sample PDF';
  int _pageCount = 0;
  int _previewPage = 0;
  Uint8List? _preview;
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
    _languages = NativePdfOcr.supportedLanguages();
    _loadSample(notify: false);
    if (_autoRun) {
      _mode = PdfOcrMode.ocrOnly;
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _loadSample({bool notify = true}) {
    final file = File(
      '${Directory.systemTemp.path}/native_pdf_kit_ocr_demo.pdf',
    )..writeAsBytesSync(_buildPdf());
    _loadPdf(file, name: 'Sample PDF', notify: notify);
  }

  void _loadPdf(File file, {String? name, bool notify = true}) {
    final document = NativePdfDocument.open(file.path);
    final preview = document.renderPage(
      0,
      width: 900,
      format: NativeImageFormat.png,
    );
    void apply() {
      _pdf = file;
      _image = null;
      _sourceName = name ?? file.uri.pathSegments.last;
      _pageCount = document.pageCount;
      _previewPage = 0;
      _preview = preview;
      _clearResults();
    }

    if (notify) {
      setState(apply);
    } else {
      apply();
    }
  }

  Future<void> _pickPdf() async {
    try {
      final selected = await openFile(
        acceptedTypeGroups: const [_pdfType],
      );
      if (selected == null) return;
      final target = File(
        '${Directory.systemTemp.path}/picked_'
        '${DateTime.now().microsecondsSinceEpoch}.pdf',
      );
      await selected.saveTo(target.path);
      _loadPdf(target, name: selected.name);
    } catch (error) {
      _fail('Could not open the PDF: $error');
    }
  }

  Future<void> _pickImage() async {
    try {
      final selected = await openFile(
        acceptedTypeGroups: const [_imageType],
      );
      if (selected == null) return;
      final bytes = await selected.readAsBytes();
      if (bytes.isEmpty) {
        _fail('The selected image is empty.');
        return;
      }
      setState(() {
        _pdf = null;
        _image = bytes;
        _sourceName = selected.name;
        _pageCount = 1;
        _previewPage = 0;
        _preview = bytes;
        _clearResults();
      });
    } catch (error) {
      _fail('Could not open the image: $error');
    }
  }

  void _showPage(int page) {
    final pdf = _pdf;
    if (pdf == null || page < 0 || page >= _pageCount) return;
    try {
      final document = NativePdfDocument.open(pdf.path);
      final preview = document.renderPage(
        page,
        width: 900,
        format: NativeImageFormat.png,
      );
      setState(() {
        _previewPage = page;
        _preview = preview;
      });
    } catch (error) {
      _fail('Could not render page ${page + 1}: $error');
    }
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
      languages: _languages
          .where((code) => code.startsWith('en'))
          .take(1)
          .toList(growable: false),
      renderWidth: 1800,
      progressInterval: const Duration(milliseconds: 60),
      liteRtModels: liteRt,
    );
  }

  Future<void> _run() async {
    final pdf = _pdf;
    final image = _image;
    if (pdf == null && image == null) {
      _fail('Choose a PDF or an image first.');
      return;
    }
    await _stop();
    final options = _options();
    _begin(image: image != null);
    if (image != null) {
      _subscription = NativePdfOcr.recognizeImage(
        image,
        options: options.copyWith(mode: PdfOcrMode.ocrOnly),
      ).listen(_onEvent, onError: _onError, onDone: _onDone);
    } else {
      _subscription = NativePdfOcr.recognizeDocument(
        NativePdfDocument.open(pdf!.path),
        options: options,
      ).listen(_onEvent, onError: _onError, onDone: _onDone);
    }
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

  void _clearResults() {
    _result = null;
    _pages.clear();
    _progress = null;
    _error = null;
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

  void _fail(String message) {
    if (!mounted) return;
    setState(() => _error = message);
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
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'On-device OCR and text extraction',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Pick a real PDF or image from the device, or start from '
                    'the sample. Apple Vision + PDFKit on iOS/macOS; ML Kit '
                    'or LiteRT/PP-OCRv5 on Android.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        key: const Key('pick-pdf'),
                        onPressed: _running ? null : _pickPdf,
                        icon: const Icon(Icons.upload_file_outlined, size: 18),
                        label: const Text('Choose PDF'),
                      ),
                      OutlinedButton.icon(
                        key: const Key('pick-image'),
                        onPressed: _running ? null : _pickImage,
                        icon: const Icon(Icons.image_outlined, size: 18),
                        label: const Text('Choose image'),
                      ),
                      TextButton.icon(
                        key: const Key('use-sample'),
                        onPressed: _running ? null : _loadSample,
                        icon: const Icon(Icons.description_outlined, size: 18),
                        label: const Text('Sample'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      DropdownButton<PdfOcrEngine>(
                        key: const Key('engine-dropdown'),
                        value: _engine,
                        isDense: true,
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
                      const SizedBox(width: 20),
                      DropdownButton<PdfOcrMode>(
                        key: const Key('mode-dropdown'),
                        value: _mode,
                        isDense: true,
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
                            child: Text('Text only'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (_engine == PdfOcrEngine.liteRt) ...[
                    const SizedBox(height: 6),
                    Text(
                      'LiteRT needs the three PP-OCRv5 model files in '
                      '${Directory.systemTemp.path}/ppocr. Fetch them with '
                      'tool/fetch_litert_ocr_models.sh.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      FilledButton.icon(
                        key: const Key('run-ocr'),
                        onPressed: _running ? null : _run,
                        icon: const Icon(Icons.document_scanner_outlined),
                        label: Text(_image == null ? 'Extract document' : 'OCR image'),
                      ),
                      const SizedBox(width: 8),
                      if (_running)
                        TextButton.icon(
                          onPressed: _stop,
                          icon: const Icon(Icons.stop_circle_outlined),
                          label: const Text('Stop'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _sourceCard(theme),
          if (_running || _progress != null) ...[
            const SizedBox(height: 12),
            _progressCard(theme),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: SelectableText(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            ),
          ],
          if (_result != null) ...[
            const SizedBox(height: 12),
            _resultCard(theme),
          ],
          for (final page in _pages) ...[
            const SizedBox(height: 10),
            _pageCard(theme, page),
          ],
        ],
      ),
    );
  }

  Widget _sourceCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _image == null
                      ? Icons.picture_as_pdf_outlined
                      : Icons.image_outlined,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _sourceName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Text(
                  _image == null
                      ? '$_pageCount page${_pageCount == 1 ? '' : 's'}'
                      : 'image',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            if (_preview != null) ...[
              const SizedBox(height: 10),
              Container(
                height: 170,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.memory(
                  _preview!,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
              ),
            ],
            if (_pdf != null && _pageCount > 1) ...[
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Previous page',
                    onPressed: _previewPage == 0
                        ? null
                        : () => _showPage(_previewPage - 1),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text('Page ${_previewPage + 1} / $_pageCount'),
                  IconButton(
                    tooltip: 'Next page',
                    onPressed: _previewPage + 1 >= _pageCount
                        ? null
                        : () => _showPage(_previewPage + 1),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _progressCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
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
                Text(
                  _progress == null
                      ? 'starting…'
                      : '${(_progress!.overallProgress * 100).round()}%',
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                minHeight: 8,
                value: _progress?.overallProgress,
              ),
            ),
            const SizedBox(height: 8),
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
    );
  }

  Widget _resultCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Result', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
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
    );
  }

  Widget _pageCard(ThemeData theme, PdfOcrPage page) {
    return Card(
      child: ExpansionTile(
        key: ValueKey('ocr-page-${page.index}'),
        initiallyExpanded: page.index == 0,
        maintainState: true,
        title: Text(
          'Page ${page.index + 1} · ${page.engine} · '
          '${page.characterCount} chars',
        ),
        subtitle: Text(
          page.error ??
              '${page.source == PdfOcrPageSource.textLayer ? 'text layer' : 'OCR'}'
                  ' · ${page.duration.inMilliseconds} ms',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
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
    );
  }

  static String _engineLabel(PdfOcrEngine engine) => switch (engine) {
    PdfOcrEngine.auto => 'Auto engine',
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
