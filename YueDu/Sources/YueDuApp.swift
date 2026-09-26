import SwiftUI

@main
struct YueDuApp: App {
    @StateObject private var store = Store.shared
    @StateObject private var settings = ReadSettings.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(settings)
        }
    }
}

struct ContentView: View {
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            BookshelfView()
                .tabItem { Label("书架", systemImage: "books.vertical") }
                .tag(0)
            SearchView()
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                .tag(1)
            SourceListView()
                .tabItem { Label("书源", systemImage: "link") }
                .tag(2)
            SettingsView()
                .tabItem { Label("我的", systemImage: "person") }
                .tag(3)
        }
    }
}

/// 网络封面图
struct CoverView: View {
    let url: String?
    let name: String
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.77, green: 0.43, blue: 0.24), Color(red: 0.55, green: 0.24, blue: 0.12)],
                           startPoint: .top, endPoint: .bottom)
            Text(name.prefix(6))
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white.opacity(0.95))
                .multilineTextAlignment(.center)
                .padding(4)
            if let u = url, let url = URL(string: u) ?? URL(string: Util.encodeLoose(u)) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() }
                }
            }
        }
        .aspectRatio(3/4, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
    }
}

/// 在后台线程跑同步任务
func runInBackground<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            do { cont.resume(returning: try work()) } catch { cont.resume(throwing: error) }
        }
    }
}
