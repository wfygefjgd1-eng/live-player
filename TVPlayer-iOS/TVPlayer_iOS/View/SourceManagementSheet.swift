import SwiftUI

struct SourceManagementSheet: View {
    @EnvironmentObject private var vm: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var inputUrl = ""
    @State private var showInvalidAlert = false

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    TextField("输入 m3u / m3u8 地址", text: $inputUrl)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(Capsule())
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .submitLabel(.done)
                        .onSubmit { add() }

                    Button {
                        pasteClipboard()
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .accessibilityLabel("粘贴剪贴板内容")

                    Button("添加") { add() }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .disabled(inputUrl.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 20)

                List {
                    Section {
                        Toggle(isOn: Binding(
                            get: { vm.lineTimeoutEnabled },
                            set: { vm.setLineTimeoutEnabled($0) }
                        )) {
                            HStack {
                                Image(systemName: "timer")
                                    .foregroundColor(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("自动切换线路")
                                    Text("线路确认失败后自动切换；每次切换会提醒，可在设置中关闭")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Toggle(isOn: Binding(
                            get: { vm.autoBlacklistEnabled },
                            set: { vm.setAutoBlacklistEnabled($0) }
                        )) {
                            HStack {
                                Image(systemName: "xmark.shield")
                                    .foregroundColor(.red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("失败线路黑名单")
                                    Text("失败线路临时排除，15分钟后自动恢复；换源后清空")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Toggle(isOn: Binding(
                            get: { vm.autoAdvanceOnExhaustion },
                            set: { vm.setAutoAdvanceOnExhaustion($0) }
                        )) {
                            HStack {
                                Image(systemName: "forward.end.fill")
                                    .foregroundColor(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("自动切换频道")
                                    Text("当前频道线路全部不可用后自动切换；每次切换会提醒，可在设置中关闭")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        if vm.autoBlacklistEnabled {
                            Button {
                                vm.clearBlacklist()
                            } label: {
                                HStack {
                                    Image(systemName: "trash")
                                        .foregroundColor(.blue)
                                    Text("清空黑名单")
                                        .foregroundColor(.primary)
                                }
                            }
                        }
                    } header: {
                        Text("播放设置")
                    }

                    Section {
                        Button {
                            vm.refreshLatestLineup()
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                if vm.isRefreshingLatest {
                                    ProgressView()
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                }
                                Text(vm.isRefreshingLatest ? "正在刷新 GitHub 最新源…" : "GitHub 最新源刷新")
                            }
                        }
                        .disabled(vm.isRefreshingLatest)
                    }

                    Section {
                        ForEach(Array(vm.sourceUrls.enumerated()), id: \.element) { i, url in
                            sourceRow(index: i, url: url)
                        }
                        .onDelete { offsets in
                            deleteSources(at: offsets)
                        }
                    } header: {
                        HStack {
                            Text("当前源：\(activeSourceLabel)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }

                    Section {
                        Toggle(isOn: $vm.showDiagnosticsOverlay) {
                            Label("页面显示实时诊断", systemImage: "waveform.path.ecg.rectangle")
                        }

                        Button {
                            UIPasteboard.general.string = vm.diagnosticsSummary
                        } label: {
                            Label("复制播放诊断", systemImage: "doc.on.doc")
                        }
                        Text("用于比较网页与 iPhone 的码率、缓冲、卡顿和线路切换情况")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } header: {
                        Text("故障排查")
                    }

                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("TV go 2.0")
                                .font(.headline)
                            Text("• 使用系统 AVPlayerViewController 作为轻量视频渲染层")
                            Text("• 不再内置 VLC，安装包恢复轻量体积")
                            Text("• 页面实时显示当前内核、输出/源帧率、丢帧、码率和等待原因")
                            Text("• 每次进入 App 都重新加载当前选中的来源")
                            Text("• 可复制包含全部实时指标的播放诊断，方便比较问题来源与正常来源")
                            Text("• 保留自动切换线路、失败线路黑名单和线路质量记忆")
                            Text("• 支持系统原生 HLS/HTTP 直播线路")
                            Text("• 支持自定义来源、收藏频道、隐藏线路和后台音频播放")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                    } header: {
                        Text("版本说明")
                    }
                }
                .listStyle(.insetGrouped)
            }
            .padding(.vertical)
            .navigationTitle("切换来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("重置") {
                        resetToDefault()
                    }
                    .foregroundColor(.red)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .alert("地址无效", isPresented: $showInvalidAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("请输入以 http:// 或 https:// 开头的有效地址")
        }
    }

    private var activeSourceLabel: String {
        for p in PRESET_SOURCES where p.url == vm.activeSourceUrl {
            return p.name
        }
        return "自定义"
    }

    @ViewBuilder
    private func sourceRow(index: Int, url: String) -> some View {
        HStack(spacing: 12) {
            Button {
                vm.selectSource(url)
                dismiss()
            } label: {
                HStack {
                    Image(systemName: url == vm.activeSourceUrl ? "largecircle.fill.circle" : "circle")
                        .foregroundColor(url == vm.activeSourceUrl ? .blue : .gray)
                        .font(.body)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName(for: url))
                            .font(.body)
                            .foregroundColor(.primary)

                        if displayName(for: url) != url {
                            Text(url)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if isBuiltin(url) {
                        Text("预置")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if url != DEFAULT_SOURCE_URL {
                Button("删除", role: .destructive) {
                    vm.deleteSourceUrl(url)
                }
            }
        }
    }

    private func displayName(for url: String) -> String {
        for p in PRESET_SOURCES where p.url == url {
            return p.name
        }
        return url
    }

    private func isBuiltin(_ url: String) -> Bool {
        PRESET_SOURCES.contains { $0.url == url }
    }

    private func add() {
        let url = inputUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }

        guard url.hasPrefix("http://") || url.hasPrefix("https://"),
              URL(string: url) != nil else {
            showInvalidAlert = true
            return
        }

        vm.selectSource(url)
        dismiss()
    }

    private func pasteClipboard() {
        guard let pasted = UIPasteboard.general.string, !pasted.isEmpty else { return }
        inputUrl = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func deleteSources(at offsets: IndexSet) {
        for i in offsets.sorted(by: >) {
            guard i < vm.sourceUrls.count else { continue }
            let url = vm.sourceUrls[i]
            if url != DEFAULT_SOURCE_URL {
                vm.deleteSourceUrl(url)
            }
        }
    }

    private func resetToDefault() {
        vm.selectSource(DEFAULT_SOURCE_URL)
        dismiss()
    }
}
