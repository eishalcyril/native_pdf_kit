import 'dart:io';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:native_pdf_kit_example/main.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('capture the OCR demo', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    await tester.pumpAndSettle();

    // OCR-only makes the screenshot show the engine rather than the PDF text
    // layer fast path.
    await tester.tap(find.byKey(const Key('mode-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OCR only').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('run-ocr')));
    await tester.pump();

    for (var attempt = 0; attempt < 240; attempt++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (find.text('Result').evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle();

    if (Platform.isAndroid) {
      await binding.convertFlutterSurfaceToImage();
      await tester.pumpAndSettle();
    }

    final platform = Platform.operatingSystem;
    await binding.takeScreenshot('$platform-top');

    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    await binding.takeScreenshot('$platform-pages');
  });
}
