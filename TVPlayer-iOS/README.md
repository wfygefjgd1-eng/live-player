# TVPlayer iOS 2.2 正式版

自签侧载版本的 **TVPlayer 正式版** 直播播放器。

## 版本

- **Marketing Version:** 2.2
- **Build:** 2200
- **显示名:** TV go

## 核心变更 (v2.2)

- 播放内核从 MobileVLCKit 3.x 升级为 **libmpv（MPVKit）**，解码兼容性大幅增强：
  - AVS2/AVS3、HEVC 10bit 50fps、DVB TS 混合流等 VLC 3.x 无法解码的源可稳定播放。
  - Metal 渲染路径（gpu-next + Vulkan/MoltenVK），支持 10bit/HDR，画面更准确。
- 保留多信号融合的起播检测、自动换线、自动换台与黑名单机制。
- 后台只播音频、回前台自动恢复画面；mpv 失败时自动回退 AVPlayer（仅一次）。
- 构建从 CocoaPods 迁移到 Swift Package Manager，CI 直接编译，无需 pod install。

## 功能

- 横屏全屏直播
- 自定义 M3U / M3U8 源
- 多线路自动切换
- 收藏 / 隐藏线路
- 后台音频、数字键与手势操作
- 失败线路黑名单管理

## 发布

```bash
git tag v2.2-ios
git push origin v2.2-ios
```

GitHub Actions 会构建 IPA 并创建 Release。
