import Foundation
import UIKit

/// 弹出网页 / 验证码界面，并在后台线程等待用户操作结束
/// （对应 Legado SourceVerificationHelp：startBrowserAwait / getVerificationCode）
enum BrowserPresenter {
    private static func present(_ vc: UIViewController) -> Bool {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = (scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first)?.rootViewController
        else { return false }
        root.topmost().present(vc, animated: true)
        return true
    }

    /// 打开网页，等用户点「完成/取消」后返回（最终网址 + 网页源代码）
    static func presentAndWait(url: String, title: String, headers: [String: String], sourceKey: String? = nil) -> HTTPResponse {
        if Thread.isMainThread { return HTTPResponse(url: url, body: "", data: Data(), code: 0, headers: [:]) }
        let sem = DispatchSemaphore(value: 0)
        var finalURL = url
        var html = ""
        DispatchQueue.main.async {
            var ref: LoginWebViewController?
            let vc = LoginWebViewController(url: url, title: title, headers: headers) { u in
                finalURL = u
                html = ref?.pageHTML ?? ""
                sem.signal()
            }
            ref = vc
            let nav = UINavigationController(rootViewController: vc)
            // 禁止下滑关闭，否则脚本会一直等下去
            nav.isModalInPresentation = true
            if !present(nav) { sem.signal() }
        }
        sem.wait()
        return HTTPResponse(url: finalURL, body: html, data: Data(html.utf8), code: 200, headers: [:])
    }

    /// 图片验证码：显示图片 + 输入框，返回用户输入
    static func askCode(imageUrl: String, headers: [String: String], title: String) -> String {
        if Thread.isMainThread { return "" }
        var img: UIImage?
        if let u = URL(string: imageUrl) ?? URL(string: Util.encodeLoose(imageUrl)) {
            var req = URLRequest(url: u, timeoutInterval: 15)
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            let s = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: req) { d, _, _ in img = d.flatMap { UIImage(data: $0) }; s.signal() }.resume()
            s.wait()
        }
        let sem = DispatchSemaphore(value: 0)
        var code = ""
        DispatchQueue.main.async {
            let a = UIAlertController(title: title.isEmpty ? "输入验证码" : "\(title)：输入验证码", message: img == nil ? "验证码图片加载失败" : "\n\n\n\n", preferredStyle: .alert)
            if let i = img {
                let iv = UIImageView(image: i)
                iv.contentMode = .scaleAspectFit
                iv.translatesAutoresizingMaskIntoConstraints = false
                a.view.addSubview(iv)
                NSLayoutConstraint.activate([
                    iv.centerXAnchor.constraint(equalTo: a.view.centerXAnchor),
                    iv.topAnchor.constraint(equalTo: a.view.topAnchor, constant: 52),
                    iv.widthAnchor.constraint(equalToConstant: 200),
                    iv.heightAnchor.constraint(equalToConstant: 70),
                ])
            }
            a.addTextField { $0.placeholder = "验证码" }
            a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in sem.signal() })
            a.addAction(UIAlertAction(title: "确定", style: .default) { _ in code = a.textFields?.first?.text ?? ""; sem.signal() })
            if !present(a) { sem.signal() }
        }
        sem.wait()
        return code
    }
}

extension UIViewController {
    func topmost() -> UIViewController {
        var top = self
        while let p = top.presentedViewController { top = p }
        return top
    }
}
