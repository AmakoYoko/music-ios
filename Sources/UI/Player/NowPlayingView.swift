import AVKit
import MediaPlayer
import SwiftUI

struct MiniPlayer: View {
    @State private var p = Player.shared
    @State private var live = Live.shared
    var body: some View {
        if let t = p.current {
            HStack(spacing: 10) {
                RemoteImage(url: t.thumbURL).frame(width: 40, height: 40).cardShape(6)
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

/// Lecteur plein écran façon Apple Music : fond aux couleurs de la pochette, paroles synchronisées, file d'attente.
struct NowPlayingView: View {
    @State private var p = Player.shared
    @State private var lib = Library.shared
    @State private var live = Live.shared
    @State private var off = Offline.shared
    @State private var colors: [Color] = []
    @State private var panel: String? = nil // lyrics | queue
    @State private var scrub: Double?
    @State private var drift = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let t = p.current {
            ZStack {
                background(t)
                VStack(spacing: 0) {
                    Capsule().fill(.white.opacity(0.4)).frame(width: 40, height: 5).padding(.top, 8)
                    if let panel { compactHeader(t).padding(.top, 14); panelView(panel).frame(maxHeight: .infinity) }
                    else {
                        Spacer(minLength: 10)
                        RemoteImage(url: absURL(t.thumb.replacingOccurrences(of: "w120-h120", with: "w800-h800")))
                            .aspectRatio(1, contentMode: .fit).cardShape(12)
                            .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
                            .scaleEffect(p.playing || p.loading ? 1 : 0.82)
                            .animation(.spring(duration: 0.45, bounce: 0.3), value: p.playing)
                            .padding(.horizontal, 8)
                        Spacer(minLength: 10)
                        titleRow(t)
                    }
                    if !t.isLive { seekBar(t).padding(.top, 14) } else { HStack { LiveDot(); Text("En direct").font(.footnote.weight(.semibold)) }.padding(.top, 14) }
                    controls(t).padding(.vertical, 18)
                    VolumeSlider().frame(height: 34)
                    bottomBar.padding(.top, 10).padding(.bottom, 4)
                }
                .padding(.horizontal, 26)
                .foregroundStyle(.white)
            }
            .task(id: t.thumb) {
                if let u = t.thumbURL, let i = await ImageCache.shared.image(u) { withAnimation(.easeInOut(duration: 0.8)) { colors = ImageCache.shared.palette(i) } }
            }
            .gesture(DragGesture().onEnded { v in if v.translation.height > 110 && abs(v.translation.width) < 80 { dismiss() } })
            .onReceive(NotificationCenter.default.publisher(for: .musicPlayerPanel)) { n in panel = n.object as? String }
        } else {
            Color.black.onAppear { dismiss() }
        }
    }

    @ViewBuilder func background(_ t: Track) -> some View {
        let c = colors.count >= 3 ? colors : [Color(white: 0.25), Color(white: 0.35), Color(white: 0.15)]
        ZStack {
            LinearGradient(colors: [c[1], c[0], c[2]], startPoint: drift ? .topTrailing : .topLeading, endPoint: drift ? .bottomLeading : .bottomTrailing)
            if Store.get("vis-style", "off") != "off" { VisualView(colors: c, playing: p.playing).opacity(0.9) }
            Color.black.opacity(0.18)
        }
        .ignoresSafeArea()
        .onAppear { if Store.get("np-drift", false) { withAnimation(.easeInOut(duration: 12).repeatForever(autoreverses: true)) { drift = true } } }
    }

    func titleRow(_ t: Track) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).font(.title3.bold()).lineLimit(1)
                Button(t.artistLine) { if let id = t.artists.first?.id { dismiss(); Router.shared.open(.artist(id)) } }
                    .font(.title3).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            Spacer()
            if !t.isLive {
                let liked = lib.liked.contains(t.id)
                Button { Task { await lib.toggleLike(t) } } label: { Image(systemName: liked ? "heart.fill" : "heart").font(.title3).frame(width: 36, height: 36).background(.white.opacity(0.15), in: Circle()) }
                    .accessibilityLabel(liked ? "Je n'aime plus" : "J'aime")
                Menu { TrackMenuItems(t: t) } label: { Image(systemName: "ellipsis").font(.title3).frame(width: 36, height: 36).background(.white.opacity(0.15), in: Circle()) }
            }
        }
    }

    func compactHeader(_ t: Track) -> some View {
        HStack(spacing: 12) {
            RemoteImage(url: t.thumbURL).frame(width: 58, height: 58).cardShape(6)
            VStack(alignment: .leading, spacing: 2) { Text(t.title).font(.headline).lineLimit(1); Text(t.artistLine).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1) }
            Spacer()
            let liked = lib.liked.contains(t.id)
            Button { Task { await lib.toggleLike(t) } } label: { Image(systemName: liked ? "heart.fill" : "heart").font(.title3) }
            Menu { TrackMenuItems(t: t) } label: { Image(systemName: "ellipsis.circle").font(.title3) }
        }
    }

    func seekBar(_ t: Track) -> some View {
        let d = max(p.duration, 1)
        let v = scrub ?? p.time
        return VStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Slider(value: Binding(get: { min(v, d) }, set: { scrub = $0 }), in: 0...d) { editing in
                    if !editing, let s = scrub { p.seek(s); scrub = nil }
                }
                .tint(.white)
                if let st = p.mixStart, !p.mixing, st < d {
                    GeometryReader { g in Circle().fill(Color.accent).frame(width: 6, height: 6).position(x: g.size.width * st / d, y: g.size.height / 2) }.allowsHitTesting(false)
                }
            }
            HStack {
                Text(clock(v)); Spacer()
                badge(t)
                Spacer(); Text("-" + clock(max(0, d - v)))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
        }
    }

    @ViewBuilder func badge(_ t: Track) -> some View {
        if p.mixing { Label("AutoMix", systemImage: "opticaldisc").font(.caption2.weight(.bold)).padding(.horizontal, 8).padding(.vertical, 2).background(.white.opacity(0.2), in: Capsule()) }
        else if off.has(t.id) { Text("Téléchargé").font(.caption2.weight(.semibold)) }
        else if t.explicit { Text("Explicite").font(.caption2.weight(.semibold)) }
    }

    func controls(_ t: Track) -> some View {
        HStack {
            Button { p.toggleShuffle() } label: { Image(systemName: "shuffle").foregroundStyle(p.shuffle ? Color.accent : .white.opacity(0.7)) }.accessibilityLabel("Aléatoire").disabled(t.isLive)
            Spacer()
            Button { p.prev() } label: { Image(systemName: "backward.fill").font(.system(size: 30)) }.accessibilityLabel("Précédent").disabled(t.isLive)
            Spacer()
            PlayPauseButton(size: 40)
            Spacer()
            Button { p.next() } label: { Image(systemName: "forward.fill").font(.system(size: 30)) }.accessibilityLabel("Suivant").disabled(t.isLive)
            Spacer()
            Button { p.cycleRepeat() } label: { Image(systemName: p.repeatMode == "one" ? "repeat.1" : "repeat").foregroundStyle(p.repeatMode != "off" ? Color.accent : .white.opacity(0.7)) }.accessibilityLabel("Répéter").disabled(t.isLive)
        }
        .font(.title3)
    }

    var bottomBar: some View {
        HStack {
            Button { withAnimation { panel = panel == "lyrics" ? nil : "lyrics" } } label: { Image(systemName: "quote.bubble").foregroundStyle(panel == "lyrics" ? Color.accent : .white.opacity(0.8)) }.accessibilityLabel("Paroles")
            Spacer()
            AirPlayButton().frame(width: 30, height: 30)
            Spacer()
            Button { Router.shared.present(.devices) } label: { Image(systemName: "hifispeaker.2").foregroundStyle(!live.targetName.isEmpty || live.devices.count > 1 ? Color.accent : .white.opacity(0.8)) }.accessibilityLabel("Appareil de sortie")
            Spacer()
            Button { Router.shared.present(.eq) } label: { Image(systemName: "slider.vertical.3").foregroundStyle(.white.opacity(0.8)) }.accessibilityLabel("Égaliseur")
            Spacer()
            Button { withAnimation { panel = panel == "queue" ? nil : "queue" } } label: { Image(systemName: "list.bullet").foregroundStyle(panel == "queue" ? Color.accent : .white.opacity(0.8)) }.accessibilityLabel("À suivre")
        }
        .font(.title3)
        .padding(.horizontal, 20)
    }

    @ViewBuilder func panelView(_ panel: String) -> some View {
        if panel == "lyrics" { LyricsPanel() } else { QueuePanel() }
    }
}

extension Notification.Name { static let musicPlayerPanel = Notification.Name("music.panel") }

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white.withAlphaComponent(0.8)
        v.activeTintColor = UIColor(Color.accent)
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct VolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: .zero)
        v.showsVolumeSlider = true
        v.tintColor = .white
        return v
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
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
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(i == cur ? .white : .white.opacity(i < cur ? 0.45 : 0.3))
                                .blur(radius: i == cur || abs(i - cur) > 6 ? 0 : 0.6)
                                .id(i)
                                .onTapGesture { p.seek(l.t / 1000 + 0.05) }
                        }
                    } else if let text {
                        Text(text).font(.title3.weight(.semibold))
                    } else if failed {
                        Label("Pas de paroles pour ce titre.", systemImage: "music.mic").foregroundStyle(.white.opacity(0.7)).padding(.top, 40)
                    } else { ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, 40) }
                    if let srcName { Text(srcName).font(.caption).foregroundStyle(.white.opacity(0.5)) }
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
                Text("À suivre").font(.headline)
                Spacer()
                Button { p.setAutoplay(!p.autoplay) } label: { Label("Auto", systemImage: "infinity").font(.subheadline.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 4).background(p.autoplay ? Color.white.opacity(0.3) : .clear, in: Capsule()) }
                Button("Effacer") { p.clearUpcoming() }.font(.subheadline)
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
