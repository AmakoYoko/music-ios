import Foundation

struct APIError: LocalizedError {
    var code: Int
    var message: String
    var errorDescription: String? { message }
}

extension Notification.Name {
    /// Une donnée affichée a changé côté serveur (`object` : chemin lu, ou « mpl »).
    static let musicStale = Notification.Name("music.stale")
    static let musicSignedOut = Notification.Name("music.signedOut")
    static let musicPlaylists = Notification.Name("music.playlists")
}

/// Session Music : cookie signé remis par /auth/app, rangé dans le magasin de cookies partagé.
enum Session {
    static let cookieName = "music_sess2"
    static var value: String? {
        get { UserDefaults.standard.string(forKey: "session") }
        set { UserDefaults.standard.set(newValue, forKey: "session"); install() }
    }
    static func install() {
        let store = HTTPCookieStorage.shared
        store.cookies(for: baseURL)?.filter { $0.name == cookieName }.forEach(store.deleteCookie)
        guard let v = value, let c = HTTPCookie(properties: [
            .domain: baseURL.host!, .path: "/", .name: cookieName, .value: v, .secure: "TRUE",
            .expires: Date().addingTimeInterval(60 * 60 * 24 * 30),
        ]) else { return }
        store.setCookie(c)
    }
    static var cookieHeader: [String: String] { value.map { ["Cookie": "\(cookieName)=\($0)"] } ?? [:] }
}

/// Appels au serveur. Lectures `/api/yt/*` : réponse immédiate depuis la mémoire ou le disque (dernière version connue),
/// puis vérification en arrière-plan ; si la réponse a changé, `.musicStale` demande un rafraîchissement discret (comme util.js).
final class API: @unchecked Sendable {
    static let shared = API()
    private let lock = NSLock()
    private var memo: [String: (at: Date, data: JSON)] = [:]
    private var revalidating = Set<String>()
    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("api")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpCookieStorage = .shared
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    private func file(_ path: String) -> URL { dir.appendingPathComponent(Data(path.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").prefix(200) + ".json") }

    /// Requête brute (n'importe quelle route du serveur).
    func raw(_ path: String, method: String = "GET", body: JSON? = nil, timeout: TimeInterval? = nil) async throws -> JSON {
        var req = URLRequest(url: URL(string: baseURL.absoluteString + path)!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { req.httpBody = body.data; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        req.timeoutInterval = timeout ?? (method == "GET" ? 30 : 120)
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        let json = JSON.parse(data) ?? .null
        if code == 401 {
            if let d = json["detail"].string { throw APIError(code: 401, message: d) } // compte YouTube Music
            await MainActor.run { NotificationCenter.default.post(name: .musicSignedOut, object: nil) }
            throw APIError(code: 401, message: "Connexion requise")
        }
        if http?.url?.path.hasPrefix("/auth") == true {
            await MainActor.run { NotificationCenter.default.post(name: .musicSignedOut, object: nil) }
            throw APIError(code: 401, message: "Connexion requise")
        }
        guard (200..<300).contains(code) else {
            let msg = json["detail"].string ?? json["detail"][0]["msg"].string ?? json["error"].string ?? "erreur \(code)"
            throw APIError(code: code, message: msg)
        }
        return json
    }

    struct Opts { var ttl: TimeInterval = 300; var fresh = false; var persist = true }

    /// Appel au moteur (relayé par /api/yt).
    func yt(_ path: String, method: String? = nil, body: JSON? = nil, _ o: Opts = Opts()) async throws -> JSON {
        let m = method ?? (body != nil ? "POST" : "GET")
        if m != "GET" {
            let d = try await raw("/api/yt" + path, method: m, body: body ?? .obj([:]))
            if !path.hasPrefix("/prefetch") && !path.hasPrefix("/history") { forget() }
            return d
        }
        lock.lock(); let hit = memo[path]; lock.unlock()
        if !o.fresh, let hit {
            if Date().timeIntervalSince(hit.at) > o.ttl { revalidate(path, hit.data) }
            return hit.data
        }
        if !o.fresh && o.persist, let d = try? Data(contentsOf: file(path)), let old = JSON.parse(d) {
            lock.lock(); memo[path] = (.distantPast, old); lock.unlock()
            revalidate(path, old)
            return old
        }
        let data = try await raw("/api/yt" + path)
        store(path, data, o.persist)
        return data
    }

    private func store(_ path: String, _ data: JSON, _ persist: Bool = true) {
        lock.lock(); memo[path] = (Date(), data); lock.unlock()
        if persist { try? data.data.write(to: file(path), options: .atomic) }
    }

    private func revalidate(_ path: String, _ known: JSON) {
        lock.lock()
        if revalidating.contains(path) { lock.unlock(); return }
        revalidating.insert(path); lock.unlock()
        Task {
            defer { lock.lock(); revalidating.remove(path); lock.unlock() }
            guard let data = try? await raw("/api/yt" + path) else { return }
            store(path, data)
            if data != known { await MainActor.run { NotificationCenter.default.post(name: .musicStale, object: path) } }
        }
    }

    /// Tout revérifier, sans perdre l'affichage instantané.
    func forget() { lock.lock(); for k in memo.keys { memo[k]?.at = .distantPast }; lock.unlock() }

    func wipeCache() {
        lock.lock(); memo = [:]; lock.unlock()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

/// Raccourci : `try await yt("/home")`.
func yt(_ path: String, method: String? = nil, body: JSON? = nil, ttl: TimeInterval = 300, fresh: Bool = false, persist: Bool = true) async throws -> JSON {
    try await API.shared.yt(path, method: method, body: body, API.Opts(ttl: ttl, fresh: fresh, persist: persist))
}

/// « ?a=1&b=2 » sans les valeurs vides.
func q(_ pairs: KeyValuePairs<String, Any?>) -> String {
    let items = pairs.compactMap { k, v -> String? in
        guard let v else { return nil }
        let s = "\(v)"
        if s.isEmpty { return nil }
        return "\(k)=\(s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s)"
    }
    return items.isEmpty ? "" : "?" + items.joined(separator: "&")
}
