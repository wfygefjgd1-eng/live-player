# TV go iOS 2.0

- 使用系统 AVPlayerViewController 作为轻量渲染层，更接近 Safari/系统播放器路径。
- 移除体积较大且运行不稳定的 VLCKit 依赖，安装包恢复轻量体积。
- 保留 AVPlayer 起播、缓冲、自动换线和实时诊断能力。
- 每次进入或重新激活 App 时，都会重新加载当前选中的来源。
- 安装后的 App 名称改为“TV go”，移除“正式版”字样。

仅支持 iOS 16 及以上的 ARM64 设备。
