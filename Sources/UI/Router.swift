import Observation
import SwiftUI

enum Route: Hashable {
    case album(String), artist(String), playlist(String), mpl(String), smart(String)
    case mood(String, String), discography(String, String, String)
    case stats(Int), radio, settings, search(String, String), library(String), downloads

    /// Adresse de la PWA (« #/album/ID ») → page native : les sources partagées entre appareils restent compatibles.
    init?(href: String?) {
        guard var h = href, h.hasPrefix("#/") else { return nil }
        h.removeFirst(2)
        let parts = h.split(separator: "?", maxSplits: 1)
        let path = parts.first.map(String.init) ?? ""
        let qs = URLComponents(string: "?" + (parts.count > 1 ? String(parts[1]) : ""))?.queryItems ?? []
        func qv(_ k: String) -> String? { qs.first { $0.name == k }?.value }
        let seg = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        switch seg.first {
        case "album": self = .album(seg[safe: 1] ?? "")
        case "artist": self = .artist(seg[safe: 1] ?? "")
        case "playlist": self = .playlist(seg[safe: 1] ?? "")
        case "mpl": self = .mpl(seg[safe: 1] ?? "")
        case "smart": self = .smart(seg[safe: 1] ?? "")
        case "mood": self = .mood(seg[safe: 1] ?? "", qv("t") ?? "Ambiance")
        case "discography": self = .discography(seg[safe: 1] ?? "", seg[safe: 2] ?? "", qv("t") ?? "Discographie")
        case "stats": self = .stats(Int(qv("d") ?? "30") ?? 30)
        case "radio": self = .radio
        case "settings": self = .settings
        case "search": self = .search(qv("q") ?? "", qv("f") ?? "")
        case "library": self = .library(seg[safe: 1] ?? "playlists")
        case "downloads": self = .downloads
        case "liked": self = .playlist("LM")
        default: return nil
        }
    }
}

enum Tab: Hashable { case home, explore, library, downloads, search }

@MainActor @Observable final class Router {
    static let shared = Router()
    var tab: Tab = .home
    var paths: [Tab: NavigationPath] = [.home: .init(), .explore: .init(), .library: .init(), .downloads: .init(), .search: .init()]
    var nowPlaying = false
    var listening = false
    var sheet: Sheet?
    var confirm: Confirm?

    func open(_ r: Route) {
        nowPlaying = false
        switch r {
        case .downloads where paths[.downloads]?.isEmpty ?? true: tab = .downloads
        default: paths[tab, default: .init()].append(r)
        }
    }
    func open(href: String?) { if let r = Route(href: href) { open(r) } }
    func binding(_ t: Tab) -> Binding<NavigationPath> {
        Binding(get: { self.paths[t] ?? .init() }, set: { self.paths[t] = $0 })
    }
}

@ViewBuilder func destination(_ r: Route) -> some View {
    switch r {
    case .album(let id): AlbumPage(id: id)
    case .artist(let id): ArtistPage(id: id)
    case .playlist(let id): PlaylistPage(id: id)
    case .mpl(let id): MplPage(id: id)
    case .smart(let id): SmartPage(id: id)
    case .mood(let p, let t): MoodPage(params: p, title: t)
    case .discography(let id, let p, let t): DiscographyPage(id: id, params: p, title: t)
    case .stats(let d): StatsPage(days: d)
    case .radio: RadioPage()
    case .settings: SettingsPage()
    case .search(let q, let f): SearchResults(term: q, filter: f)
    case .library(let t): LibraryPage(tab: t)
    case .downloads: DownloadsPage()
    }
}

/// Fenêtres ouvertes par-dessus tout (menus des titres, lecteur…).
enum Sheet: Identifiable {
    case addTo([Track]), versions(Track), editMpl(MPL), devices, eq, newPlaylist([Track])
    var id: String {
        switch self {
        case .addTo(let t): "add" + t.map(\.id).joined()
        case .versions(let t): "v" + t.id
        case .editMpl(let p): "e" + p.id
        case .devices: "devices"
        case .eq: "eq"
        case .newPlaylist: "new"
        }
    }
}

extension Router {
    func present(_ s: Sheet) { sheet = s }
}

/// Confirmation (« Supprimer la playlist ? »…).
struct Confirm: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var ok: String
    var danger = true
    var run: () -> Void
}
