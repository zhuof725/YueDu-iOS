import Foundation

/// 搜索结果 / 书籍信息
struct Book: Codable, Identifiable, Hashable {
    var id: String { bookUrl + "|" + origin }

    var bookUrl: String
    var origin: String            // 书源 URL
    var originName: String
    var name: String
    var author: String
    var kind: String?
    var coverUrl: String?
    var intro: String?
    var latestChapterTitle: String?
    var wordCount: String?
    var tocUrl: String?
    var updateTime: String?

    // 阅读进度
    var durChapterIndex: Int = 0
    var durChapterPos: Int = 0
    var durChapterTitle: String?
    var totalChapterNum: Int = 0
    var lastReadTime: Double = 0
    var addTime: Double = 0
    var variable: String?

    /// 书源脚本 put/get 用的变量表
    var variableMap: [String: String] {
        get {
            guard let v = variable, let d = v.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return [:] }
            return o
        }
        set {
            if let d = try? JSONSerialization.data(withJSONObject: newValue) {
                variable = String(data: d, encoding: .utf8)
            }
        }
    }

    static func == (l: Book, r: Book) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct BookChapter: Codable, Identifiable, Hashable {
    var id: String { url }
    var url: String
    var title: String
    var index: Int
    var isVolume: Bool = false
    var isVip: Bool = false
    var isPay: Bool = false
    var updateTime: String?
    var variable: String?

    static func == (l: BookChapter, r: BookChapter) -> Bool { l.url == r.url }
    func hash(into h: inout Hasher) { h.combine(url) }
}

enum YueDuError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let m) = self { return m }
        return nil
    }
}
