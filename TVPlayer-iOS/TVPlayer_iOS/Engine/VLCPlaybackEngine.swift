import UIKit
#if canImport(VLCKit)
import VLCKit
#endif

#if canImport(VLCKit)
/// VLC/FFmpeg-class live playback backend. AVPlayer remains available in
/// PlayerEngine only as an automatic fallback when VLC cannot open a stream.
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

    let mediaPlayer = VLCMediaPlayer()

    var onPlaying: (() -> Void)?
    var onError: ((String) -> Void)?
    var onStateChanged: ((String) -> Void)?

    private var stateObserver: NSObjectProtocol?
    private var activeMedia: VLCMedia?
    private var stoppedByOwner = true
    private var reportedPlaying = false

    init() {
        stateObserver = NotificationCenter.default.addObserver(
            forName: VLCMediaPlayer.stateChangedNotification,
            object: mediaPlayer,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleStateChange()
            }
        }
    }

    deinit {
        if let stateObserver {
            NotificationCenter.default.removeObserver(stateObserver)
        }
    }

    func play(url: URL, drawable: UIView, volume: Float) {
        stoppedByOwner = true
        mediaPlayer.stop()

        reportedPlaying = false

        guard let media = VLCMedia(url: url) else {
            onError?("VLC 无法创建媒体")
            return
        }

        // A larger live cache absorbs long HLS segments while VLC's own
        // decoder/deinterlacer handles formats that AVPlayer cannot render well.
        media.addOption(":network-caching=8000")
        media.addOption(":live-caching=8000")
        media.addOption(":http-reconnect=true")
        media.addOption(":avcodec-hw=videotoolbox")

        activeMedia = media
        mediaPlayer.drawable = drawable
        mediaPlayer.videoFitMode = .smaller
        mediaPlayer.media = media
        mediaPlayer.setDeinterlaceFilter("yadif")
        mediaPlayer.audio?.volume = Int32((max(0, min(1, volume)) * 100).rounded())

        stoppedByOwner = false
        mediaPlayer.play()
        onStateChanged?("正在打开")
    }

    func pause() {
        mediaPlayer.pause()
    }

    func resume() {
        mediaPlayer.play()
    }

    func stop() {
        stoppedByOwner = true
        reportedPlaying = false
        mediaPlayer.stop()
        mediaPlayer.media = nil
        activeMedia = nil
    }

    var isPlaying: Bool { mediaPlayer.isPlaying }

    var volume: Float {
        get { Float(mediaPlayer.audio?.volume ?? 100) / 100 }
        set { mediaPlayer.audio?.volume = Int32((max(0, min(1, newValue)) * 100).rounded()) }
    }

    var hasAudioTrack: Bool {
        !mediaPlayer.audioTracks.isEmpty || !(activeMedia?.audioTracks.isEmpty ?? true)
    }

    func diagnosticsSample() -> DiagnosticsSample {
        guard activeMedia != nil else {
            return DiagnosticsSample(stateText: stateText(for: mediaPlayer.state))
        }

        // Keep this sampler deliberately non-blocking. libvlc media.statistics,
        // track enumeration and time queries can wait on an HLS demux lock;
        // calling them on the main actor caused the UI to freeze after startup.
        let videoSize = mediaPlayer.videoSize
        let width = videoSize.width > 1 ? Int(videoSize.width.rounded()) : 0
        let height = videoSize.height > 1 ? Int(videoSize.height.rounded()) : 0
        let state = mediaPlayer.state

        return DiagnosticsSample(
            width: width,
            height: height,
            stateText: stateText(for: state),
            waitingReason: state == .opening ? "VLC 正在缓冲/打开" : "无",
            hasVideoOutput: mediaPlayer.hasVideoOut
        )
    }

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
/// Compile-time stub retained so PlayerEngine's fallback code stays isolated.
/// The shipping lightweight build does not embed VLCKit.
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
