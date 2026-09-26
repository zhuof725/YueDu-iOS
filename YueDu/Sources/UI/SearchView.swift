import SwiftUI

/// 多书源并发搜索
@MainActor
final class SearchModel: ObservableObject {
    @Published var results: [SearchGroup] = []
    @Published var searching = false
    @Published var progress = (done: 0, total: 0)
    @Published var failed: [String] = []
    private var task: Task<Void, Never>?

    /// 同名同作者的结果合并成一组（可换源）
    struct SearchGroup: Identifiable {
        var id: String { name + "|" + author }
        var name: String
        var author: String
        var books: [Book]
        var first: Book { books[0] }
    }

    func search(_ key: String, sources: [BookSource]) {
        cancel()
        let key = key.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        results = []
        failed = []
        searching = true
        progress = (0, sources.count)
        task = Task {
            await withTaskGroup(of: (BookSource, [Book]?).self) { group in
                var it = sources.makeIterator()
                // 最多同时 8 个书源
                for _ in 0..<8 {
                    if let s = it.next() { group.addTask { await Self.searchOne(s, key) } }
                }
                for await (src, books) in group {
                    if Task.isCancelled { break }
                    progress.done += 1
                    if let books = books { merge(books, key: key) } else { failed.append(src.bookSourceName) }
                    if let s = it.next() { group.addTask { await Self.searchOne(s, key) } }
                }
            }
            searching = false
        }
    }

    nonisolated private static func searchOne(_ s: BookSource, _ key: String) async -> (BookSource, [Book]?) {
        do {
            let books = try await withTimeout(30) {
                try await runInBackground { try WebBook.search(s, key: key) }
            }
            return (s, books)
        } catch {
            return (s, nil)
        }
    }

    private func merge(_ books: [Book], key: String) {
        for b in books {
            if let i = results.firstIndex(where: { $0.name == b.name && ($0.author == b.author || $0.author.isEmpty || b.author.isEmpty) }) {
                if !results[i].books.contains(where: { $0.origin == b.origin }) { results[i].books.append(b) }
            } else {
                results.append(SearchGroup(name: b.name, author: b.author, books: [b]))
            }
        }
        // 排序：完全匹配 > 包含 > 其他；同级按书源数量
        results.sort { a, b in
            func score(_ g: SearchGroup) -> Int {
                if g.name == key || g.author == key { return 3 }
                if g.name.contains(key) || g.author.contains(key) { return 2 }
                return 1
            }
            let sa = score(a), sb = score(b)
            return sa != sb ? sa > sb : a.books.count > b.books.count
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        searching = false
    }
}

struct TimeoutError: Error {}

func withTimeout<T>(_ seconds: Double, _ op: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { g in
        g.addTask { try await op() }
        g.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        let r = try await g.next()!
        g.cancelAll()
        return r
    }
}

struct SearchView: View {
    @EnvironmentObject var store: Store
    @StateObject private var model = SearchModel()
    @State private var key = ""
    @State private var group = "全部"
    @AppStorage("searchHistory") private var historyRaw = ""

    private var history: [String] { historyRaw.split(separator: "\n").map(String.init) }

    private var groups: [String] {
        var gs = Set<String>()
        for s in store.enabledSources {
            for g in (s.bookSourceGroup ?? "").split(whereSeparator: { ",，;；".contains($0) }) {
                gs.insert(g.trimmingCharacters(in: .whitespaces))
            }
        }
        return ["全部"] + gs.filter { !$0.isEmpty }.sorted()
    }

    private var targetSources: [BookSource] {
        let all = store.enabledSources
        if group == "全部" { return all }
        return all.filter { ($0.bookSourceGroup ?? "").contains(group) }
    }

    var body: some View {
        NavigationView {
            List {
                if model.searching || model.progress.total > 0 {
                    Section {
                        HStack {
                            if model.searching { ProgressView().padding(.trailing, 4) }
                            Text(model.searching ? "正在搜索 \(model.progress.done)/\(model.progress.total) 个书源"
                                                 : "搜索完成，找到 \(model.results.count) 本")
                                .font(.footnote).foregroundColor(.secondary)
                            Spacer()
                            if model.searching { Button("停止") { model.cancel() }.font(.footnote) }
                        }
                        if !model.searching && !model.failed.isEmpty {
                            Text("\(model.failed.count) 个书源失败或超时").font(.caption).foregroundColor(.orange)
                        }
                    }
                }
                if model.results.isEmpty && !model.searching {
                    if store.enabledSources.isEmpty {
                        Section {
                            Text("还没有可用书源，请先到「书源」页导入。").foregroundColor(.secondary)
                        }
                    } else if !history.isEmpty {
                        Section(header: HStack {
                            Text("搜索历史")
                            Spacer()
                            Button("清空") { historyRaw = "" }.font(.caption)
                        }) {
                            ForEach(history, id: \.self) { h in
                                Button(h) { key = h; doSearch() }
                            }
                        }
                    }
                }
                ForEach(model.results) { g in
                    NavigationLink { BookDetailView(book: g.first, alternatives: g.books) } label: { row(g) }
                }
            }
            .listStyle(.plain)
            .navigationTitle("搜索")
            .searchable(text: $key, placement: .navigationBarDrawer(displayMode: .always), prompt: "书名或作者")
            .onSubmit(of: .search) { doSearch() }
            .toolbar {
                if groups.count > 1 {
                    Menu {
                        Picker("分组", selection: $group) { ForEach(groups, id: \.self) { Text($0) } }
                    } label: { Label(group, systemImage: "line.3.horizontal.decrease.circle") }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func doSearch() {
        let k = key.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return }
        var h = history.filter { $0 != k }
        h.insert(k, at: 0)
        historyRaw = h.prefix(20).joined(separator: "\n")
        model.search(k, sources: targetSources)
    }

    private func row(_ g: SearchModel.SearchGroup) -> some View {
        HStack(alignment: .top, spacing: 12) {
            CoverView(url: g.books.first(where: { $0.coverUrl?.isEmpty == false })?.coverUrl, name: g.name)
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(g.name).font(.headline).lineLimit(1)
                    Spacer()
                    Text("\(g.books.count)源").font(.caption2).foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.8)))
                }
                Text(g.author.isEmpty ? "未知作者" : g.author).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                if let k = g.first.kind, !k.isEmpty { Text(k).font(.caption).foregroundColor(.secondary).lineLimit(1) }
                if let l = g.books.first(where: { $0.latestChapterTitle?.isEmpty == false })?.latestChapterTitle {
                    Text("最新：\(l)").font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                if let i = g.first.intro, !i.isEmpty {
                    Text(i.trimmingCharacters(in: .whitespacesAndNewlines)).font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
