# TV go iOS 2.2.2

彻底移除 AVPlayer 兜底，仅使用 libmpv 内核；修复换源后无法播放的状态污染 bug。

## 修复

- **移除 AVPlayer 兜底，改为 mpv 专用内核（关键）**
  - 根因：`PlayerEngine` 的 `hasFallenBackToAVPlayer` 标志一旦因某个源 mpv 起播失败被置为 `true`，就再也不会被重置。之后即使切回默认源，mpv 任何起波折都会因 `hasFallenBackToAVPlayer` 仍为 `true` 而跳过回退、直接 `onError` → 连续换线/换台失败 → 完全无画面。
  - 这解释了「重置能播、添加新源后就播不了、切回默认源依旧播不了」的现象。
  - 修复：彻底移除 AVPlayer 后端、`playWithAVPlayer`、`hasFallenBackToAVPlayer` 及全部 AVPlayer 观察器/诊断逻辑。`PlayerEngine` 现在只有 mpv 一条路径，起播失败直接触发换线，不再有「回退一次」的不可恢复状态。
  - 同时移除 `WindowVideoSurface` 中的 `PlayerSurfaceView`（AVPlayerLayer）、`AVPlayerViewController`、`setPlayer`、`showAVPlayer`，只保留 mpv 的 `MPVMetalHostView`。

- **修复 mpv 切源后有声音无画面**
  - `play()` 中在 `loadfile` 前显式设 `vid=auto`，确保后台切前台残留的 `vid=no` 被清除。

- **移除 video-sync=display-resample**
  - 官方 MPVKit Demo 未使用该选项，对直播源时钟有副作用。

## 说明

- v2.2.1 的 MetalLayer 黑屏修复继续保留。
- 播放内核、依赖、构建方式与 v2.2 一致（libmpv / MPVKit 1.0.0 / Swift Package Manager）。

仅支持 iOS 16 及以上的 ARM64 设备。
