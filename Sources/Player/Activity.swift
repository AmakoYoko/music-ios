import ActivityKit
import Foundation

/// Activité en direct du titre en cours (écran verrouillé, Dynamic Island), tenue à jour par l'appli.
@MainActor enum NowActivity {
    private static var activity: Activity<NowAttributes>?
    private static var last: NowAttributes.ContentState?
    static var enabled: Bool { Store.get("live-activity", true) }

    static func update(_ p: Player, art: String) {
        guard enabled, let t = p.current else { return end() }
        let s = NowAttributes.ContentState(title: t.title, artist: t.artistLine, playing: p.playing, live: t.isLive,
                                           pos: p.time, dur: p.duration,
                                           start: p.playing && !t.isLive && p.duration > 0 ? Date().addingTimeInterval(-p.time) : nil, art: art)
        // seulement quand quelque chose de visible change (titre, état, pochette, saut dans le titre)
        if let l = last, l.title == s.title, l.playing == s.playing, l.art == s.art, l.dur == s.dur,
           abs((l.start ?? .distantPast).timeIntervalSince(s.start ?? .distantPast)) < 2 { return }
        let content = ActivityContent(state: s, staleDate: nil)
        if let a = activity ?? Activity<NowAttributes>.activities.first {
            activity = a; last = s
            Task { await a.update(content) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled, let a = try? Activity.request(attributes: NowAttributes(), content: content) {
            activity = a; last = s // iOS n'en crée qu'appli ouverte : sinon nouvel essai au prochain passage
        }
    }

    static func end() {
        guard activity != nil || !Activity<NowAttributes>.activities.isEmpty else { return }
        last = nil; activity = nil
        let all = Activity<NowAttributes>.activities
        Task { for a in all { await a.end(nil, dismissalPolicy: .immediate) } }
    }

    /// Appli quittée : l'activité ne doit pas rester figée.
    nonisolated static func endNow() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for a in Activity<NowAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1.5)
    }
}
