import Foundation

/// What to look for: a cleaned film/series name, plus season and episode for an episode.
struct SubQuery: Hashable {
    var name: String
    var year: String? = nil
    var season: Int? = nil
    var episode: Int? = nil

    /// Strips provider decorations: "AR - ", "|EN|", "[4K]", "(2023)", "FHD", "مترجم"…
    static func clean(_ raw: String) -> SubQuery {
        var s = raw
        if let r = s.range(of: #"^\s*[\|\[]?[A-Za-z]{2,4}[\|\]]?\s*[-:|]\s*"#, options: .regularExpression) { s.removeSubrange(r) }
        var year: String?
        if let r = s.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) { year = String(s[r]) }
        for p in [#"\[[^\]]*\]"#, #"\([^)]*\)"#, #"\|[^|]*\|"#, #"\b(19|20)\d{2}\b"#,
                  #"(?i)\b(4k|uhd|fhd|hd|sd|1080p|720p|2160p|hevc|x265|h264|multi|vip|web-?dl|bluray)\b"#, "مترجم|مدبلج"] {
            s = s.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"[\s\-_.:|]+$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return SubQuery(name: s.isEmpty ? raw : s, year: year)
    }
}

struct SubResult: Identifiable, Hashable {
    let id: Int          // file_id
    let language: String
    let release: String
    let downloads: Int
}

/// OpenSubtitles.com REST API v1. The API key (and the optional account) are the viewer's own, kept in the Keychain.
enum OnlineSubs {
    static let keyAPI = "os.apikey", keyUser = "os.user", keyPass = "os.pass"
    private static let base = URL(string: "https://api.opensubtitles.com/api/v1/")!
    private static let agent = "Shasha v0.3"
    private static var token: String?

    enum Failure: LocalizedError {
        case noKey, http(Int, String?), quota(String?)
        var errorDescription: String? {
            switch self {
            case .noKey: return "أضف مفتاح OpenSubtitles من الإعدادات أولًا."
            case .http(401, _), .http(403, _): return "المفتاح أو الحساب غير مقبول لدى OpenSubtitles."
            case .http(let c, let m): return "OpenSubtitles ردّ بخطأ \(c)" + (m.map { ": \($0)" } ?? "")
            case .quota(let m): return "انتهى حد التنزيل اليومي" + (m.map { " (\($0))" } ?? "") + ". أضف حسابك في الإعدادات لزيادة الحد."
            }
        }
    }

    static var hasKey: Bool { !(Keychain.get(keyAPI) ?? "").isEmpty }

    private static func request(_ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) throws -> URLRequest {
        guard let key = Keychain.get(keyAPI), !key.isEmpty else { throw Failure.noKey }
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        var r = URLRequest(url: c.url!, timeoutInterval: 20)
        r.setValue(key, forHTTPHeaderField: "Api-Key")
        r.setValue(agent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    private static func json(_ r: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if code == 406 || code == 429 { throw Failure.quota(obj["message"] as? String) }
        guard (200..<300).contains(code) else { throw Failure.http(code, obj["message"] as? String) }
        return obj
    }

    /// Logs in once per launch when the viewer saved an account (higher download quota). Silent if none.
    private static func loginIfNeeded() async {
        guard token == nil, let u = Keychain.get(keyUser), !u.isEmpty, let p = Keychain.get(keyPass), !p.isEmpty,
              let r = try? request("login", body: ["username": u, "password": p]),
              let o = try? await json(r) else { return }
        token = o["token"] as? String
    }

    static func resetLogin() { token = nil }

    /// Arabic first, then English; most downloaded first inside each language.
    static func search(_ q: SubQuery) async throws -> [SubResult] {
        var items = [URLQueryItem(name: "query", value: q.name.lowercased()), URLQueryItem(name: "languages", value: "ar,en")]
        if let s = q.season { items.append(URLQueryItem(name: "season_number", value: String(s))) }
        if let e = q.episode { items.append(URLQueryItem(name: "episode_number", value: String(e))) }
        if q.season == nil, let y = q.year { items.append(URLQueryItem(name: "year", value: y)) }
        await loginIfNeeded()
        let o = try await json(try request("subtitles", query: items))
        var out: [SubResult] = []
        for d in o["data"] as? [[String: Any]] ?? [] {
            guard let a = d["attributes"] as? [String: Any],
                  let f = (a["files"] as? [[String: Any]])?.first,
                  let id = (f["file_id"] as? NSNumber)?.intValue else { continue }
            out.append(SubResult(id: id, language: a["language"] as? String ?? "?",
                                 release: (a["release"] as? String) ?? (f["file_name"] as? String) ?? "",
                                 downloads: (a["download_count"] as? NSNumber)?.intValue ?? 0))
        }
        return out.sorted { ($0.language == "ar" ? 0 : 1, -$0.downloads) < ($1.language == "ar" ? 0 : 1, -$1.downloads) }
    }

    /// Downloads one subtitle file into the caches folder and returns its local URL.
    static func download(_ s: SubResult) async throws -> URL {
        await loginIfNeeded()
        let o = try await json(try request("download", body: ["file_id": s.id, "sub_format": "srt"]))
        guard let link = (o["link"] as? String).flatMap(URL.init(string:)) else { throw Failure.http(0, "لا يوجد رابط") }
        let (data, _) = try await URLSession.shared.data(from: link)
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("subs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(s.id).srt")
        try data.write(to: file, options: .atomic)
        return file
    }
}
