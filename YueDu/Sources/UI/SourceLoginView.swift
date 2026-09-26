import SwiftUI
import UIKit

/// 登录界面状态 —— 逐项对照 Legado SourceLoginDialog / SourceLoginViewModel
/// 同时接收书源脚本回调：java.upLoginData / java.reLoginView / java.toast / java.startBrowser
@MainActor
final class LoginModel: ObservableObject, LoginUICallback {
    let source: BookSource
    let book: Book?
    @Published var rows: [LoginRow] = []
    /// 对应 Legado viewModel.loginInfo（表单里各控件的当前值）
    @Published var values: [String: String] = [:]
    /// viewName 是 JS 时算出来的显示名 / 脚本用 upLoginData 改过的按钮文字
    @Published var names: [String: String] = [:]
    @Published var toastText: String?
    @Published var working = false
    @Published var loading = false
    @Published var browser: BrowserTarget?
    @Published var headerText: String?
    @Published var uiError: String?
    let log = DebugLog()
    /// Legado hasChange：关闭时是否需要保存表单
    var hasChange = false
    /// Legado oKToClose：点了 ✓ 关闭的不再重复保存
    var okToClose = false
    private var debounce: [String: DispatchWorkItem] = [:]
    private var lastClick = Date.distantPast

    struct BrowserTarget: Identifiable { let id = UUID(); let url: String; let title: String }

    init(source: BookSource, book: Book? = nil) {
        self.source = source
        self.book = book
        headerText = LoginStore.loginHeader(source.bookSourceUrl)
    }

    var hasUi: Bool { source.hasLoginUi }

    // MARK: 构建界面（Legado onFragmentCreated / rowUiBuilder）

    /// 第一次打开：先取 source.getLoginInfoMap()（没有时按 default 生成），再生成界面
    func start() {
        let src = source
        let raw = (src.loginUi ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        log.log("loginUrl：\(SourceLogin.loginJs(src) != nil ? "登录脚本" : (src.loginUrl?.isEmpty == false ? "网址" : "无"))")
        log.log("loginUi（\(raw.count) 字）：\(raw.isEmpty ? "无" : String(raw.prefix(300)))")
        loading = true
        Task {
            let info: [String: String] = await Task.detached { SourceLogin.loginInfoMap(src) }.value
            values = info
            buildUI()
        }
    }

    func buildUI() {
        let src = source, info = values, lg = log
        uiError = nil
        loading = true
        Task {
            let rs: [LoginRow] = await Task.detached { [weak self] in
                SourceLogin.rows(src, current: info, callback: self, logger: lg)
            }.value
            loading = false
            if rs.isEmpty && hasUi { uiError = "登录界面（loginUi）生成失败，可在右上角「⋯ → 日志」查看原因" }
            log.log("生成控件 \(rs.count) 个：\(rs.map { "\($0.name)(\($0.type))" }.joined(separator: "、"))")
            apply(rs)
        }
    }

    private func apply(_ rs: [LoginRow]) {
        rows = rs
        for r in rs {
            let cur = values[r.name] ?? ""
            switch r.type {
            case "select", "toggle":
                // Legado：没值时取 default，否则第一个选项，并标记有改动
                if cur.isEmpty, let v = r.defaultValue ?? r.chars.first { values[r.name] = v; hasChange = true }
            case "text", "password":
                if values[r.name] == nil { values[r.name] = r.defaultValue ?? "" }
            default: break
            }
        }
        // viewName 是 JS 的，后台算出显示名
        for r in rs where r.viewNameNeedsJS {
            let src = source, info = values, code = r.viewName ?? "", key = r.name
            Task {
                let n: String = await Task.detached { [weak self] in
                    do { return try SourceLogin.evalUi(src, code, info: info, callback: self) } catch { return "err" }
                }.value
                names[key] = n.isEmpty ? "null" : n
            }
        }
    }

    func label(_ r: LoginRow) -> String {
        if let n = names[r.name] { return n }
        if let l = r.literalViewName { return l }
        return r.name
    }

    func toggleText(_ r: LoginRow) -> String {
        let v = values[r.name] ?? r.defaultValue ?? r.chars.first ?? ""
        return r.style.justifySelf == "right" ? label(r) + v : v + label(r)
    }

    // MARK: 动作（Legado handleButtonClick）

    func runAction(_ r: LoginRow, longClick: Bool = false) {
        guard let action = r.action?.trimmingCharacters(in: .whitespacesAndNewlines), !action.isEmpty else { return }
        if SourceLogin.isAbsUrl(action) {
            // Legado：context.openUrl(action)
            browser = BrowserTarget(url: action, title: label(r))
            return
        }
        let src = source, info = values, bk = book, lg = log, name = r.name
        Task {
            do {
                try await Task.detached { [weak self] in
                    _ = try SourceLogin.buttonAction(src, action: action, info: info, isLongClick: longClick,
                                                     callback: self, logger: lg, book: bk)
                }.value
            } catch {
                lg.log("LoginUI Button \(name) JavaScript error: \(error.localizedDescription)")
                toast("\(label(r)) 出错：\(error.localizedDescription)")
            }
            headerText = LoginStore.loginHeader(source.bookSourceUrl)
        }
    }

    /// 按钮点击（Legado：200ms 内重复点击忽略）
    func tap(_ r: LoginRow, longClick: Bool = false) {
        let now = Date()
        if now.timeIntervalSince(lastClick) < 0.2 { return }
        lastClick = now
        runAction(r, longClick: longClick)
    }

    /// 输入框带 action：停止输入 0.6 秒后执行
    func textChanged(_ r: LoginRow) {
        hasChange = true
        guard r.action?.isEmpty == false else { return }
        debounce[r.name]?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.runAction(r) }
        debounce[r.name] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    func cycleToggle(_ r: LoginRow, longClick: Bool = false) {
        let now = Date()
        if now.timeIntervalSince(lastClick) < 0.2 { return }
        lastClick = now
        let chars = r.chars.isEmpty ? ["chars is null"] : r.chars
        let cur = values[r.name] ?? chars[0]
        let i = chars.firstIndex(of: cur) ?? -1
        values[r.name] = chars[(i + 1) % chars.count]
        hasChange = true
        runAction(r, longClick: longClick)
    }

    func select(_ r: LoginRow, _ v: String) {
        guard values[r.name] != v else { return }
        values[r.name] = v
        hasChange = true
        runAction(r)
    }

    /// 右上角 ✓（Legado login）：表单为空 → 删除登录信息并关闭；否则保存 → 执行 login() → 提示成功并关闭
    func login(done: @escaping () -> Void) {
        okToClose = true
        let src = source, info = values, bk = book, lg = log
        working = true
        Task {
            do {
                try await Task.detached { [weak self] in
                    try SourceLogin.login(src, info: info, callback: self, logger: lg, book: bk)
                }.value
                working = false
                headerText = LoginStore.loginHeader(source.bookSourceUrl)
                if !info.isEmpty || SourceLogin.loginJs(src) != nil { toast("成功") }
                try? await Task.sleep(nanoseconds: 600_000_000)
                done()
            } catch {
                working = false
                okToClose = false
                lg.log("登录出错\n\(error.localizedDescription)")
                toast("登录出错\n\(error.localizedDescription)")
            }
        }
    }

    /// 关闭（Legado onDismiss）：没点 ✓ 且有改动时保存填写内容
    func saveOnClose() {
        debounce.values.forEach { $0.cancel() }
        guard !okToClose, hasChange else { return }
        _ = SourceLogin.saveInfo(source, values)
    }

    /// 排查用：App 版本、书源登录相关字段原文、日志
    func diagnosticReport() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        var out = "【登录诊断】App \(v) (\(b))\n书源：\(source.bookSourceName)\n地址：\(source.bookSourceUrl)\n"
        out += "\n── loginUrl（\((source.loginUrl ?? "").count) 字）──\n\(source.loginUrl ?? "(空)")\n"
        out += "\n── loginUi（\((source.loginUi ?? "").count) 字）──\n\(source.loginUi ?? "(空)")\n"
        out += "\n── jsLib（\((source.jsLib ?? "").count) 字）──\n\((source.jsLib ?? "").prefix(500))\n"
        out += "\n── 生成的控件 ──\n" + (rows.isEmpty ? "(无)" : rows.map { "\($0.name)(\($0.type))" }.joined(separator: "、")) + "\n"
        out += "\n── 日志 ──\n" + log.lines.joined(separator: "\n")
        return out
    }

    // MARK: LoginUICallback（脚本在后台线程调用）

    nonisolated func upLoginData(_ data: [String: Any]?) {
        let d = data?.mapValues { $0 is NSNull ? nil : JSEngine.stringify($0) }
        Task { @MainActor in
            hasChange = true
            guard let d = d else {
                // null：全部恢复默认值（Legado handleUpUiData(null)）
                var nv: [String: String] = [:]
                for r in rows {
                    switch r.type {
                    case "select", "toggle": nv[r.name] = r.defaultValue ?? r.chars.first ?? ""
                    case "text", "password": nv[r.name] = r.defaultValue ?? ""
                    case "button": names[r.name] = nil
                    default: break
                    }
                }
                values = nv
                return
            }
            for (k, v) in d {
                if let r = rows.first(where: { $0.name == k }) {
                    let val = v ?? r.defaultValue
                    switch r.type {
                    case "button": names[k] = val ?? (r.literalViewName ?? k)   // 按钮：改显示文字
                    case "toggle", "select": values[k] = val ?? r.chars.first ?? ""
                    default: values[k] = val ?? ""
                    }
                } else {
                    values[k] = v ?? ""
                }
            }
        }
    }

    nonisolated func reLoginView(_ deltaUp: Bool) {
        Task { @MainActor in hasChange = true; buildUI() }
    }

    nonisolated func toast(_ msg: String) {
        Task { @MainActor in
            toastText = msg
            let m = msg
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if toastText == m { toastText = nil }
        }
    }

    nonisolated func openBrowser(_ url: String, title: String) {
        Task { @MainActor in browser = BrowserTarget(url: url, title: title) }
    }
}

/// 登录入口 —— 对应 Legado SourceLoginActivity：
/// 书源有 loginUi → 书源自定义的登录界面；没有 loginUi → 网页登录（打开 loginUrl）
struct SourceLoginView: View {
    @Environment(\.dismiss) private var dismiss
    let source: BookSource
    @StateObject private var model: LoginModel
    @State private var showHeader = false
    @State private var showWeb = false
    @State private var showLog = false

    init(source: BookSource, book: Book? = nil) {
        self.source = source
        _model = StateObject(wrappedValue: LoginModel(source: source, book: book))
    }

    /// loginUi 为空但 loginUrl 是脚本时（Legado 这里会拿脚本当网址打开，必然失败），改为表单页只执行 login()
    private var useForm: Bool { model.hasUi || SourceLogin.loginJs(source) != nil }

    var body: some View {
        Group {
            if useForm { formPage } else { webPage }
        }
        .overlay(alignment: .bottom) {
            if let t = model.toastText {
                Text(t).font(.subheadline).foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.black.opacity(0.8)).cornerRadius(10)
                    .padding(.bottom, 40).padding(.horizontal)
                    .transition(.opacity)
                    .onTapGesture { UIPasteboard.general.string = t; model.toastText = nil }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.toastText)
    }

    // MARK: 网页登录（Legado WebViewLoginFragment）

    private var webPage: some View {
        WebLoginContainer(source: source) { _ in dismiss() }
            .ignoresSafeArea()
    }

    // MARK: 书源登录界面（Legado SourceLoginDialog）

    private var formPage: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.loading { ProgressView().frame(maxWidth: .infinity) }
                    if let e = model.uiError { Text(e).font(.footnote).foregroundColor(.orange) }
                    FlexLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(model.rows) { r in rowView(r) }
                    }
                    if !model.hasUi || (model.rows.isEmpty && !model.loading) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.hasUi
                                 ? "书源写了登录界面，但没能生成出来。"
                                 : "这个书源在 App 里保存的数据中没有登录界面（loginUi），点右上角 ✓ 会执行书源的 login() 登录脚本。\n如果书源文件里明明有登录界面，说明它是用旧版本导入的：请删除这个书源后重新导入。")
                                .font(.footnote).foregroundColor(.secondary)
                            Button {
                                UIPasteboard.general.string = model.diagnosticReport()
                                model.toast("已复制诊断信息，请发给开发者")
                            } label: { Label("复制诊断信息", systemImage: "doc.on.clipboard") }
                                .font(.footnote)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("登录 \(source.bookSourceName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { model.saveOnClose(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 14) {
                        Menu {
                            Button { model.headerText = LoginStore.loginHeader(source.bookSourceUrl); showHeader = true }
                                label: { Label("显示登录头", systemImage: "doc.text") }
                            Button(role: .destructive) {
                                LoginStore.logout(source.bookSourceUrl)
                                model.headerText = nil
                                model.toast("已删除登录头")
                            } label: { Label("删除登录头", systemImage: "trash") }
                            Button { showLog = true } label: { Label("日志", systemImage: "list.bullet.rectangle") }
                            Button { showWeb = true } label: { Label("网页登录", systemImage: "globe") }
                        } label: { Image(systemName: "ellipsis.circle") }
                        if model.working { ProgressView() }
                        else {
                            Button { model.login { dismiss() } } label: { Image(systemName: "checkmark") }
                                .font(.body.weight(.semibold))
                        }
                    }
                }
            }
            .alert("登录头", isPresented: $showHeader) {
                if model.headerText?.isEmpty == false {
                    Button("复制") { UIPasteboard.general.string = model.headerText ?? "" }
                }
                Button("关闭", role: .cancel) {}
            } message: { Text(model.headerText ?? "") }
            .sheet(item: $model.browser) { b in
                BrowserSheet(url: b.url, title: b.title, headers: source.headerMap()) { model.browser = nil }
            }
            .sheet(isPresented: $showWeb) {
                WebLoginContainer(source: source) { _ in showWeb = false }.ignoresSafeArea()
            }
            .sheet(isPresented: $showLog) { LoginLogView(log: model.log) }
        }
        .navigationViewStyle(.stack)
        .interactiveDismissDisabled(model.working)
        .onAppear { if model.rows.isEmpty && !model.loading { model.start() } }
        .onDisappear { model.saveOnClose() }
    }

    @ViewBuilder
    private func rowView(_ r: LoginRow) -> some View {
        switch r.type {
        case "password", "text":
            let b = Binding(get: { model.values[r.name] ?? "" },
                            set: { model.values[r.name] = $0; model.textChanged(r) })
            Group {
                if r.type == "password" { SecureField(model.label(r), text: b) }
                else { TextField(model.label(r), text: b) }
            }
            .multilineTextAlignment(r.style.justifySelf == "center" ? .center : r.style.justifySelf == "flex_end" ? .trailing : .leading)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 22).fill(Color(.systemBackground).opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(.separator), lineWidth: 0.6))
            .flexStyle(r.style, fullWidth: true)
        case "select":
            HStack(spacing: 6) {
                Text(model.label(r)).foregroundColor(.accentColor)
                Picker(model.label(r), selection: Binding(
                    get: { model.values[r.name] ?? r.defaultValue ?? r.chars.first ?? "" },
                    set: { model.select(r, $0) })) {
                    ForEach(r.chars.isEmpty ? ["chars", "is null"] : r.chars, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            }
            .padding(4)
            .flexStyle(r.style)
        case "toggle":
            FilletButton(text: model.toggleText(r), justify: r.style.justifySelf,
                         tap: { model.cycleToggle(r) }, longPress: { model.cycleToggle(r, longClick: true) })
                .flexStyle(r.style)
        default: // button
            FilletButton(text: model.label(r), justify: r.style.justifySelf,
                         tap: { model.tap(r) }, longPress: { model.tap(r, longClick: true) })
                .flexStyle(r.style)
        }
    }
}

/// 登录日志（Legado 菜单里的「日志」）
struct LoginLogView: View {
    @ObservedObject var log: DebugLog
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if log.lines.isEmpty { Text("暂无日志").foregroundColor(.secondary) }
                    ForEach(Array(log.lines.enumerated()), id: \.offset) { _, l in
                        Text(l).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("日志").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("复制") { UIPasteboard.general.string = log.lines.joined(separator: "\n") }
                }
            }
        }
    }
}

/// 圆角按钮（对应 Legado item_fillet_text）；支持长按（脚本里 isLongClick 为 true）
struct FilletButton: View {
    let text: String
    var justify = "auto"
    let tap: () -> Void
    let longPress: () -> Void
    @State private var pressed = false

    var body: some View {
        Text(text)
            .font(.system(size: 16))
            .foregroundColor(.accentColor)
            .lineLimit(1)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: justify == "flex_start" ? .leading : justify == "flex_end" ? .trailing : .center)
            .background(RoundedRectangle(cornerRadius: 22).fill(pressed ? Color.accentColor.opacity(0.15) : Color(.systemBackground).opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(.separator), lineWidth: 0.6))
            .fixedSize(horizontal: justify == "auto", vertical: false)
            .scaleEffect(pressed ? 0.96 : 1)
            .contentShape(Rectangle())
            .onTapGesture { tap() }
            .onLongPressGesture(minimumDuration: 0.66, pressing: { p in withAnimation(.easeOut(duration: 0.1)) { pressed = p } }) {
                longPress()
            }
    }
}

/// 书源脚本打开的网页（java.startBrowser / 按钮 action 为网址）
struct BrowserSheet: View {
    let url: String
    let title: String
    let headers: [String: String]
    let onClose: () -> Void
    var body: some View {
        BrowserContainer(url: url, title: title, headers: headers, onClose: onClose).ignoresSafeArea()
    }
}

struct BrowserContainer: UIViewControllerRepresentable {
    let url: String, title: String, headers: [String: String]
    let onClose: () -> Void
    func makeUIViewController(context: Context) -> UINavigationController {
        let vc = LoginWebViewController(url: url, title: title.isEmpty ? "网页" : title, headers: headers) { _ in onClose() }
        vc.autoDismiss = false
        return UINavigationController(rootViewController: vc)
    }
    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
}

/// 网页登录（书源没有 loginUi：打开 loginUrl，登录后点「完成」）
struct WebLoginContainer: UIViewControllerRepresentable {
    let source: BookSource
    let onDone: (Bool) -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let vc = LoginWebViewController(url: SourceLogin.webLoginUrl(source),
                                        title: "登录：\(source.bookSourceName)", headers: source.headerMap()) { _ in
            DispatchQueue.main.async { onDone(LoginStore.isLoggedIn(source.bookSourceUrl)) }
        }
        vc.autoDismiss = false
        return UINavigationController(rootViewController: vc)
    }
    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
}

extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
