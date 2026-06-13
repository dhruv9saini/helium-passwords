package net.dhruv.archdesktop;

import android.app.Activity;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.widget.TextView;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class MainActivity extends Activity {
    private static final String RESUME_SCRIPT = "/data/local/chroots/arch/arch-desktop-resume-root.sh";

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private boolean startRequested;
    private TextView status;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        status = new TextView(this);
        status.setGravity(Gravity.CENTER);
        status.setTextSize(18);
        status.setTextColor(0xffe6f8ff);
        status.setBackgroundColor(0xff101418);
        status.setText("Starting Arch desktop...");
        setContentView(status);

        if (state != null) {
            startRequested = state.getBoolean("startRequested", false);
        }

        if (!startRequested) {
            startRequested = true;
            resumeDesktop();
        }
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        outState.putBoolean("startRequested", startRequested);
        super.onSaveInstanceState(outState);
    }

    @Override
    protected void onDestroy() {
        executor.shutdownNow();
        super.onDestroy();
    }

    private void resumeDesktop() {
        executor.execute(new Runnable() {
            @Override
            public void run() {
                final int code = runRoot(RESUME_SCRIPT);
                main.post(new Runnable() {
                    @Override
                    public void run() {
                        if (code == 0) {
                            status.setText("Arch desktop started.");
                            finish();
                        } else {
                            status.setText("Desktop start failed. Check Magisk/root permission.");
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
}
