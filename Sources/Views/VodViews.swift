import SwiftUI

private let grid = [GridItem(.adaptive(minimum: 108), spacing: 12)]

/// Movies: continue watching, category chips, newest first, search.
struct MoviesView: View {
    @EnvironmentObject var library: Library
    @Binding var play: PlayItem?
    @State private var cat: String?
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                LoadingOrError()
                let cont = library.movies.filter { Store.position("movie:" + $0.id) != nil }
                if !cont.isEmpty && query.isEmpty && cat == nil {
                    Text("متابعة المشاهدة").font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(cont.prefix(20)) { m in
                                NavigationLink { MovieDetail(movie: m, play: $play) } label: { PosterCard(title: m.name, poster: m.poster, progress: progress("movie:" + m.id)).frame(width: 110) }
                                    .buttonStyle(.plain)
                            }
                        }.padding(.horizontal)
                    }
                }
                Chips(cats: library.vodCats, selected: $cat).padding(.vertical, 6)
                let list = library.movies.filter { (cat == nil || $0.categoryId == cat) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
                    .sorted { $0.added > $1.added }
                LazyVGrid(columns: grid, spacing: 16) {
                    ForEach(list) { m in
                        NavigationLink { MovieDetail(movie: m, play: $play) } label: { PosterCard(title: m.name, poster: m.poster) }.buttonStyle(.plain)
                    }
                }.padding(.horizontal)
            }
            .searchable(text: $query, prompt: "بحث في الأفلام")
            .navigationTitle("الأفلام")
            .refreshable { await library.reload() }
        }
    }
}

func progress(_ key: String) -> Double? {
    guard let p = Store.position(key), p.dur > 0 else { return nil }
    return min(1, p.pos / p.dur)
}

struct MovieDetail: View {
    @EnvironmentObject var library: Library
    let movie: Movie
    @Binding var play: PlayItem?
    @State private var info = MovieInfo()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Art(url: info.backdrop ?? movie.poster).frame(height: 220).clipped()
                    .overlay(LinearGradient(colors: [.clear, Theme.bg], startPoint: .center, endPoint: .bottom))
                Text(movie.name).font(.title2.bold()).padding(.horizontal)
                Text([info.year, info.genre, movie.rating.map { "★ " + $0 }, info.duration].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(Theme.accent).font(.subheadline).padding(.horizontal)
                let key = "movie:" + movie.id
                Button {
                    play = .vod(title: movie.name, url: movie.url, key: key)
                } label: {
                    Label(Store.position(key) != nil ? "استكمال" : "تشغيل", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 6)
                }.buttonStyle(.borderedProminent).padding(.horizontal)
                if let p = info.plot { Text(p).padding(.horizontal) }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { if let x = library.xtream { info = await x.movieInfo(movie.id) } }
    }
}

/// Series: category chips, recently updated first, search → seasons and episodes.
struct SeriesView: View {
    @EnvironmentObject var library: Library
    @Binding var play: PlayItem?
    @State private var cat: String?
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                LoadingOrError()
                Chips(cats: library.seriesCats, selected: $cat).padding(.vertical, 6)
                let list = library.shows.filter { (cat == nil || $0.categoryId == cat) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
                    .sorted { $0.updated > $1.updated }
                LazyVGrid(columns: grid, spacing: 16) {
                    ForEach(list) { s in
                        NavigationLink { SeriesDetail(show: s, play: $play) } label: { PosterCard(title: s.name, poster: s.poster) }.buttonStyle(.plain)
                    }
                }.padding(.horizontal)
            }
            .searchable(text: $query, prompt: "بحث في المسلسلات")
            .navigationTitle("المسلسلات")
            .refreshable { await library.reload() }
        }
    }
}

struct SeriesDetail: View {
    @EnvironmentObject var library: Library
    let show: Show
    @Binding var play: PlayItem?
    @State private var episodes: [Episode] = []
    @State private var season = 1
    @State private var loading = true

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Art(url: show.poster).frame(width: 100, height: 150).clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(show.name).font(.title3.bold())
                        if let r = show.rating { Text("★ " + r).foregroundStyle(Theme.accent) }
                        if let p = show.plot { Text(p).font(.footnote).lineLimit(6) }
                    }
                }
                if let next = nextEpisode {
                    Button { open(next) } label: { Label("استكمال: الموسم \(next.season) · الحلقة \(next.number)", systemImage: "play.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                }
            }
            let seasons = Array(Set(episodes.map(\.season))).sorted()
            if seasons.count > 1 {
                Picker("الموسم", selection: $season) { ForEach(seasons, id: \.self) { Text("الموسم \($0)").tag($0) } }
            }
            if loading { ProgressView() }
            ForEach(episodes.filter { $0.season == season }) { e in
                Button { open(e) } label: {
                    HStack {
                        Text("\(e.number)").font(.headline.monospacedDigit()).frame(width: 34).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading) {
                            Text(e.title.isEmpty ? "الحلقة \(e.number)" : e.title).lineLimit(2).foregroundStyle(.primary)
                            if let p = progress(key(e)) { ProgressView(value: p).tint(Theme.accent) }
                        }
                    }
                }
            }
        }
        .navigationTitle(show.name).navigationBarTitleDisplayMode(.inline)
        .task {
            guard let x = library.xtream else { loading = false; return }
            episodes = (try? await x.episodes(seriesId: show.id)) ?? []
            season = nextEpisode?.season ?? episodes.first?.season ?? 1
            loading = false
        }
    }

    private func key(_ e: Episode) -> String { "ep:" + e.id }

    /// The episode in progress, else the one after the last started, else the first.
    private var nextEpisode: Episode? {
        if let e = episodes.first(where: { Store.position(key($0)) != nil }) { return e }
        let recent = Set(Store.recent)
        if let last = episodes.lastIndex(where: { recent.contains(key($0)) }), last + 1 < episodes.count { return episodes[last + 1] }
        return nil
    }

    private func open(_ e: Episode) {
        guard let x = library.xtream else { return }
        play = .vod(title: "\(show.name) · م\(e.season) ح\(e.number)", url: x.episodeURL(e.id, e.ext), key: key(e))
    }
}
