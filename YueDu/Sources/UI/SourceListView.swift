import SwiftUI
import UniformTypeIdentifiers

struct SourceListView: View {
    @EnvironmentObject var store: Store
    @State private var filter = ""
    @State private var showImportURL = false
    @State private var importURL = ""
    @State private var showFile = false
    @State private var message: String?
    @State private var importing = false
    @State private var confirmDeleteAll = false
    @State private var shareURL: URL?
    @State private var loginSource: BookSource?

    private var list: [BookSource] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        let all = store.sources.sorted { ($0.customOrder ?? 0) < ($1.customOrder ?? 0) }
        if f.isEmpty { return all }
        return all.filter { $0.bookSourceName.contains(f) || $0.bookSourceUrl.contains(f) || ($0.bookSourceGroup ?? "").contains(f) }
    }

    var body: some View {
        NavigationView {
            List {
                if store.sources.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("还没有书源").font(.headline)
                            Text("点右上角 ＋ 导入。支持「阅读 / Legado 3.x」格式的书源：\n• 网络导入：粘贴书源订阅链接\n• 剪贴板导入：复制书源 JSON 后点导入\n• 文件导入：选择 .json / .txt 文件")
                                .font(.footnote).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                } else {
                    Section(header: Text("共 \(store.sources.count) 个，启用 \(store.sources.filter { $0.isEnabled }.count) 个")) {
                        ForEach(list) { s in
                            NavigationLink { SourceDebugView(source: s) } label: { row(s) }
                                .swipeActions(edge: .trailing) {
                                    if s.hasLogin {
                                        Button("登录") { loginSource = s }.tint(.blue)
                                    }
                                    Button(s.isEnabled ? "停用" : "启用") { store.toggleSource(s) }.tint(s.isEnabled ? .gray : .green)
                                }
                                .contextMenu {
                                    Button { loginSource = s } label: { Label("登录", systemImage: "person.crop.circle") }
                                }
                                .swipeActions(edge: .leading) {
                                    Button(s.isEnabled ? "停用" : "启用") { store.toggleSource(s) }.tint(s.isEnabled ? .gray : .green)
                                }
                        }
                        .onDelete { store.deleteSources(at: $0, in: list) }
                    }
                }
            }
            .searchable(text: $filter, prompt: "筛选书源")
            .navigationTitle("书源")
            .overlay { if importing { ProgressView("正在导入…").padding().background(.regularMaterial).cornerRadius(10) } }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { showImportURL = true } label: { Label("网络导入", systemImage: "link") }
                        Button { importFromClipboard() } label: { Label("剪贴板导入", systemImage: "doc.on.clipboard") }
                        Button { showFile = true } label: { Label("文件导入", systemImage: "folder") }
                        Divider()
                        Button { shareURL = store.exportSources() } label: { Label("导出全部", systemImage: "square.and.arrow.up") }
                            .disabled(store.sources.isEmpty)
                        Button(role: .destructive) { confirmDeleteAll = true } label: { Label("删除全部", systemImage: "trash") }
                            .disabled(store.sources.isEmpty)
                    } label: { Image(systemName: "plus.circle") }
                }
            }
            .alert("网络导入", isPresented: $showImportURL) {
                TextField("https://…", text: $importURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("导入") { importFromURL(importURL) }
                Button("取消", role: .cancel) {}
            } message: { Text("粘贴书源 JSON 的网址") }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好") {}
            }
            .confirmationDialog("确定删除全部书源？", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("删除全部", role: .destructive) { store.deleteAllSources() }
            }
            .fileImporter(isPresented: $showFile, allowedContentTypes: [.json, .plainText, .data]) { r in
                if case .success(let url) = r { importFromFile(url) }
            }
            .sheet(item: $shareURL) { u in ShareSheet(items: [u]) }
            .sheet(item: $loginSource) { src in SourceLoginView(source: src) }
        }
        .navigationViewStyle(.stack)
        .onOpenURL { url in handleOpenURL(url) }
    }

    private func row(_ s: BookSource) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(s.bookSourceName).foregroundColor(s.isEnabled ? .primary : .secondary)
                Text(s.bookSourceUrl).font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            if let g = s.bookSourceGroup, !g.isEmpty {
                Text(g).font(.caption2).foregroundColor(.secondary).lineLimit(1).frame(maxWidth: 90, alignment: .trailing)
            }
            if s.hasLogin {
                Image(systemName: LoginStore.isLoggedIn(s.bookSourceUrl) ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                    .foregroundColor(LoginStore.isLoggedIn(s.bookSourceUrl) ? .green : .blue)
            }
            if !s.isEnabled { Image(systemName: "pause.circle").foregroundColor(.secondary) }
        }
    }

    // MARK: 导入

    private func done(_ r: ImportReport) {
        let (a, u) = store.importSources(r.sources)
        var m = "导入完成：新增 \(a) 个，更新 \(u) 个"
        if !r.skipped.isEmpty {
            m += "\n跳过 \(r.skipped.count) 个无效条目"
            m += "\n" + r.skipped.prefix(3).joined(separator: "\n")
        }
        message = m
    }

    private func importText(_ text: String) {
        let t = BookSourceImporter.text(from: Data(text.utf8))
        if let u = BookSourceImporter.extractURL(t) { importFromURL(u); return }
        do { done(try BookSourceImporter.parseReport(t)) }
        catch { message = "解析失败：\(error.localizedDescription)" }
    }

    private func importFromClipboard() {
        guard let s = UIPasteboard.general.string, !s.isEmpty else {
            if UIPasteboard.general.hasURLs, let u = UIPasteboard.general.url { importFromURL(u.absoluteString); return }
            message = "剪贴板是空的"; return
        }
        importText(s)
    }

    private func importFromURL(_ raw: String) {
        let u = BookSourceImporter.extractURL(raw) ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard u.lowercased().hasPrefix("http") else { message = "这不是网址：\(BookSourceImporter.preview(raw))"; return }
        importing = true
        Task {
            defer { importing = false }
            do {
                let r = try await runInBackground {
                    try HTTP.request(url: u, headers: ["User-Agent": BookSource.defaultUA, "Accept": "application/json,text/plain,*/*"], retry: 2)
                }
                guard (200..<400).contains(r.code) else { throw YueDuError.message("网站返回 \(r.code)") }
                let text = BookSourceImporter.text(from: r.data)
                if text.lowercased().hasPrefix("<!doctype") || text.lowercased().hasPrefix("<html") {
                    throw YueDuError.message("这个链接打开的是网页，不是书源 JSON。请找「原始数据 / raw」链接")
                }
                done(try BookSourceImporter.parseReport(text))
            } catch {
                message = "导入失败：\(error.localizedDescription)"
            }
        }
    }

    private func importFromFile(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let d = try? Data(contentsOf: url) else { message = "读取文件失败"; return }
        do { done(try BookSourceImporter.parseReport(BookSourceImporter.text(from: d))) }
        catch { message = "解析失败：\(error.localizedDescription)" }
    }

    /// 支持 yuedu://import?src=URL 和 legado://import/bookSource?src=URL
    private func handleOpenURL(_ url: URL) {
        if url.isFileURL { importFromFile(url); return }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let src = comps.queryItems?.first(where: { $0.name == "src" })?.value else { return }
        importFromURL(src)
    }
}

extension URL: Identifiable { public var id: String { absoluteString } }

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// 书源调试：一步步看 搜索 → 详情 → 目录 → 正文 每一步的结果，方便定位哪条规则出问题
struct SourceDebugView: View {
    @EnvironmentObject var store: Store
    let source: BookSource
    @StateObject private var log = DebugLog()
    @State private var key = "我的"
    @State private var running = false
    @State private var showJSON = false
    @State private var showLogin = false

    var body: some View {
        List {
            Section("书源信息") {
                LabeledRow("名称", source.bookSourceName)
                LabeledRow("地址", source.bookSourceUrl)
                if let g = source.bookSourceGroup, !g.isEmpty { LabeledRow("分组", g) }
                if let c = source.bookSourceComment, !c.isEmpty { Text(c).font(.caption).foregroundColor(.secondary) }
                Toggle("启用", isOn: Binding(get: { source.isEnabled }, set: { _ in store.toggleSource(source) }))
                Button("查看书源 JSON") { showJSON = true }
            }
            Section(header: Text("登录"), footer: Text(source.hasLogin ? "" : "这个书源没有填写登录地址（loginUrl），一般不需要登录。如果网站确实要登录，也可以用网页登录试试。")) {
                Button { showLogin = true } label: {
                    Label(LoginStore.isLoggedIn(source.bookSourceUrl) ? "已登录（点此管理）" : "登录此书源", systemImage: "person.crop.circle")
                }
            }
            Section("调试") {
                HStack {
                    TextField("搜索关键字", text: $key).textFieldStyle(.roundedBorder)
                    Button(running ? "运行中…" : "开始") { run() }.disabled(running || key.isEmpty)
                }
                Text("会依次执行：搜索 → 第一本书的详情 → 目录 → 第一章正文").font(.caption).foregroundColor(.secondary)
            }
            if !log.lines.isEmpty {
                Section("日志") {
                    ForEach(Array(log.lines.enumerated()), id: \.offset) { _, l in
                        Text(l).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
        }
        .sheet(isPresented: $showLogin) { SourceLoginView(source: source) }
        .navigationTitle("书源调试")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showJSON) {
            NavigationView {
                ScrollView {
                    Text(prettyJSON).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding()
                }
                .navigationTitle("书源 JSON").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    Button("复制") { UIPasteboard.general.string = prettyJSON }
                }
            }
        }
    }

    private var prettyJSON: String {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        return (try? e.encode(source)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private func run() {
        log.lines = []
        running = true
        let src = source, k = key, logger = log
        Task {
            defer { running = false }
            do {
                logger.log("━━ 1. 搜索「\(k)」")
                let books = try await runInBackground { try WebBook.search(src, key: k, logger: logger) }
                logger.log("✓ 搜到 \(books.count) 本")
                guard var b = books.first else { logger.log("✗ 没有结果，检查搜索地址和列表规则"); return }
                logger.log("━━ 2. 详情页")
                b = try await runInBackground { var x = b; try WebBook.getBookInfo(src, book: &x, logger: logger); return x }
                logger.log("━━ 3. 目录")
                let bb = b
                let chapters = try await runInBackground { try WebBook.getChapterList(src, book: bb, logger: logger) }
                guard let first = chapters.first(where: { !$0.isVolume }) ?? chapters.first else { return }
                logger.log("━━ 4. 正文：\(first.title)")
                let next = chapters.count > first.index + 1 ? chapters[first.index + 1].url : nil
                let text = try await runInBackground { try WebBook.getContent(src, book: bb, chapter: first, nextChapterUrl: next, logger: logger) }
                logger.log("✓ 正文前 300 字：\n" + String(text.prefix(300)))
                logger.log("━━ 全部完成 ✓")
            } catch {
                logger.log("✗ 出错：\(error.localizedDescription)")
            }
        }
    }
}

struct LabeledRow: View {
    let k: String, v: String
    init(_ k: String, _ v: String) { self.k = k; self.v = v }
    var body: some View {
        HStack(alignment: .top) {
            Text(k).foregroundColor(.secondary)
            Spacer()
            Text(v).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.subheadline)
    }
}
