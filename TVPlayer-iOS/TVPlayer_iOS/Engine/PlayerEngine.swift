import AVFoundation
import Combine
import UIKit

/// 起播/卡顿检测引擎（mpv 专用）
///
/// 内核策略：仅使用 mpv(libmpv)。不再保留 AVPlayer 兜底。
/// - mpv 处理所有格式（隔行 1080i、非标 HLS、AVS/AVS2/AVS3、HEVC 10bit 等）。
/// - 起播超时或失败时，直接触发换线/换台，不回退其它内核。
/// - mpv 的统计/轨道/时间查询在后台队列采样，主线程只读快照。
@MainActor
final class PlayerEngine: ObservableObject {
    // MARK: - 配置
    /// 出画后保护：此期间禁止因软问题换线
    static let readyProtectNs: UInt64 = 4_000_000_000
    /// 出画后持续缓冲超过该阈值即判定为无数据，触发换线
    static let progressStallThreshold: TimeInterval = 8.0

    /// 起播超时：mpv 端（慢 HLS 长分片源单独放宽，见 startupTimeoutNs(for:)）
    static let mpvStartupTimeoutNs: UInt64 = 25_000_000_000
    static let mpvSlowSourceTimeoutNs: UInt64 = 40_000_000_000

    /// 慢源判定：live.264788.xyz 使用超长分片，起播/缓冲都要更久
    static func startupTimeoutNs(for url: URL) -> UInt64 {
        let host = (url.host ?? "").lowercased()
        if host == "live.264788.xyz" || host.hasSuffix(".264788.xyz") {
            return mpvSlowSourceTimeoutNs
        }
        return mpvStartupTimeoutNs
    }

    // 起播参数仍保留（bufferProfile 用于诊断展示）
    static let initialBufferSeconds: TimeInterval = 6
    static let longSegmentBufferSeconds: TimeInterval = 18

    static var steadyBufferSeconds: TimeInterval {
        NetworkMonitor.shared.isCellular ? 18 : 24
    }

    private let mpvEngine = MPVPlaybackEngine()
    private var currentURL: URL?
    private var mpvStartupTask: Task<Void, Never>?
    private var requestedVolume: Float = 1
    private var cancellables = Set<AnyCancellable>()

    private var watchTasks: [String: Task<Void, Never>] = [:]
    private var playToken = 0

    private var stallWatchEnabled = false

    private var diagnosticsTask: Task<Void, Never>?
    private var stallCheckTask: Task<Void, Never>?

    @Published var isReady = false
    @Published var isPlaying = false
    /// 最近采样网速 KB/s（供 UI/调试）
    @Published var observedSpeedKBps: Double = 0
    @Published private(set) var diagnostics = PlaybackDiagnostics()
    /// 仅在缓冲、网络/缓存不足、持续低帧或音画时钟异常时显示。
    @Published private(set) var shouldShowDiagnostics = false
    @Published private(set) var activeEngineName = "libmpv (MPVKit)"

    var diagnosticsSummary: String {
        let observed = diagnostics.observedBitrate > 0 ? String(format: "%.2f Mbps", diagnostics.observedBitrate / 1_000_000) : "未知"
        let averageVideo = diagnostics.averageVideoBitrate > 0
            ? String(format: "%.2f Mbps", diagnostics.averageVideoBitrate / 1_000_000) : "未知"
        return "TV go iOS 播放诊断\n播放内核: \(activeEngineName)\n线路: \(currentURLString.isEmpty ? "未知" : currentURLString)\n分辨率: \(diagnostics.resolutionText)\n输出/源帧率: \(String(format: "%.1f", diagnostics.currentVideoFrameRate)) / \(String(format: "%.1f", diagnostics.nominalVideoFrameRate)) fps\n累计丢帧: \(diagnostics.droppedVideoFrames)（最近 \(String(format: "%.1f", diagnostics.droppedFramesPerSecond)) 帧/秒）\n实际下载码率: \(observed)\n平均视频码率: \(averageVideo)\n缓冲: \(String(format: "%.1f", diagnostics.bufferSeconds)) 秒\n卡顿: \(diagnostics.stallCount) 次\n播放状态: \(diagnostics.timeControlStatus)\n等待原因: \(diagnostics.waitingReason)\n缓冲可持续: \(diagnostics.isLikelyToKeepUp ? "是" : "否")\n诊断判断: \(diagnostics.assessment)\n最近状态: \(diagnostics.reason.isEmpty ? "未知" : diagnostics.reason)"
    }

    var onError: (() -> Void)?
    var onReady: (() -> Void)?
    var onStartupTimeout: (() -> Void)?
    var onSilentAudio: (() -> Void)?
    /// 网速过低/无网触发换线
    var onLowSpeed: ((String) -> Void)?

    /// 线路超时/卡顿/低速自动检测（设置可关，默认开）
    var lineTimeoutEnabled: Bool = true

    private var memoryWarningObserver: NSObjectProtocol?
    private var playStartedAt: Date = .distantPast
    private var currentURLString = ""
    private var recentStalls: [Date] = []
    private var lastStallAt: Date = .distantPast
    private var failureRecorded = false
    /// 当前 play() 的代次：过滤上一个文件残留的 mpv 事件（起播/错误）
    private var activePlayToken = 0
    /// 连续缓冲秒数（每轮采样 +1）；超过 progressStallThreshold 触发换线
    private var consecutiveBufferSeconds: Double = 0
    /// 同一轮缓冲只触发一次 onLowSpeed，恢复播放后复位
    private var lowSpeedReported = false

    init() {
        setupCacheCleanup()
        mpvEngine.onPlaying = { [weak self] in
            self?.handleMPVPlaying()
        }
        mpvEngine.onError = { [weak self] reason in
            self?.handleMPVFailure(reason: reason)
        }
        mpvEngine.onStateChanged = { [weak self] state in
            guard let self else { return }
            self.diagnostics.timeControlStatus = state
        }
    }

    private func setupCacheCleanup() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            URLCache.shared.removeAllCachedResponses()
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
        diagnosticsTask?.cancel()
        mpvStartupTask?.cancel()
        cancellables.removeAll()
    }

    // MARK: - Public API

    func play(url: URL) {
        mpvStartupTask?.cancel()
        mpvStartupTask = nil
        activeEngineName = "libmpv (MPVKit)"
        guard let drawable = WindowVideoSurface.shared.showMPV() else {
            // 窗口未就绪：稍后由调用方重新触发
            diagnostics.reason = "播放窗口未就绪"
            onError?()
            return
        }

        playToken += 1
        let token = playToken
        activePlayToken = token
        resetState(for: token)
        currentURL = url
        currentURLString = url.absoluteString
        playStartedAt = Date()
        let profile = Self.bufferProfile(for: url)
        diagnostics = PlaybackDiagnostics(bufferSeconds: profile.initial, engineName: activeEngineName)
        isReady = false
        isPlaying = true
        mpvEngine.play(url: url, drawable: drawable, volume: requestedVolume)
        startLiveDiagnostics(token: token)

        guard lineTimeoutEnabled else { return }
        let timeoutNs = Self.startupTimeoutNs(for: url)
        mpvStartupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNs)
            guard let self, !Task.isCancelled, self.playToken == token,
                  !self.isReady else { return }
            self.handleMPVFailure(reason: "mpv 起播超过 \(timeoutNs / 1_000_000_000) 秒")
        }
    }

    private func handleMPVPlaying() {
        guard playToken == activePlayToken else { return }
        mpvStartupTask?.cancel()
        mpvStartupTask = nil
        isPlaying = true
        guard !isReady else { return }
        isReady = true
        diagnostics.timeControlStatus = "播放中"
        diagnostics.waitingReason = "无"
        diagnostics.isBufferEmpty = false
        diagnostics.reason = "mpv 已输出画面"
        let startupSeconds = playStartedAt == .distantPast
            ? 0 : Date().timeIntervalSince(playStartedAt)
        LineQualityStore.shared.recordStart(
            url: currentURLString,
            startupSeconds: startupSeconds
        )
        onReady?()
        WindowVideoSurface.shared.rebindPlayer()

        stallWatchEnabled = false
        scheduleTask(named: "readyProtect", token: playToken, timeout: Self.readyProtectNs) { [weak self] in
            guard let self, self.playToken == playToken else { return }
            self.stallWatchEnabled = true
            self.startStallCheck(token: playToken)
        }
    }

    private func handleMPVFailure(reason: String) {
        guard playToken == activePlayToken else { return }
        mpvStartupTask?.cancel()
        mpvStartupTask = nil
        diagnostics.reason = reason
        recordFailureOnce()
        // mpv 失败：直接通知换线，不回退其它内核
        if isReady {
            onError?()
        } else {
            onStartupTimeout?()
        }
    }

    private static func bufferProfile(for url: URL) -> (initial: TimeInterval, steady: TimeInterval) {
        let host = (url.host ?? "").lowercased()
        if host == "live.264788.xyz" || host.hasSuffix(".264788.xyz") {
            return (longSegmentBufferSeconds, longSegmentBufferSeconds)
        }
        return (initialBufferSeconds, steadyBufferSeconds)
    }

    func pause() {
        mpvEngine.pause()
        isPlaying = false
    }

    func resume() {
        guard hasCurrentMedia else { return }
        mpvEngine.resume()
        isPlaying = true
        WindowVideoSurface.shared.rebindPlayer()
    }

    var hasCurrentMedia: Bool {
        currentURL != nil
    }

    /// Re-arm line monitoring when the setting changes during playback.
    func setLineTimeoutEnabled(_ enabled: Bool) {
        lineTimeoutEnabled = enabled
        if !enabled {
            mpvStartupTask?.cancel()
            mpvStartupTask = nil
            stopStallCheck()
            cancelAllTasks()
        } else if !isReady, currentURL != nil {
            let token = playToken
            let timeoutNs = Self.startupTimeoutNs(for: currentURL!)
            mpvStartupTask?.cancel()
            mpvStartupTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNs)
                guard let self, !Task.isCancelled, self.playToken == token,
                      !self.isReady else { return }
                self.handleMPVFailure(reason: "mpv 起播超过 \(timeoutNs / 1_000_000_000) 秒")
            }
        }
    }

    func stop() {
        playToken += 1
        mpvStartupTask?.cancel()
        mpvStartupTask = nil
        mpvEngine.stop()
        cancelAllTasks()
        stopStallCheck()
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        currentURL = nil
        isPlaying = false
        isReady = false
        shouldShowDiagnostics = false
        stallWatchEnabled = false
        failureRecorded = false
    }

    var volume: Float {
        get { requestedVolume }
        set {
            requestedVolume = max(0, min(1, newValue))
            mpvEngine.volume = requestedVolume
        }
    }

    /// 当前播放地址是否有可用的声音轨
    var hasActiveAudioTrack: Bool {
        mpvEngine.hasAudioTrack
    }

    // MARK: - Private — State Management

    private func resetState(for token: Int) {
        mpvStartupTask?.cancel()
        mpvStartupTask = nil
        cancelAllTasks()
        stopStallCheck()
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        recentStalls.removeAll()
        lastStallAt = .distantPast
        failureRecorded = false
        consecutiveBufferSeconds = 0
        lowSpeedReported = false
        shouldShowDiagnostics = false
        diagnostics = PlaybackDiagnostics(
            bufferSeconds: Self.initialBufferSeconds,
            engineName: activeEngineName
        )
        isReady = false
    }

    private func cancelAllTasks() {
        for (_, task) in watchTasks {
            task.cancel()
        }
        watchTasks.removeAll()
    }

    @discardableResult
    private func scheduleTask(named name: String, token: Int, timeout: UInt64, action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        if let existing = watchTasks[name] {
            existing.cancel()
        }
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard self.playToken == token else { return }
            action()
            self.watchTasks[name] = nil
        }
        watchTasks[name] = task
        return task
    }

    private func cancelTask(named name: String) {
        watchTasks[name]?.cancel()
        watchTasks[name] = nil
    }

    // MARK: - 播放中卡顿检测

    /// mpv 播放中健康评估：core-idle / paused-for-cache 持续过久 → 换线
    private func startStallCheck(token: Int) {
        stopStallCheck()
        guard lineTimeoutEnabled else { return }
        stallCheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.lineTimeoutEnabled, self.playToken == token,
                      !Task.isCancelled, self.isReady else { return }

                let sample = self.mpvEngine.diagnosticsSample()
                let now = Date()

                // 播放稳定：记录质量
                if sample.hasVideoOutput && sample.stateText == "播放中",
                   now.timeIntervalSince(self.lastStallAt) > 15,
                   now.timeIntervalSince(self.lastQualitySampleAt) >= 15 {
                    LineQualityStore.shared.recordStablePlayback(
                        url: self.currentURLString,
                        seconds: 15,
                        observedBitrate: sample.observedBitrate
                    )
                    self.lastQualitySampleAt = now
                    self.updateDiagnostics(reason: "播放稳定")
                }

                // 卡顿：paused-for-cache 持续
                if sample.stateText == "缓冲中" {
                    self.registerStall()
                    self.consecutiveBufferSeconds += 1
                    // 持续缓冲超过阈值且本轮未报过 → 判定无数据，触发换线
                    if self.consecutiveBufferSeconds >= Self.progressStallThreshold, !self.lowSpeedReported {
                        self.lowSpeedReported = true
                        self.onLowSpeed?("持续缓冲无数据，自动换线")
                    }
                } else {
                    self.consecutiveBufferSeconds = 0
                    self.lowSpeedReported = false
                }
            }
        }
    }

    private var lastQualitySampleAt: Date = .distantPast

    private func stopStallCheck() {
        stallCheckTask?.cancel()
        stallCheckTask = nil
    }

    private func registerStall() {
        guard isReady else { return }
        let now = Date()
        lastStallAt = now
        recentStalls = recentStalls.filter { now.timeIntervalSince($0) <= 45 }
        // 防抖：5 秒内同一轮卡顿只记一次
        if let last = recentStalls.last, now.timeIntervalSince(last) < 5 { return }
        recentStalls.append(now)
        LineQualityStore.shared.recordStall(url: currentURLString)
        updateDiagnostics(reason: "检测到卡顿")
    }

    private func recordFailureOnce() {
        guard !failureRecorded else { return }
        failureRecorded = true
        LineQualityStore.shared.recordFailure(url: currentURLString)
    }

    private func updateDiagnostics(reason: String) {
        refreshDiagnostics(reason: reason)
    }

    private func startLiveDiagnostics(token: Int) {
        diagnosticsTask?.cancel()
        diagnosticsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled, self.playToken == token else { return }
                self.refreshDiagnostics(reason: nil)
            }
        }
    }

    private func refreshDiagnostics(reason: String?) {
        let sample = mpvEngine.diagnosticsSample()
        observedSpeedKBps = sample.observedBitrate > 0
            ? sample.observedBitrate / 8 / 1024 : 0
        diagnostics = PlaybackDiagnostics(
            observedBitrate: sample.observedBitrate,
            averageVideoBitrate: sample.averageVideoBitrate,
            currentVideoFrameRate: sample.outputFrameRate,
            nominalVideoFrameRate: sample.nominalFrameRate,
            droppedVideoFrames: sample.droppedFrames,
            droppedFramesPerSecond: sample.droppedFramesPerSecond,
            videoWidth: sample.width,
            videoHeight: sample.height,
            stallCount: recentStalls.count,
            bufferSeconds: 0,
            timeControlStatus: sample.stateText,
            waitingReason: sample.waitingReason,
            isLikelyToKeepUp: sample.hasVideoOutput && sample.stateText == "播放中",
            isBufferEmpty: false,
            playbackClockSeconds: sample.playbackClockSeconds,
            engineName: activeEngineName,
            reason: reason ?? diagnostics.reason
        )
    }
}

// MARK: - 多信号融合数据结构

struct PlaybackDiagnostics: Equatable {
    var observedBitrate: Double
    var averageVideoBitrate: Double
    var currentVideoFrameRate: Double
    var nominalVideoFrameRate: Double
    var droppedVideoFrames: Int
    var droppedFramesPerSecond: Double
    var videoWidth: Int
    var videoHeight: Int
    var stallCount: Int
    var bufferSeconds: TimeInterval
    var peakBitRateLimit: Double
    var timeControlStatus: String
    var waitingReason: String
    var isLikelyToKeepUp: Bool
    var isBufferEmpty: Bool
    var playbackClockSeconds: TimeInterval
    var audioVideoSyncDiff: TimeInterval
    var engineName: String
    var reason: String

    var resolutionText: String {
        videoWidth > 0 && videoHeight > 0 ? "\(videoWidth)×\(videoHeight)" : "未知"
    }

    var assessment: String {
        if engineName.lowercased().contains("mpv") {
            if timeControlStatus == "错误" {
                return "mpv 解码或媒体错误"
            }
            if timeControlStatus == "正在打开" {
                return "mpv 正在建立直播缓冲"
            }
            if droppedFramesPerSecond >= 3 {
                return "mpv 解码持续丢帧"
            }
            if timeControlStatus == "播放中", isLikelyToKeepUp {
                return "mpv 兼容内核播放正常"
            }
            return "正在收集 mpv 数据"
        }
        if timeControlStatus == "等待" || isBufferEmpty {
            return "网络或缓冲不足"
        }
        if nominalVideoFrameRate >= 15,
           currentVideoFrameRate > 0,
           currentVideoFrameRate < nominalVideoFrameRate * 0.55 {
            return "视频输出帧率明显偏低"
        }
        if droppedFramesPerSecond >= 3, bufferSeconds >= 2, timeControlStatus == "播放中" {
            return "解码/渲染持续丢帧"
        }
        if droppedVideoFrames > 0 {
            return "检测到视频丢帧，继续观察增长速度"
        }
        if timeControlStatus == "播放中", isLikelyToKeepUp {
            return "当前指标正常"
        }
        return "正在收集数据"
    }

    init(
        observedBitrate: Double = 0,
        averageVideoBitrate: Double = 0,
        currentVideoFrameRate: Double = 0,
        nominalVideoFrameRate: Double = 0,
        droppedVideoFrames: Int = 0,
        droppedFramesPerSecond: Double = 0,
        videoWidth: Int = 0,
        videoHeight: Int = 0,
        stallCount: Int = 0,
        bufferSeconds: TimeInterval = 0,
        peakBitRateLimit: Double = 0,
        timeControlStatus: String = "未开始",
        waitingReason: String = "无",
        isLikelyToKeepUp: Bool = false,
        isBufferEmpty: Bool = true,
        playbackClockSeconds: TimeInterval = 0,
        audioVideoSyncDiff: TimeInterval = 0,
        engineName: String = "AVPlayer",
        reason: String = ""
    ) {
        self.observedBitrate = observedBitrate
        self.averageVideoBitrate = averageVideoBitrate
        self.currentVideoFrameRate = currentVideoFrameRate
        self.nominalVideoFrameRate = nominalVideoFrameRate
        self.droppedVideoFrames = droppedVideoFrames
        self.droppedFramesPerSecond = droppedFramesPerSecond
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.stallCount = stallCount
        self.bufferSeconds = bufferSeconds
        self.peakBitRateLimit = peakBitRateLimit
        self.timeControlStatus = timeControlStatus
        self.waitingReason = waitingReason
        self.isLikelyToKeepUp = isLikelyToKeepUp
        self.isBufferEmpty = isBufferEmpty
        self.playbackClockSeconds = playbackClockSeconds
        self.audioVideoSyncDiff = audioVideoSyncDiff
        self.engineName = engineName
        self.reason = reason
    }
}
