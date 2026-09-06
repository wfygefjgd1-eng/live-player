import Foundation

final class StorageService {
    private let defaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "StorageService", qos: .utility, attributes: .concurrent)

    // Keys
    private let kChannels = "channels_cache"
    private let kChannelsMeta = "channels_meta"       // 元数据（版本、数量、更新时间）
    private let kSourceUrls = "source_urls"
    private let kSelectedSource = "selected_source_url"
    private let kCustomSource = "custom_source_url"
    private let kHiddenLines = "hidden_lines"
    private let kBlacklistedLines = "blacklisted_lines"  // 失败线路黑名单
    private let kFavorites = "favorites"
    private let kLastChannelKey = "last_channel_key"
    private let kLastSourceIndex = "last_source_index"
    private let kDataVersion = "data_version"
    private let kLineTimeoutEnabled = "line_timeout_enabled"
    private let kAutoBlacklistEnabled = "auto_blacklist_enabled"
    private let kAutoAdvanceOnExhaustion = "auto_advance_on_exhaustion"
    private let kBackgroundPlaybackEnabled = "background_playback_enabled"
    private let autoBlacklistTTL: TimeInterval = 15 * 60

    private let currentDataVersion = 1

    // 元数据结构
    private struct ChannelsMeta: Codable {
        let version: Int
        let count: Int
        let updatedAt: Date
    }

    private typealias BlacklistRecords = [String: Date]

    /// Reads the current format and migrates the old permanent string array on first access.
    private func loadBlacklistRecords() -> BlacklistRecords {
        if let data = defaults.data(forKey: kBlacklistedLines),
           let records = try? JSONDecoder().decode(BlacklistRecords.self, from: data) {
            return records
        }

        guard let legacy = defaults.stringArray(forKey: kBlacklistedLines), !legacy.isEmpty else {
            return [:]
        }
        let expiry = Date().addingTimeInterval(autoBlacklistTTL)
        var records: BlacklistRecords = [:]
        for line in legacy {
            records[line] = expiry
        }
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: kBlacklistedLines)
        }
        return records
    }

    private func saveBlacklistRecords(_ records: BlacklistRecords) {
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: kBlacklistedLines)
        }
    }

    // MARK: - 频道缓存（文件存储 + 内存缓存）
    // 频道缓存可能有几 MB：UserDefaults 不适合存大块数据（全量 plist 重写、启动主线程解码慢），
    // 改为 Caches 目录文件 + 原子写入 + 解码结果内存缓存；老版本的 UserDefaults 缓存首次读取时自动迁移。

    private var channelsMemo: [Channel]?
    /// 频道缓存放 Application Support（系统不会清除；Caches 目录会被系统随时清空），
    /// 并排除 iCloud 备份。目录不存在时惰性创建。
    private var channelsCacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("TVPlayer", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let url = dir.appendingPathComponent("channels_cache.json")
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    func saveChannels(_ channels: [Channel]) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.channelsMemo = channels
            guard let data = try? JSONEncoder().encode(channels) else { return }
            do {
                try data.write(to: self.channelsCacheURL, options: .atomic)
                // 文件写成功后清掉老版本塞在 UserDefaults 里的整表数据
                self.defaults.removeObject(forKey: self.kChannels)
            } catch {
                // 文件写失败时退回 UserDefaults，保证缓存不丢
                self.defaults.set(data, forKey: self.kChannels)
            }

            // 保存元数据
            let meta = ChannelsMeta(version: self.currentDataVersion,
                                    count: channels.count,
                                    updatedAt: Date())
            if let metaData = try? JSONEncoder().encode(meta) {
                self.defaults.set(metaData, forKey: self.kChannelsMeta)
            }
            self.defaults.set(self.currentDataVersion, forKey: self.kDataVersion)
        }
    }

    func loadChannels() -> [Channel] {
        // 用 barrier：本方法会写 channelsMemo，与 saveChannels 的写互斥
        queue.sync(flags: .barrier) { [weak self] in
            guard let self else { return [] }
            if let memo = self.channelsMemo {
                return memo
            }
            // 检查数据版本，必要时迁移
            let savedVersion = self.defaults.integer(forKey: self.kDataVersion)
            if savedVersion < self.currentDataVersion {
                self.migrateData(from: savedVersion)
            }

            var loaded: [Channel] = []
            if let data = try? Data(contentsOf: self.channelsCacheURL),
               let channels = try? JSONDecoder().decode([Channel].self, from: data) {
                loaded = channels
            } else if let data = self.defaults.data(forKey: self.kChannels),
                      let channels = try? JSONDecoder().decode([Channel].self, from: data) {
                // 老版本 UserDefaults 缓存：迁移到文件，写成功才清 UD 副本
                //（写失败时保留副本，下次冷启动还能迁移，否则缓存彻底丢失）
                loaded = channels
                if (try? data.write(to: self.channelsCacheURL, options: .atomic)) != nil {
                    self.defaults.removeObject(forKey: self.kChannels)
                }
            }
            self.channelsMemo = loaded
            return loaded
        }
    }

    // MARK: - 数据迁移

    private func migrateData(from oldVersion: Int) {
        // v0 → v1: 无旧数据结构，直接清理
        if oldVersion < 1 {
            // 未来版本可以在这里做结构迁移
        }
        defaults.set(currentDataVersion, forKey: kDataVersion)
    }

    // MARK: - 源地址管理

    func saveSourceUrls(_ urls: [String]) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.defaults.set(urls, forKey: self.kSourceUrls)
        }
    }

    func loadSourceUrls() -> [String] {
        queue.sync {
            defaults.stringArray(forKey: kSourceUrls) ?? []
        }
    }

    func saveSelectedSourceUrl(_ url: String) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.defaults.set(url, forKey: self.kSelectedSource)
        }
    }

    func loadSelectedSourceUrl() -> String {
        queue.sync {
            defaults.string(forKey: kSelectedSource) ?? ""
        }
    }

    func saveCustomSourceUrl(_ url: String) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.defaults.set(url, forKey: self.kCustomSource)
        }
    }

    // MARK: - 隐藏线路

    func loadHiddenLines() -> Set<String> {
        queue.sync {
            Set(defaults.stringArray(forKey: kHiddenLines) ?? [])
        }
    }

    /// 同步写入，保证随后 isLineHidden / applyRules 立刻可见
    func hideLine(_ url: String) {
        let clean = url.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        queue.sync(flags: .barrier) {
            var lines = Set(defaults.stringArray(forKey: kHiddenLines) ?? [])
            lines.insert(clean)
            defaults.set(Array(lines), forKey: kHiddenLines)
        }
    }

    func isLineHidden(_ url: String) -> Bool {
        queue.sync {
            let lines = Set(defaults.stringArray(forKey: kHiddenLines) ?? [])
            return lines.contains(url.trimmingCharacters(in: .whitespaces))
        }
    }

    func removeSourceUrl(_ url: String) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            var urls = self.defaults.stringArray(forKey: self.kSourceUrls) ?? []
            urls.removeAll { $0 == url }
            self.defaults.set(urls, forKey: self.kSourceUrls)
        }
    }

    // MARK: - 黑名单管理

    func loadBlacklistedLines() -> Set<String> {
        queue.sync(flags: .barrier) {
            let now = Date()
            let active = loadBlacklistRecords().filter { $0.value > now }
            saveBlacklistRecords(active)
            return Set(active.keys)
        }
    }

    /// 同步添加临时黑名单；同一条线路失败后重新计时。
    func blacklistLine(_ url: String) {
        let clean = url.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        queue.sync(flags: .barrier) {
            let now = Date()
            var records = loadBlacklistRecords().filter { $0.value > now }
            records[clean] = now.addingTimeInterval(autoBlacklistTTL)
            saveBlacklistRecords(records)
        }
    }

    func isLineBlacklisted(_ url: String) -> Bool {
        queue.sync(flags: .barrier) {
            let clean = url.trimmingCharacters(in: .whitespaces)
            guard let expiry = loadBlacklistRecords()[clean] else { return false }
            return expiry > Date()
        }
    }

    /// 清空黑名单（换源时调用）
    func clearBlacklist() {
        queue.sync(flags: .barrier) {
            defaults.removeObject(forKey: kBlacklistedLines)
        }
    }

    // MARK: - 设置项

    func saveLineTimeoutEnabled(_ enabled: Bool) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.defaults.set(enabled, forKey: self.kLineTimeoutEnabled)
        }
    }

    func loadLineTimeoutEnabled() -> Bool {
        queue.sync {
            // 默认开启
            if defaults.object(forKey: kLineTimeoutEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: kLineTimeoutEnabled)
        }
    }

    func saveAutoBlacklistEnabled(_ enabled: Bool) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.defaults.set(enabled, forKey: self.kAutoBlacklistEnabled)
        }
    }

    func loadAutoBlacklistEnabled() -> Bool {
        queue.sync {
            // 默认关闭
            defaults.bool(forKey: kAutoBlacklistEnabled)
        }
    }

    func saveAutoAdvanceOnExhaustion(_ enabled: Bool) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.defaults.set(enabled, forKey: self.kAutoAdvanceOnExhaustion)
        }
    }

    func loadAutoAdvanceOnExhaustion() -> Bool {
        queue.sync {
            // 保持历史版本的自动切台行为，用户可在设置中关闭。
            if defaults.object(forKey: kAutoAdvanceOnExhaustion) == nil {
                return true
            }
            return defaults.bool(forKey: kAutoAdvanceOnExhaustion)
        }
    }

    // MARK: - 后台播放

    func saveBackgroundPlaybackEnabled(_ enabled: Bool) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.defaults.set(enabled, forKey: self.kBackgroundPlaybackEnabled)
        }
    }

    func loadBackgroundPlaybackEnabled() -> Bool {
        queue.sync {
            // 默认关闭后台播放
            if defaults.object(forKey: kBackgroundPlaybackEnabled) == nil {
                return false
            }
            return defaults.bool(forKey: kBackgroundPlaybackEnabled)
        }
    }

    // MARK: - 收藏

    func loadFavorites() -> Set<String> {
        queue.sync {
            Set(defaults.stringArray(forKey: kFavorites) ?? [])
        }
    }

    func toggleFavorite(_ key: String) -> Bool {
        queue.sync(flags: .barrier) {
            var fav = Set(defaults.stringArray(forKey: kFavorites) ?? [])
            if fav.contains(key) {
                fav.remove(key)
                defaults.set(Array(fav), forKey: kFavorites)
                return false
            }
            fav.insert(key)
            defaults.set(Array(fav), forKey: kFavorites)
            return true
        }
    }

    func isFavorite(_ key: String) -> Bool {
        queue.sync {
            let fav = Set(defaults.stringArray(forKey: kFavorites) ?? [])
            return fav.contains(key)
        }
    }

    // MARK: - 上次播放位置

    func saveLastChannel(key: String, sourceIndex: Int) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.defaults.set(key, forKey: self.kLastChannelKey)
            self.defaults.set(sourceIndex, forKey: self.kLastSourceIndex)
        }
    }

    func loadLastChannelKey() -> String {
        queue.sync {
            defaults.string(forKey: kLastChannelKey) ?? ""
        }
    }

    func loadLastSourceIndex() -> Int {
        queue.sync {
            defaults.integer(forKey: kLastSourceIndex)
        }
    }

    // MARK: - 全量清理（用于恢复出厂）

    func clearAll() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.channelsCacheURL)
            self.channelsMemo = nil
            for key in [self.kChannels, self.kChannelsMeta, self.kSourceUrls,
                         self.kSelectedSource, self.kCustomSource, self.kHiddenLines,
                         self.kBlacklistedLines, self.kFavorites, self.kLastChannelKey,
                         self.kLastSourceIndex, self.kDataVersion, self.kLineTimeoutEnabled,
                         self.kAutoBlacklistEnabled, self.kAutoAdvanceOnExhaustion,
                         self.kBackgroundPlaybackEnabled] {
                self.defaults.removeObject(forKey: key)
            }
        }
    }
}
