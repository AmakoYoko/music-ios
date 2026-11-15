import SwiftUI

struct ListOpts {
    var numbered = false
    var single = false
    var source: Source? = nil
    var playlistId: String? = nil // playlist YouTube dont on est propriétaire : « Retirer »
    var mpl: String? = nil        // playlist Music modifiable : « Retirer »
    var onRemoved: (() -> Void)? = nil
}

/// Ligne de titre : toucher = lire, glisser à droite = lire ensuite, à gauche = ajouter à la file, appui long / « … » = menu.
struct TrackRow: View {
    var t: Track
    var index: Int = 0
    var list: [Track]? = nil
    var opts = ListOpts()
    var single = false
    @State private var player = Player.shared
    @State private var off = Offline.shared
    @State private var lib = Library.shared
    @State private var dx: CGFloat = 0

    var body: some View {
        let playing = player.current?.id == t.id
        HStack(spacing: 12) {
            ZStack {
                if opts.numbered {
                    if playing { EqBars(playing: player.playing) } else { Text("\(index + 1)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
                } else {
                    RemoteImage(url: t.thumbURL).frame(width: 46, height: 46).cardShape(5)
                    if playing { Color.black.opacity(0.35).cardShape(5); EqBars(playing: player.playing) }
                }
            }
            .frame(width: opts.numbered ? 28 : 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(t.title).lineLimit(1).foregroundStyle(playing ? Color.accent : t.available ? .primary : .secondary)
                    if t.explicit { Text("E").font(.system(size: 9, weight: .bold)).padding(.horizontal, 3).background(.secondary.opacity(0.3), in: RoundedRectangle(cornerRadius: 2)) }
                    if off.has(t.id) { Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(.secondary) }
                    if lib.liked.contains(t.id) { Image(systemName: "heart.fill").font(.caption2).foregroundStyle(Color.accent) }
                }
                Text(t.artistLine.isEmpty ? " " : t.artistLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let job = off.jobs[t.id] { ProgressView(value: job.progress).progressViewStyle(.circular).scaleEffect(0.7) }
            else if let d = t.duration, d > 0 { Text(clock(d)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            Menu { TrackMenuItems(t: t, opts: opts) } label: {
                Image(systemName: "ellipsis").frame(width: 32, height: 40).contentShape(Rectangle())
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .opacity(t.available ? 1 : 0.5)
        .offset(x: dx)
        .background(alignment: dx > 0 ? .leading : .trailing) {
            if dx != 0 {
                Image(systemName: dx > 0 ? "text.line.first.and.arrowtriangle.forward" : "text.line.last.and.arrowtriangle.forward")
                    .foregroundStyle(.white).padding(.horizontal, 18)
                    .frame(maxHeight: .infinity).background(abs(dx) >= 72 ? Color.accent : Color.gray)
            }
        }
        .onTapGesture { tap() }
        .simultaneousGesture(DragGesture(minimumDistance: 18).onChanged { v in
            guard t.available, abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
            dx = max(-120, min(120, v.translation.width))
        }.onEnded { _ in
            defer { withAnimation(.spring(duration: 0.25)) { dx = 0 } }
            guard abs(dx) >= 72 else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if dx > 0 { Player.shared.playNext([t]); Toast.show("Lu ensuite", .ok) } else { Player.shared.addToQueue([t]); Toast.show("Ajouté à la file", .ok) }
        })
        .contextMenu { TrackMenuItems(t: t, opts: opts) } preview: { TrackPreview(t: t) }
        .onAppear { Task { try? await Task.sleep(nanoseconds: 1_000_000_000); Warm.add([t]) } }
    }

    private func tap() {
        guard t.available else { return Toast.show("Titre indisponible", .warn) }
        if single || opts.single || list == nil { return Player.shared.playRadio(t, source: opts.source) }
        let l = list!.filter(\.available)
        Player.shared.playList(l, at: l.firstIndex(of: t) ?? 0, source: opts.source)
    }
}

struct TrackPreview: View {
    var t: Track
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(url: absURL(t.thumb.replacingOccurrences(of: "w120-h120", with: "w544-h544"))).frame(width: 260, height: 260).cardShape(10)
            Text(t.title).font(.headline).lineLimit(2)
            Text([t.artistLine, t.album?.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(14).frame(width: 288)
    }
}

/// Menu d'actions d'un titre (portage de trackMenu).
struct TrackMenuItems: View {
    var t: Track
    var opts = ListOpts()
    @State private var lib = Library.shared
    @State private var off = Offline.shared
    var body: some View {
        Section {
            Button { Player.shared.playNext([t]); Toast.show("Lu ensuite", .ok) } label: { Label("Lire ensuite", systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button { Player.shared.addToQueue([t]); Toast.show("Ajouté à la file", .ok) } label: { Label("Ajouter à la file", systemImage: "text.line.last.and.arrowtriangle.forward") }
            Button { Player.shared.startRadio(t) } label: { Label("Démarrer la radio", systemImage: "dot.radiowaves.left.and.right") }
        }
        Section {
            let liked = lib.liked.contains(t.id)
            Button { Task { await lib.toggleLike(t) } } label: { Label(liked ? "Je n'aime plus" : "J'aime", systemImage: liked ? "heart.slash" : "heart") }
            Button { Router.shared.present(.addTo([t])) } label: { Label("Ajouter à une playlist…", systemImage: "text.badge.plus") }
            Button { Router.shared.present(.versions(t)) } label: { Label("Autres versions…", systemImage: "square.stack.3d.up") }
            if t.feedback?.add != nil || t.feedback?.remove != nil {
                let inLib = t.inLibrary ?? false
                Button {
                    Task {
                        do {
                            _ = try await yt("/library-status", body: ["tokens": [.str((inLib ? t.feedback?.remove : t.feedback?.add) ?? "")]])
                            Toast.show(inLib ? "Retiré de la bibliothèque" : "Ajouté à la bibliothèque", .ok)
                        } catch { Toast.show(error.localizedDescription, .err) }
                    }
                } label: { Label(inLib ? "Retirer de la bibliothèque" : "Ajouter à la bibliothèque", systemImage: inLib ? "trash" : "plus") }
            }
            if let m = opts.mpl, let k = t.key {
                Button(role: .destructive) {
                    Task {
                        do { try await lib.removeTracks(m, [k]); Toast.show("Retiré de la playlist", .ok); opts.onRemoved?() } catch { Toast.show(error.localizedDescription, .err) }
                    }
                } label: { Label("Retirer de cette playlist", systemImage: "trash") }
            }
            if let pid = opts.playlistId, let sv = t.setVideoId {
                Button(role: .destructive) {
                    Task {
                        do {
                            _ = try await yt("/playlists/\(pid)/remove", body: ["videos": [["videoId": .str(t.id), "setVideoId": .str(sv)]]])
                            Toast.show("Retiré de la playlist", .ok); opts.onRemoved?()
                        } catch { Toast.show(error.localizedDescription, .err) }
                    }
                } label: { Label("Retirer de cette playlist", systemImage: "trash") }
            }
        }
        Section {
            if off.has(t.id) {
                Button(role: .destructive) { off.remove(t.id) } label: { Label("Supprimer le téléchargement", systemImage: "trash") }
            } else {
                Button { off.download([t]); Toast.show("Téléchargement lancé", .ok) } label: { Label("Télécharger", systemImage: "arrow.down.circle") }
            }
            if let a = t.album?.id { Button { Router.shared.open(.album(a)) } label: { Label("Voir l'album", systemImage: "opticaldisc") } }
            if let a = t.artists.first, let id = a.id { Button { Router.shared.open(.artist(id)) } label: { Label("Voir \(a.name)", systemImage: "music.mic") } }
            ShareLink(item: URL(string: "https://music.youtube.com/watch?v=\(t.id)")!) { Label("Partager", systemImage: "square.and.arrow.up") }
            Button { UIPasteboard.general.string = "https://music.youtube.com/watch?v=\(t.id)"; Toast.show("Lien copié", .ok) } label: { Label("Copier le lien", systemImage: "link") }
        }
    }
}

struct TrackList: View {
    var tracks: [Track]
    var opts = ListOpts()
    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                TrackRow(t: t, index: i, list: opts.single ? nil : tracks, opts: opts)
                if i < tracks.count - 1 { Divider().padding(.leading, opts.numbered ? 40 : 58) }
            }
        }
        .onAppear { if opts.source != nil && !opts.single { Warm.add(Array(tracks.prefix(5))) } }
    }
}

/// Boutons « Lire » / « Aléatoire ».
struct PlayButtons: View {
    var tracks: [Track]
    var source: Source?
    var body: some View {
        HStack(spacing: 12) {
            Button { Player.shared.playList(tracks, source: source) } label: { Label("Lire", systemImage: "play.fill").frame(maxWidth: .infinity) }
            Button { Player.shared.playList(tracks, source: source, shuffle: true) } label: { Label("Aléatoire", systemImage: "shuffle").frame(maxWidth: .infinity) }
        }
        .buttonStyle(.bordered).controlSize(.large).tint(.accent).fontWeight(.semibold)
    }
}

struct HeroData {
    var art: String? = nil
    var cover: AnyView? = nil
    var title: String
    var by: [Artist] = []
    var meta: String = ""
    var desc: String? = nil
}

/// En-tête album / playlist : pochette, titre, actions (lire, aléatoire, bibliothèque, téléchargement, menu).
struct Hero<MenuContent: View>: View {
    var d: HeroData
    var tracks: [Track]
    var source: Source
    var key: String
    var playlistId: String? = nil
    var rateable = false
    var likeStatus: String? = nil
    var onArtTap: (() -> Void)? = nil
    @ViewBuilder var menu: () -> MenuContent
    @State private var off = Offline.shared
    @State private var liked: Bool?
    @State private var descOpen = false

    var body: some View {
        VStack(spacing: 10) {
            Group {
                if let c = d.cover { c } else { RemoteImage(url: absURL(d.art)) }
            }
            .frame(width: 250, height: 250).cardShape(10).shadow(color: .black.opacity(0.25), radius: 16, y: 8)
            .onTapGesture { onArtTap?() }
            .padding(.top, 8)
            Text(d.title).font(.title2.bold()).multilineTextAlignment(.center)
            if !d.by.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(d.by.enumerated()), id: \.offset) { i, a in
                        Button(a.name + (i < d.by.count - 1 ? "," : "")) { if let id = a.id { Router.shared.open(.artist(id)) } }
                    }
                }
                .font(.title3).tint(.accent)
            }
            if !d.meta.isEmpty { Text(d.meta).font(.footnote).foregroundStyle(.secondary) }
            if let desc = d.desc, !desc.isEmpty {
                Text(desc).font(.footnote).foregroundStyle(.secondary).lineLimit(descOpen ? nil : 3).onTapGesture { descOpen.toggle() }
            }
            HStack(spacing: 12) {
                if rateable || key.hasPrefix("album") {
                    let on = liked ?? (likeStatus == "LIKE")
                    CircleButton(icon: on ? "checkmark" : "plus") { Task { await rate(on) } }
                }
                PlayButtons(tracks: tracks, source: source)
                CircleButton(icon: downloadIcon) { download() }
                Menu {
                    Button { Player.shared.playNext(tracks) } label: { Label("Lire ensuite", systemImage: "text.line.first.and.arrowtriangle.forward") }
                    Button { Player.shared.addToQueue(tracks) } label: { Label("Ajouter à la file", systemImage: "text.line.last.and.arrowtriangle.forward") }
                    Button { Router.shared.present(.addTo(tracks)) } label: { Label("Ajouter à une playlist…", systemImage: "text.badge.plus") }
                    menu()
                    if let pid = playlistId, !key.hasPrefix("album") {
                        Button { UIPasteboard.general.string = "https://music.youtube.com/playlist?list=\(pid)"; Toast.show("Lien copié", .ok) } label: { Label("Copier le lien", systemImage: "link") }
                    }
                } label: { CircleIcon(icon: "ellipsis") }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 10)
    }

    private var downloadIcon: String {
        if !tracks.isEmpty && tracks.allSatisfy({ off.has($0.id) }) { return "checkmark.circle.fill" }
        if tracks.contains(where: { off.jobs[$0.id] != nil }) { return "arrow.down.circle.dotted" }
        return "arrow.down.circle"
    }
    private func download() {
        if !tracks.isEmpty && tracks.allSatisfy({ off.has($0.id) }) {
            Router.shared.confirm = Confirm(title: "Supprimer le téléchargement ?", message: "\(d.title) ne sera plus disponible hors ligne.", ok: "Supprimer") {
                tracks.forEach { off.remove($0.id) }
                off.removeCollection(key)
                Toast.show("Téléchargement supprimé", .ok)
            }
            return
        }
        off.saveCollection(key, .init(title: d.title, art: d.art, href: source.href), tracks.map(\.id))
        off.download(tracks.filter(\.available))
        Toast.show("Téléchargement de \(nt(tracks.count)) lancé", .ok)
    }
    private func rate(_ on: Bool) async {
        guard let pid = playlistId else { return }
        do {
            _ = try await yt("/rate-playlist", body: ["playlistId": .str(pid), "rating": on ? "INDIFFERENT" : "LIKE"])
            liked = !on
            Toast.show(!on ? "Ajouté à la bibliothèque" : "Retiré de la bibliothèque", .ok)
            NotificationCenter.default.post(name: .musicPlaylists, object: nil)
        } catch { Toast.show(error.localizedDescription, .err) }
    }
}

struct CircleIcon: View {
    var icon: String
    var body: some View {
        Image(systemName: icon).font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
            .background(Color(.secondarySystemFill), in: Circle()).foregroundStyle(Color.accent)
    }
}
struct CircleButton: View {
    var icon: String
    var action: () -> Void
    var body: some View { Button(action: action) { CircleIcon(icon: icon) }.buttonStyle(.plain) }
}

/// Défilement de page standard (marges, place pour le mini-lecteur, rafraîchissement).
struct Page<Content: View>: View {
    var title: String
    var large = true
    var refresh: (() async -> Void)? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 16).padding(.bottom, 120)
                .containerRelativeFrame(.horizontal) // jamais plus large que l'écran
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(large ? .large : .inline)
        .refreshable { await refresh?() }
    }
}

/// Chargement d'une page : squelette, erreur avec « Réessayer », rafraîchissement discret quand la donnée change.
struct Loader<T, Content: View>: View {
    var load: () async throws -> T
    var watch: [String] = []
    @ViewBuilder var content: (T, @escaping () async -> Void) -> Content
    @State private var value: T?
    @State private var error: Error?
    var body: some View {
        Group {
            if let value { content(value, reload) }
            else if let error { ErrorView(error: error) { Task { await reload() } } }
            else { ProgressView().frame(maxWidth: .infinity, minHeight: 300) }
        }
        .task { if value == nil { await reload() } }
        .onReceive(NotificationCenter.default.publisher(for: .musicStale)) { n in
            let p = n.object as? String ?? ""
            if watch.isEmpty || watch.contains(where: { p.hasPrefix($0) }) || p == "online" { Task { await reload() } }
        }
    }
    func reload() async {
        do { value = try await load(); error = nil } catch { if value == nil { self.error = error } }
    }
}

struct ErrorView: View {
    var error: Error
    var retry: () -> Void
    var body: some View {
        if (error as? APIError)?.code == 401 && Session.value != nil {
            EmptyState(icon: "person.crop.circle.badge.exclamationmark", title: "Compte YouTube Music requis", text: error.localizedDescription, action: ("Connecter le compte", { Router.shared.open(.settings) }))
        } else if !Offline.shared.online {
            EmptyState(icon: "wifi.slash", title: "Hors ligne", text: "Tes titres téléchargés restent disponibles.", action: ("Téléchargés", { Router.shared.tab = .downloads }))
        } else {
            EmptyState(icon: "exclamationmark.triangle", title: "Impossible de charger la page", text: error.localizedDescription, action: ("Réessayer", retry))
        }
    }
}
