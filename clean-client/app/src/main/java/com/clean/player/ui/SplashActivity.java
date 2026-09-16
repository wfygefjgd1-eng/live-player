package com.clean.player.ui;

import android.content.Intent;
import android.os.Bundle;
import android.widget.TextView;

import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;

import com.clean.player.R;
import com.clean.player.model.ApiResponse;
import com.clean.player.model.SystemInfo;
import com.clean.player.net.LineConfig;
import com.clean.player.net.NetManager;
import com.clean.player.util.DeviceUtil;
import com.clean.player.util.Prefs;
import com.google.gson.Gson;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import okhttp3.Request;
import okhttp3.Response;
import retrofit2.Call;

/**
 * Line check + system bootstrap. No splash ads / force update ads.
 */
public class SplashActivity extends AppCompatActivity {
    private TextView tvStatus;
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final Gson gson = new Gson();

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_splash);
        tvStatus = findViewById(R.id.tvStatus);
        io.execute(this::boot);
    }

    private void boot() {
        if (isFinishing() || isDestroyed()) return;
        setStatus("线路检测中…");
        String probed = pickLine();

        // 候选顺序：探测命中的线路优先，其余线路兜底；
        // 仅当 systemInfo 成功时才持久化线路，坏线（如被劫持返回 200 的静态页）不会被记住
        List<String> candidates = new ArrayList<>(LineConfig.all());
        if (probed != null) {
            candidates.remove(probed);
            candidates.add(0, probed);
        }

        String chosen = null;
        for (String base : candidates) {
            if (isFinishing() || isDestroyed()) return;
            setStatus("初始化系统信息…");
            NetManager.useBaseUrl(base);
            SystemInfo info = fetchSystemInfo(base);
            if (info != null) {
                chosen = base;
                break;
            }
        }
        if (chosen == null) {
            // 全部线路拉取失败：用默认线路进主界面（内存生效，不持久化坏线）
            chosen = LineConfig.DEFAULT_LINKS.get(0);
            NetManager.useBaseUrl(chosen);
        } else {
            LineConfig.setCurrent(chosen);
        }

        if (isFinishing() || isDestroyed()) return;
        runOnUiThread(() -> {
            if (isFinishing() || isDestroyed()) return;
            startActivity(new Intent(this, MainActivity.class));
            finish();
        });
    }

    private SystemInfo fetchSystemInfo(String base) {
        try {
            Map<String, Object> body = new HashMap<>();
            body.put("device_id", DeviceUtil.deviceId());
            body.put("clipboard_text", "");
            body.put("app_code", "clean");
            body.put("channel_code", "");
            body.put("domain", base);
            body.put("ad_method", "none");
            body.put("device_info", DeviceUtil.deviceInfo());
            body.put("device_information", DeviceUtil.deviceInfo());

            Call<ApiResponse<SystemInfo>> call = NetManager.api().systemInfo(body);
            retrofit2.Response<ApiResponse<SystemInfo>> resp = call.execute();
            if (resp.isSuccessful() && resp.body() != null && resp.body().data != null) {
                SystemInfo info = resp.body().data;
                Prefs.put(Prefs.SYSTEM_INFO, gson.toJson(info));
                if (info.cdn_header != null) {
                    Prefs.put(Prefs.CDN_HEADER, info.cdn_header);
                }
                if (info.token != null && info.token.token != null) {
                    Prefs.put(Prefs.USER_TOKEN, info.token.token);
                }
                return info;
            }
        } catch (Exception e) {
            // try next line
            e.printStackTrace();
        }
        return null;
    }

    private String pickLine() {
        List<String> lines = LineConfig.all();
        for (String base : lines) {
            try {
                setStatus("检测: " + base);
                // ping relative path xl/p：仅 2xx 视为可用 —— 4xx/静态页可能是被劫持的坏线，
                // 收紧判定避免选中劫持页并持久化导致每次启动先撞死线
                Request req = new Request.Builder()
                        .url(base + "xl/p")
                        .get()
                        .header("User-Agent", "CleanPlayer/1.0")
                        .build();
                try (Response resp = NetManager.probeClient().newCall(req).execute()) {
                    if (resp.isSuccessful()) {
                        return base;
                    }
                }
                // fallback: host root
                Request root = new Request.Builder().url(base).get().build();
                try (Response resp = NetManager.probeClient().newCall(root).execute()) {
                    if (resp.isSuccessful()) {
                        return base;
                    }
                }
            } catch (Exception ignored) {
            }
        }
        return null;
    }

    private void setStatus(String s) {
        runOnUiThread(() -> {
            if (tvStatus != null) tvStatus.setText(s);
        });
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        io.shutdownNow();
    }
}
