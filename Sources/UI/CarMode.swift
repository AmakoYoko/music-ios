import SwiftUI

/// Mode voiture : interface simplifiée, gros boutons, pour le téléphone posé sur son support.
struct CarModeView: View {
    @State private var p = Player.shared
    @State private var lib = Library.shared
    @State private var smart: [JSON] = []
    @State private var settings = false
    var body: some View {
        GeometryReader { g in
            let wide = g.size.width > g.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                if let t = p.current {
                    RemoteImage(url: t.thumbURL).blur(radius: 60).opacity(0.5).ignoresSafeArea()
                }
                let layout = wide ? AnyLayout(HStackLayout(spacing: 30)) : AnyLayout(VStackLayout(spacing: 24))
                layout {
                    if let t = p.current {
                        RemoteImage(url: absURL(t.thumb.replacingOccurrences(of: "w120-h120", with: "w800-h800"))).aspectRatio(1, contentMode: .fit).cardShape(16).frame(maxWidth: wide ? g.size.height * 0.7 : .infinity)
                        VStack(spacing: 20) {
                            Text(t.title).font(.system(size: 30, weight: .bold)).lineLimit(2).multilineTextAlignment(.center)
                            Text(t.artistLine).font(.title2).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                            if !t.isLive && p.duration > 0 { ProgressView(value: min(1, p.time / p.duration)).tint(.white) }
                            HStack(spacing: 0) {
                                big("backward.fill") { p.prev() }
                                Button { p.toggle() } label: { Image(systemName: p.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 96)) }.frame(maxWidth: .infinity)
                                big("forward.fill") { p.next() }
                            }
                            HStack(spacing: 0) {
                                big(lib.liked.contains(t.id) ? "heart.fill" : "heart", 34) { Task { await lib.toggleLike(t) } }
                                big("shuffle", 34) { p.toggleShuffle() }.foregroundStyle(p.shuffle ? Color.accent : .white)
                                big("gearshape.fill", 34) { settings = true }
                            }
                        }
                    } else {
                        VStack(spacing: 18) {
                            Text("Music").font(.largeTitle.bold())
                            quick("Titres J'aime", "heart.fill") { Task { if let pl = try? await yt("/playlist?id=LM&limit=5000") { p.playList(parseTracks(pl["tracks"]), source: Source(title: "Titres J'aime", href: "#/playlist/LM"), shuffle: true) } } }
                            ForEach(Array(smart.prefix(3).enumerated()), id: \.offset) { _, s in quick(s["title"].string ?? "", "sparkles") { p.playList(smartTracks(s), source: Source(title: s["title"].string, href: "#/smart/\(s["id"].string ?? "")")) } }
                            quick("Music Live", "dot.radiowaves.left.and.right") { Radio.shared.toggle() }
                            quick("Téléchargés", "arrow.down.circle.fill") { p.playList(Offline.shared.tracks, source: Source(title: "Téléchargés", href: "#/downloads"), shuffle: true) }
                            big("gearshape.fill", 34) { settings = true }
                        }
                    }
                }
                .padding(30)
                .foregroundStyle(.white)
            }
        }
        .statusBarHidden()
        .task { smart = await smartLists() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .confirmationDialog("Mode voiture", isPresented: $settings) {
            Button("Quitter le mode voiture") { Store.set("car-mode", false); Router.shared.carMode = false }
            Button("Appareil de sortie") { Router.shared.present(.devices) }
            Button("Annuler", role: .cancel) {}
        }
    }
    func big(_ icon: String, _ size: CGFloat = 50, _ a: @escaping () -> Void) -> some View {
        Button(action: a) { Image(systemName: icon).font(.system(size: size)).frame(maxWidth: .infinity, minHeight: 80) }
    }
    func quick(_ t: String, _ icon: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) { Label(t, systemImage: icon).font(.title2.bold()).frame(maxWidth: .infinity, minHeight: 72).background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 18)) }
    }
}
