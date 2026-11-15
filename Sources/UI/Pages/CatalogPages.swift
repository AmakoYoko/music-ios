import SwiftUI

// MARK: recherche

struct SearchPage: View {
    @State private var query = ""
    @State private var suggestions: [String] = []
    @State private var history = Store.get("searches", [String]())
    var body: some View {
        Page(title: "Recherche") {
            if query.isEmpty {
                if !history.isEmpty {
                    H2(title: "Recherches récentes")
                    FlowChips(items: Array(history.prefix(12))) { go($0) }
                }
                Loader(load: { try await yt("/moods") }) { moods, _ in
                    ForEach(moods.object.keys.sorted(), id: \.self) { k in H2(title: k); MoodGrid(list: moods[k].array) }
                }
            } else {
                ForEach(suggestions.prefix(8), id: \.self) { s in
                    Button { go(s) } label: { Label(s, systemImage: "magnifyingglass").frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10) }
                        .buttonStyle(.plain)
                    Divider()
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Artistes, titres, paroles…")
        .onSubmit(of: .search) { go(query) }
        .task(id: query) {
            let v = query.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { suggestions = []; return }
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled, let l = try? await yt("/suggest" + q(["q": v])) else { return }
            suggestions = l.array.compactMap(\.string)
        }
        .onAppear { history = Store.get("searches", [String]()) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button { Router.shared.listening = true } label: { Image(systemName: "waveform") }.accessibilityLabel("Quel est ce titre ?") }
        }
    }
    private func go(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        if let u = Links.looksLikeLink(t), Links.open(u) { query = ""; return }
        Router.shared.open(.search(t, ""))
    }
}

struct FlowChips: View {
    var items: [String]
    var on: String? = nil
    var tap: (String) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { s in
                    Button(s) { tap(s) }
                        .font(.subheadline).padding(.horizontal, 14).padding(.vertical, 7)
                        .background(s == on ? Color.accent : Color(.secondarySystemFill), in: Capsule())
                        .foregroundStyle(s == on ? .white : .primary)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
    }
}

struct SearchResults: View {
    var term: String
    @State var filter: String
    static let FILTERS = [("", "Tout"), ("songs", "Morceaux"), ("albums", "Albums"), ("artists", "Artistes"), ("playlists", "Playlists"), ("community_playlists", "Playlists publiques"), ("videos", "Clips")]
    var body: some View {
        Page(title: "« \(term) »", large: false) {
            FlowChips(items: Self.FILTERS.map(\.1), on: Self.FILTERS.first { $0.0 == filter }?.1) { l in filter = Self.FILTERS.first { $0.1 == l }?.0 ?? "" }
                .padding(.vertical, 8)
            Loader(load: { try await yt("/search" + q(["q": term, "filter": filter, "limit": filter.isEmpty ? 20 : 40])) }) { res, _ in
                results(res.array)
            }
            .id(filter)
        }
        .onAppear {
            var h = Store.get("searches", [String]()).filter { $0 != term }
            h.insert(term, at: 0)
            Store.set("searches", Array(h.prefix(20)))
        }
    }

    @ViewBuilder func results(_ res: [JSON]) -> some View {
        if res.isEmpty { EmptyState(icon: "magnifyingglass", title: "Aucun résultat", text: "Rien trouvé pour « \(term) ».") }
        else if filter == "songs" || filter == "videos" { TrackList(tracks: res.compactMap { track($0) }, opts: ListOpts(single: true)) }
        else if !filter.isEmpty { TileGrid(items: res).padding(.top, 6) }
        else {
            let top = res.first { $0["category"].string == "Top result" }
            let rest = res.filter { $0 != top }
            let groups = Dictionary(grouping: rest) { $0["resultType"].string ?? "" }
            if let top { TopResult(top: top, songs: Array((groups["song"] ?? []).compactMap { track($0) }.prefix(4))) }
            ForEach([("song", "Morceaux", "songs"), ("album", "Albums", "albums"), ("artist", "Artistes", "artists"), ("playlist", "Playlists", "playlists"), ("video", "Clips", "videos")], id: \.0) { type, label, f in
                if let list = groups[type], !list.isEmpty {
                    H2(title: label, link: .search(term, f))
                    if type == "song" || type == "video" { TrackList(tracks: list.compactMap { track($0) }, opts: ListOpts(single: true)) }
                    else { Shelf(items: list) }
                }
            }
        }
    }
}

struct TopResult: View {
    var top: JSON
    var songs: [Track]
    var body: some View {
        let k = kindOf(top)
        let label: String = { switch k { case .artist: "Artiste"; case .album: "Album"; case .song: top["resultType"].string == "video" ? "Clip" : "Morceau"; case .playlist: "Playlist"; default: "" } }()
        let isArtist: Bool = { if case .artist = k { return true }; return false }()
        H2(title: "Meilleur résultat")
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                RemoteImage(url: absURL(img(top["thumbnails"], 300))).frame(width: 96, height: 96)
                    .clipShape(isArtist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(top["title"].string ?? top["artist"].string ?? top["artists"][0]["name"].string ?? "").font(.title3.bold()).lineLimit(2)
                    Text(label + (!isArtist && top["artists"].exists ? " · " + top["artists"].array.compactMap { $0["name"].string }.joined(separator: ", ") : "")).font(.subheadline).foregroundStyle(.secondary)
                    HStack {
                        Button { Task { await playCollection(top, k) } } label: { Label("Lire", systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                        if k != .song { Button { Task { await playCollection(top, k, shuffle: true) } } label: { Label("Aléatoire", systemImage: "shuffle") }.buttonStyle(.bordered) }
                    }
                    .tint(.accent).controlSize(.small)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                switch k {
                case .song: if let t = track(top) { Player.shared.playRadio(t) }
                case .album(let id): Router.shared.open(.album(id))
                case .artist(let id): Router.shared.open(.artist(id))
                case .playlist(let id): Router.shared.open(.playlist(id))
                default: break
                }
            }
            if !songs.isEmpty { TrackList(tracks: songs, opts: ListOpts(single: true)) }
        }
        .padding(14).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: album, playlist, artiste

struct AlbumPage: View {
    var id: String
    var body: some View {
        Loader(load: { try await yt("/album" + q(["id": id])) }) { a, reload in
            let ctx = TrackCtx(album: AlbumRef(name: a["title"].string ?? "", id: id), thumbs: a["thumbnails"], artists: a["artists"].decode([Artist].self))
            let ts = parseTracks(a["tracks"], ctx).map { var t = $0; t.album = AlbumRef(name: a["title"].string ?? "", id: id); return t }
            let src = Source(title: a["title"].string, href: "#/album/\(id)")
            let meta = [a["type"].string, a["year"].string, a["trackCount"].int.map { nt($0) }, a["duration"].string].compactMap { $0 }.joined(separator: " · ")
            Page(title: a["title"].string ?? "", large: false, refresh: { await reload() }) {
                Hero(d: HeroData(art: img(a["thumbnails"], 800), title: a["title"].string ?? "", by: a["artists"].decode([Artist].self) ?? [], meta: meta, desc: a["description"].string),
                     tracks: ts, source: src, key: "album:\(id)", playlistId: a["audioPlaylistId"].string, likeStatus: a["likeStatus"].string) { EmptyView() }
                TrackList(tracks: ts, opts: ListOpts(numbered: true, source: src))
                if !a["other_versions"].array.isEmpty { H2(title: "Autres versions"); Shelf(items: a["other_versions"].array) }
                if let aid = a["artists"][0]["id"].string { MoreFromArtist(artistId: aid, exclude: id) }
            }
        }
    }
}

struct MoreFromArtist: View {
    var artistId: String, exclude: String
    @State private var ar: JSON?
    var body: some View {
        Group {
            if let ar {
                let more = ar["albums"]["results"].array.filter { $0["browseId"].string != exclude }
                if !more.isEmpty { H2(title: "Plus de \(ar["name"].string ?? "")", link: .artist(artistId), label: "Voir l'artiste"); Shelf(items: more) }
            }
        }
        .task { ar = try? await yt("/artist" + q(["id": artistId])) }
    }
}

struct PlaylistPage: View {
    var id: String
    var body: some View {
        Loader(load: { try await yt("/playlist" + q(["id": id]), ttl: 60) }, watch: ["/playlist"]) { p, reload in
            let title = id == "LM" ? "Titres J'aime" : p["title"].string ?? ""
            let ts = parseTracks(p["tracks"])
            let src = Source(title: title, href: "#/playlist/\(id)")
            let owned = p["owned"].bool ?? false
            let author = p["author"]["name"].string ?? p["author"][0]["name"].string
            let meta = [author, p["year"].string, p["trackCount"].int.map { nt($0) }, p["duration"].string].compactMap { $0 }.joined(separator: " · ")
            Page(title: title, large: false, refresh: { await reload() }) {
                Hero(d: HeroData(art: img(p["thumbnails"], 800), cover: id == "LM" ? AnyView(LikedCover()) : nil, title: title, meta: meta, desc: p["description"].string),
                     tracks: ts, source: src, key: "playlist:\(id)", playlistId: id, rateable: id != "LM" && !owned, likeStatus: p["likeStatus"].string) {
                    Button {
                        Task {
                            do {
                                let n = try await Library.shared.create(title, ts)
                                Toast.show("« \(title) » copiée dans tes playlists", .ok, action: "Ouvrir") { Router.shared.open(.mpl(n.id)) }
                            } catch { Toast.show(error.localizedDescription, .err) }
                        }
                    } label: { Label("Copier dans mes playlists", systemImage: "doc.on.doc") }
                    if owned {
                        Button { renameYt(title) } label: { Label("Renommer", systemImage: "pencil") }
                        Button(role: .destructive) {
                            Router.shared.confirm = Confirm(title: "Supprimer la playlist ?", message: "« \(title) » sera supprimée de YouTube Music.", ok: "Supprimer") {
                                Task { _ = try? await yt("/playlists/\(id)", method: "DELETE"); NotificationCenter.default.post(name: .musicPlaylists, object: nil); Router.shared.paths[Router.shared.tab]?.removeLast() }
                            }
                        } label: { Label("Supprimer la playlist", systemImage: "trash") }
                    }
                }
                if ts.isEmpty { EmptyState(icon: "music.note.list", title: "Playlist vide") }
                else { TrackList(tracks: ts, opts: ListOpts(source: src, playlistId: owned ? id : nil, onRemoved: { Task { await reload() } })) }
                if !p["related"].array.isEmpty { H2(title: "Playlists similaires"); Shelf(items: p["related"].array) }
            }
        }
    }
    private func renameYt(_ old: String) {
        Prompt.ask("Renommer la playlist", value: old, ok: "Renommer") { t in
            Task {
                do { _ = try await yt("/playlists/\(id)", method: "PATCH", body: ["title": .str(t)]); NotificationCenter.default.post(name: .musicStale, object: "/playlist") }
                catch { Toast.show(error.localizedDescription, .err) }
            }
        }
    }
}

struct ArtistPage: View {
    var id: String
    var body: some View {
        Loader(load: { try await yt("/artist" + q(["id": id])) }) { a, reload in
            ArtistBody(id: id, a: a, reload: reload)
        }
    }
}

struct ArtistBody: View {
    var id: String
    var a: JSON
    var reload: () async -> Void
    @State private var subscribed: Bool?
    var body: some View {
        let name = a["name"].string ?? ""
        let sub = subscribed ?? (a["subscribed"].bool ?? false)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(url: absURL(img(a["thumbnails"], 1200))).frame(height: 360).frame(maxWidth: .infinity).clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name).font(.largeTitle.bold()).foregroundStyle(.white)
                            Text(listeners).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                        }
                        Spacer()
                        Button { Task { await toggleSub(sub) } } label: { Label(sub ? "Abonné" : "S'abonner", systemImage: sub ? "person.fill.checkmark" : "person.badge.plus") }
                            .buttonStyle(.bordered).tint(.white).controlSize(.small)
                        Button { Task { await playCollection(["browseId": .str(id), "resultType": "artist"], .artist(id)) } } label: {
                            Image(systemName: "play.fill").font(.title3).foregroundStyle(.white).frame(width: 50, height: 50).background(Color.accent, in: Circle())
                        }
                        .accessibilityLabel("Lire la radio de l'artiste")
                    }
                    .padding(16)
                }
                .padding(.bottom, 4)
                VStack(alignment: .leading, spacing: 0) {
                    let songs = parseTracks(a["songs"]["results"])
                    if !songs.isEmpty {
                        H2(title: "Top titres", link: a["songs"]["browseId"].string.map { .playlist(String($0.hasPrefix("VL") ? $0.dropFirst(2) : Substring($0))) })
                        TrackList(tracks: songs, opts: ListOpts(source: Source(title: name, href: "#/artist/\(id)")))
                    }
                    ForEach([("albums", "Albums"), ("singles", "Singles et EP"), ("videos", "Clips"), ("playlists", "Playlists"), ("related", "Artistes similaires")], id: \.0) { key, label in
                        let sec = a[key]
                        if !sec["results"].array.isEmpty {
                            let link: Route? = sec["params"].string != nil && sec["browseId"].string != nil ? .discography(sec["browseId"].string!, sec["params"].string!, "\(name) · \(label)")
                                : key == "videos" ? sec["browseId"].string.map { .playlist(String($0.hasPrefix("VL") ? $0.dropFirst(2) : Substring($0))) } : nil
                            H2(title: label, link: link)
                            Shelf(items: sec["results"].array, wide: key == "videos")
                        }
                    }
                    if let d = a["description"].string, !d.isEmpty {
                        H2(title: "À propos de \(name)")
                        Text(d).font(.subheadline).foregroundStyle(.secondary).padding(16).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 120)
            }
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .refreshable { await reload() }
    }
    private var listeners: String {
        if let m = a["monthlyListeners"].string { return m.contains("auditeur") ? m.replacingOccurrences(of: "auditeurs/mois", with: "auditeurs par mois") : "\(m) auditeurs par mois" }
        if let s = a["subscribers"].string { return "\(s) abonnés" }
        return ""
    }
    private func toggleSub(_ on: Bool) async {
        do {
            _ = try await yt("/subscribe", body: ["channelId": .str(a["channelId"].string ?? id), "on": .bool(!on)])
            subscribed = !on
            Toast.show(!on ? "Abonné à \(a["name"].string ?? "")" : "Abonnement retiré", .ok)
        } catch { Toast.show(error.localizedDescription, .err) }
    }
}
