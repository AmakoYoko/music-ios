import Foundation

let baseURL = URL(string: "https://music.lamas.one")!

struct Artist: Codable, Hashable { var name: String; var id: String? }
struct AlbumRef: Codable, Hashable { var name: String; var id: String? }
struct Feedback: Codable, Hashable { var add: String?; var remove: String? }

/// Titre normalisé, au même format que la PWA (`track()` de util.js) : il circule tel quel dans les playlists Music,
/// l'historique, les versions et l'état publié aux autres appareils.
struct Track: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var artists: [Artist] = []
    var album: AlbumRef?
    var thumb: String = ""
    var duration: Double?
    var explicit: Bool = false
    var video: Bool = false
    var setVideoId: String?
    var feedback: Feedback?
    var inLibrary: Bool?
    var like: String?
    var available: Bool = true
    // file d'attente
    var auto: Bool?
    var key: String?        // playlists Music
    var orig: String?       // « Autres versions » : id d'origine
    var live: Bool?         // Music Live
    var by: String?

    enum CodingKeys: String, CodingKey { case id, title, artists, album, thumb, duration, explicit, video, setVideoId, feedback, inLibrary, like, available, auto, key, orig, live, by }

    init(id: String, title: String, artists: [Artist] = [], album: AlbumRef? = nil, thumb: String = "", duration: Double? = nil) {
        self.id = id; self.title = title; self.artists = artists; self.album = album; self.thumb = thumb; self.duration = duration
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        artists = (try? c.decode([Artist].self, forKey: .artists)) ?? []
        album = try? c.decode(AlbumRef.self, forKey: .album)
        thumb = (try? c.decode(String.self, forKey: .thumb)) ?? ""
        duration = try? c.decode(Double.self, forKey: .duration)
        explicit = (try? c.decode(Bool.self, forKey: .explicit)) ?? false
        video = (try? c.decode(Bool.self, forKey: .video)) ?? false
        setVideoId = try? c.decode(String.self, forKey: .setVideoId)
        feedback = try? c.decode(Feedback.self, forKey: .feedback)
        inLibrary = try? c.decode(Bool.self, forKey: .inLibrary)
        like = try? c.decode(String.self, forKey: .like)
        available = (try? c.decode(Bool.self, forKey: .available)) ?? true
        auto = try? c.decode(Bool.self, forKey: .auto)
        key = try? c.decode(String.self, forKey: .key)
        orig = try? c.decode(String.self, forKey: .orig)
        live = try? c.decode(Bool.self, forKey: .live)
        by = try? c.decode(String.self, forKey: .by)
    }

    var artistLine: String { artists.map(\.name).joined(separator: ", ") }
    var thumbURL: URL? { absURL(thumb) }
    var isLive: Bool { live == true }
    /// Copie sans les champs propres à la file (pour l'historique, les versions…).
    var plain: Track { var t = self; t.auto = nil; t.orig = nil; t.feedback = nil; return t }
}

/// Adresse relative du serveur (« /api/img?u=… ») ou absolue.
func absURL(_ s: String?) -> URL? {
    guard let s, !s.isEmpty else { return nil }
    if s.hasPrefix("/") { return URL(string: baseURL.absoluteString + s) }
    return URL(string: s)
}

// MARK: - mise en forme (portage de util.js)

/// Pochette en bonne définition, relayée par le serveur.
func img(_ thumbs: JSON, _ size: Int = 544) -> String {
    var u: String?
    switch thumbs {
    case .str(let s): u = s
    case .arr(let a): u = a.last?["url"].string
    case .obj: u = thumbs["thumbnails"].array.last?["url"].string ?? thumbs["url"].string
    default: u = nil
    }
    guard var url = u, !url.isEmpty else { return "" }
    if url.contains("googleusercontent") || url.contains("ggpht") {
        if let r = url.range(of: #"=w\d+-h\d+.*$"#, options: .regularExpression) { url.replaceSubrange(r, with: "=w\(size)-h\(size)-l90-rj") }
        else if let r = url.range(of: #"=s\d+.*$"#, options: .regularExpression) { url.replaceSubrange(r, with: "=s\(size)") }
    } else if url.contains("i.ytimg.com/vi/"), let r = url.range(of: #"/[a-z]*default\.jpg.*"#, options: .regularExpression) {
        url.replaceSubrange(r, with: "/hqdefault.jpg")
    }
    return "/api/img?u=" + (url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url)
}

func secs(_ v: JSON) -> Double? {
    if case .num(let n) = v { return n }
    guard let s = v.string else { return nil }
    let p = s.split(separator: ":").map { Double($0) }
    if p.contains(where: { $0 == nil }) || p.isEmpty { return nil }
    return p.reduce(0) { $0 * 60 + $1! }
}

func clock(_ s: Double) -> String {
    let v = s.isFinite && s > 0 ? Int(s) : 0
    let h = v / 3600, m = (v % 3600) / 60, ss = v % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, ss) : String(format: "%d:%02d", m, ss)
}

func bytes(_ n: Int64) -> String {
    n > 1_000_000_000 ? String(format: "%.1f Go", Double(n) / 1e9) : n > 1_000_000 ? "\(n / 1_000_000) Mo" : "\(n / 1000) ko"
}

/// « 1 titre », « 12 titres ».
func nt(_ n: Int) -> String { "\(n) titre\(n > 1 ? "s" : "")" }

private let noise = try! NSRegularExpression(pattern: #"\s*[(\[【][^)\]】]*\b(official|officiel(le)?|video|vidéo|clip|audio|lyrics?|paroles|visuali[sz]er|hd|hq|4k|mv|m/v)\b[^)\]】]*[)\]】]"#, options: .caseInsensitive)
private let pipe = try! NSRegularExpression(pattern: #"\s*[|｜]\s*(official|officiel|clip|lyrics?|paroles|hd|4k|audio|vid[ée]o).*$"#, options: .caseInsensitive)

/// Titres de clips nettoyés : « Artiste - Titre (Official Video) [HD] » → « Titre ».
func cleanTitle(_ title: String, _ artists: [Artist] = []) -> String {
    func rep(_ re: NSRegularExpression, _ s: String) -> String { re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "") }
    var s = rep(pipe, rep(noise, title))
    s = s.replacingOccurrences(of: #"\s+#\S+"#, with: "", options: .regularExpression)
    let names = artists.map { $0.name.lowercased() }
    if let r = s.range(of: #"^(.+?)\s+[-–—]\s+(.+)$"#, options: .regularExpression) {
        let whole = String(s[r])
        if let sep = whole.range(of: #"\s+[-–—]\s+"#, options: .regularExpression) {
            let a = whole[..<sep.lowerBound].lowercased().trimmingCharacters(in: .whitespaces)
            if names.contains(where: { a.contains($0) || $0.contains(a) }) { s = String(whole[sep.upperBound...]) }
        }
    }
    s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    return s.isEmpty ? title : s
}

struct TrackCtx { var album: AlbumRef?; var thumbs: JSON = .null; var artists: [Artist]? }

/// Normalise un élément ytmusicapi (recherche, album, playlist, radio…) ; nil sans videoId.
func track(_ t: JSON, _ ctx: TrackCtx = TrackCtx()) -> Track? {
    guard let vid = t["videoId"].string, !vid.isEmpty else {
        // déjà au format de l'appli (historique, playlists Music)
        if let id = t["id"].string, t["videoId"].isNull, t["title"].exists, !t["browseId"].exists, var x = t.decode(Track.self) {
            x.id = id; return x
        }
        return nil
    }
    let artists = t["artists"].array.compactMap { a -> Artist? in
        guard let n = a["name"].string, !n.isEmpty else { return nil }
        return Artist(name: n.replacingOccurrences(of: #"\s*-\s*Topic$|VEVO$"#, with: "", options: [.regularExpression, .caseInsensitive]), id: a["id"].string)
    }
    var album: AlbumRef? = ctx.album
    if case .str(let s) = t["album"] { album = AlbumRef(name: s, id: nil) }
    else if let n = t["album"]["name"].string { album = AlbumRef(name: n, id: t["album"]["id"].string) }
    let arts = artists.isEmpty ? (ctx.artists ?? []) : artists
    var x = Track(id: vid, title: cleanTitle(t["title"].string ?? "", arts), artists: arts, album: album)
    let th = t["thumbnails"].exists ? t["thumbnails"] : t["thumbnail"].exists ? t["thumbnail"] : ctx.thumbs
    x.thumb = img(th)
    if x.thumb.isEmpty { x.thumb = img(.str("https://i.ytimg.com/vi/\(vid)/hqdefault.jpg")) }
    x.duration = t["duration_seconds"].double ?? secs(t["duration"]) ?? secs(t["length"])
    x.explicit = t["isExplicit"].bool ?? false
    if let vt = t["videoType"].string { x.video = vt != "MUSIC_VIDEO_TYPE_ATV" }
    x.setVideoId = t["setVideoId"].string
    if t["feedbackTokens"].exists { x.feedback = Feedback(add: t["feedbackTokens"]["add"].string, remove: t["feedbackTokens"]["remove"].string) }
    x.inLibrary = t["inLibrary"].bool
    x.like = t["likeStatus"].string
    x.available = t["isAvailable"].bool ?? true
    return x
}

func parseTracks(_ list: JSON, _ ctx: TrackCtx = TrackCtx()) -> [Track] { list.array.compactMap { track($0, ctx) } }

enum Kind: Equatable { case song, album(String), artist(String), playlist(String), podcast, other }

/// Ce qu'un élément de carrousel représente, et où il mène.
func kindOf(_ it: JSON) -> Kind {
    let b = it["browseId"].string ?? ""
    if it["videoId"].string != nil && !(it["playlistId"].string ?? "").hasPrefix("RDCLAK") { return .song }
    let type = it["type"].string ?? ""
    if b.hasPrefix("MPRE") || ["Album", "Single", "EP"].contains(type) || it["resultType"].string == "album" {
        return .album(!b.isEmpty ? b : it["audioPlaylistId"].string ?? it["playlistId"].string ?? "")
    }
    if b.hasPrefix("UC") || it["resultType"].string == "artist" || it["subscribers"].exists {
        return .artist(!b.isEmpty ? b : it["artists"][0]["id"].string ?? it["id"].string ?? "")
    }
    if b.hasPrefix("MPSP") { return .podcast }
    let pid = it["playlistId"].string ?? (b.hasPrefix("VL") ? String(b.dropFirst(2)) : b)
    if !pid.isEmpty { return .playlist(pid) }
    return .other
}

func subtitle(_ it: JSON) -> String {
    if let s = it["subscribers"].string, !it["artists"].exists { return s }
    if let s = it["description"].string, !it["artists"].exists { return s }
    var names = it["artists"].array.compactMap { $0["name"].string }
    if names.isEmpty {
        let au = it["author"]
        names = (au.array.isEmpty ? [au] : au.array).compactMap { $0["name"].string ?? $0.string }
    }
    let a = names.joined(separator: ", ")
    let type = it["type"].string.flatMap { $0 == "Album" ? nil : $0 }
    return [type, a.isEmpty ? it["count"].string : a, it["year"].string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
}

func itemTitle(_ it: JSON) -> String { it["title"].string ?? it["artist"].string ?? it["name"].string ?? "" }

/// Origine d'une lecture (« En lecture depuis … »), même forme que la PWA.
struct Source: Codable, Hashable { var title: String?; var href: String? }
