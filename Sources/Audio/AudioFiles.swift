import AVFoundation
import Foundation

/// Fichiers audio à jouer : titre téléchargé (hors ligne) ou copie en cache du flux du serveur (`/api/audio/:id`).
/// AVAudioEngine lit des fichiers complets : chaque titre est récupéré en entier avant de jouer, les suivants à l'avance.
final class AudioFiles: @unchecked Sendable {
    static let shared = AudioFiles()
    private let lock = NSLock()
    private var tasks: [String: Task<URL, Error>] = [:]
    let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("audio")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static let limit: Int64 = 1_500_000_000

    func cached(_ id: String) -> URL? {
        let off = Offline.dir.appendingPathComponent("\(id).m4a")
        if FileManager.default.fileExists(atPath: off.path) { return off }
        let f = dir.appendingPathComponent("\(id).m4a")
        if FileManager.default.fileExists(atPath: f.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
            return f
        }
        return nil
    }

    /// Fichier lisible du titre (téléchargé une seule fois même si plusieurs demandes arrivent).
    func file(_ id: String) async throws -> URL {
        if let f = cached(id) { return f }
        lock.lock()
        if let t = tasks[id] { lock.unlock(); return try await t.value }
        let t = Task<URL, Error> { try await fetch(id) }
        tasks[id] = t
        lock.unlock()
        defer { lock.lock(); tasks[id] = nil; lock.unlock() }
        return try await t.value
    }

    func prepare(_ ids: [String]) { for id in ids where cached(id) == nil { Task { _ = try? await file(id) } } }

    private func fetch(_ id: String, retry: Bool = false) async throws -> URL {
        let url = baseURL.appendingPathComponent("api/audio/\(id)")
        var req = URLRequest(url: URL(string: url.absoluteString + (retry ? "?r=\(Int(Date().timeIntervalSince1970))" : ""))!)
        req.timeoutInterval = 90
        do {
            let (tmp, resp) = try await API.shared.session.download(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw APIError(code: code, message: code == 401 ? "Connexion requise" : "flux indisponible (\(code))") }
            let dest = dir.appendingPathComponent("\(id).m4a")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            try await Self.makeReadable(dest)
            trim()
            return dest
        } catch where !retry && (error as? APIError)?.code != 401 {
            return try await fetch(id, retry: true)
        }
    }

    /// Les MP4 fragmentés de YouTube ne s'ouvrent pas toujours avec AVAudioFile : réécriture du conteneur (sans réencodage).
    static func makeReadable(_ f: URL) async throws {
        if let a = try? AVAudioFile(forReading: f), a.length > 0 { return }
        let out = f.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".m4a")
        let asset = AVURLAsset(url: f)
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw APIError(code: 0, message: "fichier audio illisible") }
        ex.outputURL = out
        ex.outputFileType = .m4a
        await ex.export()
        guard ex.status == .completed else {
            // dernier recours : réencodage AAC
            guard let ex2 = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw APIError(code: 0, message: "fichier audio illisible") }
            try? FileManager.default.removeItem(at: out)
            ex2.outputURL = out; ex2.outputFileType = .m4a
            await ex2.export()
            guard ex2.status == .completed else { throw APIError(code: 0, message: ex2.error?.localizedDescription ?? "fichier audio illisible") }
            _ = try FileManager.default.replaceItemAt(f, withItemAt: out)
            return
        }
        _ = try FileManager.default.replaceItemAt(f, withItemAt: out)
    }

    var usage: Int64 {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []).reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Cache limité (les plus anciens partent d'abord).
    private func trim() {
        let fm = FileManager.default
        guard var files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var total = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        guard total > Self.limit else { return }
        files.sort { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for f in files where total > Self.limit * 8 / 10 {
            total -= Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try? fm.removeItem(at: f)
        }
    }

    func clear() { try? FileManager.default.removeItem(at: dir); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
}
