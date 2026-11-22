Pod::Spec.new do |s|
  s.name             = 'native_pdf_kit'
  s.version          = '0.3.2'
  s.summary          = 'Native PDF rendering and image encoding for Flutter.'
  s.description      = <<-DESC
Direct FFI bindings to CoreGraphics and ImageIO for PDF page rendering and
native image encoding. No platform channels and no third-party source.
                       DESC
  s.homepage         = 'https://github.com/eishalcyril/native_pdf_kit'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Eishal Cyril' => 'eishalcyril@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'native_pdf_kit/Sources/native_pdf_kit/**/*.{c,h}'
  s.public_header_files = 'native_pdf_kit/Sources/native_pdf_kit/include/*.h'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'
  s.frameworks = 'CoreGraphics', 'ImageIO', 'CoreFoundation'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
