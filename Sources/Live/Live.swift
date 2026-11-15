import AVFoundation
import Foundation
import Observation
import UIKit

/// Synchro entre appareils (façon Spotify Connect, portage de live.js) : un seul appareil joue, les autres affichent la même
/// lecture et servent de télécommande ; « Appareil de sortie » transfère la lecture. Serveur : src/live.ts (SSE /api/live).
@MainActor @Observable final class Live {
    static let shared = Live()
    struct Device: Codable, Hashable, Identifiable { var id: String; var name: String; var kind: String }

    let me: String = {
        if let d = Store.get("deviceId", String?.none) { return d }
        let d = "d" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        Store.set("deviceId", d)
        return d
    }()
    let kind = UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "phone"
    var name: String = Store.get("deviceName", UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")
    var devices: [Device] = []
    var activeId: String?
    var state: JSON?
    var connected = false

    /// Appareil piloté à distance (nil : la musique joue ici).
    var target: String? { guard let a = activeId, a != me, devices.contains(where: { $0.id == a }) else { return nil }; return a }
    var targetName: String { devices.first { $0.id == target }?.name ?? "" }

    private var stream: Task<Void, Never>?
    private var claimSoon = false
    private var lastPub = Date.distantPast
    private var pubTask: Task<Void, Never>?
    private var executing = false
    private var holdUntil = Date.distantPast
    private var mirrorPos = 0.0
    private var mirrorAt = Date()
    private var carSeen: [String: Date] = [:]
    private var hush: AVAudioPlayer?
    private var timer: Timer?

    private init() {}

    func start() {
        guard stream == nil else { return }
        connect()
        Player.shared.on { [weak self] w in if w != "time" { self?.publish() } }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Player.shared.playing && self.target == nil { self.publish() }
                if !self.connected { self.connect() }
                for d in self.devices where self.carSeen[d.id] != nil { self.carSeen[d.id] = Date() }
            }
        }
    }

    func rename(_ n: String) {
        name = n
        Store.set("deviceName", n)
        Task { _ = try? await post("/api/live/rename", ["id": .str(me), "name": .str(n)]) }
    }

    private func post(_ path: String, _ body: JSON) async throws -> JSON { try await API.shared.raw(path, method: "POST", body: body, timeout: 15) }
    private func cmd(_ to: String, _ c: String, _ args: JSON = nil) async -> Bool {
        ((try? await post("/api/live/cmd", ["to": .str(to), "from": .str(me), "cmd": .str(c), "args": args]))?["ok"].bool) ?? false
    }

    // MARK: flux SSE
    func connect() {
        stream?.cancel()
        let url = URL(string: baseURL.absoluteString + "/api/live" + q(["id": me, "name": name, "kind": kind]))!
        stream = Task {
            var req = URLRequest(url: url)
            req.timeoutInterval = 60 * 60 * 24
            req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            do {
                let (bytes, resp) = try await API.shared.session.bytes(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw APIError(code: 0, message: "") }
                connected = true
                for try await line in bytes.lines {
                    guard line.hasPrefix("data:") else { continue }
                    if let m = JSON.parse(Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)) { handle(m) }
                }
            } catch {}
            connected = false
            if !Task.isCancelled { try? await Task.sleep(nanoseconds: 3_000_000_000); if !Task.isCancelled { stream = nil; connect() } }
        }
    }

    private func handle(_ m: JSON) {
        switch m["type"].string {
        case "hello", "devices":
            let before = Set(devices.map(\.id))
            devices = m["devices"].array.compactMap { $0.decode(Device.self) }
            activeId = m["activeId"].string
            if m["type"].string == "hello" { state = m["state"].isNull ? nil : m["state"] }
            if target != nil, let st = state, m["type"].string == "hello" || Player.shared.mirror == nil { applyRemote(st) }
            if target == nil && Player.shared.mirror != nil { leaveMirror() }
            autoCar(before)
        case "state":
            activeId = m["activeId"].string
            if m["activeId"].string != me { applyRemote(m["state"]) }
        case "cmd": onCmd(m)
        case "ping": Task { _ = try? await post("/api/live/alive", ["id": .str(me)]) }
        case "radio": Radio.shared.announce(m)
        case "changed": NotificationCenter.default.post(name: .musicStale, object: m["what"].string)
        default: break
        }
    }

    // MARK: actions du lecteur : ici ou vers l'appareil actif
    /// true = action envoyée à l'appareil piloté (ne rien faire ici).
    func forward(_ name: String, _ args: [JSON], claim: Bool = false) -> Bool {
        if executing { return false }
        guard let to = target else {
            if claim { claimSoon = true }
            return false
        }
        if name == "seek", let t = args.first?.double { mirrorPos = t; mirrorAt = Date() }
        Task {
            let ok = await cmd(to, "do", ["name": .str(name), "args": .arr(args)])
            if !ok {
                Toast.show("Appareil injoignable", .err)
                if activeId == to { activeId = nil }
                leaveMirror()
            }
        }
        return true
    }

    private func run(_ name: String, _ a: [JSON]) {
        let p = Player.shared
        executing = true
        defer { executing = false }
        let ts = { (j: JSON) in j.array.compactMap { $0.decode(Track.self) } }
        switch name {
        case "playList": p.playList(ts(a[safe: 0] ?? nil), at: a[safe: 1]?.int ?? 0, source: a[safe: 2]?.decode(Source.self), shuffle: a[safe: 3]?["shuffle"].bool ?? false)
        case "playRadio": if let t = a.first?.decode(Track.self) { p.playRadio(t, source: a[safe: 1]?.decode(Source.self)) }
        case "startRadio": if let t = a.first?.decode(Track.self) { p.startRadio(t) }
        case "playNext": p.playNext(ts(a.first ?? nil))
        case "addToQueue": p.addToQueue(ts(a.first ?? nil))
        case "jump": p.jump(a.first?.int ?? 0)
        case "remove": p.remove(a.first?.int ?? -1)
        case "move": p.move(a[safe: 0]?.int ?? 0, a[safe: 1]?.int ?? 0)
        case "clearUpcoming": p.clearUpcoming()
        case "toggle": p.toggle()
        case "play": p.play()
        case "pause": p.pause()
        case "next": p.next()
        case "prev": p.prev()
        case "seek": if let t = a.first?.double { p.seek(t) }
        case "setVolume": if let v = a.first?.double { p.setVolume(v) }
        case "toggleShuffle": p.toggleShuffle()
        case "cycleRepeat": p.cycleRepeat()
        default: break
        }
    }

    private func onCmd(_ m: JSON) {
        let a = m["args"]
        switch m["cmd"].string {
        case "do": if let n = a["name"].string { run(n, a["args"].array) }
        case "pause": executing = true; Player.shared.pause(); executing = false
        case "takeover": takeover(m)
        case "failed": Toast.show(a["message"].string ?? "Lecture impossible sur l'autre appareil", .err)
        case "transferTo": if let to = a["to"].string { Task { await transfer(to) } }
        case "eq": EQ.shared.apply(remote: a)
        default: break
        }
    }

    // MARK: appareil actif : publie son état
    func publish(force: Bool = false) {
        let p = Player.shared
        guard target == nil, p.current != nil, p.mirror == nil else { return }
        if !p.playing && !claimSoon && !force && activeId != me { return } // un appareil en pause ne prend pas la main
        pubTask?.cancel()
        let wait = max(0, 0.4 - Date().timeIntervalSince(lastPub))
        pubTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
            guard !Task.isCancelled else { return }
            lastPub = Date()
            let claim = claimSoon
            claimSoon = false
            guard let r = try? await post("/api/live/state", ["id": .str(me), "state": p.snapshot(), "claim": .bool(claim)]) else { return }
            if r["active"].bool == true && activeId != me { activeId = me }
            else if r["active"].bool == false, let a = r["activeId"].string, a != me {
                activeId = a
                if !r["state"].isNull { state = r["state"] }
                if target != nil, let st = state { applyRemote(st) }
            }
            if !connected { connect() }
        }
    }

    // MARK: miroir
    private func applyRemote(_ st: JSON) {
        guard st.exists, Date() > holdUntil else { return }
        state = st
        mirrorPos = st["position"].double ?? 0
        mirrorAt = Date()
        let playing = st["playing"].bool ?? false
        Player.shared.applyMirror(st) { [weak self] in
            guard let self else { return 0 }
            let d = Player.shared.duration
            return min(d > 0 ? d : 1e9, self.mirrorPos + (playing ? Date().timeIntervalSince(self.mirrorAt) : 0))
        }
        hushSync()
    }
    private func leaveMirror(prepare: Bool = true) {
        guard Player.shared.mirror != nil else { return }
        let pos = Player.shared.time
        Player.shared.mirror = nil
        Player.shared.playing = false
        if prepare, var st = state, !st["queue"].array.isEmpty {
            if case .obj(var o) = st { o["position"] = .num(pos); st = .obj(o) }
            Player.shared.loadState(st, autoplay: false)
        }
        hushSync()
        Player.shared.changed()
    }
    /// L'écran verrouillé n'affiche les commandes que si l'appli joue du son : boucle muette pendant le miroir.
    private func hushSync() {
        let want = Player.shared.mirror != nil && Player.shared.current != nil
        if !want { hush?.stop(); return }
        if hush == nil {
            var d = Data("RIFF".utf8); let n = 8000
            func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
            func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
            u32(UInt32(36 + n)); d.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(8000); u32(8000); u16(1); u16(8)
            d.append(Data("data".utf8)); u32(UInt32(n)); d.append(Data(repeating: 128, count: n))
            hush = try? AVAudioPlayer(data: d)
            hush?.numberOfLoops = -1
            hush?.volume = 0
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        hush?.play()
    }

    // MARK: transferts
    /// Fait jouer la musique sur l'appareil `id` (cet appareil ou un autre), au même endroit.
    func transfer(_ id: String) async {
        let p = Player.shared
        if id == me {
            guard let from = target, var st = state else { return }
            if case .obj(var o) = st { o["position"] = .num(p.time); st = .obj(o) }
            leaveMirror(prepare: false)
            p.loadState(st, autoplay: true)
            holdUntil = Date().addingTimeInterval(3)
            await claimNow()
            _ = await cmd(from, "pause")
            return Toast.show("La lecture continue sur cet appareil", .ok)
        }
        if let t = target {
            _ = await cmd(t, "transferTo", ["to": .str(id)])
        } else if p.current != nil {
            var st = p.snapshot()
            if case .obj(var o) = st { o["playing"] = true; o["requester"] = .str(me); st = .obj(o) }
            guard await cmd(id, "takeover", st) else { return Toast.show("Appareil injoignable", .err) }
            return Toast.show("Passage sur \(devices.first { $0.id == id }?.name ?? "l'autre appareil")…", .info)
        } else { return }
        activeId = id
        Toast.show("Lecture sur \(devices.first { $0.id == id }?.name ?? "l'autre appareil")", .ok)
    }

    private func claimNow() async {
        let p = Player.shared
        var st = p.snapshot()
        if case .obj(var o) = st { o["playing"] = true; st = .obj(o) }
        activeId = me
        _ = try? await post("/api/live/state", ["id": .str(me), "state": st, "claim": true])
    }

    /// Lecture envoyée par un autre appareil : on ne se déclare actif qu'une fois le son lancé (l'appli native joue même en arrière-plan).
    private func takeover(_ m: JSON) {
        let st = m["args"]
        Player.shared.mirror = nil
        hushSync()
        Player.shared.loadState(st, autoplay: true)
        Task {
            for _ in 0..<150 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Player.shared.playing && !Player.shared.loading { await claimNow(); return }
            }
            let msg = "\(name) n'a pas pu lancer le son."
            for to in Set([m["from"].string, st["requester"].string].compactMap { $0 }) { _ = await cmd(to, "failed", ["message": .str(msg)]) }
        }
    }

    // MARK: voiture
    private func isCar(_ d: Device) -> Bool { d.kind == "car" || d.name.range(of: "clio", options: .caseInsensitive) != nil }
    /// « Basculer sur la voiture » : la voiture qui arrive vraiment (absente plus de 10 min) reprend la lecture.
    private func autoCar(_ before: Set<String>) {
        let now = Date(), cars = devices.filter { $0.id != me && isCar($0) }
        let fresh = cars.first { !before.contains($0.id) && now.timeIntervalSince(carSeen[$0.id] ?? .distantPast) > 600 }
        for c in cars { carSeen[c.id] = now }
        guard let f = fresh, Store.get("auto-car", false), target == nil, Player.shared.playing else { return }
        Task { await transfer(f.id) }
    }

    /// Égaliseur de l'appareil qui joue (celui-ci ou l'appareil piloté).
    func sendEQ(_ args: JSON) {
        guard let t = target else { return }
        if var st = state, case .obj(var o) = st, case .obj(var e) = o["eq"] {
            for (k, v) in args.object where k != "profile" { e[k] = v }
            o["eq"] = .obj(e); st = .obj(o); state = st
        }
        Task { _ = await cmd(t, "eq", args) }
    }
}
