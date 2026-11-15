import AVFoundation
import SwiftUI

struct DevicePicker: View {
    @State private var live = Live.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(id: live.me, name: "\(live.name) (cet appareil)", kind: live.kind)
                    ForEach(live.devices.filter { $0.id != live.me }) { d in row(id: d.id, name: d.name, kind: d.kind) }
                } footer: { Text(live.connected ? "Les appareils où Music est ouverte apparaissent ici." : "Connexion à la synchro…") }
            }
            .navigationTitle("Appareil de sortie").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
    func row(id: String, name: String, kind: String) -> some View {
        let active = (live.activeId ?? live.me) == id || (id == live.me && live.target == nil)
        return Button { Task { await live.transfer(id); dismiss() } } label: {
            HStack {
                Image(systemName: ["phone": "iphone", "tablet": "ipad", "car": "car.fill"][kind] ?? "laptopcomputer").frame(width: 28)
                Text(name)
                Spacer()
                if active { Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accent) }
            }
        }
        .foregroundStyle(.primary)
    }
}

/// Égaliseur de l'appareil qui joue (celui-ci, ou l'appareil piloté à distance).
struct EQSheet: View {
    @State private var eq = EQ.shared
    @State private var live = Live.shared
    @Environment(\.dismiss) private var dismiss
    var remote: Bool { live.target != nil }
    var on: Bool { remote ? live.state?["eq"]["on"].bool ?? false : eq.on }
    var gains: [Double] { remote ? (live.state?["eq"]["gains"].array.compactMap(\.double)).flatMap { $0.count == 7 ? $0 : nil } ?? Array(repeating: 0, count: 7) : eq.gains }
    var profiles: [String: [Double]] { remote ? live.state?["eq"]["profiles"].object.mapValues { $0.array.compactMap(\.double) } ?? [:] : eq.profiles }
    var body: some View {
        NavigationStack {
            Form {
                if remote { Text("Réglage de \(live.targetName)").font(.footnote).foregroundStyle(.secondary) }
                Toggle("Égaliseur", isOn: Binding(get: { on }, set: { v in remote ? live.sendEQ(["on": .bool(v)]) : (eq.on = v) }))
                Section("Préréglages") {
                    let all = EQ.presets + profiles.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(all, id: \.0) { name, g in
                                Button(name) { set(g, on: true) }.buttonStyle(.bordered).tint(g == gains ? .accent : .gray)
                                    .contextMenu { if profiles[name] != nil && !remote { Button("Supprimer", role: .destructive) { eq.deleteProfile(name) } } }
                            }
                        }
                    }
                    Button { Prompt.ask("Enregistrer le réglage", placeholder: "Casque, Voiture…", ok: "Enregistrer") { n in remote ? live.sendEQ(["profile": ["name": .str(n), "gains": .arr(gains.map { .num($0) })]]) : eq.saveProfile(n) } } label: { Label("Enregistrer ce réglage…", systemImage: "plus") }
                }
                Section("Bandes") {
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(0..<7, id: \.self) { i in
                            VStack {
                                Text(String(format: "%+.0f", gains[i])).font(.caption2.monospacedDigit())
                                Slider(value: Binding(get: { gains[i] }, set: { v in var g = gains; g[i] = (v * 2).rounded() / 2; set(g) }), in: -12...12)
                                    .rotationEffect(.degrees(-90)).frame(width: 160, height: 30).frame(width: 40, height: 160)
                                Text(EQ.bands[i] >= 1000 ? "\(EQ.bands[i] / 1000)k" : "\(EQ.bands[i])").font(.caption2)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!on)
                }
            }
            .navigationTitle("Égaliseur").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
    }
    private func set(_ g: [Double], on o: Bool? = nil) {
        if remote { var a: [String: JSON] = ["gains": .arr(g.map { .num($0) })]; if let o { a["on"] = .bool(o) }; live.sendEQ(.obj(a)) }
        else { eq.gains = g; if let o { eq.on = o } }
    }
}

struct AddToSheet: View {
    var tracks: [Track]
    @State private var lib = Library.shared
    @State private var loading = true
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Button { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { newPlaylist(tracks, open: false) } } label: { Label("Nouvelle playlist…", systemImage: "plus") }
                let mine = lib.mine.filter(\.canEdit)
                if !mine.isEmpty {
                    Section("Mes playlists") {
                        ForEach(mine) { p in
                            row(AnyView(MplCover(p: p)), p.title, nt(p.count ?? 0)) { try await lib.add(p.id, tracks) }
                        }
                    }
                }
                let yts = lib.ytPlaylists.filter { let i = $0["playlistId"].string ?? ""; return !i.isEmpty && i != "LM" && i != "SE" }
                if lib.connected && !yts.isEmpty {
                    Section("YouTube Music") {
                        ForEach(Array(yts.enumerated()), id: \.offset) { _, p in
                            row(AnyView(RemoteImage(url: absURL(img(p["thumbnails"], 120)))), p["title"].string ?? "", p["count"].int.map { nt($0) } ?? "") {
                                _ = try await yt("/playlists/\(p["playlistId"].string ?? "")/items", body: ["videoIds": .arr(tracks.map { .str($0.id) })])
                            }
                        }
                    }
                }
                if loading { ProgressView() }
            }
            .navigationTitle("Ajouter à une playlist").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } } }
            .task { await lib.refreshMine(); if lib.connected { await lib.refreshYtPlaylists() }; loading = false }
        }
        .presentationDetents([.medium, .large])
    }
    func row(_ art: AnyView, _ title: String, _ sub: String, run: @escaping () async throws -> Void) -> some View {
        Button {
            dismiss()
            Task { do { try await run(); Toast.show("Ajouté à « \(title) »", .ok) } catch { Toast.show(error.localizedDescription, .err) } }
        } label: {
            HStack { art.frame(width: 44, height: 44).cardShape(5); VStack(alignment: .leading) { Text(title).lineLimit(1); Text(sub).font(.caption).foregroundStyle(.secondary) } }
        }
        .foregroundStyle(.primary)
    }
}

/// Live, acoustique, remix, clip… : la version choisie remplace toujours ce titre, partout et sur tous les appareils.
struct VersionsSheet: View {
    var t: Track
    @State private var list: [(Track, String)] = []
    @State private var msg = "Recherche des versions…"
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let orig = t.orig ?? t.id
        let chosen = Player.shared.versionOf(orig)?.id ?? orig
        NavigationStack {
            List {
                ForEach([(t, "Originale")] + list, id: \.0.id) { v, kind in
                    Button {
                        dismiss()
                        Task {
                            do { try await Player.shared.setVersion(orig, v.id == orig ? nil : v); Toast.show(v.id == orig ? "Version d'origine rétablie" : "Version « \(kind) » retenue", .ok) }
                            catch { Toast.show(error.localizedDescription, .err) }
                        }
                    } label: {
                        HStack {
                            RemoteImage(url: v.thumbURL).frame(width: 44, height: 44).cardShape(5)
                            VStack(alignment: .leading) {
                                Text(v.title).lineLimit(1)
                                Text([kind, v.artistLine, v.album?.name ?? "", v.duration.map { clock($0) } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if v.id == chosen { Image(systemName: "checkmark").foregroundStyle(Color.accent) }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                if !msg.isEmpty { Text(msg).foregroundStyle(.secondary) }
            }
            .navigationTitle("Autres versions").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } } }
            .task {
                do {
                    let vs = try await yt("/versions" + q(["title": t.title, "artist": t.artistLine, "id": orig]), ttl: 86400)
                    list = vs.array.compactMap { v in track(v).map { ($0, v["kind"].string ?? "") } }
                    msg = list.isEmpty ? "Aucune autre version trouvée." : ""
                } catch { msg = error.localizedDescription }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
