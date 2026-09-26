import Foundation

/// 书源工作流：搜索 → 详情 → 目录 → 正文（对应 Legado model/webBook）
/// 所有方法都是同步的，必须在后台线程调用
enum WebBook {

    // MARK: 搜索

    static func search(_ source: BookSource, key: String, page: Int = 1, logger: DebugLog? = nil) throws -> [Book] {
        guard let searchUrl = source.searchUrl, !searchUrl.isEmpty else {
            throw YueDuError.message("该书源没有搜索地址")
        }
        let engine = RuleEngine(source: source, logger: logger)
        let au = AnalyzeUrl(searchUrl, key: key, page: page, source: source, engine: engine)
        logger?.log("⇒ 搜索地址：\(au.requestUrl)  [\(au.method)]")
        let res = try au.fetch()
        logger?.log("⇐ 状态 \(res.code)，长度 \(res.body.count)")
        return try parseBookList(source, body: res.body, baseUrl: res.url, rule: source.ruleSearch,
                                 isSearch: true, engine: engine, logger: logger)
    }

    static func explore(_ source: BookSource, url: String, page: Int = 1, logger: DebugLog? = nil) throws -> [Book] {
        let engine = RuleEngine(source: source, logger: logger)
        let au = AnalyzeUrl(url, page: page, source: source, engine: engine)
        let res = try au.fetch()
        let rule = source.ruleExplore?.bookList?.isEmpty == false ? source.ruleExplore : source.ruleSearch
        return try parseBookList(source, body: res.body, baseUrl: res.url, rule: rule, isSearch: false, engine: engine, logger: logger)
    }

    static func parseBookList(_ source: BookSource, body: String, baseUrl: String, rule: SearchRule?,
                              isSearch: Bool, engine: RuleEngine, logger: DebugLog?) throws -> [Book] {
        guard let rule = rule else { throw YueDuError.message("书源缺少搜索规则") }
        engine.setContent(body, baseUrl: baseUrl)
        engine.setRedirectUrl(baseUrl)

        // 搜索结果直接跳到详情页
        if isSearch, let p = source.bookUrlPattern, !p.isEmpty,
           baseUrl.range(of: p, options: .regularExpression) != nil {
            logger?.log("≡ 链接是详情页")
            var b = Book(bookUrl: baseUrl, origin: source.bookSourceUrl, originName: source.bookSourceName, name: "", author: "")
            try parseBookInfo(source, book: &b, body: body, baseUrl: baseUrl, engine: RuleEngine(source: source, logger: logger), logger: logger)
            return b.name.isEmpty ? [] : [b]
        }

        var listRule = rule.bookList ?? ""
        var reverse = false
        if listRule.hasPrefix("-") { reverse = true; listRule.removeFirst() }
        if listRule.hasPrefix("+") { listRule.removeFirst() }
        let items = engine.getElements(listRule)
        logger?.log("≡ 列表数量：\(items.count)")

        if items.isEmpty && (source.bookUrlPattern ?? "").isEmpty {
            // 可能直接是详情页
            var b = Book(bookUrl: baseUrl, origin: source.bookSourceUrl, originName: source.bookSourceName, name: "", author: "")
            if (try? parseBookInfo(source, book: &b, body: body, baseUrl: baseUrl, engine: RuleEngine(source: source, logger: logger), logger: logger)) != nil,
               !b.name.isEmpty {
                return [b]
            }
            return []
        }

        var books: [Book] = []
        for (i, item) in items.enumerated() {
            let e = RuleEngine(source: source, logger: nil)
            e.setContent(item, baseUrl: baseUrl)
            e.setRedirectUrl(baseUrl)
            let log = i == 0 ? logger : nil
            var b = Book(bookUrl: "", origin: source.bookSourceUrl, originName: source.bookSourceName, name: "", author: "")
            b.name = Util.formatBookName(e.getString(rule.name))
            log?.log("┌书名：\(b.name)")
            if b.name.isEmpty { continue }
            b.author = Util.formatAuthor(e.getString(rule.author))
            log?.log("┌作者：\(b.author)")
            b.kind = e.getStringList(rule.kind)?.filter { !$0.isEmpty }.joined(separator: ",")
            b.wordCount = e.getString(rule.wordCount)
            b.latestChapterTitle = e.getString(rule.lastChapter)
            b.intro = Util.formatIntro(e.getString(rule.intro))
            let cover = e.getString(rule.coverUrl)
            if !cover.isEmpty { b.coverUrl = Util.absoluteURL(baseUrl, cover) }
            b.bookUrl = e.getString(rule.bookUrl, isUrl: true)
            if b.bookUrl.isEmpty { b.bookUrl = baseUrl }
            log?.log("┌详情页：\(b.bookUrl)")
            books.append(b)
        }
        if reverse { books.reverse() }
        return books
    }

    // MARK: 详情

    static func getBookInfo(_ source: BookSource, book: inout Book, logger: DebugLog? = nil) throws {
        let engine = RuleEngine(source: source, book: book, logger: logger)
        let au = AnalyzeUrl(book.bookUrl, baseUrl: source.bookSourceUrl, source: source, book: book, engine: engine)
        logger?.log("⇒ 详情页：\(au.requestUrl)")
        let res = try au.fetch()
        try parseBookInfo(source, book: &book, body: res.body, baseUrl: res.url, engine: engine, logger: logger)
    }

    static func parseBookInfo(_ source: BookSource, book: inout Book, body: String, baseUrl: String,
                              engine: RuleEngine, logger: DebugLog?) throws {
        let rule = source.ruleBookInfo ?? BookInfoRule()
        engine.book = book
        engine.setContent(body, baseUrl: baseUrl)
        engine.setRedirectUrl(baseUrl)
        if let initRule = rule.`init`, !initRule.isEmpty {
            logger?.log("≡ 执行详情页初始化规则")
            if let r = engine.getElement(initRule) {
                if let el = r as? [Any], el.count == 1 { engine.setContent(el[0]) }
                else { engine.setContent(r) }
            }
        }
        let name = Util.formatBookName(engine.getString(rule.name))
        if !name.isEmpty && (book.name.isEmpty || Util.isTrue(rule.canReName)) { book.name = name }
        let author = Util.formatAuthor(engine.getString(rule.author))
        if !author.isEmpty && book.author.isEmpty { book.author = author }
        if let k = engine.getStringList(rule.kind)?.filter({ !$0.isEmpty }), !k.isEmpty { book.kind = k.joined(separator: ",") }
        let wc = engine.getString(rule.wordCount); if !wc.isEmpty { book.wordCount = wc }
        let lc = engine.getString(rule.lastChapter); if !lc.isEmpty { book.latestChapterTitle = lc }
        let intro = engine.getString(rule.intro); if !intro.isEmpty { book.intro = Util.formatIntro(intro) }
        let cover = engine.getString(rule.coverUrl); if !cover.isEmpty { book.coverUrl = Util.absoluteURL(baseUrl, cover) }
        let toc = engine.getString(rule.tocUrl, isUrl: true)
        book.tocUrl = toc.isEmpty ? baseUrl : toc
        logger?.log("┌书名：\(book.name)\n┌作者：\(book.author)\n┌目录页：\(book.tocUrl ?? "")")
        // 如果目录页就是详情页，缓存 HTML 避免再请求
        if book.tocUrl == baseUrl { TocCache.shared.put(baseUrl, body) }
    }

    // MARK: 目录

    static func getChapterList(_ source: BookSource, book: Book, logger: DebugLog? = nil) throws -> [BookChapter] {
        guard let rule = source.ruleToc else { throw YueDuError.message("书源缺少目录规则") }
        let tocUrl = (book.tocUrl?.isEmpty == false) ? book.tocUrl! : book.bookUrl
        let engine = RuleEngine(source: source, book: book, logger: logger)
        var body: String
        var redirect: String
        if let cached = TocCache.shared.take(tocUrl) {
            body = cached; redirect = tocUrl
        } else {
            let au = AnalyzeUrl(tocUrl, baseUrl: book.bookUrl, source: source, book: book, engine: engine)
            logger?.log("⇒ 目录页：\(au.requestUrl)")
            let res = try au.fetch()
            body = res.body; redirect = res.url
        }
        var listRule = rule.chapterList ?? ""
        var reverse = false
        if listRule.hasPrefix("-") { reverse = true; listRule.removeFirst() }
        if listRule.hasPrefix("+") { listRule.removeFirst() }

        var all: [BookChapter] = []
        var visited: Set<String> = [redirect]
        var (list, nexts) = parseChapterPage(source, book: book, body: body, baseUrl: redirect, rule: rule, listRule: listRule, logger: logger)
        all += list
        if nexts.count == 1 {
            var next = nexts[0]
            var guardCount = 0
            while !next.isEmpty && !visited.contains(next) && guardCount < 500 {
                visited.insert(next); guardCount += 1
                let au = AnalyzeUrl(next, source: source, book: book, engine: engine)
                guard let res = try? au.fetch() else { break }
                (list, nexts) = parseChapterPage(source, book: book, body: res.body, baseUrl: res.url, rule: rule, listRule: listRule, logger: nil)
                all += list
                next = nexts.first ?? ""
            }
            logger?.log("◇ 目录总页数：\(visited.count)")
        } else if nexts.count > 1 {
            var pages = [[BookChapter]](repeating: [], count: nexts.count)
            let g = DispatchGroup()
            let sem = DispatchSemaphore(value: 6)
            for (i, u) in nexts.enumerated() {
                g.enter()
                DispatchQueue.global().async {
                    sem.wait(); defer { sem.signal(); g.leave() }
                    let au = AnalyzeUrl(u, source: source, book: book)
                    if let res = try? au.fetch() {
                        pages[i] = parseChapterPage(source, book: book, body: res.body, baseUrl: res.url, rule: rule, listRule: listRule, logger: nil).0
                    }
                }
            }
            g.wait()
            for p in pages { all += p }
        }
        if all.isEmpty { throw YueDuError.message("目录为空，可能是书源失效或规则不兼容") }
        if reverse { all.reverse() }
        // 按 URL 去重（保留第一次出现的）
        var seen = Set<String>()
        var out: [BookChapter] = []
        for c in all where !seen.contains(c.url) || c.isVolume {
            seen.insert(c.url)
            out.append(c)
        }
        for i in out.indices { out[i].index = i }
        logger?.log("◇ 目录总数：\(out.count)")
        return out
    }

    private static func parseChapterPage(_ source: BookSource, book: Book, body: String, baseUrl: String,
                                         rule: TocRule, listRule: String, logger: DebugLog?) -> ([BookChapter], [String]) {
        let engine = RuleEngine(source: source, book: book, logger: logger)
        engine.setContent(body, baseUrl: baseUrl)
        engine.setRedirectUrl(baseUrl)
        var nexts: [String] = []
        if let n = rule.nextTocUrl, !n.isEmpty {
            nexts = (engine.getStringList(n, isUrl: true) ?? []).filter { $0 != baseUrl }
        }
        let items = engine.getElements(listRule)
        logger?.log("≡ 本页章节数：\(items.count)")
        var list: [BookChapter] = []
        for item in items {
            let e = RuleEngine(source: source, book: book)
            e.setContent(item, baseUrl: baseUrl)
            e.setRedirectUrl(baseUrl)
            let title = e.getString(rule.chapterName).trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty { continue }
            let isVolume = Util.isTrue(e.getString(rule.isVolume))
            var url = e.getString(rule.chapterUrl, isUrl: true)
            if url.isEmpty || url == baseUrl {
                url = isVolume ? title + "\(list.count)" : baseUrl
            }
            var ch = BookChapter(url: url, title: title, index: list.count)
            ch.isVolume = isVolume
            ch.isVip = Util.isTrue(e.getString(rule.isVip))
            ch.isPay = Util.isTrue(e.getString(rule.isPay))
            let ut = e.getString(rule.updateTime); if !ut.isEmpty { ch.updateTime = ut }
            list.append(ch)
        }
        if let first = list.first { logger?.log("┌首章：\(first.title) \(first.url)") }
        return (list, nexts)
    }

    // MARK: 正文

    static func getContent(_ source: BookSource, book: Book, chapter: BookChapter, nextChapterUrl: String?,
                           logger: DebugLog? = nil) throws -> String {
        if chapter.isVolume && !chapter.url.hasPrefix("http") { return "" }
        guard let rule = source.ruleContent, let cr = rule.content, !cr.isEmpty else {
            throw YueDuError.message("书源缺少正文规则")
        }
        let engine = RuleEngine(source: source, book: book, logger: logger)
        engine.chapter = chapter
        engine.nextChapterUrl = nextChapterUrl
        let au = AnalyzeUrl(chapter.url, baseUrl: book.tocUrl ?? book.bookUrl, source: source, book: book, engine: engine)
        logger?.log("⇒ 正文页：\(au.requestUrl)")
        let res = try au.fetch()
        var parts: [String] = []
        var (text, nexts) = parseContentPage(source, book: book, chapter: chapter, body: res.body, baseUrl: res.url,
                                             rule: rule, nextChapterUrl: nextChapterUrl, logger: logger)
        parts.append(text)
        var visited: Set<String> = [res.url]
        if nexts.count == 1 {
            var next = nexts[0]
            var n = 0
            while !next.isEmpty && !visited.contains(next) && n < 100 {
                if let nc = nextChapterUrl, Util.absoluteURL(res.url, next) == Util.absoluteURL(res.url, nc) { break }
                visited.insert(next); n += 1
                let au2 = AnalyzeUrl(next, source: source, book: book, engine: engine)
                guard let r2 = try? au2.fetch() else { break }
                (text, nexts) = parseContentPage(source, book: book, chapter: chapter, body: r2.body, baseUrl: r2.url,
                                                 rule: rule, nextChapterUrl: nextChapterUrl, logger: nil)
                parts.append(text)
                next = nexts.first ?? ""
            }
        } else if nexts.count > 1 {
            var pages = [String](repeating: "", count: nexts.count)
            let g = DispatchGroup()
            for (i, u) in nexts.enumerated() {
                g.enter()
                DispatchQueue.global().async {
                    defer { g.leave() }
                    if let r = try? AnalyzeUrl(u, source: source, book: book).fetch() {
                        pages[i] = parseContentPage(source, book: book, chapter: chapter, body: r.body, baseUrl: r.url,
                                                    rule: rule, nextChapterUrl: nextChapterUrl, logger: nil, getNext: false).0
                    }
                }
            }
            g.wait()
            parts += pages
        }
        var content = parts.filter { !$0.isEmpty }.joined(separator: "\n")
        // 替换净化规则
        if let rr = rule.replaceRegex, !rr.isEmpty {
            let e = RuleEngine(source: source, book: book)
            e.chapter = chapter
            e.setContent(content, baseUrl: res.url)
            content = e.getString(rr, content: content)
        }
        // 去掉正文开头重复的章节名
        let lines = content.components(separatedBy: "\n")
        if let first = lines.first?.trimmingCharacters(in: CharacterSet(charactersIn: " 　\t")),
           !first.isEmpty, first == chapter.title.trimmingCharacters(in: .whitespaces) {
            content = lines.dropFirst().joined(separator: "\n")
        }
        return content
    }

    private static func parseContentPage(_ source: BookSource, book: Book, chapter: BookChapter, body: String, baseUrl: String,
                                         rule: ContentRule, nextChapterUrl: String?, logger: DebugLog?, getNext: Bool = true) -> (String, [String]) {
        let engine = RuleEngine(source: source, book: book, logger: logger)
        engine.chapter = chapter
        engine.nextChapterUrl = nextChapterUrl
        engine.setContent(body, baseUrl: baseUrl)
        engine.setRedirectUrl(baseUrl)
        var content = engine.getString(rule.content, unescape: false)
        content = Util.formatContent(content)
        var nexts: [String] = []
        if getNext, let n = rule.nextContentUrl, !n.isEmpty {
            nexts = (engine.getStringList(n, isUrl: true) ?? []).filter { !$0.isEmpty && $0 != baseUrl }
        }
        logger?.log("┌正文长度：\(content.count)  下一页：\(nexts.first ?? "无")")
        return (content, nexts)
    }
}

/// 详情页 = 目录页时，暂存 HTML，避免重复请求
final class TocCache {
    static let shared = TocCache()
    private var map: [String: String] = [:]
    private let lock = NSLock()
    func put(_ k: String, _ v: String) { lock.lock(); map[k] = v; lock.unlock() }
    func take(_ k: String) -> String? { lock.lock(); defer { lock.unlock() }; return map.removeValue(forKey: k) }
}
