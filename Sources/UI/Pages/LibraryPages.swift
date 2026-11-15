import PhotosUI
import SwiftUI

/// Saisie de texte (nouvelle playlist, renommer…).
@MainActor @Observable final class Prompt {
    static let shared = Prompt()
    var title = "", value = "", ok = "OK", placeholder = ""
    var shown = false
    var run: ((String) -> Void)?
    static func ask(_ title: String, value: String = "", placeholder: String = "", ok: String = "OK", run: @escaping (String) -> Void) {
        let p = shared
        p.title = title; p.value = value; p.placeholder = placeholder; p.ok = ok; p.run = run; p.shown = true
    }
}

func newPlaylist(_ ts: [Track] = [], open: Bool = true) {
    Prompt.ask("Nouvelle playlist", placeholder: "Nom de la playlist", ok: "Créer") { title in
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            do {
                let p = try await Library.shared.create(title, ts)
                if open && ts.isEmpty { Router.shared.open(.mpl(p.id)) }
                else { Toast.show("Playlist « \(title) » créée", .ok, action: "Ouvrir") { Router.shared.open(.mpl(p.id)) } }
            } catch { Toast.show(error.localizedDescription, .err) }
        }
    }
}

struct MplPage: View {
    var id: String
    @State private var editMode: EditMode = .inactive
    @State private var order: [Track] = []
    var body: some View {
        Loader(load: { try await Library.shared.mpl(id) }, watch: ["mpl"]) { p, reload in
            let ts = (p.tracks ?? []).map { var t = $0; t.title = cleanTitle(t.title, t.artists); t.available = true; return t }
            let src = Source(title: p.title, href: "#/mpl/\(id)")
            let dups = duplicates(ts)
            let total = ts.reduce(0) { $0 + ($1.duration ?? 0) }
            let share = ["private": nil, "read": "Partagée", "edit": "Collaborative"][p.share] ?? nil
            let meta = [p.mine ? share : "De \(p.owner.split(separator: "@").first.map(String.init) ?? "")", nt(ts.count), total > 0 ? "\(Int(total / 60)) min" : nil].compactMap { $0 }.joined(separator: " · ")
            if editMode == .active {
                List {
                    ForEach(order, id: \.key) { t in TrackRow(t: t, opts: ListOpts()).allowsHitTesting(false) }
                        .onMove { order.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.plain)
                .environment(\.editMode, $editMode)
                .navigationTitle(p.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Terminé") {
                            Task {
                                do { try await Library.shared.update(id, ["order": .arr(order.compactMap(\.key).map { .str($0) })]); Toast.show("Ordre enregistré", .ok) }
                                catch { Toast.show(error.localizedDescription, .err) }
                                editMode = .inactive
                                await reload()
                            }
                        }
                    }
                }
            } else {
                Page(title: p.title, large: false, refresh: { await reload() }) {
                    Hero(d: HeroData(cover: AnyView(MplCover(p: p)), title: p.title, meta: meta, desc: p.description), tracks: ts, source: src, key: "mpl:\(id)",
                         onArtTap: p.canEdit ? { Router.shared.present(.editMpl(p)) } : nil) {
                        if p.canEdit {
                            Button { Router.shared.present(.editMpl(p)) } label: { Label("Modifier…", systemImage: "pencil") }
                            Button { order = p.tracks ?? []; editMode = .active } label: { Label("Réorganiser", systemImage: "arrow.up.arrow.down") }
                        }
                        if !dups.isEmpty && p.canEdit {
                            Button {
                                Task {
                                    try? await Library.shared.removeTracks(id, dups.compactMap(\.key))
                                    Toast.show("\(dups.count) doublon\(dups.count > 1 ? "s" : "") retiré\(dups.count > 1 ? "s" : "")", .ok)
                                    await reload()
                                }
                            } label: { Label("Retirer les doublons (\(dups.count))", systemImage: "rectangle.on.rectangle.slash") }
                        }
                        if p.mine {
                            Button(role: .destructive) {
                                Router.shared.confirm = Confirm(title: "Supprimer la playlist ?", message: "« \(p.title) » sera supprimée de Music\(p.share != "private" ? ", pour tout le monde" : "").", ok: "Supprimer") {
                                    Task {
                                        do { try await Library.shared.remove(id); Router.shared.paths[Router.shared.tab]?.removeLast() } catch { Toast.show(error.localizedDescription, .err) }
                                    }
                                }
                            } label: { Label("Supprimer la playlist", systemImage: "trash") }
                        }
                    }
                    if ts.isEmpty { EmptyState(icon: "music.note.list", title: "Playlist vide", text: "Ajoute des titres avec le menu « … » d'un morceau, puis « Ajouter à une playlist ».") }
                    else { TrackList(tracks: ts, opts: ListOpts(source: src, mpl: p.canEdit ? id : nil, onRemoved: { Task { await reload() } })) }
                }
            }
        }
    }
    private func duplicates(_ ts: [Track]) -> [Track] {
        var seen = Set<String>()
        func dk(_ t: Track) -> String {
            t.title.lowercased().replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) + "|" + (t.artists.first?.name.lowercased() ?? "")
        }
        return ts.filter { t in
            if seen.contains(t.id) || seen.contains(dk(t)) { return true }
            seen.insert(t.id); seen.insert(dk(t)); return false
        }
    }
}

/// Fenêtre « Modifier » d'une playlist Music : titre, description, miniature (aperçu en direct), partage.
struct EditMplSheet: View {
    var p: MPL
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var desc = ""
    @State private var style = "mosaic"
    @State private var palette = 0
    @State private var share = "private"
    @State private var item: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack { Spacer(); MplCover(p: MPL(id: p.id, title: title.isEmpty ? p.title : title, cover: p.cover, thumbs: p.thumbs, tracks: p.tracks), style: style, palette: palette, image: image).frame(width: 180, height: 180).cardShape(10); Spacer() }
                        .listRowBackground(Color.clear)
                    Picker("Miniature", selection: $style) { Text("Mosaïque").tag("mosaic"); Text("Dégradé").tag("gradient"); Text("Image").tag("image") }.pickerStyle(.segmented)
                    if style == "gradient" {
                        HStack {
                            ForEach(PALETTES.indices, id: \.self) { i in
                                Circle().fill(LinearGradient(colors: [Color(hex: PALETTES[i].0), Color(hex: PALETTES[i].1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 30, height: 30).overlay(Circle().stroke(.primary, lineWidth: palette == i ? 2 : 0)).onTapGesture { palette = i }
                            }
                        }
                    }
                    if style == "image" { PhotosPicker("Choisir une image", selection: $item, matching: .images) }
                }
                Section("Titre") { TextField("Titre", text: $title) }
                Section("Description") { TextField("Description", text: $desc, axis: .vertical).lineLimit(2...6) }
                if p.mine {
                    Section("Partage") {
                        Picker("Partage", selection: $share) { Text("Privée").tag("private"); Text("Partagée (lecture)").tag("read"); Text("Collaborative").tag("edit") }.pickerStyle(.inline).labelsHidden()
                    }
                }
            }
            .navigationTitle("Modifier la playlist").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Enregistrer") { Task { await save() } }.disabled(busy) }
            }
            .onAppear { title = p.title; desc = p.description ?? ""; style = p.cover?.style ?? "mosaic"; palette = p.cover?.palette ?? 0; share = p.share }
            .onChange(of: item) {
                Task {
                    guard let d = try? await item?.loadTransferable(type: Data.self), let i = UIImage(data: d) else { return }
                    // recadrée en carré sur l'appareil
                    let s = min(i.size.width, i.size.height), r = CGRect(x: (i.size.width - s) / 2, y: (i.size.height - s) / 2, width: s, height: s)
                    let out = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 800)).image { _ in i.draw(in: CGRect(x: -r.minX * 800 / s, y: -r.minY * 800 / s, width: i.size.width * 800 / s, height: i.size.height * 800 / s)) }
                    image = out
                }
            }
        }
    }
    private func save() async {
        busy = true
        defer { busy = false }
        do {
            var patch: [String: JSON] = ["title": .str(title), "description": .str(desc), "cover": ["style": .str(style == "image" && image == nil && p.cover?.version == nil ? "mosaic" : style), "palette": .num(Double(palette))]]
            if p.mine { patch["share"] = .str(share) }
            try await Library.shared.update(p.id, .obj(patch))
            if style == "image", let image, let jpg = image.jpegData(compressionQuality: 0.85) { try await Library.shared.cover(p.id, jpeg: jpg) }
            dismiss()
        } catch { Toast.show(error.localizedDescription, .err) }
    }
}

struct LibraryPage: View {
    @State var tab: String
    static let TABS = [("playlists", "Playlists"), ("songs", "Morceaux"), ("albums", "Albums"), ("artists", "Artistes"), ("history", "Historique")]
    var body: some View {
        Page(title: "Bibliothèque") {
            FlowChips(items: Self.TABS.map(\.1) + ["Téléchargés", "Récap"], on: Self.TABS.first { $0.0 == tab }?.1) { l in
                if l == "Téléchargés" { Router.shared.tab = .downloads } else if l == "Récap" { Router.shared.open(.stats(30)) }
                else { tab = Self.TABS.first { $0.1 == l }?.0 ?? "playlists" }
            }
            .padding(.vertical, 8)
            switch tab {
            case "playlists": PlaylistsTab()
            case "history": HistoryTab()
            default: LibraryList(tab: tab).id(tab)
            }
        }
        .toolbar { TopButtons() }
    }
}

struct PlaylistsTab: View {
    @State private var lib = Library.shared
    @State private var smart: [JSON] = []
    var body: some View {
        H2(title: "Mes playlists")
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) {
            Button { newPlaylist() } label: {
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemFill)).aspectRatio(1, contentMode: .fit).overlay(Image(systemName: "plus").font(.largeTitle).foregroundStyle(Color.accent))
                    Text("Nouvelle playlist").font(.subheadline); Text("Music").font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            Button { Router.shared.open(.playlist("LM")) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    LikedCover().cardShape()
                    Text("Titres J'aime").font(.subheadline); Text(lib.liked.isEmpty ? "Music" : nt(lib.liked.count)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            ForEach(lib.mine) { p in
                Button { Router.shared.open(.mpl(p.id)) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        MplCover(p: p).cardShape()
                        Text(p.title).font(.subheadline).lineLimit(1)
                        Text((p.mine ? "" : "\(p.owner.split(separator: "@").first ?? "") · ") + nt(p.count ?? 0)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { Task { if let f = try? await lib.mpl(p.id) { Player.shared.playList((f.tracks ?? []).map { var t = $0; t.available = true; return t }, source: Source(title: p.title, href: "#/mpl/\(p.id)")) } } } label: { Label("Lire", systemImage: "play.fill") }
                }
            }
        }
        if !smart.isEmpty {
            H2(title: "Pour toi")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) { ForEach(Array(smart.enumerated()), id: \.offset) { _, p in SmartTile(p: p, width: nil) } }
        }
        let pls = lib.ytPlaylists
        if !pls.isEmpty {
            H2(title: "Playlists enregistrées")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 18) {
                ForEach(Array(pls.enumerated()), id: \.offset) { _, p in Tile(it: p, sub: p["count"].int.map { nt($0) } ?? p["author"][0]["name"].string ?? "", width: nil) }
            }
        }
        Color.clear.frame(height: 1)
            .task { await lib.refreshMine(); smart = await smartLists(); await lib.refreshYtPlaylists() }
            .onReceive(NotificationCenter.default.publisher(for: .musicPlaylists)) { _ in API.shared.forget(); Task { await lib.refreshYtPlaylists() } }
    }
}

struct LibraryList: View {
    var tab: String
    var body: some View {
        Loader(load: { try await yt("/library/\(tab)", ttl: 60) }, watch: ["/library"]) { data, _ in
            let name = LibraryPage.TABS.first { $0.0 == tab }?.1 ?? ""
            if tab == "songs" {
                let ts = parseTracks(data)
                if ts.isEmpty { EmptyState(icon: "heart", title: "Aucun titre J'aime", text: "Touche le cœur d'un titre, dans le lecteur ou son menu « … », pour le retrouver ici.") }
                else {
                    let src = Source(title: name, href: "#/library/songs")
                    PlayButtons(tracks: ts, source: src).padding(.bottom, 10)
                    TrackList(tracks: ts, opts: ListOpts(source: src))
                }
            } else if data.array.isEmpty {
                let e: (String, String, String) = ["albums": ("opticaldisc", "Aucun album", "Sur la page d'un album, touche « + » pour l'ajouter à ta bibliothèque."),
                    "artists": ("music.mic", "Aucun artiste suivi", "Sur la page d'un artiste, touche « S'abonner » : ses nouveautés apparaîtront sur l'accueil.")][tab] ?? ("opticaldisc", "Rien ici pour l'instant", "")
                EmptyState(icon: e.0, title: e.1, text: e.2)
            } else { TileGrid(items: data.array) }
        }
    }
}

/// Historique complet tenu par Music (daté, sans limite), avec recherche et saut à une date.
struct HistoryTab: View {
    @State private var groups: [(String, [Track])] = []
    @State private var before: Double?
    @State private var lastDay = ""
    @State private var search = ""
    @State private var day = Date()
    @State private var summary = ""
    @State private var more = false
    @State private var first: Double?
    @State private var empty = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Rechercher dans l'historique", text: $search).textFieldStyle(.roundedBorder)
                DatePicker("Aller au…", selection: $day, in: (first.map { Date(timeIntervalSince1970: $0) } ?? .distantPast)...Date(), displayedComponents: .date).labelsHidden()
            }
            Text(summary).font(.footnote).foregroundStyle(.secondary).padding(.vertical, 8)
            if empty { EmptyState(icon: "clock", title: "Aucune écoute trouvée") }
            ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                if !g.0.isEmpty { H2(title: g.0) }
                TrackList(tracks: g.1, opts: ListOpts(source: Source(title: "Historique", href: "#/library/history")))
            }
            if more { Button("Plus ancien") { Task { await page(reset: false) } }.buttonStyle(.bordered).frame(maxWidth: .infinity).padding(.vertical, 16) }
        }
        .task {
            if let f = try? await yt("/history/local" + q(["limit": 1]), fresh: true) {
                first = f["first"].double
                if let fs = first { summary = "\(f["total"].int ?? 0) écoutes depuis le \(Date(timeIntervalSince1970: fs).formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "fr_FR"))))" }
            }
            await page(reset: true)
        }
        .task(id: search) { try? await Task.sleep(nanoseconds: 300_000_000); if !Task.isCancelled { before = nil; await page(reset: true) } }
        .onChange(of: day) { before = Calendar.current.startOfDay(for: day).timeIntervalSince1970 + 86400; Task { await page(reset: true, keepBefore: true) } }
    }
    private func label(_ d: Date) -> String {
        let c = Calendar.current
        if c.isDateInToday(d) { return "Aujourd'hui" }
        if c.isDateInYesterday(d) { return "Hier" }
        let sameYear = c.component(.year, from: d) == c.component(.year, from: Date())
        let s = d.formatted(sameYear ? .dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "fr_FR")) : .dateTime.weekday(.wide).day().month(.wide).year().locale(Locale(identifier: "fr_FR")))
        return s.prefix(1).uppercased() + s.dropFirst()
    }
    private func page(reset: Bool, keepBefore: Bool = false) async {
        if reset { if !keepBefore { before = nil }; lastDay = "" }
        guard let r = try? await yt("/history/local" + q(["before": before.map { Int($0) }, "limit": 150, "q": search.isEmpty ? nil : search]), fresh: true) else { return }
        var gs = reset ? [] : groups
        for it in r["items"].array {
            guard var t = it["t"].decode(Track.self), let ts = it["ts"].double else { continue }
            t.title = cleanTitle(t.title, t.artists); t.available = true
            let d = Date(timeIntervalSince1970: ts), k = Calendar.current.startOfDay(for: d).description
            if k != lastDay { gs.append((label(d), [])); lastDay = k } else if gs.isEmpty { gs.append(("", [])) }
            gs[gs.count - 1].1.append(t)
        }
        groups = gs
        if let l = r["items"].array.last?["ts"].double { before = l }
        more = r["items"].array.count >= 150
        empty = reset && r["items"].array.isEmpty
    }
}

struct DownloadsPage: View {
    @State private var off = Offline.shared
    var body: some View {
        Page(title: "Téléchargés") {
            Text("\(nt(off.tracks.count)) · \(bytes(off.totalSize)) sur cet appareil · espace libre \(bytes(off.freeSpace))").font(.subheadline).foregroundStyle(.secondary).padding(.bottom, 12)
            if !off.jobs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(off.jobs.count) téléchargement(s) en cours").bold()
                    ProgressView(value: off.jobs.values.map(\.progress).reduce(0, +) / Double(off.jobs.count)).tint(.accent)
                }
                .padding(14).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12)).padding(.bottom, 12)
            }
            if !off.collections.isEmpty {
                H2(title: "Albums et playlists")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(off.collections) { c in
                            Button {
                                let l = c.ids.compactMap { i in off.tracks.first { $0.id == i } }
                                Player.shared.playList(l, source: Source(title: c.meta.title, href: "#/downloads"))
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    collectionArt(c).frame(width: 150, height: 150).cardShape()
                                    Text(c.meta.title).font(.subheadline).lineLimit(1)
                                    Text("\(c.ids.filter { off.has($0) }.count)/\(nt(c.ids.count))").font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(width: 150)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if let r = Route(href: c.meta.href) { Button { Router.shared.open(r) } label: { Label("Ouvrir", systemImage: "arrow.up.right") } }
                                Button(role: .destructive) { c.ids.forEach { off.remove($0) }; off.removeCollection(c.key) } label: { Label("Supprimer le téléchargement", systemImage: "trash") }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
            }
            if off.tracks.isEmpty && off.jobs.isEmpty {
                EmptyState(icon: "arrow.down.circle", title: "Aucun titre téléchargé", text: "Télécharge un album, une playlist ou un titre (menu « … ») pour l'écouter sans réseau, même en avion.")
            } else if !off.tracks.isEmpty {
                H2(title: "Titres")
                let src = Source(title: "Téléchargés", href: "#/downloads")
                PlayButtons(tracks: off.tracks, source: src).padding(.bottom, 10)
                TrackList(tracks: off.tracks, opts: ListOpts(source: src))
            }
        }
        .toolbar { TopButtons() }
    }
    @ViewBuilder func collectionArt(_ c: Offline.Collection) -> some View {
        if c.key == "playlist:LM" { LikedCover() }
        else if c.key.hasPrefix("smart:"), let id = c.key.split(separator: ":").last { let pal = SMART_PAL[String(id)] ?? ("#0a84ff", "#64d2ff"); GradientCover(a: pal.0, b: pal.1, icon: "sparkles", title: c.meta.title, sub: "Pour toi") }
        else if let a = c.meta.art, !a.isEmpty { RemoteImage(url: absURL(a)) }
        else { GradientCover(a: PALETTES[0].0, b: PALETTES[0].1, title: c.meta.title) }
    }
}
