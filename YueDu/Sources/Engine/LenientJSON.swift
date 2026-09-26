import Foundation

/// 仿 Gson 宽松模式（setLenient）的 JSON 解析器
/// Legado 用 GSON.fromJsonArray 解析 loginUi，能接受很多「不标准」的写法，iOS 自带解析器会直接失败：
/// - 字符串里直接有换行 / Tab（action 里写多行 JS 最常见）
/// - 单引号字符串、键名不加引号、值不加引号
/// - // 和 /* */ 注释、# 注释
/// - 结尾多余的逗号、用 ; 分隔、用 = 或 => 代替 :
enum LenientJSON {
    static func parse(_ text: String) -> Any? {
        var p = Parser(Array(text.unicodeScalars))
        p.skipWS()
        // 只接受对象或数组（避免把普通文本当成 JSON）
        guard let first = p.peek(), first == "[" || first == "{" else { return nil }
        guard let v = p.value() else { return nil }
        p.skipWS()
        // 后面只允许多余的 ; 或 ,
        while let c = p.peek(), c == ";" || c == "," { p.i += 1; p.skipWS() }
        return p.atEnd ? v : nil
    }

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        init(_ s: [Unicode.Scalar]) { self.s = s }

        var atEnd: Bool { i >= s.count }
        func peek(_ o: Int = 0) -> Unicode.Scalar? { i + o < s.count ? s[i + o] : nil }

        mutating func skipWS() {
            while let c = peek() {
                if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{FEFF}" || c == "\u{00A0}" { i += 1; continue }
                if c == "/" && peek(1) == "/" || c == "#" {
                    while let d = peek(), d != "\n" { _ = d; i += 1 }
                    continue
                }
                if c == "/" && peek(1) == "*" {
                    i += 2
                    while !atEnd && !(peek() == "*" && peek(1) == "/") { i += 1 }
                    i = min(s.count, i + 2)
                    continue
                }
                break
            }
        }

        mutating func value() -> Any? {
            skipWS()
            guard let c = peek() else { return nil }
            switch c {
            case "{": return object()
            case "[": return array()
            case "\"", "'": return string(c)
            default: return literal()
            }
        }

        mutating func object() -> [String: Any]? {
            i += 1
            var out: [String: Any] = [:]
            while true {
                skipWS()
                guard let c = peek() else { return nil }
                if c == "}" { i += 1; return out }
                if c == "," || c == ";" { i += 1; continue }
                let key: String
                if c == "\"" || c == "'" { key = string(c) ?? "" }
                else { key = unquoted(stopAt: ":=") }
                skipWS()
                if peek() == ":" { i += 1 }
                else if peek() == "=" { i += 1; if peek() == ">" { i += 1 } }
                else { return nil }
                guard let v = value() else { return nil }
                out[key] = v
                skipWS()
                if peek() == "," || peek() == ";" { i += 1 }
            }
        }

        mutating func array() -> [Any]? {
            i += 1
            var out: [Any] = []
            while true {
                skipWS()
                guard let c = peek() else { return nil }
                if c == "]" { i += 1; return out }
                if c == "," || c == ";" { i += 1; continue }
                guard let v = value() else { return nil }
                out.append(v)
            }
        }

        /// 引号字符串；允许里面有原样的换行、Tab
        mutating func string(_ q: Unicode.Scalar) -> String? {
            i += 1
            var out = String.UnicodeScalarView()
            while let c = peek() {
                i += 1
                if c == q { return String(out) }
                if c == "\\" {
                    guard let e = peek() else { break }
                    i += 1
                    switch e {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "b": out.append("\u{8}")
                    case "f": out.append("\u{C}")
                    case "u":
                        var hex = ""
                        while hex.count < 4, let h = peek(), h.properties.isASCIIHexDigit { hex.unicodeScalars.append(h); i += 1 }
                        if var code = UInt32(hex, radix: 16) {
                            // 代理对（emoji 等）
                            if (0xD800...0xDBFF).contains(code), peek() == "\\", peek(1) == "u" {
                                let save = i
                                i += 2
                                var hex2 = ""
                                while hex2.count < 4, let h = peek(), h.properties.isASCIIHexDigit { hex2.unicodeScalars.append(h); i += 1 }
                                if let lo = UInt32(hex2, radix: 16), (0xDC00...0xDFFF).contains(lo) {
                                    code = 0x10000 + ((code - 0xD800) << 10) + (lo - 0xDC00)
                                } else { i = save }
                            }
                            if let u = Unicode.Scalar(code) { out.append(u) }
                        }
                    default: out.append(e)   // \" \' \\ \/ 以及其他
                    }
                    continue
                }
                out.append(c)
            }
            return nil   // 字符串没闭合
        }

        /// 不加引号的键名 / 值
        mutating func unquoted(stopAt extra: String = "") -> String {
            var out = String.UnicodeScalarView()
            let stops: Set<Unicode.Scalar> = Set(",;}]:\n\r".unicodeScalars).union(extra.unicodeScalars)
            while let c = peek(), !stops.contains(c) {
                if c == "/" && (peek(1) == "/" || peek(1) == "*") { break }
                out.append(c); i += 1
            }
            return String(out).trimmingCharacters(in: .whitespaces)
        }

        mutating func literal() -> Any? {
            let t = unquoted(stopAt: "")
            if t.isEmpty { return nil }
            switch t {
            case "true": return true
            case "false": return false
            case "null", "undefined": return NSNull()
            default: break
            }
            if let n = Int(t) { return NSNumber(value: n) }
            if let d = Double(t) { return NSNumber(value: d) }
            return t
        }
    }
}
