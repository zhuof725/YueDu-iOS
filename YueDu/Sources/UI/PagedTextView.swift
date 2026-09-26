import SwiftUI
import UIKit

/// 左右翻页模式：用 TextKit 按屏幕大小把正文分页
struct PagedTextView: View {
    @ObservedObject var model: ReaderModel
    @Binding var showMenu: Bool
    @EnvironmentObject var settings: ReadSettings
    @State private var pages: [NSAttributedString] = []
    @State private var page = 0
    @State private var size: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let theme = settings.currentTheme
            ZStack {
                if model.loading && model.text.isEmpty {
                    ProgressView()
                } else if pages.indices.contains(page) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.title).font(.caption).foregroundColor(theme.fg.opacity(0.5)).lineLimit(1)
                            .padding(.bottom, 6)
                        AttributedLabel(text: pages[page])
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        HStack {
                            Text("\(model.index + 1)/\(model.chapters.count)章")
                            Spacer()
                            Text("\(page + 1)/\(pages.count)")
                        }
                        .font(.caption2).foregroundColor(theme.fg.opacity(0.5))
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, settings.horizontalPadding)
                    .padding(.top, geo.safeAreaInsets.top + 8)
                    .padding(.bottom, max(geo.safeAreaInsets.bottom, 10))
                }
                // 点击区域：左 1/3 上一页，右 1/3 下一页，中间菜单
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { turn(-1) }
                    Color.clear.contentShape(Rectangle()).onTapGesture { withAnimation { showMenu.toggle() } }
                    Color.clear.contentShape(Rectangle()).onTapGesture { turn(1) }
                }
            }
            .ignoresSafeArea()
            .gesture(DragGesture(minimumDistance: 30).onEnded { v in
                if v.translation.width < -40 { turn(1) } else if v.translation.width > 40 { turn(-1) }
            })
            .onAppear { size = geo.size; paginate(geo) }
            .onChange(of: geo.size) { _ in size = geo.size; paginate(geo) }
            .onChange(of: model.chapterToken) { _ in paginate(geo, restore: true) }
            .onChange(of: settings.fontSize) { _ in paginate(geo) }
            .onChange(of: settings.lineSpacing) { _ in paginate(geo) }
            .onChange(of: settings.paragraphSpacing) { _ in paginate(geo) }
            .onChange(of: settings.horizontalPadding) { _ in paginate(geo) }
            .onChange(of: settings.theme) { _ in paginate(geo) }
        }
    }

    private var goingBack: Bool { model.book.durChapterPos == -1 }

    private func turn(_ d: Int) {
        if showMenu { withAnimation { showMenu = false }; return }
        let n = page + d
        if n < 0 {
            if model.index > 0 {
                model.book.durChapterPos = -1   // 标记：跳到上一章最后一页
                Task { await model.loadChapter(model.index - 1, restorePos: true) }
            }
        } else if n >= pages.count {
            if model.index + 1 < model.chapters.count { Task { await model.next() } }
        } else {
            page = n
            model.saveProgress(pos: pageStartParagraph(n))
        }
    }

    /// 页首大致对应的段落号（用来和滚动模式共享进度）
    @State private var pageParagraphs: [Int] = []
    private func pageStartParagraph(_ p: Int) -> Int { pageParagraphs.indices.contains(p) ? pageParagraphs[p] : 0 }

    private func paginate(_ geo: GeometryProxy, restore: Bool = false) {
        let theme = settings.currentTheme
        let width = geo.size.width - settings.horizontalPadding * 2
        let height = geo.size.height - geo.safeAreaInsets.top - max(geo.safeAreaInsets.bottom, 10) - 8 - 44
        guard width > 50, height > 100 else { return }

        let font = UIFont.systemFont(ofSize: settings.fontSize)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = settings.lineSpacing
        style.paragraphSpacing = settings.paragraphSpacing
        style.firstLineHeadIndent = settings.fontSize * 2
        style.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style, .foregroundColor: UIColor(theme.fg)]
        let paras = model.paragraphs
        let full = NSMutableAttributedString()
        var paraStarts: [Int] = []
        let titleStyle = NSMutableParagraphStyle(); titleStyle.paragraphSpacing = settings.paragraphSpacing * 2
        full.append(NSAttributedString(string: model.title + "\n", attributes: [
            .font: UIFont.boldSystemFont(ofSize: settings.fontSize + 4), .paragraphStyle: titleStyle, .foregroundColor: UIColor(theme.fg)]))
        for (i, p) in paras.enumerated() {
            paraStarts.append(full.length)
            full.append(NSAttributedString(string: p + (i == paras.count - 1 ? "" : "\n"), attributes: attrs))
        }

        let storage = NSTextStorage(attributedString: full)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var result: [NSAttributedString] = []
        var starts: [Int] = []
        var loc = 0
        while loc < full.length {
            let container = NSTextContainer(size: CGSize(width: width, height: height))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            let range = layout.glyphRange(for: container)
            let charRange = layout.characterRange(forGlyphRange: range, actualGlyphRange: nil)
            if charRange.length == 0 { break }
            result.append(full.attributedSubstring(from: charRange))
            starts.append(charRange.location)
            loc = charRange.location + charRange.length
            if result.count > 2000 { break }
        }
        if result.isEmpty { result = [NSAttributedString(string: model.loading ? "" : "（本章无内容）", attributes: attrs)] }
        pages = result
        pageParagraphs = starts.map { s in (paraStarts.lastIndex { $0 <= s } ?? 0) }

        if goingBack {
            page = pages.count - 1
            model.book.durChapterPos = pageStartParagraph(page)
        } else {
            let pos = model.book.durChapterPos
            if restore || pos > 0 {
                page = pageParagraphs.lastIndex { $0 <= pos } ?? 0
            } else {
                page = 0
            }
        }
        page = min(max(0, page), pages.count - 1)
    }
}

/// 显示富文本（不可编辑的 UITextView，顶端对齐，排版和分页计算一致）
struct AttributedLabel: UIViewRepresentable {
    let text: NSAttributedString
    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isEditable = false
        v.isSelectable = false
        v.isScrollEnabled = false
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.isUserInteractionEnabled = false
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return v
    }
    func updateUIView(_ v: UITextView, context: Context) { v.attributedText = text }
}
