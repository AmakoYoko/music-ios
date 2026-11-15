import CoreSpotlight
import UniformTypeIdentifiers

/// Recherche de l'iPhone : titres téléchargés et récemment écoutés, playlists Music, albums et playlists téléchargés.
@MainActor enum Spotlight {
    private static var pending: Task<Void, Never>?

    /// Réindexation regroupée (plusieurs changements d'affilée = une seule passe).
    static func schedule() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await index()
        }
    }

    private static func item(_ id: String, _ title: String, _ sub: String, _ type: UTType, keywords: [String] = []) -> CSSearchableItem {
        let a = CSSearchableItemAttributeSet(contentType: type)
        a.title = title
        a.contentDescription = sub
        a.keywords = keywords + ["Music"]
        return CSSearchableItem(uniqueIdentifier: id, domainIdentifier: "music", attributeSet: a)
    }

    private static func index() async {
        var seen = Set<String>(), items: [CSSearchableItem] = []
        for t in Offline.shared.tracks + Store.get("recent", [Track]()) where seen.insert(t.id).inserted && !t.isLive {
            let sub = [t.artistLine, t.album?.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            items.append(item("t:\(t.id)", t.title, sub, .audio, keywords: t.artists.map(\.name)))
        }
        for m in Library.shared.mine { items.append(item("h:#/mpl/\(m.id)", m.title, "Playlist Music", .playlist)) }
        for c in Offline.shared.collections { if let h = c.meta.href { items.append(item("h:\(h)", c.meta.title, "Téléchargé", .playlist)) } }
        let idx = CSSearchableIndex.default()
        try? await idx.deleteSearchableItems(withDomainIdentifiers: ["music"])
        try? await idx.indexSearchableItems(items)
    }

    /// Résultat touché dans la recherche de l'iPhone.
    static func open(_ ua: NSUserActivity) {
        guard let id = ua.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
        if id.hasPrefix("h:") { Router.shared.open(href: String(id.dropFirst(2))); return }
        guard id.hasPrefix("t:") else { return }
        let tid = String(id.dropFirst(2)), off = Offline.shared.tracks
        if !Offline.shared.online, let i = off.firstIndex(where: { $0.id == tid }) {
            Player.shared.playList(off, at: i, source: Source(title: "Téléchargés", href: "#/downloads"))
        } else if let t = off.first(where: { $0.id == tid }) ?? Store.get("recent", [Track]()).first(where: { $0.id == tid }) {
            Player.shared.playRadio(t)
        } else { return }
        Router.shared.nowPlaying = true
    }
}
