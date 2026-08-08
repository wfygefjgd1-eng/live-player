import SwiftUI
import AVKit
import UIKit

/// SwiftUI 叠层：透明，画面在 UIKit root 底层
/// - 仅浮动 OSD/提示抬高
/// - 手势与频道面板仍在此层
struct ContentView: View {
    @EnvironmentObject private var vm: PlayerViewModel

    @State private var numberInput = ""
    @State private var numberInputTask: Task<Void, Never>?
    @State private var singleTapTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            // 透明：露出 root 底层 mpv 画面
            Color.clear
                .ignoresSafeArea()

            // 透明占位：画面在 UIKit root 底层（mpv 直接渲染到 Metal 图层）
            VideoPlayerView()
                .frame(width: 0, height: 0)
                .opacity(0)
                .allowsHitTesting(false)

            Color.clear
                .contentShape(Rectangle())
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .ignoresSafeArea()
                .highPriorityGesture(playerDragGesture())
                .simultaneousGesture(longPressGesture())
                .simultaneousGesture(doubleTapGesture())
                .simultaneousGesture(singleTapGesture())
                .zIndex(2)

            floatingChrome()
                .zIndex(5)

            // 自动切换提示弹窗（唯一）：独立顶层，弹窗可见时拦截底层 tap（暂停让路）
            if let prompt = vm.autoSwitchPrompt {
                // 全屏透明拦击层：接住所有 tap（含按钮周围空白），
                // 高优先级保证底层的「单击暂停」手势在此绕路，不误触暂停
                Color.clear
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .highPriorityGesture(
                        TapGesture().onEnded {
                            // 空操作：吞掉 tap，避免触发暂停；按钮自身的点击仍由按钮接收
                        }
                    )
                    .zIndex(8)

                AutoSwitchPromptView(
                    message: prompt.message,
                    kind: prompt.kind,
                    onClose: { vm.handleCloseAutoSwitch() },
                    onEnable: { vm.handleEnableAutoSwitch() }
                )
                .zIndex(9)
            }

            if vm.playbackPaused && !vm.panelVisible {
                Button {
                    vm.resume()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 76, height: 76)
                        .background(Color.black.opacity(0.62))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("恢复播放")
                .zIndex(6)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .ignoresSafeArea()
        .background(Color.clear)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .onAppear {
            vm.startup()
            WindowVideoSurface.shared.rebindPlayer()
            refreshImmersiveChrome()
            WindowPanelSurface.shared.setPanel(
                AnyView(
                    ChannelListPanel(onShowSettings: {
                        vm.panelVisible = false
                        WindowPanelSurface.shared.prepareForModalPresentation()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            vm.showSourceSheet = true
                        }
                    })
                    .environmentObject(vm)
                ),
                viewModel: vm
            )
        }
        .onChange(of: vm.panelVisible) { visible in
            if visible { WindowPanelSurface.shared.show() }
            else { WindowPanelSurface.shared.hide() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelShouldClose)) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                vm.panelVisible = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            cancelNumberInput()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tvPlayerRemotePlay)) { _ in vm.resume() }
        .onReceive(NotificationCenter.default.publisher(for: .tvPlayerRemotePause)) { _ in vm.pause() }
        .onReceive(NotificationCenter.default.publisher(for: .tvPlayerRemoteNext)) { _ in vm.nextChannel() }
        .onReceive(NotificationCenter.default.publisher(for: .tvPlayerRemotePrevious)) { _ in vm.prevChannel() }
        .onReceive(NotificationCenter.default.publisher(for: .tvPlayerInterruptionBegan)) { _ in
            vm.noteInterruptionBegan()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tvPlayerInterruptionEnded)) { note in
            let shouldResume = (note.userInfo?["shouldResume"] as? Bool) ?? true
            vm.noteInterruptionEnded(shouldResume: shouldResume)
        }
        .onDisappear {
            singleTapTask?.cancel()
        }
        .sheet(isPresented: $vm.showSourceSheet) {
            SourceManagementSheet().environmentObject(vm)
        }
        .then { base in
            if #available(iOS 17.0, *) {
                AnyView(base.onKeyPress { press in handleKeyPress(press) })
            } else {
                AnyView(base)
            }
        }
    }

    /// 仅浮动 UI 抬高；等价 Flutter MediaQuery.padding.bottom
    @ViewBuilder
    private func floatingChrome() -> some View {
        GeometryReader { geo in
            // 容器已强制 insets=0；OSD 用系统值或横屏兜底，避免贴边
            let bottom = max(geo.safeAreaInsets.bottom, 21)
            let top = max(geo.safeAreaInsets.top, 12)

            ZStack {
                if vm.isBootstrapping {
                    VStack(spacing: 10) {
                        ProgressView().progressViewStyle(.circular).tint(.white)
                        Text(vm.bootstrapMessage)
                            .foregroundColor(.white.opacity(0.9))
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                    }
                    .padding(20)
                    .background(Color.black.opacity(0.55))
                    .cornerRadius(12)
                } else if vm.channels.isEmpty {
                    VStack(spacing: 12) {
                        Text("暂无频道").foregroundColor(.white)
                        Button("重新加载源") { vm.retryLoadSources() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(24)
                    .background(Color.black.opacity(0.55))
                    .cornerRadius(12)
                }

                VStack {
                    ChannelOSDView(text: vm.channelOSD)
                        .padding(.top, top + 4)
                    Spacer(minLength: 0)
                    if !vm.isBootstrapping {
                        IndicatorView(text: vm.indicatorText)
                            .padding(.bottom, bottom + 4)
                    }
                }
                .allowsHitTesting(false)

                // 左上角常驻状态区：网速恒显 + 加载/缓冲状态标识
                // 网速徽标已经直接 @ObservedObject 观察 PlayerEngine，0.5s 采样即时刷新。
                VStack(alignment: .leading, spacing: 6) {
                    // 网速永远显示（含切换/缓冲时）——黑屏时也能看到来源是否在动
                    HStack {
                        NetworkSpeedBadge(player: vm.player)
                        Spacer(minLength: 0)
                    }
                    // 状态行：加载中 / 缓冲中 —— 切台黑屏时用户能知道是加载还是卡了
                    HStack {
                        PlayerStatusBadge(player: vm.player)
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, top + 4)
                .padding(.leading, max(geo.safeAreaInsets.leading, 12) + 4)
                .allowsHitTesting(false)      // 纯状态展示，不拦截手势

                if vm.showDiagnosticsOverlay || vm.player.shouldShowDiagnostics {
                    VStack {
                        HStack {
                            Spacer(minLength: 0)
                            PlaybackDiagnosticsOverlay(player: vm.player)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, top + 8)
                    .padding(.trailing, max(geo.safeAreaInsets.trailing, 12) + 8)
                    .allowsHitTesting(false)
                }

                if !numberInput.isEmpty {
                    VStack {
                        Spacer()
                        Text(numberInput)
                            .font(.system(size: 60, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(16)
                        Text("按数字键选台")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                        Spacer().frame(height: bottom + 16)
                    }
                    .allowsHitTesting(false)
                }

                // 自动切换提示弹窗已移到 body 顶层（见 ContentView body），与此处分离，
                // 避免被 floatingChrome 的 allowsHitTesting(false) 吞掉点击。
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func refreshImmersiveChrome() {
        guard let root = (UIApplication.shared.delegate as? AppDelegate)?.window?.rootViewController else { return }
        root.setNeedsUpdateOfHomeIndicatorAutoHidden()
        root.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        root.setNeedsStatusBarAppearanceUpdate()
        (root as? FullScreenRootController)?.refreshSystemChrome()
    }

    /// 播放状态徽标（左上角）：切台=「正在加载中」，否则若缓冲中=「正在缓冲中」。
    /// 让用户在黑屏/切台时明确知道是加载、缓冲，还是来源真卡了（配合网速标识判断）。
    private struct PlayerStatusBadge: View {
        @ObservedObject var player: PlayerEngine

        var body: some View {
            if let label = statusText {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.6))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                .allowsHitTesting(false)
            }
        }

        /// nil = 无需要提示的状态；否则返回显示文案。
        /// 优先「正在加载」（切台/起播），其次「正在缓冲」（播放中卡顿无新进度）。
        private var statusText: String? {
            if player.isSwitching { return "正在加载" }
            let t = player.diagnostics.timeControlStatus
            if t == "缓冲中" { return "正在缓冲" }
            // 起播阶段尚未出画（正在打开）
            if t == "正在打开" && !player.isReady { return "正在加载" }
            return nil
        }
    }

    /// 自动切换提示弹窗（唯一，居中偏上）。含关闭/开启按钮。
    /// 消失机制：下一条线路画面/声音出来后由 onPlayerReady 清空 autoSwitchPrompt。
    /// OK 键（keyboard/遥控）在弹窗显示时优先响应按钮（见 handleKeyPress），
    /// 弹窗不存在时 OK 键保留暂停/恢复画面功能。
    private struct AutoSwitchPromptView: View {
        let message: String
        let kind: AutoSwitchPrompt.Kind
        let onClose: () -> Void
        let onEnable: () -> Void

        var body: some View {
            VStack(spacing: 14) {
                Text(message)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    switch kind {
                    case .offerCloseAutoSwitch:
                        Button {
                            onClose()
                        } label: {
                            Text("关闭自动切换")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.orange.opacity(0.85))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    case .offerEnableAutoSwitch:
                        Button {
                            onEnable()
                        } label: {
                            Text("开启自动切换")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.orange.opacity(0.85))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color.black.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.25), lineWidth: 0.6)
            )
            .padding(.top, 24)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.2), value: message)
        }
    }

    private func longPressGesture() -> some Gesture {
        // 识别成功即切换一次；勿与抬手二次命中遮罩冲突（遮罩有短暂忽略）
        LongPressGesture(minimumDuration: 0.4, maximumDistance: 12)
            .onEnded { _ in
                let open = !vm.panelVisible
                vm.panelVisible = open
                if open {
                    WindowPanelSurface.shared.show()
                } else {
                    WindowPanelSurface.shared.hide()
                }
            }
    }

    private func playerDragGesture() -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard !vm.panelVisible else { return }
                let w = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height, 1)
                let sx = value.startLocation.x
                let dy = value.translation.height
                let dx = value.translation.width
                if sx > w * 0.65 {
                    if abs(dy) > abs(dx) {
                        vm.handleVolumeDrag(translationHeight: dy, ended: false)
                    }
                    return
                }
            }
            .onEnded { value in
                guard !vm.panelVisible else { return }
                let w = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height, 1)
                let sx = value.startLocation.x
                let dx = value.translation.width
                let dy = value.translation.height
                if sx > w * 0.65 {
                    vm.handleVolumeDrag(translationHeight: dy, ended: true)
                    return
                }
                if abs(dx) > abs(dy) && abs(dx) > 50 {
                    // 从右往左滑 = 下一线路（1→2），从左往右滑 = 上一线路
                    if dx < 0 { vm.switchSource(direction: 1) }
                    else { vm.switchSource(direction: -1) }
                    return
                }
                if abs(dy) > abs(dx) && abs(dy) > 36, sx <= w * 0.65 {
                    // 从下往上滑（dy<0）= 下一频道（1→2），从上往下滑 = 上一频道
                    if dy < 0 { vm.nextChannel() } else { vm.prevChannel() }
                }
            }
    }

    private func doubleTapGesture() -> some Gesture {
        TapGesture(count: 2).onEnded {
            singleTapTask?.cancel()
            let open = !vm.panelVisible
            vm.panelVisible = open
            if open {
                WindowPanelSurface.shared.show()
            } else {
                WindowPanelSurface.shared.hide()
            }
        }
    }

    private func singleTapGesture() -> some Gesture {
        TapGesture(count: 1).onEnded {
            // 给双击识别留出短暂窗口，避免双击打开面板后又被单击暂停。
            singleTapTask?.cancel()
            singleTapTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 280_000_000)
                guard !Task.isCancelled, !vm.panelVisible else { return }
                if vm.player.isPlaying { vm.pause() } else { vm.resume() }
            }
        }
    }

    @available(iOS 17.0, *)
    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard !vm.panelVisible else { return .ignored }
        if let digit = press.characters.first(where: \.isNumber) {
            appendNumber(digit)
            return .handled
        }
        if press.key == .return {
            // 弹窗可见时，OK 键优先响应弹窗按钮（关闭/开启自动切换）
            if let prompt = vm.autoSwitchPrompt {
                switch prompt.kind {
                case .offerCloseAutoSwitch:
                    vm.handleCloseAutoSwitch()
                case .offerEnableAutoSwitch:
                    vm.handleEnableAutoSwitch()
                }
                return .handled
            }
            confirmNumberInput()
            return .handled
        }
        if press.key == .escape { cancelNumberInput(); return .handled }
        if press.key == .delete, !numberInput.isEmpty {
            numberInput.removeLast()
            if numberInput.isEmpty { cancelNumberInput() }
            return .handled
        }
        if press.key == .upArrow { vm.prevChannel(); return .handled }
        if press.key == .downArrow { vm.nextChannel(); return .handled }
        if press.key == .leftArrow { vm.switchSource(direction: -1); return .handled }
        if press.key == .rightArrow { vm.switchSource(direction: 1); return .handled }
        if press.characters == " " {
            if vm.player.isPlaying { vm.pause() } else { vm.resume() }
            return .handled
        }
        return .ignored
    }

    private func appendNumber(_ digit: Character) {
        numberInput.append(digit)
        numberInputTask?.cancel()
        numberInputTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { confirmNumberInput() }
        }
        if numberInput.count >= 4 { confirmNumberInput() }
    }

    private func confirmNumberInput() {
        guard let num = Int(numberInput), num > 0 else {
            cancelNumberInput()
            return
        }
        let index = num - 1
        if index < vm.channels.count {
            vm.selectChannel(vm.channels[index])
        } else if !vm.channels.isEmpty {
            vm.selectChannel(vm.channels[vm.channels.count - 1])
        }
        cancelNumberInput()
    }

    private func cancelNumberInput() {
        numberInput = ""
        numberInputTask?.cancel()
        numberInputTask = nil
    }
}

private struct NetworkSpeedBadge: View {
    @ObservedObject var player: PlayerEngine

    var body: some View {
        // 网速恒显：无论是否切换/缓冲/速度为 0，都显示（0 显示 --），
        // 让用户时刻知道来源在不在传数据。
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.55))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
    }

    private var text: String {
        if player.observedSpeedKBps >= 1024 {
            return String(format: "%.1f MB/s", player.observedSpeedKBps / 1024)
        }
        if player.observedSpeedKBps > 0 {
            return String(format: "%.0f KB/s", player.observedSpeedKBps)
        }
        return "--"
    }
}

private struct PlaybackDiagnosticsOverlay: View {
    @ObservedObject var player: PlayerEngine

    var body: some View {
        let d = player.diagnostics
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor(d))
                    .frame(width: 7, height: 7)
                Text("实时播放诊断")
                    .fontWeight(.semibold)
            }
            Text("内核 \(d.engineName)")
            Text("画面 \(d.resolutionText)  输出/源 \(fps(d.currentVideoFrameRate))/\(fps(d.nominalVideoFrameRate)) fps")
            Text("丢帧 \(d.droppedVideoFrames)  +\(String(format: "%.1f", d.droppedFramesPerSecond))/秒")
            Text("音画偏差 \(String(format: "%.3f", d.audioVideoSyncDiff)) 秒")
            Text("缓冲 \(String(format: "%.1f", d.bufferSeconds)) 秒  \(d.isLikelyToKeepUp ? "可持续" : "不足")")
            Text("下载 \(mbps(d.observedBitrate))  视频 \(mbps(d.averageVideoBitrate))")
            Text("状态 \(d.timeControlStatus)  卡顿 \(d.stallCount)  等待：\(d.waitingReason)")
            Text("判断：\(d.assessment)")
                .foregroundColor(statusColor(d))
                .fontWeight(.semibold)
        }
        .font(.system(size: 11, weight: .regular, design: .monospaced))
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
        )
    }

    private func fps(_ value: Double) -> String {
        value > 0 ? String(format: "%.1f", value) : "--"
    }

    private func mbps(_ value: Double) -> String {
        value > 0 ? String(format: "%.2fM", value / 1_000_000) : "--"
    }

    private func statusColor(_ d: PlaybackDiagnostics) -> Color {
        if d.assessment.contains("持续丢帧") || d.assessment.contains("明显偏低") {
            return .red
        }
        if d.assessment.contains("不足") || d.assessment.contains("检测到") {
            return .orange
        }
        if d.assessment.contains("正常") {
            return .green
        }
        return .yellow
    }
}

private extension View {
    @ViewBuilder
    func then<Content: View>(_ transform: (Self) -> Content) -> some View {
        transform(self)
    }
}
