# TV go Android ARM64 2.0.2

- **默认源统一对齐**：默认源从指向 upstream 仓库（wfygefjgd）改为指向 origin 仓库（wfygefjgd1-eng）的今日精选源 `validated-channels-2026-08-08.m3u`，与 iOS 完全一致（此前两个仓库的同名文件内容不同，Android 用户拉到的可能是旧数据）。
- 预置源列表同步更新：4 个精选源镜像（jsDelivr / Fastly / Pages / raw）均指向 origin 仓库。
- 保留 OSD 提示跟随声画出画才消失（v2.0.1 引入），以及现有 ExoPlayer 播放、频道管理、手势、遥控器操作和自动换线能力。
- 本次 GitHub 发布包仅面向 ARM64 Android 手机、电视和盒子。
