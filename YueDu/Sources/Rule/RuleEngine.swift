import Foundation
import JavaScriptCore
import SwiftSoup

/// 规则分析器 —— 对应 Legado AnalyzeRule
final class RuleEngine {
    enum Mode { case xpath, json, `default`, js, regex, webJs }

    let source: BookSource?
    var book: Book?
    var chapter: BookChapter?
    var nextChapterUrl: String?
    var logger: DebugLog?
    /// JS 出错时回调（登录流程用它把错误显示给用户）
    var onJSError: ((String) -> Void)?
    var lastError: String?
    /// 登录界面（书源脚本 java.upLoginData / reLoginView 回调到这里）
    weak var loginCallback: LoginUICallback?

    private(set) var content: Any?
    private(set) var baseUrl: String?
    private(set) var redirectUrl: String?
    private var isJSON = false
    private var isRegex = false
    private var jsCtx: JSContext?
    // 同一份内容只解析一次
    private var cacheJsoup: AnalyzeByJSoup?
    private var cacheXPath: AnalyzeByXPath?
    private var cacheJson: AnalyzeByJSonPath?

    private func jsoup(_ o: Any, _ isContent: Bool) -> AnalyzeByJSoup {
        guard isContent else { return AnalyzeByJSoup(o) }
        if let c = cacheJsoup { return c }
        let a = AnalyzeByJSoup(o); cacheJsoup = a; return a
    }
    private func xpath(_ o: Any, _ isContent: Bool) -> AnalyzeByXPath {
        guard isContent else { return AnalyzeByXPath(o) }
        if let c = cacheXPath { return c }
        let a = AnalyzeByXPath(o); cacheXPath = a; return a
    }
    private func json(_ o: Any, _ isContent: Bool) -> AnalyzeByJSonPath {
        guard isContent else { return AnalyzeByJSonPath(o) }
        if let c = cacheJson { return c }
        let a = AnalyzeByJSonPath(o); cacheJson = a; return a
    }

    init(source: BookSource?, book: Book? = nil, logger: DebugLog? = nil) {
        self.source = source
        self.book = book
        self.logger = logger
    }

    func log(_ s: String) { logger?.log(s) }

    @discardableResult
    func setContent(_ content: Any, baseUrl: String? = nil) -> RuleEngine {
        self.content = content
        if content is Element { isJSON = false }
        else if content is [String] { isJSON = false }
        else if content is [String: Any] || content is [Any] { isJSON = true }
        else { isJSON = Util.isJSON(AnalyzeByJSoup.stringOf(content)) }
        if let b = baseUrl { self.baseUrl = b }
        cacheJsoup = nil; cacheXPath = nil; cacheJson = nil
        return self
    }

    func setBaseUrl(_ u: String?) { if let u = u { baseUrl = u } }
    func setRedirectUrl(_ u: String) { redirectUrl = u }

    // MARK: - 变量

    private var bookScope: String? { book.map { "book:" + $0.bookUrl } }
    private var sourceScope: String { "src:" + (source?.bookSourceUrl ?? "") }

    func put(_ k: String, _ v: String) {
        if let c = chapter { VariableStore.shared.put("chap:" + c.url, k, v) }
        if let s = bookScope { VariableStore.shared.put(s, k, v) }
        VariableStore.shared.put(sourceScope, k, v)
    }

    func get(_ k: String) -> String {
        if k == "bookName", let b = book { return b.name }
        if k == "title", let c = chapter { return c.title }
        if let c = chapter, let v = VariableStore.shared.get("chap:" + c.url, k) { return v }
        if let s = bookScope, let v = VariableStore.shared.get(s, k) { return v }
        return VariableStore.shared.get(sourceScope, k) ?? ""
    }

    // MARK: - JS

    private func context() -> JSContext {
        if let c = jsCtx { return c }
        let c = JSEngine.shared.makeContext(vm: JSVirtualMachine())
        let java = JavaBridge(engine: self)
        c.setObject(java, forKeyedSubscript: "java" as NSString)
        c.evaluateScript("__setupJava(java);")
        c.setObject(CookieBridge(), forKeyedSubscript: "cookie" as NSString)
        c.setObject(CacheBridge(), forKeyedSubscript: "cache" as NSString)
        c.setObject(SourceBridge(source), forKeyedSubscript: "source" as NSString)
        c.evaluateScript("__setupSource(source);")
        if let lib = source?.jsLib, !lib.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for code in JsLibLoader.scripts(lib) {
                if let e = JSEngine.run(c, code) as? JSEngine.JSError { log("jsLib 出错：\(e.message)") }
            }
        }
        jsCtx = c
        return c
    }

    func evalJS(_ js: String, result: Any?, extra: [String: Any] = [:]) -> Any? {
        let c = context()
        c.setObject(toJS(result), forKeyedSubscript: "result" as NSString)
        c.setObject(baseUrl ?? source?.bookSourceUrl ?? "", forKeyedSubscript: "baseUrl" as NSString)
        c.setObject(toJS(content), forKeyedSubscript: "src" as NSString)
        c.setObject(nextChapterUrl ?? "", forKeyedSubscript: "nextChapterUrl" as NSString)
        if let b = book {
            let bo: [String: Any] = ["name": b.name, "author": b.author, "bookUrl": b.bookUrl, "tocUrl": b.tocUrl ?? "",
                                     "origin": b.origin, "intro": b.intro ?? "", "coverUrl": b.coverUrl ?? "", "kind": b.kind ?? ""]
            c.setObject(bo, forKeyedSubscript: "book" as NSString)
            c.evaluateScript("book.getVariable=function(k){return java.getVar(k)};book.putVariable=function(k,v){return java.put(k,v)};")
        }
        if let ch = chapter {
            c.setObject(["title": ch.title, "url": ch.url, "index": ch.index] as [String: Any], forKeyedSubscript: "chapter" as NSString)
            c.setObject(ch.title, forKeyedSubscript: "title" as NSString)
        }
        for (k, v) in extra { c.setObject(v, forKeyedSubscript: k as NSString) }
        let r = JSEngine.run(c, js)
        if let e = r as? JSEngine.JSError { log(e.message); onJSError?(e.message); return nil }
        return r
    }

    private func toJS(_ v: Any?) -> Any {
        guard let v = v else { return NSNull() }
        if let e = v as? Element { return (try? e.outerHtml()) ?? "" }
        if let a = v as? [Any] { return a.map { toJS($0) } }
        return v
    }

    // MARK: - 规则拆分

    final class SourceRule {
        var mode: Mode
        var rule: String
        var replaceRegex = ""
        var replacement = ""
        var replaceFirst = false
        var putMap: [String: String] = [:]
        fileprivate var params: [String] = []
        fileprivate var types: [Int] = []   // -2 @get  -1 {{js}}  0 普通  >0 $n

        init(_ ruleStr: String, _ mode0: Mode, isJSON: Bool) {
            var mode = mode0
            var r: String
            let lower = ruleStr.lowercased()
            if mode == .js || mode == .regex { r = ruleStr }
            else if lower.hasPrefix("@css:") { mode = .default; r = ruleStr }
            else if ruleStr.hasPrefix("@@") { mode = .default; r = String(ruleStr.dropFirst(2)) }
            else if lower.hasPrefix("@xpath:") { mode = .xpath; r = String(ruleStr.dropFirst(7)) }
            else if lower.hasPrefix("@json:") { mode = .json; r = String(ruleStr.dropFirst(6)) }
            else if isJSON || ruleStr.hasPrefix("$.") || ruleStr.hasPrefix("$[") { mode = .json; r = ruleStr }
            else if ruleStr.hasPrefix("/") { mode = .xpath; r = ruleStr }
            else { r = ruleStr }
            self.mode = mode
            self.rule = r
            // @put:{...}
            let putRx = try! NSRegularExpression(pattern: "@put:(\\{[^}]+?\\})", options: .caseInsensitive)
            while let m = putRx.firstMatch(in: rule, range: NSRange(location: 0, length: (rule as NSString).length)) {
                let ns = rule as NSString
                let js = ns.substring(with: m.range(at: 1))
                if let o = AnalyzeUrl.parseLooseJSON(js) { for (k, v) in o { putMap[k] = "\(v)" } }
                rule = ns.replacingCharacters(in: m.range, with: "")
            }
            // @get:{} 与 {{}}
            let evalRx = try! NSRegularExpression(pattern: "@get:\\{[^}]+?\\}|\\{\\{[\\w\\W]*?\\}\\}", options: .caseInsensitive)
            let ns = rule as NSString
            let ms = evalRx.matches(in: rule, range: NSRange(location: 0, length: ns.length))
            var start = 0
            if let first = ms.first {
                let pre = ns.substring(to: first.range.location)
                if self.mode != .js && self.mode != .regex && (first.range.location == 0 || !pre.contains("##")) {
                    self.mode = .regex
                }
                for m in ms {
                    if m.range.location > start {
                        splitRegex(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
                    }
                    let t = ns.substring(with: m.range)
                    if t.lowercased().hasPrefix("@get:") {
                        types.append(-2); params.append(String(t.dropFirst(6).dropLast()))
                    } else if t.hasPrefix("{{") {
                        types.append(-1); params.append(String(t.dropFirst(2).dropLast(2)))
                    } else { splitRegex(t) }
                    start = m.range.location + m.range.length
                }
            }
            if ns.length > start { splitRegex(ns.substring(from: start)) }
        }

        private func splitRegex(_ s: String) {
            let parts = s.components(separatedBy: "##")
            let rx = try! NSRegularExpression(pattern: "\\$\\d{1,2}")
            let first = parts[0] as NSString
            let ms = rx.matches(in: parts[0], range: NSRange(location: 0, length: first.length))
            var start = 0
            let ns = s as NSString
            if !ms.isEmpty {
                if mode != .js && mode != .regex { mode = .regex }
                for m in ms {
                    if m.range.location > start {
                        types.append(0); params.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
                    }
                    let t = ns.substring(with: m.range)
                    types.append(Int(t.dropFirst()) ?? 0); params.append(t)
                    start = m.range.location + m.range.length
                }
            }
            if ns.length > start { types.append(0); params.append(ns.substring(from: start)) }
        }

        var paramCount: Int { params.count }

        /// 替换 @get / {{}} / $n，得到最终规则
        func makeUp(_ result: Any?, _ engine: RuleEngine) {
            if !params.isEmpty {
                var s = ""
                for i in 0..<params.count {
                    let t = types[i]
                    if t > 0 {
                        if let list = result as? [String], list.count > t { s += list[t] }
                        else if let list = result as? [Any], list.count > t { s += "\(list[t])" }
                        else { s += params[i] }
                    } else if t == -1 {
                        let p = params[i]
                        if p.hasPrefix("@") || p.hasPrefix("$.") || p.hasPrefix("$[") || p.hasPrefix("//") {
                            s += engine.getString(p)
                        } else {
                            s += JSEngine.stringify(engine.evalJS(p, result: result))
                        }
                    } else if t == -2 {
                        s += engine.get(params[i])
                    } else {
                        s += params[i]
                    }
                }
                rule = s
            }
            let parts = rule.components(separatedBy: "##")
            rule = parts[0].trimmingCharacters(in: .whitespaces)
            if parts.count > 1 { replaceRegex = parts[1] }
            if parts.count > 2 { replacement = parts[2] }
            if parts.count > 3 { replaceFirst = true }
        }
    }

    func splitSourceRule(_ ruleStr: String?, allInOne: Bool = false) -> [SourceRule] {
        guard let ruleStr = ruleStr, !ruleStr.isEmpty else { return [] }
        var list: [SourceRule] = []
        var mode: Mode = .default
        var start = 0
        let ns = ruleStr as NSString
        if allInOne && ruleStr.hasPrefix(":") {
            mode = .regex; isRegex = true; start = 1
        } else if isRegex { mode = .regex }

        let jsRx = try! NSRegularExpression(pattern: "<js>([\\w\\W]*?)</js>|@js:([\\w\\W]*)", options: .caseInsensitive)
        for m in jsRx.matches(in: ruleStr, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > start {
                let t = ns.substring(with: NSRange(location: start, length: m.range.location - start)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { list.append(SourceRule(t, mode, isJSON: isJSON)) }
            }
            let g = m.range(at: 2).location != NSNotFound ? m.range(at: 2) : m.range(at: 1)
            list.append(SourceRule(ns.substring(with: g), .js, isJSON: isJSON))
            start = m.range.location + m.range.length
        }
        let webRx = try! NSRegularExpression(pattern: "@webjs:([\\w\\W]{5,})", options: .caseInsensitive)
        if start < ns.length {
            let rest = ns.substring(from: start)
            if let m = webRx.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) {
                let rn = rest as NSString
                if m.range.location > 0 {
                    let t = rn.substring(to: m.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { list.append(SourceRule(t, mode, isJSON: isJSON)) }
                }
                list.append(SourceRule(rn.substring(with: m.range(at: 1)), .webJs, isJSON: isJSON))
                start = ns.length
            }
        }
        if ns.length > start {
            let t = ns.substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { list.append(SourceRule(t, mode, isJSON: isJSON)) }
        }
        return list
    }

    private func putRule(_ map: [String: String]) {
        for (k, v) in map { put(k, getString(v)) }
    }

    private func replaceRegex(_ result: String, _ r: SourceRule) -> String {
        if r.replaceRegex.isEmpty { return result }
        guard let rx = try? NSRegularExpression(pattern: r.replaceRegex, options: []) else {
            return r.replaceFirst ? r.replacement : result.replacingOccurrences(of: r.replaceRegex, with: r.replacement)
        }
        let ns = result as NSString
        // Java 的 $1 与 NSRegularExpression 模板一致
        if r.replaceFirst {
            guard let m = rx.firstMatch(in: result, range: NSRange(location: 0, length: ns.length)) else { return "" }
            let matched = ns.substring(with: m.range)
            return rx.stringByReplacingMatches(in: matched, range: NSRange(location: 0, length: (matched as NSString).length),
                                               withTemplate: r.replacement).components(separatedBy: "\u{0}").first ?? ""
        }
        return rx.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: ns.length), withTemplate: r.replacement)
    }

    private func webJs(_ js: String, _ result: Any) -> String {
        let html = AnalyzeByJSoup.stringOf(content ?? "")
        return (try? WebViewLoader.load(url: baseUrl ?? "", html: html, headers: source?.headerMap() ?? [:], js: js).body) ?? ""
    }

    // MARK: - 取值

    func getStringList(_ rule: String?, content mContent: Any? = nil, isUrl: Bool = false) -> [String]? {
        guard let rule = rule, !rule.isEmpty else { return nil }
        let rules = splitSourceRule(rule)
        guard var result: Any = mContent ?? content, !rules.isEmpty else { return nil }
        let fromContent = mContent == nil
        for (step, sr) in rules.enumerated() {
            putRule(sr.putMap)
            sr.makeUp(result, self)
            let r = sr.rule
            let isC = fromContent && step == 0
            if !r.isEmpty {
                switch sr.mode {
                case .js: result = evalJS(r, result: result) ?? ""
                case .webJs: result = webJs(r, result)
                case .json: result = json(result, isC).getStringList(r)
                case .xpath: result = xpath(result, isC).getStringList(r)
                case .default: result = jsoup(result, isC).getStringList(r)
                case .regex: result = r
                }
            }
            if !sr.replaceRegex.isEmpty {
                if let list = result as? [Any] { result = list.map { replaceRegex(JSEngine.stringify($0), sr) } }
                else { result = replaceRegex(JSEngine.stringify(result), sr) }
            }
        }
        var list: [String]
        if let s = result as? String { list = s.components(separatedBy: "\n") }
        else if let a = result as? [String] { list = a }
        else if let a = result as? [Any] { list = a.map { JSEngine.stringify($0) } }
        else { list = [JSEngine.stringify(result)] }
        if isUrl {
            var urls: [String] = []
            for u in list {
                let abs = Util.absoluteURL(redirectUrl ?? baseUrl, u)
                if !abs.isEmpty && !urls.contains(abs) { urls.append(abs) }
            }
            return urls
        }
        return list
    }

    func getString(_ ruleStr: String?, content mContent: Any? = nil, isUrl: Bool = false, unescape: Bool = true) -> String {
        guard let ruleStr = ruleStr, !ruleStr.isEmpty else { return "" }
        let rules = splitSourceRule(ruleStr)
        var result: Any? = mContent ?? content
        let fromContent = mContent == nil
        if result != nil {
            for (step, sr) in rules.enumerated() {
                putRule(sr.putMap)
                sr.makeUp(result, self)
                guard let cur = result else { continue }
                let r = sr.rule
                let isC = fromContent && step == 0
                if !r.trimmingCharacters(in: .whitespaces).isEmpty || sr.replaceRegex.isEmpty {
                    switch sr.mode {
                    case .js: result = evalJS(r, result: cur)
                    case .webJs: result = webJs(r, cur)
                    case .json: result = json(cur, isC).getString(r)
                    case .xpath: result = xpath(cur, isC).getString(r)
                    case .default: result = isUrl ? jsoup(cur, isC).getString0(r) : jsoup(cur, isC).getString(r)
                    case .regex: result = r
                    }
                }
                if let cur2 = result, !sr.replaceRegex.isEmpty {
                    result = replaceRegex(JSEngine.stringify(cur2), sr)
                }
            }
        }
        var str = JSEngine.stringify(result)
        if unescape { str = Util.unescapeHTML(str) }
        if isUrl {
            return str.trimmingCharacters(in: .whitespaces).isEmpty ? (baseUrl ?? "") : Util.absoluteURL(redirectUrl ?? baseUrl, str)
        }
        return str
    }

    func getElement(_ ruleStr: String) -> Any? {
        let rules = splitSourceRule(ruleStr, allInOne: true)
        guard var result: Any = content, !rules.isEmpty else { return nil }
        for sr in rules {
            putRule(sr.putMap)
            sr.makeUp(result, self)
            let r = sr.rule
            switch sr.mode {
            case .regex: result = AnalyzeByRegex.getElement(JSEngine.stringify(result), r.components(separatedBy: "&&").filter { !$0.isEmpty }) ?? []
            case .js: result = evalJS(r, result: result) ?? ""
            case .webJs: result = webJs(r, result)
            case .json: result = AnalyzeByJSonPath(result).getObject(r) ?? ""
            case .xpath: result = AnalyzeByXPath(result).getElements(r)
            case .default: result = AnalyzeByJSoup(result).getElements(r)
            }
            if !sr.replaceRegex.isEmpty { result = replaceRegex(JSEngine.stringify(result), sr) }
        }
        return result
    }

    /// 列表规则：返回每一项（Element / JSON 对象 / 正则分组数组 / HTML 片段）
    func getElements(_ ruleStr: String) -> [Any] {
        let rules = splitSourceRule(ruleStr, allInOne: true)
        guard var result: Any = content, !rules.isEmpty else { return [] }
        for (step, sr) in rules.enumerated() {
            let first = step == 0
            putRule(sr.putMap)
            let r = sr.rule
            switch sr.mode {
            case .regex: result = AnalyzeByRegex.getElements(JSEngine.stringify(result), r.components(separatedBy: "&&").filter { !$0.isEmpty })
            case .js:
                let v = evalJS(r, result: result)
                if let s = v as? String, let j = JSONPath.parse(s), j is [Any] { result = j } else { result = v ?? [] }
            case .webJs:
                let s = webJs(r, result)
                result = JSONPath.parse(s) as? [Any] ?? []
            case .json: result = json(result, first).getList(r)
            case .xpath: result = xpath(result, first).getElements(r)
            case .default: result = jsoup(result, first).getElements(r)
            }
        }
        if let a = result as? [Any] { return a }
        return []
    }
}
