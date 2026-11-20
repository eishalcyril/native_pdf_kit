Pod::Spec.new do |s|
  s.name             = 'native_pdf_kit_ocr'
  s.version          = '0.1.0'
  s.summary          = 'On-device OCR and text extraction for native_pdf_kit.'
  s.description      = <<-DESC
Apple Vision OCR and PDFKit text extraction behind a narrow C surface, with
realtime progress and cancellation. No platform channels, no third-party
source, no bundled model.
                       DESC
  s.homepage         = 'https://github.com/eishalcyril/native_pdf_kit'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Eishal Cyril' => 'eishalcyril@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'native_pdf_kit_ocr/Sources/native_pdf_kit_ocr/**/*.{c,h,m}'
  s.public_header_files = 'native_pdf_kit_ocr/Sources/native_pdf_kit_ocr/include/*.h'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'
  s.frameworks = 'CoreGraphics', 'ImageIO', 'CoreFoundation', 'Vision', 'PDFKit'
  s.requires_arc = true
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
