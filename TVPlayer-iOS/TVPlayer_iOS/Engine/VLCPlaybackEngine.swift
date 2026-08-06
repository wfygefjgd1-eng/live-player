import UIKit
import VLCKit

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
    private var lastDisplayedPictures: UInt64 = 0
    private var lastLostPictures: UInt64 = 0
    private var lastSampleAt = Date.distantPast

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
        lastDisplayedPictures = 0
        lastLostPictures = 0
        lastSampleAt = .distantPast

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
        mediaPlayer.audio.volume = Int32((max(0, min(1, volume)) * 100).rounded())

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
        get { Float(mediaPlayer.audio.volume) / 100 }
        set { mediaPlayer.audio.volume = Int32((max(0, min(1, newValue)) * 100).rounded()) }
    }

    var hasAudioTrack: Bool {
        !mediaPlayer.audioTracks.isEmpty || !(activeMedia?.audioTracks.isEmpty ?? true)
    }

    func diagnosticsSample() -> DiagnosticsSample {
        guard let media = activeMedia else {
            return DiagnosticsSample(stateText: stateText(for: mediaPlayer.state))
        }

        let statistics = media.statistics
        let now = Date()
        let displayed = statistics.displayedPictures
        let lost = statistics.lostPictures + statistics.latePictures
        var outputFPS = 0.0
        var droppedPerSecond = 0.0

        if lastSampleAt != .distantPast {
            let elapsed = now.timeIntervalSince(lastSampleAt)
            if elapsed > 0.2 {
                if displayed >= lastDisplayedPictures {
                    outputFPS = Double(displayed - lastDisplayedPictures) / elapsed
                }
                if lost >= lastLostPictures {
                    droppedPerSecond = Double(lost - lastLostPictures) / elapsed
                }
            }
        }
        lastDisplayedPictures = displayed
        lastLostPictures = lost
        lastSampleAt = now

        let videoTrack = media.videoTracks.first?.video
        let videoSize = mediaPlayer.videoSize
        let width = videoSize.width > 1 ? Int(videoSize.width.rounded()) : Int(videoTrack?.width ?? 0)
        let height = videoSize.height > 1 ? Int(videoSize.height.rounded()) : Int(videoTrack?.height ?? 0)
        let denominator = Double(videoTrack?.frameRateDenominator ?? 0)
        let nominalFPS = denominator > 0 ? Double(videoTrack?.frameRate ?? 0) / denominator : 0
        let videoBitrate = Double(media.videoTracks.first?.bitrate ?? 0)
        let clockMilliseconds = mediaPlayer.time.intValue
        let state = mediaPlayer.state

        // libvlc reports inputBitrate in MiB/s.
        let observedBitsPerSecond = Double(statistics.inputBitrate) * 8_000_000

        return DiagnosticsSample(
            observedBitrate: observedBitsPerSecond,
            averageVideoBitrate: videoBitrate,
            outputFrameRate: outputFPS,
            nominalFrameRate: nominalFPS,
            droppedFrames: Int(lost),
            droppedFramesPerSecond: droppedPerSecond,
            width: width,
            height: height,
            playbackClockSeconds: Double(clockMilliseconds) / 1000,
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
