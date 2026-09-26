import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var settings: ReadSettings
    @State private var cacheSize = "计算中…"
    @State private var confirmClear = false

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationView {
            Form {
                Section("阅读") {
                    NavigationLink("阅读设置") { ReadSettingsSheet() }
                }
                Section("数据") {
                    LabeledRow("书架", "\(store.shelf.count) 本")
                    LabeledRow("书源", "\(store.sources.count) 个")
                    HStack {
                        Text("正文缓存")
                        Spacer()
                        Text(cacheSize).foregroundColor(.secondary)
                    }
                    Button("清除全部正文缓存", role: .destructive) { confirmClear = true }
                    Button("清除网站 Cookie") {
                        HTTPCookieStorage.shared.cookies?.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
                    }
                }
                Section("关于") {
                    LabeledRow("版本", version)
                    Text("兼容「阅读 / Legado」书源格式。本 App 不提供任何内容，所有内容来自用户自行导入的书源。")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .navigationTitle("我的")
            .onAppear { computeCache() }
            .confirmationDialog("清除全部已缓存的章节？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清除", role: .destructive) {
                    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("content")
                    try? FileManager.default.removeItem(at: dir)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    computeCache()
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func computeCache() {
        DispatchQueue.global().async {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("content")
            var total: Int64 = 0
            if let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let u as URL in e {
                    total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            }
            let s = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            DispatchQueue.main.async { cacheSize = s }
        }
    }
}
