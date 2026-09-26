import Foundation

/// 登录表单的一项（对应 Legado RowUi）
struct LoginRow: Identifiable {
    var id: String { name + "#" + type }
    var name: String
    var type: String          // text / password / button / toggle / select
    var action: String?
    var chars: [String]
    var defaultValue: String?
    var viewName: String?

    var label: String { viewName?.isEmpty == false ? viewName! : name }
    var isInput: Bool { type == "text" || type == "password" }
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

    /// 解析登录表单（loginUi 可以是 JSON 数组，也可以是 @js: 生成的）
    static func rows(_ s: BookSource, current: [String: String] = [:]) -> [LoginRow] {
        guard var ui = s.loginUi?.trimmingCharacters(in: .whitespacesAndNewlines), !ui.isEmpty else { return [] }
        var code: String?
        if ui.hasPrefix("@js:") { code = String(ui.dropFirst(4)) }
        else if ui.lowercased().hasPrefix("<js>") {
            var b = String(ui.dropFirst(4))
            if let r = b.range(of: "</js>", options: [.caseInsensitive, .backwards]) { b = String(b[..<r.lowerBound]) }
            code = b
        }
        if let c = code {
            let js = (loginJs(s) ?? "") + "\n" + c
            ui = JSEngine.stringify(run(s, js, result: current))
        }
        guard let parsed = BookSourceImporter.parseJSONLoose(ui) else { return [] }
        let arr: [Any] = (parsed as? [Any]) ?? [parsed]
        return arr.compactMap { item -> LoginRow? in
            guard let o = item as? [String: Any] else { return nil }
            let name = (o["name"] as? String) ?? ""
            if name.isEmpty { return nil }
            var chars: [String] = []
            if let c = o["chars"] as? [Any] { chars = c.compactMap { $0 is NSNull ? nil : JSONPath.stringify($0) } }
            return LoginRow(name: name,
                            type: ((o["type"] as? String) ?? "text").lowercased(),
                            action: (o["action"] as? String),
                            chars: chars,
                            defaultValue: o["default"].flatMap { $0 is NSNull ? nil : JSONPath.stringify($0) },
                            viewName: o["viewName"] as? String)
        }
    }

    /// 在书源环境里执行一段 JS（可用 java.* / source.* / cookie.* / result）
    @discardableResult
    static func run(_ s: BookSource, _ js: String, result: [String: String], logger: DebugLog? = nil) -> Any? {
        let engine = RuleEngine(source: s, logger: logger)
        engine.setContent("", baseUrl: s.bookSourceUrl)
        let v = engine.evalJS(js, result: result, extra: ["result": result])
        return v
    }

    /// 保存表单并调用书源的 login() 函数
    static func login(_ s: BookSource, info: [String: String], logger: DebugLog? = nil) throws {
        if let d = try? JSONSerialization.data(withJSONObject: info), let str = String(data: d, encoding: .utf8) {
            _ = LoginStore.putLoginInfo(s.bookSourceUrl, str)
        }
        guard let lj = loginJs(s) else { return }
        let js = """
        if (typeof result === 'object') __jmap(result);
        \(lj)
        if (typeof login == 'function') { login.apply(this); } else { throw('书源没有实现 login 函数'); }
        """
        let engine = RuleEngine(source: s, logger: logger)
        engine.setContent("", baseUrl: s.bookSourceUrl)
        engine.onJSError = { msg in engine.lastError = msg }
        _ = engine.evalJS(js, result: info, extra: ["result": info])
        if let e = engine.lastError { throw YueDuError.message(e) }
    }

    /// 表单里按钮的动作：网址则打开，否则执行 JS
    static func buttonAction(_ s: BookSource, action: String, info: [String: String], logger: DebugLog? = nil) throws -> Any? {
        let js = "if (typeof result === 'object') __jmap(result);\n" + (loginJs(s) ?? "") + "\n" + action
        let engine = RuleEngine(source: s, logger: logger)
        engine.setContent("", baseUrl: s.bookSourceUrl)
        engine.onJSError = { msg in engine.lastError = msg }
        let v = engine.evalJS(js, result: info, extra: ["result": info])
        if let e = engine.lastError { throw YueDuError.message(e) }
        return v
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
