[app]
title = TVPlayer
package.name = tvplayer
package.domain = org.tvplayer
source.dir = .
# Kivy 版只需要 main.py + android_main.py（源均来自网络，无内置 JSON 依赖）
source.include_exts = py,png,jpg,kv,atlas
source.include_patterns = android_main.py,main.py
# 排除无关目录，避免把 iOS/Android 工程与数 MB 的频道 JSON 打进 APK
source.exclude_dirs = .git,.github,TVPlayer-iOS,TVPlayer_iOS,__pycache__,android-native,build-artifacts,clean-client,iptv-mirrors,release,scripts
source.exclude_patterns = tv_player.py,tv_player_desktop.py,tv_player_mpv.py,tv_player_pro.py,tv_player_tk.py,channel_manager.py,channel_rules_manager.py,verify_optimizations.py,PATCH_RULES_MANAGER.py,channel_rules.json,iptv-sources.json
version = 1.0.0
requirements = python3,kivy==2.2.1,ffpyplayer
orientation = landscape
fullscreen = 1

# Android 5.0 (API 21) ~ Android 13 (API 33)
android.api = 33
android.minapi = 21
android.ndk = 25b
android.sdk = 33
android.archs = arm64-v8a,armeabi-v7a
android.permissions = INTERNET,ACCESS_NETWORK_STATE,WRITE_SETTINGS
android.accept_sdk_license = True
android.allow_backup = True
android.entrypoint = org.kivy.android.PythonActivity
android.presplash_color = #000000

# entry point
# buildozer uses main.py by default; we rename via p4a bootstrap
# Keep android_main.py and copy as main.py during build if needed

[buildozer]
log_level = 2
warn_on_root = 1
