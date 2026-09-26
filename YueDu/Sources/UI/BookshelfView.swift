import SwiftUI

struct BookshelfView: View {
    @EnvironmentObject var store: Store
    @State private var reading: Book?
    @State private var refreshing = false
    @State private var updates: [String: Int] = [:]   // 书 → 新章节数

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 16)]

    var body: some View {
        NavigationView {
            Group {
                if store.shelf.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "books.vertical").font(.system(size: 56)).foregroundColor(.secondary)
                        Text("书架还是空的").font(.headline)
                        Text("先到「书源」页导入书源，\n再到「搜索」页找书加入书架")
                            .font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(store.sortedShelf) { book in
                                Button { reading = book } label: { shelfItem(book) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        NavigationLink { BookDetailView(book: book) } label: {
                                            Label("书籍详情", systemImage: "info.circle")
                                        }
                                        Button { Store.shared.clearContentCache(book) } label: {
                                            Label("清除缓存", systemImage: "trash.slash")
                                        }
                                        Button(role: .destructive) { store.removeFromShelf(book) } label: {
                                            Label("移出书架", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        .padding()
                    }
                    .refreshable { await refreshAll() }
                }
            }
            .navigationTitle("书架")
            .toolbar {
                if refreshing { ProgressView() }
            }
        }
        .navigationViewStyle(.stack)
        .fullScreenCover(item: $reading) { book in
            ReaderView(book: book)
        }
    }

    private func shelfItem(_ book: Book) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topTrailing) {
                CoverView(url: book.coverUrl, name: book.name)
                if let n = updates[book.bookUrl], n > 0 {
                    Text("\(n)").font(.caption2.bold()).foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.red)).offset(x: 4, y: -4)
                }
            }
            Text(book.name).font(.footnote.weight(.medium)).lineLimit(1)
            Text(progressText(book)).font(.caption2).foregroundColor(.secondary).lineLimit(1)
        }
    }

    private func progressText(_ b: Book) -> String {
        if b.lastReadTime == 0 { return "未读" }
        if b.totalChapterNum > 0 {
            return "\(b.durChapterIndex + 1)/\(b.totalChapterNum)章"
        }
        return b.durChapterTitle ?? ""
    }

    /// 下拉刷新：更新每本书的目录
    private func refreshAll() async {
        refreshing = true
        defer { refreshing = false }
        await withTaskGroup(of: (Book, [BookChapter]?).self) { group in
            for book in store.shelf {
                guard let src = store.source(for: book.origin) else { continue }
                group.addTask {
                    let list = try? await runInBackground { try WebBook.getChapterList(src, book: book) }
                    return (book, list)
                }
            }
            for await (book, list) in group {
                guard let list = list, !list.isEmpty else { continue }
                let old = Store.shared.loadToc(book)?.count ?? book.totalChapterNum
                Store.shared.saveToc(book, list)
                var b = book
                b.totalChapterNum = list.count
                b.latestChapterTitle = list.last?.title
                store.updateBook(b)
                if list.count > old { updates[book.bookUrl] = list.count - old }
            }
        }
    }
}
