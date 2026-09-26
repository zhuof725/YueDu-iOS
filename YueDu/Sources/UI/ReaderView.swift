import SwiftUI

@MainActor
final class ReaderModel: ObservableObject {
    @Published var book: Book
    @Published var chapters: [BookChapter] = []
    @Published var index: Int
    @Published var text = ""
    @Published var loading = false
    @Published var error: String?
    /// 每次换章 +1，驱动视图滚回顶部
    @Published var chapterToken = 0

    let source: BookSource?
    private var memo: [Int: String] = [:]

    init(book: Book) {
        self.book = book
        self.index = book.durChapterIndex
        self.source = Store.shared.source(for: book.origin)
    }

    var chapter: BookChapter? { chapters.indices.contains(index) ? chapters[index] : nil }
    var title: String { chapter?.title ?? book.name }

    func start() async {
        if let cached = Store.shared.loadToc(book), !cached.isEmpty {
            chapters = cached
        }
        if chapters.isEmpty {
            await reloadToc()
        }
        if chapters.isEmpty { return }
        index = min(max(0, index), chapters.count - 1)
        await loadChapter(index, restorePos: true)
    }

    func reloadToc() async {
        guard let src = source else { error = "找不到书源「\(book.originName)」，可能已被删除"; return }
        loading = true
        defer { loading = false }
        let b = book
        do {
            let list = try await runInBackground { () -> [BookChapter] in
                var nb = b
                if nb.tocUrl == nil { try WebBook.getBookInfo(src, book: &nb) }
                return try WebBook.getChapterList(src, book: nb)
            }
            chapters = list
            Store.shared.saveToc(book, list)
            book.totalChapterNum = list.count
            book.latestChapterTitle = list.last?.title
            Store.shared.updateBook(book)
        } catch {
            self.error = "目录加载失败：\(error.localizedDescription)"
        }
    }

    private func fetch(_ i: Int) async throws -> String {
        if let t = memo[i] { return t }
        let c = chapters[i]
        if let t = Store.shared.loadContent(book, c), !t.isEmpty { memo[i] = t; return t }
        guard let src = source else { throw YueDuError.message("找不到书源") }
        let b = book
        let next = chapters.indices.contains(i + 1) ? chapters[i + 1].url : nil
        let t = try await runInBackground { try WebBook.getContent(src, book: b, chapter: c, nextChapterUrl: next) }
        if !t.isEmpty {
            Store.shared.saveContent(b, c, t)
            memo[i] = t
        }
        return t
    }

    func loadChapter(_ i: Int, restorePos: Bool = false) async {
        guard chapters.indices.contains(i) else { return }
        index = i
        error = nil
        loading = true
        if !restorePos { book.durChapterPos = 0 }
        do {
            let t = try await fetch(i)
            text = t.isEmpty ? "（本章没有内容，可能是书源规则不兼容或需要登录）" : t
        } catch {
            text = ""
            self.error = error.localizedDescription
        }
        loading = false
        chapterToken += 1
        saveProgress()
        // 预加载后面 3 章
        let upcoming: [Int] = i + 1 < chapters.count ? Array((i + 1)...min(i + 3, chapters.count - 1)) : []
        Task { for j in upcoming { _ = try? await fetch(j) } }
        // 内存里只留附近的章节
        memo = memo.filter { abs($0.key - i) <= 4 }
    }

    func next() async { if index + 1 < chapters.count { await loadChapter(index + 1) } }
    func prev() async { if index > 0 { await loadChapter(index - 1) } }

    func saveProgress(pos: Int? = nil) {
        if let p = pos { book.durChapterPos = p }
        book.durChapterIndex = index
        book.durChapterTitle = chapter?.title
        book.totalChapterNum = chapters.count
        book.lastReadTime = Date().timeIntervalSince1970
        if Store.shared.isOnShelf(book) { Store.shared.updateBook(book) }
    }

    func refreshCurrent() async {
        guard let c = chapter else { return }
        memo[index] = nil
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("content/\(Util.md5(book.bookUrl))/\(Util.md5(c.url)).txt")
        try? FileManager.default.removeItem(at: url)
        await loadChapter(index)
    }

    /// 段落（用于渲染）
    var paragraphs: [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " 　\t\r")) }
            .filter { !$0.isEmpty }
    }
}

struct ReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var settings: ReadSettings
    @StateObject private var model: ReaderModel
    @State private var showMenu = false
    @State private var showToc = false
    @State private var showSettings = false

    init(book: Book) {
        _model = StateObject(wrappedValue: ReaderModel(book: book))
    }

    var theme: ReadSettings.Theme { settings.currentTheme }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            content
            if showMenu { menuOverlay }
        }
        .statusBarHidden(!showMenu)
        .preferredColorScheme(settings.theme == 4 ? .dark : nil)
        .task { await model.start() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model.saveProgress()
        }
        .sheet(isPresented: $showToc) { tocSheet }
        .sheet(isPresented: $showSettings) {
            ReadSettingsSheet().environmentObject(settings)
                .presentationDetentsIfAvailable()
        }
    }

    // MARK: 正文

    @ViewBuilder private var content: some View {
        if model.chapters.isEmpty && model.loading {
            VStack(spacing: 12) { ProgressView(); Text("正在加载目录…").foregroundColor(theme.fg.opacity(0.6)) }
        } else if let e = model.error, model.text.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(.orange)
                Text(e).foregroundColor(theme.fg).multilineTextAlignment(.center).padding(.horizontal)
                HStack {
                    Button("重试") { Task { model.chapters.isEmpty ? await model.start() : await model.refreshCurrent() } }
                        .buttonStyle(.borderedProminent)
                    Button("返回") { dismiss() }.buttonStyle(.bordered)
                }
            }
            .padding()
        } else if settings.pageMode == 1 {
            PagedTextView(model: model, showMenu: $showMenu)
        } else {
            scrollContent
        }
    }

    private var scrollContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: settings.paragraphSpacing) {
                    Color.clear.frame(height: 1).id("top")
                    Text(model.title)
                        .font(.system(size: settings.fontSize + 5, weight: .bold))
                        .foregroundColor(theme.fg)
                        .padding(.top, 30).padding(.bottom, 12)
                    if model.loading && model.text.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                    }
                    ForEach(Array(model.paragraphs.enumerated()), id: \.offset) { i, p in
                        Text("　　" + p)
                            .font(.system(size: settings.fontSize))
                            .lineSpacing(settings.lineSpacing)
                            .foregroundColor(theme.fg)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                            .onAppear { if i % 5 == 0 { model.book.durChapterPos = i } }
                    }
                    chapterFooter
                }
                .padding(.horizontal, settings.horizontalPadding)
                .padding(.bottom, 40)
                .textSelection(.enabled)
            }
            .onChange(of: model.chapterToken) { _ in
                let pos = model.book.durChapterPos
                if pos > 0 && pos < model.paragraphs.count {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { proxy.scrollTo(pos, anchor: .top) }
                } else {
                    proxy.scrollTo("top", anchor: .top)
                }
            }
            .simultaneousGesture(TapGesture().onEnded { withAnimation(.easeInOut(duration: 0.2)) { showMenu.toggle() } })
        }
    }

    private var chapterFooter: some View {
        HStack(spacing: 16) {
            Button { Task { await model.prev() } } label: { Label("上一章", systemImage: "chevron.left") }
                .disabled(model.index == 0)
            Spacer()
            Text("\(model.index + 1)/\(model.chapters.count)").font(.caption).foregroundColor(theme.fg.opacity(0.5))
            Spacer()
            Button { Task { await model.next() } } label: { Label("下一章", systemImage: "chevron.right") }
                .disabled(model.index + 1 >= model.chapters.count)
        }
        .buttonStyle(.bordered)
        .tint(theme.fg.opacity(0.7))
        .padding(.top, 30)
    }

    // MARK: 菜单

    private var menuOverlay: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.saveProgress(); dismiss() } label: { Image(systemName: "chevron.left").font(.title3) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.book.name).font(.headline).lineLimit(1)
                    Text(model.title).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer()
                Menu {
                    Button { Task { await model.refreshCurrent() } } label: { Label("刷新本章", systemImage: "arrow.clockwise") }
                    Button { Task { await model.reloadToc() } } label: { Label("更新目录", systemImage: "list.bullet") }
                    Text("来源：\(model.book.originName)")
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
            }
            .padding()
            .background(.regularMaterial)

            Color.clear.contentShape(Rectangle())
                .onTapGesture { withAnimation { showMenu = false } }

            VStack(spacing: 14) {
                HStack {
                    Button("上一章") { Task { await model.prev() } }.disabled(model.index == 0)
                    Slider(value: Binding(
                        get: { Double(model.index) },
                        set: { v in let i = Int(v.rounded()); if i != model.index { Task { await model.loadChapter(i) } } }
                    ), in: 0...Double(max(model.chapters.count - 1, 1)), step: 1)
                    Button("下一章") { Task { await model.next() } }.disabled(model.index + 1 >= model.chapters.count)
                }
                .font(.footnote)
                HStack {
                    menuButton("目录", "list.bullet") { showToc = true }
                    menuButton(settings.theme == 4 ? "日间" : "夜间", settings.theme == 4 ? "sun.max" : "moon") {
                        settings.theme = settings.theme == 4 ? 0 : 4
                    }
                    menuButton(settings.pageMode == 0 ? "翻页模式" : "滚动模式", settings.pageMode == 0 ? "book" : "scroll") {
                        settings.pageMode = settings.pageMode == 0 ? 1 : 0
                        model.chapterToken += 1
                    }
                    menuButton("设置", "textformat.size") { showSettings = true }
                }
            }
            .padding()
            .background(.regularMaterial)
        }
        .transition(.opacity)
    }

    private func menuButton(_ t: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(t).font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .foregroundColor(.primary)
    }

    private var tocSheet: some View {
        NavigationView {
            ScrollViewReader { proxy in
                List(model.chapters) { c in
                    Button {
                        showToc = false; showMenu = false
                        Task { await model.loadChapter(c.index) }
                    } label: {
                        HStack {
                            Text(c.title)
                                .foregroundColor(c.index == model.index ? .accentColor : (c.isVolume ? .secondary : .primary))
                                .font(c.isVolume ? .subheadline.bold() : .body)
                            Spacer()
                            if Store.shared.loadContent(model.book, c) != nil {
                                Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundColor(.green.opacity(0.6))
                            }
                        }
                    }
                    .id(c.index)
                }
                .listStyle(.plain)
                .onAppear { proxy.scrollTo(model.index, anchor: .center) }
            }
            .navigationTitle("目录（\(model.chapters.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("关闭") { showToc = false } }
        }
    }
}

extension View {
    @ViewBuilder func presentationDetentsIfAvailable() -> some View {
        if #available(iOS 16.0, *) { self.presentationDetents([.medium, .large]) } else { self }
    }
}

/// 阅读设置面板
struct ReadSettingsSheet: View {
    @EnvironmentObject var s: ReadSettings
    var body: some View {
        NavigationView {
            Form {
                Section("字号 \(Int(s.fontSize))") {
                    HStack {
                        Button("A-") { s.fontSize = max(12, s.fontSize - 1) }.buttonStyle(.bordered)
                        Slider(value: $s.fontSize, in: 12...36, step: 1)
                        Button("A+") { s.fontSize = min(36, s.fontSize + 1) }.buttonStyle(.bordered)
                    }
                }
                Section("间距") {
                    VStack(alignment: .leading) {
                        Text("行距 \(Int(s.lineSpacing))").font(.caption)
                        Slider(value: $s.lineSpacing, in: 0...30, step: 1)
                    }
                    VStack(alignment: .leading) {
                        Text("段距 \(Int(s.paragraphSpacing))").font(.caption)
                        Slider(value: $s.paragraphSpacing, in: 0...40, step: 1)
                    }
                    VStack(alignment: .leading) {
                        Text("左右边距 \(Int(s.horizontalPadding))").font(.caption)
                        Slider(value: $s.horizontalPadding, in: 4...48, step: 1)
                    }
                }
                Section("背景") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(ReadSettings.themes.indices, id: \.self) { i in
                                let t = ReadSettings.themes[i]
                                VStack(spacing: 4) {
                                    Circle().fill(t.bg).frame(width: 40, height: 40)
                                        .overlay(Text("文").foregroundColor(t.fg))
                                        .overlay(Circle().stroke(s.theme == i ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: s.theme == i ? 3 : 1))
                                    Text(t.name).font(.caption2)
                                }
                                .onTapGesture { s.theme = i }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section {
                    Picker("翻页方式", selection: $s.pageMode) {
                        Text("上下滚动").tag(0)
                        Text("左右翻页").tag(1)
                    }
                    Toggle("阅读时屏幕常亮", isOn: $s.keepScreenOn)
                }
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
