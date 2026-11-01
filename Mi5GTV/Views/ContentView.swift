import SwiftUI

struct ContentView: View {
    @StateObject private var tv = TVSession()

    var body: some View {
        ZStack(alignment: .bottom) {
            if tv.state == .connected {
                MainTabs()
            } else {
                ConnectView()
            }
            if let t = tv.toast {
                Text(t)
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 90)
                    .transition(.opacity)
            }
        }
        .environmentObject(tv)
        .environment(\.layoutDirection, .rightToLeft)
        .animation(.easeInOut, value: tv.toast)
        .alert("تنبيه", isPresented: errorBinding, actions: {
            Button("حسنًا", role: .cancel) { }
        }, message: {
            Text(tv.errorMessage ?? "")
        })
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { tv.errorMessage != nil },
            set: { newValue in if !newValue { tv.errorMessage = nil } }
        )
    }
}

struct MainTabs: View {
    var body: some View {
        TabView {
            RemoteView()
                .tabItem { Label("الريموت", systemImage: "gamecontroller.fill") }
            AppsView()
                .tabItem { Label("التطبيقات", systemImage: "square.grid.2x2.fill") }
            ToolsView()
                .tabItem { Label("الأدوات", systemImage: "bolt.fill") }
        }
    }
}
