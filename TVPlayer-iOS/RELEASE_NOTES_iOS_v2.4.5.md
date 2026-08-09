# TV go iOS v2.4.5

## 修复

- **切台转圈时的加载反馈更真实**：此前 v2.4.4 的缓冲增长估速依赖 accessLog 的流码率，但 iOS 起播缓冲阶段 accessLog 无实时事件，码率为 0，估速仍失效，转圈只显示「加载中」。本次：
  - **码率来源补强**：缓冲增长估速改用 `AVAssetTrack.estimatedDataRate`（AVPlayer 解析出媒体轨道后即有，不依赖 accessLog）作为码率兜底，让转圈时尽可能算出真实下载 KB/s。
  - **缓冲秒数兜底**：即使码率仍不可得，转圈时也显示「缓冲 X.Xs」（缓冲秒数在增长 = 网络确实在下载），而不是静止的「加载中」——用户能看到切台后源在努力联网、缓冲在推进。
  - 出画后仍由 AVPlayer 实际字节速度接管，显示实时网速。

> 说明：iOS 系统播放器（AVPlayer）在起播缓冲阶段不暴露实时的「下载字节」数据（accessLog 事件要等出画/访问段结束才有）。因此转圈阶段能显示的是「估算下载速度」或「缓冲秒数」——这是平台能给出的最真实反馈；出画后即为精确的实时网速。

## 验证

- macOS runner（XcodeGen + xcodebuild archive，Release，CODE_SIGNING=NO）构建通过
- 切台转圈时显示「缓冲 X.Xs」（缓冲在增长）或估算下载速度；出画后显示实时网速

---

**安装方式：** 下载 TVPlayer.ipa → 用 Sideloadly/AltStore 侧载

**系统要求：** iOS 16.0+

**注意：** 免费 Apple ID 签名每 7 天需重签一次