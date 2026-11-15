import Foundation
import Observation

/// Music Live : flux continu (/api/radio/live.mp3) joué dans le lecteur principal en mode direct ; infos du direct.
@MainActor @Observable final class Radio {
    static let shared = Radio()
    var info: JSON = [:]
    var on: Bool { Player.shared.current?.isLive == true && Player.shared.playing }
    var loading: Bool { Player.shared.current?.isLive == true && Player.shared.loading }

    @discardableResult func load() async throws -> JSON {
        info = try await API.shared.raw("/api/radio")
        Player.shared.setLive(info["now"])
        return info
    }
    func toggle() {
        if on || loading { Player.shared.pause() }
        else { Player.shared.playLive(info["now"]); Task { try? await load() } }
    }
    func renew() async throws {
        let r = try await API.shared.raw("/api/radio/token", method: "POST", body: [:])
        if case .obj(var o) = info { o["url"] = r["url"]; info = .obj(o) }
    }
    /// Titre suivant annoncé par le serveur (SSE).
    func announce(_ m: JSON) {
        guard case .obj(var o) = info else { return }
        for (k, v) in m.object where k != "type" { o[k] = v }
        info = .obj(o)
        Player.shared.setLive(info["now"])
    }
}
