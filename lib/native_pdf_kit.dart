/// Fast native PDF rendering and image encoding for Flutter.
///
/// v0.1 supports iOS and macOS. All work happens in the system PDF and image
/// stacks through direct FFI — no platform channels, no bundled third-party
/// engine.
library;

export 'src/bindings.dart' show NativeImageFormat, NativePdfException;
export 'src/document.dart';
export 'src/image.dart';
export 'src/optimizer/pdf_optimizer.dart';
