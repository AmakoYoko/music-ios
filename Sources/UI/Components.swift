import SwiftUI

// MARK: en-têtes

struct H2: View {
    var title: String
    var link: Route? = nil
    var label = "Tout voir"
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.bold())
            Spacer()
            if let link { Button(label) { Router.shared.open(link) }.font(.subheadline) }
        }
        .padding(.top, 22).padding(.bottom, 8)
    }
}

struct Kicker: View {
    var text: String
    var body: some View { Text(text.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 18) }
}

struct EmptyState: View {
    var icon: String, title: String, text: String = ""
    var action: (String, () -> Void)? = nil
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            if !text.isEmpty { Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            if let action { Button(action.0, action: action.1).buttonStyle(.borderedProminent).padding(.top, 6) }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 50).padding(.horizontal, 24)
    }
}

/// Bannière hors ligne.
struct OfflineBanner: View {
    @State private var off = Offline.shared
    var body: some View {
        if !off.online {
            Label("Hors ligne : seuls les titres téléchargés peuvent être lus.", systemImage: "wifi.slash")
                .font(.subheadline).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: pochettes générées

struct GradientCover: View {
    var a: String, b: String
    var icon: String = "music.note"
    var title: String
    var sub: String = "Music"
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [Color(hex: a), Color(hex: b)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: icon).font(.system(size: g.size.width * 0.22, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(g.size.width * 0.09)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: max(11, g.size.width * 0.1), weight: .bold)).lineLimit(2)
                    Text(sub).font(.system(size: max(9, g.size.width * 0.065))).opacity(0.8)
                }
                .foregroundStyle(.white).padding(g.size.width * 0.09)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

let SMART_PAL: [String: (String, String)] = ["mix": ("#bf5af2", "#ff375f"), "liked": ("#ff2d55", "#ff9f0a"), "repeat": ("#fa2d48", "#ff8a5c"), "month": ("#ff9f0a", "#ffd60a"), "new": ("#5e5ce6", "#bf5af2"), "forgotten": ("#30b0c7", "#34c759")]

/// Icônes Lucide de la PWA → SF Symbols.
func sfSymbol(_ lucide: String?) -> String {
    ["sparkles": "sparkles", "heart": "heart.fill", "repeat": "repeat", "calendar": "calendar", "flame": "flame.fill", "history": "clock.arrow.circlepath",
     "star": "star.fill", "music": "music.note", "zap": "bolt.fill", "moon": "moon.fill", "sun": "sun.max.fill", "rewind": "backward.fill",
     "trending-up": "chart.line.uptrend.xyaxis", "radio": "dot.radiowaves.left.and.right", "disc-3": "opticaldisc", "gem": "diamond.fill"][lucide ?? ""] ?? "music.note"
}

struct SmartCover: View {
    var p: JSON
    var body: some View {
        let pal = SMART_PAL[p["id"].string ?? ""] ?? ("#0a84ff", "#64d2ff")
        GradientCover(a: pal.0, b: pal.1, icon: sfSymbol(p["icon"].string), title: p["title"].string ?? "", sub: "Pour toi")
    }
}

struct LikedCover: View { var body: some View { GradientCover(a: "#ff2d55", b: "#bf5af2", icon: "heart.fill", title: "Titres J'aime") } }

/// Miniature d'une playlist Music : image envoyée, dégradé avec titre, ou mosaïque des pochettes.
struct MplCover: View {
    var p: MPL
    var style: String? = nil
    var palette: Int? = nil
    var image: UIImage? = nil
    var body: some View {
        let st = style ?? p.cover?.style ?? "mosaic"
        let th = (p.thumbs ?? Array(Set((p.tracks ?? []).map(\.thumb).filter { !$0.isEmpty })).prefix(4).map { $0 })
        let pal = PALETTES[(palette ?? p.cover?.palette ?? 0) % PALETTES.count]
        Group {
            if st == "image", let image { Image(uiImage: image).resizable().scaledToFill() }
            else if st == "image", let v = p.cover?.version { RemoteImage(url: absURL("/api/mpl/\(p.id)/cover.jpg?v=\(Int(v))")) }
            else if st == "mosaic" && th.count >= 4 {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow { RemoteImage(url: absURL(th[0])); RemoteImage(url: absURL(th[1])) }
                    GridRow { RemoteImage(url: absURL(th[2])); RemoteImage(url: absURL(th[3])) }
                }
            } else if st == "mosaic", let f = th.first { RemoteImage(url: absURL(f)) }
            else { GradientCover(a: pal.0, b: pal.1, title: p.title) }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipped()
    }
}

// MARK: tuiles

struct Tile: View {
    var it: JSON
    var wide = false
    var sub: String? = nil
    var width: CGFloat? = 150
    var body: some View {
        let k = kindOf(it)
        let round: Bool = { if case .artist = k { return true }; return false }()
        Button { open(k) } label: {
            VStack(alignment: round ? .center : .leading, spacing: 6) {
                ZStack {
                    if case .playlist = k, img(it["thumbnails"].exists ? it["thumbnails"] : it["thumbnail"]).isEmpty {
                        let t = itemTitle(it)
                        let pal = PALETTES[t.unicodeScalars.reduce(0) { $0 + Int($1.value) } % PALETTES.count]
                        GradientCover(a: pal.0, b: pal.1, title: t)
                    } else {
                        RemoteImage(url: absURL(img(it["thumbnails"].exists ? it["thumbnails"] : it["thumbnail"], wide ? 640 : 400)))
                    }
                }
                .aspectRatio(wide ? 16 / 9 : 1, contentMode: .fill)
                .frame(width: width.map { wide ? $0 * 1.6 : $0 })
                .clipShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous)))
                Text(itemTitle(it)).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
                Text(sub ?? subtitle(it)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: width.map { wide ? $0 * 1.6 : $0 })
        }
        .buttonStyle(.plain)
        .contextMenu {
            if case .song = k, let t = track(it) { TrackMenuItems(t: t) }
            else if k != .other && k != .podcast {
                Button { Task { await playCollection(it, k) } } label: { Label("Lire", systemImage: "play.fill") }
                Button { Task { await playCollection(it, k, shuffle: true) } } label: { Label("Aléatoire", systemImage: "shuffle") }
            }
        }
    }
    private func open(_ k: Kind) {
        switch k {
        case .song: if let t = track(it) { Player.shared.playRadio(t) }
        case .album(let id): Router.shared.open(.album(id))
        case .artist(let id): Router.shared.open(.artist(id))
        case .playlist(let id): Router.shared.open(.playlist(id))
        default: break
        }
    }
}

@MainActor func playCollection(_ it: JSON, _ k: Kind, shuffle: Bool = false) async {
    do {
        switch k {
        case .song: if let t = track(it) { Player.shared.playRadio(t) }
        case .album(let id):
            let a = try await yt("/album" + q(["id": it["browseId"].string ?? id]))
            let ts = parseTracks(a["tracks"], TrackCtx(album: AlbumRef(name: a["title"].string ?? "", id: a["audioPlaylistId"].string), thumbs: a["thumbnails"], artists: a["artists"].decode([Artist].self)))
            Player.shared.playList(ts, source: Source(title: a["title"].string, href: "#/album/\(id)"), shuffle: shuffle)
        case .playlist(let pid):
            let p = try await yt("/playlist" + q(["id": pid]))
            Player.shared.playList(parseTracks(p["tracks"]), source: Source(title: p["title"].string, href: "#/playlist/\(pid)"), shuffle: shuffle)
        case .artist(let id):
            let a = try await yt("/artist" + q(["id": id]))
            let w = try await yt("/watch" + q(["playlistId": shuffle ? a["shuffleId"].string : a["radioId"].string ?? a["shuffleId"].string, "limit": 50]))
            Player.shared.playList(parseTracks(w["tracks"]), source: Source(title: a["name"].string, href: "#/artist/\(id)"))
        default: break
        }
    } catch { Toast.show(error.localizedDescription, .err) }
}

struct Shelf: View {
    var items: [JSON]
    var wide = false
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in Tile(it: it, wide: wide) }
            }
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
    }
}

struct TileGrid: View {
    var items: [JSON]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in Tile(it: it, width: nil) }
        }
    }
}

struct MoodGrid: View {
    var list: [JSON]
    static let colors = ["#fa2d48", "#ff9f0a", "#30b0c7", "#5e5ce6", "#34c759", "#bf5af2", "#ff375f", "#64d2ff", "#ac8e68", "#0a84ff", "#ff6b35", "#32ade6"]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            ForEach(Array(list.enumerated()), id: \.offset) { i, m in
                Button { Router.shared.open(.mood(m["params"].string ?? "", m["title"].string ?? "")) } label: {
                    Text(m["title"].string ?? "").font(.headline).foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 64, alignment: .bottomLeading)
                        .padding(12).background(Color(hex: Self.colors[i % Self.colors.count]), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Rayon d'accueil : carrousel de tuiles, ou liste de titres s'il ne contient que des morceaux.
struct SectionView: View {
    var sec: JSON
    var body: some View {
        let items = (sec["contents"].exists ? sec["contents"] : sec["items"].exists ? sec["items"] : sec["results"]).array.filter(\.exists)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if let k = sec["kicker"].string { Kicker(text: k) }
                H2(title: sec["title"].string ?? "", link: Route(href: sec["link"]["href"].string ?? sec["link"].string))
                if let d = sec["desc"].string { Text(d).font(.subheadline).foregroundStyle(.secondary).padding(.top, -4).padding(.bottom, 8) }
                if items.allSatisfy({ kindOf($0) == .song }) {
                    let ts = items.compactMap { track($0) }
                    SongGrid(tracks: Array(ts.prefix(12)))
                } else {
                    Shelf(items: items, wide: items.allSatisfy { $0["videoId"].exists && ($0["videoType"].string ?? "").range(of: "VIDEO_TYPE_(OMV|UGC)", options: .regularExpression) != nil })
                }
            }
        }
    }
}

/// Titres en colonnes de 4, défilant à l'horizontale (façon « Sélection rapide »).
struct SongGrid: View {
    var tracks: [Track]
    var body: some View {
        let cols = stride(from: 0, to: tracks.count, by: 4).map { Array(tracks[$0..<min($0 + 4, tracks.count)]) }
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(Array(cols.enumerated()), id: \.offset) { _, col in
                    VStack(spacing: 0) { ForEach(col) { t in TrackRow(t: t, single: true).frame(width: 300) } }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
        .onAppear { Warm.add(Array(tracks.prefix(4))) }
    }
}

/// Le serveur prépare les flux des titres restés visibles (~1 s) : un toucher = lecture immédiate.
enum Warm {
    @MainActor private static var warmed = Set<String>()
    @MainActor private static var batch: [String] = []
    @MainActor private static var task: Task<Void, Never>?
    @MainActor static func add(_ ts: [Track]) {
        let ids = ts.filter { !$0.isLive && !warmed.contains($0.id) && !Offline.shared.has($0.id) }.map(\.id)
        guard !ids.isEmpty else { return }
        ids.forEach { warmed.insert($0) }
        batch += ids
        task?.cancel()
        task = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let b = batch; batch = []
            _ = try? await yt("/prefetch", body: ["ids": .arr(b.map { .str($0) })])
        }
    }
}
