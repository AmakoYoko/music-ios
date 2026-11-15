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

struct MusicShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayMixIntent(), phrases: ["Lis mon Mix du jour dans \(.applicationName)", "Mix du jour dans \(.applicationName)"], shortTitle: "Mix du jour", systemImageName: "sparkles")
        AppShortcut(intent: PlayLikedIntent(), phrases: ["Lis mes titres J'aime dans \(.applicationName)", "Mes J'aime dans \(.applicationName)"], shortTitle: "Titres J'aime", systemImageName: "heart.fill")
        AppShortcut(intent: PlayLiveIntent(), phrases: ["Lance \(.applicationName) Live", "Mets la radio dans \(.applicationName)"], shortTitle: "Music Live", systemImageName: "dot.radiowaves.left.and.right")
        AppShortcut(intent: PlayDownloadsIntent(), phrases: ["Lis mes téléchargements dans \(.applicationName)"], shortTitle: "Téléchargés", systemImageName: "arrow.down.circle.fill")
        AppShortcut(intent: PlaySearchIntent(), phrases: ["Lis de la musique dans \(.applicationName)", "Cherche dans \(.applicationName)"], shortTitle: "Lire…", systemImageName: "magnifyingglass")
        AppShortcut(intent: NextTrackIntent(), phrases: ["Titre suivant dans \(.applicationName)"], shortTitle: "Suivant", systemImageName: "forward.fill")
    }
}
