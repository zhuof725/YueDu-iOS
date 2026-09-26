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

    /// 解析 header 字段（可以是 JSON 对象，也可以是 @js: 代码）
    func headerMap() -> [String: String] {
        guard let h = header?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty else {
            return ["User-Agent": BookSource.defaultUA]
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

enum BookSourceImporter {
    /// 兼容：单个对象 / 数组 / 数字型布尔等宽松格式
    static func parse(_ data: Data) throws -> [BookSource] {
        let decoder = JSONDecoder()
        // 先尝试数组
        if let list = try? decoder.decode([LenientSource].self, from: data) {
            return list.compactMap { $0.source }
        }
        if let one = try? decoder.decode(LenientSource.self, from: data), let s = one.source {
            return [s]
        }
        throw NSError(domain: "YueDu", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "不是有效的书源 JSON"])
    }

    /// 宽松解码：各字段类型不严格（比如 enabled 可能是 0/1，规则可能是数字）
    struct LenientSource: Decodable {
        var source: BookSource?

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            let any = try c.decode(AnyCodable.self).value
            guard var dict = any as? [String: Any] else { return }
            // 规范化布尔值
            for key in ["enabled", "enabledExplore", "enabledCookieJar"] {
                if let v = dict[key] {
                    if let n = v as? NSNumber { dict[key] = n.boolValue }
                    else if let s = v as? String { dict[key] = (s == "true" || s == "1") }
                }
            }
            for key in ["bookSourceType", "weight", "customOrder"] {
                if let s = dict[key] as? String { dict[key] = Int(s) ?? 0 }
            }
            // 规则子对象里所有值转成字符串
            for key in ["ruleSearch", "ruleExplore", "ruleBookInfo", "ruleToc", "ruleContent"] {
                if var sub = dict[key] as? [String: Any] {
                    for (k, v) in sub where !(v is String) {
                        if v is NSNull { sub[k] = nil } else { sub[k] = "\(v)" }
                    }
                    dict[key] = sub
                } else if dict[key] is String {
                    // 有些书源把规则存成 JSON 字符串
                    if let s = dict[key] as? String, let d = s.data(using: .utf8),
                       let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        dict[key] = o
                    } else { dict[key] = nil }
                }
            }
            if let h = dict["header"], !(h is String) {
                if let d = try? JSONSerialization.data(withJSONObject: h) {
                    dict["header"] = String(data: d, encoding: .utf8)
                }
            }
            guard dict["bookSourceUrl"] is String, dict["bookSourceName"] is String else { return }
            let data = try JSONSerialization.data(withJSONObject: dict)
            source = try JSONDecoder().decode(BookSource.self, from: data)
        }
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
