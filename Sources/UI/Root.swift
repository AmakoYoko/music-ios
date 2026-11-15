import AuthenticationServices
import SwiftUI

@main
struct MusicApp: App {
    init() { Session.install() }
    var body: some Scene { WindowGroup { Root().tint(.accent) } }
}

struct Root: View {
    @State private var signedIn = Session.value != nil
    var body: some View {
        Group {
            if signedIn { Main() } else { LoginView { signedIn = true } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .musicSignedOut)) { _ in
            if Session.value == nil || signedIn { Session.value = nil; signedIn = false }
        }
    }
}

struct Main: View {
    @State private var router = Router.shared
    @State private var player = Player.shared
    @State private var toast = Toast.shared
    @State private var prompt = Prompt.shared
    @State private var started = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            tabs
        }
        .overlay(alignment: .top) { ToastView(item: toast.current) }
        // une seule fenêtre à la fois : par-dessus le lecteur quand il est ouvert (sinon iOS ferme le lecteur pour l'afficher)
        .sheet(item: Binding(get: { router.nowPlaying || router.listening ? nil : router.sheet }, set: { router.sheet = $0 })) { s in sheet(s) }
        .fullScreenCover(isPresented: $router.nowPlaying) {
            NowPlayingView()
                .sheet(item: Binding(get: { router.nowPlaying ? router.sheet : nil }, set: { router.sheet = $0 })) { s in sheet(s) }
                .alert(router.confirm?.title ?? "", isPresented: Binding(get: { router.confirm != nil }, set: { if !$0 { router.confirm = nil } }), presenting: router.confirm) { c in
                    Button(c.ok, role: c.danger ? .destructive : nil) { c.run() }
                    Button("Annuler", role: .cancel) {}
                } message: { c in Text(c.message) }
                .overlay(alignment: .top) { ToastView(item: toast.current) }
        }
        .fullScreenCover(isPresented: $router.listening) { ListenView() }
        .alert(router.confirm?.title ?? "", isPresented: Binding(get: { router.confirm != nil }, set: { if !$0 { router.confirm = nil } }), presenting: router.confirm) { c in
            Button(c.ok, role: c.danger ? .destructive : nil) { c.run() }
            Button("Annuler", role: .cancel) {}
        } message: { c in Text(c.message) }
        .alert(prompt.title, isPresented: $prompt.shown) {
            TextField(prompt.placeholder, text: $prompt.value)
            Button(prompt.ok) { let v = prompt.value.trimmingCharacters(in: .whitespaces); if !v.isEmpty { prompt.run?(v) } }
            Button("Annuler", role: .cancel) {}
        }
        .task {
            guard !started else { return }
            started = true
            // lancement d'une liste : le lecteur plein écran s'ouvre tout de suite
            player.on { w in if w == "start" { Router.shared.nowPlaying = true } }
            player.restore()
            Live.shared.start()
            await Library.shared.loadAccount(cached: true)
            await Library.shared.refreshMine()
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await Offline.shared.autoSync()
        }
        .onChange(of: phase) {
            guard phase == .active else { if phase == .background { player.save(now: true) }; return }
            if !Live.shared.connected { Live.shared.connect() }
            Task { await Offline.shared.autoSync() }
        }
    }

    @ViewBuilder func sheet(_ s: Sheet) -> some View {
        switch s {
        case .addTo(let t): AddToSheet(tracks: t)
        case .versions(let t): VersionsSheet(t: t)
        case .editMpl(let p): EditMplSheet(p: p)
        case .devices: DevicePicker()
        case .eq: EQSheet()
        case .newPlaylist(let t): Color.clear.onAppear { router.sheet = nil; newPlaylist(t) }
        }
    }

    var tabs: some View {
        TabView(selection: $router.tab) {
            stack(.home) { HomePage() }.tabItem { Label("Accueil", systemImage: "house.fill") }.tag(Tab.home)
            stack(.explore) { ExplorePage() }.tabItem { Label("Explorer", systemImage: "square.grid.2x2.fill") }.tag(Tab.explore)
            stack(.library) { LibraryPage(tab: "playlists") }.tabItem { Label("Bibliothèque", systemImage: "square.stack.fill") }.tag(Tab.library)
            stack(.downloads) { DownloadsPage() }.tabItem { Label("Téléchargés", systemImage: "arrow.down.circle.fill") }.tag(Tab.downloads)
            stack(.search) { SearchPage() }.tabItem { Label("Recherche", systemImage: "magnifyingglass") }.tag(Tab.search)
        }
        .modifier(MiniPlayerHost(show: player.current != nil))
    }

    func stack<V: View>(_ t: Tab, @ViewBuilder _ root: () -> V) -> some View {
        NavigationStack(path: router.binding(t)) {
            root().navigationDestination(for: Route.self) { destination($0) }
        }
    }
}

/// Mini-lecteur au-dessus de la barre d'onglets (accessoire natif d'iOS 26, sinon encart).
struct MiniPlayerHost: ViewModifier {
    var show: Bool
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if show { content.tabViewBottomAccessory { MiniPlayer() } } else { content }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                if show { MiniPlayer().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 8).padding(.bottom, 54) }
            }
        }
    }
}

struct ToastView: View {
    var item: Toast.Item?
    var body: some View {
        ZStack {
            if let i = item {
                HStack(spacing: 10) {
                    Image(systemName: ["ok": "checkmark.circle.fill", "err": "exclamationmark.octagon.fill", "warn": "exclamationmark.triangle.fill", "info": "info.circle.fill"][k(i.kind)] ?? "info.circle.fill")
                        .foregroundStyle(i.kind == .err ? .red : i.kind == .warn ? .orange : i.kind == .ok ? .green : .accent)
                    Text(i.text).font(.subheadline).lineLimit(3)
                    if let a = i.action { Button(a) { i.run?(); Toast.shared.current = nil }.font(.subheadline.bold()) }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .padding(.top, 8).padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { Toast.shared.current = nil }
                .id(i.id)
            }
        }
        .animation(.spring(duration: 0.35), value: item)
    }
    private func k(_ x: Toast.Kind) -> String { switch x { case .ok: "ok"; case .err: "err"; case .warn: "warn"; case .info: "info" } }
}

// MARK: connexion Lamas ID

final class AuthContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}

struct LoginView: View {
    let done: () -> Void
    @State private var error: String?
    private let ctx = AuthContext()
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "music.note").font(.system(size: 64, weight: .semibold)).foregroundStyle(Color.accent)
            Text("Music").font(.largeTitle.bold())
            Text("Connecte-toi avec ton compte Lamas.").foregroundStyle(.secondary)
            Spacer()
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            Button(action: login) { Text("Se connecter").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(32)
    }
    private func login() {
        let s = ASWebAuthenticationSession(url: baseURL.appendingPathComponent("auth/app"), callbackURLScheme: "lamasmusic") { url, err in
            guard let url, let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "s" })?.value else {
                if let err, (err as? ASWebAuthenticationSessionError)?.code != .canceledLogin { error = err.localizedDescription }
                return
            }
            Session.value = v
            done()
        }
        s.presentationContextProvider = ctx
        s.start()
    }
}
