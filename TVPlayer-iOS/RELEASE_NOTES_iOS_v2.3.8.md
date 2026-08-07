# TV go iOS v2.3.8

## 修复

- **网速显示实时性**：左上角网速徽标直接观察播放引擎（@ObservedObject），0.5s 采样点即时刷新；AVPlayer 内核改为累计字节差分计算瞬时速度，替代全程累计均值（均值在直播波动时不变化导致显示滞后）；断网归零从 3s 缩短到 1.5s。
- **音频中断恢复**：来电/闹钟结束后自动恢复播放（注册 AVAudioSession.interruptionNotification，按系统建议恢复）。
- **诊断浮层**：修复 refreshDiagnostics 死分支；实现「异常时即使关闭也短暂提示」的语义。
- **M3U 解析加固**：strip UTF-8 BOM、URL 合法性校验、支持 #EXTGRP 分组、限制超大源。
- **Channel 契约**：hash/== 统一只看 key，满足 Hashable 一致性。

## 合规

- ATS 收窄为 NSAllowsArbitraryLoadsForMedia（仅媒体放行 HTTP）。
- release.sh 去掉 git push --force。
- 清理 Info.plist 冗余 scene manifest。

## 清理

- 删除死代码：ChannelValidator / ChannelValidationView / ValidationStorage / refreshChannelsFromRemote / retryLoadWithBackoff / 静音检测链路。

---

**安装方式：** 下载 TVPlayer.ipa → 用 Sideloadly/AltStore 侧载

**系统要求：** iOS 16.0+

**注意：** 免费 Apple ID 签名每 7 天需重签一次
