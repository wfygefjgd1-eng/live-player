# TVPlayer iOS v1.9.10

- 修复自定义高码率 1080i 来源“声音正常、画面像幻灯片”的问题：视频层仅在播放器实例真正变化时重绑，避免 SwiftUI 状态刷新反复重置 AVPlayerLayer。
- 使用 AVPlayerLayer 的 `isReadyForDisplay` 上报真实首帧，避免仅凭音频时钟推进就误判视频已经稳定出画。
- 针对 `live.264788.xyz` 的 10 秒长分片线路使用稳定的两段缓冲，并移除多余的强制 `rate = 1.0`，让 AVPlayer 的自动防卡顿策略真正生效。
