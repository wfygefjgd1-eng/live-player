# TVPlayer iOS v2.3.8 更新说明

## 🎉 v2.3.8 更新说明

### 📡 网速显示实时性
- 左上角网速徽标改为直接观察播放引擎（@ObservedObject），0.5s 采样点即时刷新，不再依赖界面偶然重绘
- AVPlayer 内核改为「累计字节差分」计算瞬时下载速度，替代原来的全程累计均值（均值在直播波动时不变化，导致显示滞后）
- 网速归零超时从 3s 缩短到 1.5s，断网后更快归零

### 🐛 Bug 修复
- 修复音频中断（来电/闹钟）后不自动恢复播放：注册 AVAudioSession.interruptionNotification，按系统建议恢复
- 修复 refreshDiagnostics 死分支（if activeBackend == .mpv 判断缩进/逻辑混乱）
- 实现诊断浮层「异常时即使关闭也短暂提示」的语义（shouldShowDiagnostics 此前永远为 false）
- M3U 解析：strip UTF-8 BOM、URL 合法性校验、支持 #EXTGRP 分组、限制超大源
- Channel hash/== 契约统一（只看 key），满足 Hashable 一致性

### 🔒 合规与安全
- ATS 从 NSAllowsArbitraryLoads 收窄为 NSAllowsArbitraryLoadsForMedia（仅媒体放行 HTTP）
- release.sh 去掉 git push --force，避免覆盖线上 tag
- 清理 Info.plist 冗余 scene manifest（AppDelegate 已编程注册）

### 🧹 代码清理
- 删除死代码：ChannelValidator / ChannelValidationView / ValidationStorage / refreshChannelsFromRemote / retryLoadWithBackoff / 静音检测链路 / 若干无调用点方法

---

**安装方式：** 下载 TVPlayer.ipa → 用 Sideloadly/AltStore 侧载

**系统要求：** iOS 16.0+

**注意：** 免费 Apple ID 签名每 7 天需重签一次
