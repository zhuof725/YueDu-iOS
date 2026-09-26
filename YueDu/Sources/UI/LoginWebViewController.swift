import Foundation
import UIKit
import WebKit

/// 网页登录页：登录完成后点「完成」返回，cookie 已存入系统 Cookie 存储
final class LoginWebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let url: String
    private let titleText: String
    private let headers: [String: String]
    private let onDone: (String) -> Void
    private var webView: WKWebView!
    /// SwiftUI 里使用时由外层负责关闭
    var autoDismiss = true
    private var finished = false

    init(url: String, title: String, headers: [String: String], onDone: @escaping (String) -> Void) {
        self.url = url
        self.titleText = title
        self.headers = headers
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        navigationItem.title = titleText.isEmpty ? "登录" : titleText
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "取消", style: .plain, target: self, action: #selector(closeTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "完成", style: .done, target: self, action: #selector(closeTapped))
        if url.lowercased().hasPrefix("data:") {
            // data:text/html;base64,xxx（书源用来展示一段网页，比如「复制 Tag」）
            if let comma = url.firstIndex(of: ",") {
                let meta = url[..<comma].lowercased()
                let payload = String(url[url.index(after: comma)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                let html: String
                if meta.contains(";base64") {
                    html = Data(base64Encoded: payload, options: .ignoreUnknownCharacters).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                } else {
                    html = payload.removingPercentEncoding ?? payload
                }
                webView.loadHTMLString(html, baseURL: nil)
            }
        } else if let u = URL(string: url) ?? URL(string: Util.encodeLoose(url)) {
            var req = URLRequest(url: u)
            if let ua = headers.first(where: { $0.key.lowercased() == "user-agent" })?.value {
                webView.customUserAgent = ua
            }
            for (k, v) in headers where k.lowercased() != "user-agent" {
                req.setValue(v, forHTTPHeaderField: k)
            }
            webView.load(req)
        }
    }

    @objc private func closeTapped() { finish() }

    /// 把网页里的 Cookie 同步到 App 的网络请求（WKWebView 的 Cookie 和 URLSession 是分开存的）
    func finish() {
        guard !finished else { return }
        finished = true
        let final = webView?.url?.absoluteString ?? url
        guard let store = webView?.configuration.websiteDataStore.httpCookieStore else {
            onDone(final); if autoDismiss { dismiss(animated: true) }; return
        }
        store.getAllCookies { [weak self] cookies in
            for c in cookies { HTTPCookieStorage.shared.setCookie(c) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.onDone(final)
                if self.autoDismiss { self.dismiss(animated: true) }
            }
        }
    }

    /// 页面加载完也同步一次 Cookie（防止用户直接划掉页面）
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            for c in cookies { HTTPCookieStorage.shared.setCookie(c) }
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

extension CookieBridge {
    /// 同时清掉网页里的登录 Cookie，否则再次打开登录页还是已登录状态
    static func removeWebCookies(_ root: String) {
        DispatchQueue.main.async {
            let store = WKWebsiteDataStore.default().httpCookieStore
            store.getAllCookies { cs in
                for c in cs {
                    let d = c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                    if d == root || d.hasSuffix("." + root) { store.delete(c) }
                }
            }
        }
    }
}
