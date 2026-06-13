package net.dhruv.archdesktop;

import android.app.Activity;
import android.content.Context;
import android.content.pm.ActivityInfo;
import android.graphics.PointF;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.InputDevice;
import android.view.KeyEvent;
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
    private static final String ATTACH_SCRIPT = "/data/local/chroots/arch/arch-desktop-attach-root.sh";
    private static final String HIBERNATE_SCRIPT = "/data/local/chroots/arch/arch-desktop-hibernate-root.sh";
    private static final String HIBERNATE_OSD_SCRIPT = "/data/local/chroots/arch/x11-hibernate-hold-osd-root.sh";
    private static final String RUNNING_CHECK_SCRIPT =
            "sh -c 'state=$(cat /data/local/chroots/arch/root/.local/state/x11/session.state 2>/dev/null || true); "
                    + "[ \"$state\" = running ] && "
                    + "{ pgrep -f \"[t]ermux-x11 com.termux.x11 :1\" >/dev/null 2>&1 || "
                    + "[ -S /data/local/chroots/arch/tmp/.X11-unix/X1 ]; }'";
    private static final String POINTER_HELPER_COMMAND =
            "chroot /data/local/chroots/arch /usr/bin/env DISPLAY=:1 "
                    + "XDG_RUNTIME_DIR=/tmp/runtime-root "
                    + "PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/bin "
                    + "/root/.local/bin/x11-pointer-helper >/dev/null 2>&1";
    private static final String KEY_HELPER_COMMAND =
            "chroot /data/local/chroots/arch /usr/bin/env DISPLAY=:1 "
                    + "XDG_RUNTIME_DIR=/tmp/runtime-root "
                    + "PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/bin "
                    + "/root/.local/bin/x11-key-helper";
    private static final float MOVE_SENSITIVITY = 1.65f;
    private static final float SCROLL_SENSITIVITY = 0.13f;
    private static final float HARDWARE_POINTER_SENSITIVITY = 0.75f;
    private static final float HARDWARE_SCROLL_SENSITIVITY = 2.0f;
    private static final long HIBERNATE_HOLD_MS = 3000L;
    private static final long MODIFIER_STUCK_RELEASE_MS = 10000L;

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService rootExecutor = Executors.newSingleThreadExecutor();
    private final ExecutorService inputExecutor = Executors.newSingleThreadExecutor();
    private final Map<Integer, String> forwardedKeys = new HashMap<>();
    private boolean startRequested;
    private boolean attachInFlight;
    private boolean desktopRunning;
    private boolean hibernateRequested;
    private boolean hibernateHoldActive;
    private long hibernateHoldStartedAt;
    private Process pointerProcess;
    private OutputStream pointerInput;
    private Process keyProcess;
    private OutputStream keyInput;
    private Button hibernateButton;
    private TextView status;
    private TrackpadView trackpadView;
    private float pendingHardwareMoveX;
    private float pendingHardwareMoveY;
    private float pendingHardwareScrollX;
    private float pendingHardwareScrollY;
    private float lastHardwareX;
    private float lastHardwareY;
    private boolean hasHardwarePoint;
    private final Runnable hibernateHoldTick = new Runnable() {
        @Override
        public void run() {
            updateHibernateHold();
        }
    };

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE);
        setContentView(buildLayout());

        if (state != null) {
            startRequested = state.getBoolean("startRequested", false);
            desktopRunning = state.getBoolean("desktopRunning", false);
            hibernateRequested = state.getBoolean("hibernateRequested", false);
            if (desktopRunning) {
                status.setText("Arch desktop running");
            }
        }

        attachOrResumeDesktop();
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
    protected void onResume() {
        super.onResume();
        armHardwareInputRepeatedly();
        if (!hibernateRequested) {
            attachOrResumeDesktop();
        }
    }

    @Override
    protected void onPause() {
        releaseForwardedKeys();
        super.onPause();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) {
            armHardwareInputRepeatedly();
        }
    }

    @Override
    public void onPointerCaptureChanged(boolean hasCapture) {
        super.onPointerCaptureChanged(hasCapture);
        if (!hasCapture) {
            hasHardwarePoint = false;
        }
    }

    @Override
    protected void onDestroy() {
        cancelHibernateHold(false);
        if (isFinishing() && desktopRunning && !hibernateRequested) {
            requestHibernate(false);
        }
        stopPointerProcess();
        stopKeyProcess();
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

        trackpadView = new TrackpadView(this);
        root.addView(trackpadView, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                0,
                1.0f));

        hibernateButton = new Button(this);
        hibernateButton.setAllCaps(false);
        hibernateButton.setText("Hold 3 sec to hibernate");
        hibernateButton.setTextSize(20);
        hibernateButton.setTextColor(0xffffffff);
        hibernateButton.setBackgroundColor(0xff263746);
        hibernateButton.setMinHeight(dp(96));
        hibernateButton.setPadding(pad, pad, pad, pad);
        hibernateButton.setOnTouchListener(new View.OnTouchListener() {
            @Override
            public boolean onTouch(View view, MotionEvent event) {
                switch (event.getActionMasked()) {
                    case MotionEvent.ACTION_DOWN:
                        beginHibernateHold();
                        return true;
                    case MotionEvent.ACTION_UP:
                    case MotionEvent.ACTION_CANCEL:
                        cancelHibernateHold(true);
                        return true;
                    default:
                        return true;
                }
            }
        });
        root.addView(hibernateButton, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        return root;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private void attachOrResumeDesktop() {
        if (attachInFlight || hibernateRequested) {
            return;
        }
        attachInFlight = true;
        startRequested = true;
        if (status != null && !desktopRunning) {
            status.setText("Starting Arch desktop...");
        }
        rootExecutor.execute(new Runnable() {
            @Override
            public void run() {
                int running = runRoot(RUNNING_CHECK_SCRIPT);
                final int code = running == 0 ? runRoot(ATTACH_SCRIPT) : runRoot(RESUME_SCRIPT);
                main.post(new Runnable() {
                    @Override
                    public void run() {
                        attachInFlight = false;
                        if (code == 0) {
                            desktopRunning = true;
                            status.setText("Arch desktop running");
                            armHardwareInputRepeatedly();
                        } else {
                            startRequested = false;
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
        clearHibernateHold();
        hibernateRequested = true;
        status.setText("Hibernating Arch desktop...");
        if (hibernateButton != null) {
            hibernateButton.setText("Hibernating...");
        }
        releaseForwardedKeys();
        stopPointerProcess();
        stopKeyProcess();
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
                            resetHibernateButton();
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

    private void runRootAsync(final String script) {
        try {
            rootExecutor.execute(new Runnable() {
                @Override
                public void run() {
                    runRoot(script);
                }
            });
        } catch (RejectedExecutionException ignored) {
            // Activity shutdown is already in progress.
        }
    }

    private void beginHibernateHold() {
        if (!desktopRunning || hibernateRequested || hibernateHoldActive) {
            return;
        }
        hibernateHoldActive = true;
        hibernateHoldStartedAt = System.currentTimeMillis();
        updateHibernateHoldUi(HIBERNATE_HOLD_MS);
        runRootAsync(HIBERNATE_OSD_SCRIPT + " show");
        main.removeCallbacks(hibernateHoldTick);
        main.postDelayed(hibernateHoldTick, 100);
    }

    private void updateHibernateHold() {
        if (!hibernateHoldActive) {
            return;
        }
        long remaining = HIBERNATE_HOLD_MS - (System.currentTimeMillis() - hibernateHoldStartedAt);
        if (remaining <= 0L) {
            completeHibernateHold();
            return;
        }
        updateHibernateHoldUi(remaining);
        main.postDelayed(hibernateHoldTick, 100);
    }

    private void completeHibernateHold() {
        if (!hibernateHoldActive) {
            return;
        }
        clearHibernateHold();
        if (hibernateButton != null) {
            hibernateButton.setText("Hibernating...");
        }
        runRootAsync(HIBERNATE_OSD_SCRIPT + " commit");
        requestHibernate(true);
    }

    private void cancelHibernateHold(boolean updateStatus) {
        if (!hibernateHoldActive) {
            return;
        }
        clearHibernateHold();
        resetHibernateButton();
        if (updateStatus && status != null && desktopRunning && !hibernateRequested) {
            status.setText("Hibernate canceled");
        }
        runRootAsync(HIBERNATE_OSD_SCRIPT + " cancel");
    }

    private void clearHibernateHold() {
        hibernateHoldActive = false;
        main.removeCallbacks(hibernateHoldTick);
    }

    private void updateHibernateHoldUi(long remainingMs) {
        int seconds = Math.max(1, (int) Math.ceil(remainingMs / 1000.0));
        if (hibernateButton != null) {
            hibernateButton.setText("Keep holding: " + seconds);
        }
        if (status != null) {
            status.setText("Release to cancel hibernate");
        }
    }

    private void resetHibernateButton() {
        if (hibernateButton != null) {
            hibernateButton.setText("Hold 3 sec to hibernate");
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

    private void sendKeyLine(final String line) {
        try {
            inputExecutor.execute(new Runnable() {
                @Override
                public void run() {
                    try {
                        writeKeyLine(line);
                    } catch (IOException ignored) {
                        stopKeyProcess();
                        try {
                            writeKeyLine(line);
                        } catch (IOException ignoredAgain) {
                            stopKeyProcess();
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

    private void writeKeyLine(String line) throws IOException {
        ensureKeyProcess();
        keyInput.write((line + "\n").getBytes(StandardCharsets.UTF_8));
        keyInput.flush();
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

    private void ensureKeyProcess() throws IOException {
        if (keyProcess != null) {
            try {
                keyProcess.exitValue();
                stopKeyProcess();
            } catch (IllegalThreadStateException running) {
                return;
            }
        }
        keyProcess = new ProcessBuilder("su", "-mm", "-c", KEY_HELPER_COMMAND)
                .redirectErrorStream(true)
                .start();
        keyInput = keyProcess.getOutputStream();
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

    private void stopKeyProcess() {
        forwardedKeys.clear();
        if (keyInput != null) {
            try {
                keyInput.close();
            } catch (IOException ignored) {
                // Nothing useful to do while the process is being torn down.
            }
            keyInput = null;
        }
        if (keyProcess != null) {
            keyProcess.destroy();
            keyProcess = null;
        }
    }

    private void armHardwareInput() {
        if (trackpadView == null) {
            return;
        }
        trackpadView.setFocusableInTouchMode(true);
        getWindow().getDecorView().setFocusableInTouchMode(true);
        getWindow().getDecorView().requestFocus();
        trackpadView.requestFocus();
    }

    private void armHardwareInputRepeatedly() {
        if (!desktopRunning) {
            return;
        }
        armHardwareInput();
        main.postDelayed(new Runnable() {
            @Override
            public void run() {
                armHardwareInput();
            }
        }, 400);
        main.postDelayed(new Runnable() {
            @Override
            public void run() {
                armHardwareInput();
            }
        }, 1200);
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        if (desktopRunning && forwardKeyEvent(event)) {
            return true;
        }
        return super.dispatchKeyEvent(event);
    }

    @Override
    public boolean dispatchGenericMotionEvent(MotionEvent event) {
        if (desktopRunning && forwardGenericMotionEvent(event)) {
            return true;
        }
        return super.dispatchGenericMotionEvent(event);
    }

    private boolean forwardKeyEvent(KeyEvent event) {
        int keyCode = event.getKeyCode();
        if (keyCode == KeyEvent.KEYCODE_BACK) {
            return false;
        }
        String key = xKeyName(event);
        if (key == null) {
            return false;
        }
        int keyId = forwardedKeyId(event);
        if (event.getAction() == KeyEvent.ACTION_DOWN) {
            if (event.getRepeatCount() > 0) {
                if (isModifierKey(event)) {
                    return true;
                }
                sendKeyLine("key " + key);
                return true;
            }
            if (!forwardedKeys.containsKey(keyId)) {
                forwardedKeys.put(keyId, key);
                sendKeyLine("keydown " + key);
                if (isModifierKey(event)) {
                    scheduleModifierStuckRelease(keyId, key);
                }
            }
            return true;
        }
        if (event.getAction() == KeyEvent.ACTION_UP) {
            forwardedKeys.remove(keyId);
            sendKeyLine("keyup " + key);
            return true;
        }
        return false;
    }

    private int forwardedKeyId(KeyEvent event) {
        int scanCode = event.getScanCode();
        if (scanCode > 0) {
            return (event.getDeviceId() << 16) ^ scanCode;
        }
        return event.getKeyCode();
    }

    private void scheduleModifierStuckRelease(final int keyId, final String key) {
        main.postDelayed(new Runnable() {
            @Override
            public void run() {
                if (key.equals(forwardedKeys.get(keyId))) {
                    forwardedKeys.remove(keyId);
                    sendKeyLine("keyup " + key);
                    sendKeyLine("releaseall");
                }
            }
        }, MODIFIER_STUCK_RELEASE_MS);
    }

    private void releaseForwardedKeys() {
        if (!forwardedKeys.isEmpty()) {
            for (String key : forwardedKeys.values()) {
                sendKeyLine("keyup " + key);
            }
            forwardedKeys.clear();
        }
        sendKeyLine("releaseall");
    }

    private boolean forwardGenericMotionEvent(MotionEvent event) {
        int source = event.getSource();
        boolean pointerSource = (source & InputDevice.SOURCE_MOUSE) == InputDevice.SOURCE_MOUSE
                || (source & InputDevice.SOURCE_TOUCHPAD) == InputDevice.SOURCE_TOUCHPAD
                || (source & InputDevice.SOURCE_TRACKBALL) == InputDevice.SOURCE_TRACKBALL;
        if (!pointerSource) {
            return false;
        }
        armHardwareInput();

        switch (event.getActionMasked()) {
            case MotionEvent.ACTION_SCROLL: {
                pendingHardwareScrollX += event.getAxisValue(MotionEvent.AXIS_HSCROLL) * HARDWARE_SCROLL_SENSITIVITY;
                pendingHardwareScrollY += event.getAxisValue(MotionEvent.AXIS_VSCROLL) * HARDWARE_SCROLL_SENSITIVITY;
                int sx = takeWholeDeltaXScroll();
                int sy = takeWholeDeltaYScroll();
                if (sx != 0 || sy != 0) {
                    sendPointerLine("scroll " + sx + " " + sy);
                }
                return true;
            }
            case MotionEvent.ACTION_BUTTON_PRESS:
            case MotionEvent.ACTION_BUTTON_RELEASE: {
                int button = xButton(event.getActionButton());
                if (button != 0) {
                    String state = event.getActionMasked() == MotionEvent.ACTION_BUTTON_PRESS ? "down" : "up";
                    sendPointerLine("button " + button + " " + state);
                    return true;
                }
                return false;
            }
            case MotionEvent.ACTION_HOVER_MOVE:
            case MotionEvent.ACTION_MOVE: {
                float dx = event.getAxisValue(MotionEvent.AXIS_RELATIVE_X);
                float dy = event.getAxisValue(MotionEvent.AXIS_RELATIVE_Y);
                if (dx == 0.0f && dy == 0.0f) {
                    float x = event.getX();
                    float y = event.getY();
                    if (!hasHardwarePoint) {
                        lastHardwareX = x;
                        lastHardwareY = y;
                        hasHardwarePoint = true;
                        return true;
                    }
                    dx = x - lastHardwareX;
                    dy = y - lastHardwareY;
                    lastHardwareX = x;
                    lastHardwareY = y;
                } else {
                    lastHardwareX = event.getX();
                    lastHardwareY = event.getY();
                    hasHardwarePoint = true;
                }
                if (dx == 0.0f && dy == 0.0f) {
                    return true;
                }
                pendingHardwareMoveX += dx * HARDWARE_POINTER_SENSITIVITY;
                pendingHardwareMoveY += dy * HARDWARE_POINTER_SENSITIVITY;
                int moveX = takeWholeDeltaXMove();
                int moveY = takeWholeDeltaYMove();
                if (moveX != 0 || moveY != 0) {
                    sendPointerLine("move " + moveX + " " + moveY);
                }
                return true;
            }
            default:
                return false;
        }
    }

    private int takeWholeDeltaXMove() {
        int value = takeWholeDelta(pendingHardwareMoveX);
        pendingHardwareMoveX -= value;
        return value;
    }

    private int takeWholeDeltaYMove() {
        int value = takeWholeDelta(pendingHardwareMoveY);
        pendingHardwareMoveY -= value;
        return value;
    }

    private int takeWholeDeltaXScroll() {
        int value = takeWholeDelta(pendingHardwareScrollX);
        pendingHardwareScrollX -= value;
        return value;
    }

    private int takeWholeDeltaYScroll() {
        int value = takeWholeDelta(pendingHardwareScrollY);
        pendingHardwareScrollY -= value;
        return value;
    }

    private int takeWholeDelta(float value) {
        if (value >= 1.0f) {
            return (int) Math.floor(value);
        }
        if (value <= -1.0f) {
            return (int) Math.ceil(value);
        }
        return 0;
    }

    private int xButton(int androidButton) {
        switch (androidButton) {
            case MotionEvent.BUTTON_PRIMARY:
                return 1;
            case MotionEvent.BUTTON_SECONDARY:
                return 3;
            case MotionEvent.BUTTON_TERTIARY:
                return 2;
            case MotionEvent.BUTTON_BACK:
                return 8;
            case MotionEvent.BUTTON_FORWARD:
                return 9;
            default:
                return 0;
        }
    }

    private boolean isModifierKey(KeyEvent event) {
        switch (event.getScanCode()) {
            case 42:
            case 54:
            case 29:
            case 97:
            case 56:
            case 100:
            case 125:
            case 126:
                return true;
            default:
                return isModifierKey(event.getKeyCode());
        }
    }

    private boolean isModifierKey(int keyCode) {
        switch (keyCode) {
            case KeyEvent.KEYCODE_SHIFT_LEFT:
            case KeyEvent.KEYCODE_SHIFT_RIGHT:
            case KeyEvent.KEYCODE_CTRL_LEFT:
            case KeyEvent.KEYCODE_CTRL_RIGHT:
            case KeyEvent.KEYCODE_ALT_LEFT:
            case KeyEvent.KEYCODE_ALT_RIGHT:
            case KeyEvent.KEYCODE_META_LEFT:
            case KeyEvent.KEYCODE_META_RIGHT:
                return true;
            default:
                return false;
        }
    }

    private String xKeyName(KeyEvent event) {
        switch (event.getScanCode()) {
            case 100:
                return "Alt_R";
            case 125:
                return "Super_L";
            case 126:
                return "Super_R";
            default:
                return xKeyName(event.getKeyCode());
        }
    }

    private String xKeyName(int keyCode) {
        if (keyCode >= KeyEvent.KEYCODE_A && keyCode <= KeyEvent.KEYCODE_Z) {
            return String.valueOf((char) ('a' + keyCode - KeyEvent.KEYCODE_A));
        }
        if (keyCode >= KeyEvent.KEYCODE_0 && keyCode <= KeyEvent.KEYCODE_9) {
            return String.valueOf((char) ('0' + keyCode - KeyEvent.KEYCODE_0));
        }
        if (keyCode >= KeyEvent.KEYCODE_F1 && keyCode <= KeyEvent.KEYCODE_F12) {
            return "F" + (keyCode - KeyEvent.KEYCODE_F1 + 1);
        }
        if (keyCode >= KeyEvent.KEYCODE_NUMPAD_0 && keyCode <= KeyEvent.KEYCODE_NUMPAD_9) {
            return "KP_" + (keyCode - KeyEvent.KEYCODE_NUMPAD_0);
        }
        switch (keyCode) {
            case KeyEvent.KEYCODE_ENTER:
            case KeyEvent.KEYCODE_NUMPAD_ENTER:
                return "Return";
            case KeyEvent.KEYCODE_TAB:
                return "Tab";
            case KeyEvent.KEYCODE_SPACE:
                return "space";
            case KeyEvent.KEYCODE_ESCAPE:
                return "Escape";
            case KeyEvent.KEYCODE_DEL:
                return "BackSpace";
            case KeyEvent.KEYCODE_FORWARD_DEL:
                return "Delete";
            case KeyEvent.KEYCODE_DPAD_LEFT:
                return "Left";
            case KeyEvent.KEYCODE_DPAD_RIGHT:
                return "Right";
            case KeyEvent.KEYCODE_DPAD_UP:
                return "Up";
            case KeyEvent.KEYCODE_DPAD_DOWN:
                return "Down";
            case KeyEvent.KEYCODE_MOVE_HOME:
                return "Home";
            case KeyEvent.KEYCODE_MOVE_END:
                return "End";
            case KeyEvent.KEYCODE_PAGE_UP:
                return "Page_Up";
            case KeyEvent.KEYCODE_PAGE_DOWN:
                return "Page_Down";
            case KeyEvent.KEYCODE_INSERT:
                return "Insert";
            case KeyEvent.KEYCODE_SHIFT_LEFT:
                return "Shift_L";
            case KeyEvent.KEYCODE_SHIFT_RIGHT:
                return "Shift_R";
            case KeyEvent.KEYCODE_CTRL_LEFT:
                return "Control_L";
            case KeyEvent.KEYCODE_CTRL_RIGHT:
                return "Control_R";
            case KeyEvent.KEYCODE_ALT_LEFT:
                return "Alt_L";
            case KeyEvent.KEYCODE_ALT_RIGHT:
                return "Alt_R";
            case KeyEvent.KEYCODE_META_LEFT:
                return "Super_L";
            case KeyEvent.KEYCODE_META_RIGHT:
                return "Super_R";
            case KeyEvent.KEYCODE_CAPS_LOCK:
                return "Caps_Lock";
            case KeyEvent.KEYCODE_MINUS:
                return "minus";
            case KeyEvent.KEYCODE_EQUALS:
                return "equal";
            case KeyEvent.KEYCODE_LEFT_BRACKET:
                return "bracketleft";
            case KeyEvent.KEYCODE_RIGHT_BRACKET:
                return "bracketright";
            case KeyEvent.KEYCODE_BACKSLASH:
                return "backslash";
            case KeyEvent.KEYCODE_SEMICOLON:
                return "semicolon";
            case KeyEvent.KEYCODE_APOSTROPHE:
                return "apostrophe";
            case KeyEvent.KEYCODE_COMMA:
                return "comma";
            case KeyEvent.KEYCODE_PERIOD:
                return "period";
            case KeyEvent.KEYCODE_SLASH:
                return "slash";
            case KeyEvent.KEYCODE_GRAVE:
                return "grave";
            case KeyEvent.KEYCODE_NUMPAD_DIVIDE:
                return "KP_Divide";
            case KeyEvent.KEYCODE_NUMPAD_MULTIPLY:
                return "KP_Multiply";
            case KeyEvent.KEYCODE_NUMPAD_SUBTRACT:
                return "KP_Subtract";
            case KeyEvent.KEYCODE_NUMPAD_ADD:
                return "KP_Add";
            case KeyEvent.KEYCODE_NUMPAD_DOT:
                return "KP_Decimal";
            default:
                return null;
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
        public boolean onCapturedPointerEvent(MotionEvent event) {
            return super.onCapturedPointerEvent(event);
        }

        @Override
        public void onPointerCaptureChange(boolean hasCapture) {
            super.onPointerCaptureChange(hasCapture);
            if (!hasCapture) {
                hasHardwarePoint = false;
            }
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
