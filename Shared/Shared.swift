import AppIntents
import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif
#if canImport(ActivityKit)
import ActivityKit

/// Activité en direct (écran verrouillé, Dynamic Island) : mise à jour par l'appli, sans notification push.
struct NowAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String; var artist: String; var playing: Bool; var live: Bool
        var pos: Double; var dur: Double
        var start: Date?     // début du titre (lecture en cours) : la barre avance seule
        var art: String      // change avec la pochette
    }
}
#endif

/// Données partagées entre l'appli et le widget (groupe d'applis).
enum SharedNow {
    static let group = "group.one.lamas.music"
    static var defaults: UserDefaults? { UserDefaults(suiteName: group) }
    static var artURL: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("now.jpg") }
    /// Petite pochette pour l'activité en direct (iOS refuse les images trop lourdes).
    static var smallArtURL: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("now-small.jpg") }
    struct Now: Codable { var title: String; var artist: String; var playing: Bool; var live: Bool; var id: String }
    static func read() -> Now? { defaults?.data(forKey: "now").flatMap { try? JSONDecoder().decode(Now.self, from: $0) } }
    static func write(_ n: Now?) {
        if let n, let d = try? JSONEncoder().encode(n) { defaults?.set(d, forKey: "now") } else { defaults?.removeObject(forKey: "now") }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

// Commandes du widget : exécutées dans l'appli (AudioPlaybackIntent), même fermée.
struct TogglePlayIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Lecture / pause"
    func perform() async throws -> some IntentResult {
        #if !WIDGET
        await MainActor.run { Player.shared.toggle() }
        #endif
        return .result()
    }
}
struct NextTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Titre suivant"
    func perform() async throws -> some IntentResult {
        #if !WIDGET
        await MainActor.run { Player.shared.next() }
        #endif
        return .result()
    }
}
struct PrevTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Titre précédent"
    func perform() async throws -> some IntentResult {
        #if !WIDGET
        await MainActor.run { Player.shared.prev() }
        #endif
        return .result()
    }
}
