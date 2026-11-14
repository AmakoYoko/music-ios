import AuthenticationServices
import SwiftUI

@main
struct MusicApp: App {
    init() { Session.install() }
    var body: some Scene { WindowGroup { Root().tint(.pink) } }
}

struct Root: View {
    @State private var signedIn = Session.value != nil
    var body: some View {
        if signedIn {
            Tabs(signOut: { Session.value = nil; signedIn = false })
        } else {
            LoginView { signedIn = true }
        }
    }
}

struct Tabs: View {
    let signOut: () -> Void
    @State private var showPlayer = false
    @State private var player = Player.shared
    var body: some View {
        TabView {
            NavigationStack { LibraryView(signOut: signOut) }
                .tabItem { Label("Bibliothèque", systemImage: "square.stack.fill") }
            NavigationStack { SearchView() }
                .tabItem { Label("Recherche", systemImage: "magnifyingglass") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if player.current != nil {
                MiniPlayer().onTapGesture { showPlayer = true }
                    .padding(.bottom, 49) // au-dessus de la barre d'onglets
            }
        }
        .sheet(isPresented: $showPlayer) { NowPlayingView() }
    }
}

// MARK: - Connexion Lamas ID

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
            Image(systemName: "music.note").font(.system(size: 64, weight: .semibold)).foregroundStyle(.pink)
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
