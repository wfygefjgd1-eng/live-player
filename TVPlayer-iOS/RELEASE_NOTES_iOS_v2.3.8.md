# TV go iOS v2.3.8

## 修复

- **网速显示实时性**：左上角网速徽标直接观察播放引擎（@ObservedObject），0.5s 采样点即时刷新；AVPlayer 内核改为累计字节差分计算瞬时速度，替代全程累计均值（均值在直播波动时不变化导致显示滞后）；断网归零从 3s 缩短到 1.5s。
- **切换频道速度残留**：切台/换内核时复位网速与差分状态，避免转圈下残留旧频道速度、差分测速吃着旧流的累计字节而长期失真。
- **音频中断处理**：来电/闹钟开始即同步暂停状态；结束后按系统建议自动恢复；拒接来电保持暂停态与"恢复播放"按钮一致。
- **诊断浮层**：修复 refreshDiagnostics 死分支；实现「异常时即使关闭也短暂提示」的语义。
- **快速切台转圈**：修复旧频道转圈延迟任务无守卫、可能提前关掉新台"切换中"反馈的问题。
- **M3U 解析加固**：strip UTF-8 BOM、URL 合法性校验（放行 http/https/rtmp/rtsp 等播放管线支持的协议）、支持 #EXTGRP 分组、限制超大源。
- **Channel 契约**：hash/== 统一只看 key，满足 Hashable 一致性。
- **并发安全**：修复 MPVPlaybackEngine 快照复位缺锁的 data race；修复 AVPlayer→mpv 回退后残留的空转采样任务。

## 稳定性与兼容

- **保留 scene manifest**：确认无 UIApplicationSceneManifest 时传统 AppDelegate 生命周期不创建 UIWindowScene → 启动黑屏，此前的清理已撤销（Info.plist 与 project.yml 均已保留）。
- **保持 ATS 全局放行 HTTP**：URLSession 拉取 m3u 播放列表不受 NSAllowsArbitraryLoadsForMedia 媒体豁免覆盖，收窄会导致自定义 http 源加载失败（自签侧载场景可接受）。
- release.sh：校验 tag 必须以 -ios 结尾（对齐 CI 触发规则）、tag 已存在时报错。

## 清理

- 删除死代码：ChannelValidator / ChannelValidationView / ValidationStorage / refreshChannelsFromRemote / retryLoadWithBackoff / 静音检测链路。

---

**安装方式：** 下载 TVPlayer.ipa → 用 Sideloadly/AltStore 侧载

**系统要求：** iOS 16.0+

**注意：** 免费 Apple ID 签名每 7 天需重签一次