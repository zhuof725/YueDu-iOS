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
        if let u = URL(string: url) ?? URL(string: Util.encodeLoose(url)) {
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

    @objc private func closeTapped() {
        // 取当前页面 cookie 写回（WKWebView 会自动存，主动同步一次）
        let store = (webView.configuration.websiteDataStore.httpCookieStore)
        store.getAllCookies { _ in }
        let final = webView.url?.absoluteString ?? url
        onDone(final)
        dismiss(animated: true)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}