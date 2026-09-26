import Foundation

/// 书源 jsLib（对应 Legado SharedJsScope.getScope）
/// - 普通 JS 文本：直接执行
/// - JSON 对象 {"名字": "https://…/lib.js"}：逐个下载网址里的脚本（缓存到本地）再执行
enum JsLibLoader {
    private static var memory: [String: String] = [:]
    private static let lock = NSLock()

    static func scripts(_ jsLib: String) -> [String] {
        let t = jsLib.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{"), let map = BookSourceImporter.parseJSONLoose(t) as? [String: Any] else { return [t] }
        var out: [String] = []
        for key in map.keys.sorted() {
            let v = JSONPath.stringify(map[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = v.lowercased()
            guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { continue }
            if let js = load(v) { out.append(js) }
        }
        return out
    }

    private static func cacheFile(_ url: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("shareJs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(Util.md5(url))
    }

    static func load(_ url: String) -> String? {
        lock.lock(); if let m = memory[url] { lock.unlock(); return m }; lock.unlock()
        let f = cacheFile(url)
        if let d = try? Data(contentsOf: f), let s = String(data: d, encoding: .utf8), !s.isEmpty {
            lock.lock(); memory[url] = s; lock.unlock(); return s
        }
        guard let u = URL(string: url) else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var body: String?
        var req = URLRequest(url: u, timeoutInterval: 20)
        req.setValue(BookSource.defaultUA, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { d, r, _ in
            if let d = d, ((r as? HTTPURLResponse)?.statusCode ?? 200) < 400 {
                body = String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 25)
        guard let js = body, !js.isEmpty else { return nil }
        try? Data(js.utf8).write(to: f, options: .atomic)
        lock.lock(); memory[url] = js; lock.unlock()
        return js
    }

    /// Legado source.refreshJSLib()：清缓存后重新下载
    static func remove(_ jsLib: String?) {
        guard let t = jsLib?.trimmingCharacters(in: .whitespacesAndNewlines), t.hasPrefix("{"),
              let map = BookSourceImporter.parseJSONLoose(t) as? [String: Any] else { return }
        for v in map.values {
            let url = JSONPath.stringify(v)
            try? FileManager.default.removeItem(at: cacheFile(url))
            lock.lock(); memory[url] = nil; lock.unlock()
        }
    }
}
