import AppIntents
import UIKit

/// Siri et Raccourcis : « Dis Siri, lis mon Mix du jour dans Music »…
struct PlayMixIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Lire le Mix du jour"
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let mix = await smartLists().first { $0["id"].string == "mix" }
        guard let mix else { return .result(dialog: "Le Mix du jour n'est pas encore prêt.") }
        await MainActor.run { Player.shared.playList(smartTracks(mix), source: Source(title: mix["title"].string, href: "#/smart/mix")) }
        return .result(dialog: "C'est parti pour le Mix du jour.")
    }
}
struct PlayLikedIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Lire mes titres J'aime"
    func perform() async throws -> some IntentResult {
        let p = try await yt("/playlist?id=LM&limit=5000")
        await MainActor.run { Player.shared.playList(parseTracks(p["tracks"]), source: Source(title: "Titres J'aime", href: "#/playlist/LM"), shuffle: true) }
        return .result()
    }
}
struct PlayLiveIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Écouter Music Live"
    func perform() async throws -> some IntentResult {
        await MainActor.run { if !Radio.shared.on { Radio.shared.toggle() } }
        return .result()
    }
}
struct PlayDownloadsIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Lire mes téléchargements"
    func perform() async throws -> some IntentResult {
        await MainActor.run { Player.shared.playList(Offline.shared.tracks, source: Source(title: "Téléchargés", href: "#/downloads"), shuffle: true) }
        return .result()
    }
}
struct PlaySearchIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Lire un titre ou un artiste"
    @Parameter(title: "Recherche") var query: String
    static var parameterSummary: some ParameterSummary { Summary("Lire \(\.$query)") }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let r = try await yt("/search" + q(["q": query, "limit": 20]))
        let all = r.array
        if let top = all.first(where: { $0["category"].string == "Top result" }), kindOf(top) != .song, kindOf(top) != .other {
            await playCollection(top, kindOf(top))
            return .result(dialog: "Je lance \(itemTitle(top)).")
        }
        guard let t = all.compactMap({ track($0) }).first else { return .result(dialog: "Je n'ai rien trouvé pour \(query).") }
        await MainActor.run { Player.shared.playRadio(t) }
        return .result(dialog: "Je lance \(t.title).")
    }
}

struct PlayPlaylistIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Lire une playlist"
    @Parameter(title: "Playlist") var name: String
    static var parameterSummary: some ParameterSummary { Summary("Lire la playlist \(\.$name)") }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let n = fold(name)
        // playlists Music, puis albums et playlists téléchargés, puis la recherche
        if let m = await Library.shared.refreshMine().first(where: { fold($0.title).contains(n) }) {
            let p = try await Library.shared.mpl(m.id)
            await MainActor.run { Player.shared.playList(p.tracks, source: Source(title: m.title, href: "#/mpl/\(m.id)")) }
            return .result(dialog: "Je lance \(m.title).")
        }
        let off = await MainActor.run { (Offline.shared.collections, Offline.shared.tracks) }
        if let c = off.0.first(where: { fold($0.meta.title).contains(n) }) {
            let ts = c.ids.compactMap { id in off.1.first { $0.id == id } }
            if !ts.isEmpty {
                await MainActor.run { Player.shared.playList(ts, source: Source(title: c.meta.title, href: c.meta.href)) }
                return .result(dialog: "Je lance \(c.meta.title).")
            }
        }
        let r = try await yt("/search" + q(["q": name, "limit": 20]))
        guard let it = r.array.first(where: { if case .playlist = kindOf($0) { return true }; if case .album = kindOf($0) { return true }; return false }) else {
            return .result(dialog: "Je n'ai pas trouvé de playlist « \(name) ».")
        }
        await playCollection(it, kindOf(it))
        return .result(dialog: "Je lance \(itemTitle(it)).")
    }
}
struct SleepTimerIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Minuteur de sommeil"
    @Parameter(title: "Minutes (0 pour annuler)", default: 30) var minutes: Int
    static var parameterSummary: some ParameterSummary { Summary("Arrêter la musique dans \(\.$minutes) minutes") }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run { Player.shared.sleep(in: Double(minutes)) }
        return .result(dialog: minutes > 0 ? "La musique s'arrêtera dans \(minutes) minutes." : "Minuteur de sommeil annulé.")
    }
}
struct LikeCurrentIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "J'aime ce titre"
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let t = await Player.shared.current else { return .result(dialog: "Rien n'est en lecture.") }
        if await Library.shared.liked.contains(t.id) { return .result(dialog: "\(t.title) est déjà dans tes J'aime.") }
        await Library.shared.toggleLike(t)
        return .result(dialog: "\(t.title) ajouté à tes J'aime.")
    }
}
struct WhatsPlayingIntent: AppIntent {
    static var title: LocalizedStringResource = "Quel est ce titre ?"
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let t = await Player.shared.current else { return .result(dialog: "Rien n'est en lecture.") }
        return .result(dialog: t.artistLine.isEmpty ? "C'est \(t.title)." : "C'est \(t.title), de \(t.artistLine).")
    }
}
struct ShuffleIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Lecture aléatoire"
    func perform() async throws -> some IntentResult {
        await MainActor.run { Player.shared.toggleShuffle() }
        return .result()
    }
}
struct RadioFromCurrentIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Radio du titre en cours"
    func perform() async throws -> some IntentResult {
        await MainActor.run { if let t = Player.shared.current, !t.isLive { Player.shared.startRadio(t) } }
        return .result()
    }
}
private func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }

struct MusicShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayMixIntent(), phrases: ["Lis mon Mix du jour dans \(.applicationName)", "Mix du jour dans \(.applicationName)"], shortTitle: "Mix du jour", systemImageName: "sparkles")
        AppShortcut(intent: PlayLikedIntent(), phrases: ["Lis mes titres J'aime dans \(.applicationName)", "Mes J'aime dans \(.applicationName)"], shortTitle: "Titres J'aime", systemImageName: "heart.fill")
        AppShortcut(intent: PlayLiveIntent(), phrases: ["Lance \(.applicationName) Live", "Mets la radio dans \(.applicationName)"], shortTitle: "Music Live", systemImageName: "dot.radiowaves.left.and.right")
        AppShortcut(intent: PlayDownloadsIntent(), phrases: ["Lis mes téléchargements dans \(.applicationName)"], shortTitle: "Téléchargés", systemImageName: "arrow.down.circle.fill")
        AppShortcut(intent: PlaySearchIntent(), phrases: ["Lis de la musique dans \(.applicationName)", "Cherche dans \(.applicationName)"], shortTitle: "Lire…", systemImageName: "magnifyingglass")
        AppShortcut(intent: NextTrackIntent(), phrases: ["Titre suivant dans \(.applicationName)"], shortTitle: "Suivant", systemImageName: "forward.fill")
        AppShortcut(intent: PlayPlaylistIntent(), phrases: ["Lis une playlist dans \(.applicationName)", "Lance une playlist dans \(.applicationName)"], shortTitle: "Playlist…", systemImageName: "music.note.list")
        AppShortcut(intent: SleepTimerIntent(), phrases: ["Minuteur de sommeil dans \(.applicationName)", "Arrête \(.applicationName) plus tard"], shortTitle: "Minuteur de sommeil", systemImageName: "moon.zzz.fill")
        AppShortcut(intent: LikeCurrentIntent(), phrases: ["J'aime ce titre dans \(.applicationName)", "Ajoute ce titre à mes J'aime dans \(.applicationName)"], shortTitle: "J'aime", systemImageName: "heart")
        AppShortcut(intent: WhatsPlayingIntent(), phrases: ["Quel est ce titre dans \(.applicationName)", "Qu'est-ce qui passe dans \(.applicationName)"], shortTitle: "Quel titre ?", systemImageName: "questionmark.circle")
    }
}
