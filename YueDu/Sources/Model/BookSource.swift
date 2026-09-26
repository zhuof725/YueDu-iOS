import Foundation

/// 书源（兼容 Legado / 阅读 3.x 的 JSON 格式）
struct BookSource: Codable, Identifiable, Hashable {
    var id: String { bookSourceUrl }

    var bookSourceUrl: String
    var bookSourceName: String
    var bookSourceGroup: String?
    var bookSourceType: Int?          // 0 文本 1 音频 2 图片 3 文件
    var bookSourceComment: String?
    var enabled: Bool?
    var enabledExplore: Bool?
    var header: String?
    var loginUrl: String?
    var loginUi: String?
    var loginCheckJs: String?
    var coverDecodeJs: String?
    var bookUrlPattern: String?
    var searchUrl: String?
    var exploreUrl: String?
    var weight: Int?
    var customOrder: Int?
    var lastUpdateTime: Double?
    var respondTime: Double?
    var jsLib: String?
    var concurrentRate: String?
    var variableComment: String?

    var ruleSearch: SearchRule?
    var ruleExplore: ExploreRule?
    var ruleBookInfo: BookInfoRule?
    var ruleToc: TocRule?
    var ruleContent: ContentRule?

    var isEnabled: Bool { enabled ?? true }

    /// 这个书源是否支持登录
    var hasLogin: Bool {
        !(loginUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !(loginUi ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 解析 header 字段（可以是 JSON 对象，也可以是 @js: 代码）
    func headerMap() -> [String: String] {
        guard let h = header?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty else {
            var m = ["User-Agent": BookSource.defaultUA]
            for (k, v) in LoginStore.headerMap(bookSourceUrl) { m[k] = v }
            return m
        }
        var map: [String: String] = [:]
        if h.hasPrefix("@js:") || h.lowercased().hasPrefix("<js>") {
            let js = h.hasPrefix("@js:") ? String(h.dropFirst(4)) : h
                .replacingOccurrences(of: "<js>", with: "").replacingOccurrences(of: "</js>", with: "")
            if let r = JSEngine.shared.eval(js, bindings: ["source": bookSourceUrl]) as? [String: Any] {
                for (k, v) in r { map[k] = "\(v)" }
            } else if let s = JSEngine.shared.eval(js, bindings: [:]) as? String,
                      let d = s.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                for (k, v) in o { map[k] = "\(v)" }
            }
        } else if let d = h.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])) as? [String: Any] {
            for (k, v) in o { map[k] = "\(v)" }
        }
        if map["User-Agent"] == nil && map["user-agent"] == nil {
            map["User-Agent"] = BookSource.defaultUA
        }
        // 登录后保存的请求头（例如 token、Cookie）
        for (k, v) in LoginStore.headerMap(bookSourceUrl) { map[k] = v }
        return map
    }

    static let defaultUA = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
}

struct SearchRule: Codable, Hashable {
    var checkKeyWord: String?
    var bookList: String?
    var name: String?
    var author: String?
    var intro: String?
    var kind: String?
    var lastChapter: String?
    var updateTime: String?
    var bookUrl: String?
    var coverUrl: String?
    var wordCount: String?
}

typealias ExploreRule = SearchRule

struct BookInfoRule: Codable, Hashable {
    var `init`: String?
    var name: String?
    var author: String?
    var intro: String?
    var kind: String?
    var lastChapter: String?
    var updateTime: String?
    var coverUrl: String?
    var tocUrl: String?
    var wordCount: String?
    var canReName: String?
    var downloadUrls: String?
}

struct TocRule: Codable, Hashable {
    var preUpdateJs: String?
    var chapterList: String?
    var chapterName: String?
    var chapterUrl: String?
    var formatJs: String?
    var isVolume: String?
    var isVip: String?
    var isPay: String?
    var updateTime: String?
    var nextTocUrl: String?
}

struct ContentRule: Codable, Hashable {
    var content: String?
    var title: String?
    var nextContentUrl: String?
    var webJs: String?
    var sourceRegex: String?
    var replaceRegex: String?
    var imageStyle: String?
    var imageDecode: String?
    var payAction: String?
}

// MARK: - 导入

struct ImportReport {
    var sources: [BookSource] = []
    var skipped: [String] = []     // 跳过的条目及原因
}

enum BookSourceImporter {
    private static let intKeys: Set<String> = ["bookSourceType", "weight", "customOrder"]
    private static let doubleKeys: Set<String> = ["lastUpdateTime", "respondTime"]
    private static let boolKeys: Set<String> = ["enabled", "enabledExplore", "enabledCookieJar"]
    private static let ruleKeys: Set<String> = ["ruleSearch", "ruleExplore", "ruleBookInfo", "ruleToc", "ruleContent"]
    private static let stringKeys: [String] = ["bookSourceUrl", "bookSourceName", "bookSourceGroup", "bookSourceComment",
        "header", "loginUrl", "loginUi", "loginCheckJs", "coverDecodeJs", "bookUrlPattern", "searchUrl", "exploreUrl", "jsLib", "concurrentRate", "variableComment"]

    /// 字节 → 文本（兼容 UTF-8 BOM、GBK 编码的 txt）
    static func text(from data: Data) -> String {
        var s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: Util.gbk) ?? String(decoding: data, as: UTF8.self)
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 兼容旧接口：解析失败或 0 个时抛出带原因的错误
    static func parse(_ data: Data) throws -> [BookSource] {
        let r = try parseReport(text(from: data))
        return r.sources
    }

    static func parseReport(_ raw: String) throws -> ImportReport {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw YueDuError.message("内容是空的") }
        guard let root = parseJSONLoose(t) else {
            throw YueDuError.message("内容不是 JSON。开头是：\n\(preview(t))")
        }
        var items: [Any] = []
        if let a = root as? [Any] { items = a }
        else if let o = root as? [String: Any] {
            if o["bookSourceUrl"] != nil { items = [o] }
            else if let a = (o["data"] ?? o["list"] ?? o["sources"] ?? o["bookSources"]) as? [Any] { items = a }
            else if o["sourceUrl"] != nil && o["sourceName"] != nil {
                throw YueDuError.message("这是「订阅源 / RSS 源」，不是书源，暂不支持")
            }
            else { items = [o] }
        } else if let s = root as? String, let inner = parseJSONLoose(s) {
            // 被再包了一层字符串的 JSON
            return try parseReport(JSONPath.stringify(inner))
        }
        var report = ImportReport()
        for (i, it) in items.enumerated() {
            guard let d = it as? [String: Any] else { report.skipped.append("第\(i + 1)条：不是对象"); continue }
            do { report.sources.append(try normalize(d)) }
            catch { report.skipped.append("第\(i + 1)条「\(d["bookSourceName"] ?? d["sourceName"] ?? "?")」：\(error.localizedDescription)") }
        }
        if report.sources.isEmpty {
            if items.first.flatMap({ ($0 as? [String: Any])?["sourceUrl"] }) != nil {
                throw YueDuError.message("这是「订阅源 / RSS 源」，不是书源，暂不支持")
            }
            let why = report.skipped.prefix(3).joined(separator: "\n")
            throw YueDuError.message("没有找到可用的书源（共 \(items.count) 条）\n\(why)")
        }
        return report
    }

    /// 标准 JSON 失败时，用 JS 引擎解析（兼容注释、尾逗号、单引号）
    static func parseJSONLoose(_ t: String) -> Any? {
        if let d = t.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) {
            return o
        }
        guard t.hasPrefix("[") || t.hasPrefix("{") else { return nil }
        let r = JSEngine.shared.eval("JSON.stringify(eval('(' + __t + ')'))", bindings: ["__t": t])
        if let s = r as? String, let d = s.data(using: .utf8) { return try? JSONSerialization.jsonObject(with: d) }
        return nil
    }

    static func preview(_ s: String) -> String {
        let p = s.prefix(80).replacingOccurrences(of: "\n", with: " ")
        return s.count > 80 ? p + "…" : p
    }

    /// 把各种字段类型统一成模型需要的类型
    static func normalize(_ src: [String: Any]) throws -> BookSource {
        var d: [String: Any] = [:]
        for k in stringKeys {
            guard let v = src[k], !(v is NSNull) else { continue }
            d[k] = (v as? String) ?? JSONPath.stringify(v)
        }
        guard let url = d["bookSourceUrl"] as? String, !url.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw YueDuError.message("缺少 bookSourceUrl")
        }
        d["bookSourceUrl"] = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if (d["bookSourceName"] as? String)?.isEmpty ?? true { d["bookSourceName"] = url }
        for k in intKeys { if let v = src[k] { d[k] = Int(JSONPath.stringify(v)) ?? Int(Double(JSONPath.stringify(v)) ?? 0) } }
        for k in doubleKeys { if let v = src[k] { d[k] = Double(JSONPath.stringify(v)) ?? 0 } }
        for k in boolKeys {
            guard let v = src[k], !(v is NSNull) else { continue }
            if let b = v as? Bool { d[k] = b }
            else { let s = JSONPath.stringify(v).lowercased(); d[k] = (s == "true" || s == "1") }
        }
        for k in ruleKeys {
            var rule: [String: Any]?
            if let o = src[k] as? [String: Any] { rule = o }
            else if let s = src[k] as? String, let o = parseJSONLoose(s) as? [String: Any] { rule = o }
            // 数组、空值等不认识的格式：当作没有该规则
            guard let r = rule else { continue }
            var out: [String: String] = [:]
            for (rk, rv) in r where !(rv is NSNull) { out[rk] = (rv as? String) ?? JSONPath.stringify(rv) }
            d[k] = out
        }
        let data = try JSONSerialization.data(withJSONObject: d)
        return try JSONDecoder().decode(BookSource.self, from: data)
    }

    /// 从一段文字里找书源链接（支持 legado://、yuedu:// 导入链接，以及夹杂文字的网址）
    static func extractURL(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("[") || t.hasPrefix("{") { return nil }
        if let r = t.range(of: #"[?&]src=([^\s&]+)"#, options: .regularExpression) {
            let v = String(t[r]).components(separatedBy: "src=").last ?? ""
            let decoded = v.removingPercentEncoding ?? v
            if decoded.lowercased().hasPrefix("http") { return decoded }
        }
        if let r = t.range(of: #"https?://[^\s"'<>，。]+"#, options: .regularExpression) {
            return String(t[r])
        }
        return nil
    }
}

/// 任意 JSON 值
struct AnyCodable: Codable {
    let value: Any
    init(_ value: Any) { self.value = value }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = NSNull() }
        else if let b = try? c.decode(Bool.self) { value = b }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = d }
        else if let s = try? c.decode(String.self) { value = s }
        else if let a = try? c.decode([AnyCodable].self) { value = a.map { $0.value } }
        else if let o = try? c.decode([String: AnyCodable].self) { value = o.mapValues { $0.value } }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported") }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let a as [Any]: try c.encode(a.map { AnyCodable($0) })
        case let o as [String: Any]: try c.encode(o.mapValues { AnyCodable($0) })
        default: try c.encode("\(value)")
        }
    }
}
