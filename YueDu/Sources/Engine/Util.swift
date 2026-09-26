import Foundation
import Combine
import CryptoKit
import SwiftSoup

enum Util {
    /// 拼接绝对地址（兼容中文、空格等未编码字符）
    static func absoluteURL(_ base: String?, _ relative: String) -> String {
        let rel = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        if rel.isEmpty { return base ?? "" }
        let lower = rel.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("data:") { return rel }
        if lower.hasPrefix("javascript") { return "" }
        guard let base = base, !base.isEmpty else { return rel }
        // 去掉 base 里 ",{...}" 参数部分
        var b = base
        if let r = b.range(of: #"\s*,\s*(?=\{)"#, options: .regularExpression) { b = String(b[..<r.lowerBound]) }
        guard let baseU = URL(string: b) ?? URL(string: encodeLoose(b)) else { return rel }
        // 保留 rel 里 ",{...}" 参数
        var suffix = ""
        var path = rel
        if let r = rel.range(of: #"\s*,\s*(?=\{)"#, options: .regularExpression) {
            suffix = String(rel[r.lowerBound...])
            path = String(rel[..<r.lowerBound])
        }
        if path.hasPrefix("//") { return (baseU.scheme ?? "https") + ":" + path + suffix }
        if let u = URL(string: path, relativeTo: baseU) ?? URL(string: encodeLoose(path), relativeTo: baseU) {
            return u.absoluteString + suffix
        }
        return rel
    }

    /// 只编码非 ASCII 和空格，保留已有的 %XX 和保留字符
    static func encodeLoose(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert(charactersIn: "#%[]")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func baseUrl(of url: String) -> String {
        guard let u = URL(string: url) ?? URL(string: encodeLoose(url)), let h = u.host else { return url }
        var s = "\(u.scheme ?? "https")://\(h)"
        if let p = u.port { s += ":\(p)" }
        return s
    }

    static func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func encoding(named name: String?) -> String.Encoding? {
        guard var n = name?.trimmingCharacters(in: .whitespaces).lowercased(), !n.isEmpty else { return nil }
        n = n.replacingOccurrences(of: "\"", with: "")
        switch n {
        case "utf-8", "utf8": return .utf8
        case "gbk", "gb2312", "gb18030", "x-gbk", "cp936":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case "big5", "big-5":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        case "iso-8859-1", "latin1": return .isoLatin1
        case "utf-16": return .utf16
        default:
            let cf = CFStringConvertIANACharSetNameToEncoding(n as CFString)
            if cf == kCFStringEncodingInvalidId { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
    }

    static var gbk: String.Encoding { encoding(named: "gbk")! }

    /// 按指定编码进行 URL 编码（已编码的 %XX 保持不变）
    static func urlEncode(_ s: String, encoding: String.Encoding?) -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~*")
        var out = ""
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "%", i + 2 < chars.count, chars[i + 1].isHexDigit, chars[i + 2].isHexDigit {
                out.append(contentsOf: String(chars[i...i + 2])); i += 3; continue
            }
            if unreserved.contains(c) { out.append(c) }
            else if c == " " { out += "%20" }
            else {
                let enc = encoding ?? .utf8
                let data = String(c).data(using: enc) ?? Data(String(c).utf8)
                for b in data { out += String(format: "%%%02X", b) }
            }
            i += 1
        }
        return out
    }

    /// 解码响应体：优先 指定编码 → 响应头 → HTML meta → UTF-8 → GBK
    static func decode(_ data: Data, charset: String?, contentType: String?) -> String {
        if let enc = encoding(named: charset), let s = String(data: data, encoding: enc) { return s }
        if let ct = contentType?.lowercased(), let r = ct.range(of: "charset=") {
            let name = ct[r.upperBound...].split(separator: ";").first.map(String.init)
            if let enc = encoding(named: name), let s = String(data: data, encoding: enc) { return s }
        }
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        if let r = head.range(of: #"charset\s*=\s*["']?([a-z0-9_\-]+)"#, options: .regularExpression) {
            let m = String(head[r])
            let name = m.components(separatedBy: "=").last?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if let enc = encoding(named: name), let s = String(data: data, encoding: enc) { return s }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: gbk) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    static func isJSON(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t.hasPrefix("{") && t.hasSuffix("}")) || (t.hasPrefix("[") && t.hasSuffix("]"))
    }

    static func unescapeHTML(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return (try? Entities.unescape(s)) ?? s
    }

    // MARK: 正文格式化（移植自 HtmlFormatter）
    private static let rx: [(String, String)] = [
        ("(&nbsp;)+", " "),
        ("(&ensp;|&emsp;)", " "),
        ("(&thinsp;|&zwnj;|&zwj;|\u{2009}|\u{200C}|\u{200D})", ""),
        ("</?(?:div|p|br|hr|h\\d|article|dd|dl)[^>]*>", "\n"),
        ("<!--[^>]*-->", ""),
    ]

    static func formatContent(_ html: String) -> String {
        var s = html
        for (p, r) in rx { s = s.replacingOccurrences(of: p, with: r, options: [.regularExpression, .caseInsensitive]) }
        // 图片替换成占位
        s = s.replacingOccurrences(of: "<img[^>]*>", with: "\n[图片]\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</?[a-zA-Z]+(?=[ >])[^<>]*>", with: "", options: .regularExpression)
        s = unescapeHTML(s)
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")
        s = s.replacingOccurrences(of: "\\s*\\n+\\s*", with: "\n　　", options: .regularExpression)
        s = s.replacingOccurrences(of: "^[\\n\\s]+", with: "　　", options: .regularExpression)
        s = s.replacingOccurrences(of: "[\\n\\s]+$", with: "", options: .regularExpression)
        return s
    }

    static func formatIntro(_ s: String?) -> String? {
        guard let s = s, !s.isEmpty else { return s }
        return formatContent(s)
    }

    static func formatBookName(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+作\\s*者.*|\\s+\\S+\\s+著", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func formatAuthor(_ s: String) -> String {
        s.replacingOccurrences(of: "^\\s*作\\s*者[:：\\s]+|\\s+著", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isTrue(_ s: String?) -> Bool {
        guard let s = s?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return false }
        return !["false", "no", "not", "0", "null", "undefined"].contains(s)
    }
}

/// 书源 put/get 变量存储（按 书源 / 书 / 章节 分区，持久化）
final class VariableStore {
    static let shared = VariableStore()
    private var data: [String: [String: String]]
    private let lock = NSLock()
    private let key = "yuedu.variables"

    private init() {
        data = (UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]]) ?? [:]
    }

    func get(_ scope: String, _ k: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return data[scope]?[k]
    }

    func put(_ scope: String, _ k: String, _ v: String) {
        lock.lock()
        data[scope, default: [:]][k] = v
        let snapshot = data
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: key)
    }

    func all(_ scope: String) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return data[scope] ?? [:]
    }

    func clear(_ scope: String) {
        lock.lock(); data[scope] = nil; lock.unlock()
    }

    func copy(from: String, to: String) {
        lock.lock()
        if let d = data[from] { data[to, default: [:]].merge(d) { _, n in n } }
        let snapshot = data
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: key)
    }

    /// 简易缓存 cache.put / cache.get
    private var cache: [String: String] = [:]
    func cacheGet(_ k: String) -> String? { lock.lock(); defer { lock.unlock() }; return cache[k] }
    func cachePut(_ k: String, _ v: String) { lock.lock(); cache[k] = v; lock.unlock() }
}

/// 调试日志
final class DebugLog: ObservableObject {
    @Published var lines: [String] = []
    func log(_ s: String) {
        let line = s.count > 3000 ? String(s.prefix(3000)) + "…(已截断)" : s
        if Thread.isMainThread { lines.append(line) }
        else { DispatchQueue.main.async { self.lines.append(line) } }
    }
}
