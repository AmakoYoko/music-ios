import SwiftUI

struct MiniPlayer: View {
    @State private var p = Player.shared
    @State private var live = Live.shared
    var body: some View {
        if let t = p.current {
            HStack(spacing: 10) {
                RemoteImage(url: t.thumbURL).frame(width: 40, height: 40).cardShape(6).modifier(ZoomSource())
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if !live.targetName.isEmpty { Label("Lecture sur \(live.targetName)", systemImage: "hifispeaker.fill").font(.caption).foregroundStyle(Color.accent).lineLimit(1) }
                    else { Text(t.artistLine.isEmpty ? p.source?.title ?? "" : t.artistLine).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 4)
                PlayPauseButton(size: 20)
                if !t.isLive { Button { p.next() } label: { Image(systemName: "forward.fill").font(.system(size: 20)) }.accessibilityLabel("Suivant").frame(width: 36) }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture { Router.shared.nowPlaying = true }
            .sensoryFeedback(.selection, trigger: p.idx)
            .gesture(DragGesture(minimumDistance: 30).onEnded { v in
                if abs(v.translation.width) > 70 && abs(v.translation.width) > abs(v.translation.height) { v.translation.width < 0 ? p.next() : p.prev() }
                else if v.translation.height < -40 { Router.shared.nowPlaying = true }
            })
            .overlay(alignment: .bottom) {
                if !t.isLive && p.duration > 0 {
                    GeometryReader { g in Rectangle().fill(Color.accent).frame(width: g.size.width * min(1, p.time / p.duration), height: 2) }.frame(height: 2).padding(.horizontal, 12)
                }
            }
        }
    }
}

struct PlayPauseButton: View {
    var size: CGFloat
    @State private var p = Player.shared
    var body: some View {
        Button { p.toggle() } label: {
            ZStack {
                if p.loading && p.mirror == nil { ProgressView() }
                else { Image(systemName: p.playing ? "pause.fill" : "play.fill").font(.system(size: size)) }
            }
            .frame(width: size * 1.8, height: size * 1.8)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(p.playing ? "Pause" : "Lecture")
    }
}

/// Lecteur plein écran façon Apple Music (mêmes mesures que music.css de la PWA) : pochette floutée qui tourne en fond,
/// taches de couleur, pochette qui « respire », paroles synchronisées, file d'attente.
struct NowPlayingView: View {
    @State private var p = Player.shared
    @State private var lib = Library.shared
    @State private var live = Live.shared
    @State private var off = Offline.shared
    @State private var colors: [Color] = []
    @State private var panel: String? = nil // lyrics | queue
    @State private var scrub: Double?
    @State private var drag: CGFloat = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let t = p.current {
            GeometryReader { g in
                ZStack {
                    NPBackground(thumb: t.thumbURL, colors: colors, playing: p.playing)
                    VStack(spacing: 0) {
                        Capsule().fill(.white.opacity(0.45)).frame(width: 38, height: 5).padding(.vertical, 10).frame(maxWidth: .infinity).contentShape(Rectangle())
                            .onTapGesture { dismiss() }
                        if let panel {
                            panelView(panel, t).frame(maxHeight: .infinity)
                        } else {
                            Spacer(minLength: 0)
                            art(t, width: min(g.size.width - 48, 440, g.size.height * 0.46))
                            Spacer(minLength: 14)
                            titleRow(t)
                        }
                        if !t.isLive { seekBar(t).padding(.top, 18) } else { HStack(spacing: 6) { LiveDot(); Text("EN DIRECT").font(.system(size: 11, weight: .bold)) }.padding(.top, 18) }
                        controls(t).padding(.top, 14)
                        if !live.targetName.isEmpty {
                            Button { Router.shared.present(.devices) } label: {
                                Label("Lecture sur \(live.targetName)", systemImage: "hifispeaker.fill").font(.system(size: 13, weight: .bold))
                                    .padding(.horizontal, 14).padding(.vertical, 7).background(.white.opacity(0.16), in: Capsule())
                            }
                            .padding(.top, 6)
                        }
                        foot.padding(.top, 14).padding(.bottom, 8)
                    }
                    .padding(.horizontal, 24)
                    .foregroundStyle(.white)
                    .frame(width: g.size.width)
                }
                .offset(y: drag)
                .simultaneousGesture(DragGesture().onChanged { v in if panel == nil { drag = max(0, v.translation.height) } }.onEnded { v in
                    if panel == nil && v.translation.height > 110 { dismiss() } else { withAnimation(.spring(duration: 0.35)) { drag = 0 } }
                })
            }
            .tint(.white)
            .sensoryFeedback(.impact(weight: .light), trigger: p.playing)
            .sensoryFeedback(.selection, trigger: p.idx)
            .sensoryFeedback(.success, trigger: lib.liked.contains(t.id)) { _, on in on }
            .sensoryFeedback(.selection, trigger: scrub == nil)
            .sensoryFeedback(.impact(weight: .light), trigger: panel)
            .task(id: t.thumb) {
                if let u = t.thumbURL, let i = await ImageCache.shared.image(u) { withAnimation(.easeInOut(duration: 1)) { colors = ImageCache.shared.palette(i) } }
            }
        } else {
            Color.black.onAppear { dismiss() }
        }
    }

    func art(_ t: Track, width: CGFloat) -> some View {
        let on = p.playing || p.loading
        return TimelineView(.animation(minimumInterval: 1 / 30, paused: !on)) { tl in
            let breathe = on ? 1 + 0.0125 * (1 - cos(tl.date.timeIntervalSinceReferenceDate * .pi / 3)) : 1
            RemoteImage(url: bigArt(t))
                .frame(width: width, height: width)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(on ? 0.6 : 0.5), radius: on ? 30 : 15, y: on ? 30 : 14)
                .scaleEffect((on ? 1 : 0.82) * breathe)
                .animation(.spring(duration: 0.6, bounce: 0.35), value: on)
        }
        .frame(width: width, height: width)
    }

    func titleRow(_ t: Track) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title).font(.system(size: 21, weight: .bold)).lineLimit(1)
                Text(t.artistLine).font(.system(size: 19)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    .onTapGesture { if let id = t.artists.first?.id { dismiss(); Router.shared.open(.artist(id)) } }
            }
            Spacer(minLength: 4)
            if !t.isLive {
                let liked = lib.liked.contains(t.id)
                RoundIcon(icon: liked ? "heart.fill" : "heart") { Task { await lib.toggleLike(t) } }.accessibilityLabel(liked ? "Je n'aime plus" : "J'aime")
                Menu { TrackMenuItems(t: t) } label: { RoundIconLabel(icon: "ellipsis") }.accessibilityLabel("Plus")
            }
        }
    }

    func seekBar(_ t: Track) -> some View {
        let d = max(p.duration, 1)
        let v = min(scrub ?? p.time, d)
        return VStack(spacing: 0) {
            GeometryReader { g in
                let active = scrub != nil
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white.opacity(0.85)).frame(width: max(0, g.size.width * v / d))
                    if let st = p.mixStart, !p.mixing, st < d {
                        Circle().fill(Color.accent).frame(width: 8, height: 8).offset(x: g.size.width * st / d - 4)
                    }
                }
                .frame(height: active ? 10 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { x in
                    scrub = max(0, min(d, Double(x.location.x / max(1, g.size.width)) * d))
                }.onEnded { _ in
                    if let s = scrub { p.seek(s) }
                    scrub = nil
                })
                .animation(.easeOut(duration: 0.15), value: active)
            }
            .frame(height: 24)
            HStack {
                Text(clock(v)).frame(width: 60, alignment: .leading)
                Spacer()
                badge(t)
                Spacer()
                Text("-" + clock(max(0, d - v))).frame(width: 60, alignment: .trailing)
            }
            .font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.6))
        }
    }

    @ViewBuilder func badge(_ t: Track) -> some View {
        let text = p.mixing ? "AutoMix" : off.has(t.id) ? "Téléchargé" : t.explicit ? "Explicite" : ""
        if !text.isEmpty {
            HStack(spacing: 4) {
                if p.mixing { Image(systemName: "opticaldisc") }
                Text(text.uppercased())
            }
            .font(.system(size: 10, weight: .bold)).tracking(0.4)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    func controls(_ t: Track) -> some View {
        HStack {
            SideButton(icon: "shuffle", on: p.shuffle) { p.toggleShuffle() }.accessibilityLabel("Aléatoire").disabled(t.isLive)
            Spacer()
            Button { p.prev() } label: { Image(systemName: "backward.fill").font(.system(size: 32)).frame(width: 64, height: 64).contentShape(Rectangle()) }.accessibilityLabel("Précédent").disabled(t.isLive)
            Spacer()
            Button { p.toggle() } label: {
                ZStack {
                    if p.loading && p.mirror == nil { ProgressView().controlSize(.large).tint(.white) }
                    else { Image(systemName: p.playing ? "pause.fill" : "play.fill").font(.system(size: 46)).contentTransition(.symbolEffect(.replace)) }
                }
                .frame(width: 64, height: 64).contentShape(Rectangle())
            }
            .accessibilityLabel(p.playing ? "Pause" : "Lecture")
            Spacer()
            Button { p.next() } label: { Image(systemName: "forward.fill").font(.system(size: 32)).frame(width: 64, height: 64).contentShape(Rectangle()) }.accessibilityLabel("Suivant").disabled(t.isLive)
            Spacer()
            SideButton(icon: p.repeatMode == "one" ? "repeat.1" : "repeat", on: p.repeatMode != "off") { p.cycleRepeat() }.accessibilityLabel("Répéter").disabled(t.isLive)
        }
        .buttonStyle(.plain)
    }

    var foot: some View {
        HStack {
            Spacer()
            FootButton(icon: "quote.bubble", on: panel == "lyrics") { withAnimation(.spring(duration: 0.4)) { panel = panel == "lyrics" ? nil : "lyrics" } }.accessibilityLabel("Paroles")
            Spacer()
            FootButton(icon: "slider.vertical.3", on: false) { Router.shared.present(.eq) }.accessibilityLabel("Égaliseur")
            Spacer()
            FootButton(icon: "hifispeaker", on: !live.targetName.isEmpty) { Router.shared.present(.devices) }.accessibilityLabel("Appareil de sortie")
            Spacer()
            FootButton(icon: "list.bullet", on: panel == "queue") { withAnimation(.spring(duration: 0.4)) { panel = panel == "queue" ? nil : "queue" } }.accessibilityLabel("À suivre")
            Spacer()
        }
    }

    func panelView(_ panel: String, _ t: Track) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                RemoteImage(url: t.thumbURL).frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(.system(size: 17, weight: .bold)).lineLimit(1)
                    Text(t.artistLine).font(.system(size: 15)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
                Spacer(minLength: 4)
                if !t.isLive {
                    let liked = lib.liked.contains(t.id)
                    RoundIcon(icon: liked ? "heart.fill" : "heart") { Task { await lib.toggleLike(t) } }
                    Menu { TrackMenuItems(t: t) } label: { RoundIconLabel(icon: "ellipsis") }
                }
            }
            .padding(.bottom, 6)
            if panel == "lyrics" { LyricsPanel() } else { QueuePanel() }
        }
        .transition(.opacity)
    }
}

func bigArt(_ t: Track) -> URL? {
    absURL(t.thumb.replacingOccurrences(of: "w120-h120", with: "w800-h800").replacingOccurrences(of: "w544-h544", with: "w800-h800"))
}

/// Fond du lecteur : couleur de la pochette, deux taches floutées, deux copies floutées de la pochette qui tournent.
struct NPBackground: View {
    var thumb: URL?
    var colors: [Color]
    var playing: Bool
    @State private var drift = false
    var body: some View {
        let c = colors.count >= 3 ? colors : [Color(white: 0.2), Color(white: 0.33), Color(white: 0.13)]
        GeometryReader { g in
            let s = max(g.size.width, g.size.height)
            ZStack {
                c[0]
                TimelineView(.animation(minimumInterval: 1 / 20, paused: !playing)) { tl in
                    let a = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 60) / 60 * 360
                    ZStack {
                        RemoteImage(url: thumb).frame(width: s, height: s).scaleEffect(1.4).rotationEffect(.degrees(a))
                        RemoteImage(url: thumb).frame(width: s, height: s).scaleEffect(1.4).rotationEffect(.degrees(-a)).opacity(0.5)
                    }
                    .saturation(1.6).blur(radius: 60).opacity(0.75)
                }
                .frame(width: g.size.width, height: g.size.height)
                .id(thumb)
                .transition(.opacity.animation(.easeInOut(duration: 1.2)))
                Circle().fill(c[1]).frame(width: s * 0.7).blur(radius: 80).opacity(0.9).blendMode(.softLight)
                    .offset(x: -g.size.width * 0.3 + (drift ? s * 0.1 : 0), y: -g.size.height * 0.3 + (drift ? s * 0.07 : 0))
                Circle().fill(c[2]).frame(width: s * 0.7).blur(radius: 80).opacity(0.9).blendMode(.softLight)
                    .offset(x: g.size.width * 0.3 - (drift ? s * 0.1 : 0), y: g.size.height * 0.3 - (drift ? s * 0.07 : 0))
                if Store.get("vis-style", "off") != "off" { VisualView(colors: c, playing: playing).opacity(0.85) }
                Color.black.opacity(0.28)
            }
            .frame(width: g.size.width, height: g.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear { if Store.get("np-drift", false) { withAnimation(.easeInOut(duration: 22).repeatForever(autoreverses: true)) { drift = true } } }
    }
}

struct RoundIconLabel: View {
    var icon: String
    var body: some View { Image(systemName: icon).font(.system(size: 15, weight: .semibold)).frame(width: 32, height: 32).background(.white.opacity(0.14), in: Circle()) }
}
struct RoundIcon: View {
    var icon: String
    var action: () -> Void
    var body: some View { Button(action: action) { RoundIconLabel(icon: icon) }.buttonStyle(.plain) }
}
struct SideButton: View {
    var icon: String, on: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 19, weight: .semibold)).frame(width: 40, height: 40)
                .foregroundStyle(on ? .white : .white.opacity(0.6)).background(on ? Color.white.opacity(0.18) : .clear, in: Circle())
        }
        .buttonStyle(.plain)
    }
}
struct FootButton: View {
    var icon: String, on: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 19, weight: .medium)).frame(width: 44, height: 44)
                .foregroundStyle(on ? .white : .white.opacity(0.65)).background(on ? Color.white.opacity(0.18) : .clear, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: paroles

struct LyricsPanel: View {
    @State private var p = Player.shared
    @State private var lines: [(t: Double, text: String)] = []
    @State private var text: String?
    @State private var srcName: String?
    @State private var loadedId: String?
    @State private var userScroll = Date.distantPast
    @State private var failed = false
    var body: some View {
        let ms = p.time * 1000 + 250
        let cur = lines.lastIndex { $0.t <= ms } ?? -1
        ScrollViewReader { sv in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !lines.isEmpty {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                            Text(l.text.isEmpty ? "…" : l.text)
                                .font(.system(size: 27, weight: .heavy)).tracking(-0.3)
                                .foregroundStyle(i == cur ? .white : .white.opacity(i < cur ? 0.45 : 0.32))
                                .blur(radius: i <= cur ? 0 : 0.6)
                                .scaleEffect(i == cur ? 1.03 : 1, anchor: .leading)
                                .animation(.easeOut(duration: 0.4), value: cur)
                                .id(i)
                                .onTapGesture { p.seek(l.t / 1000 + 0.05) }
                        }
                    } else if let text {
                        Text(text).font(.system(size: 21, weight: .heavy)).foregroundStyle(.white.opacity(0.85))
                    } else if failed {
                        Label("Pas de paroles pour ce titre.", systemImage: "music.mic").foregroundStyle(.white.opacity(0.7)).padding(.top, 40)
                    } else { ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, 40) }
                    if let srcName { Text(srcName).font(.caption).foregroundStyle(.white.opacity(0.5)) }
                }
                .padding(.top, 60).padding(.bottom, 200).padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04), .init(color: .black, location: 0.9), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            .simultaneousGesture(DragGesture().onChanged { _ in userScroll = Date() })
            .onChange(of: cur) {
                guard cur >= 0, Date().timeIntervalSince(userScroll) > 3 else { return }
                withAnimation(.easeInOut(duration: 0.5)) { sv.scrollTo(cur, anchor: UnitPoint(x: 0, y: 0.32)) }
            }
        }
        .task(id: p.current?.id) { await load() }
    }
    private func load() async {
        guard let t = p.current, t.id != loadedId else { return }
        loadedId = t.id; lines = []; text = nil; srcName = nil; failed = false
        let info = await p.trackInfo(t.id)
        let d = try? await yt("/lyrics" + q(["id": info["lyrics"].string, "title": t.title, "artist": t.artists.first?.name, "duration": t.duration.map { Int($0) }]), ttl: 86400)
        guard loadedId == t.id else { return }
        if let l = d?["lines"].array, !l.isEmpty { lines = l.map { ($0["t"].double ?? 0, $0["text"].string ?? "") } }
        else if let tx = d?["text"].string { text = tx } else { failed = true }
        srcName = d?["source"].string
    }
}

// MARK: file d'attente

struct QueuePanel: View {
    @State private var p = Player.shared
    var body: some View {
        let upcoming = p.queue.indices.filter { $0 > p.idx }
        let next = upcoming.filter { p.queue[$0].auto != true }, auto = upcoming.filter { p.queue[$0].auto == true }
        VStack(spacing: 0) {
            HStack {
                Text("À suivre").font(.system(size: 17, weight: .bold))
                Spacer()
                Button { p.setAutoplay(!p.autoplay) } label: {
                    Label("Auto", systemImage: "infinity").font(.system(size: 13.5, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(p.autoplay ? Color.white : .white.opacity(0.12), in: Capsule()).foregroundStyle(p.autoplay ? .black : .white.opacity(0.8))
                }
                Button { p.clearUpcoming() } label: { Text("Effacer").font(.system(size: 13.5, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 6).background(.white.opacity(0.12), in: Capsule()).foregroundStyle(.white.opacity(0.8)) }
            }
            .padding(.vertical, 10)
            List {
                if let c = p.current {
                    Section { QueueRow(t: c, playing: true) } header: { QueueHeader(text: p.source?.title.map { "En lecture depuis \($0)" } ?? "En lecture", icon: "waveform") }
                }
                if !next.isEmpty {
                    Section {
                        ForEach(next.prefix(150), id: \.self) { i in QueueRow(t: p.queue[i]).onTapGesture { p.jump(i) }.swipeActions { Button("Retirer", role: .destructive) { p.remove(i) } }.contextMenu { qMenu(i) } }
                            .onMove { from, to in move(next, from, to) }
                    } header: { QueueHeader(text: "À suivre", icon: "music.note.list") }
                }
                if !auto.isEmpty && p.autoplay {
                    Section {
                        ForEach(auto.prefix(60), id: \.self) { i in QueueRow(t: p.queue[i]).onTapGesture { p.jump(i) }.swipeActions { Button("Retirer", role: .destructive) { p.remove(i) } }.contextMenu { qMenu(i) } }
                            .onMove { from, to in move(auto, from, to) }
                    } header: { QueueHeader(text: "Lecture automatique : titres similaires", icon: "infinity") }
                }
                if next.isEmpty && auto.isEmpty { Text("Rien à suivre.").foregroundStyle(.white.opacity(0.6)).listRowBackground(Color.clear) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04), .init(color: .black, location: 0.9), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            .environment(\.editMode, .constant(.active))
        }
    }
    @ViewBuilder func qMenu(_ i: Int) -> some View {
        Button(role: .destructive) { p.remove(i) } label: { Label("Retirer de la file", systemImage: "xmark") }
        Button { let t = p.queue[i]; p.remove(i); p.playNext([t]) } label: { Label("Lire ensuite", systemImage: "text.line.first.and.arrowtriangle.forward") }
    }
    private func move(_ section: [Int], _ from: IndexSet, _ to: Int) {
        guard let f = from.first else { return }
        let src = section[f]
        let dst = to >= section.count ? section.last! : to > f ? section[to - 1] : section[to]
        p.move(src, dst)
    }
}

struct QueueHeader: View {
    var text: String, icon: String
    var body: some View { Label(text, systemImage: icon).font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.7)).textCase(nil) }
}

struct QueueRow: View {
    var t: Track
    var playing = false
    var body: some View {
        HStack(spacing: 10) {
            RemoteImage(url: t.thumbURL).frame(width: 42, height: 42).cardShape(5)
            VStack(alignment: .leading, spacing: 1) { Text(t.title).lineLimit(1); Text(t.artistLine).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1) }
            Spacer()
            if playing { EqBars(playing: Player.shared.playing) }
        }
        .foregroundStyle(.white)
        .listRowBackground(Color.clear)
        .contentShape(Rectangle())
    }
}

extension Notification.Name { static let musicPlayerPanel = Notification.Name("music.panel") }
