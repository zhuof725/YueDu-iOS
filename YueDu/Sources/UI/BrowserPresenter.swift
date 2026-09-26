import Foundation
import UIKit

/// 弹出网页登录界面（书源脚本 java.startBrowserAwait 用），在界面关闭后返回
enum BrowserPresenter {
    static func presentAndWait(url: String, title: String, headers: [String: String]) -> HTTPResponse {
        precondition(!Thread.isMainThread, "不能在主线程等待浏览器关闭")
        let sem = DispatchSemaphore(value: 0)
        var finalURL = url
        DispatchQueue.main.async {
            let vc = LoginWebViewController(url: url, title: title, headers: headers) {
                finalURL = $0
                sem.signal()
            }
            let nav = UINavigationController(rootViewController: vc)
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
                root.topmost().present(nav, animated: true)
            } else {
                sem.signal()
            }
        }
        sem.wait()
        return HTTPResponse(url: finalURL, body: "", data: Data(), code: 200, headers: [:])
    }
}

extension UIViewController {
    func topmost() -> UIViewController {
        var top = self
        while let p = top.presentedViewController { top = p }
        return top
    }
}
