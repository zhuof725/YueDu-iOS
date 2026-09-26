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
        .onAppear { loadState() }
    }

    private var formView: some View {
        List {
            if rows.isEmpty {
                Section {
                    Text("该书源没有登录表单，将打开网页登录。\n在网页里完成登录后点「完成」返回。")
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
                isLoggedIn = done
                loadState()
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

    /// 执行表单按钮（发送验证码、检查等）
    private func runButton(_ row: LoginRow) {
        guard let action = row.action else { return }
        working = true; message = nil
        defer { working = false }
        do {
            if action.lowercased().hasPrefix("http") {
                let abs = Util.absoluteURL(source.bookSourceUrl, action)
                BrowserPresenter.presentAndWait(url: abs, title: row.label, headers: source.headerMap())
                loadState()
            } else {
                let v = try SourceLogin.buttonAction(source, action: action, info: values)
                let s = JSEngine.stringify(v)
                if !s.isEmpty { message = s }
                loadState()
            }
        } catch {
            message = "出错：\(error.localizedDescription)"
        }
    }

    private func doLogin() {
        working = true; message = nil
        defer { working = false }
        do {
            try SourceLogin.login(source, info: values)
            // 登录脚本可能改了登录头，刷新状态
            loadState()
            message = isLoggedIn ? "成功：已登录" : "已保存账号信息"
        } catch {
            message = "登录失败：\(error.localizedDescription)"
        }
    }
}

/// 网页登录（内嵌 WKWebView 包装）
struct WebLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    let source: BookSource
    let onFinish: (Bool) -> Void

    var body: some View {
        NavigationView {
            WebLoginContainer(source: source) { ok in
                onFinish(ok)
                dismiss()
            }
            .navigationTitle("网页登录").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { onFinish(true); dismiss() } }
            }
        }
    }
}

struct WebLoginContainer: UIViewControllerRepresentable {
    let source: BookSource
    let onDone: (Bool) -> Void

    func makeUIViewController(context: Context) -> LoginWebViewController {
        let vc = LoginWebViewController(url: SourceLogin.loginPageUrl(source) ?? source.bookSourceUrl,
                                        title: "登录", headers: source.headerMap()) { _ in
            DispatchQueue.main.async { onDone(LoginStore.isLoggedIn(source.bookSourceUrl)) }
        }
        return vc
    }
    func updateUIViewController(_ vc: LoginWebViewController, context: Context) {}
}
