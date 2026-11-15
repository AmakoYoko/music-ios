import SwiftUI

struct RadioPage: View {
    func renew() {
        Router.shared.confirm = Confirm(title: "Changer l'adresse ?", message: "L'ancienne cessera de fonctionner partout où elle est enregistrée.", ok: "Changer", danger: false) {
            Task { do { try await Radio.shared.renew(); Toast.show("Nouvelle adresse prête", .ok) } catch { Toast.show(error.localizedDescription, .err) } }
        }
    }
    @State private var radio = Radio.shared
    @State private var player = Player.shared
    var body: some View {
        Loader(load: { try await Radio.shared.load() }) { _, reload in
            let d = radio.info, n = d["now"]
            Page(title: "Music Live", refresh: { await reload() }) {
                VStack(spacing: 12) {
                    RemoteImage(url: liveImg(n["thumb"].string)).frame(width: 250, height: 250).cardShape(12).shadow(radius: 14, y: 6)
                    HStack(spacing: 6) { LiveDot(); Text("En direct · Music Live").font(.footnote.weight(.semibold)).foregroundStyle(.secondary) }
                    Text(n["title"].string ?? "La radio démarre…").font(.title2.bold()).multilineTextAlignment(.center).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(n["artist"].string ?? "").font(.title3).foregroundStyle(Color.accent)
                    Button { radio.toggle() } label: {
                        if radio.loading { Label("Connexion…", systemImage: "hourglass") }
                        else { Label(radio.on ? "Arrêter" : "Écouter le direct", systemImage: radio.on ? "stop.fill" : "play.fill") }
                    }
                    .buttonStyle(.borderedProminent).tint(.accent).controlSize(.large)
                }
                .frame(maxWidth: .infinity).padding(.top, 8)
                if d["next"].exists { H2(title: "Ensuite"); LiveRow(t: d["next"]) }
                if !d["recent"].array.isEmpty { H2(title: "Déjà passés"); ForEach(Array(d["recent"].array.enumerated()), id: \.offset) { _, t in LiveRow(t: t) } }
                H2(title: "Écouter hors de l'appli")
                Text("Adresse à coller dans VLC, Home Assistant ou la voiture. Elle fonctionne sans connexion : ne la partage pas.").font(.subheadline).foregroundStyle(.secondary)
                ViewThatFits {
                HStack {
                    Button { UIPasteboard.general.string = d["url"].string; Toast.show("Adresse copiée", .ok) } label: { Label("Copier l'adresse", systemImage: "doc.on.doc") }
                    Button {
                        Router.shared.confirm = Confirm(title: "Changer l'adresse ?", message: "L'ancienne cessera de fonctionner partout où elle est enregistrée.", ok: "Changer", danger: false) {
                            Task { do { try await radio.renew(); Toast.show("Nouvelle adresse prête", .ok) } catch { Toast.show(error.localizedDescription, .err) } }
                        }
                    } label: { Label("Changer l'adresse", systemImage: "arrow.clockwise") }
                }
                VStack(alignment: .leading) {
                    Button { UIPasteboard.general.string = d["url"].string; Toast.show("Adresse copiée", .ok) } label: { Label("Copier l'adresse", systemImage: "doc.on.doc") }
                    Button { renew() } label: { Label("Changer l'adresse", systemImage: "arrow.clockwise") }
                }
                }
                .buttonStyle(.bordered).padding(.top, 10)
            }
        }
    }
}

func liveImg(_ u: String?) -> URL? { u.flatMap { absURL("/api/img?u=" + ($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0)) } }

struct LiveRow: View {
    var t: JSON
    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: liveImg(t["thumb"].string)).frame(width: 46, height: 46).cardShape(5)
            VStack(alignment: .leading) { Text(t["title"].string ?? "").lineLimit(1); Text(t["artist"].string ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            if let at = t["at"].double { Text(Date(timeIntervalSince1970: at / 1000).formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 5)
    }
}

struct SettingsPage: View {
    @State private var lib = Library.shared
    @State private var player = Player.shared
    @State private var live = Live.shared
    @State private var off = Offline.shared
    @State private var curl = ""
    @State private var busy = false
    @State private var autoLiked = Store.get("auto-liked", false)
    @State private var autoWifi = Store.get("auto-wifi", true)
    @State private var autoCar = Store.get("auto-car", false)
    @State private var vis = Store.get("vis-style", "off")
    @State private var react = Store.get("vis-react", false)
    @State private var drift = Store.get("np-drift", false)
    @State private var devName = Live.shared.name
    @State private var update: String?

    var body: some View {
        Form {
            Section("Importer depuis YouTube Music") { account }
            Section("Lecture") {
                Toggle(isOn: Binding(get: { player.autoplay }, set: { player.setAutoplay($0) })) { SettingLabel("Lecture automatique", "À la fin de la file, continuer avec des titres similaires", "infinity") }
                Toggle(isOn: Binding(get: { player.smart }, set: { player.setSmart($0) })) { SettingLabel("Enchaînement intelligent", "Saute les silences et les passages hors musique des clips (intro parlée, scène finale)", "scissors") }
                Picker(selection: Binding(get: { player.crossfade }, set: { player.setCrossfade($0) })) {
                    ForEach([0.0, 2, 4, 6, 8, 12], id: \.self) { v in Text(v == 0 ? "Désactivé" : "\(Int(v)) s").tag(v) }
                } label: { SettingLabel("Fondu enchaîné", "Transition entre deux titres (0 = enchaînement sans blanc)", "waveform.path") }
                Toggle(isOn: Binding(get: { player.automix }, set: { player.setAutomix($0) })) { SettingLabel("Auto mix", "Transitions façon DJ sur la file en cours : tempo calé, drop du suivant à la sortie, échange des basses (sinon fondu). Fonctionne aussi écran verrouillé.", "opticaldisc") }
                Picker(selection: $vis) { ForEach(Visual.styles, id: \.0) { Text($0.1).tag($0.0) } } label: { SettingLabel("Lecteur animé", "Animation aux couleurs de la pochette derrière le lecteur plein écran. Consommation énergétique élevée sur batterie.", "sparkles") }
                    .onChange(of: vis) { Store.set("vis-style", vis) }
                if vis != "off" { Toggle(isOn: $react) { SettingLabel("Réagir à la musique", "L'animation suit les basses et les attaques du morceau.", "waveform") }.onChange(of: react) { Store.set("vis-react", react) } }
                Toggle(isOn: $drift) { SettingLabel("Fond en mouvement", "Les couleurs du lecteur plein écran dérivent lentement. Consomme de la batterie.", "water.waves") }.onChange(of: drift) { Store.set("np-drift", drift) }
                Button { Router.shared.present(.eq) } label: { SettingLabel("Égaliseur", EQ.shared.on ? "Activé" : "Désactivé", "slider.vertical.3") }
                SettingLabel("Téléchargements à jour", "Les playlists téléchargées récupèrent seules leurs nouveaux titres · toujours", "arrow.clockwise")
                Toggle(isOn: $autoLiked) { SettingLabel("Titres J'aime hors ligne", "Chaque titre aimé est téléchargé automatiquement", "heart") }
                    .onChange(of: autoLiked) { Store.set("auto-liked", autoLiked); if autoLiked { Task { await off.autoSync(force: true) } } }
                Toggle(isOn: $autoWifi) { SettingLabel("Seulement en Wi-Fi", "Pas de téléchargement automatique sur réseau mobile", "wifi") }.onChange(of: autoWifi) { Store.set("auto-wifi", autoWifi) }
            }
            Section("Appareils") {
                HStack { SettingLabel("Nom de cet appareil", "Affiché dans « Appareil de sortie » sur tes autres appareils", "iphone"); TextField("Nom", text: $devName).multilineTextAlignment(.trailing).onSubmit { if !devName.isEmpty { live.rename(devName) } } }
                Button { Router.shared.present(.devices) } label: { SettingLabel("Appareils connectés", live.devices.map { $0.name + ($0.id == live.activeId ? " (lecture)" : "") }.joined(separator: " · ").ifEmpty("aucun"), "hifispeaker") }
                Toggle(isOn: $autoCar) { SettingLabel("Basculer sur la voiture", "Quand la voiture se connecte, la lecture en cours sur cet appareil passe dessus", "car") }.onChange(of: autoCar) { Store.set("auto-car", autoCar) }
            }
            Section("Application") {
                Button { Task { await checkUpdate() } } label: { SettingLabel("Mise à jour de l'appli", update ?? "Version \(appVersion) · les mises à jour arrivent par SideStore", "arrow.triangle.2.circlepath") }
            }
            Section("Hors ligne") {
                SettingLabel("Sur cet appareil", "\(bytes(off.totalSize)) téléchargés · cache de lecture \(bytes(AudioFiles.shared.usage)) · espace libre \(bytes(off.freeSpace))", "arrow.down.circle")
                Button(role: .destructive) {
                    Router.shared.confirm = Confirm(title: "Supprimer tous les téléchargements ?", message: "Les titres resteront écoutables en ligne.", ok: "Supprimer") { off.wipe() }
                } label: { SettingLabel("Tout supprimer", "Retire les titres téléchargés de cet appareil", "trash") }
                Button { AudioFiles.shared.clear(); ImageCache.shared.clear(); API.shared.wipeCache(); Toast.show("Cache vidé", .ok) } label: { SettingLabel("Vider le cache", "Pochettes, pages et titres récemment écoutés", "xmark.bin") }
            }
            Section("Compte Lamas") {
                Button(role: .destructive) { Session.value = nil; NotificationCenter.default.post(name: .musicSignedOut, object: nil) } label: { SettingLabel("Se déconnecter", "Music ne sera plus accessible sur cet appareil", "rectangle.portrait.and.arrow.right") }
            }
        }
        .navigationTitle("Réglages")
        .task { await lib.loadAccount() }
    }

    @ViewBuilder var account: some View {
        if lib.connected || lib.account["disabled"].bool == true {
            HStack(spacing: 12) {
                RemoteImage(url: absURL(img(lib.account["photo"], 120))).frame(width: 44, height: 44).clipShape(Circle())
                VStack(alignment: .leading) {
                    Text(lib.account["name"].string ?? "Compte connecté").bold()
                    Text("\(lib.account["handle"].string ?? "") · copie ses J'aime, artistes, albums et playlists dans ta bibliothèque Music (sans doublon)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button {
                busy = true
                Task {
                    do {
                        let n = try await yt("/import", body: [:])
                        Toast.show("Importé : \(n["likes"].int ?? 0) J'aime, \(n["artists"].int ?? 0) artistes, \(n["albums"].int ?? 0) albums, \(n["playlists"].int ?? 0) playlists", .ok, seconds: 5)
                        await lib.loadAccount()
                    } catch { Toast.show(error.localizedDescription, .err) }
                    busy = false
                }
            } label: { Label("Importer", systemImage: "square.and.arrow.down") }
            .disabled(busy || lib.account["disabled"].bool == true)
            Toggle(isOn: Binding(get: { lib.account["disabled"].bool ?? false }, set: { v in
                Task { do { _ = try await yt("/account/disabled", body: ["on": .bool(v)]); await lib.loadAccount() } catch { Toast.show(error.localizedDescription, .err) } }
            })) { SettingLabel("Ne plus utiliser le compte Google", "Music ne s'en sert plus (import, lecture des titres réservés). Réactivable à tout moment sans le reconnecter.", "shield.slash") }
            Button(role: .destructive) {
                Router.shared.confirm = Confirm(title: "Déconnecter YouTube Music ?", message: "Ta bibliothèque Music et ce qui a déjà été importé restent en place.", ok: "Déconnecter") {
                    Task { _ = try? await yt("/account", method: "DELETE"); await lib.loadAccount() }
                }
            } label: { Label("Déconnecter", systemImage: "rectangle.portrait.and.arrow.right") }
        } else {
            if lib.account["expired"].bool == true { Label("La session YouTube Music a expiré : reconnecte le compte.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            Text("Facultatif : Music fonctionne sans compte YouTube. Pour récupérer une fois tes J'aime, artistes, albums et playlists, ouvre music.youtube.com sur un ordinateur, outils de développement › Réseau, requête « browse » › Copier en cURL, puis colle ci-dessous.").font(.footnote).foregroundStyle(.secondary)
            TextField("curl 'https://music.youtube.com/youtubei/v1/browse?…' -H 'cookie: …'", text: $curl, axis: .vertical).font(.caption.monospaced()).lineLimit(3...8)
            Button {
                busy = true
                Task {
                    do { let r = try await yt("/account", body: ["headers": .str(curl)]); Toast.show("Connecté : \(r["name"].string ?? "")", .ok); curl = ""; await lib.loadAccount() }
                    catch { Toast.show(error.localizedDescription, .err) }
                    busy = false
                }
            } label: { Label("Connecter", systemImage: "link") }
            .disabled(busy || curl.isEmpty)
        }
    }

    private var appVersion: String { "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"))" }
    private func checkUpdate() async {
        update = "Recherche…"
        guard let (d, _) = try? await URLSession.shared.data(from: URL(string: "https://api.github.com/repos/AmakoYoko/music-ios/releases/tags/latest")!), let j = JSON.parse(d),
              let name = j["name"].string, let n = Int(name.split(separator: " ").last ?? "") else { update = "Impossible de vérifier"; return }
        let mine = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
        update = n > mine ? "Version \(n) disponible : mets à jour Music dans SideStore" : "Music est à jour"
    }
}

struct SettingLabel: View {
    var title: String, sub: String, icon: String
    init(_ title: String, _ sub: String, _ icon: String) { self.title = title; self.sub = sub; self.icon = icon }
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) { Text(title).foregroundStyle(.primary); Text(sub).font(.caption).foregroundStyle(.secondary) }
        } icon: { Image(systemName: icon).foregroundStyle(Color.accent) }
    }
}

extension String { func ifEmpty(_ d: String) -> String { isEmpty ? d : self } }
