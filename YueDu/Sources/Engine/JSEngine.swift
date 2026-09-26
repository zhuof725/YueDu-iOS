import Foundation
import JavaScriptCore
import CryptoKit
import SwiftSoup

/// JavaScript 引擎 —— 用 iOS 自带的 JavaScriptCore 执行书源里的 @js: / {{ }} / <js></js>
final class JSEngine {
    static let shared = JSEngine()
    private let vm = JSVirtualMachine()
    private let lock = NSRecursiveLock()

    /// 每次执行创建新的 context（书源脚本互不干扰），共用一个虚拟机
    func makeContext(vm custom: JSVirtualMachine? = nil) -> JSContext {
        let ctx = JSContext(virtualMachine: custom ?? vm)!
        ctx.exceptionHandler = { c, e in c?.exception = e }
        // 常用 polyfill
        ctx.evaluateScript(JSEngine.polyfill)
        return ctx
    }

    func eval(_ script: String, bindings: [String: Any]) -> Any? {
        lock.lock(); defer { lock.unlock() }
        let ctx = makeContext()
        for (k, v) in bindings { ctx.setObject(v, forKeyedSubscript: k as NSString) }
        return JSEngine.run(ctx, script)
    }

    static func run(_ ctx: JSContext, _ script: String) -> Any? {
        ctx.exception = nil
        let v = ctx.evaluateScript(script)
        if let e = ctx.exception {
            let msg = e.toString() ?? "JS 错误"
            let line = e.forProperty("line")?.toInt32() ?? 0
            let err = "JS 执行出错(第\(line)行): \(msg)"
            ctx.setObject(nil, forKeyedSubscript: "__err" as NSString)
            ctx.exception = nil
            return JSError(message: err)
        }
        return toSwift(v)
    }

    struct JSError { let message: String }

    static func toSwift(_ v: JSValue?) -> Any? {
        guard let v = v, !v.isUndefined, !v.isNull else { return nil }
        if v.isString { return v.toString() }
        if v.isBoolean { return v.toBool() }
        if v.isNumber { return v.toNumber() }
        if v.isArray { return v.toArray() }
        if v.isObject {
            if let o = v.toObject() { return o }
        }
        return v.toString()
    }

    static func stringify(_ v: Any?) -> String {
        guard let v = v else { return "" }
        if let e = v as? JSError { return e.message }
        if let s = v as? String { return s }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            let d = n.doubleValue
            if d == d.rounded() && abs(d) < 1e15 { return String(Int64(d)) }
            return "\(d)"
        }
        if let a = v as? [Any] { return a.map { stringify($0) }.joined(separator: "\n") }
        if JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v) {
            return String(data: d, encoding: .utf8) ?? ""
        }
        return "\(v)"
    }

    static let polyfill = """
    var console = { log: function(){ var a=[]; for (var i=0;i<arguments.length;i++) a.push(String(arguments[i])); if (typeof java!=='undefined') java.log(a.join(' ')); } };
    var String2 = String;
    if (!String.prototype.replaceAll) { String.prototype.replaceAll = function(a,b){ return this.split(a).join(b); }; }
    function __setupJava(j){
      if (!j) return;
      j.get = function(a,b){ return arguments.length>=2 ? j.httpGet(a,b) : j.getVar(a); };
      j.encodeURI = function(a,b){ return b ? j.encodeURIWith(String(a),String(b)) : j.encodeURIWith(String(a),'UTF-8'); };
      j.getString = function(r,a,b){ if (typeof a==='boolean') return j.getStringUrl(r,a); if (typeof b==='boolean') { if (a!=null) j.setContent(a); return j.getStringUrl(r,b);} if (a!=null && a!==undefined) j.setContent(a); return j.getStringUrl(r,false); };
    }
    if (!Array.prototype.flat) { Array.prototype.flat = function(){ return [].concat.apply([], this); }; }
    """
}

// MARK: - java 对象（书源脚本里的 java.xxx）

@objc protocol JavaBridgeExports: JSExport {
    func ajax(_ url: String) -> String
    func ajaxAll(_ urls: [String]) -> [String]
    func httpGet(_ url: String, _ headers: [String: String]) -> Any
    func post(_ url: String, _ body: String, _ headers: [String: String]) -> Any
    func connect(_ url: String) -> Any
    func log(_ msg: Any?) -> Any?
    func logType(_ o: Any?)
    func toast(_ msg: Any?)
    func longToast(_ msg: Any?)
    func md5Encode(_ s: String) -> String
    func md5Encode16(_ s: String) -> String
    func base64Encode(_ s: String) -> String
    func base64Decode(_ s: String) -> String
    func base64DecodeToByteArray(_ s: String) -> [Int]
    func hexEncodeToString(_ s: String) -> String
    func hexDecodeToString(_ s: String) -> String
    func strToBytes(_ s: String) -> [Int]
    func bytesToStr(_ b: [Int]) -> String
    func encodeURI(_ s: String) -> String
    func encodeURIWith(_ s: String, _ enc: String) -> String
    func htmlFormat(_ s: String) -> String
    func timeFormat(_ t: Double) -> String
    func timeFormatUTC(_ t: Double, _ fmt: String, _ sh: Int) -> String
    func t2s(_ s: String) -> String
    func s2t(_ s: String) -> String
    func put(_ k: String, _ v: String) -> String
    func getVar(_ k: String) -> String
    func getCookie(_ tag: String, _ key: String?) -> String
    func randomUUID() -> String
    func getString(_ rule: String) -> String
    func getStringUrl(_ rule: String, _ isUrl: Bool) -> String
    func getStringList(_ rule: String) -> [String]
    func getElement(_ rule: String) -> Any?
    func getElements(_ rule: String) -> [Any]
    func setContent(_ c: Any?) -> Any
    func getSource() -> Any
    func getWebViewUA() -> String
    func toNumChapter(_ s: String) -> String
    func HMacHex(_ algo: String, _ key: String, _ data: String) -> String
    func HMacBase64(_ algo: String, _ key: String, _ data: String) -> String
    func digestHex(_ algo: String, _ data: String) -> String
    func digestBase64Str(_ algo: String, _ data: String) -> String
    func createSymmetricCrypto(_ transformation: String, _ key: Any, _ iv: Any?) -> SymmetricCryptoBridge
    func webView(_ html: String?, _ url: String?, _ js: String?) -> String
    func startBrowserAwait(_ url: String, _ title: String) -> Any
    func downloadFile(_ url: String) -> String
    func importScript(_ path: String) -> String
    func cacheFile(_ url: String) -> String
    func getTxtInFolder(_ path: String) -> String
    func deleteFile(_ path: String)
}

@objc final class JavaBridge: NSObject, JavaBridgeExports {
    weak var engine: RuleEngine?
    init(engine: RuleEngine?) { self.engine = engine }

    private var source: BookSource? { engine?.source }
    private var scope: String { source?.bookSourceUrl ?? "global" }

    private func hdr(_ h: [String: String]) -> [String: String] {
        var m = source?.headerMap() ?? [:]
        for (k, v) in h { m[k] = v }
        return m
    }

    func ajax(_ url: String) -> String {
        do {
            let a = AnalyzeUrl(url, source: source, book: engine?.book, engine: engine)
            return try a.fetch().body
        } catch { engine?.log("ajax 失败 \(url): \(error.localizedDescription)"); return "" }
    }

    func ajaxAll(_ urls: [String]) -> [String] {
        var out = [String](repeating: "", count: urls.count)
        let g = DispatchGroup()
        for (i, u) in urls.enumerated() {
            g.enter()
            let src = source, bk = engine?.book
            DispatchQueue.global().async {
                let a = AnalyzeUrl(u, source: src, book: bk, engine: RuleEngine(source: src, book: bk))
                out[i] = (try? a.fetch().body) ?? ""
                g.leave()
            }
        }
        g.wait()
        return out
    }

    func httpGet(_ url: String, _ headers: [String: String]) -> Any {
        do {
            let r = try HTTP.request(url: url, headers: hdr(headers))
            return ResponseBridge(r)
        } catch { return ResponseBridge(HTTPResponse(url: url, body: "", data: Data(), code: 0, headers: [:])) }
    }

    func post(_ url: String, _ body: String, _ headers: [String: String]) -> Any {
        do {
            var h = hdr(headers)
            if h.first(where: { $0.key.lowercased() == "content-type" }) == nil {
                h["Content-Type"] = Util.isJSON(body) ? "application/json" : "application/x-www-form-urlencoded"
            }
            let r = try HTTP.request(url: url, method: "POST", headers: h, body: body.data(using: .utf8))
            return ResponseBridge(r)
        } catch { return ResponseBridge(HTTPResponse(url: url, body: "", data: Data(), code: 0, headers: [:])) }
    }

    func connect(_ url: String) -> Any {
        do {
            let a = AnalyzeUrl(url, source: source, book: engine?.book, engine: engine)
            return ResponseBridge(try a.fetch())
        } catch { return ResponseBridge(HTTPResponse(url: url, body: "", data: Data(), code: 0, headers: [:])) }
    }

    func log(_ msg: Any?) -> Any? { engine?.log("JS: \(JSEngine.stringify(msg))"); return msg }
    func logType(_ o: Any?) { engine?.log("type: \(type(of: o as Any))") }
    func toast(_ msg: Any?) { engine?.log("toast: \(JSEngine.stringify(msg))") }
    func longToast(_ msg: Any?) { toast(msg) }

    func md5Encode(_ s: String) -> String { Util.md5(s) }
    func md5Encode16(_ s: String) -> String { String(Util.md5(s).dropFirst(8).prefix(16)) }
    func base64Encode(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
    func base64Decode(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        guard let d = Data(base64Encoded: t, options: .ignoreUnknownCharacters) else { return "" }
        return String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
    }
    func base64DecodeToByteArray(_ s: String) -> [Int] {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.count % 4 != 0 { t += "=" }
        return (Data(base64Encoded: t, options: .ignoreUnknownCharacters) ?? Data()).map { Int(Int8(bitPattern: $0)) }
    }
    func hexEncodeToString(_ s: String) -> String { Data(s.utf8).map { String(format: "%02x", $0) }.joined() }
    func hexDecodeToString(_ s: String) -> String {
        var d = Data(); var i = s.startIndex
        while i < s.endIndex, let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex) {
            if let b = UInt8(s[i..<j], radix: 16) { d.append(b) }; i = j
        }
        return String(data: d, encoding: .utf8) ?? ""
    }
    func strToBytes(_ s: String) -> [Int] { Data(s.utf8).map { Int(Int8(bitPattern: $0)) } }
    func bytesToStr(_ b: [Int]) -> String { String(decoding: Data(b.map { UInt8(truncatingIfNeeded: $0) }), as: UTF8.self) }
    func encodeURI(_ s: String) -> String { Util.urlEncode(s, encoding: .utf8) }
    func encodeURIWith(_ s: String, _ enc: String) -> String { Util.urlEncode(s, encoding: Util.encoding(named: enc)) }
    func htmlFormat(_ s: String) -> String { Util.formatContent(s) }
    func timeFormat(_ t: Double) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: t / 1000))
    }
    func timeFormatUTC(_ t: Double, _ fmt: String, _ sh: Int) -> String {
        let f = DateFormatter(); f.dateFormat = fmt; f.timeZone = TimeZone(secondsFromGMT: sh * 3600)
        return f.string(from: Date(timeIntervalSince1970: t / 1000))
    }
    func t2s(_ s: String) -> String { s.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? s }
    func s2t(_ s: String) -> String { s.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? s }

    func put(_ k: String, _ v: String) -> String { engine?.put(k, v); return v }
    func getVar(_ k: String) -> String { engine?.get(k) ?? "" }

    func getCookie(_ tag: String, _ key: String?) -> String {
        guard let u = URL(string: tag) else { return "" }
        let cs = HTTPCookieStorage.shared.cookies(for: u) ?? []
        if let k = key, !k.isEmpty { return cs.first { $0.name == k }?.value ?? "" }
        return cs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
    func randomUUID() -> String { UUID().uuidString }

    func getString(_ rule: String) -> String { engine?.getString(rule) ?? "" }
    func getStringUrl(_ rule: String, _ isUrl: Bool) -> String { engine?.getString(rule, isUrl: isUrl) ?? "" }
    func getStringList(_ rule: String) -> [String] { engine?.getStringList(rule) ?? [] }
    func getElement(_ rule: String) -> Any? { engine?.getElement(rule).map { AnalyzeByJSoup.stringOf($0) } }
    func getElements(_ rule: String) -> [Any] { (engine?.getElements(rule) ?? []).map { AnalyzeByJSoup.stringOf($0) } }
    func setContent(_ c: Any?) -> Any { engine?.setContent(c ?? ""); return self }
    func getSource() -> Any { SourceBridge(source) }
    func getWebViewUA() -> String { BookSource.defaultUA }

    func toNumChapter(_ s: String) -> String {
        let rx = try! NSRegularExpression(pattern: "(第)(.+?)(章)")
        let ns = s as NSString
        guard let m = rx.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return s }
        let cn = ns.substring(with: m.range(at: 2))
        return ns.replacingCharacters(in: m.range, with: "第\(ChineseNumber.parse(cn))章")
    }

    func HMacHex(_ algo: String, _ key: String, _ data: String) -> String { Crypto.hmac(algo, key, data).map { String(format: "%02x", $0) }.joined() }
    func HMacBase64(_ algo: String, _ key: String, _ data: String) -> String { Crypto.hmac(algo, key, data).base64EncodedString() }
    func digestHex(_ algo: String, _ data: String) -> String { Crypto.digest(algo, Data(data.utf8)).map { String(format: "%02x", $0) }.joined() }
    func digestBase64Str(_ algo: String, _ data: String) -> String { Crypto.digest(algo, Data(data.utf8)).base64EncodedString() }
    func createSymmetricCrypto(_ transformation: String, _ key: Any, _ iv: Any?) -> SymmetricCryptoBridge {
        SymmetricCryptoBridge(transformation, Crypto.bytes(key), iv.flatMap { $0 is NSNull ? nil : Crypto.bytes($0) })
    }

    func webView(_ html: String?, _ url: String?, _ js: String?) -> String {
        do { return try WebViewLoader.load(url: url ?? "", html: html, headers: source?.headerMap() ?? [:], js: js).body }
        catch { return "" }
    }
    func startBrowserAwait(_ url: String, _ title: String) -> Any {
        return ResponseBridge(HTTPResponse(url: url, body: "", data: Data(), code: 0, headers: [:]))
    }
    func downloadFile(_ url: String) -> String { "" }
    func importScript(_ path: String) -> String {
        let u = Util.absoluteURL(source?.bookSourceUrl, path)
        return (try? HTTP.request(url: u).body) ?? ""
    }
    func cacheFile(_ url: String) -> String { importScript(url) }
    func getTxtInFolder(_ path: String) -> String { "" }
    func deleteFile(_ path: String) {}
}

@objc protocol ResponseBridgeExports: JSExport {
    func body() -> String
    func code() -> Int
    func url() -> String
    func headers() -> [String: String]
    func header(_ k: String) -> String
    func cookie() -> String
    func message() -> String
    func toString() -> String
}
@objc final class ResponseBridge: NSObject, ResponseBridgeExports {
    let r: HTTPResponse
    init(_ r: HTTPResponse) { self.r = r }
    func body() -> String { r.body }
    func code() -> Int { r.code }
    func url() -> String { r.url }
    func headers() -> [String: String] { r.headers }
    func header(_ k: String) -> String { r.headers.first { $0.key.lowercased() == k.lowercased() }?.value ?? "" }
    func cookie() -> String { header("Set-Cookie") }
    func message() -> String { HTTPURLResponse.localizedString(forStatusCode: r.code) }
    override var description: String { r.body }
    func toString() -> String { r.body }
}

@objc protocol SourceBridgeExports: JSExport {
    var bookSourceUrl: String { get }
    var bookSourceName: String { get }
    var loginUrl: String { get }
    func getKey() -> String
    func getVariable() -> String
    func setVariable(_ v: String?)
    func getLoginInfo() -> String
    func getLoginInfoMap() -> [String: String]
    func getLoginHeader() -> String
    func getLoginHeaderMap() -> [String: String]
    func putLoginHeader(_ h: String)
}
@objc final class SourceBridge: NSObject, SourceBridgeExports {
    let s: BookSource?
    init(_ s: BookSource?) { self.s = s }
    var bookSourceUrl: String { s?.bookSourceUrl ?? "" }
    var bookSourceName: String { s?.bookSourceName ?? "" }
    var loginUrl: String { s?.loginUrl ?? "" }
    func getKey() -> String { bookSourceUrl }
    func getVariable() -> String { VariableStore.shared.get("src:" + bookSourceUrl, "__variable") ?? "" }
    func setVariable(_ v: String?) { VariableStore.shared.put("src:" + bookSourceUrl, "__variable", v ?? "") }
    func getLoginInfo() -> String { VariableStore.shared.get("src:" + bookSourceUrl, "__loginInfo") ?? "" }
    func getLoginInfoMap() -> [String: String] { AnalyzeUrl.parseLooseJSON(getLoginInfo())?.mapValues { "\($0)" } ?? [:] }
    func getLoginHeader() -> String { VariableStore.shared.get("src:" + bookSourceUrl, "__loginHeader") ?? "" }
    func getLoginHeaderMap() -> [String: String] { AnalyzeUrl.parseLooseJSON(getLoginHeader())?.mapValues { "\($0)" } ?? [:] }
    func putLoginHeader(_ h: String) { VariableStore.shared.put("src:" + bookSourceUrl, "__loginHeader", h) }
}

@objc protocol CookieBridgeExports: JSExport {
    func getCookie(_ url: String) -> String
    func getKey(_ url: String, _ key: String) -> String
    func setCookie(_ url: String, _ cookie: String)
    func removeCookie(_ url: String)
}
@objc final class CookieBridge: NSObject, CookieBridgeExports {
    func getCookie(_ url: String) -> String {
        guard let u = URL(string: url) else { return "" }
        return (HTTPCookieStorage.shared.cookies(for: u) ?? []).map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
    func getKey(_ url: String, _ key: String) -> String {
        guard let u = URL(string: url) else { return "" }
        return HTTPCookieStorage.shared.cookies(for: u)?.first { $0.name == key }?.value ?? ""
    }
    func setCookie(_ url: String, _ cookie: String) {
        guard let u = URL(string: url), let host = u.host else { return }
        for pair in cookie.components(separatedBy: ";") {
            let kv = pair.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            if let c = HTTPCookie(properties: [.name: String(kv[0]), .value: String(kv[1]), .domain: host, .path: "/"]) {
                HTTPCookieStorage.shared.setCookie(c)
            }
        }
    }
    func removeCookie(_ url: String) {
        guard let u = URL(string: url) else { return }
        HTTPCookieStorage.shared.cookies(for: u)?.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
    }
}

@objc protocol CacheBridgeExports: JSExport {
    func get(_ k: String) -> String?
    func put(_ k: String, _ v: Any?)
    func delete(_ k: String)
}
@objc final class CacheBridge: NSObject, CacheBridgeExports {
    func get(_ k: String) -> String? { VariableStore.shared.cacheGet(k) }
    func put(_ k: String, _ v: Any?) { VariableStore.shared.cachePut(k, JSEngine.stringify(v)) }
    func delete(_ k: String) { VariableStore.shared.cachePut(k, "") }
}

/// 中文数字转阿拉伯数字（第一百二十章 → 第120章）
enum ChineseNumber {
    static func parse(_ s: String) -> String {
        if let n = Int(s) { return String(n) }
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
                                        "壹": 1, "贰": 2, "叁": 3, "肆": 4, "伍": 5, "陆": 6, "柒": 7, "捌": 8, "玖": 9]
        let units: [Character: Int] = ["十": 10, "拾": 10, "百": 100, "佰": 100, "千": 1000, "仟": 1000, "万": 10000, "亿": 100000000]
        var total = 0, section = 0, num = 0
        for c in s {
            if let d = digits[c] { num = d }
            else if let u = units[c] {
                if u >= 10000 { section = (section + num) * u; total += section; section = 0 }
                else { section += (num == 0 && u == 10 ? 1 : num) * u }
                num = 0
            } else { return s }
        }
        return String(total + section + num)
    }
}
