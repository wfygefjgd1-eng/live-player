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
    static let startupHardTimeoutNs: UInt64 = 12_000_000_000
    /// 出画后保护：此期间禁止因软问题换线
    static let readyProtectNs: UInt64 = 4_000_000_000
    /// 连续缓冲卡顿阈值（秒）：画面冻结累计这么久才确认卡顿。原 12s 太保守——
    /// 配合旧网速门（网速>0即判流动）导致卡断也不切。缩到 6s：激进但仍有防误切余量。
    static let progressStallThreshold: TimeInterval = 6.0

    /// 内核差异化超时：官方 AVPlayer 原生快，少等（20s）；mpv 需多等（35s）；
    /// 慢 HLS 长分片源（如 264788）单独放宽（50s）。避免「固定短超时」误砍慢内核。
    static let mpvStartupTimeoutNs: UInt64 = 35_000_000_000
    static let mpvSlowSourceTimeoutNs: UInt64 = 50_000_000_000
    /// AVPlayer 起播超时（官方内核最快；20s 足够，不必赔慢）
    static let avPlayerStartupTimeoutNs: UInt64 = 20_000_000_000

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
    /// 30 秒无声无画兜底看门狗
    private var silentStallTask: Task<Void, Never>?
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

    /// 最近一次有效网速采样的时间：超时（1.5s 无新数据）即归零，避免显示过期速度。
    /// 太短会因直播分片间隙抖动闪烁，太长会掩盖断网；0.5s 采样 × 3 拍为界。
    private var lastValidSpeedSampleAt: Date = .distantPast
    private let speedStaleTimeout: TimeInterval = 1.5

    /// 切台最小展示时长：防止快速源出画太快导致转圈一闪而过
    private var switchStartedAt: Date = .distantPast
    static let minSwitchDisplayTime: TimeInterval = 0.8

    /// AVPlayer 累计字节追踪（用于计算真实瞬时下载速度）
    private var lastAVTotalBytes: Int64 = 0
    private var lastAVSampleTime: Date = .distantPast

    @Published var isReady = false
    @Published var isPlaying = false
    /// 正在切台/切线路（起播中未出画）：UI 显示「正在切换」反馈
    @Published private(set) var isSwitching = false
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
    /// 30 秒无声无画面的兜底通知：Viewer 用于重新弹出「开启自动切换」按钮
    var onSilentStall30s: (() -> Void)?

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
        silentStallTask?.cancel()
        cancellables.removeAll()
    }

    // MARK: - Public API

    func play(url: URL) {
        mpvStartupTask?.cancel()
        mpvStartupTask = nil
        avStartupTask?.cancel()
        avStartupTask = nil
        // 切台前必须完全停止旧后端，否则会出现「双声」：上一频道的声音仍在后台播放。
        // play() 是切换的统一入口（切台/切线路/自动换线都走这里），在此一次性停干净：
        // - mpv：stop() 命令停止解复用与渲染
        // - AVPlayer：pause + 清空 item（释放当前渲染/解码资源）
        // 之后再启动新源，保证声音与画面都完全切到新的。
        stopCurrentEngine()
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
        switchStartedAt = Date()
        lastValidSpeedSampleAt = .distantPast
        // 复位网速显示与差分测速状态：切换/新内核后立即归零，
        // 避免转圈下残留旧频道速度、或差分 guard 吃着旧流的累计字节而长期失效。
        observedSpeedKBps = 0
        lastAVTotalBytes = 0
        lastAVSampleTime = .distantPast
        // 启动 30 秒无声无画兜底看门狗（出画后 reportReady 会取消）
        startSilentStallWatchdog()

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
        // 等待视频在线可用，避免网络抖动时丢视频帧保音频 →「声音流畅、画面幻灯片」
        avPlayer.automaticallyWaitsToMinimizeStalling = true
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
        // 已出画，取消 30s 兜底看门狗
        cancelSilentStallWatchdog()
        isPlaying = true
        guard !isReady else { return }
        isReady = true
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

        // 「正在加载/转圈」与提示的消失跟随声画真实流动，而非固定 0.8s。
        // 至少展示 minSwitchDisplayTime（快速源一闪而过要让用户看清频道），
        // 之后持续轮询 isAudioVideoFlowing()：声画免疫瞬时缓冲抖动，确认稳定流动
        // 才关闭转圈并回调 onReady（上层据此清除「正在加载」提示）。
        // 用 playToken 守卫：窗口内又切到新台则作废，不得误关新台反馈。
        let elapsed = Date().timeIntervalSince(switchStartedAt)
        let minimumDisplay = max(0, Self.minSwitchDisplayTime - elapsed)
        let token = playToken
        let backend = activeBackend
        let fireOnReady = { [weak self] in
            self?.onReady?()
            WindowVideoSurface.shared.rebindPlayer()
            self?.stallWatchEnabled = false
            self?.scheduleTask(named: "readyProtect", token: token, timeout: Self.readyProtectNs) {
                guard let self else { return }
                self.stallWatchEnabled = true
                if self.activeBackend == .mpv {
                    self.startStallCheck(token: token)
                }
            }
        }
        Task { @MainActor [weak self] in
            if minimumDisplay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(minimumDisplay * 1_000_000_000))
            }
            guard let self, !Task.isCancelled, self.playToken == token,
                  self.activeBackend == backend else { return }
            // 声画流动确认。轮询带硬上限：超时（约 8s）也不得让转圈永久挂着，
            // 强制转出并触发 onReady；若真的坏线，将由上层 onStartupTimeout / 静音
            // 看门狗继续换线兜底。250ms × 32 ≈ 8s。
            var attempts = 0
            while !Task.isCancelled, self.playToken == token, attempts < 32 {
                if self.isAudioVideoFlowing() {
                    self.isSwitching = false
                    fireOnReady()
                    return
                }
                attempts += 1
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            self.isSwitching = false
            fireOnReady()
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

    /// 当前是否有「声画在流动」。（Viewer 用于自动换线前的复核：若仍正常播放则取消误切）
    /// 判定看「画面/声音实际在动」，不再以网速>0 当流动证据：
    /// 卡顿时（源仍传数据、网速>0）画面冻结，若用网速判定会误判为「正常流动」→ 永不切换。
    /// - AVPlayer：缓冲充足且可播放（isPlaybackLikelyToKeepUp），画面尺寸就绪，非暂停
    /// - mpv：已出画 + 未 paused-for-cache（缓存有数据）
    func isAudioVideoFlowing() -> Bool {
        guard isReady else { return false }
        if activeBackend == .mpv {
            let sample = mpvEngine.diagnosticsSample()
            // mpv 卡顿的直接证据是 paused-for-cache（画面暂停等缓存）：
            // 只要在缓冲中就不算流动，即使缓存里有数据（解码跟不上也卡）。
            return sample.hasVideoOutput
                && sample.width > 0 && sample.height > 0
                && sample.stateText != "缓冲中"
        } else {
            guard let item = avItem else { return false }
            let size = item.presentationSize
            let state = avStateText()
            // 画面尺寸就绪 + 非暂停（缓冲中/播放中皆可）
            guard size.width > 1, size.height > 1, state != "暂停" else { return false }
            // 缓冲充足且可播放 = 画面实际在推进；不把网速>0 当流动证据（卡顿时网速可能仍>0）
            return !item.isPlaybackBufferEmpty && item.isPlaybackLikelyToKeepUp
        }
    }

    /// 网速是否持续达标（≥ threshold KB/s）——「源还活着」的硬证据。
    /// 画面/声音可能瞬时抖动，但正在下载的字节数不会说谎：有持续网速=源在传=不该切。
    func isNetworkFlowing(aboveKBps threshold: Double) -> Bool {
        observedSpeedKBps >= threshold
    }

    /// 30 秒无声无画兜底：启动一个后台看门狗，若 30s 内声画一直未流动则回调。
    func startSilentStallWatchdog() {
        silentStallTask?.cancel()
        silentStallTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self, !Task.isCancelled, !self.isAudioVideoFlowing(), self.hasCurrentMedia else { return }
            self.onSilentStall30s?()
        }
    }

    func cancelSilentStallWatchdog() {
        silentStallTask?.cancel()
        silentStallTask = nil
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

    /// 完全停止当前内核的播放（无论 mpv 还是 AVPlayer），释放音频/画面资源。
    /// 切台/切线路必须调用，防止上一频道在后台继续出声（双声 bug）。
    private func stopCurrentEngine() {
        // 停止 mpv（若正在使用）
        mpvEngine.stop()
        // 停止 AVPlayer：暂停并清空 item，释放渲染/解码
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        teardownAVObservers()
        // 清理诊断采样循环
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        avDiagnosticsTask?.cancel()
        avDiagnosticsTask = nil
        diagnosticsDismissTask?.cancel()
        diagnosticsDismissTask = nil
        stopStallCheck()
        cancelAllTasks()
        avRenderedConsecutive = 0
    }

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
        if activeBackend == .mpv {
            let sample = mpvEngine.diagnosticsSample()
            // 实时下载速度：cache-speed = 缓存实时填充速率（KB/s），
            // demux bitrate 是长时间滑动均值，长分片源在分片下载间歇会掉到 0。
            updateSpeed(rawKBps: sample.cacheSpeedKBps)
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
                engineName: activeEngineName,
                reason: reason ?? diagnostics.reason
            )
        }
        // AVPlayer 分支的 diagnostics/网速由 sampleAVDiagnostics() 采样维护，此处无需处理。
    }

    // MARK: - AVPlayer 轻量采样（0.5s，主线程安全）

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
        if item.isPlaybackBufferEmpty || state == "缓冲中" {
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
