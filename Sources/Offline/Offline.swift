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
    private var ids = Set<String>()
    private var syncAt = Date.distantPast
    private let monitor = NWPathMonitor()
    private(set) var cellular = false
    private(set) var online = true
    /// Titres gardés automatiquement après écoute : les seuls retirés pour faire de la place.
    private(set) var kept = Set<String>()
    private var played: [String: Double] = [:]
    private var retry: [String: Track] = [:]
    private struct Smart: Codable { var kept: [String]; var played: [String: Double] }

    nonisolated static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("offline")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        var dd = d; try? dd.setResourceValues(v)
        return d
    }()
    private var index: URL { Self.dir.appendingPathComponent("index.json") }
    private var colIndex: URL { Self.dir.appendingPathComponent("collections.json") }
    private var smartIndex: URL { Self.dir.appendingPathComponent("smart.json") }

    private init() {
        if let d = try? Data(contentsOf: index), let t = try? JSONDecoder().decode([Track].self, from: d) { tracks = t }
        if let d = try? Data(contentsOf: colIndex), let c = try? JSONDecoder().decode([Collection].self, from: d) { collections = c }
        ids = Set(tracks.map(\.id))
        if let d = try? Data(contentsOf: smartIndex), let s = try? JSONDecoder().decode(Smart.self, from: d) { kept = Set(s.kept).intersection(ids); played = s.played }
        monitor.pathUpdateHandler = { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                let was = self.online
                self.online = p.status == .satisfied
                self.cellular = p.usesInterfaceType(.cellular)
                if self.online && !was {
                    Toast.show("De nouveau en ligne", .ok); NotificationCenter.default.post(name: .musicStale, object: "online")
                    // téléchargements interrompus par la coupure : relancés
                    let again = Array(self.retry.values); self.retry = [:]
                    if !again.isEmpty { self.download(again) }
                }
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
        var started = false
        for t in ts where !t.id.isEmpty && !ids.contains(t.id) && jobs[t.id] == nil && t.available && !t.isLive {
            jobs[t.id] = Job(progress: 0, track: t)
            BackgroundDL.shared.start(t)
            started = true
        }
        if started { saveJobs() }
    }

    /// Fichier arrivé (même appli fermée : iOS relance l'appli en arrière-plan pour le ranger).
    func finished(_ id: String, part: URL) async {
        defer { jobs[id] = nil; saveJobs() }
        guard let t = jobs[id]?.track ?? pendingMeta()[id] else { try? FileManager.default.removeItem(at: part); return }
        do {
            try await AudioFiles.makeReadable(part)
            try? FileManager.default.removeItem(at: file(id))
            try FileManager.default.moveItem(at: part, to: file(id))
            var x = t.plain; x.auto = nil
            tracks.removeAll { $0.id == id }
            tracks.insert(x, at: 0)
            ids.insert(id)
            kept.remove(id)
            save()
            enforceQuota()
        } catch {
            try? FileManager.default.removeItem(at: part)
            Toast.show("Téléchargement impossible : \(t.title)", .err)
        }
    }
    func failed(_ id: String, _ message: String?, network: Bool = false) {
        let t = jobs[id]?.track
        jobs[id] = nil
        saveJobs()
        if network, !online, let t { retry[id] = t; return } // repris au retour du réseau
        if online, let t { Toast.show("Téléchargement impossible : \(t.title)", .err) }
    }
    func progress(_ id: String, _ p: Double) { jobs[id]?.progress = p }

    /// Téléchargements lancés avant la fermeture de l'appli : on les retrouve.
    func restoreJobs() async {
        let meta = pendingMeta()
        let running = await BackgroundDL.shared.runningIds()
        for (id, t) in meta where running.contains(id) && jobs[id] == nil { jobs[id] = Job(progress: 0, track: t) }
        saveJobs()
    }
    private var jobsFile: URL { Self.dir.appendingPathComponent("jobs.json") }
    private func pendingMeta() -> [String: Track] { (try? JSONDecoder().decode([String: Track].self, from: Data(contentsOf: jobsFile))) ?? [:] }
    private func saveJobs() { try? JSONEncoder().encode(jobs.mapValues(\.track)).write(to: jobsFile, options: .atomic) }

    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: file(id))
        tracks.removeAll { $0.id == id }
        ids.remove(id)
        kept.remove(id)
        save()
    }

    // MARK: hors ligne intelligent : écoutes gardées, espace maximal
    /// Titre écouté : sa copie de lecture rejoint les téléchargements (option « Garder mes écoutes »), sans retéléchargement.
    func listened(_ t: Track) {
        played[t.id] = Date().timeIntervalSince1970
        defer { saveSmart() }
        guard Store.get("auto-recent", false), !has(t.id), t.available, !t.isLive, jobs[t.id] == nil else { return }
        let src = AudioFiles.shared.dir.appendingPathComponent("\(t.id).m4a")
        guard FileManager.default.fileExists(atPath: src.path), (try? FileManager.default.copyItem(at: src, to: file(t.id))) != nil else { return }
        var x = t.plain; x.auto = nil
        tracks.insert(x, at: 0)
        ids.insert(t.id); kept.insert(t.id)
        save()
        enforceQuota()
    }
    /// Au-delà de l'espace choisi (ou si l'appareil est presque plein), les titres gardés automatiquement
    /// les moins récemment écoutés partent ; jamais ceux d'un album ou d'une playlist téléchargés.
    func enforceQuota() {
        let quota = Int64(Store.get("offline-quota", 0.0) * 1_000_000_000)
        var total = totalSize
        let keep = Set(collections.flatMap(\.ids))
        let victims = tracks.filter { kept.contains($0.id) && !keep.contains($0.id) }.sorted { (played[$0.id] ?? 0) < (played[$1.id] ?? 0) }
        for t in victims {
            guard (quota > 0 && total > quota) || freeSpace < 1_000_000_000 else { break }
            total -= size(t.id)
            remove(t.id)
        }
    }
    private func saveSmart() { try? JSONEncoder().encode(Smart(kept: Array(kept), played: played)).write(to: smartIndex, options: .atomic) }
    func saveCollection(_ key: String, _ meta: Collection.Meta, _ trackIds: [String]) {
        collections.removeAll { $0.key == key }
        collections.insert(Collection(key: key, meta: meta, ids: trackIds, at: Date().timeIntervalSince1970 * 1000), at: 0)
        save()
    }
    func removeCollection(_ key: String) { collections.removeAll { $0.key == key }; save() }
    func wipe() { for t in tracks { try? FileManager.default.removeItem(at: file(t.id)) }; tracks = []; ids = []; kept = []; collections = []; save() }

    private func save() {
        try? JSONEncoder().encode(tracks).write(to: index, options: .atomic)
        try? JSONEncoder().encode(collections).write(to: colIndex, options: .atomic)
        saveSmart()
        Spotlight.schedule()
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
        if ProcessInfo.processInfo.isLowPowerModeEnabled && !force { return }
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
        enforceQuota()
        if added > 0 { Toast.show("\(added) nouveau\(added > 1 ? "x" : "") titre\(added > 1 ? "s" : "") en téléchargement", .info) }
    }
}

/// Session de transfert iOS : les téléchargements continuent appli fermée.
final class BackgroundDL: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundDL()
    static let id = "one.lamas.music.downloads"
    var completion: (() -> Void)?
    private var last: [String: Date] = [:]
    private let lock = NSLock()

    lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.id)
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        c.httpCookieStorage = .shared
        c.httpMaximumConnectionsPerHost = 3
        c.timeoutIntervalForResource = 60 * 60 * 6
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    func start(_ t: Track) {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/download/\(t.id)"))
        for (k, v) in Session.cookieHeader { req.setValue(v, forHTTPHeaderField: k) }
        let task = session.downloadTask(with: req)
        task.taskDescription = t.id
        task.resume()
    }
    func runningIds() async -> Set<String> { Set(await session.allTasks.compactMap(\.taskDescription)) }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite e: Int64) {
        guard let id = downloadTask.taskDescription, e > 0 else { return }
        lock.lock()
        let ok = Date().timeIntervalSince(last[id] ?? .distantPast) > 0.3
        if ok { last[id] = Date() }
        lock.unlock()
        if ok { Task { @MainActor in Offline.shared.progress(id, Double(w) / Double(e)) } }
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { Task { @MainActor in Offline.shared.failed(id, "erreur \(code)") }; return }
        // le fichier temporaire disparaît au retour de cette fonction : on le range tout de suite
        let part = Offline.dir.appendingPathComponent("\(id).part")
        try? FileManager.default.removeItem(at: part)
        do { try FileManager.default.moveItem(at: location, to: part) } catch { Task { @MainActor in Offline.shared.failed(id, nil) }; return }
        Task { @MainActor in await Offline.shared.finished(id, part: part) }
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        let network = (error as? URLError).map { $0.code != .cancelled } ?? false
        Task { @MainActor in Offline.shared.failed(id, error.localizedDescription, network: network) }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { self.completion?(); self.completion = nil }
    }
}
