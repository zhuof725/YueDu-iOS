import Foundation
import Security

/// 登录信息存储
/// - 账号密码（loginInfo）存 iOS 钥匙串，系统加密
/// - 登录请求头（loginHeader，例如 token）也存钥匙串，访问书源时自动带上
enum LoginStore {
    private static let service = "io.github.zhuof725.yuedu.login"

    // MARK: 钥匙串读写

    private static func keychainGet(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    private static func keychainSet(_ account: String, _ value: String?) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let v = value, !v.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(v.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return true }
        // 钥匙串不可用时（例如测试环境）退回内存
        fallback[account] = v
        return false
    }

    private static var fallback: [String: String] = [:]
    private static func read(_ account: String) -> String? { keychainGet(account) ?? fallback[account] }
    private static func write(_ account: String, _ v: String?) { fallback[account] = nil; keychainSet(account, v) }

    // MARK: 登录信息（账号、密码等表单内容）

    static func loginInfo(_ key: String) -> String? { read("info_" + key) }
    static func putLoginInfo(_ key: String, _ info: String) -> Bool { write("info_" + key, info); return true }
    static func removeLoginInfo(_ key: String) { write("info_" + key, nil) }

    static func loginInfoMap(_ key: String) -> [String: String] {
        guard let s = loginInfo(key), let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o.mapValues { JSONPath.stringify($0) }
    }

    // MARK: 登录请求头

    static func loginHeader(_ key: String) -> String? { read("header_" + key) }

    static func headerMap(_ key: String) -> [String: String] {
        guard let s = loginHeader(key), let d = s.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o.mapValues { JSONPath.stringify($0) }
    }

    /// 保存登录头；里面有 Cookie 的话同时写进 Cookie 存储
    static func putLoginHeader(_ key: String, _ header: String) {
        write("header_" + key, header)
        if let c = headerMap(key).first(where: { $0.key.lowercased() == "cookie" })?.value {
            CookieHelper.set(url: key, cookie: c)
        }
    }

    static func removeLoginHeader(_ key: String) {
        write("header_" + key, nil)
    }

    /// 是否已经登录（有登录头或者有该站 Cookie）
    static func isLoggedIn(_ key: String) -> Bool {
        if !headerMap(key).isEmpty { return true }
        return !CookieHelper.get(url: key).isEmpty
    }

    /// 退出登录：清除登录头 + 该站 Cookie（保留账号密码，方便再次登录）
    static func logout(_ key: String) {
        removeLoginHeader(key)
        CookieHelper.remove(url: key)
    }
}

enum CookieHelper {
    static func get(url: String) -> String {
        guard let u = URL(string: url) else { return "" }
        return (HTTPCookieStorage.shared.cookies(for: u) ?? []).map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    static func set(url: String, cookie: String) {
        guard let u = URL(string: url), let host = u.host else { return }
        // 主域名（a.b.com → .b.com），让子域名共享登录状态
        let parts = host.split(separator: ".")
        let domain = parts.count >= 2 && Int(parts.last!) == nil ? "." + parts.suffix(2).joined(separator: ".") : host
        for pair in cookie.components(separatedBy: ";") {
            let kv = pair.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2, !kv[0].isEmpty else { continue }
            let lower = kv[0].lowercased()
            if ["path", "domain", "expires", "max-age", "secure", "httponly", "samesite"].contains(lower) { continue }
            if let c = HTTPCookie(properties: [.name: kv[0], .value: kv[1], .domain: domain, .path: "/",
                                               .expires: Date().addingTimeInterval(3600 * 24 * 365)]) {
                HTTPCookieStorage.shared.setCookie(c)
            }
        }
    }

    static func remove(url: String) {
        guard let u = URL(string: url), let host = u.host else { return }
        let parts = host.split(separator: ".")
        let root = parts.suffix(2).joined(separator: ".")
        for c in HTTPCookieStorage.shared.cookies ?? [] where c.domain.hasSuffix(root) {
            HTTPCookieStorage.shared.deleteCookie(c)
        }
    }
}
