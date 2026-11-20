import Foundation

/// A playlist the viewer added: an Xtream account or an M3U link. The password lives in the Keychain.
enum SourceKind: String, Codable { case xtream, m3u }

struct Source: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var kind: SourceKind
    /// Xtream: server base (scheme://host:port). M3U: the playlist link.
    var server: String
    var username: String = ""
}

struct Category: Identifiable, Hashable {
    let id: String
    let name: String
}

struct Channel: Identifiable, Hashable {
    let id: String
    let name: String
    let logo: String?
    let categoryId: String
    let url: String
}

struct Movie: Identifiable, Hashable {
    let id: String
    let name: String
    let poster: String?
    let categoryId: String
    let rating: String?
    let ext: String
    let added: Int
    let url: String
}

struct Show: Identifiable, Hashable {
    let id: String
    let name: String
    let poster: String?
    let categoryId: String
    let rating: String?
    let plot: String?
    let updated: Int
}

struct Episode: Identifiable, Hashable {
    let id: String
    let title: String
    let season: Int
    let number: Int
    let ext: String
    let plot: String?
    let image: String?
}

struct MovieInfo {
    var plot: String?
    var genre: String?
    var year: String?
    var duration: String?
    var backdrop: String?
}

/// Loose JSON helpers: Xtream servers send numbers as strings and strings as numbers.
enum J {
    static func s(_ v: Any?) -> String? {
        switch v {
        case let x as String: return x.isEmpty ? nil : x
        case let x as NSNumber: return x.stringValue
        default: return nil
        }
    }
    static func i(_ v: Any?) -> Int { Int(s(v) ?? "") ?? Int(Double(s(v) ?? "") ?? 0) }
}
