import SwiftUI
import UIKit

/// 登录界面状态（同时接收书源脚本的回调：java.upLoginData / java.reLoginView / java.toast）
@MainActor
final class LoginModel: ObservableObject, LoginUICallback {
    let source: BookSource
    @Published var rows: [LoginRow] = []
    @Published var values: [String: String] = [:]
    /// viewName 是 JS 时算出来的显示名
    @Published var names: [String: String] = [:]
    @Published var toastText: String?
    @Published var working = false
    @Published var loading = false
    @Published var browser: BrowserTarget?
    @Published var headerText: String?
    @Published var uiError: String?
    private var debounce: [String: DispatchWorkItem] = [:]

    struct BrowserTarget: Identifiable { let id = UUID(); let url: String; let title: String }

    init(source: BookSource) {
        self.source = source
        values = LoginStore.loginInfoMap(source.bookSourceUrl)
        headerText = LoginStore.loginHeader(source.bookSourceUrl)
    }

    var hasUi: Bool { !(source.loginUi ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: 构建界面

    func buildUI() {
        let src = source, info = values
        uiError = nil
        if SourceLogin.loginUiJs(src) != nil { loading = true }
        Task {
            let rs: [LoginRow] = await Task.detached { [weak self] in
                SourceLogin.rows(src, current: info, callback: self)
            }.value
            loading = false
            if rs.isEmpty && hasUi && SourceLogin.loginUiJs(src) == nil { uiError = "书源的登录界面（loginUi）解析失败，可查看书源 JSON 检查格式" }
            apply(rs)
        }
    }

    private func apply(_ rs: [LoginRow]) {
        rows = rs
        // 默认值（Legado：select/toggle 没值时取 default 或第一个选项）
        for r in rs {
            if values[r.name] == nil || values[r.name]?.isEmpty == true {
                switch r.type {
                case "select", "toggle":
                    if let v = r.defaultValue ?? r.chars.first { values[r.name] = v }
                case "text", "password":
                    if let d = r.defaultValue { values[r.name] = d }
                default: break
                }
            }
        }
        // viewName 是 JS 的，后台算出显示名
        for r in rs where r.viewNameNeedsJS {
            let src = source, info = values, code = r.viewName ?? "", key = r.id
            Task {
                let n: String = await Task.detached { [weak self] in
                    (try? SourceLogin.evalUi(src, code, info: info, callback: self)) ?? "err"
                }.value
                names[key] = n.isEmpty ? "null" : n
            }
        }
    }

    func label(_ r: LoginRow) -> String {
        if let l = r.literalViewName { return l }
        if r.viewNameNeedsJS { return names[r.id] ?? r.name }
        return r.name
    }

    func toggleText(_ r: LoginRow) -> String {
        let v = values[r.name] ?? r.defaultValue ?? r.chars.first ?? ""
        return r.style.justifySelf == "right" ? label(r) + v : v + label(r)
    }

    // MARK: 动作

    /// 按钮/开关/选择的 action：网址打开，JS 执行（带上登录脚本，和 Legado 一样）
    func runAction(_ r: LoginRow, longClick: Bool = false) {
        guard let action = r.action?.trimmingCharacters(in: .whitespacesAndNewlines), !action.isEmpty else { return }
        if SourceLogin.looksLikeURL(action) {
            browser = BrowserTarget(url: Util.absoluteURL(source.bookSourceUrl, action), title: label(r))
            return
        }
        let src = source, info = values
        Task {
            do {
                try await Task.detached { [weak self] in
                    _ = try SourceLogin.buttonAction(src, action: action, info: info, isLongClick: longClick, callback: self)
                }.value
            } catch {
                toast("\(label(r)) 出错：\(error.localizedDescription)")
            }
            headerText = LoginStore.loginHeader(source.bookSourceUrl)
        }
    }

    /// 输入框带 action：停止输入 0.6 秒后执行
    func textChanged(_ r: LoginRow) {
        guard r.action?.isEmpty == false else { return }
        debounce[r.id]?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.runAction(r) }
        debounce[r.id] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    func cycleToggle(_ r: LoginRow) {
        guard !r.chars.isEmpty else { return }
        let cur = values[r.name] ?? r.chars[0]
        let i = r.chars.firstIndex(of: cur) ?? -1
        values[r.name] = r.chars[(i + 1) % r.chars.count]
        runAction(r)
    }

    /// 右上角「登录」：保存表单并调用书源 login()
    func login(done: @escaping () -> Void) {
        if SourceLogin.loginJs(source) == nil {
            // 只有表单没有脚本：仅保存
            _ = SourceLogin.saveInfo(source, values)
            toast("已保存"); done(); return
        }
        working = true
        let src = source, info = values
        Task {
            do {
                try await Task.detached { [weak self] in try SourceLogin.login(src, info: info, callback: self) }.value
                working = false
                headerText = LoginStore.loginHeader(source.bookSourceUrl)
                toast("登录成功")
                try? await Task.sleep(nanoseconds: 700_000_000)
                done()
            } catch {
                working = false
                toast("登录出错\n\(error.localizedDescription)")
            }
        }
    }

    /// 关闭时保存填写内容（Legado 也是这样）
    func saveOnClose() { _ = SourceLogin.saveInfo(source, values) }

    // MARK: LoginUICallback（脚本在后台线程调用）

    nonisolated func upLoginData(_ data: [String: Any]?) {
        let d = data?.mapValues { $0 is NSNull ? "" : JSEngine.stringify($0) }
        Task { @MainActor in
            if let d = d {
                for (k, v) in d { values[k] = v }
            } else {
                // null：全部恢复默认值
                var nv: [String: String] = [:]
                for r in rows {
                    switch r.type {
                    case "select", "toggle": nv[r.name] = r.defaultValue ?? r.chars.first ?? ""
                    case "text", "password": nv[r.name] = r.defaultValue ?? ""
                    default: break
                    }
                }
                values = nv
            }
        }
    }

    nonisolated func reLoginView(_ deltaUp: Bool) {
        Task { @MainActor in buildUI() }
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

/// 登录界面：完全按书源 loginUi 生成；没有 loginUi 时是网页登录（与 Legado 一致）
struct SourceLoginView: View {
    @Environment(\.dismiss) private var dismiss
    let source: BookSource
    @StateObject private var model: LoginModel
    @State private var showHeader = false
    @State private var showWeb = false

    init(source: BookSource) {
        self.source = source
        _model = StateObject(wrappedValue: LoginModel(source: source))
    }

    var body: some View {
        Group {
            // 有 loginUi，或 loginUrl 是登录脚本 → 表单；只有网址 → 网页登录（与 Legado 一致）
            if model.hasUi || SourceLogin.loginJs(source) != nil { formPage } else { webPage }
        }
        .overlay(alignment: .bottom) {
            if let t = model.toastText {
                Text(t).font(.subheadline).foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.black.opacity(0.8)).cornerRadius(10)
                    .padding(.bottom, 40).padding(.horizontal)
                    .transition(.opacity)
                    .onTapGesture { UIPasteboard.general.string = t; model.toastText = nil }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.toastText)
    }

    // MARK: 网页登录（书源没有 loginUi）

    private var webPage: some View {
        WebLoginContainer(source: source) { _ in dismiss() }
            .ignoresSafeArea()
    }

    // MARK: 表单登录（书源 loginUi）

    private var formPage: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.loading { ProgressView().frame(maxWidth: .infinity) }
                    if let e = model.uiError { Text(e).font(.footnote).foregroundColor(.orange) }
                    FlexLayout(spacing: 12, lineSpacing: 12) {
                        ForEach(model.rows) { r in rowView(r) }
                    }
                    if !model.hasUi {
                        Text("该书源没有登录界面（loginUi），点右上角「确认」执行书源的登录脚本。\n如果这个书源本来有登录按钮，请重新导入一次书源（旧版本导入时没有保存登录界面）。").font(.footnote).foregroundColor(.secondary)
                    }
                    if let h = model.headerText, !h.isEmpty {
                        Label("已登录", systemImage: "checkmark.shield").font(.footnote).foregroundColor(.green)
                    }
                }
                .padding()
            }
            .navigationTitle("登录 - \(source.bookSourceName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { model.saveOnClose(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 14) {
                        Menu {
                            Button { showHeader = true } label: { Label("查看登录头", systemImage: "doc.text") }
                            Button(role: .destructive) {
                                LoginStore.logout(source.bookSourceUrl)
                                model.headerText = nil
                                model.toast("已删除登录头")
                            } label: { Label("删除登录头", systemImage: "trash") }
                            Button { showWeb = true } label: { Label("网页登录", systemImage: "globe") }
                        } label: { Image(systemName: "ellipsis.circle") }
                        if model.working { ProgressView() }
                        else {
                            Button("确认") { model.login { dismiss() } }.font(.body.weight(.semibold))
                        }
                    }
                }
            }
            .alert("登录头", isPresented: $showHeader) {
                Button("复制") { UIPasteboard.general.string = model.headerText ?? "" }
                Button("关闭", role: .cancel) {}
            } message: { Text(model.headerText ?? "（没有登录头）") }
            .sheet(item: $model.browser) { b in
                BrowserSheet(url: b.url, title: b.title, headers: source.headerMap()) { model.browser = nil }
            }
            .sheet(isPresented: $showWeb) {
                WebLoginContainer(source: source) { _ in showWeb = false }.ignoresSafeArea()
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { if model.rows.isEmpty { model.buildUI() } }
    }

    @ViewBuilder
    private func rowView(_ r: LoginRow) -> some View {
        switch r.type {
        case "password", "text":
            let b = Binding(get: { model.values[r.name] ?? "" },
                            set: { model.values[r.name] = $0; model.textChanged(r) })
            VStack(alignment: .leading, spacing: 3) {
                Group {
                    if r.type == "password" { SecureField(model.label(r), text: b) }
                    else { TextField(model.label(r), text: b) }
                }
                .multilineTextAlignment(r.style.justifySelf == "center" ? .center : r.style.justifySelf == "flex_end" ? .trailing : .leading)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 22).fill(Color(.systemBackground).opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(.separator), lineWidth: 0.6))
            }
            .flexStyle(r.style, fullWidth: true)
        case "select":
            HStack(spacing: 6) {
                Text(model.label(r)).foregroundColor(.accentColor)
                Picker(model.label(r), selection: Binding(
                    get: { model.values[r.name] ?? r.defaultValue ?? r.chars.first ?? "" },
                    set: { model.values[r.name] = $0; model.runAction(r) })) {
                    ForEach(r.chars, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            }
            .padding(.vertical, 2)
            .flexStyle(r.style)
        case "toggle":
            FilletButton(text: model.toggleText(r), justify: r.style.justifySelf,
                         tap: { model.cycleToggle(r) }, longPress: { model.cycleToggle(r) })
                .flexStyle(r.style)
        default: // button
            FilletButton(text: model.label(r), justify: r.style.justifySelf,
                         tap: { model.runAction(r) }, longPress: { model.runAction(r, longClick: true) })
                .flexStyle(r.style)
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
