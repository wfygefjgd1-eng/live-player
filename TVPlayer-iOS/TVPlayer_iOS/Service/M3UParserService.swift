import Foundation

class M3UParserService {
    private static let groupPattern = try! NSRegularExpression(pattern: "group-title=\"([^\"]*)\"")
    private static let namePattern = try! NSRegularExpression(pattern: ",(.+?)$")
    private static let cctvPattern = try! NSRegularExpression(pattern: "cctv\\s*[-_ ]*0*([1-9]\\d*)(k|\\+)?", options: .caseInsensitive)
    private static let trailingPattern = try! NSRegularExpression(
        pattern: "(fhd|uhd|hd|sd|4k|8k|1080p|720p|576p|50fps|60fps|h264|h265|hevc|hdr|"
            + "高清|超清|标清|蓝光|流畅|高码|高帧|测试|备用\\d*|线路\\d+|源\\d+|"
            + "直播|在线|综合|频道|央视|卫视|中文|台)$",
        options: .caseInsensitive
    )

    static func parse(_ text: String) -> [Channel] {
        // 剥离 UTF-8 BOM：带 BOM 的源首行 hasPrefix("#EXTINF:") 会失败，导致首个频道丢失
        let cleaned = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        guard !cleaned.isEmpty else { return [] }
        var channels = OrderedDictionary<String, Channel>()
        var pendingName: String? = nil
        var pendingGroup = "未分组"

        let lines = cleaned.components(separatedBy: .newlines)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                if let g = groupPattern.firstMatch(in: line), g.count > 1 {
                    pendingGroup = g[1]
                }
                if let n = namePattern.firstMatch(in: line), n.count > 1 {
                    pendingName = n[1]
                }
            } else if line.hasPrefix("#EXTGRP:") {
                // 部分源用 #EXTGRP 标记分组，优先于 #EXTINF 里可能缺失的 group-title
                let groupName = line.dropFirst("#EXTGRP:".count).trimmingCharacters(in: .whitespaces)
                if !groupName.isEmpty {
                    pendingGroup = groupName
                }
            } else if !line.isEmpty, !line.hasPrefix("#"), let name = pendingName {
                // 脏源（HTML 误解析、js 脚本行）里的非 URL 行不灌进频道列表
                guard isValidMediaURL(line) else {
                    pendingName = nil
                    pendingGroup = "未分组"
                    continue
                }
                let display = normalizeDisplayName(name)
                let key = normalizeName(display)
                // 央视统一进「央视」分组，避免 CCTV-15/17 落在未分组
                let group = isCCTVKey(key) ? "央视" : pendingGroup
                if var existing = channels[key] {
                    existing.addUrl(line)
                    channels[key] = existing
                } else {
                    var ch = Channel(name: display, group: group, key: key)
                    ch.addUrl(line)
                    channels[key] = ch
                }
                pendingName = nil
                pendingGroup = "未分组"
            }
        }
        return Array(channels.values)
    }

    /// URL 合法性校验：必须是 http/https 且有可解析的主机名。
    /// 注：此处过滤脏数据，但不过度约束——rtmp/rtsp 等非标准协议仍保留给其他路径。
    private static func isValidMediaURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return false
        }
        return true
    }

    static func isCCTVKey(_ key: String) -> Bool {
        key.lowercased().hasPrefix("cctv")
    }

    /// 从 key/name 解析 CCTV 台号，解析失败返回 Int.max（排后）
    static func cctvNumber(from keyOrName: String) -> Int {
        let w = keyOrName.lowercased()
        if let m = cctvPattern.firstMatch(in: w), m.count > 1, let num = Int(m[1]) {
            return num
        }
        return Int.max
    }

    static func normalizeName(_ name: String) -> String {
        var w = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let m = cctvPattern.firstMatch(in: w), m.count > 1, let num = Int(m[1]) {
            let suffix = m.count > 2 && !m[2].isEmpty ? m[2].uppercased() : ""
            return "cctv\(num)\(suffix)"
        }
        w = w.replacingOccurrences(of: "[\\s\\-—_\u{00B7}\u{002E}\u{FF0C}\u{3001}\u{3002}/\\\\|()（）\\[\\]【】:+]+", with: "", options: .regularExpression)
        for (a, b) in [("中央", "cctv"), ("央视", "cctv"), ("高清", ""), ("超清", ""), ("蓝光", ""), ("流畅", ""), ("频道", ""), ("直播", ""), ("在线", "")] {
            w = w.replacingOccurrences(of: a, with: b)
        }
        w = w.replacingOccurrences(of: "(测试|试看|备份|备用|线路|源)+", with: "", options: .regularExpression)
        w = w.replacingOccurrences(of: "(?:第)?0*([1-9]\\d*)台$", with: "$1", options: .regularExpression)
        w = stripTrailingNoise(w)
        return w
    }

    static func normalizeDisplayName(_ rawName: String) -> String {
        var clean = rawName.trimmingCharacters(in: .whitespaces)
        if let m = cctvPattern.firstMatch(in: clean), m.count > 1, let num = Int(m[1]) {
            let suffix = m.count > 2 && !m[2].isEmpty ? m[2].uppercased() : ""
            return "CCTV-\(num)\(suffix)"
        }
        clean = clean.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        clean = clean.replacingOccurrences(of: "(?i)(高清|超清|蓝光|流畅|频道|直播|在线|测试|备用\\d*|线路\\d+|源\\d+)$", with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? "未知" : clean
    }

    private static func stripTrailingNoise(_ value: String) -> String {
        var w = value
        while true {
            guard let m = trailingPattern.matchResult(in: w) else { break }
            let nsRange = m.range(at: 0)
            guard nsRange.location != NSNotFound else { break }
            guard let start = Range(nsRange, in: w)?.lowerBound else { break }
            w = String(w[..<start])
        }
        return w
    }
}

// MARK: - Regex helpers
private extension NSRegularExpression {
    func firstMatch(in string: String) -> [String]? {
        let range = NSRange(location: 0, length: string.utf16.count)
        guard let m = firstMatch(in: string, range: range) else { return nil }
        var result: [String] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            if r.location == NSNotFound { result.append(""); continue }
            result.append((string as NSString).substring(with: r))
        }
        return result
    }
    func matchResult(in string: String) -> NSTextCheckingResult? {
        let range = NSRange(location: 0, length: string.utf16.count)
        return firstMatch(in: string, range: range)
    }
}


