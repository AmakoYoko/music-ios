import Foundation
import Observation

/// Titres enregistrés sur l'appareil : fichiers dans Application Support, index JSON à côté.
@Observable final class Offline {
    static let shared = Offline()
    private(set) var tracks: [Track] = []
    private(set) var downloading: Set<String> = []
    var lastError: String?

    private let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("offline")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        var dd = d; try? dd.setResourceValues(v)
        return d
    }()
    private var index: URL { dir.appendingPathComponent("index.json") }

    init() {
        if let d = try? Data(contentsOf: index), let t = try? JSONDecoder().decode([Track].self, from: d) { tracks = t }
    }

    func file(_ vid: String) -> URL { dir.appendingPathComponent("\(vid).m4a") }
    func has(_ vid: String) -> Bool { FileManager.default.fileExists(atPath: file(vid).path) }

    func download(_ t: Track) {
        guard !has(t.videoId), !downloading.contains(t.videoId) else { return }
        downloading.insert(t.videoId)
        Task {
            defer { Task { @MainActor in self.downloading.remove(t.videoId) } }
            do {
                let (tmp, resp) = try await URLSession.shared.download(from: API.downloadURL(t.videoId))
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.http((resp as? HTTPURLResponse)?.statusCode ?? 0) }
                try? FileManager.default.removeItem(at: file(t.videoId))
                try FileManager.default.moveItem(at: tmp, to: file(t.videoId))
                await MainActor.run {
                    self.tracks.removeAll { $0.videoId == t.videoId }
                    self.tracks.insert(t, at: 0)
                    self.save()
                }
            } catch {
                await MainActor.run { self.lastError = "\(t.title) : \(error.localizedDescription)" }
            }
        }
    }

    func downloadAll(_ ts: [Track]) { ts.forEach(download) }

    func remove(_ t: Track) {
        try? FileManager.default.removeItem(at: file(t.videoId))
        tracks.removeAll { $0.videoId == t.videoId }
        save()
    }

    private func save() { try? JSONEncoder().encode(tracks).write(to: index, options: .atomic) }
}
