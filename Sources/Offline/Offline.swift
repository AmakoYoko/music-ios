import Foundation
import Network
import Observation

/// Hors ligne sur l'appareil : fichiers audio + infos, et collections (album, playlist) tenues à jour (portage de offline.js).
@MainActor @Observable final class Offline {
    static let shared = Offline()
    struct Collection: Codable, Hashable, Identifiable {
        struct Meta: Codable, Hashable { var title: String; var art: String?; var href: String? }
        var key: String; var meta: Meta; var ids: [String]; var at: Double
        var id: String { key }
    }
    struct Job: Equatable { var progress: Double; var track: Track }

    private(set) var tracks: [Track] = []
    private(set) var collections: [Collection] = []
    private(set) var jobs: [String: Job] = [:]
    private var pending: [Track] = []
    private var active = 0
    private var ids = Set<String>()
    private var syncAt = Date.distantPast
    private let monitor = NWPathMonitor()
    private(set) var cellular = false
    private(set) var online = true

    nonisolated static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("offline")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        var dd = d; try? dd.setResourceValues(v)
        return d
    }()
    private var index: URL { Self.dir.appendingPathComponent("index.json") }
    private var colIndex: URL { Self.dir.appendingPathComponent("collections.json") }

    private init() {
        if let d = try? Data(contentsOf: index), let t = try? JSONDecoder().decode([Track].self, from: d) { tracks = t }
        if let d = try? Data(contentsOf: colIndex), let c = try? JSONDecoder().decode([Collection].self, from: d) { collections = c }
        ids = Set(tracks.map(\.id))
        monitor.pathUpdateHandler = { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                let was = self.online
                self.online = p.status == .satisfied
                self.cellular = p.usesInterfaceType(.cellular)
                if self.online && !was { Toast.show("De nouveau en ligne", .ok); NotificationCenter.default.post(name: .musicStale, object: "online") }
                if !self.online && was { Toast.show("Hors ligne : les titres téléchargés restent disponibles", .warn) }
            }
        }
        monitor.start(queue: .global())
    }

    nonisolated func file(_ id: String) -> URL { Self.dir.appendingPathComponent("\(id).m4a") }
    nonisolated func fileIfPresent(_ id: String) -> URL? { let f = file(id); return FileManager.default.fileExists(atPath: f.path) ? f : nil }
    func has(_ id: String) -> Bool { ids.contains(id) }
    var totalSize: Int64 { tracks.reduce(0) { $0 + size($1.id) } }
    func size(_ id: String) -> Int64 { Int64((try? FileManager.default.attributesOfItem(atPath: file(id).path)[.size] as? Int) ?? 0) }
    var freeSpace: Int64 { (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0 }

    func download(_ ts: [Track]) {
        for t in ts where !t.id.isEmpty && !ids.contains(t.id) && jobs[t.id] == nil && t.available && !t.isLive {
            jobs[t.id] = Job(progress: 0, track: t)
            pending.append(t)
        }
        pump()
    }

    private func pump() {
        while active < 2, !pending.isEmpty {
            let t = pending.removeFirst()
            active += 1
            Task {
                await fetch(t)
                active -= 1
                jobs[t.id] = nil
                pump()
            }
        }
    }

    private func fetch(_ t: Track) async {
        let url = baseURL.appendingPathComponent("api/download/\(t.id)")
        do {
            let tmp = Self.dir.appendingPathComponent("\(t.id).part")
            let prog = DownloadProgress { p in Task { @MainActor in Offline.shared.jobs[t.id]?.progress = p } }
            let (dl, resp) = try await API.shared.session.download(from: url, delegate: prog)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw APIError(code: (resp as? HTTPURLResponse)?.statusCode ?? 0, message: "téléchargement refusé") }
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.moveItem(at: dl, to: tmp)
            try await AudioFiles.makeReadable(tmp)
            try? FileManager.default.removeItem(at: file(t.id))
            try FileManager.default.moveItem(at: tmp, to: file(t.id))
            var x = t.plain; x.auto = nil
            tracks.removeAll { $0.id == t.id }
            tracks.insert(x, at: 0)
            ids.insert(t.id)
            save()
        } catch {
            try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent("\(t.id).part"))
            if online { Toast.show("Téléchargement impossible : \(t.title)", .err) }
        }
    }

    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: file(id))
        tracks.removeAll { $0.id == id }
        ids.remove(id)
        save()
    }
    func saveCollection(_ key: String, _ meta: Collection.Meta, _ trackIds: [String]) {
        collections.removeAll { $0.key == key }
        collections.insert(Collection(key: key, meta: meta, ids: trackIds, at: Date().timeIntervalSince1970 * 1000), at: 0)
        save()
    }
    func removeCollection(_ key: String) { collections.removeAll { $0.key == key }; save() }
    func wipe() { for t in tracks { try? FileManager.default.removeItem(at: file(t.id)) }; tracks = []; ids = []; collections = []; save() }

    private func save() {
        try? JSONEncoder().encode(tracks).write(to: index, options: .atomic)
        try? JSONEncoder().encode(collections).write(to: colIndex, options: .atomic)
    }

    // MARK: téléchargement automatique : collections à jour, option « Titres J'aime hors ligne »
    private func collectionTracks(_ key: String) async -> [Track]? {
        guard let i = key.firstIndex(of: ":") else { return nil }
        let kind = String(key[..<i]), id = String(key[key.index(after: i)...])
        switch kind {
        case "playlist": return (try? await yt("/playlist" + q(["id": id, "limit": 2000]), fresh: true)).map { parseTracks($0["tracks"]) }
        case "mpl": return (try? await Library.shared.mpl(id))?.tracks
        case "smart": return (await smartLists(fresh: true)).first { $0["id"].string == id }.map(smartTracks)
        default: return nil // album : ne change pas
        }
    }

    func autoSync(force: Bool = false) async {
        guard online, force || Date().timeIntervalSince(syncAt) > 30 * 60 else { return }
        if Store.get("auto-wifi", true) && cellular { return }
        syncAt = Date()
        var cols = collections
        if Store.get("auto-liked", false) && !cols.contains(where: { $0.key == "playlist:LM" }) {
            cols.append(Collection(key: "playlist:LM", meta: .init(title: "Titres J'aime", href: "#/playlist/LM"), ids: [], at: 0))
        }
        var added = 0
        for c in cols {
            guard let ts = await collectionTracks(c.key) else { continue }
            let ok = ts.filter(\.available)
            let missing = ok.filter { !has($0.id) }
            if !missing.isEmpty { download(missing); added += missing.count }
            if !missing.isEmpty || ok.count != c.ids.count { saveCollection(c.key, c.meta, ok.map(\.id)) }
        }
        if added > 0 { Toast.show("\(added) nouveau\(added > 1 ? "x" : "") titre\(added > 1 ? "s" : "") en téléchargement", .info) }
    }
}

/// Progression d'un téléchargement (barre des Téléchargés).
final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let on: (Double) -> Void
    private var last = Date.distantPast
    init(_ on: @escaping (Double) -> Void) { self.on = on }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite e: Int64) {
        guard e > 0, Date().timeIntervalSince(last) > 0.3 else { return }
        last = Date()
        on(Double(w) / Double(e))
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
