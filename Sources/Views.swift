import SwiftUI

struct Artwork: View {
    let url: URL?
    var size: CGFloat = 48
    var body: some View {
        AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: {
            ZStack { Color(.secondarySystemFill); Image(systemName: "music.note").foregroundStyle(.secondary) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 100 ? 10 : 6, style: .continuous))
    }
}

struct TrackRow: View {
    let track: Track
    @State private var off = Offline.shared
    @State private var player = Player.shared
    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: track.art(120))
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                    .foregroundStyle(player.current?.videoId == track.videoId ? Color.pink : Color.primary)
                Text(track.artistLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if off.downloading.contains(track.videoId) { ProgressView() }
            else if off.has(track.videoId) { Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary).imageScale(.small) }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if off.has(track.videoId) {
                Button(role: .destructive) { off.remove(track) } label: { Label("Retirer de l'appareil", systemImage: "trash") }
            } else {
                Button { off.download(track) } label: { Label("Télécharger", systemImage: "arrow.down.circle") }
            }
        }
    }
}

/// Liste de titres jouable, avec « Lecture », « Aléatoire » et « Tout télécharger ».
struct TrackList: View {
    let title: String
    let load: () async throws -> [Track]
    @State private var tracks: [Track] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        List {
            if !tracks.isEmpty {
                HStack(spacing: 12) {
                    Button { Player.shared.play(tracks) } label: { Label("Lecture", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    Button { Player.shared.play(tracks.shuffled()) } label: { Label("Aléatoire", systemImage: "shuffle").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.bordered).controlSize(.large).listRowSeparator(.hidden)
            }
            ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                TrackRow(track: t).onTapGesture { Player.shared.play(tracks, at: i) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if loading && tracks.isEmpty { ProgressView() }
            else if let error, tracks.isEmpty { ContentUnavailableView("Indisponible", systemImage: "wifi.slash", description: Text(error)) }
        }
        .navigationTitle(title)
        .toolbar {
            if !tracks.isEmpty {
                Button { Offline.shared.downloadAll(tracks) } label: { Image(systemName: "arrow.down.circle") }
                    .accessibilityLabel("Tout télécharger")
            }
        }
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    private func refresh() async {
        do { tracks = try await load(); error = nil } catch { self.error = error.localizedDescription }
        loading = false
    }
}

struct LibraryView: View {
    let signOut: () -> Void
    @State private var playlists: [PlaylistRef] = []
    @State private var off = Offline.shared
    var body: some View {
        List {
            Section {
                NavigationLink { TrackList(title: "Titres J'aime", load: API.likedSongs) } label: {
                    Label("Titres J'aime", systemImage: "heart.fill")
                }
                NavigationLink { TrackList(title: "Sur l'appareil") { Offline.shared.tracks } } label: {
                    Label("Sur l'appareil (\(off.tracks.count))", systemImage: "arrow.down.circle.fill")
                }
            }
            Section("Playlists") {
                ForEach(playlists) { p in
                    NavigationLink {
                        TrackList(title: p.title) { try await API.playlist(p.playlistId).tracks?.items ?? [] }
                    } label: {
                        HStack(spacing: 12) {
                            Artwork(url: p.art, size: 56)
                            VStack(alignment: .leading) {
                                Text(p.title).lineLimit(1)
                                if let d = p.description { Text(d).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Bibliothèque")
        .toolbar {
            Menu {
                Button(role: .destructive, action: signOut) { Label("Se déconnecter", systemImage: "rectangle.portrait.and.arrow.right") }
            } label: { Image(systemName: "person.crop.circle") }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do { playlists = try await API.playlists() }
        catch APIError.unauthorized { signOut() }
        catch {}
    }
}

struct SearchView: View {
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var searching = false
    var body: some View {
        List {
            ForEach(Array(results.enumerated()), id: \.offset) { i, t in
                TrackRow(track: t).onTapGesture { Player.shared.play(results, at: i) }
            }
        }
        .listStyle(.plain)
        .overlay { if searching { ProgressView() } }
        .navigationTitle("Recherche")
        .searchable(text: $query, prompt: "Artistes, titres…")
        .onSubmit(of: .search) { Task { await run() } }
    }

    private func run() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        results = (try? await API.search(q)) ?? []
        searching = false
    }
}

struct MiniPlayer: View {
    @State private var player = Player.shared
    var body: some View {
        if let t = player.current {
            HStack(spacing: 12) {
                Artwork(url: t.art(120), size: 40)
                Text(t.title).lineLimit(1)
                Spacer()
                Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
                    .font(.title3).accessibilityLabel(player.isPlaying ? "Pause" : "Lecture")
                Button { player.next() } label: { Image(systemName: "forward.fill") }.font(.title3).accessibilityLabel("Suivant")
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 8).padding(.bottom, 4)
        }
    }
}

struct NowPlayingView: View {
    @State private var player = Player.shared
    @State private var scrub: Double?
    var body: some View {
        if let t = player.current {
            VStack(spacing: 28) {
                Capsule().fill(.secondary).frame(width: 40, height: 5).padding(.top, 8)
                Spacer()
                Artwork(url: t.art(800), size: 320).shadow(radius: 20, y: 10)
                VStack(alignment: .leading, spacing: 4) {
                    Text(t.title).font(.title2.bold()).lineLimit(1)
                    Text(t.artistLine).font(.title3).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 4) {
                    Slider(value: Binding(get: { scrub ?? player.elapsed }, set: { scrub = $0 }),
                           in: 0...max(player.duration, 1)) { editing in
                        if !editing, let s = scrub { player.seek(s); scrub = nil }
                    }
                    HStack {
                        Text(fmt(scrub ?? player.elapsed)); Spacer(); Text("-" + fmt(max(player.duration - (scrub ?? player.elapsed), 0)))
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 56) {
                    Button { player.previous() } label: { Image(systemName: "backward.fill") }.accessibilityLabel("Précédent")
                    Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 48)) }
                        .accessibilityLabel(player.isPlaying ? "Pause" : "Lecture")
                    Button { player.next() } label: { Image(systemName: "forward.fill") }.accessibilityLabel("Suivant")
                }
                .font(.largeTitle).foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 28)
            .presentationDragIndicator(.hidden)
        }
    }

    private func fmt(_ s: Double) -> String {
        guard s.isFinite else { return "0:00" }
        let i = Int(s); return String(format: "%d:%02d", i / 60, i % 60)
    }
}
