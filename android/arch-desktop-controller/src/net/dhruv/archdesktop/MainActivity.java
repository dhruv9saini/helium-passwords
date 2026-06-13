package net.dhruv.archdesktop;

import android.app.Activity;
import android.content.Context;
import android.graphics.PointF;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.OutputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;

public final class MainActivity extends Activity {
    private static final String RESUME_SCRIPT = "/data/local/chroots/arch/arch-desktop-resume-root.sh";
    private static final String HIBERNATE_SCRIPT = "/data/local/chroots/arch/arch-desktop-hibernate-root.sh";
    private static final String POINTER_HELPER_COMMAND =
            "chroot /data/local/chroots/arch /usr/bin/env DISPLAY=:1 "
                    + "XDG_RUNTIME_DIR=/tmp/runtime-root "
                    + "PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/bin "
                    + "/root/.local/bin/x11-pointer-helper >/dev/null 2>&1";
    private static final float MOVE_SENSITIVITY = 0.70f;
    private static final float SCROLL_SENSITIVITY = 0.72f;

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService rootExecutor = Executors.newSingleThreadExecutor();
    private final ExecutorService inputExecutor = Executors.newSingleThreadExecutor();
    private boolean startRequested;
    private boolean desktopRunning;
    private boolean hibernateRequested;
    private Process pointerProcess;
    private OutputStream pointerInput;
    private TextView status;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        setContentView(buildLayout());

        if (state != null) {
            startRequested = state.getBoolean("startRequested", false);
            desktopRunning = state.getBoolean("desktopRunning", false);
            hibernateRequested = state.getBoolean("hibernateRequested", false);
            if (desktopRunning) {
                status.setText("Arch desktop running");
            }
        }

        if (!startRequested) {
            startRequested = true;
            resumeDesktop();
        }
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        outState.putBoolean("startRequested", startRequested);
        outState.putBoolean("desktopRunning", desktopRunning);
        outState.putBoolean("hibernateRequested", hibernateRequested);
        super.onSaveInstanceState(outState);
    }

    @Override
    public void onBackPressed() {
        requestHibernate(true);
    }

    @Override
    protected void onDestroy() {
        if (isFinishing() && desktopRunning && !hibernateRequested) {
            requestHibernate(false);
        }
        stopPointerProcess();
        rootExecutor.shutdown();
        inputExecutor.shutdownNow();
        super.onDestroy();
    }

    private View buildLayout() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(0xff05070a);

        status = new TextView(this);
        status.setGravity(Gravity.CENTER);
        status.setTextSize(14);
        status.setTextColor(0xffe6f8ff);
        status.setBackgroundColor(0xff101418);
        status.setText("Starting Arch desktop...");
        int pad = dp(12);
        status.setPadding(pad, pad, pad, pad);
        root.addView(status, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        root.addView(new TrackpadView(this), new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                0,
                1.0f));

        Button hibernate = new Button(this);
        hibernate.setAllCaps(false);
        hibernate.setText("Hibernate");
        hibernate.setTextColor(0xffffffff);
        hibernate.setBackgroundColor(0xff20303a);
        hibernate.setPadding(pad, pad, pad, pad);
        hibernate.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                requestHibernate(true);
            }
        });
        root.addView(hibernate, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        return root;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private void resumeDesktop() {
        rootExecutor.execute(new Runnable() {
            @Override
            public void run() {
                final int code = runRoot(RESUME_SCRIPT);
                main.post(new Runnable() {
                    @Override
                    public void run() {
                        if (code == 0) {
                            desktopRunning = true;
                            status.setText("Arch desktop running");
                        } else {
                            status.setText("Desktop start failed. Check Magisk/root permission.");
                        }
                    }
                });
            }
        });
    }

    private void requestHibernate(final boolean finishWhenDone) {
        if (hibernateRequested) {
            return;
        }
        hibernateRequested = true;
        status.setText("Hibernating Arch desktop...");
        stopPointerProcess();
        rootExecutor.execute(new Runnable() {
            @Override
            public void run() {
                final int code = runRoot(HIBERNATE_SCRIPT);
                main.post(new Runnable() {
                    @Override
                    public void run() {
                        if (code == 0) {
                            desktopRunning = false;
                            status.setText("Arch desktop hibernated");
                            if (finishWhenDone) {
                                finishAndRemoveTask();
                            }
                        } else {
                            hibernateRequested = false;
                            status.setText("Hibernate failed. Check Magisk/root permission.");
                        }
                    }
                });
            }
        });
    }

    private int runRoot(String script) {
        Process process = null;
        try {
            process = new ProcessBuilder("su", "-mm", "-c", script).redirectErrorStream(true).start();
            try (BufferedReader reader = new BufferedReader(new InputStreamReader(process.getInputStream()))) {
                while (reader.readLine() != null) {
                    // Drain output so root commands cannot block on a full pipe.
                }
            }
            return process.waitFor();
        } catch (Exception ignored) {
            return 1;
        } finally {
            if (process != null) {
                process.destroy();
            }
        }
    }

    private void sendPointerLine(final String line) {
        try {
            inputExecutor.execute(new Runnable() {
                @Override
                public void run() {
                    try {
                        writePointerLine(line);
                    } catch (IOException ignored) {
                        stopPointerProcess();
                        try {
                            writePointerLine(line);
                        } catch (IOException ignoredAgain) {
                            stopPointerProcess();
                        }
                    }
                }
            });
        } catch (RejectedExecutionException ignored) {
            // Activity shutdown is already in progress.
        }
    }

    private void writePointerLine(String line) throws IOException {
        ensurePointerProcess();
        pointerInput.write((line + "\n").getBytes(StandardCharsets.UTF_8));
        pointerInput.flush();
    }

    private void ensurePointerProcess() throws IOException {
        if (pointerProcess != null) {
            try {
                pointerProcess.exitValue();
                stopPointerProcess();
            } catch (IllegalThreadStateException running) {
                return;
            }
        }
        pointerProcess = new ProcessBuilder("su", "-mm", "-c", POINTER_HELPER_COMMAND)
                .redirectErrorStream(true)
                .start();
        pointerInput = pointerProcess.getOutputStream();
    }

    private void stopPointerProcess() {
        if (pointerInput != null) {
            try {
                pointerInput.close();
            } catch (IOException ignored) {
                // Nothing useful to do while the process is being torn down.
            }
            pointerInput = null;
        }
        if (pointerProcess != null) {
            pointerProcess.destroy();
            pointerProcess = null;
        }
    }

    private final class TrackpadView extends View {
        private static final int TAP_MS = 280;
        private static final float TAP_DISTANCE = 18.0f;

        private final Map<Integer, PointF> active = new HashMap<>();
        private float lastX;
        private float lastY;
        private float startX;
        private float startY;
        private long startedAt;
        private int maxTouches;
        private float maxDistance;
        private float pendingMoveX;
        private float pendingMoveY;
        private float pendingScrollX;
        private float pendingScrollY;
        private boolean flushScheduled;

        TrackpadView(Context context) {
            super(context);
            setBackgroundColor(0xff05070a);
            setFocusable(true);
        }

        @Override
        public boolean onTouchEvent(MotionEvent event) {
            int action = event.getActionMasked();
            switch (action) {
                case MotionEvent.ACTION_DOWN:
                case MotionEvent.ACTION_POINTER_DOWN:
                    addChangedPointer(event);
                    resetGesture();
                    return true;
                case MotionEvent.ACTION_MOVE:
                    updatePointers(event);
                    moveOrScroll();
                    return true;
                case MotionEvent.ACTION_POINTER_UP:
                    removeChangedPointer(event);
                    resetLastCenter();
                    return true;
                case MotionEvent.ACTION_UP:
                    removeChangedPointer(event);
                    finishGesture(false);
                    return true;
                case MotionEvent.ACTION_CANCEL:
                    active.clear();
                    finishGesture(true);
                    return true;
                default:
                    return true;
            }
        }

        private void addChangedPointer(MotionEvent event) {
            int index = event.getActionIndex();
            active.put(event.getPointerId(index), new PointF(event.getX(index), event.getY(index)));
            maxTouches = Math.max(maxTouches, active.size());
        }

        private void updatePointers(MotionEvent event) {
            for (int i = 0; i < event.getPointerCount(); i++) {
                active.put(event.getPointerId(i), new PointF(event.getX(i), event.getY(i)));
            }
            maxTouches = Math.max(maxTouches, active.size());
        }

        private void removeChangedPointer(MotionEvent event) {
            int index = event.getActionIndex();
            active.remove(event.getPointerId(index));
        }

        private void resetGesture() {
            if (active.isEmpty()) {
                return;
            }
            PointF center = center();
            lastX = center.x;
            lastY = center.y;
            startX = center.x;
            startY = center.y;
            startedAt = System.currentTimeMillis();
            maxTouches = Math.max(1, active.size());
            maxDistance = 0.0f;
        }

        private void resetLastCenter() {
            if (active.isEmpty()) {
                return;
            }
            PointF center = center();
            lastX = center.x;
            lastY = center.y;
        }

        private void moveOrScroll() {
            if (active.isEmpty()) {
                return;
            }
            PointF center = center();
            float dx = center.x - lastX;
            float dy = center.y - lastY;
            lastX = center.x;
            lastY = center.y;
            maxDistance = Math.max(maxDistance, distance(center.x, center.y, startX, startY));

            if (active.size() == 1) {
                pendingMoveX += dx * MOVE_SENSITIVITY;
                pendingMoveY += dy * MOVE_SENSITIVITY;
            } else if (active.size() == 2) {
                pendingScrollX += dx * SCROLL_SENSITIVITY;
                pendingScrollY += dy * SCROLL_SENSITIVITY;
            }
            scheduleFlush();
        }

        private void finishGesture(boolean canceled) {
            boolean wasTap = !canceled
                    && maxDistance <= TAP_DISTANCE
                    && System.currentTimeMillis() - startedAt <= TAP_MS;
            if (wasTap) {
                int button = maxTouches == 2 ? 3 : maxTouches >= 3 ? 2 : 1;
                sendPointerLine("click " + button);
            }
            maxTouches = 0;
            maxDistance = 0.0f;
        }

        private PointF center() {
            float x = 0.0f;
            float y = 0.0f;
            for (PointF point : active.values()) {
                x += point.x;
                y += point.y;
            }
            float count = Math.max(1, active.size());
            return new PointF(x / count, y / count);
        }

        private float distance(float ax, float ay, float bx, float by) {
            float dx = ax - bx;
            float dy = ay - by;
            return (float) Math.sqrt(dx * dx + dy * dy);
        }

        private void scheduleFlush() {
            if (flushScheduled) {
                return;
            }
            flushScheduled = true;
            postOnAnimation(new Runnable() {
                @Override
                public void run() {
                    flushScheduled = false;
                    flushPointerDeltas();
                }
            });
        }

        private void flushPointerDeltas() {
            int moveX = Math.round(pendingMoveX);
            int moveY = Math.round(pendingMoveY);
            pendingMoveX -= moveX;
            pendingMoveY -= moveY;
            if (moveX != 0 || moveY != 0) {
                sendPointerLine("move " + moveX + " " + moveY);
            }

            int scrollX = (int) pendingScrollX;
            int scrollY = (int) pendingScrollY;
            pendingScrollX -= scrollX;
            pendingScrollY -= scrollY;
            if (scrollX != 0 || scrollY != 0) {
                sendPointerLine("scroll " + scrollX + " " + scrollY);
            }

            if (Math.abs(pendingMoveX) >= 0.5f || Math.abs(pendingMoveY) >= 0.5f
                    || Math.abs(pendingScrollX) >= 1.0f || Math.abs(pendingScrollY) >= 1.0f) {
                scheduleFlush();
            }
        }
    }
}
