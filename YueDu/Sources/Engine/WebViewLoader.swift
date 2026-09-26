import Foundation
import WebKit

/// 用隐藏的 WKWebView 加载网页并取渲染后的 HTML（对应书源里的 webView:true）
final class WebViewLoader: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var done: ((Result<HTTPResponse, Error>) -> Void)?
    private var js: String?
    private var url = ""
    private var finished = false

    /// 同步调用（必须在后台线程）
    static func load(url: String, html: String? = nil, headers: [String: String], js: String?, timeout: TimeInterval = 25) throws -> HTTPResponse {
        precondition(!Thread.isMainThread, "WebViewLoader.load 不能在主线程调用")
        let sem = DispatchSemaphore(value: 0)
        var result: Result<HTTPResponse, Error> = .failure(YueDuError.message("WebView 超时"))
        var loader: WebViewLoader?
        DispatchQueue.main.async {
            loader = WebViewLoader()
            loader!.start(url: url, html: html, headers: headers, js: js) { r in
                result = r
                sem.signal()
            }
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            DispatchQueue.main.async { loader?.cleanup() }
        }
        return try result.get()
    }

    private func start(url: String, html: String?, headers: [String: String], js: String?, done: @escaping (Result<HTTPResponse, Error>) -> Void) {
        self.done = done
        self.js = js
        self.url = url
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 800), configuration: cfg)
        wv.navigationDelegate = self
        wv.customUserAgent = headers.first { $0.key.lowercased() == "user-agent" }?.value ?? BookSource.defaultUA
        webView = wv
        if let html = html, !html.isEmpty {
            wv.loadHTMLString(html, baseURL: URL(string: url))
        } else if let u = URL(string: url) ?? URL(string: Util.encodeLoose(url)) {
            var req = URLRequest(url: u)
            for (k, v) in headers where k.lowercased() != "user-agent" { req.setValue(v, forHTTPHeaderField: k) }
            wv.load(req)
        } else {
            finish(.failure(YueDuError.message("网址无效")))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 等页面脚本跑一会儿
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.collect(attempt: 0) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }

    private func collect(attempt: Int) {
        guard let wv = webView, !finished else { return }
        let script = (js?.isEmpty == false) ? js! : "document.documentElement.outerHTML"
        wv.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self = self else { return }
            let s: String
            if let v = value as? String { s = v } else if let v = value { s = "\(v)" } else { s = "" }
            // 有 webJs 时，返回空说明还没准备好，重试几次
            if s.isEmpty && attempt < 8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.collect(attempt: attempt + 1) }
                return
            }
            let final = wv.url?.absoluteString ?? self.url
            self.finish(.success(HTTPResponse(url: final, body: s, data: Data(s.utf8), code: 200, headers: [:])))
        }
    }

    private func finish(_ r: Result<HTTPResponse, Error>) {
        guard !finished else { return }
        finished = true
        done?(r)
        cleanup()
    }

    private func cleanup() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        done = nil
    }
}
