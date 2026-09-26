import Foundation

struct HTTPResponse {
    var url: String          // 最终地址（重定向后）
    var body: String
    var data: Data
    var code: Int
    var headers: [String: String]
}

/// 同步 HTTP 客户端（只能在后台线程调用）
enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 40
        c.httpCookieStorage = HTTPCookieStorage.shared
        c.httpShouldSetCookies = true
        c.httpCookieAcceptPolicy = .always
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    static func request(url: String, method: String = "GET", headers: [String: String] = [:],
                        body: Data? = nil, charset: String? = nil, retry: Int = 0) throws -> HTTPResponse {
        guard let u = URL(string: url) ?? URL(string: Util.encodeLoose(url)) else {
            throw YueDuError.message("网址无效：\(url)")
        }
        var req = URLRequest(url: u)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue(BookSource.defaultUA, forHTTPHeaderField: "User-Agent")
        }
        if let b = body {
            req.httpBody = b
            if req.value(forHTTPHeaderField: "Content-Type") == nil {
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        }
        var lastError: Error?
        for _ in 0...max(0, retry) {
            let sem = DispatchSemaphore(value: 0)
            var out: (Data?, URLResponse?, Error?) = (nil, nil, nil)
            let task = session.dataTask(with: req) { d, r, e in out = (d, r, e); sem.signal() }
            task.resume()
            sem.wait()
            if let e = out.2 { lastError = e; continue }
            let http = out.1 as? HTTPURLResponse
            let data = out.0 ?? Data()
            var hs: [String: String] = [:]
            http?.allHeaderFields.forEach { hs["\($0.key)"] = "\($0.value)" }
            let text = Util.decode(data, charset: charset, contentType: hs["Content-Type"] ?? hs["content-type"])
            return HTTPResponse(url: http?.url?.absoluteString ?? url, body: text, data: data,
                                code: http?.statusCode ?? 0, headers: hs)
        }
        throw lastError ?? YueDuError.message("请求失败：\(url)")
    }
}

/// 解析书源里的 URL 规则，例如：
///   https://x.com/search?q={{key}}&p={{page}}
///   /s.php,{"method":"POST","body":"key={{key}}","charset":"gbk"}
///   @js: ... / <js>...</js>
///   <1,2,3> 分页写法
final class AnalyzeUrl {
    private(set) var url = ""
    private(set) var ruleUrl = ""
    private(set) var method = "GET"
    private(set) var headers: [String: String] = [:]
    private(set) var body: String?
    private(set) var charset: String?
    private(set) var retry = 0
    private(set) var useWebView = false
    private(set) var webJs: String?
    private(set) var type: String?
    private var baseUrl: String

    let key: String?
    let page: Int?
    let source: BookSource?
    let book: Book?
    let engine: RuleEngine

    init(_ mUrl: String, key: String? = nil, page: Int? = nil, baseUrl: String = "",
         source: BookSource?, book: Book? = nil, engine: RuleEngine? = nil) {
        self.key = key
        self.page = page
        self.source = source
        self.book = book
        self.engine = engine ?? RuleEngine(source: source, book: book)
        var b = baseUrl.isEmpty ? (source?.bookSourceUrl ?? "") : baseUrl
        if let r = b.range(of: #"\s*,\s*(?=\{)"#, options: .regularExpression) { b = String(b[..<r.lowerBound]) }
        self.baseUrl = b
        self.headers = source?.headerMap() ?? ["User-Agent": BookSource.defaultUA]
        self.ruleUrl = AnalyzeUrl.upgradeOld(mUrl)
        analyzeJs()
        replaceKeyPageJs()
        analyzeUrl()
    }

    /// 兼容老版本书源：searchKey / searchPage
    private static func upgradeOld(_ s: String) -> String {
        var u = s
        if u.contains("searchKey") && !u.contains("{{") {
            u = u.replacingOccurrences(of: "searchKey", with: "{{key}}")
            u = u.replacingOccurrences(of: "searchPage-1", with: "{{page-1}}")
            u = u.replacingOccurrences(of: "searchPage+1", with: "{{page+1}}")
            u = u.replacingOccurrences(of: "searchPage", with: "{{page}}")
        }
        return u
    }

    private var jsBindings: [String: Any] {
        var b: [String: Any] = ["baseUrl": baseUrl]
        if let k = key { b["key"] = k }
        if let p = page { b["page"] = p }
        return b
    }

    private func analyzeJs() {
        let pattern = try! NSRegularExpression(pattern: "<js>([\\w\\W]*?)</js>|@js:([\\w\\W]*)", options: [.caseInsensitive])
        let ns = ruleUrl as NSString
        let matches = pattern.matches(in: ruleUrl, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return }
        var start = 0
        var result = ruleUrl
        for m in matches {
            if m.range.location > start {
                let t = ns.substring(with: NSRange(location: start, length: m.range.location - start))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { result = t.replacingOccurrences(of: "@result", with: result) }
            }
            let js = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ns.substring(with: m.range(at: 1))
            var b = jsBindings; b["result"] = result
            result = JSEngine.stringify(engine.evalJS(js, result: result, extra: b))
            start = m.range.location + m.range.length
        }
        if ns.length > start {
            let t = ns.substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { result = t.replacingOccurrences(of: "@result", with: result) }
        }
        ruleUrl = result
    }

    private func replaceKeyPageJs() {
        if ruleUrl.contains("{{") && ruleUrl.contains("}}") {
            let an = RuleSplitter(ruleUrl)
            let u = an.innerRule("{{", "}}") { js in
                let r = self.engine.evalJS(js, result: nil, extra: self.jsBindings)
                return JSEngine.stringify(r)
            }
            if !u.isEmpty { ruleUrl = u }
        }
        if let page = page {
            let rx = try! NSRegularExpression(pattern: "<(.*?)>")
            while let m = rx.firstMatch(in: ruleUrl, range: NSRange(location: 0, length: (ruleUrl as NSString).length)) {
                let ns = ruleUrl as NSString
                let pages = ns.substring(with: m.range(at: 1)).components(separatedBy: ",")
                let pick = page < pages.count ? pages[page - 1] : pages.last!
                ruleUrl = ns.replacingCharacters(in: m.range, with: pick.trimmingCharacters(in: .whitespaces))
            }
        }
    }

    private func analyzeUrl() {
        var urlNoOption = ruleUrl
        var optionStr: String?
        if let r = ruleUrl.range(of: #"\s*,\s*(?=\{)"#, options: .regularExpression) {
            urlNoOption = String(ruleUrl[..<r.lowerBound])
            optionStr = String(ruleUrl[r.upperBound...])
        }
        url = Util.absoluteURL(baseUrl, urlNoOption)
        baseUrl = Util.baseUrl(of: url)
        if let os = optionStr, let opt = AnalyzeUrl.parseLooseJSON(os) {
            if let m = opt["method"] as? String { method = m.uppercased() == "POST" ? "POST" : (m.uppercased() == "HEAD" ? "HEAD" : "GET") }
            if let h = opt["headers"] {
                var hm: [String: Any]? = h as? [String: Any]
                if hm == nil, let hs = h as? String { hm = AnalyzeUrl.parseLooseJSON(hs) }
                hm?.forEach { headers[$0.key] = "\($0.value)" }
            }
            if let b = opt["body"] {
                if let s = b as? String { body = s }
                else { body = JSONPath.stringify(b) }
            }
            type = opt["type"] as? String
            charset = opt["charset"] as? String
            if let r = opt["retry"] { retry = Int("\(r)") ?? 0 }
            if let w = opt["webView"] { useWebView = Util.isTrue("\(w)") }
            webJs = opt["webJs"] as? String
            if let js = opt["js"] as? String {
                var b = jsBindings; b["result"] = url
                if let r = engine.evalJS(js, result: url, extra: b) { url = JSEngine.stringify(r) }
            }
        }
    }

    /// 宽松 JSON：兼容单引号、键不加引号
    static func parseLooseJSON(_ s: String) -> [String: Any]? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = t.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return o }
        // 用 JS 引擎解析宽松写法
        if let r = JSEngine.shared.eval("(\(t))", bindings: [:]) as? [String: Any] { return r }
        return nil
    }

    /// 编码 key=value&key2=value2
    private func encodeParams(_ params: String) -> String {
        let enc = charset == "escape" ? nil : Util.encoding(named: charset)
        return params.components(separatedBy: "&").map { pair -> String in
            guard let eq = pair.firstIndex(of: "=") else { return Util.urlEncode(pair, encoding: enc) }
            let k = String(pair[..<eq]), v = String(pair[pair.index(after: eq)...])
            if charset == "escape" {
                return k + "=" + (JSEngine.shared.eval("escape(v)", bindings: ["v": v]) as? String ?? v)
            }
            return Util.urlEncode(k, encoding: enc) + "=" + Util.urlEncode(v, encoding: enc)
        }.joined(separator: "&")
    }

    /// 最终要请求的 URL（GET 时编码查询串）
    var requestUrl: String {
        guard method != "POST", let q = url.firstIndex(of: "?") else { return url }
        let path = String(url[..<q])
        let query = String(url[url.index(after: q)...])
        return path + "?" + encodeParams(query)
    }

    func fetch() throws -> HTTPResponse {
        var bodyData: Data?
        if method == "POST", let b = body {
            let ct = headers.first { $0.key.lowercased() == "content-type" }?.value
            if Util.isJSON(b) {
                bodyData = b.data(using: .utf8)
                if ct == nil { headers["Content-Type"] = "application/json; charset=UTF-8" }
            } else if ct != nil {
                bodyData = b.data(using: Util.encoding(named: charset) ?? .utf8)
            } else {
                bodyData = encodeParams(b).data(using: .utf8)
            }
        }
        if useWebView {
            return try WebViewLoader.load(url: requestUrl, headers: headers, js: webJs)
        }
        return try HTTP.request(url: requestUrl, method: method, headers: headers,
                                body: bodyData, charset: charset, retry: retry)
    }
}
