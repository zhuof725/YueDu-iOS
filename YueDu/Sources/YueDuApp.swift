import SwiftUI

@main
struct YueDuApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            NavigationView {
                VStack(spacing: 16) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 60))
                        .foregroundColor(.accentColor)
                    Text("书架还是空的")
                        .font(.headline)
                    Text("云端编译成功 🎉\n版本 0.1.0 · 流程验证版")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .navigationTitle("书架")
            }
            .navigationViewStyle(.stack)
            .tabItem { Label("书架", systemImage: "books.vertical") }

            NavigationView {
                Text("书源管理（下一步实现）")
                    .foregroundColor(.secondary)
                    .navigationTitle("书源")
            }
            .navigationViewStyle(.stack)
            .tabItem { Label("书源", systemImage: "link") }
        }
    }
}
