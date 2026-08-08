import AVFoundation
import Combine
import UIKit

/// 起播/卡顿检测引擎（系统 AVPlayer 主内核 + libmpv 兜底）
///
/// 内核策略：
/// - 主内核：系统 AVPlayer。iPhone 最底层、最稳定的原生播放核心，零体积开销，
///   绝大多数标准 HLS 源都能直接播放。
/// - 特殊源：已知 AVPlayer 无法持续输出画面的源（live.264788.xyz 的 1080i
///   长分片 HLS）直接走 libmpv（MPVKit），不浪费时间先试 AVPlayer。
/// - 自动回退：AVPlayer 明确失败（item failed / 致命错误日志 / 起播超时无画面）
///   时，本次播放自动回退 mpv 一次；mpv 再失败才触发换线。
/// - 回退状态每次 play() 重置，杜绝旧的「hasFallenBackToAVPlayer 一次性标志」
///   状态污染：以前某条源回退过一次后，之后所有源都不再回退、全部直接判死。
@MainActor
final class PlayerEngine: ObservableObject {
    // MARK: - 配置
    /// 起播硬上限：慢 HLS 也要给足时间，避免「没几个能看」
    static let readyProtectNs: UInt64 = 4_000_000_000
    static let progressStallThreshold: TimeInterval = 8.0

    /// mpv 起播超时；慢 HLS 长分片源单独放宽（见 startupTimeoutNs(for:)）
    /// 起播绝对上限（网络门控下的兜底）：网络达标（≥200KB/s）就继续等；
    /// 但无论网络如何，超过 safeLineCapSeconds 仍不出画就切。这取代了旧的
    /// 固定 25/30/40 秒超时——慢源只要在传数据就相对稳定，异常源最多 15 秒兜底。
    static let safeLineCapSeconds: TimeInterval = 15.0
    static let safeLineCapNs: UInt64 = 15_000_000_000
    /// mpv 起播/慢源超时统一走 safeLineCap 网络门控
    static let mpvStartupTimeoutNs: UInt64 = safeLineCapNs
    static let mpvSlowSourceTimeoutNs: UInt64 = safeLineCapNs
    /// AVPlayer 起播超时同样统一
    static let avPlayerStartupTimeoutNs: UInt64 = safeLineCapNs

    /// 慢源判定：live.264788.xyz 使用超长分片，起播/缓冲都要更久
    static func startupTimeoutNs(for url: URL) -> UInt64 {
        let host = (url.host ?? "").lowercased()
        if host == "live.264788.xyz" || host.hasSuffix(".264788.xyz") {
            return mpvSlowSourceTimeoutNs
        }
        return mpvStartupTimeoutNs
    }

    // 起播参数仍保留（bufferProfile 用于诊断展示）。
    // initialBufferSeconds 是 AVPlayer preferredForwardBufferDuration：决定了等待多少
    // 缓冲才出首帧。直播源无需等 6s（6s 是存片习惯值），降到 3s 画面更快。
    // 3s 后系统会渐进填充。长分片源（18s）与稳态缓冲（24s）不受影响。
    static let initialBufferSeconds: TimeInterval = 3
    static let longSegmentBufferSeconds: TimeInterval = 18

    static var steadyBufferSeconds: TimeInterval {
        NetworkMonitor.shared.isCellular ? 18 : 24
    }

    /// 已知 AVPlayer 无法持续出画的源：直接走 mpv
    static func requiresMPV(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host == "live.264788.xyz" || host.hasSuffix(".264788.xyz")
    }

    private enum Backend {
        case avPlayer
        case mpv
    }

    private let avPlayer = AVPlayer()
    private let mpvEngine = MPVPlaybackEngine()
    private var activeBackend: Backend = .avPlayer

    private var currentURL: URL?
    private var mpvStartupTask: Task<Void, Never>?
    private var avStartupTask: Task<Void, Never>?
    private var requestedVolume: Float = 1
    private var cancellables = Set<AnyCancellable>()

    private var watchTasks: [String: Task<Void, Never>] = [:]
    private var playToken = 0
    /// 当前 play() 的代次：过滤上一个文件残留的事件
    private var activePlayToken = 0
    /// 本次 play 是否已用过 mpv 回退（每次 play() 重置，无永久回退状态）
    private var fallbackUsed = false

    private var stallWatchEnabled = false
    private var diagnosticsTask: Task<Void, Never>?
    private var stallCheckTask: Task<Void, Never>?
    private var avDiagnosticsTask: Task<Void, Never>?
    /// 诊断浮层异常短暂提示的自动隐藏任务
    private var diagnosticsDismissTask: Task<Void, Never>?

    private var memoryWarningObserver: NSObjectProtocol?
    private var renderedObserver: NSObjectProtocol?
    private var playStartedAt: Date = .distantPast
    private var currentURLString = ""
    private var recentStalls: [Date] = []
    private var lastStallAt: Date = .distantPast
    private var lastQualitySampleAt: Date = .distantPast
    private var failureRecorded = false

    // AVPlayer 侧状态
    private var avItem: AVPlayerItem?
    private var avItemStatusObserver: NSKeyValueObservation?
    private var avTimeObserver: NSKeyValueObservation?
    private var avErrorObserver: NSObjectProtocol?
    private var avRenderedConsecutive = 0
    private var consecutiveBufferSeconds: Double = 0
    private var lowSpeedReported = false

    /// 慢线硬指标：网络不达标（<200KB/s）持续停滞 → 快速换线；网络达标则继续等。
    /// 这是「死链 vs 慢源」的核心区分——网络在流动说明源活着，不误杀慢源。
    static let slowLineSpeedThresholdKBps: Double = 200
    static let slowLineDurationSeconds: TimeInterval = 3.0
    /// 当前是否处于「慢线证据」积累中（网络不达标 + 声画无进展持续计数）
    private var slowLineEvidenceStartedAt: Date? = nil
    /// 本次 play() 内是否出现过一次达标网速（≥200KB/s）。
    /// 起播初期网速从 0 开始（尚未连上数据源），若从未达标就卡住 3s → 判死线快速切；
    /// 一旦达标过，说明源在传数据，转入「网络流动等待」不轻易误杀。
    private var hasSeenHealthySpeed = false

    /// 多信号健康确认：连续健康拍数（每 0.5s 采样 1 拍）。达到阈值才宣布健康。
    private var healthyConsecutivePulses = 0
    /// 多信号健康确认所需的最小连续拍数：2 拍（1s）避免单拍抖动误判。
    static let healthyPulsesRequired = 2
    /// 健康态一旦确立后不再回退（本线路出画即视为可用，卡顿交给 stall 检测而非转圈）
    private var healthyEverEstablished = false

    /// 最近一次有效网速采样的时间：超时（1.5s 无新数据）即归零，避免显示过期速度。
    /// 太短会因直播分片间隙抖动闪烁，太长会掩盖断网；0.5s 采样 × 3 拍为界。
    private var lastValidSpeedSampleAt: Date = .distantPast
    private let speedStaleTimeout: TimeInterval = 1.5

    /// AVPlayer 累计字节追踪（用于计算真实瞬时下载速度）
    private var lastAVTotalBytes: Int64 = 0
    private var lastAVSampleTime: Date = .distantPast

    @Published var isReady = false
    @Published var isPlaying = false
    /// 正在切台/切线路（起播中未出画）：UI 显示「正在切换」反馈
    @Published private(set) var isSwitching = false
    /// 多信号确认的健康态：有声 + 有画 + 画面在流转（事件驱动，无固定时长）。
    /// 由 UI 加载窗口观察；连续健康拍数达标后才置 true。
    @Published private(set) var isPlaybackHealthy = false
    /// 最近采样网速 KB/s（供 UI/调试）
    @Published var observedSpeedKBps: Double = 0
    @Published private(set) var diagnostics = PlaybackDiagnostics()
    /// 仅在缓冲、网络/缓存不足、持续低帧或音画时钟异常时显示。
    @Published private(set) var shouldShowDiagnostics = false
    @Published private(set) var activeEngineName = "系统 AVPlayer"

    var diagnosticsSummary: String {
        let observed = diagnostics.observedBitrate > 0 ? String(format: "%.2f Mbps", diagnostics.observedBitrate / 1_000_000) : "未知"
        let averageVideo = diagnostics.averageVideoBitrate > 0
            ? String(format: "%.2f Mbps", diagnostics.averageVideoBitrate / 1_000_000) : "未知"
        var summary = "TV go iOS 播放诊断\n播放内核: \(activeEngineName)\n线路: \(currentURLString.isEmpty ? "未知" : currentURLString)\n分辨率: \(diagnostics.resolutionText)\n输出/源帧率: \(String(format: "%.1f", diagnostics.currentVideoFrameRate)) / \(String(format: "%.1f", diagnostics.nominalVideoFrameRate)) fps\n累计丢帧: \(diagnostics.droppedVideoFrames)（最近 \(String(format: "%.1f", diagnostics.droppedFramesPerSecond)) 帧/秒）\n实际下载码率: \(observed)\n平均视频码率: \(averageVideo)\n缓冲: \(String(format: "%.1f", diagnostics.bufferSeconds)) 秒\n卡顿: \(diagnostics.stallCount) 次\n播放状态: \(diagnostics.timeControlStatus)\n等待原因: \(diagnostics.waitingReason)\n缓冲可持续: \(diagnostics.isLikelyToKeepUp ? "是" : "否")\n解码: \(diagnostics.hwdecActive ? "硬解" : "软解/未知")  缓存速度: \(String(format: "%.0f", diagnostics.cacheSpeedKBps)) KB/s  中止标志: \(diagnostics.playbackAborted ? "是" : "否")\n诊断判断: \(diagnostics.assessment)\n最近状态: \(diagnostics.reason.isEmpty ? "未知" : diagnostics.reason)"
        let log = mpvEngine.logTailText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !log.isEmpty {
            summary += "\nmpv 日志（最近 30 条）:\n\(log)"
        }
        return summary
    }

    var onError: (() -> Void)?
    var onReady: (() -> Void)?
    var onStartupTimeout: (() -> Void)?
    /// 网速过低/无数据触发换线
    var onLowSpeed: ((String) -> Void)?

    /// 线路超时/卡顿/低速自动检测（设置可关，默认开）
    var lineTimeoutEnabled: Bool = true

    init() {
        setupCacheCleanup()
        mpvEngine.onPlaying = { [weak self] in
            self?.handleMPVPlaying()
        }
        mpvEngine.onError = { [weak self] reason in
            self?.handleMPVFailure(reason: reason)
        }
        mpvEngine.onStateChanged = { [weak self] state in
            guard let self, self.activeBackend == .mpv else { return }
            self.diagnostics.timeControlStatus = state
        }
        renderedObserver = NotificationCenter.default.addObserver(
            forName: .tvPlayerVideoRendered,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, self.activeBackend == .avPlayer,
                  let player = note.object as? AVPlayer, player === self.avPlayer,
                  !self.isReady else { return }
            self.reportReady()
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
        if let renderedObserver {
            NotificationCenter.default.removeObserver(renderedObserver)
        }
        if let avErrorObserver {
            NotificationCenter.default.removeObserver(avErrorObserver)
        }
        avItemStatusObserver?.invalidate()
        avTimeObserver?.invalidate()
        diagnosticsTask?.cancel()
        mpvStartupTask?.cancel()
        avStartupTask?.cancel()
        avDiagnosticsTask?.cancel()
        diagnosticsDismissTask?.cancel()
        cancellables.removeAll()
    }

    // MARK: - Public API

    func play(url: URL) {
        mpvStartupTask?.cancel()
        mpvStartupTask = nil
        avStartupTask?.cancel()
        avStartupTask = nil

        playToken += 1
        let token = playToken
        activePlayToken = token
        fallbackUsed = false
        resetState(for: token)
        currentURL = url
        currentURLString = url.absoluteString
        playStartedAt = Date()
        isReady = false
        isPlaying = true
        isSwitching = true
        lastValidSpeedSampleAt = .distantPast
        // 复位网速显示与差分测速状态：切换/新内核后立即归零，
        // 避免转圈下残留旧频道速度、或差分 guard 吃着旧流的累计字节而长期失效。
        observedSpeedKBps = 0
        lastAVTotalBytes = 0
        lastAVSampleTime = .distantPast
        // 复位多信号健康态：新线路必须重新确认「声画流动」才关闭加载窗口
        isPlaybackHealthy = false
        healthyEverEstablished = false
        healthyConsecutivePulses = 0
        // 复位慢线证据：新线路从零开始，必须重新确认是否「曾达标」与是否停滞
        hasSeenHealthySpeed = false
        slowLineEvidenceStartedAt = nil

        if Self.requiresMPV(url) {
            // 已知 AVPlayer 无法处理：直接 mpv，不再先试 AVPlayer
            fallbackUsed = true
            startMPV(url: url, token: token, asFallback: false)
            return
        }
        startAVPlayer(url: url, token: token)
    }

    // MARK: - AVPlayer 主内核

    private func startAVPlayer(url: URL, token: Int) {
        activeBackend = .avPlayer
        activeEngineName = "系统 AVPlayer"
        avRenderedConsecutive = 0
        diagnostics = PlaybackDiagnostics(
            bufferSeconds: Self.initialBufferSeconds,
            engineName: activeEngineName
        )

        guard let drawable = WindowVideoSurface.shared.showAVPlayer(avPlayer) else {
            diagnostics.reason = "播放窗口未就绪"
            finishFailure(reason: "播放窗口未就绪")
            return
        }
        _ = drawable

        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
            "AVURLAssetHTTPHeaderFieldsKey": [
                "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
            ],
        ])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = Self.initialBufferSeconds
        item.preferredPeakBitRate = 0
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        // 关键：直播首帧提速。automaticallyWaitsToMinimizeStalling = true 会让 AVPlayer
        // 等到缓冲积攒到 preferredForwardBufferDuration 才出首帧（点播合理、直播拖慢）。
        // 设为 false 后，一拿到首批数据（几百 ms）就立即开播——B站/YouTube 之所以
        // "转两圈就能播"，正是这类即时起播策略。弱网下的缓冲由快速换线逻辑兜底，
        // 首帧与流畅优先。
        avPlayer.automaticallyWaitsToMinimizeStalling = false
        avItem = item

        teardownAVObservers()
        avItemStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, self.activeBackend == .avPlayer, item === self.avItem else { return }
                if item.status == .failed {
                    self.handleAVPlayerFailure(reason: "AVPlayer 播放器报告错误：\(item.error?.localizedDescription ?? "未知")")
                }
            }
        }
        avTimeObserver = avPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, self.activeBackend == .avPlayer else { return }
                self.diagnostics.timeControlStatus = self.avStateText()
            }
        }
        avErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.activeBackend == .avPlayer else { return }
            self.handleAVPlayerFailure(reason: "AVPlayer 播放中断")
        }

        avPlayer.replaceCurrentItem(with: item)
        avPlayer.volume = requestedVolume
        avPlayer.isMuted = requestedVolume == 0
        avPlayer.play()
        startLiveDiagnostics(token: token)
        startAVDiagnostics(token: token)

        guard lineTimeoutEnabled else { return }
        let timeoutNs = Self.avPlayerStartupTimeoutNs
        avStartupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNs)
            guard let self, !Task.isCancelled, self.playToken == token,
                  self.activeBackend == .avPlayer, !self.isReady else { return }
            self.handleAVPlayerFailure(reason: "AVPlayer 起播超过 \(timeoutNs / 1_000_000_000) 秒")
        }
    }

    private func avStateText() -> String {
        switch avPlayer.timeControlStatus {
        case .playing: return "播放中"
        case .waitingToPlayAtSpecifiedRate: return "缓冲中"
        case .paused: return "暂停"
        @unknown default: return "未知"
        }
    }

    /// AVPlayer 明确失败：回退 mpv 一次，再失败才换线
    private func handleAVPlayerFailure(reason: String) {
        guard playToken == activePlayToken, activeBackend == .avPlayer else { return }
        if !fallbackUsed, let url = currentURL, !Self.requiresMPV(url) {
            fallbackUsed = true
            startMPV(url: url, token: playToken, asFallback: true)
            return
        }
        finishFailure(reason: reason)
    }

    private func teardownAVObservers() {
        avItemStatusObserver?.invalidate()
        avItemStatusObserver = nil
        avTimeObserver?.invalidate()
        avTimeObserver = nil
        if let avErrorObserver {
            NotificationCenter.default.removeObserver(avErrorObserver)
        }
        avErrorObserver = nil
    }

    // MARK: - mpv 兜底内核

    private func startMPV(url: URL, token: Int, asFallback: Bool) {
        activeBackend = .mpv
        activeEngineName = "libmpv (MPVKit)"
        avStartupTask?.cancel()
        avStartupTask = nil
        // 取消 AVPlayer 分支的 0.5s 采样循环：mpv 阶段不需要它，否则残留一个
        // 每 0.5s 触发、仅因 activeBackend != .avPlayer 就立即 return 的空转任务。
        avDiagnosticsTask?.cancel()
        avDiagnosticsTask = nil
        teardownAVObservers()
        avPlayer.replaceCurrentItem(with: nil)

        guard let drawable = WindowVideoSurface.shared.showMPV() else {
            finishFailure(reason: "播放窗口未就绪")
            return
        }

        let profile = Self.bufferProfile(for: url)
        diagnostics = PlaybackDiagnostics(
            bufferSeconds: profile.initial,
            engineName: activeEngineName,
            reason: asFallback ? "AVPlayer 起播失败，已自动回退 mpv" : ""
        )
        mpvEngine.play(
            url: url,
            drawable: drawable,
            volume: requestedVolume,
            softwareDecode: Self.requiresMPV(url)
        )
        startLiveDiagnostics(token: token)

        guard lineTimeoutEnabled else { return }
        let timeoutNs = Self.startupTimeoutNs(for: url)
        mpvStartupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNs)
            guard let self, !Task.isCancelled, self.playToken == token,
                  self.activeBackend == .mpv, !self.isReady else { return }
            self.finishFailure(reason: "mpv 起播超过 \(timeoutNs / 1_000_000_000) 秒")
        }
    }

    private func handleMPVPlaying() {
        guard playToken == activePlayToken, activeBackend == .mpv else { return }
        reportReady()
    }

    private func handleMPVFailure(reason: String) {
        guard playToken == activePlayToken, activeBackend == .mpv else { return }
        finishFailure(reason: reason)
    }

    /// 统一失败出口：mpv 已用尽 / mpv 自身失败 → 通知上层换线
    private func finishFailure(reason: String) {
        mpvStartupTask?.cancel()
        mpvStartupTask = nil
        avStartupTask?.cancel()
        avStartupTask = nil
        diagnostics.reason = reason
        recordFailureOnce()
        isSwitching = false
        // 失败即中止本次线路的健康态，避免残留健康标记影响下一次起播
        isPlaybackHealthy = false
        healthyEverEstablished = false
        healthyConsecutivePulses = 0
        hasSeenHealthySpeed = false
        slowLineEvidenceStartedAt = nil
        if isReady {
            onError?()
        } else {
            onStartupTimeout?()
        }
    }

    private func reportReady() {
        mpvStartupTask?.cancel()
        mpvStartupTask = nil
        avStartupTask?.cancel()
        avStartupTask = nil
        isPlaying = true
        guard !isReady else { return }
        isReady = true
        // 加载窗口由多信号健康确认（isPlaybackHealthy）决定何时消失；
        // isSwitching 此时保持 true，直到健康达标才清（见 evaluatePlaybackHealth）。

        diagnostics.timeControlStatus = "播放中"
        diagnostics.waitingReason = "无"
        diagnostics.isBufferEmpty = false
        diagnostics.reason = activeBackend == .avPlayer ? "AVPlayer 已出画" : "mpv 已输出画面"
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
            // scheduleTask 内部已按 token 过滤，此处只需存活校验
            guard let self else { return }
            self.stallWatchEnabled = true
            if self.activeBackend == .mpv {
                self.startStallCheck(token: playToken)
            }
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
        if activeBackend == .mpv {
            mpvEngine.pause()
        } else {
            avPlayer.pause()
        }
        isPlaying = false
    }

    func resume() {
        guard hasCurrentMedia else { return }
        if activeBackend == .mpv {
            mpvEngine.resume()
        } else {
            avPlayer.play()
        }
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
            avStartupTask?.cancel()
            avStartupTask = nil
            stopStallCheck()
            cancelAllTasks()
        } else if !isReady, currentURL != nil {
            let token = playToken
            let timeoutNs = Self.startupTimeoutNs(for: currentURL!)
            if activeBackend == .mpv {
                mpvStartupTask?.cancel()
                mpvStartupTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNs)
                    guard let self, !Task.isCancelled, self.playToken == token,
                          self.activeBackend == .mpv, !self.isReady else { return }
                    self.finishFailure(reason: "mpv 起播超过 \(timeoutNs / 1_000_000_000) 秒")
                }
            } else {
                avStartupTask?.cancel()
                avStartupTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: Self.avPlayerStartupTimeoutNs)
                    guard let self, !Task.isCancelled, self.playToken == token,
                          self.activeBackend == .avPlayer, !self.isReady else { return }
                    self.handleAVPlayerFailure(reason: "AVPlayer 起播超过 \(Self.avPlayerStartupTimeoutNs / 1_000_000_000) 秒")
                }
            }
        }
    }

    func stop() {
        playToken += 1
        mpvStartupTask?.cancel()
        mpvStartupTask = nil
        avStartupTask?.cancel()
        avStartupTask = nil
        mpvEngine.stop()
        teardownAVObservers()
        avPlayer.replaceCurrentItem(with: nil)
        cancelAllTasks()
        stopStallCheck()
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        avDiagnosticsTask?.cancel()
        avDiagnosticsTask = nil
        diagnosticsDismissTask?.cancel()
        diagnosticsDismissTask = nil
        currentURL = nil
        isPlaying = false
        isReady = false
        isSwitching = false
        shouldShowDiagnostics = false
        stallWatchEnabled = false
        failureRecorded = false
        lastValidSpeedSampleAt = .distantPast
        observedSpeedKBps = 0
        // 复位多信号健康态
        isPlaybackHealthy = false
        healthyEverEstablished = false
        healthyConsecutivePulses = 0
        hasSeenHealthySpeed = false
        slowLineEvidenceStartedAt = nil
    }

    var volume: Float {
        get { requestedVolume }
        set {
            requestedVolume = max(0, min(1, newValue))
            if activeBackend == .mpv {
                mpvEngine.volume = requestedVolume
            } else {
                avPlayer.volume = requestedVolume
                avPlayer.isMuted = requestedVolume == 0
            }
        }
    }

    // MARK: - Private — State Management

    private func resetState(for token: Int) {
        mpvStartupTask?.cancel()
        mpvStartupTask = nil
        avStartupTask?.cancel()
        avStartupTask = nil
        cancelAllTasks()
        stopStallCheck()
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        avDiagnosticsTask?.cancel()
        avDiagnosticsTask = nil
        diagnosticsDismissTask?.cancel()
        diagnosticsDismissTask = nil
        recentStalls.removeAll()
        lastStallAt = .distantPast
        failureRecorded = false
        consecutiveBufferSeconds = 0
        lowSpeedReported = false
        avRenderedConsecutive = 0
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

    // MARK: - 播放中卡顿检测（mpv 后端）

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
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !Task.isCancelled, self.playToken == token else { return }
                self.refreshDiagnostics(reason: nil)
            }
        }
    }

    /// 直接显示原始网速（mpv cache-speed 已内部平滑，AVPlayer 取分片瞬时值），
    /// 连续 1.5s 无新数据才归零——不叠加额外 EMA，避免双重平滑导致滞后。
    private func updateSpeed(rawKBps: Double) {
        let now = Date()
        if rawKBps > 0 {
            observedSpeedKBps = rawKBps
            lastValidSpeedSampleAt = now
        } else if now.timeIntervalSince(lastValidSpeedSampleAt) > speedStaleTimeout {
            observedSpeedKBps = 0
        }
        // rawKBps==0 且未超时：保持上次值不变
    }

    /// 标记异常并短暂显示诊断浮层（即使设置里关闭了常驻浮层）。
    /// 仅「真实异常」触发：持续缓冲/无数据、解码丢帧明显、音画不同步等，
    /// 正常播放/稳定卡顿时不弹。自动隐藏由 diagnosticsDismissTask 调度。
    private func flagDiagnosticsForReason(_ reason: String?) {
        guard let reason, !reason.isEmpty else { return }
        let isAnomaly = reason.contains("卡顿") || reason.contains("缓冲")
            || reason.contains("无数据") || reason.contains("丢帧")
            || reason.contains("不足") || reason.contains("低帧")
            || reason.contains("同步") || reason.contains("错误")
            || reason.contains("中止") || reason.contains("失败")
        guard isAnomaly else { return }
        shouldShowDiagnostics = true
        diagnosticsDismissTask?.cancel()
        diagnosticsDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.shouldShowDiagnostics = false
        }
    }

    private func refreshDiagnostics(reason: String?) {
        flagDiagnosticsForReason(reason)
        // 每个采样拍评估多信号健康态（事件驱动，连续拍达标才关加载窗口）
        evaluatePlaybackHealth()
        if activeBackend == .mpv {
            let sample = mpvEngine.diagnosticsSample()
            // 实时下载速度：cache-speed = 缓存实时填充速率（KB/s），
            // demux bitrate 是长时间滑动均值，长分片源在分片下载间歇会掉到 0。
            updateSpeed(rawKBps: sample.cacheSpeedKBps)
            // 慢线硬指标：mpv 分支。起播与播放中都评估（0.5s 一拍），
            // 网络不达标持续 slowLineDuration 秒 → 切。声画在动则视为正常。
            let isProgressing = sample.hasVideoOutput && sample.stateText == "播放中"
            checkSlowLineEvidence(isProgressing: isProgressing)
            diagnostics = PlaybackDiagnostics(
                observedBitrate: observedSpeedKBps * 1024 * 8,
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
                audioVideoSyncDiff: sample.audioVideoSyncDiff,
                engineName: activeEngineName,
                reason: reason ?? diagnostics.reason
            )
        }
        // AVPlayer 分支的 diagnostics/网速由 sampleAVDiagnostics() 采样维护，此处无需处理。
    }

// MARK: - 多信号健康确认（事件驱动）

    /// 每个采样拍评估一次当前是否有「声画在流动」。多信号判定：
    /// - 画面：已确认出画且画面在流转（视频尺寸就绪 + 播放态）
    /// - 网络：采样网速 / mpv cache-speed > 0（资源在流动；分片间歇瞬时为 0
    ///   由 1.5s 滞留窗口容忍）
    /// - 声音：有音频轨且在动；纯视频流（无音轨）不因「无声」卡转圈
    ///
    /// 事件驱动而非计时：每拍（0.5s）真实重算，连续 healthyPulsesRequired 拍才宣布健康。
    /// 获得过一次健康后不再回退：同一线路已证明可播，之后卡顿交给 stall 检测换线，
    /// 转圈不再反复弹出。
    private func evaluatePlaybackHealth() {
        guard isReady, lineTimeoutEnabled, !healthyEverEstablished else { return }
        // 允许在 isSwitching 期间评估：加载窗口要在「声画流动」确认后才消失
        if isAudioVideoFlowing() {
            healthyConsecutivePulses += 1
            if healthyConsecutivePulses >= Self.healthyPulsesRequired {
                healthyEverEstablished = true
                isPlaybackHealthy = true
                // 健康确认：加载窗口随之关闭（isSwitching 语义回到「已就绪」）
                if isSwitching {
                    isSwitching = false
                }
            }
        } else {
            healthyConsecutivePulses = 0
        }
    }

    /// 当前采样拍是否「声画在流动、网络在动」。
    /// - AVPlayer：画面=视频轨存在且有尺寸+播放中（纯音频流则仅要求播放中）。
    ///   声音=有音频轨且缓冲未空；网络由「播放中 + 缓冲充足」隐含（分片间隙
    ///   差分网速会瞬时为 0，仅靠网速判断会把好线误判为不健康）
    /// - mpv：画面=hasVideoOutput 且帧率可读；声音=audio-pts 前进（纯视频流跳过）；
    ///   网络=cache-speed>0 或采样网速>0（mpv 的 cache-speed 是平滑值，抖动小）
    func isAudioVideoFlowing() -> Bool {
        if activeBackend == .mpv {
            let sample = mpvEngine.diagnosticsSample()
            let videoOK = sample.hasVideoOutput
                && (sample.outputFrameRate > 0 || sample.nominalFrameRate > 0)
            let networkOK = sample.cacheSpeedKBps > 0 || observedSpeedKBps > 0
            let audioOK = sample.hasAudioProgress || !sample.hasAudioCapability
            return videoOK && networkOK && audioOK
        } else {
            guard let item = avItem else { return false }
            let state = avStateText()
            let hasVideoTrack = item.tracks.contains { $0.assetTrack?.mediaType == .video }
            let hasAudioTrack = item.tracks.contains { $0.assetTrack?.mediaType == .audio }
            let hasVideo = item.presentationSize.width > 1 && item.presentationSize.height > 1
            let playing = state == "播放中" && item.isPlaybackLikelyToKeepUp
            let videoOK = hasVideoTrack ? (hasVideo && playing) : playing
            let audioOK = hasAudioTrack ? !item.isPlaybackBufferEmpty : true
            // 网络流动由「播放中 + 缓冲充足」隐含，不再单独要求差分网速>0
            return videoOK && audioOK
        }
    }

    private func startAVDiagnostics(token: Int) {
        avDiagnosticsTask?.cancel()
        avDiagnosticsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !Task.isCancelled, self.playToken == token,
                      self.activeBackend == .avPlayer else { return }
                self.sampleAVDiagnostics()
            }
        }
    }

    // MARK: - 慢线硬指标（卡住 + 低速 → 快速换线）

/// 网络门控的慢线判定：源的网络不达标才累计停滞，达标则重置继续等。
    /// 这是「死链 vs 慢源」的核心区分——网络在流动（≥阈值）说明源还活着，
    /// 愿意等它起播/恢复；网络停滞（<阈值，含死链 0 字节）持续 slowLineDuration
    /// 秒就切——起播阶段同样生效（死链、被墙源无需等 15s 上限，3s 即走）。
    /// 每次 play() / 出画会复位证据起点。
    private func checkSlowLineEvidence(isProgressing: Bool) {
        guard lineTimeoutEnabled, !lowSpeedReported else {
            slowLineEvidenceStartedAt = nil
            return
        }
        let speed = observedSpeedKBps
        // 网络达标（≥200KB/s）：源在传数据，重置停滞计时继续等——不误杀慢源
        if speed >= Self.slowLineSpeedThresholdKBps {
            hasSeenHealthySpeed = true
            slowLineEvidenceStartedAt = nil
            return
        }
        // 起播就未达标（速度从未 ≥200）：只要停滞即按死线快速切，不拖到 15s 上限
        if !hasSeenHealthySpeed {
            if slowLineEvidenceStartedAt == nil {
                slowLineEvidenceStartedAt = Date()
            }
            if let start = slowLineEvidenceStartedAt,
               Date().timeIntervalSince(start) >= Self.slowLineDurationSeconds, !isProgressing {
                lowSpeedReported = true
                slowLineEvidenceStartedAt = nil
                onLowSpeed?("线路网速不足 \(Int(Self.slowLineSpeedThresholdKBps))KB/s，自动换线")
            }
            return
        }
        // 已达标过一次（源确实在传）：落速停滞 slowLineDuration 且声画无进展 → 切
        if slowLineEvidenceStartedAt == nil {
            slowLineEvidenceStartedAt = Date()
        }
        guard let start = slowLineEvidenceStartedAt else { return }
        if Date().timeIntervalSince(start) >= Self.slowLineDurationSeconds && !isProgressing {
            lowSpeedReported = true
            slowLineEvidenceStartedAt = nil
            onLowSpeed?("线路网速不足 \(Int(Self.slowLineSpeedThresholdKBps))KB/s，自动换线")
        }
    }

    private func sampleAVDiagnostics() {
        guard let item = avItem else { return }
        let log = item.accessLog()
        let event = log?.events.last
        // 实时网速：对 AVPlayer 的累计已传输字节数做差分（本次采样 - 上次采样）/ 时间差。
        // 这才是真正的「瞬时」下载速度；而 event.transferDuration / numberOfBytesTransferred
        // 是从分片开始到现在的累计均值，直播中网络一波动该均值几乎不动，导致网速「不实时」。
        let totalBytes = Double(event?.numberOfBytesTransferred ?? 0)
        let now = Date()
        var instantKBps = 0.0
        if totalBytes >= Double(lastAVTotalBytes), lastAVSampleTime != .distantPast {
            let dt = now.timeIntervalSince(lastAVSampleTime)
            let dBytes = totalBytes - Double(lastAVTotalBytes)
            if dt > 0.05 && dBytes > 0 {
                instantKBps = dBytes / 1024 / dt
            }
        }
        lastAVTotalBytes = Int64(totalBytes)
        lastAVSampleTime = now
        // 分片边界重置累计计数器时（新分片字节数比上次小），退化为短窗均值兜底
        let transferDuration = event?.transferDuration ?? 0
        let shortAvgKBps = transferDuration > 0.05 && transferDuration < 5
            ? (Double(event?.numberOfBytesTransferred ?? 0)) / 1024 / transferDuration : 0
        let fallbackKBps = (event?.observedBitrate ?? 0) > 0 ? (event?.observedBitrate ?? 0) / 8 / 1024 : 0
        updateSpeed(rawKBps: instantKBps > 0 ? instantKBps : (shortAvgKBps > 0 ? shortAvgKBps : fallbackKBps))
        let bitrate = event?.indicatedBitrate ?? 0
        let size = item.presentationSize
        let ranges = item.loadedTimeRanges
        let bufferedEnd = ranges.compactMap { value -> TimeInterval? in
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(value.timeRangeValue))
            return end.isFinite ? end : nil
        }.max() ?? 0
        let current = CMTimeGetSeconds(item.currentTime())
        let buffered = max(0, bufferedEnd - (current.isFinite ? current : 0))
        let state = avStateText()
        let videoTrack = item.tracks.first { $0.assetTrack?.mediaType == .video }?.assetTrack

        diagnostics = PlaybackDiagnostics(
            observedBitrate: observedSpeedKBps * 1024 * 8,
            averageVideoBitrate: Double(bitrate),
            currentVideoFrameRate: 0,
            nominalVideoFrameRate: videoTrack.map { Double($0.nominalFrameRate) } ?? 0,
            droppedVideoFrames: 0,
            droppedFramesPerSecond: 0,
            videoWidth: Int(size.width),
            videoHeight: Int(size.height),
            stallCount: recentStalls.count,
            bufferSeconds: buffered,
            timeControlStatus: state,
            waitingReason: avPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate
                ? "AVPlayer 正在缓冲/等待数据" : "无",
            isLikelyToKeepUp: item.isPlaybackLikelyToKeepUp && state == "播放中",
            isBufferEmpty: item.isPlaybackBufferEmpty,
            playbackClockSeconds: current.isFinite ? current : 0,
            engineName: activeEngineName,
            reason: diagnostics.reason
        )

        // 起播兜底：视频尺寸就绪 + 播放中（连续两次采样）
        if item.status == .readyToPlay, state == "播放中",
           size.width > 1, size.height > 1 {
            avRenderedConsecutive += 1
            if avRenderedConsecutive >= 2, !isReady {
                reportReady()
            }
        } else {
            avRenderedConsecutive = 0
        }

        // 卡顿/无数据
        // 出画保护期（readyProtect 4s）内不判定缓冲型软问题：与 mpv 分支一致，
        // 否则 AVPlayer 起播成功后 4 秒内的一次短暂抖动就会累计触发 onLowSpeed
        // 把刚出画的线路立刻换走（此前无门控，保护只对 mpv 生效）。
        if stallWatchEnabled, item.isPlaybackBufferEmpty || state == "缓冲中" {
            registerStall()
            consecutiveBufferSeconds += 1
            if consecutiveBufferSeconds >= Self.progressStallThreshold, !lowSpeedReported {
                lowSpeedReported = true
                onLowSpeed?("持续缓冲无数据，自动换线")
            }
        } else {
            consecutiveBufferSeconds = 0
            lowSpeedReported = false
        }
        // 慢线硬指标：AVPlayer 分支，卡住 + 网速过低 → 3s 快速换线
        let progressing = state == "播放中"
            && !item.isPlaybackBufferEmpty
            && size.width > 1 && size.height > 1
        checkSlowLineEvidence(isProgressing: progressing)
        // 多信号健康态评估（AVPlayer 分支同样事件驱动）
        evaluatePlaybackHealth()
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
    /// mpv 缓存读取速度（KB/s），>0 说明网络在流动、卡的是解码/渲染
    var cacheSpeedKBps: Double
    /// mpv 硬解是否实际生效
    var hwdecActive: Bool
    /// mpv playback-abort 中止标志
    var playbackAborted: Bool

    var resolutionText: String {
        videoWidth > 0 && videoHeight > 0 ? "\(videoWidth)×\(videoHeight)" : "未知"
    }

    var assessment: String {
        if engineName.lowercased().contains("mpv") {
            if timeControlStatus == "错误" {
                return "mpv 解码或媒体错误"
            }
            if timeControlStatus == "正在打开" {
                if playbackAborted {
                    return "mpv 已中止：致命错误"
                }
                if cacheSpeedKBps > 0 {
                    return "网络在流动，卡在解码/渲染（已按隔行源启用软解）"
                }
                return "mpv 正在建立直播缓冲（网络暂未取得数据）"
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
        reason: String = "",
        cacheSpeedKBps: Double = 0,
        hwdecActive: Bool = false,
        playbackAborted: Bool = false
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
        self.cacheSpeedKBps = cacheSpeedKBps
        self.hwdecActive = hwdecActive
        self.playbackAborted = playbackAborted
    }
}
