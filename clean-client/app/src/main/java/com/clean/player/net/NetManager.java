package com.clean.player.net;

import com.clean.player.BuildConfig;
import com.clean.player.api.ApiService;

import java.util.concurrent.TimeUnit;

import okhttp3.OkHttpClient;
import okhttp3.logging.HttpLoggingInterceptor;
import retrofit2.Retrofit;
import retrofit2.converter.gson.GsonConverterFactory;

public final class NetManager {
    private static volatile OkHttpClient client;
    private static volatile OkHttpClient probeClient;
    private static volatile ApiService api;

    private NetManager() {}

    public static synchronized void init() {
        if (client == null) {
            OkHttpClient.Builder b = new OkHttpClient.Builder()
                    .connectTimeout(15, TimeUnit.SECONDS)
                    .readTimeout(30, TimeUnit.SECONDS)
                    .writeTimeout(30, TimeUnit.SECONDS)
                    .addInterceptor(new HeaderInterceptor())
                    .retryOnConnectionFailure(true);
            if (BuildConfig.DEBUG) {
                HttpLoggingInterceptor log = new HttpLoggingInterceptor();
                log.setLevel(HttpLoggingInterceptor.Level.BASIC);
                b.addInterceptor(log);
            }
            client = b.build();

            // Short-timeout client for line probing; shares interceptors/pool.
            probeClient = client.newBuilder()
                    .connectTimeout(3, TimeUnit.SECONDS)
                    .readTimeout(3, TimeUnit.SECONDS)
                    .callTimeout(5, TimeUnit.SECONDS)
                    .build();
        }
        rebuild();
    }

    public static synchronized void rebuild() {
        Retrofit retrofit = new Retrofit.Builder()
                .baseUrl(LineConfig.current())
                .client(client)
                .addConverterFactory(GsonConverterFactory.create())
                .build();
        api = retrofit.create(ApiService.class);
    }

    public static ApiService api() {
        if (api == null) {
            init();
        }
        return api;
    }

    public static OkHttpClient client() {
        if (client == null) {
            init();
        }
        return client;
    }

    public static OkHttpClient probeClient() {
        if (probeClient == null) {
            init();
        }
        return probeClient;
    }
}
