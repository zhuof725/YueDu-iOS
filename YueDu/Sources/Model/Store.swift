import Foundation
import SwiftUI

/// 全局数据仓库：书源、书架、目录、正文缓存，全部存在 App 的 Documents 目录
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var sources: [BookSource] = []
    @Published var shelf: [Book] = []

    private let fm = FileManager.default
    private let dir: URL
    private let ioQueue = DispatchQueue(label: "yuedu.io")

    private init() {
        dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: dir.appendingPathComponent("toc"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: dir.appendingPathComponent("content"), withIntermediateDirectories: true)
        sources = load("sources.json") ?? []
        shelf = load("shelf.json") ?? []
    }

    // MARK: 文件读写

    private func load<T: Decodable>(_ name: String) -> T? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    private func save<T: Encodable>(_ v: T, _ name: String) {
        let url = dir.appendingPathComponent(name)
        ioQueue.async {
            if let d = try? JSONEncoder().encode(v) { try? d.write(to: url, options: .atomic) }
        }
    }

    // MARK: 书源

    var enabledSources: [BookSource] {
        sources.filter { $0.isEnabled && ($0.searchUrl?.isEmpty == false) }
    }

    func source(for url: String) -> BookSource? { sources.first { $0.bookSourceUrl == url } }

    /// 导入书源，返回（新增，更新）
    @discardableResult
    func importSources(_ list: [BookSource]) -> (Int, Int) {
        var added = 0, updated = 0
        var map = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($1.bookSourceUrl, $0) })
        for s in list {
            if let i = map[s.bookSourceUrl] { sources[i] = s; updated += 1 }
            else { sources.append(s); map[s.bookSourceUrl] = sources.count - 1; added += 1 }
        }
        save(sources, "sources.json")
        return (added, updated)
    }

    func toggleSource(_ s: BookSource) {
        guard let i = sources.firstIndex(of: s) else { return }
        sources[i].enabled = !(sources[i].enabled ?? true)
        save(sources, "sources.json")
    }

    func deleteSources(at offsets: IndexSet, in list: [BookSource]) {
        let urls = Set(offsets.map { list[$0].bookSourceUrl })
        sources.removeAll { urls.contains($0.bookSourceUrl) }
        save(sources, "sources.json")
    }

    func deleteAllSources() {
        sources.removeAll()
        save(sources, "sources.json")
    }

    func exportSources() -> URL? {
        let url = fm.temporaryDirectory.appendingPathComponent("书源备份.json")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let d = try? enc.encode(sources) else { return nil }
        try? d.write(to: url)
        return url
    }

    // MARK: 书架

    func isOnShelf(_ b: Book) -> Bool { shelf.contains { $0.bookUrl == b.bookUrl } }

    func addToShelf(_ b: Book) {
        var book = b
        if book.addTime == 0 { book.addTime = Date().timeIntervalSince1970 }
        if let i = shelf.firstIndex(where: { $0.bookUrl == b.bookUrl }) { shelf[i] = book }
        else { shelf.insert(book, at: 0) }
        save(shelf, "shelf.json")
    }

    func removeFromShelf(_ b: Book) {
        shelf.removeAll { $0.bookUrl == b.bookUrl }
        save(shelf, "shelf.json")
        let key = Util.md5(b.bookUrl)
        try? fm.removeItem(at: dir.appendingPathComponent("toc/\(key).json"))
        try? fm.removeItem(at: dir.appendingPathComponent("content/\(key)"))
    }

    func updateBook(_ b: Book) {
        if let i = shelf.firstIndex(where: { $0.bookUrl == b.bookUrl }) {
            shelf[i] = b
            save(shelf, "shelf.json")
        }
    }

    /// 按最近阅读排序
    var sortedShelf: [Book] {
        shelf.sorted { max($0.lastReadTime, $0.addTime) > max($1.lastReadTime, $1.addTime) }
    }

    // MARK: 目录缓存

    nonisolated func loadToc(_ b: Book) -> [BookChapter]? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("toc/\(Util.md5(b.bookUrl)).json")
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([BookChapter].self, from: d)
    }

    nonisolated func saveToc(_ b: Book, _ list: [BookChapter]) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("toc/\(Util.md5(b.bookUrl)).json")
        if let d = try? JSONEncoder().encode(list) { try? d.write(to: url, options: .atomic) }
    }

    // MARK: 正文缓存

    nonisolated private func contentURL(_ b: Book, _ c: BookChapter) -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("content/\(Util.md5(b.bookUrl))")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("\(Util.md5(c.url)).txt")
    }

    nonisolated func loadContent(_ b: Book, _ c: BookChapter) -> String? {
        try? String(contentsOf: contentURL(b, c), encoding: .utf8)
    }

    nonisolated func saveContent(_ b: Book, _ c: BookChapter, _ text: String) {
        guard !text.isEmpty else { return }
        try? text.write(to: contentURL(b, c), atomically: true, encoding: .utf8)
    }

    nonisolated func clearContentCache(_ b: Book) {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("content/\(Util.md5(b.bookUrl))")
        try? FileManager.default.removeItem(at: base)
    }
}

/// 阅读设置（修改后自动保存）
final class ReadSettings: ObservableObject {
    static let shared = ReadSettings()
    private static let ud = UserDefaults.standard

    @Published var fontSize: Double { didSet { Self.ud.set(fontSize, forKey: "fontSize") } }
    @Published var lineSpacing: Double { didSet { Self.ud.set(lineSpacing, forKey: "lineSpacing") } }
    @Published var paragraphSpacing: Double { didSet { Self.ud.set(paragraphSpacing, forKey: "paragraphSpacing") } }
    @Published var horizontalPadding: Double { didSet { Self.ud.set(horizontalPadding, forKey: "horizontalPadding") } }
    @Published var theme: Int { didSet { Self.ud.set(theme, forKey: "theme") } }
    @Published var pageMode: Int { didSet { Self.ud.set(pageMode, forKey: "pageMode") } }   // 0 上下滚动 1 左右翻页
    @Published var keepScreenOn: Bool { didSet { Self.ud.set(keepScreenOn, forKey: "keepScreenOn") } }

    private init() {
        let u = Self.ud
        fontSize = u.object(forKey: "fontSize") as? Double ?? 20
        lineSpacing = u.object(forKey: "lineSpacing") as? Double ?? 10
        paragraphSpacing = u.object(forKey: "paragraphSpacing") as? Double ?? 12
        horizontalPadding = u.object(forKey: "horizontalPadding") as? Double ?? 20
        theme = u.object(forKey: "theme") as? Int ?? 0
        pageMode = u.object(forKey: "pageMode") as? Int ?? 0
        keepScreenOn = u.object(forKey: "keepScreenOn") as? Bool ?? true
    }

    struct Theme { let name: String; let bg: Color; let fg: Color }
    static let themes: [Theme] = [
        Theme(name: "羊皮纸", bg: Color(red: 0.96, green: 0.93, blue: 0.85), fg: Color(red: 0.2, green: 0.17, blue: 0.13)),
        Theme(name: "白色", bg: .white, fg: Color(white: 0.12)),
        Theme(name: "护眼绿", bg: Color(red: 0.8, green: 0.91, blue: 0.81), fg: Color(red: 0.12, green: 0.2, blue: 0.12)),
        Theme(name: "浅灰", bg: Color(white: 0.9), fg: Color(white: 0.15)),
        Theme(name: "夜间", bg: Color(white: 0.08), fg: Color(white: 0.62)),
    ]
    var currentTheme: Theme { ReadSettings.themes[min(max(theme, 0), ReadSettings.themes.count - 1)] }
}
