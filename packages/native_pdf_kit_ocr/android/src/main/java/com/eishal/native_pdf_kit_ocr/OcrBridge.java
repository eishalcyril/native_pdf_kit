package com.eishal.native_pdf_kit_ocr;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Matrix;
import android.graphics.RectF;
import android.graphics.pdf.PdfRenderer;
import android.graphics.pdf.content.PdfPageTextContent;
import android.os.Build;
import android.os.ParcelFileDescriptor;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * JNI entry point for native_pdf_kit_ocr.
 *
 * <p>Every method returns a String, which keeps the low-level JNI calls on the
 * Dart side simple. A job runs on its own thread and is polled for status,
 * progress and its final JSON result. Nothing here touches a platform channel.
 */
public final class OcrBridge {
    private static final int STATUS_RUNNING = 1;
    private static final int STATUS_DONE = 2;
    private static final int STATUS_CANCELLED = 3;
    private static final int STATUS_FAILED = 4;

    private static final int STAGE_PREPARING = 0;
    private static final int STAGE_TEXT_LAYER = 1;
    private static final int STAGE_RENDERING = 2;
    private static final int STAGE_RECOGNIZING = 3;

    private static final Map<String, Session> SESSIONS = new ConcurrentHashMap<>();
    private static final AtomicInteger SEQUENCE = new AtomicInteger(0);

    private OcrBridge() {}

    /** Receives progress from an engine. Values are 0..1. */
    public interface ProgressSink {
        void update(double value);
    }

    /** A task that may throw. */
    private interface Worker {
        void run() throws Exception;
    }

    /**
     * Starts a PDF page job. Returns the session id, or an id whose session is
     * already failed when the file cannot be read.
     */
    public static String startPage(String path, int pageIndex, String optionsJson) {
        Session session = new Session();
        SESSIONS.put(session.id, session);
        if (path == null || path.isEmpty() || !new File(path).isFile()) {
            fail(session, "PDF file not found: " + path);
            return session.id;
        }
        JSONObject options = parseOptions(optionsJson);
        startWorker(session, () -> runPage(session, path, pageIndex, options));
        return session.id;
    }

    /** Starts an encoded image (PNG/JPEG) job. */
    public static String startImage(byte[] bytes, String optionsJson) {
        Session session = new Session();
        SESSIONS.put(session.id, session);
        if (bytes == null || bytes.length == 0) {
            fail(session, "the image is empty");
            return session.id;
        }
        JSONObject options = parseOptions(optionsJson);
        byte[] copy = bytes.clone();
        startWorker(session, () -> runImage(session, copy, options));
        return session.id;
    }

    /** Returns a JSON status object. */
    public static String poll(String id) {
        Session session = SESSIONS.get(id);
        if (session == null) {
            return statusJson(STATUS_FAILED, STAGE_PREPARING, 0, null,
                    "unknown OCR session");
        }
        return statusJson(session.status, session.stage, session.progress,
                session.result, session.error);
    }

    public static String cancel(String id) {
        Session session = SESSIONS.get(id);
        if (session != null) {
            session.cancelled.set(true);
        }
        return "ok";
    }

    public static String release(String id) {
        Session session = SESSIONS.remove(id);
        if (session != null) {
            session.released = true;
            session.cancelled.set(true);
        }
        return "ok";
    }

    /** JSON array of BCP-47 hints for the selected script. */
    public static String supportedLanguages(String optionsJson) {
        JSONObject options = parseOptions(optionsJson);
        String script = options.optString("script", "latin");
        JSONArray languages = new JSONArray();
        switch (script) {
            case "chinese":
                languages.put("zh-Hans");
                languages.put("zh-Hant");
                break;
            case "japanese":
                languages.put("ja");
                break;
            case "korean":
                languages.put("ko");
                break;
            case "devanagari":
                languages.put("hi");
                languages.put("mr");
                languages.put("ne");
                break;
            default:
                for (String code : new String[] {
                        "en", "es", "fr", "de", "it", "pt", "nl", "sv", "da",
                        "nb", "fi", "pl", "cs", "sk", "hu", "ro", "tr", "vi",
                        "id", "ms", "tl"}) {
                    languages.put(code);
                }
                break;
        }
        return languages.toString();
    }

    // ─────────────────────────────────────────────────────────────────────
    // Jobs
    // ─────────────────────────────────────────────────────────────────────

    private static void runPage(Session session, String path, int pageIndex,
                                JSONObject options) throws Exception {
        ParcelFileDescriptor descriptor =
                ParcelFileDescriptor.open(new File(path), ParcelFileDescriptor.MODE_READ_ONLY);
        if (descriptor == null) {
            fail(session, "could not open the PDF file");
            return;
        }
        PdfRenderer renderer = new PdfRenderer(descriptor);
        try {
            if (pageIndex < 0 || pageIndex >= renderer.getPageCount()) {
                fail(session, "page " + pageIndex + " is out of range");
                return;
            }
            try (PdfRenderer.Page page = renderer.openPage(pageIndex)) {
                String mode = options.optString("mode", "auto");
                if (!"ocr".equals(mode)) {
                    session.stage = STAGE_TEXT_LAYER;
                    session.setProgress(0.03);
                    JSONObject layer = textLayer(page);
                    if (layer != null) {
                        String text = layer.optString("text", "");
                        int minimum = options.optInt("minTextChars", 12);
                        if ("text".equals(mode) || characterCount(text) >= minimum) {
                            finishDone(session, layer.toString());
                            return;
                        }
                    }
                    if ("text".equals(mode)) {
                        finishDone(session, emptyTextLayer(page));
                        return;
                    }
                    if (session.cancelled.get()) {
                        finishCancelled(session);
                        return;
                    }
                }

                session.stage = STAGE_RENDERING;
                session.setProgress(0.08);
                Bitmap bitmap = render(page, options);
                if (bitmap == null) {
                    fail(session, "could not rasterize the page");
                    return;
                }
                try {
                    if (session.cancelled.get()) {
                        finishCancelled(session);
                        return;
                    }
                    session.stage = STAGE_RECOGNIZING;
                    session.setProgress(0.15);
                    String result = recognize(session, bitmap, options);
                    if (session.cancelled.get()) {
                        finishCancelled(session);
                        return;
                    }
                    finishDone(session, result);
                } finally {
                    bitmap.recycle();
                }
            }
        } finally {
            try {
                renderer.close();
            } catch (Throwable ignored) {
                // Already closed.
            }
            try {
                descriptor.close();
            } catch (Throwable ignored) {
                // Already closed.
            }
        }
    }

    private static void runImage(Session session, byte[] bytes,
                                 JSONObject options) throws Exception {
        session.stage = STAGE_RENDERING;
        session.setProgress(0.05);
        Bitmap bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.length);
        if (bitmap == null) {
            fail(session, "could not decode the image");
            return;
        }
        try {
            if (session.cancelled.get()) {
                finishCancelled(session);
                return;
            }
            session.stage = STAGE_RECOGNIZING;
            session.setProgress(0.15);
            String result = recognize(session, bitmap, options);
            if (session.cancelled.get()) {
                finishCancelled(session);
                return;
            }
            finishDone(session, result);
        } finally {
            bitmap.recycle();
        }
    }

    private static String recognize(Session session, Bitmap bitmap,
                                    JSONObject options) throws Exception {
        String engine = options.optString("engine", "mlkit");
        if ("litert".equals(engine)) {
            return recognizeWithLiteRt(session, bitmap, options);
        }
        return MlKitEngine.recognize(bitmap, options, session.cancelled,
                session::setProgress);
    }

    /**
     * LiteRT is optional: the app adds the runtime dependency. Reflection keeps
     * the class from being resolved when only ML Kit is in use.
     */
    private static String recognizeWithLiteRt(Session session, Bitmap bitmap,
                                              JSONObject options) throws Exception {
        final Class<?> engine;
        try {
            engine = Class.forName("com.eishal.native_pdf_kit_ocr.LiteRtEngine");
        } catch (ClassNotFoundException error) {
            throw new IllegalStateException(
                    "LiteRT is not installed; add "
                            + "com.google.ai.edge.litert:litert:2.2.0 to the app "
                            + "and raise minSdk to 24",
                    error);
        }
        final Method method = engine.getMethod("recognize", Bitmap.class,
                JSONObject.class, AtomicBoolean.class, ProgressSink.class);
        try {
            return (String) method.invoke(null, bitmap, options,
                    session.cancelled, (ProgressSink) session::setProgress);
        } catch (InvocationTargetException error) {
            Throwable cause = error.getCause();
            throw new IllegalStateException(
                    cause == null ? error.toString() : cause.getMessage(), cause);
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // Android 15+ text layer
    // ─────────────────────────────────────────────────────────────────────

    @SuppressWarnings("NewApi")
    private static JSONObject textLayer(PdfRenderer.Page page) {
        if (Build.VERSION.SDK_INT < 35) {
            return null;
        }
        final List<PdfPageTextContent> contents;
        try {
            contents = page.getTextContents();
        } catch (Throwable error) {
            return null;
        }
        if (contents == null || contents.isEmpty()) {
            return null;
        }

        double pageWidth = Math.max(1, page.getWidth());
        double pageHeight = Math.max(1, page.getHeight());
        JSONArray lines = new JSONArray();
        StringBuilder text = new StringBuilder();
        for (PdfPageTextContent content : contents) {
            String value = content.getText();
            if (value == null || value.trim().isEmpty()) {
                continue;
            }
            if (text.length() > 0) {
                text.append('\n');
            }
            text.append(value);

            JSONObject line = new JSONObject();
            try {
                line.put("text", value);
                line.put("confidence", 1.0);
                List<RectF> bounds = content.getBounds();
                if (bounds != null && !bounds.isEmpty()) {
                    RectF box = bounds.get(0);
                    line.put("box", boxArray(box.left / pageWidth,
                            box.top / pageHeight,
                            box.width() / pageWidth,
                            box.height() / pageHeight));
                } else {
                    line.put("box", boxArray(0, 0, 1, 1));
                }
                lines.put(line);
            } catch (Exception ignored) {
                // Skip a malformed line.
            }
        }
        if (text.length() == 0) {
            return null;
        }
        try {
            JSONObject root = new JSONObject();
            root.put("source", "text-layer");
            root.put("engine", "android-pdf");
            root.put("width", pageWidth);
            root.put("height", pageHeight);
            root.put("text", text.toString());
            root.put("lines", lines);
            return root;
        } catch (Exception error) {
            return null;
        }
    }

    private static String emptyTextLayer(PdfRenderer.Page page) {
        try {
            JSONObject root = new JSONObject();
            root.put("source", "text-layer");
            root.put("engine", "android-pdf");
            root.put("width", Math.max(1, page.getWidth()));
            root.put("height", Math.max(1, page.getHeight()));
            root.put("text", "");
            root.put("lines", new JSONArray());
            return root.toString();
        } catch (Exception error) {
            return "{\"source\":\"text-layer\",\"engine\":\"android-pdf\","
                    + "\"width\":0,\"height\":0,\"text\":\"\",\"lines\":[]}";
        }
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

    private static int characterCount(String text) {
        if (text == null) return 0;
        int count = 0;
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (!Character.isWhitespace(c)) count++;
        }
        return count;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Rendering
    // ─────────────────────────────────────────────────────────────────────

    private static Bitmap render(PdfRenderer.Page page, JSONObject options) {
        double target = options.optDouble("renderWidth", 2000.0);
        if (target < 200) target = 200;
        if (target > 6000) target = 6000;
        int pageWidth = Math.max(1, page.getWidth());
        int pageHeight = Math.max(1, page.getHeight());
        int width = Math.max(1, (int) Math.round(target));
        int height = Math.max(1, (int) Math.round(pageHeight * (target / pageWidth)));

        Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
        if (bitmap == null) return null;
        bitmap.eraseColor(0xFFFFFFFF);
        Matrix matrix = new Matrix();
        matrix.setScale((float) (target / pageWidth), (float) (target / pageWidth));
        try {
            page.render(bitmap, null, matrix,
                    PdfRenderer.Page.RENDER_MODE_FOR_PRINT);
        } catch (Throwable error) {
            bitmap.recycle();
            return null;
        }
        return bitmap;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Session plumbing
    // ─────────────────────────────────────────────────────────────────────

    private static JSONObject parseOptions(String json) {
        if (json == null || json.isEmpty()) return new JSONObject();
        try {
            return new JSONObject(json);
        } catch (Exception error) {
            return new JSONObject();
        }
    }

    private static void startWorker(Session session, Worker worker) {
        Thread thread = new Thread(() -> {
            try {
                worker.run();
            } catch (Throwable error) {
                if (session.cancelled.get()) {
                    finishCancelled(session);
                } else {
                    fail(session, describe(error));
                }
            }
        }, "npdf-ocr-" + session.id);
        thread.setDaemon(true);
        thread.start();
    }

    private static void finishDone(Session session, String result) {
        session.result = result;
        session.error = null;
        session.progress = 1.0;
        session.status = STATUS_DONE;
    }

    private static void finishCancelled(Session session) {
        session.status = STATUS_CANCELLED;
        session.error = null;
    }

    private static void fail(Session session, String message) {
        session.error = message;
        session.result = null;
        session.status = STATUS_FAILED;
    }

    private static String describe(Throwable error) {
        String message = error.getMessage();
        if (message == null || message.isEmpty()) {
            message = error.getClass().getSimpleName();
        }
        if (message.length() > 600) {
            message = message.substring(0, 600);
        }
        return message;
    }

    private static String statusJson(int status, int stage, double progress,
                                     String result, String error) {
        try {
            JSONObject object = new JSONObject();
            object.put("status", status);
            object.put("stage", stage);
            object.put("progress", Math.max(0, Math.min(1, progress)));
            object.put("result", result == null ? JSONObject.NULL : result);
            object.put("error", error == null ? JSONObject.NULL : error);
            return object.toString();
        } catch (Exception ignored) {
            return "{\"status\":4,\"stage\":0,\"progress\":0,"
                    + "\"result\":null,\"error\":\"status serialization failed\"}";
        }
    }

    private static final class Session {
        final String id = Integer.toString(SEQUENCE.incrementAndGet(), 36);
        final AtomicBoolean cancelled = new AtomicBoolean(false);
        volatile int status = STATUS_RUNNING;
        volatile int stage = STAGE_PREPARING;
        volatile double progress = 0;
        volatile String result;
        volatile String error;
        volatile boolean released;

        void setProgress(double value) {
            if (value > progress) {
                progress = Math.min(1, value);
            }
        }
    }
}
