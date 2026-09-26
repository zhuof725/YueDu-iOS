import SwiftUI
import UIKit

/// 登录界面：书源有 loginUi 就显示表单，否则显示网页登录
struct SourceLoginView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let source: BookSource
    @State private var rows: [LoginRow] = []
    @State private var values: [String: String] = [:]
    @State private var working = false
    @State private var message: String?
    @State private var isLoggedIn = false
    @State private var loginHeaderText: String?
    @State private var showWeb = false
    @State private var needReLogin = false

    var body: some View {
        NavigationView {
            Group {
                if needReLogin || loginHeaderText == nil {
                    formView
                } else {
                    loggedInView
                }
            }
            .navigationTitle("登录 \(source.bookSourceName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("关闭") { dismiss() } }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            loadState()
            // 没有表单、也没有 login 函数：直接打开网页登录
            if rows.isEmpty && !SourceLogin.hasLoginFunction(source) && loginHeaderText == nil { showWeb = true }
        }
    }

    private var formView: some View {
        List {
            if rows.isEmpty {
                Section {
                    Text(SourceLogin.hasLoginFunction(source)
                         ? "该书源使用脚本登录，点下方「登录」执行。"
                         : "该书源使用网页登录。\n点下方「网页登录」，在网页里登录后点右上角「完成」返回。")
                        .font(.footnote).foregroundColor(.secondary)
                }
            } else {
                Section("账号信息") {
                    ForEach(rows) { row in
                        if row.isInput {
                            if row.type == "password" {
                                SecureField(row.label, text: Binding(get: { values[row.name] ?? "" }, set: { values[row.name] = $0 }))
                            } else {
                                TextField(row.label, text: Binding(get: { values[row.name] ?? "" }, set: { values[row.name] = $0 }))
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                            }
                        } else if row.type == "select" {
                            Picker(row.label, selection: Binding(get: { values[row.name] ?? row.chars.first ?? "" }, set: { values[row.name] = $0 })) {
                                ForEach(row.chars, id: \.self) { Text($0) }
                            }
                        } else if row.type == "toggle" {
                            Toggle(row.label, isOn: Binding(get: { values[row.name] == "1" || values[row.name] == row.chars.first },
                                                            set: { values[row.name] = $0 ? (row.chars.first ?? "1") : "" }))
                        }
                    }
                }
                Section("操作") {
                    ForEach(rows.filter { $0.type == "button" }) { row in
                        Button(row.label) { runButton(row) }.disabled(working)
                    }
                }
            }
            if let m = message {
                Section { Text(m).font(.footnote).foregroundColor(m.hasPrefix("成功") ? .green : .orange) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 14) {
                Button { showWeb = true } label: { Text("网页登录").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                Button { doLogin() } label: {
                    Text(working ? "登录中…" : "登录").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || (rows.isEmpty && !source.hasLogin))
            }
            .padding()
            .background(.bar)
        }
        .sheet(isPresented: $showWeb) {
            WebLoginSheet(source: source) { done in
                loadState()
                isLoggedIn = done
                message = done ? "成功：网页登录状态已保存" : "未检测到登录 Cookie，如已登录可直接去搜索试试"
            }
        }
    }

    private var loggedInView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.shield").font(.system(size: 52)).foregroundColor(.green)
            Text("已登录").font(.title2.bold())
            if let h = loginHeaderText { Text(h).font(.caption).foregroundColor(.secondary).lineLimit(3) }
            if needReLogin {
                Text("检测到登录可能已失效，请重新登录。").font(.footnote).foregroundColor(.orange)
            }
            Button(role: .destructive) {
                LoginStore.logout(source.bookSourceUrl)
                needReLogin = true
                loadState()
            } label: { Text("退出登录").frame(maxWidth: .infinity) }
            .buttonStyle(.bordered)
            .padding(.horizontal)
        }
        .padding()
    }

    private func loadState() {
        rows = SourceLogin.rows(source, current: LoginStore.loginInfoMap(source.bookSourceUrl))
        values = LoginStore.loginInfoMap(source.bookSourceUrl)
        isLoggedIn = LoginStore.isLoggedIn(source.bookSourceUrl)
        loginHeaderText = LoginStore.loginHeader(source.bookSourceUrl)
        needReLogin = false
    }

    /// 执行表单按钮（发送验证码、检查等）。脚本可能联网或弹网页，放后台执行
    private func runButton(_ row: LoginRow) {
        guard let action = row.action?.trimmingCharacters(in: .whitespacesAndNewlines), !action.isEmpty else { return }
        working = true; message = nil
        let src = source, info = values
        Task {
            do {
                if SourceLogin.looksLikeURL(action) {
                    let abs = Util.absoluteURL(src.bookSourceUrl, action)
                    _ = try await runInBackground { BrowserPresenter.presentAndWait(url: abs, title: row.label, headers: src.headerMap()) }
                } else {
                    let s = try await runInBackground { JSEngine.stringify(try SourceLogin.buttonAction(src, action: action, info: info)) }
                    if !s.isEmpty && s != "undefined" { message = s }
                }
            } catch {
                message = "出错：\(error.localizedDescription)"
            }
            let m = message
            loadState()
            message = m
            working = false
        }
    }

    private func doLogin() {
        // 没有登录脚本 → 只能网页登录
        if SourceLogin.loginJs(source) == nil {
            showWeb = true; return
        }
        working = true; message = nil
        let src = source, info = values
        Task {
            do {
                try await runInBackground { try SourceLogin.login(src, info: info) }
                loadState()
                message = isLoggedIn ? "成功：已登录" : "成功：已保存账号信息（书源脚本没有返回登录凭证，可去搜索试试是否生效）"
            } catch {
                message = "登录失败：\(error.localizedDescription)"
            }
            working = false
        }
    }
}

/// 网页登录（内嵌 WKWebView 包装）
struct WebLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    let source: BookSource
    let onFinish: (Bool) -> Void

    var body: some View {
        WebLoginContainer(source: source) { ok in
            onFinish(ok)
            dismiss()
        }
        .ignoresSafeArea()
    }
}

struct WebLoginContainer: UIViewControllerRepresentable {
    let source: BookSource
    let onDone: (Bool) -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let vc = LoginWebViewController(url: SourceLogin.webLoginUrl(source),
                                        title: "网页登录", headers: source.headerMap()) { _ in
            DispatchQueue.main.async { onDone(LoginStore.isLoggedIn(source.bookSourceUrl)) }
        }
        vc.autoDismiss = false
        return UINavigationController(rootViewController: vc)
    }
    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
}
