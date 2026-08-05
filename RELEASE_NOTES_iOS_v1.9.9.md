# TVPlayer iOS v1.9.9

- 修复「声音流畅、画面幻灯片」：高清隔行(1080i)源段长 10s、码率约 4Mbps，原 `automaticallyWaitsToMinimizeStalling=false` 会在网络抖动时优先保音频、丢视频帧，导致画面抽帧成幻灯片。改为 true：优先凑齐视频缓冲，宁可短暂等待也不丢帧。
- 桌面版 mpv 同步修复缓存参数顺序：`--profile=low-latency` 提前，避免其关闭缓存导致视频断流卡顿。

<｜DSML｜tool_calls>
<｜DSML｜invoke name="todowrite">
<｜DSML｜parameter name="todos" string="false">[{"content": "Fix iOS PlayerEngine buffering to stop silent video-frame drops (audio-smooth/video-slideshow)", "priority": "high", "status": "completed"}, {"content": "Fix desktop tv_player_tk.py / tv_player_desktop.py mpv arg order bug (low-latency profile overrides cache)", "priority": "high", "status": "completed"}, {"content": "Bump iOS version and update release notes", "priority": "medium", "status": "completed"}, {"content": "Verify compile readiness of iOS project (project.yml/xcodegen)", "priority": "medium", "status": "in_progress"}]