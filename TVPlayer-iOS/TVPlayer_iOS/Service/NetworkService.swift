import Foundation
import Network
import UIKit

enum NetworkFetchError: LocalizedError {
    case invalidURL
    case badResponse
    case emptyBody
    case parseEmpty
    case allFailed
    case noNetwork

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "地址无效"
        case .badResponse: return "服务器响应异常"
        case .emptyBody: return "内容为空"
        case .parseEmpty: return "解析不到频道"
        case .allFailed: return "所有源均加载失败"
        case .noNetwork: return "网络不可用"
        }
    }
}

final class NetworkService {
    static let shared = NetworkService()

    private static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15"
    private static let timeout: TimeInterval = 15

    // 不能用 lazy var：镜像竞速的 TaskGroup 会并发首次触碰 session，
    // Swift lazy 初始化非线程安全（TSan 必报的数据竞争）。改为构造期一次性创建。
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 2
        cfg.waitsForConnectivity = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData  // 🆕 强制不使用缓存
        cfg.urlCache = URLCache(
            memoryCapacity: 2 * 1024 * 1024,    // 🆕 减小内存缓存到2MB
            diskCapacity: 0,                     // 🆕 禁用磁盘缓存
            diskPath: nil
        )
        cfg.httpAdditionalHeaders = ["User-Agent": ua]
        return URLSession(configuration: cfg)
    }()

    // 网络状态监听
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "NetworkMonitor")
    private var isNetworkAvailable = true
    private var cacheCleanupObservers: [NSObjectProtocol] = []

    private init() {
        startNetworkMonitor()
        setupCacheCleanup()  // 🆕 设置缓存清理
    }

    // 🆕 定时清理缓存机制
    private func setupCacheCleanup() {
        // App进入后台时清理缓存
        cacheCleanupObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clearCache()
        })

        // App收到内存警告时清理缓存
        cacheCleanupObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clearCache()
        })
    }

    // 🆕 清理缓存
    func clearCache() {
        URLCache.shared.removeAllCachedResponses()
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    deinit {
        cacheCleanupObservers.forEach { NotificationCenter.default.removeObserver($0) }
        monitor.cancel()
    }

    private func startNetworkMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.isNetworkAvailable = path.status == .satisfied
        }
        monitor.start(queue: monitorQueue)
    }

    func fetch(url: String) async throws -> String {
        guard let u = URL(string: url), u.scheme != nil else {
            throw NetworkFetchError.invalidURL
        }

        let available = monitorQueue.sync { isNetworkAvailable }
        if !available {
            throw NetworkFetchError.noNetwork
        }

        var request = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        // 一次性读取（原生缓冲，最快）：资源超时 17s 兜底下载时长，
        // 下载后按 maxBodyBytes 拒绝异常大响应，避免内存占用过高
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw NetworkFetchError.badResponse
        }
        // 超大源（几十 MB）拒绝解析，避免内存占用过高；正常 M3U 都在 KB 级
        if data.count > Self.maxBodyBytes {
            throw NetworkFetchError.parseEmpty
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            // 中文圈仍有 GBK/GB18030 源；Latin1 对任意字节都"成功"会产生静默乱码，只作最后兜底
            if let gbk = String(data: data, encoding: Self.gb18030), !gbk.isEmpty {
                return gbk
            }
            if let text2 = String(data: data, encoding: .isoLatin1), !text2.isEmpty {
                return text2
            }
            throw NetworkFetchError.emptyBody
        }
        return text
    }

    /// GB18030（兼容 GBK/GB2312）文本编码
    private static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    /// M3U 源最大字节数：5MB 足够容纳最大公开源（几十万行），再大视为异常拒绝
    private static let maxBodyBytes = 5 * 1024 * 1024

    /// 单一源 + 镜像竞速：GitHub 系地址自动展开镜像并发请求，任一候选返回可用文本即胜出。
    /// 被墙域名常见表现是挂到超时而非快速失败，串行回退会拖慢启动，故并发。
    func fetchTextWithMirrors(url: String) async throws -> String {
        let candidates = MirrorResolver.candidates(for: url)
        guard !candidates.isEmpty else { throw NetworkFetchError.invalidURL }
        if candidates.count == 1 {
            return try await fetch(url: candidates[0])
        }
        let text: String? = await withTaskGroup(of: String?.self) { group in
            for candidate in candidates {
                group.addTask {
                    try? await self.fetch(url: candidate)
                }
            }
            for await result in group {
                if let result, !result.isEmpty {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
        guard let text else { throw NetworkFetchError.allFailed }
        return text
    }
}
