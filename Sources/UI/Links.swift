import SwiftUI
import UIKit

/// Liens qui ouvrent l'appli : lamasmusic://album/ID, music.youtube.com (titre, playlist, album, artiste), music.lamas.one/#/…
@MainActor enum Links {
    /// true si le lien a été reconnu (et ouvert).
    @discardableResult static func open(_ u: URL) -> Bool {
        if u.scheme == "lamasmusic" {
            if u.host == "auth" { return false }
            if u.host == "now" { Router.shared.nowPlaying = Player.shared.current != nil; return true }
            if u.host == "open", let s = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value, let inner = URL(string: s) { return open(inner) }
            let path = [u.host, u.path.isEmpty ? nil : String(u.path.dropFirst())].compactMap { $0 }.joined(separator: "/")
            return go(Route(href: "#/" + path + (u.query.map { "?" + $0 } ?? "")))
        }
        guard let host = u.host?.lowercased() else { return false }
        if host == baseURL.host, let f = u.fragment { return go(Route(href: "#" + f)) }
        guard host.hasSuffix("youtube.com") || host == "youtu.be" else { return false }
        let qs = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func qv(_ k: String) -> String? { qs.first { $0.name == k }?.value }
        let parts = u.path.split(separator: "/").map(String.init)
        if host == "youtu.be", let id = parts.first { return play(id) }
        if parts.first == "watch", let v = qv("v") { return play(v) }
        if parts.first == "playlist", let l = qv("list") { return go(l.hasPrefix("OLAK") ? .album(l) : .playlist(l)) }
        if parts.first == "browse", let b = parts[safe: 1] {
            if b.hasPrefix("MPRE") { return go(.album(b)) }
            if b.hasPrefix("VL") { return go(.playlist(String(b.dropFirst(2)))) }
            if b.hasPrefix("UC") { return go(.artist(b)) }
        }
        if parts.first == "channel", let c = parts[safe: 1] { return go(.artist(c)) }
        return false
    }

    static func looksLikeLink(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("http") || t.hasPrefix("lamasmusic:") || t.contains("youtube.com/") || t.contains("youtu.be/"), let u = URL(string: t.hasPrefix("http") || t.hasPrefix("lamasmusic") ? t : "https://" + t) else { return nil }
        return u
    }

    private static func go(_ r: Route?) -> Bool {
        guard let r else { return false }
        Router.shared.open(r)
        return true
    }
    private static func play(_ id: String) -> Bool {
        Task {
            if let w = try? await yt("/watch" + q(["videoId": id, "limit": 1])), let t = parseTracks(w["tracks"]).first { Player.shared.playRadio(t) }
            else { Toast.show("Titre introuvable", .err) }
        }
        return true
    }

    private static var lastChange = UIPasteboard.general.changeCount
    /// Retour dans l'appli avec un lien copié : on propose de l'ouvrir (la lecture du presse-papiers ne se fait qu'au toucher).
    static func offerClipboard() {
        let pb = UIPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        pb.detectPatterns(for: [\UIPasteboard.DetectedValues.probableWebURL]) { r in
            guard (try? r.get())?.isEmpty == false else { return }
            Task { @MainActor in
                Toast.show("Lien copié", .info, action: "Ouvrir dans Music", seconds: 6) {
                    guard let s = UIPasteboard.general.url?.absoluteString ?? UIPasteboard.general.string, let u = looksLikeLink(s), open(u) else { return Toast.show("Ce lien ne mène pas à de la musique", .warn) }
                }
            }
        }
    }
}
