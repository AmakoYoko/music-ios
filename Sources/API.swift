import Foundation

let baseURL = URL(string: "https://music.lamas.one")!

struct Artist: Codable, Hashable { let name: String; let id: String? }
struct Album: Codable, Hashable { let name: String; let id: String? }
struct Thumb: Codable, Hashable { let url: String }

struct Track: Codable, Hashable, Identifiable {
    let videoId: String
    let title: String
    var artists: [Artist]?
    var album: Album?
    var thumbnails: [Thumb]?
    var duration_seconds: Int?
    var resultType: String?

    var id: String { videoId }
    var artistLine: String { (artists ?? []).map(\.name).joined(separator: ", ") }
    /// Pochette agrandie (les adresses Google acceptent =wN-hN).
    func art(_ size: Int = 544) -> URL? {
        guard var u = thumbnails?.last?.url else { return nil }
        if let r = u.range(of: #"=w\d+-h\d+"#, options: .regularExpression) { u.replaceSubrange(r, with: "=w\(size)-h\(size)") }
        return URL(string: u)
    }
}

struct PlaylistRef: Codable, Hashable, Identifiable {
    let playlistId: String
    let title: String
    var thumbnails: [Thumb]?
    var description: String?
    var id: String { playlistId }
    var art: URL? { thumbnails?.last.flatMap { URL(string: $0.url) } }
}

struct PlaylistDetail: Decodable { let title: String; var tracks: Lossy<Track>? }

enum APIError: LocalizedError {
    case unauthorized, http(Int)
    var errorDescription: String? {
        switch self {
        case .unauthorized: "Connexion requise"
        case .http(let c): "Erreur serveur (\(c))"
        }
    }
}

/// Session Music : cookie signé remis par /auth/app, conservé dans les réglages et le magasin de cookies partagé
/// (URLSession, AVPlayer et les images s'en servent tous).
enum Session {
    static let cookieName = "music_sess2"
    static var value: String? {
        get { UserDefaults.standard.string(forKey: "session") }
        set {
            UserDefaults.standard.set(newValue, forKey: "session")
            install()
        }
    }
    static func install() {
        let store = HTTPCookieStorage.shared
        store.cookies(for: baseURL)?.filter { $0.name == cookieName }.forEach(store.deleteCookie)
        guard let v = value, let c = HTTPCookie(properties: [
            .domain: baseURL.host!, .path: "/", .name: cookieName, .value: v, .secure: "TRUE",
            .expires: Date().addingTimeInterval(60 * 60 * 24 * 30),
        ]) else { return }
        store.setCookie(c)
    }
}

enum API {
    static func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        var c = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: c.url!)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw APIError.unauthorized }
        guard code == 200 else { throw APIError.http(code) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func search(_ q: String) async throws -> [Track] {
        let r: Lossy<Track> = try await get("api/yt/search", ["q": q, "filter": "songs", "limit": "40"])
        return r.items.filter { $0.resultType == nil || $0.resultType == "song" || $0.resultType == "video" }
    }
    static func likedSongs() async throws -> [Track] { (try await get("api/yt/library/songs") as Lossy<Track>).items }
    static func playlists() async throws -> [PlaylistRef] { try await get("api/yt/library/playlists") }
    static func playlist(_ id: String) async throws -> PlaylistDetail { try await get("api/yt/playlist", ["id": id]) }
    static func audioURL(_ vid: String) -> URL { baseURL.appendingPathComponent("api/audio/\(vid)") }
    static func downloadURL(_ vid: String) -> URL { baseURL.appendingPathComponent("api/download/\(vid)") }
}

/// Tableau qui ignore les éléments illisibles (titres indisponibles sans videoId, résultats d'un autre type).
struct Lossy<T: Decodable>: Decodable {
    let items: [T]
    init(from d: Decoder) throws {
        var c = try d.unkeyedContainer(), out: [T] = []
        while !c.isAtEnd {
            if let v = try? c.decode(T.self) { out.append(v) } else { _ = try? c.decode(Skip.self) }
        }
        items = out
    }
    private struct Skip: Decodable {}
}
