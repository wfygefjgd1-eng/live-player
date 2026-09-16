package com.clean.player.ui;

import android.net.Uri;
import android.os.Bundle;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;

import com.clean.player.R;
import com.clean.player.util.Prefs;
import com.google.android.exoplayer2.AudioAttributes;
import com.google.android.exoplayer2.C;
import com.google.android.exoplayer2.ExoPlayer;
import com.google.android.exoplayer2.MediaItem;
import com.google.android.exoplayer2.Player;
import com.google.android.exoplayer2.source.DefaultMediaSourceFactory;
import com.google.android.exoplayer2.ui.PlayerView;
import com.google.android.exoplayer2.upstream.DefaultHttpDataSource;

import java.util.HashMap;
import java.util.Map;

public class PlayerActivity extends AppCompatActivity {
    public static final String EXTRA_TITLE = "title";
    public static final String EXTRA_URL = "url";
    public static final String EXTRA_ID = "id";
    private static final int MAX_AUTO_RETRY = 2;

    private ExoPlayer player;
    private PlayerView playerView;
    private String playUrl;
    private int errorRetries = 0;

    private final Player.Listener playerListener = new Player.Listener() {
        @Override
        public void onPlayerError(@NonNull com.google.android.exoplayer2.PlaybackException error) {
            if (player == null) return;
            // 失效地址自动重试几次，仍失败则明确提示而不是黑屏
            if (errorRetries < MAX_AUTO_RETRY) {
                errorRetries++;
                player.prepare();
                player.play();
            } else {
                Toast.makeText(PlayerActivity.this,
                        "播放失败：" + (error.getMessage() != null ? error.getMessage() : "源地址不可用"),
                        Toast.LENGTH_LONG).show();
            }
        }
    };

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_player);
        TextView tvTitle = findViewById(R.id.tvTitle);
        playerView = findViewById(R.id.playerView);

        String title = getIntent().getStringExtra(EXTRA_TITLE);
        playUrl = getIntent().getStringExtra(EXTRA_URL);
        tvTitle.setText(title == null ? "" : title);

        if (playUrl == null || playUrl.isEmpty()) {
            Toast.makeText(this, "无可播放地址", Toast.LENGTH_SHORT).show();
            finish();
        }
    }

    @Override
    protected void onStart() {
        super.onStart();
        if (playUrl == null || playUrl.isEmpty()) return;
        // onStop 释放后回到前台重建播放器
        if (player == null) {
            buildPlayer();
            player.setMediaItem(MediaItem.fromUri(Uri.parse(playUrl)));
            player.prepare();
            player.play();
        }
    }

    private void buildPlayer() {
        Map<String, String> headers = new HashMap<>();
        String cdn = Prefs.get(Prefs.CDN_HEADER);
        if (cdn != null && !cdn.isEmpty()) {
            // original app sets referer from systemBean.cdn_header
            headers.put("Referer", cdn);
        }
        headers.put("User-Agent", "Mozilla/5.0 CleanPlayer/1.0");

        DefaultHttpDataSource.Factory httpFactory = new DefaultHttpDataSource.Factory()
                .setDefaultRequestProperties(headers)
                .setAllowCrossProtocolRedirects(true);

        player = new ExoPlayer.Builder(this)
                .setMediaSourceFactory(new DefaultMediaSourceFactory(httpFactory))
                .build();
        // 申请音频焦点（不混音）+ 拔耳机自动暂停
        player.setAudioAttributes(
                new AudioAttributes.Builder()
                        .setUsage(C.USAGE_MEDIA)
                        .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                        .build(),
                /* handleAudioFocus= */ true);
        player.setHandleAudioBecomingNoisy(true);
        player.addListener(playerListener);
        playerView.setPlayer(player);
        errorRetries = 0;
    }

    @Override
    protected void onStop() {
        super.onStop();
        // 后台释放解码器与连接，回前台由 onStart 重建
        if (player != null) {
            player.release();
            player = null;
            playerView.setPlayer(null);
        }
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (player != null) {
            player.release();
            player = null;
            playerView.setPlayer(null);
        }
    }
}
