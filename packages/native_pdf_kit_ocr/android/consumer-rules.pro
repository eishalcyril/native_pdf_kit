# Reached from Dart through JNI.
-keep class com.eishal.native_pdf_kit_ocr.OcrBridge { *; }

# Instantiated reflectively so the app can opt into LiteRT.
-keep class com.eishal.native_pdf_kit_ocr.LiteRtEngine { *; }

# LiteRT is compileOnly; apps that do not add it must still build.
-dontwarn org.tensorflow.lite.**
-dontwarn com.google.ai.edge.litert.**
