import SwiftUI

struct BookDetailView: View {
    @EnvironmentObject var store: Store
    @State var book: Book
    var alternatives: [Book] = []

    @State private var chapters: [BookChapter] = []
    @State private var loading = false
    @State private var error: String?
    @State private var reading: Book?
    @State private var showToc = false
    @State private var showSources = false
    @State private var showLogin = false

    private var srcHasLogin: Bool { store.source(for: book.origin)?.hasLogin ?? false }

    init(book: Book, alternatives: [Book] = []) {
        _book = State(initialValue: book)
        self.alternatives = alternatives
    }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    CoverView(url: book.coverUrl, name: book.name).frame(width: 90)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(book.name).font(.title3.bold())
                        Text(book.author.isEmpty ? "未知作者" : book.author).foregroundColor(.secondary)
                        if let k = book.kind, !k.isEmpty { Text(k).font(.caption).foregroundColor(.secondary) }
                        if let w = book.wordCount, !w.isEmpty { Text(w).font(.caption).foregroundColor(.secondary) }
                        Text("来源：\(book.originName)").font(.caption).foregroundColor(.accentColor)
                    }
                }
                .padding(.vertical, 4)
            }

            if let intro = book.intro, !intro.isEmpty {
                Section("简介") {
                    Text(intro.trimmingCharacters(in: .whitespacesAndNewlines)).font(.callout)
                }
            }

            Section {
                if loading {
                    HStack { ProgressView(); Text("正在加载目录…").foregroundColor(.secondary) }
                } else if let e = error {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("加载失败").foregroundColor(.red)
                        Text(e).font(.caption).foregroundColor(.secondary)
                        Button("重试") { Task { await load() } }
                    }
                } else {
                    Button { showToc = true } label: {
                        HStack {
                            Text("目录")
                            Spacer()
                            Text("共 \(chapters.count) 章").foregroundColor(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .foregroundColor(.primary)
                    if let last = chapters.last {
                        HStack {
                            Text("最新章节")
                            Spacer()
                            Text(last.title).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                }
                if alternatives.count > 1 {
                    Button { showSources = true } label: {
                        HStack {
                            Text("换源")
                            Spacer()
                            Text("\(alternatives.count) 个来源").foregroundColor(.secondary)
                        }
                    }
                    .foregroundColor(.primary)
                }
            }
        }
        .navigationTitle(book.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button {
                    if store.isOnShelf(book) { store.removeFromShelf(book) } else { saveToShelf() }
                } label: {
                    Text(store.isOnShelf(book) ? "移出书架" : "加入书架").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    saveToShelf()
                    reading = store.shelf.first { $0.bookUrl == book.bookUrl } ?? book
                } label: {
                    Text(store.isOnShelf(book) && (store.shelf.first { $0.bookUrl == book.bookUrl }?.lastReadTime ?? 0) > 0 ? "继续阅读" : "开始阅读")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(chapters.isEmpty)
            }
            .padding()
            .background(.bar)
        }
        .sheet(isPresented: $showToc) {
            NavigationView {
                List(chapters) { c in
                    Button {
                        showToc = false
                        saveToShelf()
                        var b = store.shelf.first { $0.bookUrl == book.bookUrl } ?? book
                        b.durChapterIndex = c.index; b.durChapterPos = 0
                        store.updateBook(b)
                        reading = b
                    } label: {
                        Text(c.title).foregroundColor(c.isVolume ? .secondary : .primary)
                            .font(c.isVolume ? .subheadline.bold() : .body)
                    }
                }
                .listStyle(.plain)
                .navigationTitle("目录（\(chapters.count)）")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("关闭") { showToc = false } }
            }
        }
        .confirmationDialog("选择来源", isPresented: $showSources) {
            ForEach(alternatives) { alt in
                Button(alt.originName + (alt.origin == book.origin ? " ✓" : "")) {
                    book = alt
                    Task { await load() }
                }
            }
        }
        .fullScreenCover(item: $reading) { b in ReaderView(book: b) }
        .sheet(item: Binding(get: { showLogin ? book : nil }, set: { if $0 == nil { showLogin = false } })) { bk in
            if let src = store.source(for: bk.origin) {
                SourceLoginView(source: src, book: bk)
            }
        }
        .task { await load() }
    }

    private func saveToShelf() {
        var b = store.shelf.first { $0.bookUrl == book.bookUrl } ?? book
        b.name = book.name; b.author = book.author
        b.coverUrl = book.coverUrl ?? b.coverUrl
        b.intro = book.intro; b.tocUrl = book.tocUrl; b.kind = book.kind
        b.totalChapterNum = chapters.count
        b.latestChapterTitle = chapters.last?.title
        store.addToShelf(b)
        if !chapters.isEmpty { store.saveToc(b, chapters) }
    }

    private func load() async {
        guard let src = store.source(for: book.origin) else {
            error = "找不到书源：\(book.originName)"; return
        }
        loading = true; error = nil
        defer { loading = false }
        let b = book
        do {
            let (nb, list) = try await runInBackground { () -> (Book, [BookChapter]) in
                var nb = b
                // 有目录地址时，也刷新一次详情拿简介封面；失败不影响
                if nb.tocUrl == nil || nb.intro == nil || nb.coverUrl == nil {
                    try WebBook.getBookInfo(src, book: &nb)
                }
                let list = try WebBook.getChapterList(src, book: nb)
                return (nb, list)
            }
            book = nb
            chapters = list
            if store.isOnShelf(nb) {
                store.saveToc(nb, list)
                if var s = store.shelf.first(where: { $0.bookUrl == nb.bookUrl }) {
                    s.totalChapterNum = list.count; s.latestChapterTitle = list.last?.title
                    s.tocUrl = nb.tocUrl; s.intro = nb.intro ?? s.intro; s.coverUrl = nb.coverUrl ?? s.coverUrl
                    store.updateBook(s)
                }
            }
        } catch {
            self.error = error.localizedDescription
            if let cached = store.loadToc(book), !cached.isEmpty { chapters = cached; self.error = nil }
        }
    }
}
