import AVFoundation
import UIKit
import KSPlayer

/// KSPlayer-only playback backend. KSMEPlayer is selected directly so the
/// system AVPlayer is never used as an automatic fallback.
@MainActor
final class KSPlaybackEngine: NSObject {
    struct DiagnosticsSample {
        var observedBytes: Int64 = 0
        var videoBitrate: Double = 0
        var outputFrameRate: Double = 0
        var nominalFrameRate: Double = 0
        var droppedFrames: Int = 0
        var audioVideoSyncDiff: TimeInterval = 0
        var bufferSeconds: TimeInterval = 0
        var width: Int = 0
        var height: Int = 0
        var playbackClockSeconds: TimeInterval = 0
        var stateText = "未开始"
        var waitingReason = "无"
        var hasVideoOutput = false
    }

    var onReady: (() -> Void)?
    var onError: ((String) -> Void)?
    var onStateChanged: ((String) -> Void)?
    var onTimeChanged: ((TimeInterval) -> Void)?

    private(set) var layer: KSPlayerLayer?
    private var stoppedByOwner = true
    private var reportedReady = false
    private var requestedVolume: Float = 1

    var view: UIView? { layer?.player.view }
    var isPlaying: Bool { layer?.player.isPlaying ?? false }
    var hasAudioTrack: Bool {
        !(layer?.player.tracks(mediaType: .audio).isEmpty ?? true)
    }

    var volume: Float {
        get { requestedVolume }
        set {
            requestedVolume = max(0, min(1, newValue))
            layer?.player.playbackVolume = requestedVolume
        }
    }

    func play(url: URL, volume: Float) {
        stop()

        requestedVolume = max(0, min(1, volume))
        reportedReady = false
        stoppedByOwner = false

        // Use one decoder path only. Interlaced video is decoded in software
        // because KSPlayer documents a crash in yadif_videotoolbox.
        KSOptions.firstPlayerType = KSMEPlayer.self
        KSOptions.secondPlayerType = nil
        KSOptions.isSecondOpen = false
        KSOptions.preferredFrame = true
        KSOptions.yadifMode = 0

        let options = KSOptions()
        options.userAgent = "Mozilla/5.0 (iPhone; CPU iOS 17_0 like Mac OS X)"
        options.preferredForwardBufferDuration = isLongSegmentSource(url) ? 8 : 3
        options.maxBufferDuration = isLongSegmentSource(url) ? 24 : 15
        options.registerRemoteControll = false
        options.autoDeInterlace = true
        options.videoAdaptable = false

        if isLongSegmentSource(url) {
            options.hardwareDecode = false
            options.asynchronousDecompression = false
            options.autoDeInterlace = false
            // One output frame per input frame. mode=1 doubles the work to
            // 50 fps and made 1080i software decoding miss its 25 fps target.
            options.videoFilters = ["yadif=mode=0:parity=-1:deint=1"]
        }

        let layer = KSPlayerLayer(
            url: url,
            isAutoPlay: false,
            options: options,
            delegate: self
        )
        self.layer = layer
        layer.player.playbackVolume = requestedVolume
        layer.player.contentMode = .scaleAspectFit
        WindowVideoSurface.shared.showKSPlayer(layer.player.view)
        layer.play()
        onStateChanged?("正在打开")
    }

    func pause() {
        layer?.pause()
    }

    func resume() {
        layer?.play()
    }

    func stop() {
        stoppedByOwner = true
        reportedReady = false
        layer?.stop()
        layer?.player.view?.removeFromSuperview()
        layer = nil
        WindowVideoSurface.shared.showKSPlayer(nil)
    }

    func diagnosticsSample() -> DiagnosticsSample {
        guard let player = layer?.player else { return DiagnosticsSample() }
        let size = player.naturalSize
        let info = player.dynamicInfo
        return DiagnosticsSample(
            observedBytes: info?.bytesRead ?? 0,
            videoBitrate: Double(info?.videoBitrate ?? 0),
            outputFrameRate: info?.displayFPS ?? 0,
            nominalFrameRate: Double(player.nominalFrameRate),
            droppedFrames: Int(info?.droppedVideoFrameCount ?? 0),
            audioVideoSyncDiff: info?.audioVideoSyncDiff ?? 0,
            bufferSeconds: max(0, player.playableTime),
            width: size.width > 1 ? Int(size.width.rounded()) : 0,
            height: size.height > 1 ? Int(size.height.rounded()) : 0,
            playbackClockSeconds: player.currentPlaybackTime,
            stateText: stateText(layer?.state),
            waitingReason: layer?.state == .buffering ? "KSPlayer 正在缓冲" : "无",
            hasVideoOutput: size.width > 1 && size.height > 1 && (info?.displayFPS ?? 0) > 0
        )
    }

    private func isLongSegmentSource(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host == "live.264788.xyz" || host.hasSuffix(".264788.xyz")
    }

    private func stateText(_ state: KSPlayerState?) -> String {
        switch state {
        case .preparing: return "正在打开"
        case .readyToPlay: return "准备完成"
        case .buffering: return "缓冲中"
        case .bufferFinished: return "播放中"
        case .paused: return "暂停"
        case .playedToTheEnd: return "播放结束"
        case .error: return "错误"
        case .initialized, .none: return "未开始"
        }
    }
}

extension KSPlaybackEngine: KSPlayerLayerDelegate {
    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        guard layer === self.layer else { return }
        onStateChanged?(stateText(state))

        switch state {
        case .readyToPlay, .bufferFinished:
            guard !reportedReady else { return }
            reportedReady = true
            onReady?()
        case .error:
            guard !stoppedByOwner else { return }
            onError?("KSPlayer 解码或媒体错误")
        default:
            break
        }
    }

    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        guard layer === self.layer else { return }
        onTimeChanged?(currentTime)
    }

    func player(layer: KSPlayerLayer, finish error: Error?) {
        guard layer === self.layer, !stoppedByOwner else { return }
        if let error {
            onError?("KSPlayer 播放失败：\(error.localizedDescription)")
        } else {
            onError?("直播流已结束")
        }
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {
        guard layer === self.layer else { return }
        onStateChanged?("缓冲中")
    }
}
