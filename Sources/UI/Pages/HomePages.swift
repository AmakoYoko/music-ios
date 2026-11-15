import SwiftUI

struct HomePage: View {
    var body: some View {
        Loader(load: load, watch: ["/editorial", "/home", "/history/smart"]) { d, reload in
            Page(title: d.hello, refresh: { await reload() }) {
                Text(d.today.capitalized).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, -6)
                OfflineBanner().padding(.top, 8)
                if let lead = d.smart.first(where: { $0["id"].string == "mix" }) { LeadCard(p: lead).padding(.top, 14) }
                Button { Router.shared.open(.radio) } label: {
                    HStack(spacing: 10) {
                        LiveDot()
                        Text("Music Live").bold()
                        Text("Les tops pop, en direct").foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(14).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain).padding(.top, 14)
                if !d.recent.isEmpty {
                    H2(title: "Écouté récemment")
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(d.recent.prefix(20)) { t in
                                Button { Player.shared.playRadio(t) } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        RemoteImage(url: t.thumbURL).frame(width: 150, height: 150).cardShape()
                                        Text(t.title).font(.subheadline).lineLimit(1)
                                        Text(t.artistLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .frame(width: 150)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { TrackMenuItems(t: t) }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.horizontal, -16)
                }
                let others = d.smart.filter { $0["id"].string != "mix" }
                if !others.isEmpty {
                    Kicker(text: "Tes playlists automatiques")
                    H2(title: "Pour toi", link: .stats(30), label: "Ton récap")
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 14) { ForEach(Array(others.enumerated()), id: \.offset) { _, p in SmartTile(p: p) } }.padding(.horizontal, 16)
                    }
                    .padding(.horizontal, -16)
                }
                ForEach(Array(d.edito.enumerated()), id: \.offset) { _, s in SectionView(sec: s) }
                if !d.home.isEmpty { Kicker(text: "Plus d'idées") }
                ForEach(Array(d.home.enumerated()), id: \.offset) { _, s in SectionView(sec: s) }
                if let at = d.editoAt {
                    Label("Sélection mise à jour à \(at.formatted(date: .omitted, time: .shortened)) · elle change au fil de la journée", systemImage: "arrow.clockwise")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 24)
                }
            }
            .toolbar { TopButtons() }
        }
    }

    struct Data { var hello: String; var today: String; var recent: [Track]; var smart: [JSON]; var edito: [JSON]; var home: [JSON]; var editoAt: Date? }
    func load() async throws -> Data {
        let hr = Calendar.current.component(.hour, from: Date())
        let today = Date().formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "fr_FR")))
        async let ed = try? yt("/editorial", ttl: 900)
        async let all = try? yt("/home?limit=6")
        let smart = await smartLists()
        let (e, h) = await (ed, all)
        let mine = Set((e?["sections"].array ?? []).compactMap { $0["title"].string?.lowercased() })
        let home = (h?.array ?? []).filter { s in
            let t = s["title"].string ?? ""
            return !mine.contains(t.lowercased()) && t.range(of: "^s[ée]lection rapide|^quick picks", options: [.regularExpression, .caseInsensitive]) == nil
        }
        return Data(hello: hr < 5 || hr >= 18 ? "Bonsoir" : "Bonjour", today: today, recent: Store.get("recent", [Track]()), smart: smart,
                    edito: e?["sections"].array ?? [], home: home, editoAt: e?["at"].double.map { Date(timeIntervalSince1970: $0) })
    }
}

struct LiveDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(Color.red).frame(width: 9, height: 9).opacity(on ? 1 : 0.35)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { on = true } }
    }
}

struct LeadCard: View {
    var p: JSON
    var body: some View {
        let ts = smartTracks(p)
        Button { Router.shared.open(.smart("mix")) } label: {
            HStack(spacing: 14) {
                SmartCover(p: p).frame(width: 130, height: 130).cardShape(10)
                VStack(alignment: .leading, spacing: 6) {
                    Text("À LA UNE").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    Text(p["title"].string ?? "").font(.title3.bold())
                    Text("\(p["description"].string ?? "") : \(ts.prefix(3).compactMap { $0.artists.first?.name }.joined(separator: ", ")) et d'autres.")
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                    Button { Player.shared.playList(ts, source: Source(title: p["title"].string, href: "#/smart/mix")) } label: { Label("Lire", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).tint(.accent).controlSize(.small)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }
}

struct SmartTile: View {
    var p: JSON
    var width: CGFloat? = 150
    var body: some View {
        Button { Router.shared.open(.smart(p["id"].string ?? "")) } label: {
            VStack(alignment: .leading, spacing: 6) {
                SmartCover(p: p).frame(width: width).cardShape()
                Text(p["title"].string ?? "").font(.subheadline).lineLimit(1)
                Text(nt(p["tracks"].array.count)).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: width)
        }
        .buttonStyle(.plain)
    }
}

struct SmartPage: View {
    var id: String
    var body: some View {
        Loader(load: { await smartLists(fresh: true).first { $0["id"].string == id } }, watch: ["/history/smart"]) { p, reload in
            if let p {
                let ts = smartTracks(p)
                let src = Source(title: p["title"].string, href: "#/smart/\(id)")
                Page(title: p["title"].string ?? "", large: false, refresh: { await reload() }) {
                    Hero(d: HeroData(cover: AnyView(SmartCover(p: p)), title: p["title"].string ?? "", meta: "\(nt(ts.count)) · mise à jour automatique", desc: p["description"].string),
                         tracks: ts, source: src, key: "smart:\(id)") { EmptyView() }
                    TrackList(tracks: ts, opts: ListOpts(source: src))
                }
            } else {
                Page(title: "Pour toi") { EmptyState(icon: "sparkles", title: "Pas encore assez d'écoutes", text: "Cette playlist se remplit toute seule au fil de tes écoutes.") }
            }
        }
    }
}

struct StatsPage: View {
    @State var days: Int
    var body: some View {
        Loader(load: { try await yt("/history/stats" + q(["days": days]), fresh: true) }) { r, reload in
            Page(title: "Ton récap", refresh: { await reload() }) {
                Picker("Période", selection: $days) {
                    Text("7 jours").tag(7); Text("30 jours").tag(30); Text("1 an").tag(365); Text("Tout").tag(0)
                }
                .pickerStyle(.segmented).padding(.vertical, 8)
                .onChange(of: days) { Task { await reload() } }
                if (r["plays"].int ?? 0) == 0 {
                    EmptyState(icon: "chart.bar", title: "Pas encore d'écoutes sur cette période", text: "Le récap se construit à partir de ce que tu écoutes dans Music.")
                } else {
                    let m = r["minutes"].int ?? 0
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                        StatCard(v: m >= 120 ? "\(Int((Double(m) / 60).rounded())) h" : "\(m) min", l: "d'écoute")
                        StatCard(v: "\(r["plays"].int ?? 0)", l: "écoutes")
                        StatCard(v: "\(r["tracks"].int ?? 0)", l: "titres différents")
                        StatCard(v: "\(r["artists"].int ?? 0)", l: "artistes")
                        StatCard(v: "\(r["streak"].int ?? 0) j", l: "série en cours")
                    }
                    if !r["topArtists"].array.isEmpty {
                        H2(title: "Artistes les plus écoutés")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(Array(r["topArtists"].array.enumerated()), id: \.offset) { i, a in
                                    Button { if let id = a["id"].string { Router.shared.open(.artist(id)) } } label: {
                                        VStack(spacing: 4) {
                                            RemoteImage(url: absURL(a["thumb"].string)).frame(width: 120, height: 120).clipShape(Circle())
                                                .overlay(alignment: .bottomLeading) { Text("\(i + 1)").font(.title.bold()).foregroundStyle(.white).shadow(radius: 4) }
                                            Text(a["name"].string ?? "").font(.subheadline).lineLimit(1)
                                            Text("\(a["n"].int ?? 0) écoute\((a["n"].int ?? 0) > 1 ? "s" : "")").font(.caption).foregroundStyle(.secondary)
                                        }
                                        .frame(width: 120)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .padding(.horizontal, -16)
                    }
                    let ts = r["topTracks"].array.compactMap { $0.decode(Track.self) }
                    H2(title: "Titres les plus écoutés")
                    TrackList(tracks: Array(ts.prefix(10)), opts: ListOpts(numbered: true, source: Source(title: "Récap", href: "#/stats")))
                    H2(title: "Quand tu écoutes")
                    let hours = r["hours"].array.compactMap(\.double), wd = r["weekdays"].array.compactMap(\.double)
                    let peak = hours.firstIndex(of: hours.max() ?? 0) ?? 0, wpeak = wd.firstIndex(of: wd.max() ?? 0) ?? 0
                    VStack(spacing: 12) {
                        Bars(title: "Heures", sub: "Surtout vers \(peak) h", vals: hours, labels: hours.indices.map { $0 % 6 == 0 ? "\($0)h" : "" })
                        Bars(title: "Jours", sub: "Surtout le \(["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"][safe: wpeak] ?? "")", vals: wd, labels: ["lun", "mar", "mer", "jeu", "ven", "sam", "dim"])
                    }
                }
            }
        }
        .id(days)
    }
}

struct StatCard: View {
    var v: String, l: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) { Text(v).font(.title2.bold()); Text(l).font(.caption).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct Bars: View {
    var title: String, sub: String, vals: [Double], labels: [String]
    var body: some View {
        let mx = max(1, vals.max() ?? 1)
        VStack(alignment: .leading, spacing: 4) {
            Text(title).bold(); Text(sub).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(vals.indices, id: \.self) { i in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.accent.gradient).frame(height: max(2, 90 * vals[i] / mx))
                        Text(labels[safe: i] ?? "").font(.system(size: 8)).foregroundStyle(.secondary).fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 110, alignment: .bottom)
        }
        .padding(14).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ExplorePage: View {
    var body: some View {
        Loader(load: { async let ex = yt("/explore"); async let m = try? yt("/moods"); return try await (ex, m ?? [:]) }, watch: ["/explore", "/moods"]) { d, reload in
            let (ex, moods) = d
            Page(title: "Explorer", refresh: { await reload() }) {
                if !ex["new_releases"].array.isEmpty { H2(title: "Nouveautés"); Shelf(items: ex["new_releases"].array) }
                if !ex["top_songs"]["items"].array.isEmpty {
                    H2(title: "Top titres", link: ex["top_songs"]["playlist"].string.map { .playlist($0) })
                    TrackList(tracks: Array(parseTracks(ex["top_songs"]["items"]).prefix(10)), opts: ListOpts(numbered: true))
                }
                if !ex["trending"]["items"].array.isEmpty {
                    H2(title: "Tendances", link: ex["trending"]["playlist"].string.map { .playlist(String($0.hasPrefix("VL") ? $0.dropFirst(2) : Substring($0))) })
                    TrackList(tracks: Array(parseTracks(ex["trending"]["items"]).prefix(10)), opts: ListOpts(single: true))
                }
                ForEach(moods.object.keys.sorted(), id: \.self) { k in H2(title: k); MoodGrid(list: moods[k].array) }
                if !ex["new_videos"].array.isEmpty { H2(title: "Nouveaux clips"); Shelf(items: ex["new_videos"].array, wide: true) }
            }
            .toolbar { TopButtons() }
        }
    }
}

struct MoodPage: View {
    var params: String, title: String
    var body: some View {
        Loader(load: { try await yt("/mood" + q(["params": params])) }) { pls, reload in
            Page(title: title, refresh: { await reload() }) { TileGrid(items: pls.array).padding(.top, 8) }
        }
    }
}

struct DiscographyPage: View {
    var id: String, params: String, title: String
    var body: some View {
        Loader(load: { try await yt("/artist/albums" + q(["id": id, "params": params])) }) { l, reload in
            Page(title: title, refresh: { await reload() }) { TileGrid(items: l.array).padding(.top, 8) }
        }
    }
}

/// Boutons de la barre du haut : « Quel est ce titre ? » et compte.
struct TopButtons: ToolbarContent {
    @State private var lib = Library.shared
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { Router.shared.listening = true } label: { Image(systemName: "waveform") }.accessibilityLabel("Quel est ce titre ?")
            Button { Router.shared.open(.settings) } label: {
                if lib.connected, let u = absURL(img(lib.account["photo"], 80)) { RemoteImage(url: u).frame(width: 28, height: 28).clipShape(Circle()) }
                else { Image(systemName: "person.crop.circle") }
            }
            .accessibilityLabel("Réglages")
        }
    }
}
