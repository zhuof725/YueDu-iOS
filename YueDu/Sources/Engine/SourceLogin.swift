import Foundation

/// 登录表单的一项（对应 Legado RowUi）
struct LoginRow: Identifiable {
    var index: Int = 0
    var id: String { "\(index)#" + name + "#" + type }
    var name: String
    var type: String          // text / password / button / toggle / select
    var action: String?
    var chars: [String]
    var defaultValue: String?
    var viewName: String?
    var style = LoginRowStyle()

    var label: String { viewName?.isEmpty == false ? viewName! : name }
    var isInput: Bool { type == "text" || type == "password" }

    /// viewName 写成 'xxx'（单引号包住，3~19 字）时是纯文字；其他情况是 JS（Legado 规则）
    var literalViewName: String? {
        guard let v = viewName else { return nil }
        if v.count >= 3 && v.count <= 19 && v.hasPrefix("'") && v.hasSuffix("'") { return String(v.dropFirst().dropLast()) }
        return nil
    }
    var viewNameNeedsJS: Bool { viewName != nil && literalViewName == nil && !(viewName ?? "").isEmpty }
}

/// 对应 Legado FlexChildStyle（Flexbox 布局参数）
struct LoginRowStyle {
    var flexGrow: Double = 0
    var flexShrink: Double = 1
    var alignSelf = "auto"
    var flexBasisPercent: Double = -1
    var wrapBefore = false
    var justifySelf = "auto"

    init() {}
    init(_ o: [String: Any]?) {
        guard let o = o else { return }
        func num(_ k: String) -> Double? { o[k].flatMap { Double(JSONPath.stringify($0)) } }
        flexGrow = num("layout_flexGrow") ?? 0
        flexShrink = num("layout_flexShrink") ?? 1
        flexBasisPercent = num("layout_flexBasisPercent") ?? -1
        alignSelf = (o["layout_alignSelf"] as? String) ?? "auto"
        justifySelf = (o["layout_justifySelf"] as? String) ?? "auto"
        if let w = o["layout_wrapBefore"] { wrapBefore = (w as? Bool) ?? (JSONPath.stringify(w) == "true") }
    }
}

/// 登录界面接收书源脚本回调（java.upLoginData / java.reLoginView / java.toast 等）
protocol LoginUICallback: AnyObject {
    func upLoginData(_ data: [String: Any]?)
    func reLoginView(_ deltaUp: Bool)
    func toast(_ msg: String)
    func openBrowser(_ url: String, title: String)
}

/// 全局提示（没有登录界面时，java.toast 走这里）
enum AppToast {
    static var handler: ((String) -> Void)?
}

/// 执行书源登录相关的 JS
enum SourceLogin {

    /// 取出 loginUrl 里的 JS 代码。
    /// 与 Legado 一致：@js: / <js></js> 是 JS；没有前缀时，只要不是网址也当作 JS
    /// （大多数书源直接写 `function login(){...}`，没有 @js: 前缀）
    static func loginJs(_ s: BookSource) -> String? {
        guard let l = s.loginUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !l.isEmpty else { return nil }
        if l.hasPrefix("@js:") { return String(l.dropFirst(4)) }
        if l.lowercased().hasPrefix("<js>") {
            var body = String(l.dropFirst(4))
            if let r = body.range(of: "</js>", options: [.caseInsensitive, .backwards]) { body = String(body[..<r.lowerBound]) }
            return body
        }
        return looksLikeURL(l) ? nil : l
    }

    /// 判断 loginUrl 是不是网址（而不是 JS 代码）
    static func looksLikeURL(_ l: String) -> Bool {
        let t = l.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            // 网址后面可以跟 ,{...} 参数，但不能是多行代码
            let head = t.components(separatedBy: ",{").first ?? t
            return !head.contains("\n") && !head.contains(" ")
        }
        if t.hasPrefix("/") && !t.hasPrefix("//") && !t.contains("\n") && !t.contains("function") { return true }
        return false
    }

    /// 书源是否带登录脚本（有 login 函数）
    static func hasLoginFunction(_ s: BookSource) -> Bool {
        guard let js = loginJs(s) else { return false }
        return js.range(of: #"function\s+login\s*\("#, options: .regularExpression) != nil
            || js.range(of: #"login\s*=\s*function"#, options: .regularExpression) != nil
    }

    /// 网页登录的地址（loginUrl 是普通网址时）；去掉 ",{...}" 请求参数
    static func loginPageUrl(_ s: BookSource) -> String? {
        guard let l = s.loginUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !l.isEmpty, loginJs(s) == nil else { return nil }
        var u = Util.absoluteURL(s.bookSourceUrl, l)
        if let r = u.range(of: #"\s*,\s*\{"#, options: .regularExpression) { u = String(u[..<r.lowerBound]) }
        return u
    }

    /// 网页登录要打开的地址：loginUrl 网址，否则书源首页
    static func webLoginUrl(_ s: BookSource) -> String {
        if let u = loginPageUrl(s) { return u }
        var u = s.bookSourceUrl
        if let r = u.range(of: "#") { u = String(u[..<r.lowerBound]) }
        return u
    }

    /// loginUi 是 @js: / <js> 时返回其中代码
    static func loginUiJs(_ s: BookSource) -> String? {
        guard let ui = s.loginUi?.trimmingCharacters(in: .whitespacesAndNewlines), !ui.isEmpty else { return nil }
        if ui.hasPrefix("@js:") { return String(ui.dropFirst(4)) }
        if ui.lowercased().hasPrefix("<js>") {
            var b = String(ui.dropFirst(4))
            if let r = b.range(of: "</js>", options: [.caseInsensitive, .backwards]) { b = String(b[..<r.lowerBound]) }
            return b
        }
        return nil
    }

    /// 解析登录表单（loginUi 可以是 JSON 数组，也可以是 @js: 生成的）
    static func rows(_ s: BookSource, current: [String: String] = [:], callback: LoginUICallback? = nil, logger: DebugLog? = nil) -> [LoginRow] {
        guard s.hasLoginUi, var ui = s.loginUi?.trimmingCharacters(in: .whitespacesAndNewlines) else { return [] }
        if let c = loginUiJs(s) {
            do { ui = try evalUi(s, c, info: current, callback: callback, logger: logger) }
            catch { logger?.log("loginUi 脚本出错：\(error.localizedDescription)"); ui = "" }
        }
        guard let parsed = BookSourceImporter.parseJSONLoose(ui) else {
            logger?.log("loginUi JSON 解析失败：\(ui.prefix(200))")
            return []
        }
        let arr: [Any] = (parsed as? [Any]) ?? [parsed]
        return parseRows(arr)
    }

    /// 对应 Legado BaseSource.getLoginInfoMap()：
    /// 有保存的登录信息就用；没有时按 loginUi 里各控件（除按钮外）的 default 生成一份并保存
    static func loginInfoMap(_ s: BookSource) -> [String: String] {
        let key = s.bookSourceUrl
        if LoginStore.loginInfo(key) != nil { return LoginStore.loginInfoMap(key) }
        guard !(s.loginUi ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        // 防止 loginUi 脚本里又调用 source.getLoginInfoMap() 造成死循环
        let flag = "yuedu.loginInfoMap." + key
        if Thread.current.threadDictionary[flag] != nil { return [:] }
        Thread.current.threadDictionary[flag] = true
        defer { Thread.current.threadDictionary.removeObject(forKey: flag) }
        var m: [String: String] = [:]
        for r in rows(s) where r.type != "button" { m[r.name] = r.defaultValue ?? "" }
        if !m.isEmpty { saveInfo(s, m) }
        return m
    }

    /// Legado isAbsUrl：只有 http(s):// 开头的 action 当网址打开，其余都当 JS
    static func isAbsUrl(_ s: String) -> Bool {
        let l = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (l.hasPrefix("http://") || l.hasPrefix("https://")) && !l.contains("\n")
    }

    static func parseRows(_ arr: [Any]) -> [LoginRow] {
        var out: [LoginRow] = []
        for item in arr {
            guard let o = item as? [String: Any] else { continue }
            let name = o["name"].map { JSONPath.stringify($0) } ?? ""
            var chars: [String] = []
            if let c = o["chars"] as? [Any] { chars = c.compactMap { $0 is NSNull ? nil : JSONPath.stringify($0) } }
            var row = LoginRow(name: name,
                            type: ((o["type"] as? String) ?? "text").lowercased(),
                            action: o["action"].flatMap { $0 is NSNull ? nil : JSONPath.stringify($0) },
                            chars: chars,
                            defaultValue: o["default"].flatMap { $0 is NSNull ? nil : JSONPath.stringify($0) },
                            viewName: o["viewName"].flatMap { $0 is NSNull ? nil : JSONPath.stringify($0) },
                            style: LoginRowStyle(o["style"] as? [String: Any]))
            row.index = out.count
            out.append(row)
        }
        return out
    }

    /// 在书源环境里执行一段 JS（可用 java.* / source.* / cookie.* / result）
    @discardableResult
    static func run(_ s: BookSource, _ js: String, result: [String: String], logger: DebugLog? = nil) -> Any? {
        try? exec(s, js, info: result, logger: logger)
    }

    /// 执行「登录脚本 + 代码」，出错抛出
    static func exec(_ s: BookSource, _ code: String, info: [String: String], isLongClick: Bool = false,
                     callback: LoginUICallback? = nil, logger: DebugLog? = nil, book: Book? = nil) throws -> Any? {
        let js = "if (typeof result === 'object') __jmap(result);\n" + (loginJs(s) ?? "") + "\n" + code
        let engine = RuleEngine(source: s, book: book, logger: logger)
        engine.loginCallback = callback
        engine.setContent("", baseUrl: s.bookSourceUrl)
        var err: String?
        engine.onJSError = { err = $0 }
        let v = engine.evalJS(js, result: info, extra: ["result": info, "isLongClick": isLongClick])
        if let e = err { throw YueDuError.message(e) }
        return v
    }

    /// 执行 loginUi / viewName 里的 JS，返回字符串
    static func evalUi(_ s: BookSource, _ code: String, info: [String: String], callback: LoginUICallback? = nil, logger: DebugLog? = nil) throws -> String {
        let v = try exec(s, code, info: info, callback: callback, logger: logger)
        // 脚本直接返回数组/对象时转成 JSON（stringify 对数组是按行拼接）
        if let v = v, !(v is String), JSONSerialization.isValidJSONObject(v),
           let d = try? JSONSerialization.data(withJSONObject: v), let str = String(data: d, encoding: .utf8) { return str }
        return JSEngine.stringify(v)
    }

    /// 保存表单填写内容（loginInfo，存钥匙串）
    @discardableResult
    static func saveInfo(_ s: BookSource, _ info: [String: String]) -> Bool {
        if info.isEmpty { LoginStore.removeLoginInfo(s.bookSourceUrl); return true }
        guard let d = try? JSONSerialization.data(withJSONObject: info), let str = String(data: d, encoding: .utf8) else { return false }
        return LoginStore.putLoginInfo(s.bookSourceUrl, str)
    }

    /// 保存表单并调用书源的 login() 函数（对应 Legado BaseSource.login）
    /// 与 Legado SourceLoginDialog.login 一致：表单为空时删除登录信息直接返回；否则保存后执行 login()
    static func login(_ s: BookSource, info: [String: String], callback: LoginUICallback? = nil,
                      logger: DebugLog? = nil, book: Book? = nil) throws {
        if info.isEmpty && !(s.loginUi ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            LoginStore.removeLoginInfo(s.bookSourceUrl)
            return
        }
        if !info.isEmpty { saveInfo(s, info) }
        guard loginJs(s) != nil else { return }
        _ = try exec(s, "if (typeof login == 'function') { login.apply(this); } else { throw('Function login not implements!!!'); }",
                     info: info, callback: callback, logger: logger, book: book)
    }

    /// 表单里按钮的动作（Legado handleButtonClick）：http 网址用网页打开，否则「登录脚本 + action」当 JS 执行
    static func buttonAction(_ s: BookSource, action: String, info: [String: String], isLongClick: Bool = false,
                             callback: LoginUICallback? = nil, logger: DebugLog? = nil, book: Book? = nil) throws -> Any? {
        try exec(s, action, info: info, isLongClick: isLongClick, callback: callback, logger: logger, book: book)
    }

    /// 请求完成后执行 loginCheckJs（书源用它检测登录是否失效、必要时自动重新登录）
    static func check(_ s: BookSource, response: HTTPResponse, engine: RuleEngine) -> HTTPResponse {
        guard let js = s.loginCheckJs?.trimmingCharacters(in: .whitespacesAndNewlines), !js.isEmpty else { return response }
        let bridge = ResponseBridge(response)
        let v = engine.evalJS(js, result: bridge, extra: ["result": bridge])
        if let r = v as? ResponseBridge { return r.r }
        return response
    }
}
