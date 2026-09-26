import Foundation

/// 精简版 JSONPath 实现，覆盖书源常用写法：
/// $.a.b  $['a']  $..a  [*]  [0]  [-1]  [0,2]  [1:3]  [?(@.x)]  [?(@.x == 'y')]  .length()
enum JSONPath {
    static func parse(_ text: String) -> Any? {
        guard let d = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    }

    /// 返回匹配到的所有值
    static func read(_ root: Any, _ path: String) -> [Any] {
        var p = path.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("$") { p.removeFirst() } else if p.hasPrefix("@") { p.removeFirst() }
        let tokens = tokenize(p)
        var current: [Any] = [root]
        var definite = true
        for t in tokens {
            var next: [Any] = []
            switch t {
            case .key(let k):
                if k == "length()" {
                    next = current.map { v -> Any in
                        if let a = v as? [Any] { return a.count }
                        if let s = v as? String { return s.count }
                        if let o = v as? [String: Any] { return o.count }
                        return 0
                    }
                } else {
                    for v in current {
                        if let o = v as? [String: Any], let x = o[k], !(x is NSNull) { next.append(x) }
                    }
                }
            case .keys(let ks):
                for v in current {
                    if let o = v as? [String: Any] {
                        for k in ks { if let x = o[k], !(x is NSNull) { next.append(x) } }
                    }
                }
                definite = false
            case .wildcard:
                definite = false
                for v in current {
                    if let a = v as? [Any] { next.append(contentsOf: a) }
                    else if let o = v as? [String: Any] { next.append(contentsOf: o.values) }
                }
            case .deep(let k):
                definite = false
                for v in current { collectDeep(v, k, &next) }
            case .indexes(let idx):
                if idx.count > 1 { definite = false }
                for v in current {
                    guard let a = v as? [Any] else { continue }
                    for i in idx {
                        let j = i < 0 ? a.count + i : i
                        if j >= 0 && j < a.count { next.append(a[j]) }
                    }
                }
            case .slice(let s, let e, let step):
                definite = false
                for v in current {
                    guard let a = v as? [Any] else { continue }
                    let n = a.count
                    var st = s ?? 0; if st < 0 { st += n }
                    var en = e ?? n; if en < 0 { en += n }
                    st = max(0, min(st, n)); en = max(0, min(en, n))
                    var i = st
                    while i < en { next.append(a[i]); i += max(step, 1) }
                }
            case .filter(let expr):
                definite = false
                for v in current {
                    let items: [Any]
                    if let a = v as? [Any] { items = a }
                    else if let o = v as? [String: Any] { items = Array(o.values) }
                    else { items = [] }
                    for it in items where evalFilter(expr, it) { next.append(it) }
                }
            }
            current = next
        }
        _ = definite
        return current
    }

    /// 作为列表读取（结果本身是数组时展开）
    static func readList(_ root: Any, _ path: String) -> [Any] {
        let r = read(root, path)
        if r.count == 1, let a = r[0] as? [Any] { return a }
        return r
    }

    static func stringify(_ v: Any) -> String {
        switch v {
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            let d = n.doubleValue
            if d == d.rounded() && abs(d) < 1e15 { return String(Int64(d)) }
            return "\(d)"
        case is NSNull: return ""
        default:
            if JSONSerialization.isValidJSONObject(v),
               let d = try? JSONSerialization.data(withJSONObject: v),
               let s = String(data: d, encoding: .utf8) { return s }
            return "\(v)"
        }
    }

    // MARK: - 私有

    private enum Token {
        case key(String), keys([String]), wildcard, deep(String?)
        case indexes([Int]), slice(Int?, Int?, Int), filter(String)
    }

    private static func collectDeep(_ v: Any, _ k: String?, _ out: inout [Any]) {
        if let o = v as? [String: Any] {
            if let k = k {
                if let x = o[k] { out.append(x) }
            } else { out.append(contentsOf: o.values) }
            for (_, c) in o { collectDeep(c, k, &out) }
        } else if let a = v as? [Any] {
            if k == nil { out.append(contentsOf: a) }
            for c in a { collectDeep(c, k, &out) }
        }
    }

    private static func tokenize(_ p: String) -> [Token] {
        var tokens: [Token] = []
        let c = Array(p)
        var i = 0
        func readName() -> String {
            var s = ""
            while i < c.count && c[i] != "." && c[i] != "[" { s.append(c[i]); i += 1 }
            return s
        }
        while i < c.count {
            if c[i] == "." {
                if i + 1 < c.count && c[i + 1] == "." {
                    i += 2
                    if i < c.count && c[i] == "*" { i += 1; tokens.append(.deep(nil)) }
                    else if i < c.count && c[i] == "[" { tokens.append(.deep(nil)) }
                    else { tokens.append(.deep(readName())) }
                } else {
                    i += 1
                    if i < c.count && c[i] == "*" { i += 1; tokens.append(.wildcard) }
                    else {
                        let n = readName()
                        if !n.isEmpty { tokens.append(.key(n)) }
                    }
                }
            } else if c[i] == "[" {
                // 找匹配的 ]
                var depth = 0, j = i
                var inQ: Character? = nil
                while j < c.count {
                    let ch = c[j]
                    if let q = inQ { if ch == q { inQ = nil } }
                    else if ch == "'" || ch == "\"" { inQ = ch }
                    else if ch == "[" { depth += 1 }
                    else if ch == "]" { depth -= 1; if depth == 0 { break } }
                    j += 1
                }
                let inner = String(c[(i + 1)..<min(j, c.count)]).trimmingCharacters(in: .whitespaces)
                i = j + 1
                tokens.append(parseBracket(inner))
            } else {
                let n = readName()
                if n == "*" { tokens.append(.wildcard) }
                else if !n.isEmpty { tokens.append(.key(n)) }
            }
        }
        return tokens
    }

    private static func parseBracket(_ s: String) -> Token {
        if s == "*" { return .wildcard }
        if s.hasPrefix("?") {
            var e = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            if e.hasPrefix("(") && e.hasSuffix(")") { e = String(e.dropFirst().dropLast()) }
            return .filter(e)
        }
        if s.hasPrefix("'") || s.hasPrefix("\"") {
            let parts = s.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            }
            return parts.count == 1 ? .key(parts[0]) : .keys(parts)
        }
        if s.contains(":") {
            let p = s.split(separator: ":", omittingEmptySubsequences: false).map {
                Int($0.trimmingCharacters(in: .whitespaces))
            }
            return .slice(p.count > 0 ? p[0] : nil, p.count > 1 ? p[1] : nil, p.count > 2 ? (p[2] ?? 1) : 1)
        }
        let nums = s.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if !nums.isEmpty { return .indexes(nums) }
        return .key(s)
    }

    /// 简单过滤表达式：@.a  @.a == 'x'  @.a != 1  @.a > 3  &&  ||
    private static func evalFilter(_ expr: String, _ item: Any) -> Bool {
        if expr.contains("||") {
            return expr.components(separatedBy: "||").contains { evalFilter($0.trimmingCharacters(in: .whitespaces), item) }
        }
        if expr.contains("&&") {
            return expr.components(separatedBy: "&&").allSatisfy { evalFilter($0.trimmingCharacters(in: .whitespaces), item) }
        }
        let ops = ["==", "!=", ">=", "<=", "=~", ">", "<"]
        for op in ops {
            if let r = expr.range(of: op) {
                let l = expr[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                let rv = expr[r.upperBound...].trimmingCharacters(in: .whitespaces)
                let lv = value(l, item)
                let rvv = value(rv, item)
                let ls = lv.map { stringify($0) } ?? ""
                let rs = rvv.map { stringify($0) } ?? ""
                switch op {
                case "==": return ls == rs
                case "!=": return ls != rs
                case "=~":
                    var pat = rs
                    if pat.hasPrefix("/") { pat.removeFirst() }
                    var opts: NSRegularExpression.Options = []
                    if pat.hasSuffix("/i") { pat = String(pat.dropLast(2)); opts.insert(.caseInsensitive) }
                    else if pat.hasSuffix("/") { pat.removeLast() }
                    return ls.range(of: pat, options: opts.contains(.caseInsensitive) ? [.regularExpression, .caseInsensitive] : .regularExpression) != nil
                default:
                    let a = Double(ls) ?? 0, b = Double(rs) ?? 0
                    switch op {
                    case ">": return a > b
                    case "<": return a < b
                    case ">=": return a >= b
                    default: return a <= b
                    }
                }
            }
        }
        // 只有 @.a：存在即真
        if let v = value(expr, item) {
            if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            return !(v is NSNull)
        }
        return false
    }

    private static func value(_ s: String, _ item: Any) -> Any? {
        if s.hasPrefix("@") {
            let r = read(item, s)
            return r.first
        }
        if (s.hasPrefix("'") && s.hasSuffix("'")) || (s.hasPrefix("\"") && s.hasSuffix("\"")) {
            return String(s.dropFirst().dropLast())
        }
        if s == "true" { return true }
        if s == "false" { return false }
        if s == "null" { return NSNull() }
        if let d = Double(s) { return NSNumber(value: d) }
        return s
    }
}

/// JSON 规则解析 —— 移植自 Legado AnalyzeByJSonPath
final class AnalyzeByJSonPath {
    private let ctx: Any

    init(_ json: Any) {
        if let s = json as? String { ctx = JSONPath.parse(s) ?? [String: Any]() }
        else { ctx = json }
    }

    func getString(_ rule: String) -> String? {
        if rule.isEmpty { return nil }
        let an = RuleSplitter(rule, code: true)
        let rules = an.splitRule("&&", "||")
        if rules.count == 1 {
            an.reSetPos()
            var result = an.innerRule("{$.") { self.getString($0) }
            if result.isEmpty {
                let r = JSONPath.read(ctx, rule)
                if r.isEmpty { return nil }
                if r.count == 1, let a = r[0] as? [Any] {
                    result = a.map { JSONPath.stringify($0) }.joined(separator: "\n")
                } else if r.count == 1 {
                    result = JSONPath.stringify(r[0])
                } else {
                    result = r.map { JSONPath.stringify($0) }.joined(separator: "\n")
                }
            }
            return result
        }
        var list: [String] = []
        for rl in rules {
            if let t = getString(rl), !t.isEmpty {
                list.append(t)
                if an.elementsType == "||" { break }
            }
        }
        return list.joined(separator: "\n")
    }

    func getStringList(_ rule: String) -> [String] {
        var result: [String] = []
        if rule.isEmpty { return result }
        let an = RuleSplitter(rule, code: true)
        let rules = an.splitRule("&&", "||", "%%")
        if rules.count == 1 {
            an.reSetPos()
            let st = an.innerRule("{$.") { self.getString($0) }
            if st.isEmpty {
                for o in JSONPath.readList(ctx, rule) { result.append(JSONPath.stringify(o)) }
            } else {
                result.append(st)
            }
            return result
        }
        var results: [[String]] = []
        for rl in rules {
            let t = getStringList(rl)
            if !t.isEmpty {
                results.append(t)
                if an.elementsType == "||" { break }
            }
        }
        if an.elementsType == "%%", let first = results.first {
            for i in 0..<first.count { for t in results where i < t.count { result.append(t[i]) } }
        } else {
            for t in results { result.append(contentsOf: t) }
        }
        return result
    }

    func getObject(_ rule: String) -> Any? {
        let r = JSONPath.read(ctx, rule)
        return r.count == 1 ? r[0] : (r.isEmpty ? nil : r)
    }

    func getList(_ rule: String) -> [Any] {
        if rule.isEmpty { return [] }
        let an = RuleSplitter(rule, code: true)
        let rules = an.splitRule("&&", "||", "%%")
        if rules.count == 1 {
            return JSONPath.readList(ctx, rules[0])
        }
        var results: [[Any]] = []
        for rl in rules {
            let t = getList(rl)
            if !t.isEmpty {
                results.append(t)
                if an.elementsType == "||" { break }
            }
        }
        var result: [Any] = []
        if an.elementsType == "%%", let first = results.first {
            for i in 0..<first.count { for t in results where i < t.count { result.append(t[i]) } }
        } else {
            for t in results { result.append(contentsOf: t) }
        }
        return result
    }
}
