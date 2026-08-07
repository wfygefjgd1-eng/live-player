# TVPlayer iOS 2.3.8

自签侧载版本的 **TVPlayer 正式版** 直播播放器。

## 版本

- **Marketing Version:** 2.3.8
- **Build:** 2308
- **显示名:** TV go

## 核心变更 (v2.3.8)

- 网速显示实时性修复：左上角网速徽标直接观察播放引擎，AVPlayer 内核改为累计字节差分计算瞬时速度，断网更快归零
- 音频中断（来电/闹钟）后自动恢复播放
- 修复 refreshDiagnostics 死分支，实现诊断浮层「异常时短暂提示」
- M3U 解析加固：BOM strip、URL 校验、#EXTGRP 分组、超大源限制
- ATS 收窄为 NSAllowsArbitraryLoadsForMedia、清理死代码与版本统一

## 功能

- 横屏全屏直播
- 自定义 M3U / M3U8 源
- 多线路自动切换
- 收藏 / 隐藏线路
- 后台音频、数字键与手势操作
- 失败线路黑名单管理

## 发布

```bash
git tag v2.3.8-ios
git push origin v2.3.8-ios
```

GitHub Actions 会构建 IPA 并创建 Release。
