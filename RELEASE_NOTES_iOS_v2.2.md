# TV go iOS 2.2

- 播放内核升级：弃用 MobileVLCKit 3.x，改用 **libmpv（MPVKit 1.0.0，mpv v0.41.0 + FFmpeg n8.1.2）** 作为主内核，AVPlayer 作为自动兜底。
  - 兼容性全面超越旧 VLC 内核：AVS2/AVS3、HEVC 10bit 50fps、DVB TS 混合流、中途换编码等 VLC 3.x（内置 FFmpeg 老旧）无法解码的源现在都能稳定播放。
  - 渲染改为 **Metal 路径**（`vo=gpu-next` + Vulkan/MoltenVK），完整支持 10bit/HDR，画面比旧 OpenGL ES 路径更准确。
  - VideoToolbox 硬解 + 网络断线自动重连 + 播放缓存，直播稳定性更强。
- 保留 v2.1 的稳定性架构：mpv 的统计/轨道/时间查询仍在后台队列采样，主线程只读快照，不会阻塞 demux 导致 UI 冻结。
- mpv 起播超过 25 秒或明确失败时，自动回退 AVPlayer（仅一次），保证可用性。
- 后台播放只保留音频（自动卸下视频输出），回到前台自动恢复画面，避免黑屏。
- 构建方式从 CocoaPods（MobileVLCKit）迁移到 Swift Package Manager（MPVKit），CI 不再依赖 pod install。
- 安装包体积较 v2.1 明显减小（移除 VLCKit）。

仅支持 iOS 16 及以上的 ARM64 设备。
