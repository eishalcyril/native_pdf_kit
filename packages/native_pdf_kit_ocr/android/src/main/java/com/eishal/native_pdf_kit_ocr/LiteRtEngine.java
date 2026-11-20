package com.eishal.native_pdf_kit_ocr;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Rect;
import android.graphics.RectF;

import org.json.JSONArray;
import org.json.JSONObject;
import org.tensorflow.lite.Interpreter;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStreamReader;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.MappedByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import java.util.concurrent.CancellationException;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * LiteRT + PP-OCRv5 (Apache-2.0) on-device OCR.
 *
 * <p>App opt-in: add {@code com.google.ai.edge.litert:litert:2.2.0} and raise
 * minSdk to 24. The detector and recognizer models plus the CTC dictionary are
 * read from the paths in the {@code liteRt} options object; they are not
 * bundled with the package.
 *
 * <p>Pipeline: letterboxed DB detector, connected components + bbox unclip,
 * per-line crop, CTC recognizer, greedy decode.
 */
public final class LiteRtEngine {
    private static final float DET_THRESHOLD = 0.3f;
    private static final float UNCLIP_RATIO = 1.5f;
    private static final int MAX_LINES = 200;

    private LiteRtEngine() {}

    public static String recognize(Bitmap bitmap, JSONObject options,
                                   AtomicBoolean cancelled,
                                   OcrBridge.ProgressSink progress) throws Exception {
        JSONObject lite = options.optJSONObject("liteRt");
        if (lite == null) {
            throw new IllegalStateException(
                    "LiteRT needs liteRt.detModel, liteRt.recModel and "
                            + "liteRt.dictionary");
        }
        File detectorFile = new File(lite.getString("detModel"));
        File recognizerFile = new File(lite.getString("recModel"));
        File dictionaryFile = new File(lite.getString("dictionary"));
        if (!detectorFile.isFile() || !recognizerFile.isFile()
                || !dictionaryFile.isFile()) {
            throw new IllegalStateException(
                    "LiteRT model files are missing; see "
                            + "tool/fetch_litert_ocr_models.sh");
        }
        int threads = Math.max(1, Math.min(8, lite.optInt("threads", 4)));
        List<String> dictionary = loadDictionary(dictionaryFile);

        Interpreter.Options interpreterOptions =
                new Interpreter.Options().setNumThreads(threads);
        Interpreter detector = new Interpreter(
                mapModel(detectorFile), interpreterOptions);
        Interpreter recognizer = new Interpreter(
                mapModel(recognizerFile), interpreterOptions);
        try {
            int[] detShape = detector.getInputTensor(0).shape();
            if (detShape.length != 4 || detShape[1] != 3) {
                throw new IllegalStateException(
                        "unsupported detector input shape");
            }
            int detHeight = detShape[2];
            int detWidth = detShape[3];

            int[] recShape = recognizer.getInputTensor(0).shape();
            if (recShape.length != 4 || recShape[1] != 3) {
                throw new IllegalStateException(
                        "unsupported recognizer input shape");
            }
            int recHeight = recShape[2];
            int recWidth = recShape[3];
            int[] outShape = recognizer.getOutputTensor(0).shape();
            if (outShape.length != 3) {
                throw new IllegalStateException(
                        "unsupported recognizer output shape");
            }
            int timesteps = outShape[1];
            int vocabulary = outShape[2];

            float[][][][] detInput = new float[1][3][detHeight][detWidth];
            float[][][][] detOutput = new float[1][1][detHeight][detWidth];

            Letterbox letterbox = fillDetectorInput(
                    bitmap, detInput, detWidth, detHeight);
            if (cancelled.get()) throw new CancellationException();
            detector.run(detInput, detOutput);
            progress.update(0.35);
            if (cancelled.get()) throw new CancellationException();

            List<RectF> boxes = detectBoxes(
                    detOutput[0][0], detWidth, detHeight,
                    letterbox.scale, bitmap.getWidth(), bitmap.getHeight());
            if (boxes.isEmpty()) {
                return emptyResult(bitmap);
            }
            if (boxes.size() > MAX_LINES) {
                boxes = boxes.subList(0, MAX_LINES);
            }

            float[][][][] recInput = new float[1][3][recHeight][recWidth];
            float[][][] recOutput = new float[1][timesteps][vocabulary];

            JSONArray lines = new JSONArray();
            StringBuilder all = new StringBuilder();
            for (int i = 0; i < boxes.size(); i++) {
                if (cancelled.get()) throw new CancellationException();
                RectF box = boxes.get(i);
                String line = recognizeLine(bitmap, box, recognizer,
                        recInput, recOutput, dictionary, recWidth, recHeight,
                        timesteps, vocabulary);
                if (line != null && !line.isEmpty()) {
                    if (all.length() > 0) all.append('\n');
                    all.append(line);

                    JSONObject item = new JSONObject();
                    item.put("text", line);
                    item.put("confidence", 0.0);
                    item.put("box", boxArray(box.left / bitmap.getWidth(),
                            box.top / bitmap.getHeight(),
                            box.width() / bitmap.getWidth(),
                            box.height() / bitmap.getHeight()));
                    lines.put(item);
                }
                progress.update(0.35 + 0.6 * ((i + 1) / (double) boxes.size()));
            }

            JSONObject root = new JSONObject();
            root.put("source", "ocr");
            root.put("engine", "litert");
            root.put("width", bitmap.getWidth());
            root.put("height", bitmap.getHeight());
            root.put("text", all.toString());
            root.put("lines", lines);
            return root.toString();
        } finally {
            close(detector);
            close(recognizer);
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Detection
    // ─────────────────────────────────────────────────────────────────────

    private static final class Letterbox {
        final float scale;
        final int width;
        final int height;

        Letterbox(float scale, int width, int height) {
            this.scale = scale;
            this.width = width;
            this.height = height;
        }
    }

    private static Letterbox fillDetectorInput(Bitmap bitmap,
                                               float[][][][] input,
                                               int targetWidth,
                                               int targetHeight) {
        float scale = Math.min((float) targetWidth / bitmap.getWidth(),
                (float) targetHeight / bitmap.getHeight());
        int scaledWidth = Math.max(1, Math.round(bitmap.getWidth() * scale));
        int scaledHeight = Math.max(1, Math.round(bitmap.getHeight() * scale));

        Bitmap canvas = Bitmap.createBitmap(targetWidth, targetHeight,
                Bitmap.Config.ARGB_8888);
        Canvas drawing = new Canvas(canvas);
        drawing.drawColor(Color.WHITE);
        Paint paint = new Paint(Paint.FILTER_BITMAP_FLAG);
        Bitmap scaled = Bitmap.createScaledBitmap(bitmap, scaledWidth,
                scaledHeight, true);
        drawing.drawBitmap(scaled, 0, 0, paint);
        scaled.recycle();

        int[] pixels = new int[targetWidth * targetHeight];
        canvas.getPixels(pixels, 0, targetWidth, 0, 0, targetWidth, targetHeight);
        canvas.recycle();

        final float[] mean = {0.485f, 0.456f, 0.406f};
        final float[] std = {0.229f, 0.224f, 0.225f};
        for (int y = 0; y < targetHeight; y++) {
            int row = y * targetWidth;
            for (int x = 0; x < targetWidth; x++) {
                int pixel = pixels[row + x];
                input[0][0][y][x] =
                        (((pixel >> 16) & 0xFF) / 255.0f - mean[0]) / std[0];
                input[0][1][y][x] =
                        (((pixel >> 8) & 0xFF) / 255.0f - mean[1]) / std[1];
                input[0][2][y][x] =
                        ((pixel & 0xFF) / 255.0f - mean[2]) / std[2];
            }
        }
        return new Letterbox(scale, scaledWidth, scaledHeight);
    }

    private static List<RectF> detectBoxes(float[][] probability, int width,
                                           int height, float scale,
                                           int imageWidth, int imageHeight) {
        boolean[] visited = new boolean[width * height];
        int[] stack = new int[width * height];
        List<RectF> boxes = new ArrayList<>();

        for (int y = 0; y < height; y++) {
            for (int x = 0; x < width; x++) {
                int start = y * width + x;
                if (visited[start] || probability[y][x] <= DET_THRESHOLD) {
                    continue;
                }
                int top = 0;
                stack[top++] = start;
                visited[start] = true;
                int minX = x;
                int maxX = x;
                int minY = y;
                int maxY = y;
                int count = 0;
                double sum = 0;

                while (top > 0) {
                    int index = stack[--top];
                    int px = index % width;
                    int py = index / width;
                    count++;
                    sum += probability[py][px];
                    if (px < minX) minX = px;
                    if (px > maxX) maxX = px;
                    if (py < minY) minY = py;
                    if (py > maxY) maxY = py;

                    if (px > 0) {
                        int next = index - 1;
                        if (!visited[next]
                                && probability[py][px - 1] > DET_THRESHOLD) {
                            visited[next] = true;
                            stack[top++] = next;
                        }
                    }
                    if (px + 1 < width) {
                        int next = index + 1;
                        if (!visited[next]
                                && probability[py][px + 1] > DET_THRESHOLD) {
                            visited[next] = true;
                            stack[top++] = next;
                        }
                    }
                    if (py > 0) {
                        int next = index - width;
                        if (!visited[next]
                                && probability[py - 1][px] > DET_THRESHOLD) {
                            visited[next] = true;
                            stack[top++] = next;
                        }
                    }
                    if (py + 1 < height) {
                        int next = index + width;
                        if (!visited[next]
                                && probability[py + 1][px] > DET_THRESHOLD) {
                            visited[next] = true;
                            stack[top++] = next;
                        }
                    }
                }

                if (count < 8) continue;
                double score = sum / count;
                if (score < DET_THRESHOLD) continue;

                double boxWidth = maxX - minX + 1;
                double boxHeight = maxY - minY + 1;
                if (boxWidth < 4 || boxHeight < 4) continue;

                double perimeter = 2 * (boxWidth + boxHeight);
                double distance = perimeter <= 0
                        ? 0
                        : count * UNCLIP_RATIO / perimeter;

                float left = (float) ((minX - distance) / scale);
                float topEdge = (float) ((minY - distance) / scale);
                float right = (float) ((maxX + distance) / scale);
                float bottom = (float) ((maxY + distance) / scale);

                left = Math.max(0, left);
                topEdge = Math.max(0, topEdge);
                right = Math.min(imageWidth, right);
                bottom = Math.min(imageHeight, bottom);
                if (right - left < 6 || bottom - topEdge < 6) continue;

                RectF box = new RectF(left, topEdge, right, bottom);
                boolean duplicate = false;
                for (RectF existing : boxes) {
                    if (intersectionOverUnion(existing, box) > 0.75f) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) boxes.add(box);
            }
        }

        Collections.sort(boxes, new Comparator<RectF>() {
            @Override
            public int compare(RectF left, RectF right) {
                int byTop = Float.compare(left.top, right.top);
                return byTop != 0 ? byTop : Float.compare(left.left, right.left);
            }
        });
        return boxes;
    }

    private static float intersectionOverUnion(RectF first, RectF second) {
        float left = Math.max(first.left, second.left);
        float top = Math.max(first.top, second.top);
        float right = Math.min(first.right, second.right);
        float bottom = Math.min(first.bottom, second.bottom);
        if (right <= left || bottom <= top) return 0;
        float intersection = (right - left) * (bottom - top);
        float union = first.width() * first.height()
                + second.width() * second.height() - intersection;
        return union <= 0 ? 0 : intersection / union;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Recognition
    // ─────────────────────────────────────────────────────────────────────

    private static String recognizeLine(Bitmap bitmap, RectF box,
                                        Interpreter recognizer,
                                        float[][][][] input,
                                        float[][][] output,
                                        List<String> dictionary,
                                        int targetWidth, int targetHeight,
                                        int timesteps, int vocabulary) {
        int padding = 2;
        int left = Math.max(0, (int) Math.floor(box.left) - padding);
        int top = Math.max(0, (int) Math.floor(box.top) - padding);
        int right = Math.min(bitmap.getWidth(),
                (int) Math.ceil(box.right) + padding);
        int bottom = Math.min(bitmap.getHeight(),
                (int) Math.ceil(box.bottom) + padding);
        int width = right - left;
        int height = bottom - top;
        if (width < 2 || height < 2) return "";

        Bitmap crop;
        try {
            crop = Bitmap.createBitmap(bitmap, left, top, width, height);
        } catch (Throwable error) {
            return "";
        }

        Bitmap canvas = Bitmap.createBitmap(targetWidth, targetHeight,
                Bitmap.Config.ARGB_8888);
        Canvas drawing = new Canvas(canvas);
        drawing.drawColor(Color.WHITE);
        float scale = Math.min((float) targetWidth / width,
                (float) targetHeight / height);
        int scaledWidth = Math.max(1, Math.round(width * scale));
        int scaledHeight = Math.max(1, Math.round(height * scale));
        Bitmap scaled = Bitmap.createScaledBitmap(crop, scaledWidth,
                scaledHeight, true);
        crop.recycle();
        drawing.drawBitmap(scaled, 0, 0, new Paint(Paint.FILTER_BITMAP_FLAG));
        scaled.recycle();

        int[] pixels = new int[targetWidth * targetHeight];
        canvas.getPixels(pixels, 0, targetWidth, 0, 0, targetWidth, targetHeight);
        canvas.recycle();

        for (int y = 0; y < targetHeight; y++) {
            int row = y * targetWidth;
            for (int x = 0; x < targetWidth; x++) {
                int pixel = pixels[row + x];
                input[0][0][y][x] = ((pixel >> 16) & 0xFF) / 127.5f - 1.0f;
                input[0][1][y][x] = ((pixel >> 8) & 0xFF) / 127.5f - 1.0f;
                input[0][2][y][x] = (pixel & 0xFF) / 127.5f - 1.0f;
            }
        }

        recognizer.run(input, output);
        return decodeCtc(output[0], timesteps, vocabulary, dictionary);
    }

    private static String decodeCtc(float[][] logits, int timesteps,
                                    int vocabulary, List<String> dictionary) {
        StringBuilder text = new StringBuilder();
        int previous = -1;
        for (int t = 0; t < timesteps; t++) {
            int best = 0;
            float bestValue = logits[t][0];
            for (int v = 1; v < vocabulary; v++) {
                if (logits[t][v] > bestValue) {
                    bestValue = logits[t][v];
                    best = v;
                }
            }
            if (best != 0 && best != previous) {
                int index = best - 1;
                if (index < dictionary.size()) {
                    text.append(dictionary.get(index));
                } else if (index == dictionary.size()) {
                    text.append(' ');
                }
            }
            previous = best;
        }
        return text.toString().trim();
    }

    // ─────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────

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

    private static String emptyResult(Bitmap bitmap) throws Exception {
        JSONObject root = new JSONObject();
        root.put("source", "ocr");
        root.put("engine", "litert");
        root.put("width", bitmap.getWidth());
        root.put("height", bitmap.getHeight());
        root.put("text", "");
        root.put("lines", new JSONArray());
        return root.toString();
    }

    private static MappedByteBuffer mapModel(File file) throws Exception {
        FileInputStream stream = new FileInputStream(file);
        try {
            FileChannel channel = stream.getChannel();
            return channel.map(FileChannel.MapMode.READ_ONLY, 0, channel.size());
        } finally {
            stream.close();
        }
    }

    private static List<String> loadDictionary(File file) throws Exception {
        List<String> tokens = new ArrayList<>();
        BufferedReader reader = new BufferedReader(new InputStreamReader(
                new FileInputStream(file), StandardCharsets.UTF_8));
        try {
            String line;
            while ((line = reader.readLine()) != null) {
                if (!line.isEmpty()) tokens.add(line);
            }
        } finally {
            reader.close();
        }
        return tokens;
    }

    private static void close(Interpreter interpreter) {
        try {
            interpreter.close();
        } catch (Throwable ignored) {
            // Already closed.
        }
    }
}
