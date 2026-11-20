import SwiftUI

/// Live TV: groups (Favourites, All, provider groups) → channels with search → player.
struct LiveView: View {
    @EnvironmentObject var library: Library
    @Binding var play: PlayItem?

    var body: some View {
        NavigationStack {
            List {
                LoadingOrError()
                NavigationLink { ChannelList(title: "المفضلة", filter: { Store.isFavorite($0.id) }, play: $play) } label: {
                    Label("المفضلة", systemImage: "star.fill").foregroundStyle(Theme.accent)
                }
                NavigationLink { ChannelList(title: "كل القنوات", filter: { _ in true }, play: $play) } label: {
                    HStack { Text("كل القنوات"); Spacer(); Text("\(library.channels.count)").foregroundStyle(.secondary) }
                }
                ForEach(library.liveCats) { c in
                    NavigationLink { ChannelList(title: c.name, filter: { $0.categoryId == c.id }, play: $play) } label: { Text(c.name).lineLimit(2) }
                }
            }
            .navigationTitle("القنوات")
            .refreshable { await library.reload() }
        }
    }
}

struct ChannelList: View {
    @EnvironmentObject var library: Library
    let title: String
    let filter: (Channel) -> Bool
    @Binding var play: PlayItem?
    @State private var query = ""
    @State private var favTick = 0

    var body: some View {
        let list = library.channels.filter(filter).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        List(Array(list.enumerated()), id: \.element.id) { i, ch in
            Button { play = .live(list: list, index: i) } label: {
                HStack(spacing: 12) {
                    Art(url: ch.logo, fit: true).frame(width: 56, height: 36).background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                    Text(ch.name).lineLimit(2).foregroundStyle(.primary)
                    Spacer()
                    if Store.isFavorite(ch.id) { Image(systemName: "star.fill").foregroundStyle(Theme.accent) }
                }
            }
            .swipeActions { Button { Store.toggleFavorite(ch.id); favTick += 1 } label: { Label("مفضلة", systemImage: "star") }.tint(Theme.accent) }
            .contextMenu { Button { Store.toggleFavorite(ch.id); favTick += 1 } label: { Label(Store.isFavorite(ch.id) ? "إزالة من المفضلة" : "إضافة للمفضلة", systemImage: "star") } }
        }
        .id(favTick)
        .searchable(text: $query, prompt: "بحث في القنوات")
        .navigationTitle(title)
    }
}
