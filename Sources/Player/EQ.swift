import Foundation
import Observation

/// Égaliseur de l'appareil (7 bandes, préréglages, profils enregistrés) ; réglable à distance depuis un autre appareil.
@MainActor @Observable final class EQ {
    static let shared = EQ()
    static let bands = [60, 150, 400, 1000, 2400, 6000, 15000]
    static let presets: [(String, [Double])] = [
        ("Plat", [0, 0, 0, 0, 0, 0, 0]), ("Basses", [6, 4, 1, 0, 0, 0, 0]), ("Aigus", [0, 0, 0, 0, 2, 4, 6]),
        ("Voix", [-2, -1, 1, 3, 3, 1, 0]), ("Rock", [4, 2, -1, -1, 1, 3, 4]), ("Électro", [5, 3, 0, -1, 1, 3, 4]),
        ("Acoustique", [2, 1, 0, 1, 2, 2, 1]), ("Soirée", [5, 3, 0, 0, 1, 2, 3]),
    ]
    var on = Store.get("eq-on", false) { didSet { apply() } }
    var gains = Store.get("eq-gains", [0.0, 0, 0, 0, 0, 0, 0]) { didSet { apply() } }
    var profiles = Store.get("eq-profiles", [String: [Double]]())

    private init() { apply() }
    private func apply() {
        Store.set("eq-on", on); Store.set("eq-gains", gains)
        AudioEngine.shared.setEQ(on: on, gains: gains)
        Player.shared.emit("eq")
    }
    func saveProfile(_ name: String) { profiles[name] = gains; Store.set("eq-profiles", profiles); Player.shared.emit("eq") }
    func deleteProfile(_ name: String) { profiles[name] = nil; Store.set("eq-profiles", profiles); Player.shared.emit("eq") }

    var json: JSON { ["on": .bool(on), "gains": .arr(gains.map { .num($0) }), "profiles": .obj(profiles.mapValues { .arr($0.map { .num($0) }) })] }

    /// Commande « eq » reçue d'un autre appareil (même forme que la PWA).
    func apply(remote a: JSON) {
        if let name = a["profile"]["name"].string {
            let g = a["profile"]["gains"].array.compactMap(\.double)
            profiles[name] = g.count == 7 ? g : gains
            Store.set("eq-profiles", profiles); Player.shared.emit("eq")
            return
        }
        if let o = a["on"].bool { on = o }
        let g = a["gains"].array.compactMap(\.double)
        if g.count == 7 { gains = g }
    }
}
