# TV go iOS 2.2.1

紧急修复：v2.2 更换播放内核为 libmpv（MPVKit）后视频无法播放（黑屏）。

## 修复

- **修复黑屏 / 视频播放不了（关键）**
  - 根因：MoltenVK 在强制完成 presentation 时会把 `CAMetalLayer.drawableSize` 临时置为 1×1（mpv 已知问题，见 mpv PR #13651）。项目使用原生 `CAMetalLayer`，未拦截该写入，导致画面被渲染到 1 像素的表面 → 黑屏。
  - 由于 mpv 已报告「播放成功」，AVPlayer 兜底永远不会触发，表现为所有频道都播不了。
  - 修复：新增 `MetalLayer` 子类，在 setter 中拒绝 1×1 的写入（与官方 MPVKit Demo-iOS 的 workaround 一致）。`MPVMetalHostView` 改用该子类。
  - 参考官方实现：[MPVKit/Demo/Demo-iOS/Demo-iOS/Player/Metal/MetalLayer.swift](https://github.com/mpvkit/MPVKit/blob/main/Demo/Demo-iOS/Demo-iOS/Player/Metal/MetalLayer.swift)

- **修复设置页「版本说明」信息过期**
  - 仍显示 v2.0 的「使用 AVPlayerViewController / 不再内置 VLC」，与当前 libmpv 内核不符。已更新为 v2.2 的实际内核说明。

## 说明

- 播放内核、依赖、构建方式与 v2.2 一致（libmpv / MPVKit 1.0.0 / Swift Package Manager）。
- 后台只播音频、回前台自动恢复画面的逻辑保持不变；MetalLayer 修复后回前台不再黑屏。

仅支持 iOS 16 及以上的 ARM64 设备。
