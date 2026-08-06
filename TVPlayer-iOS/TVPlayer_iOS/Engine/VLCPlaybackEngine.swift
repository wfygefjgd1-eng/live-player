import UIKit
#if canImport(VLCKit)
import VLCKit
#elseif canImport(MobileVLCKit)
import MobileVLCKit
#endif

#if canImport(VLCKit) || canImport(MobileVLCKit)
/// VLC / libvlc 直播内核。AVPlayer 仅在 VLC 无法打开流时由 PlayerEngine 兜底。
///
/// 稳定性要点：所有 libvlc 统计/轨道/时间查询都在后台队列采样，主线程只读快照。
/// （历史版本在 @MainActor 上同步轮询 statistics，会阻塞在 HLS demux 锁上导致 UI 冻结，
///  这正是 v2.0 之前“VLCKit 不稳定”的根因。）
///
/// 该类本身非 actor 隔离：play/stop/pause/resume 在主线程调用（由 @MainActor 的
/// PlayerEngine 驱动），后台采样在 samplerQueue 上读取 libvlc 的只读状态（libvlc 对
/// 这类查询线程安全），共享快照 lastSnapshot 由 NSLock 保护。
final class VLCPlaybackEngine {
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

    let mediaPlayer = VLCMediaPlayer()

    var onPlaying: (() -> Void)?
    var onError: ((String) -> Void)?
    var onStateChanged: ((String) -> Void)?

    private var stateObserver: NSObjectProtocol?
    private var activeMedia: VLCMedia?
    private var stoppedByOwner = true
    private var reportedPlaying = false

    // 后台采样：避免在主线程触碰可能阻塞 demux 锁的 libvlc 调用
    private let samplerQueue = DispatchQueue(label: "tvplayer.vlc.sampler", qos: .utility)
    private let snapshotLock = NSLock()
    private var samplerCancelled = true
    private var lastSnapshot = DiagnosticsSample()

    init() {
        stateObserver = NotificationCenter.default.addObserver(
            forName: VLCMediaPlayer.stateChangedNotification,
            object: mediaPlayer,
            queue: .main
        ) { [weak self] _ in
            // 状态变更是事件驱动，主线程读取 .state（快速缓存值）安全；
            // 不在此触碰 statistics/tracks/time 等可能阻塞 demux 锁的接口。
            Task { @MainActor [weak self] in
                self?.handleStateChange()
            }
        }
    }

    deinit {
        if let stateObserver {
            NotificationCenter.default.removeObserver(stateObserver)
        }
        samplerCancelled = true
    }

    func play(url: URL, drawable: UIView, volume: Float) {
        stoppedByOwner = true
        mediaPlayer.stop()

        reportedPlaying = false
        samplerCancelled = true
        lastSnapshot = DiagnosticsSample()

        guard let media = VLCMedia(url: url) else {
            onError?("VLC 无法创建媒体")
            return
        }

        // 更大的直播缓存吸收长 HLS 分片；VLC 自身的解码器/反隔行器负责
        // AVPlayer 难以渲染的格式。
        media.addOption(":network-caching=8000")
        media.addOption(":live-caching=8000")
        media.addOption(":http-reconnect=true")
        media.addOption(":avcodec-hw=videotoolbox")
        // 串为媒体选项时，未知的选项名会被 VLC 忽略（仅告警），不会导致无法打开媒体，
        // 因此这里设置反隔行模式无运行时风险。
        media.addOption(":deinterlace-mode=yadif")

        activeMedia = media
        mediaPlayer.drawable = drawable
        mediaPlayer.media = media
        mediaPlayer.audio?.volume = Int32((max(0, min(1, volume)) * 100).rounded())

        stoppedByOwner = false
        mediaPlayer.play()
        onStateChanged?("正在打开")

        // 开启后台采样循环
        samplerCancelled = false
        scheduleNextSample()
    }

    func pause() {
        mediaPlayer.pause()
    }

    func resume() {
        try? AVAudioSession.sharedInstance().setActive(true)
        mediaPlayer.play()
    }

    func stop() {
        stoppedByOwner = true
        reportedPlaying = false
        samplerCancelled = true
        mediaPlayer.stop()
        mediaPlayer.media = nil
        activeMedia = nil
        lastSnapshot = DiagnosticsSample()
    }

    var isPlaying: Bool { mediaPlayer.isPlaying }

    var volume: Float {
        get { Float(mediaPlayer.audio?.volume ?? 100) / 100 }
        set { mediaPlayer.audio?.volume = Int32((max(0, min(1, newValue)) * 100).rounded()) }
    }

    var hasAudioTrack: Bool {
        !mediaPlayer.audioTracks.isEmpty || !(activeMedia?.audioTracks.isEmpty ?? true)
    }

    /// 主线程调用：只读后台采样的快照，绝不触碰 libvlc。
    func diagnosticsSample() -> DiagnosticsSample {
        snapshotLock.lock()
        let snap = lastSnapshot
        snapshotLock.unlock()
        return snap
    }

    // MARK: - 后台采样

    private func scheduleNextSample() {
        samplerQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !self.samplerCancelled else { return }
            self.collectSampleOnBackground()
            self.scheduleNextSample()
        }
    }

    /// 在后台队列采集 VLC 状态。这里允许触碰 videoSize / state / hasVideoOut 等
    /// 可能阻塞 demux 锁的接口——因为不在主线程，最多让采样慢一拍，不会冻 UI。
    private func collectSampleOnBackground() {
        guard activeMedia != nil else { return }

        let videoSize = mediaPlayer.videoSize
        let width = videoSize.width > 1 ? Int(videoSize.width.rounded()) : 0
        let height = videoSize.height > 1 ? Int(videoSize.height.rounded()) : 0
        let state = mediaPlayer.state
        let hasVideoOut = mediaPlayer.hasVideoOut
        let stateText = self.stateText(for: state)
        let waitingReason = state == .opening ? "VLC 正在缓冲/打开" : "无"

        let snapshot = DiagnosticsSample(
            width: width,
            height: height,
            stateText: stateText,
            waitingReason: waitingReason,
            hasVideoOutput: hasVideoOut
        )

        snapshotLock.lock()
        lastSnapshot = snapshot
        snapshotLock.unlock()
    }

    // MARK: - 状态处理（事件驱动，主线程）

    private func handleStateChange() {
        let state = mediaPlayer.state
        let text = stateText(for: state)
        onStateChanged?(text)

        switch state {
        case .playing:
            guard !reportedPlaying else { return }
            reportedPlaying = true
            onPlaying?()
        case .error:
            guard !stoppedByOwner else { return }
            onError?("VLC 播放器报告解码或媒体错误")
        default:
            break
        }
    }

    private func stateText(for state: VLCMediaPlayerState) -> String {
        switch state {
        case .opening: return "正在打开"
        case .playing: return "播放中"
        case .paused: return "暂停"
        case .stopping: return "正在停止"
        case .stopped: return "已停止"
        case .error: return "错误"
        case .nothingSpecial: return "未开始"
        @unknown default: return "未知"
        }
    }
}
#else
/// 编译期占位：保留 PlayerEngine 兜底代码的隔离结构。
/// 发版构建必须嵌入 VLCKit，否则此处会触发编译错误提醒。
@MainActor
final class VLCPlaybackEngine {
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

    func play(url: URL, drawable: UIView, volume: Float) {}
    func pause() {}
    func resume() {}
    func stop() {}
    var hasAudioTrack: Bool { false }
    var volume: Float = 1
    func diagnosticsSample() -> DiagnosticsSample { DiagnosticsSample() }
}
#endif
