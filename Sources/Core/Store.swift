import Foundation

/// Réglages et petites données de l'appareil (équivalent du localStorage « music.* » de la PWA).
enum Store {
    private static let d = UserDefaults.standard
    static func get<T: Codable>(_ k: String, _ def: T) -> T {
        guard let data = d.data(forKey: "music.\(k)"), let v = try? JSONDecoder().decode(T.self, from: data) else { return def }
        return v
    }
    static func set<T: Codable>(_ k: String, _ v: T) {
        if let data = try? JSONEncoder().encode(v) { d.set(data, forKey: "music.\(k)") }
    }
    static func remove(_ k: String) { d.removeObject(forKey: "music.\(k)") }
}
