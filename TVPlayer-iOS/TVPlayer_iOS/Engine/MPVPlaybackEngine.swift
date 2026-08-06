import UIKit
import QuartzCore
import Metal
import AVFAudio
import Libmpv

/// mpv / libmpv 直播内核（MPVKit 预编译库）。AVPlayer 仅在 mpv 无法打开流时由 PlayerEngine 兜底。
///
/// 稳定性要点：与 VLC 内核同构——所有 mpv 统计/轨道/时间查询都在后台队列采样，
/// 主线程只读快照，绝不触碰可能阻塞 demux 的调用；事件（起播/结束/错误）由
/// mpv 唤醒回调驱动，转发回主线程。
///
/// 渲染路径：Metal（vo=gpu-next + gpu-api=vulkan + gpu-context=moltenvk）。
/// 相比旧 VLC 内核的 OpenGL ES，Metal 路径完整支持 10bit/HDR 与硬解回退。
/// 画面宿主是 CAMetalLayer（MPVMetalHostView），mpv 通过 --wid 直接渲染进去。
final class MPVPlaybackEngine {
    struct DiagnosticsSample {
        var observedBitrate: Double = 0
        var averageVideoBitrate: Double = 0
        var outputFrameRate: Double = 0
        var nominalFrameRate: Double = 0
        var droppedFrames: Int = 0
        var droppedFramesPerSecond: Double = 0
        var width: Int = 0
        var height: Int = 0
        var playbackClockSeconds: TimeInterval = 0
        var stateText: String = "未开始"
        var waitingReason: String = "无"
        var hasVideoOutput = false
    }

    var onPlaying: (() -> Void)?
    var onError: ((String) -> Void)?
    var onStateChanged: ((String) -> Void)?

    private var mpv: OpaquePointer?
    private var activeURL: URL?
    private var stoppedByOwner = true
    private var reportedPlaying = false

    // 事件循环：mpv 只允许单线程 wait_event，唤醒回调也只在此队列排队
    private let eventQueue = DispatchQueue(label: "tvplayer.mpv.events", qos: .userInitiated)

    // 后台采样：避免在主线程触碰可能阻塞 demux 锁的 mpv 调用
    private let samplerQueue = DispatchQueue(label: "tvplayer.mpv.sampler", qos: .utility)
    private let snapshotLock = NSLock()
    private var samplerCancelled = true
    private var lastSnapshot = DiagnosticsSample()
    private var cachedAudioTrackCount = 0

    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    init() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.enterBackground()
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.enterForeground()
        }
    }

    deinit {
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        samplerCancelled = true
        if let mpv {
            mpv_terminate_destroy(mpv)
            self.mpv = nil
        }
    }

    // MARK: - Public API（与旧 VLCPlaybackEngine 保持同一形状）

    func play(url: URL, drawable: UIView, volume: Float) {
        stoppedByOwner = true
        command("stop", args: [])

        reportedPlaying = false
        samplerCancelled = true
        lastSnapshot = DiagnosticsSample()
        cachedAudioTrackCount = 0
        activeURL = url

        guard let host = drawable as? MPVMetalHostView,
              ensureMpvInitialized(layer: host.metalLayer) else {
            onError?("mpv 初始化失败")
            return
        }

        setVolumeProperty(volume)
        stoppedByOwner = false
        command("loadfile", args: [url.absoluteString, "replace"])
        onStateChanged?("正在打开")

        // 开启后台采样循环
        samplerCancelled = false
        scheduleNextSample()
    }

    func pause() {
        setFlagProperty("pause", true)
    }

    func resume() {
        try? AVAudioSession.sharedInstance().setActive(true)
        setFlagProperty("pause", false)
    }

    func stop() {
        stoppedByOwner = true
        reportedPlaying = false
        samplerCancelled = true
        command("stop", args: [])
        activeURL = nil
        cachedAudioTrackCount = 0
        lastSnapshot = DiagnosticsSample()
    }

    var isPlaying: Bool {
        !getFlagProperty("pause") && !getFlagProperty("core-idle")
    }

    var volume: Float {
        get { Float(getInt64Property("volume")) / 100 }
        set { setVolumeProperty(newValue) }
    }

    var hasAudioTrack: Bool {
        cachedAudioTrackCount > 0
    }

    /// 主线程调用：只读后台采样的快照，绝不触碰 mpv。
    func diagnosticsSample() -> DiagnosticsSample {
        snapshotLock.lock()
        let snap = lastSnapshot
        snapshotLock.unlock()
        return snap
    }

    // MARK: - 初始化

    /// 首次 play 时惰性创建 mpv：wid 需要先拿到 CAMetalLayer。
    private func ensureMpvInitialized(layer: CAMetalLayer) -> Bool {
        if mpv != nil { return true }

        guard let ctx = mpv_create() else { return false }
        mpv = ctx

        #if DEBUG
        checkError(mpv_request_log_messages(ctx, "debug"))
        #else
        checkError(mpv_request_log_messages(ctx, "warn"))
        #endif

        // 渲染：Metal 路径（MoltenVK 转 Vulkan，libplacebo 渲染）
        checkError(mpv_set_option_string(ctx, "vo", "gpu-next"))
        checkError(mpv_set_option_string(ctx, "gpu-api", "vulkan"))
        checkError(mpv_set_option_string(ctx, "gpu-context", "moltenvk"))
        checkError(mpv_set_option_string(ctx, "hwdec", "videotoolbox"))
        var layerPtr = Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(layer).toOpaque())))
        checkError(mpv_set_option(ctx, "wid", MPV_FORMAT_INT64, &layerPtr))

        // 直播稳定：网络重连 + 播放缓存
        checkError(mpv_set_option_string(ctx, "cache", "yes"))
        checkError(mpv_set_option_string(ctx, "cache-secs", "10"))
        checkError(mpv_set_option_string(ctx, "stream-lavf-o",
            "reconnect=1:reconnect_streamed=1:reconnect_on_network_error=1"))
        checkError(mpv_set_option_string(ctx, "user-agent",
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"))

        // 广播源 25/50fps 到 60Hz 屏的平滑播放；不叠加插帧
        checkError(mpv_set_option_string(ctx, "video-sync", "display-resample"))

        // 电视场景不需要字幕/OSD
        checkError(mpv_set_option_string(ctx, "sid", "no"))
        checkError(mpv_set_option_string(ctx, "osd-level", "0"))

        checkError(mpv_initialize(ctx))

        mpv_set_wakeup_callback(ctx, { raw in
            let engine = unsafeBitCast(raw, to: MPVPlaybackEngine.self)
            engine.eventQueue.async { engine.drainEvents() }
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))

        return true
    }

    private func enterBackground() {
        guard mpv != nil, !stoppedByOwner else { return }
        // 保留后台音频，先卸掉视频输出，避免回前台黑屏
        checkError(mpv_set_option_string(mpv, "vid", "no"))
    }

    private func enterForeground() {
        guard mpv != nil else { return }
        checkError(mpv_set_option_string(mpv, "vid", "auto"))
    }

    // MARK: - 事件循环

    private func drainEvents() {
        guard let ctx = mpv else { return }
        while mpv != nil {
            guard let event = mpv_wait_event(ctx, 0) else { continue }
            if event.pointee.event_id == MPV_EVENT_NONE { break }
            handleEvent(event)
        }
    }

    private func handleEvent(_ event: UnsafePointer<mpv_event>) {
        switch event.pointee.event_id {
        case MPV_EVENT_START_FILE:
            guard !stoppedByOwner else { return }
            notifyState("正在打开")
        case MPV_EVENT_VIDEO_RECONFIG:
            // 视频参数就绪 = 解码器已出第一帧
            reportPlayingIfNeeded()
        case MPV_EVENT_END_FILE:
            let end = UnsafePointer<mpv_event_end_file>(OpaquePointer(event.pointee.data))
            if end?.pointee.reason == MPV_END_FILE_REASON_ERROR {
                guard !stoppedByOwner else { return }
                notifyError("mpv 播放器报告解码或媒体错误")
            }
        case MPV_EVENT_SHUTDOWN:
            mpv = nil
        case MPV_EVENT_LOG_MESSAGE:
            #if DEBUG
            if let msg = UnsafePointer<mpv_event_log_message>(OpaquePointer(event.pointee.data)) {
                let text = msg.pointee.text.flatMap { String(cString: $0) } ?? ""
                print("[mpv] \(text)", terminator: "")
            }
            #endif
        default:
            break
        }
    }

    private func reportPlayingIfNeeded() {
        guard !reportedPlaying else { return }
        reportedPlaying = true
        DispatchQueue.main.async { [weak self] in
            self?.onPlaying?()
        }
    }

    private func notifyError(_ reason: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?(reason)
        }
    }

    private func notifyState(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onStateChanged?(text)
        }
    }

    // MARK: - 后台采样

    private func scheduleNextSample() {
        samplerQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !self.samplerCancelled else { return }
            self.collectSampleOnBackground()
            self.scheduleNextSample()
        }
    }

    /// 在后台队列采集 mpv 状态。mpv 的属性查询线程安全，但可能阻塞在 demux 锁上——
    /// 不在主线程做，最多让采样慢一拍，不会冻 UI。
    private func collectSampleOnBackground() {
        guard let ctx = mpv, activeURL != nil else { return }

        let timePos = getDoubleProperty("time-pos")
        let demuxBitrate = getInt64Property("bitrate")
        let videoBitrate = getInt64Property("video-bitrate")
        let cacheSpeed = getInt64Property("cache-speed")
        let width = Int(getInt64Property("video-params/w"))
        let height = Int(getInt64Property("video-params/h"))
        let outputFPS = getDoubleProperty("estimated-vf-fps")
        let nominalFPS = getDoubleProperty("video-params/fps")
        let dropped = Int(getInt64Property("drop-frame-count"))
            + Int(getInt64Property("vo-drop-frame-count"))
        let coreIdle = getFlagProperty("core-idle")
        let pausedForCache = getFlagProperty("paused-for-cache")
        let paused = getFlagProperty("pause")

        let hasVideo = width > 0 && height > 0
        let stateText: String
        if paused { stateText = "暂停" }
        else if pausedForCache { stateText = "缓冲中" }
        else if coreIdle || !hasVideo { stateText = "正在打开" }
        else { stateText = "播放中" }
        let waitingReason = pausedForCache ? "mpv 正在缓冲/等待数据" : "无"

        cachedAudioTrackCount = audioTrackCount()

        let snapshot = DiagnosticsSample(
            observedBitrate: Double(demuxBitrate),
            averageVideoBitrate: Double(videoBitrate),
            outputFrameRate: outputFPS,
            nominalFrameRate: nominalFPS,
            droppedFrames: dropped,
            width: width,
            height: height,
            playbackClockSeconds: timePos,
            stateText: stateText,
            waitingReason: waitingReason,
            hasVideoOutput: hasVideo && !coreIdle && !pausedForCache
        )

        snapshotLock.lock()
        lastSnapshot = snapshot
        snapshotLock.unlock()

        // 兜底出画判定：音频-only 流没有 VIDEO_RECONFIG，用活跃状态代替
        if !coreIdle && !pausedForCache && !paused && !reportedPlaying {
            reportPlayingIfNeeded()
        }
    }

    private func audioTrackCount() -> Int {
        guard let ctx = mpv else { return 0 }
        var node = mpv_node()
        let rc = mpv_get_property(ctx, "track-list", MPV_FORMAT_NODE, &node)
        guard rc >= 0, node.format == MPV_FORMAT_NODE_ARRAY, let list = node.u.list else {
            if rc >= 0 { mpv_free_node_contents(&node) }
            return 0
        }
        defer { mpv_free_node_contents(&node) }

        var count = 0
        for i in 0..<Int(list.pointee.num) {
            let item = list.pointee.values[i]
            guard item.format == MPV_FORMAT_NODE_MAP, let map = item.u.list else { continue }
            var isAudio = false
            for j in 0..<Int(map.pointee.num) {
                guard let key = map.pointee.keys[j] else { continue }
                let keyName = String(cString: key)
                if keyName == "type",
                   let value = map.pointee.values[j].u.string,
                   String(cString: value) == "audio" {
                    isAudio = true
                }
            }
            if isAudio { count += 1 }
        }
        return count
    }

    // MARK: - mpv 属性/命令辅助

    private func setVolumeProperty(_ volume: Float) {
        let v = Int64((max(0, min(1, volume)) * 100).rounded())
        setInt64Property("volume", v)
        setFlagProperty("mute", false)
    }

    private func command(_ commandName: String, args: [String]) {
        guard let ctx = mpv else { return }
        var cargs = args.map { UnsafePointer<CChar>(strdup($0)) }
        cargs.insert(UnsafePointer<CChar>(strdup(commandName)), at: 0)
        cargs.append(nil)
        defer {
            for ptr in cargs where ptr != nil {
                free(UnsafeMutablePointer(mutating: ptr!))
            }
        }
        let rc = mpv_command(ctx, &cargs)
        if rc < 0 {
            print("[mpv] command '\(commandName)' error: \(String(cString: mpv_error_string(rc)))")
        }
    }

    private func getDoubleProperty(_ name: String) -> Double {
        guard let ctx = mpv else { return 0 }
        var value = Double()
        mpv_get_property(ctx, name, MPV_FORMAT_DOUBLE, &value)
        return value
    }

    private func getInt64Property(_ name: String) -> Int64 {
        guard let ctx = mpv else { return 0 }
        var value = Int64()
        mpv_get_property(ctx, name, MPV_FORMAT_INT64, &value)
        return value
    }

    private func getFlagProperty(_ name: String) -> Bool {
        guard let ctx = mpv else { return false }
        var value = Int32()
        mpv_get_property(ctx, name, MPV_FORMAT_FLAG, &value)
        return value != 0
    }

    private func setFlagProperty(_ name: String, _ flag: Bool) {
        guard let ctx = mpv else { return }
        var value: Int32 = flag ? 1 : 0
        mpv_set_property(ctx, name, MPV_FORMAT_FLAG, &value)
    }

    private func setInt64Property(_ name: String, _ value: Int64) {
        guard let ctx = mpv else { return }
        var v = value
        mpv_set_property(ctx, name, MPV_FORMAT_INT64, &v)
    }

    private func checkError(_ status: Int32) {
        if status < 0 {
            print("[mpv] API error: \(String(cString: mpv_error_string(status)))")
        }
    }
}

/// CAMetalLayer 画面宿主：mpv 的 --wid 直接渲染进该 layer。
/// drawableSize 必须跟随 bounds 与屏幕缩放，否则旋转/横屏后画面尺寸错误。
final class MPVMetalHostView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        clipsToBounds = true
        isUserInteractionEnabled = false
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        syncDrawableSize()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncDrawableSize()
    }

    private func syncDrawableSize() {
        let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        metalLayer.contentsScale = scale
        let px = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if metalLayer.drawableSize != px {
            metalLayer.drawableSize = px
        }
    }
}
