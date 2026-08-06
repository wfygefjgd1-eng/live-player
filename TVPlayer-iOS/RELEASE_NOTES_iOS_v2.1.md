# TV go iOS 2.1

- 切换播放内核：弃用运行不稳定的 KSPlayer，改用 **MobileVLCKit（libvlc）** 作为主内核，AVPlayer 作为自动兜底。
  - VLC 的 demuxer/解码器/音画时钟历经多年调优，能稳定播放 AVPlayer/KSPlayer 难以胜任的格式（隔行 1080i、非标 HLS、各种 codec）。
  - VideoToolbox 硬解 + yadif 反隔行（通过 libvlc 选项启用，规避 KSPlayer 的 yadif_videotoolbox 崩溃）。
- 修复 v2.0 之前「VLCKit 不稳定」的根因：libvlc 的统计/轨道/时间查询原在主线程同步轮询，会阻塞在 HLS demux 锁上导致 UI 冻结。现统一在后台队列采样，主线程只读快照。
- VLC 起播超过 25 秒或明确失败时，自动回退 AVPlayer（仅一次），保证可用性。
- 体积增大（嵌入 VLCKit），换取更强的格式兼容与播放稳定性。
- 移除 KSPlayer 依赖与相关代码；保留原有的多信号融合起播/卡顿/换线逻辑作为 AVPlayer 兜底路径。

仅支持 iOS 16 及以上的 ARM64 设备。
