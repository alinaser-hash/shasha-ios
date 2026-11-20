import Foundation
import SwiftUI

/// Everything the screens show for the active playlist, plus the saved playlists.
@MainActor
final class Library: ObservableObject {
    @Published private(set) var sources: [Source] = []
    @Published var activeId: UUID?
    @Published private(set) var liveCats: [Category] = []
    @Published private(set) var channels: [Channel] = []
    @Published private(set) var vodCats: [Category] = []
    @Published private(set) var movies: [Movie] = []
    @Published private(set) var seriesCats: [Category] = []
    @Published private(set) var shows: [Show] = []
    @Published private(set) var loading = false
    @Published var error: String?

    private let key = "sources.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode([Source].self, from: d) { sources = s }
        activeId = UUID(uuidString: UserDefaults.standard.string(forKey: "active.v1") ?? "") ?? sources.first?.id
    }

    var active: Source? { sources.first { $0.id == activeId } ?? sources.first }

    var xtream: Xtream? {
        guard let s = active, s.kind == .xtream else { return nil }
        return Xtream(server: s.server, user: s.username, pass: Keychain.get(s.id.uuidString) ?? "")
    }

    private func save() {
        if let d = try? JSONEncoder().encode(sources) { UserDefaults.standard.set(d, forKey: key) }
        UserDefaults.standard.set(activeId?.uuidString, forKey: "active.v1")
    }

    func addXtream(name: String, server: String, user: String, pass: String) async throws {
        let base = Xtream.normalize(server)
        guard URL(string: base) != nil else { throw LoadError.badAddress }
        try await Xtream(server: base, user: user, pass: pass).verify()
        let s = Source(name: name.isEmpty ? (URL(string: base)?.host ?? "Xtream") : name, kind: .xtream, server: base, username: user)
        Keychain.set(pass, for: s.id.uuidString)
        sources.append(s); activeId = s.id; save()
        await reload()
    }

    func addM3U(name: String, url: String) async throws {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: u)?.scheme?.hasPrefix("http") == true else { throw LoadError.badAddress }
        let s = Source(name: name.isEmpty ? "M3U" : name, kind: .m3u, server: u)
        sources.append(s); activeId = s.id; save()
        await reload()
    }

    func remove(_ s: Source) {
        Keychain.set(nil, for: s.id.uuidString)
        sources.removeAll { $0.id == s.id }
        if activeId == s.id { activeId = sources.first?.id }
        save()
        Task { await reload() }
    }

    func select(_ s: Source) { activeId = s.id; save(); Task { await reload() } }

    /// Reads the whole playlist (lists only; details are read when a title is opened).
    func reload() async {
        guard let s = active else { clear(); return }
        loading = true; error = nil
        defer { loading = false }
        do {
            if let x = xtream {
                async let lc = x.categories("get_live_categories")
                async let ch = x.channels()
                async let vc = x.categories("get_vod_categories")
                async let mv = x.movies()
                async let sc = x.categories("get_series_categories")
                async let sh = x.shows()
                liveCats = try await lc; channels = try await ch
                vodCats = (try? await vc) ?? []; movies = (try? await mv) ?? []
                seriesCats = (try? await sc) ?? []; shows = (try? await sh) ?? []
            } else {
                guard let url = URL(string: s.server) else { throw LoadError.badAddress }
                let (data, _) = try await URLSession.shared.data(from: url)
                let text = String(decoding: data, as: UTF8.self)
                let r = await Task.detached { M3U.parse(text) }.value
                liveCats = r.cats; channels = r.channels; movies = r.movies
                vodCats = r.cats.filter { c in r.movies.contains { $0.categoryId == c.id } }
                seriesCats = []; shows = []
            }
            if channels.isEmpty && movies.isEmpty && shows.isEmpty { throw LoadError.empty }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func clear() { liveCats = []; channels = []; vodCats = []; movies = []; seriesCats = []; shows = [] }
}

/// Now-playing programme per channel, fetched lazily for the rows on screen (Xtream only).
@MainActor
final class EPG: ObservableObject {
    @Published private(set) var now: [String: EPGNow] = [:]
    private var asked: [String: Date] = [:]

    func load(_ ch: Channel, from x: Xtream?) {
        guard let x else { return }
        if let n = now[ch.id], n.end > Date() { return }
        if let a = asked[ch.id], Date().timeIntervalSince(a) < 120 { return }
        asked[ch.id] = Date()
        Task {
            if let r = await x.shortEPG(ch.id) { now[ch.id] = r }
        }
    }

    func clear() { now = [:]; asked = [:] }
}

/// Resume points and favourites (on this phone).
enum Store {
    private static var d: UserDefaults { .standard }

    static func position(_ key: String) -> (pos: Double, dur: Double)? {
        guard let a = d.array(forKey: "pos." + key) as? [Double], a.count == 2, a[0] > 5 else { return nil }
        return (a[0], a[1])
    }

    /// Saved until 95 % watched, then cleared (watched).
    static func setPosition(_ key: String, _ pos: Double, _ dur: Double) {
        if dur > 0 && pos / dur > 0.95 { d.removeObject(forKey: "pos." + key); return }
        d.set([pos, dur], forKey: "pos." + key)
        var recent = d.stringArray(forKey: "recent") ?? []
        recent.removeAll { $0 == key }; recent.insert(key, at: 0)
        d.set(Array(recent.prefix(60)), forKey: "recent")
    }

    static var recent: [String] { d.stringArray(forKey: "recent") ?? [] }

    static func isFavorite(_ id: String) -> Bool { (d.stringArray(forKey: "fav") ?? []).contains(id) }

    static func toggleFavorite(_ id: String) {
        var f = d.stringArray(forKey: "fav") ?? []
        if let i = f.firstIndex(of: id) { f.remove(at: i) } else { f.insert(id, at: 0) }
        d.set(f, forKey: "fav")
    }

    static var favorites: [String] { d.stringArray(forKey: "fav") ?? [] }
}
