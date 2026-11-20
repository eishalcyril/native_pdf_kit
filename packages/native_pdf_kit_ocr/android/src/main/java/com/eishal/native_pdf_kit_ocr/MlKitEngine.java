package com.eishal.native_pdf_kit_ocr;

import android.graphics.Bitmap;
import android.graphics.Rect;

import com.google.android.gms.tasks.Task;
import com.google.mlkit.vision.common.InputImage;
import com.google.mlkit.vision.text.Text;
import com.google.mlkit.vision.text.TextRecognition;
import com.google.mlkit.vision.text.TextRecognizer;
import com.google.mlkit.vision.text.latin.TextRecognizerOptions;

import org.json.JSONArray;
import org.json.JSONObject;

import java.lang.reflect.Method;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

/** ML Kit Text Recognition v2, Latin by default with optional script models. */
final class MlKitEngine {
    private static final ExecutorService CALLBACKS = Executors.newCachedThreadPool();

    private MlKitEngine() {}

    static String recognize(Bitmap bitmap, JSONObject options,
                            AtomicBoolean cancelled,
                            OcrBridge.ProgressSink progress) throws Exception {
        String script = options.optString("script", "latin");
        TextRecognizer recognizer = create(script);
        try {
            InputImage image = InputImage.fromBitmap(bitmap, 0);
            progress.update(0.2);
            Text text = process(recognizer, image, cancelled);
            progress.update(0.9);
            if (text == null) {
                throw new IllegalStateException("ML Kit returned no text");
            }
            return toJson(text, bitmap.getWidth(), bitmap.getHeight());
        } finally {
            try {
                recognizer.close();
            } catch (Throwable ignored) {
                // Already closed.
            }
        }
    }

    private static TextRecognizer create(String script) {
        if (script == null || script.isEmpty() || "latin".equals(script)) {
            return TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS);
        }
        final String optionsClass;
        switch (script) {
            case "chinese":
                optionsClass =
                        "com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions";
                break;
            case "devanagari":
                optionsClass =
                        "com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions";
                break;
            case "japanese":
                optionsClass =
                        "com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions";
                break;
            case "korean":
                optionsClass =
                        "com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions";
                break;
            default:
                optionsClass = null;
                break;
        }
        if (optionsClass != null) {
            try {
                Class<?> builderClass = Class.forName(optionsClass + "$Builder");
                Object builder = builderClass.getDeclaredConstructor().newInstance();
                Object scriptOptions = builderClass.getMethod("build").invoke(builder);
                for (Method method : TextRecognition.class.getMethods()) {
                    if (!"getClient".equals(method.getName())
                            || method.getParameterCount() != 1) {
                        continue;
                    }
                    if (method.getParameterTypes()[0].isInstance(scriptOptions)) {
                        return (TextRecognizer) method.invoke(null, scriptOptions);
                    }
                }
            } catch (Throwable ignored) {
                // The script artifact is not installed; use Latin.
            }
        }
        return TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS);
    }

    private static Text process(TextRecognizer recognizer, InputImage image,
                                AtomicBoolean cancelled) throws Exception {
        final CountDownLatch latch = new CountDownLatch(1);
        final AtomicReference<Text> result = new AtomicReference<>();
        final AtomicReference<Throwable> failure = new AtomicReference<>();

        Task<Text> task = recognizer.process(image);
        task.addOnCompleteListener(CALLBACKS, completed -> {
            if (completed.isSuccessful()) {
                result.set(completed.getResult());
            } else {
                failure.set(completed.getException());
            }
            latch.countDown();
        });

        while (!latch.await(50, TimeUnit.MILLISECONDS)) {
            if (cancelled.get()) {
                // ML Kit cannot abort an in-flight request; wait briefly for it
                // to settle and then let the caller settle the session.
                latch.await(2, TimeUnit.SECONDS);
                break;
            }
        }
        Throwable error = failure.get();
        if (error != null) {
            throw new IllegalStateException(
                    error.getMessage() == null ? error.toString() : error.getMessage(),
                    error);
        }
        return result.get();
    }

    private static String toJson(Text text, int width, int height) throws Exception {
        double safeWidth = Math.max(1, width);
        double safeHeight = Math.max(1, height);
        JSONArray lines = new JSONArray();
        StringBuilder all = new StringBuilder();

        for (Text.TextBlock block : text.getTextBlocks()) {
            for (Text.Line line : block.getLines()) {
                String value = line.getText();
                if (value == null || value.trim().isEmpty()) {
                    continue;
                }
                if (all.length() > 0) {
                    all.append('\n');
                }
                all.append(value);

                JSONObject item = new JSONObject();
                item.put("text", value);
                float confidence = line.getConfidence();
                item.put("confidence", confidence > 0 ? (double) confidence : 0.0);
                Rect box = line.getBoundingBox();
                if (box != null) {
                    item.put("box", boxArray(box.left / safeWidth,
                            box.top / safeHeight,
                            box.width() / safeWidth,
                            box.height() / safeHeight));
                }
                lines.put(item);
            }
        }

        JSONObject root = new JSONObject();
        root.put("source", "ocr");
        root.put("engine", "mlkit");
        root.put("width", safeWidth);
        root.put("height", safeHeight);
        root.put("text", all.toString());
        root.put("lines", lines);
        return root.toString();
    }

    private static JSONArray boxArray(double left, double top, double width,
                                      double height) {
        JSONArray array = new JSONArray();
        try {
            array.put(clamp01(left));
            array.put(clamp01(top));
            array.put(clamp01(width));
            array.put(clamp01(height));
        } catch (Exception ignored) {
            // Doubles are always valid JSON values.
        }
        return array;
    }

    private static double clamp01(double value) {
        if (value < 0) return 0;
        if (value > 1) return 1;
        return value;
    }
}
