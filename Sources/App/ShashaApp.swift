import SwiftUI

enum Theme {
    static let bg = Color(red: 14 / 255, green: 20 / 255, blue: 27 / 255)
    static let surface = Color(red: 27 / 255, green: 38 / 255, blue: 52 / 255)
    static let accent = Color(red: 242 / 255, green: 179 / 255, blue: 61 / 255)
    static let teal = Color(red: 43 / 255, green: 179 / 255, blue: 163 / 255)
}

@main
struct ShashaApp: App {
    @StateObject private var library = Library()
    @StateObject private var epg = EPG()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(epg)
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "ar"))
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var epg: EPG
    @State private var play: PlayItem?

    var body: some View {
        Group {
            if library.sources.isEmpty {
                NavigationStack { SetupView() }
            } else {
                TabView {
                    LiveView(play: $play).tabItem { Label("القنوات", systemImage: "tv") }
                    MoviesView(play: $play).tabItem { Label("الأفلام", systemImage: "film") }
                    SeriesView(play: $play).tabItem { Label("المسلسلات", systemImage: "play.rectangle.on.rectangle") }
                    SettingsView().tabItem { Label("الإعدادات", systemImage: "gearshape") }
                }
            }
        }
        .fullScreenCover(item: $play) { PlayerScreen(item: $0).environmentObject(library).environmentObject(epg) }
        .onChange(of: library.activeId) { _ in epg.clear() }
        .task { if !library.sources.isEmpty && library.channels.isEmpty && library.movies.isEmpty { await library.reload() } }
    }
}
