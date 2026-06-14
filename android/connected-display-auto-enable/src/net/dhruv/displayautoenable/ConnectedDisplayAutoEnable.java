package net.dhruv.displayautoenable;

import android.hardware.display.DisplayManager;
import android.os.Handler;
import android.os.HandlerThread;
import android.view.Display;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.CountDownLatch;

public final class ConnectedDisplayAutoEnable {
    private static final long EVENT_FLAG_DISPLAY_ADDED = 1L << 0;
    private static final long EVENT_FLAG_DISPLAY_REMOVED = 1L << 1;
    private static final long EVENT_FLAG_DISPLAY_CHANGED = 1L << 2;
    private static final long PRIVATE_EVENT_FLAG_DISPLAY_CONNECTION_CHANGED = 1L << 2;
    private static final long INTERNAL_EVENT_FLAG_DISPLAY_ADDED = 1L << 0;
    private static final long INTERNAL_EVENT_FLAG_DISPLAY_CHANGED = 1L << 1;
    private static final long INTERNAL_EVENT_FLAG_DISPLAY_REMOVED = 1L << 2;
    private static final long INTERNAL_EVENT_FLAG_DISPLAY_CONNECTION_CHANGED = 1L << 5;
    private static final int DISPLAY_TYPE_EXTERNAL = 2;
    private static final Map<Integer, Long> LAST_ENABLE_ATTEMPT_MS = new HashMap<>();

    private ConnectedDisplayAutoEnable() {
    }

    public static void main(String[] args) throws Exception {
        String command = args.length > 0 ? args[0] : "watch";
        if ("help".equals(command) || "--help".equals(command)) {
            usage();
            return;
        }

        relaxHiddenApi();
        Object displayManagerGlobal = displayManagerGlobal();

        if ("once".equals(command)) {
            enablePendingDisplays(displayManagerGlobal);
            return;
        }

        if (!"watch".equals(command)) {
            throw new IllegalArgumentException("unknown command: " + command);
        }

        enablePendingDisplays(displayManagerGlobal);

        HandlerThread thread = new HandlerThread("connected-display-auto-enable");
        thread.start();
        Handler handler = new Handler(thread.getLooper());
        DisplayManager.DisplayListener listener = new DisplayManager.DisplayListener() {
            @Override
            public void onDisplayAdded(int displayId) {
                enablePendingDisplays(displayManagerGlobal);
            }

            @Override
            public void onDisplayRemoved(int displayId) {
                enablePendingDisplays(displayManagerGlobal);
            }

            @Override
            public void onDisplayChanged(int displayId) {
                enablePendingDisplays(displayManagerGlobal);
            }

            public void onDisplayConnected(int displayId) {
                enablePendingDisplays(displayManagerGlobal);
            }

            public void onDisplayDisconnected(int displayId) {
                enablePendingDisplays(displayManagerGlobal);
            }
        };

        registerDisplayListener(displayManagerGlobal, listener, handler);
        startFastPoll(displayManagerGlobal, handler);
        new CountDownLatch(1).await();
    }

    private static void usage() {
        System.out.println("usage: ConnectedDisplayAutoEnable [once|watch]");
    }

    private static void enablePendingDisplays(Object displayManagerGlobal) {
        int[] displayIds = getDisplayIds(displayManagerGlobal, true);
        for (int displayId : displayIds) {
            if (displayId == Display.DEFAULT_DISPLAY) {
                continue;
            }
            Object displayInfo = getDisplayInfo(displayManagerGlobal, displayId);
            if (displayInfo == null) {
                continue;
            }
            if (displayInfoInt(displayInfo, "type") != DISPLAY_TYPE_EXTERNAL) {
                continue;
            }
            if (displayInfoInt(displayInfo, "state") != Display.STATE_OFF) {
                continue;
            }
            maybeEnableDisplay(displayManagerGlobal, displayId);
        }
    }

    private static void maybeEnableDisplay(Object displayManagerGlobal, int displayId) {
        long now = System.currentTimeMillis();
        Long lastAttempt = LAST_ENABLE_ATTEMPT_MS.get(Integer.valueOf(displayId));
        if (lastAttempt != null && now - lastAttempt.longValue() < 5000) {
            return;
        }
        LAST_ENABLE_ATTEMPT_MS.put(Integer.valueOf(displayId), Long.valueOf(now));
        enableDisplay(displayManagerGlobal, displayId);
    }

    private static void enableDisplay(Object displayManagerGlobal, int displayId) {
        invokeEnableConnectedDisplay(displayManagerGlobal, displayId);
        runCmdEnableDisplay(displayId);
        runCmdPowerReset(displayId);
        logVisibleDisplayIds();
    }

    private static void startFastPoll(final Object displayManagerGlobal, Handler handler) {
        handler.post(new Runnable() {
            @Override
            public void run() {
                enablePendingDisplays(displayManagerGlobal);
                handler.postDelayed(this, 1000);
            }
        });
        System.out.println("started 1000ms pending-display poll");
    }

    private static int[] getDisplayIds(Object displayManagerGlobal, boolean includeDisabled) {
        try {
            Method method = displayManagerGlobal.getClass().getDeclaredMethod(
                    "getDisplayIds", boolean.class);
            method.setAccessible(true);
            return (int[]) method.invoke(displayManagerGlobal, includeDisabled);
        } catch (Throwable ex) {
            System.out.println("getDisplayIds failed: " + ex.getClass().getName()
                    + ": " + ex.getMessage());
            return new int[0];
        }
    }

    private static Object getDisplayInfo(Object displayManagerGlobal, int displayId) {
        try {
            Method method = displayManagerGlobal.getClass().getDeclaredMethod(
                    "getDisplayInfo", int.class);
            method.setAccessible(true);
            return method.invoke(displayManagerGlobal, displayId);
        } catch (Throwable ex) {
            System.out.println("getDisplayInfo failed for " + displayId + ": "
                    + ex.getClass().getName() + ": " + ex.getMessage());
            return null;
        }
    }

    private static int displayInfoInt(Object displayInfo, String fieldName) {
        try {
            Field field = displayInfo.getClass().getDeclaredField(fieldName);
            field.setAccessible(true);
            return field.getInt(displayInfo);
        } catch (Throwable ex) {
            return -1;
        }
    }

    private static boolean invokeEnableConnectedDisplay(Object displayManagerGlobal, int displayId) {
        try {
            Method method = displayManagerGlobal.getClass().getDeclaredMethod(
                    "enableConnectedDisplay", int.class);
            method.setAccessible(true);
            method.invoke(displayManagerGlobal, displayId);
            System.out.println("enabled connected display " + displayId
                    + " via DisplayManagerGlobal");
            return true;
        } catch (Throwable ex) {
            Throwable cause = ex.getCause() == null ? ex : ex.getCause();
            System.out.println("DisplayManager enable failed for " + displayId + ": "
                    + cause.getClass().getName() + ": " + cause.getMessage());
            return false;
        }
    }

    private static void runCmdEnableDisplay(int displayId) {
        try {
            Process process = new ProcessBuilder(
                    "/system/bin/cmd", "display", "enable-display", String.valueOf(displayId))
                    .redirectErrorStream(true)
                    .start();
            int exit = process.waitFor();
            System.out.println("cmd display enable-display " + displayId + " exit " + exit);
        } catch (Throwable ex) {
            System.out.println("cmd display enable failed for " + displayId + ": "
                    + ex.getClass().getName() + ": " + ex.getMessage());
        }
    }

    private static void runCmdPowerReset(int displayId) {
        try {
            Process process = new ProcessBuilder(
                    "/system/bin/cmd", "display", "power-reset", String.valueOf(displayId))
                    .redirectErrorStream(true)
                    .start();
            int exit = process.waitFor();
            System.out.println("cmd display power-reset " + displayId + " exit " + exit);
        } catch (Throwable ex) {
            System.out.println("cmd display power-reset failed for " + displayId + ": "
                    + ex.getClass().getName() + ": " + ex.getMessage());
        }
    }

    private static void logVisibleDisplayIds() {
        try {
            Process process = new ProcessBuilder(
                    "/system/bin/cmd", "display", "get-displays", "--ids-only")
                    .redirectErrorStream(true)
                    .start();
            byte[] output = new byte[4096];
            int length = process.getInputStream().read(output);
            int exit = process.waitFor();
            String text = length > 0 ? new String(output, 0, length).trim() : "";
            System.out.println("cmd display get-displays exit " + exit + ": " + text);
        } catch (Throwable ex) {
            System.out.println("cmd display get-displays failed: "
                    + ex.getClass().getName() + ": " + ex.getMessage());
        }
    }

    private static void registerDisplayListener(Object displayManagerGlobal,
            DisplayManager.DisplayListener listener, Handler handler) {
        long eventFlags = EVENT_FLAG_DISPLAY_ADDED
                | EVENT_FLAG_DISPLAY_REMOVED
                | EVENT_FLAG_DISPLAY_CHANGED;
        long internalFlags = INTERNAL_EVENT_FLAG_DISPLAY_ADDED
                | INTERNAL_EVENT_FLAG_DISPLAY_CHANGED
                | INTERNAL_EVENT_FLAG_DISPLAY_REMOVED
                | INTERNAL_EVENT_FLAG_DISPLAY_CONNECTION_CHANGED;
        try {
            Method mapMethod = findMethod(displayManagerGlobal.getClass(),
                    "mapFlagsToInternalEventFlag", 2);
            if (mapMethod != null) {
                mapMethod.setAccessible(true);
                internalFlags = ((Long) mapMethod.invoke(displayManagerGlobal, eventFlags,
                        PRIVATE_EVENT_FLAG_DISPLAY_CONNECTION_CHANGED)).longValue();
            }

            Method method = displayManagerGlobal.getClass().getDeclaredMethod(
                    "registerDisplayListener",
                    DisplayManager.DisplayListener.class,
                    Handler.class,
                    long.class,
                    String.class);
            method.setAccessible(true);
            method.invoke(displayManagerGlobal, listener, handler, internalFlags,
                    "net.dhruv.displayautoenable");
            System.out.println("registered display listener with internal flags " + internalFlags);
        } catch (Throwable ex) {
            Throwable cause = ex.getCause() == null ? ex : ex.getCause();
            System.out.println("private display listener failed, using public event flags: "
                    + cause.getClass().getName() + ": " + cause.getMessage());
            try {
                Method method = displayManagerGlobal.getClass().getDeclaredMethod(
                        "registerDisplayListener",
                        DisplayManager.DisplayListener.class,
                        Handler.class,
                        long.class,
                        String.class);
                method.setAccessible(true);
                method.invoke(displayManagerGlobal, listener, handler, eventFlags,
                        "net.dhruv.displayautoenable");
            } catch (Throwable second) {
                Throwable secondCause = second.getCause() == null ? second : second.getCause();
                throw new IllegalStateException("display listener registration failed",
                        secondCause);
            }
        }
    }

    private static Method findMethod(Class<?> cls, String name, int parameterCount) {
        for (Method method : cls.getDeclaredMethods()) {
            if (method.getName().equals(name)
                    && method.getParameterTypes().length == parameterCount) {
                return method;
            }
        }
        return null;
    }

    private static Object displayManagerGlobal() throws Exception {
        Class<?> cls = Class.forName("android.hardware.display.DisplayManagerGlobal");
        Method getInstance = cls.getDeclaredMethod("getInstance");
        getInstance.setAccessible(true);
        Object global = getInstance.invoke(null);
        if (global == null) {
            throw new IllegalStateException("DisplayManagerGlobal unavailable");
        }
        return global;
    }

    private static void relaxHiddenApi() {
        try {
            Class<?> runtimeClass = Class.forName("dalvik.system.VMRuntime");
            Method getRuntime = runtimeClass.getDeclaredMethod("getRuntime");
            Method setHiddenApiExemptions =
                    runtimeClass.getDeclaredMethod("setHiddenApiExemptions", String[].class);
            Object runtime = getRuntime.invoke(null);
            setHiddenApiExemptions.invoke(runtime, (Object) new String[] {"L"});
        } catch (Throwable ignored) {
        }
    }
}
