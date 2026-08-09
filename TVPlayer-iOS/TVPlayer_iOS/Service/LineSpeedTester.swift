import Foundation

/// 线路质量数据
struct LineQuality: Codable {
    let url: String
    var responseTime: Int  // 毫秒
    var isAvailable: Bool
    var lastChecked: Date
}

/// 预检结果：只有 hardFail 才跳过；unknown 仍交给 AVPlayer
enum PreflightResult {
    case ok
    case hardFail   // 明确死链：404/403/连接失败
    case unknown    // 超时/慢/拒 HEAD：不判死，继续播
}

/// 线路速度检测器
@MainActor
final class LineSpeedTester {
    static let shared = LineSpeedTester()

    private let session: URLSession
    private let timeout: TimeInterval = 5.0
    private var cache: [String: LineQuality] = [:]
    /// hardFail 才缓存为不可用；unknown 不缓存，避免误杀
    private var hardFailCache: [String: Date] = [:]

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)"
        ]
        self.session = URLSession(configuration: config)
    }

    /// 弱探测：HEAD 仅作参考；最终「可播」以 AVPlayer 起播成败为准
    /// 起播前预检：仅 hardFail 跳过；超时/慢线返回 unknown，交给播放器
    func quickPreflight(_ url: String, timeout: TimeInterval = 2.5) async -> PreflightResult {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .hardFail
        }
        if let t = hardFailCache[url], Date().timeIntervalSince(t) < 120 {
            return .hardFail
        }
        if let cached = cache[url], cached.isAvailable,
           Date().timeIntervalSince(cached.lastChecked) < 120 {
            return .ok
        }

        let start = Date()
        // 单次 Range 请求使用完整预检预算；拿到响应头后立即取消响应体流。
        // 直播流响应体永不结束，若不取消会泄漏一条连接（同主机连接耗尽后全局播放失败）。
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        do {
            let (bytes, resp) = try await session.bytes(for: req)
            bytes.task.cancel()
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 || code == 403 || code == 410 || code == 451 {
                hardFailCache[url] = Date()
                cache[url] = LineQuality(url: url, responseTime: Int.max, isAvailable: false, lastChecked: Date())
                return .hardFail
            }
            if (200...399).contains(code) {
                cache[url] = LineQuality(
                    url: url,
                    responseTime: Int(Date().timeIntervalSince(start) * 1000),
                    isAvailable: true,
                    lastChecked: Date()
                )
                return .ok
            }
            // 其它状态或超时：未知，仍尝试播放，不叠加第二轮探测。
            return .unknown
        } catch let err as URLError {
            switch err.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .dnsLookupFailed, .notConnectedToInternet:
                // 超时/连不上：多数是慢或临时网络，不当 hardFail（否则可播率崩）
                // 仅「明确无法解析的非法 host」才 hard——这里统一 unknown，让 AVPlayer 再试
                if err.code == .cannotFindHost || err.code == .dnsLookupFailed {
                    hardFailCache[url] = Date()
                    return .hardFail
                }
                return .unknown
            default:
                return .unknown
            }
        } catch {
            return .unknown
        }
    }

    func clearCache() {
        cache.removeAll()
        hardFailCache.removeAll()
    }

    /// 起播转圈时显示真实下载速度：下载源前若干 KB 测速（预算内即停）。
    /// 返回 KB/s；失败返回 nil（上层显示加载态，不谎报数字）。
    /// 与 quickPreflight 不同：quickPreflight 是 bytes=0-1 探活拿不到速度；
    /// 此方法真实读响应体字节测下载速率，反映「源在努力联网」。
    /// 一次性、随即取消，避免泄漏连接。
    func probeDownloadSpeed(_ url: String, budget: TimeInterval = 0.7) async -> Double? {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        req.timeoutInterval = budget + 0.5
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        let start = Date()
        do {
            let (bytes, resp) = try await session.bytes(for: req)
            guard (resp as? HTTPURLResponse).map({ (200...399).contains($0.statusCode) }) ?? false else {
                bytes.task.cancel()
                return nil
            }
            // 精确累计收到的字节数，直到预算时间到即停。URLSession.AsyncBytes 元素是 UInt8
            // 且是 async 序列（须用 for try await）。逐字节计数，预算内 break。
            var received = 0
            for try await _ in bytes {
                received += 1
                if Date().timeIntervalSince(start) >= budget { break }
            }
            bytes.task.cancel()
            let interval = Date().timeIntervalSince(start)
            guard interval > 0.05, received > 0 else { return nil }
            return Double(received) / 1024 / interval
        } catch {
            return nil
        }
    }
}
