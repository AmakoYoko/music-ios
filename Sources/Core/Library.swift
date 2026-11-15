import Foundation
import Observation

/// Playlist Music (serveur, indépendante de YouTube Music).
struct MPL: Codable, Hashable, Identifiable {
    struct Cover: Codable, Hashable { var style: String?; var palette: Int?; var version: Double? }
    var id: String
    var title: String
    var description: String?
    var cover: Cover?
    var count: Int?
    var thumbs: [String]?
    var owner: String = ""
    var share: String = "private"
    var mine: Bool = true
    var canEdit: Bool = true
    var tracks: [Track]?
    var updatedAt: Double?
}

let PALETTES: [(String, String)] = [("#fa2d48", "#ff8a5c"), ("#5e5ce6", "#bf5af2"), ("#0a84ff", "#64d2ff"), ("#30d158", "#0a8f6b"), ("#ff9f0a", "#ff375f"), ("#1c1c1e", "#5a5a60"), ("#ac8e68", "#d4b483"), ("#ff2d92", "#7d2cff")]

/// Compte YouTube Music, « J'aime », playlists Music (portage de ui.js et mpl.js).
@MainActor @Observable final class Library {
    static let shared = Library()
    var account: JSON = [:]
    var liked = Set<String>()
    var mine: [MPL] = Store.get("mpl.list", [MPL]())
    var ytPlaylists: [JSON] = []

    var connected: Bool { account["connected"].bool ?? false }

    func loadAccount(cached: Bool = false) async {
        if let a = try? await yt("/account", fresh: !cached) { account = a }
        if let p = try? await yt("/playlist?id=LM&limit=5000", ttl: 0, fresh: true, persist: false) {
            liked = Set(p["tracks"].array.compactMap { $0["videoId"].string })
        }
    }

    func toggleLike(_ t: Track?) async {
        guard let t else { return }
        let on = !liked.contains(t.id)
        if on { liked.insert(t.id) } else { liked.remove(t.id) }
        if on && Store.get("auto-liked", false) { Offline.shared.download([t]) }
        do {
            _ = try await yt("/rate", body: ["videoId": .str(t.id), "rating": on ? "LIKE" : "INDIFFERENT", "track": JSON.encode(t.plain)])
            Toast.show(on ? "Ajouté aux titres J'aime" : "Retiré des titres J'aime", .ok)
        } catch {
            if on { liked.remove(t.id) } else { liked.insert(t.id) }
            Toast.show(error.localizedDescription, .err)
        }
    }

    // MARK: playlists Music
    private func call(_ path: String, method: String = "GET", body: JSON? = nil) async throws -> JSON {
        try await API.shared.raw("/api/mpl" + path, method: method, body: body)
    }
    private func changed() {
        NotificationCenter.default.post(name: .musicStale, object: "mpl")
        Task { await refreshMine() }
    }
    @discardableResult func refreshMine() async -> [MPL] {
        if let d = try? await call(""), let l = d.decode([MPL].self) { mine = l; Store.set("mpl.list", l) }
        return mine
    }
    func mpl(_ id: String) async throws -> MPL {
        let d = try await call("/\(id)")
        guard let p = d.decode(MPL.self) else { throw APIError(code: 0, message: "playlist illisible") }
        Store.set("mpl.\(id)", p)
        return p
    }
    func cachedMpl(_ id: String) -> MPL? { Store.get("mpl.\(id)", MPL?.none) }
    @discardableResult func create(_ title: String, _ ts: [Track] = []) async throws -> MPL {
        let d = try await call("", method: "POST", body: ["title": .str(title), "tracks": JSON.encode(ts.map(\.plain))])
        changed()
        return d.decode(MPL.self)!
    }
    func update(_ id: String, _ patch: JSON) async throws { _ = try await call("/\(id)", method: "PATCH", body: patch); changed() }
    func remove(_ id: String) async throws { _ = try await call("/\(id)", method: "DELETE"); changed() }
    func add(_ id: String, _ ts: [Track]) async throws { _ = try await call("/\(id)/tracks", method: "POST", body: ["tracks": JSON.encode(ts.map(\.plain))]); changed() }
    func removeTracks(_ id: String, _ keys: [String]) async throws { _ = try await call("/\(id)/remove", method: "POST", body: ["keys": .arr(keys.map { .str($0) })]); changed() }
    func cover(_ id: String, jpeg: Data) async throws {
        _ = try await call("/\(id)/cover", method: "POST", body: ["image": .str("data:image/jpeg;base64," + jpeg.base64EncodedString())]); changed()
    }

    func refreshYtPlaylists() async {
        if let l = try? await yt("/library/playlists") { ytPlaylists = l.array }
    }
}

/// Playlists automatiques calculées sur l'historique (« Pour toi »).
func smartLists(fresh: Bool = false) async -> [JSON] {
    let r = (try? await yt("/history/smart", ttl: 300, fresh: fresh)) ?? [:]
    return r["items"].array.filter { $0["tracks"].array.count >= 3 }
}
func smartTracks(_ p: JSON) -> [Track] { p["tracks"].array.compactMap { track($0) } }
