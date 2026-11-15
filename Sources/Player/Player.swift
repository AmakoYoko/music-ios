import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// Lecteur : file d'attente, lecture continue (radio automatique), préchargement, enchaînement intelligent, fondu enchaîné,
/// Auto mix, « Autres versions », écran verrouillé, reprise de la session (portage de player.js).
@MainActor @Observable final class Player {
    static let shared = Player()

    // MARK: état (même forme que S dans la PWA)
    var queue: [Track] = []
    var idx = -1
    var shuffle = false
    var repeatMode = "off" // off | all | one
    var autoplay = Store.get("autoplay", true)
    var crossfade = Store.get("crossfade", 0.0)
    var automix = Store.get("automix", false)
    var smart = Store.get("smartTrans", true)
    var volume = Store.get("volume", 1.0)
    var source: Source?
    var playing = false
    var loading = false
    var mixing = false
    var time: Double = 0
    private var order: [Track]?
    private var info: [String: JSON] = [:]

    /// Miroir d'un autre appareil (Live) : temps estimé ; nil = lecture sur cet appareil.
    var mirror: (() -> Double)?

    var current: Track? { queue[safe: idx] }
    var duration: Double {
        if let d = current?.duration, d > 0 { return d }
        let l = A.length
        return l > 0 ? l : 0
    }

    // MARK: moteur
    private let audio = AudioEngine.shared
    private var cur = 0
    private var A: Deck { audio.decks[cur] }
    private var B: Deck { audio.decks[1 - cur] }
    private var preloaded: String?
    private var fading = false
    private var loadSeq = 0
    private var wanted = false
    private var reported = Set<String>()
    private var trims: [String: JSON] = [:]
    private var trimTasks = Set<String>()
    private var versions: [String: Track] = [:]
    private var ticker: Timer?
    private var liveItem: AVPlayer?
    /// Démarrage instantané : le titre joue en flux (AVPlayer) le temps que son fichier arrive, puis passe sur le moteur.
    private var streamer: AVPlayer?
    private var streamEnd: Any?
    private var listeners: [UUID: (String) -> Void] = [:]
    private var lastPrefetch = ""
    private var radioBusy = false
    private var errorRetry = Set<String>()
    private var lastSave = Date.distantPast

    private init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        audio.bus.outputVolume = Float(volume)
        for (i, d) in audio.decks.enumerated() {
            d.onEnd = { [weak self] in
                guard let self, i == self.cur, !self.fading else { return }
                self.next(auto: true)
            }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let opts = AVAudioSession.InterruptionOptions(rawValue: (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0)
            MainActor.assumeIsolated {
                guard let self else { return }
                if type == .began { self.pauseLocal(keepWanted: true) }
                else if type == .ended, opts.contains(.shouldResume), self.wanted { self.resumeLocal() }
            }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated { if reason == .oldDeviceUnavailable { self?.pause() } } // casque débranché
        }
        Task { if let v = try? await yt("/versions/prefs", fresh: true) { versions = v.object.compactMapValues { $0.decode(Track.self) } } }
        NowPlaying.setup(self)
        ticker = Timer.common(withTimeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }

    // MARK: écouteurs (Live publie l'état à chaque changement)
    @discardableResult func on(_ f: @escaping (String) -> Void) -> UUID { let k = UUID(); listeners[k] = f; return k }
    func off(_ k: UUID) { listeners[k] = nil }
    func emit(_ w: String) { for f in listeners.values { f(w) } }

    // MARK: actions
    func playList(_ ts: [Track], at i: Int = 0, source: Source? = nil, shuffle sh: Bool = false) {
        if Live.shared.forward("playList", [JSON.encode(ts), .num(Double(i)), JSON.encode(source), ["shuffle": .bool(sh)]], claim: true) { return }
        let list = ts.filter(\.available)
        guard !list.isEmpty else { return }
        let start = ts.indices.contains(i) ? max(0, list.firstIndex(of: ts[i]) ?? 0) : 0
        queue = list.map { var t = $0; t.auto = false; return t }
        order = nil
        idx = start
        self.source = source
        if sh { shuffle = false; toggleShuffle(true) } else if shuffle { shuffle = false; toggleShuffle(true) }
        load(autoplay: true)
        emit("start")
    }

    func playLive(_ now: JSON?) {
        queue = [liveTrack(now)]
        idx = 0; order = nil; shuffle = false; repeatMode = "off"
        source = Source(title: "Music Live", href: "#/radio")
        load(autoplay: true)
        emit("start")
    }
    func setLive(_ now: JSON?) {
        guard current?.isLive == true, let now, now.exists else { return }
        queue[idx] = liveTrack(now)
        NowPlaying.update(self)
        changed()
    }
    private func liveTrack(_ now: JSON?) -> Track {
        var t = Track(id: "live-\(now?["id"].string ?? now?["title"].string ?? "")", title: now?["title"].string ?? "Music Live",
                      artists: [Artist(name: now?["artist"].string ?? "En direct")])
        if let th = now?["thumb"].string { t.thumb = "/api/img?u=" + (th.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? th) }
        t.live = true; t.auto = false
        return t
    }

    /// Lit un titre seul : la suite vient de la radio YouTube Music.
    func playRadio(_ t: Track, source: Source? = nil) {
        if Live.shared.forward("playRadio", [JSON.encode(t), JSON.encode(source)], claim: true) { return }
        var x = t; x.auto = false
        queue = [x]; idx = 0; order = nil
        self.source = source ?? Source(title: "Radio : \(t.title)")
        load(autoplay: true)
        emit("start")
        Task { await fillRadio(t.id, replace: true) }
    }
    func startRadio(_ t: Track) {
        if Live.shared.forward("startRadio", [JSON.encode(t)], claim: true) { return }
        playRadio(t, source: Source(title: "Radio : \(t.title)")) }

    func playNext(_ ts: [Track]) {
        if Live.shared.forward("playNext", [JSON.encode(ts)]) { return }
        guard idx >= 0 else { return playList(ts) }
        let add = ts.map { var t = $0; t.auto = false; return t }
        queue.insert(contentsOf: add, at: idx + 1)
        order?.append(contentsOf: add)
        changed()
    }
    func addToQueue(_ ts: [Track]) {
        if Live.shared.forward("addToQueue", [JSON.encode(ts)]) { return }
        guard idx >= 0 else { return playList(ts) }
        var at = queue.indices.first { $0 > idx && queue[$0].auto == true } ?? queue.count
        at = min(at, queue.count)
        let add = ts.map { var t = $0; t.auto = false; return t }
        queue.insert(contentsOf: add, at: at)
        order?.append(contentsOf: add)
        changed()
    }
    func jump(_ i: Int) {
        if Live.shared.forward("jump", [.num(Double(i))], claim: true) { return }
        guard queue.indices.contains(i) else { return }; idx = i; load(autoplay: true) }
    func remove(_ i: Int) {
        if Live.shared.forward("remove", [.num(Double(i))]) { return }
        guard i != idx, queue.indices.contains(i) else { return }
        let gone = queue.remove(at: i)
        order?.removeAll { $0 == gone }
        if i < idx { idx -= 1 }
        changed()
    }
    func move(_ from: Int, _ to: Int) {
        if Live.shared.forward("move", [.num(Double(from)), .num(Double(to))]) { return }
        guard queue.indices.contains(from), to >= 0, to < queue.count else { return }
        let t = queue.remove(at: from)
        queue.insert(t, at: to)
        if idx == from { idx = to } else if from < idx && to >= idx { idx -= 1 } else if from > idx && to <= idx { idx += 1 }
        changed()
    }
    func clearUpcoming() {
        if Live.shared.forward("clearUpcoming", []) { return }
        if idx + 1 < queue.count { queue.removeSubrange((idx + 1)...) }; changed() }

    func toggle() {
        if Live.shared.forward("toggle", [], claim: true) { return }
        guard current != nil else { return }
        if playing || loading { pause() } else { play() }
    }
    func play() {
        if Live.shared.forward("play", [], claim: true) { return }
        guard let t = current else { return }
        if t.isLive && liveItem == nil { return load(autoplay: true) }
        if A.file == nil && !t.isLive && streamer == nil { return load(autoplay: true, at: time) }
        resumeLocal()
    }
    func pause() {
        if Live.shared.forward("pause", []) { return }
        pauseLocal(keepWanted: false) }

    private func resumeLocal() {
        wanted = true
        try? AVAudioSession.sharedInstance().setActive(true)
        if let l = liveItem { l.play(); playing = true; changed(); return }
        if let s = streamer { s.play(); playing = true; changed(); return }
        audio.start()
        A.resume()
        playing = true
        changed()
    }
    private func pauseLocal(keepWanted: Bool) {
        if !keepWanted { wanted = false }
        liveItem?.pause()
        streamer?.pause()
        if fading { finishFadeNow() }
        A.pause()
        audio.pause()
        playing = false
        loading = false
        save(now: true)
        changed()
    }

    func next(auto: Bool = false) {
        if !auto, Live.shared.forward("next", [], claim: true) { return }
        guard !queue.isEmpty, current?.isLive != true else { return }
        if auto && repeatMode == "one" { A.schedule(from: startOf(current)); return }
        if idx + 1 < queue.count { idx += 1 }
        else if repeatMode == "all" { idx = 0 }
        else if auto {
            if autoplay && repeatMode == "off", let seed = queue.last {
                Task {
                    let n = await fillRadio(seed.id, fresh: true)
                    if n > 0 && idx + 1 < queue.count { idx += 1; load(autoplay: true) } else { pauseLocal(keepWanted: false) }
                }
                return
            }
            pauseLocal(keepWanted: false)
            return
        } else { return }
        load(autoplay: true)
    }
    func prev() {
        if Live.shared.forward("prev", [], claim: true) { return }
        guard current?.isLive != true else { return }
        if time > 4 || idx == 0 { return seek(startOf(current)) }
        idx -= 1
        load(autoplay: true)
    }
    func seek(_ t: Double) {
        if Live.shared.forward("seek", [.num(t)]) { return }
        guard t.isFinite, current?.isLive != true else { return }
        let s = max(0, min(t, (duration > 0 ? duration : 1e9) - 0.3))
        if fading { finishFadeNow() }
        resetMix()
        let wasPlaying = playing
        if let st = streamer, A.file == nil || A.id != current?.id {
            st.seek(to: CMTime(seconds: s, preferredTimescale: 600))
        } else if A.file != nil {
            A.schedule(from: s, to: trimNow(current)?["end"].double)
            if !wasPlaying { A.pause() }
        }
        time = s
        NowPlaying.update(self)
        emit("time")
    }
    func setVolume(_ v: Double) {
        if Live.shared.forward("setVolume", [.num(v)]) { volume = v; return }
        volume = v; Store.set("volume", v); audio.bus.outputVolume = Float(v); streamer?.volume = Float(v) }

    func toggleShuffle(_ on: Bool? = nil) {
        if on == nil, Live.shared.forward("toggleShuffle", []) { return }
        let on = on ?? !shuffle
        shuffle = on
        if on {
            order = queue
            let curT = current
            var rest = queue.enumerated().filter { $0.offset != idx }.map(\.element)
            rest.shuffle()
            queue = curT.map { [$0] + rest } ?? rest
            idx = curT == nil ? -1 : 0
        } else if let o = order {
            let curT = current
            let ids = Set(o.map(\.id))
            let extra = queue.filter { !ids.contains($0.id) && !ids.contains($0.orig ?? "") }
            queue = o + extra
            idx = max(0, queue.firstIndex { $0.id == curT?.id || $0.orig == curT?.id || $0.id == curT?.orig } ?? 0)
            order = nil
        }
        changed()
    }
    func cycleRepeat() {
        if Live.shared.forward("cycleRepeat", []) { return }
        repeatMode = ["off": "all", "all": "one", "one": "off"][repeatMode] ?? "off"; changed() }
    func setAutoplay(_ v: Bool) { autoplay = v; Store.set("autoplay", v); if v { Task { await maybeRadio() } } }
    func setSmart(_ v: Bool) { smart = v; Store.set("smartTrans", v) }
    func setCrossfade(_ v: Double) { crossfade = v; Store.set("crossfade", v) }
    func setAutomix(_ v: Bool) { automix = v; Store.set("automix", v) }

    func versionOf(_ id: String) -> Track? { versions[id] }
    /// Toujours jouer `alt` à la place de `id` (nil : revenir à l'original).
    func setVersion(_ id: String, _ alt: Track?) async throws {
        let r = try await yt("/versions/prefs", body: ["id": .str(id), "track": alt.map { var a = $0.plain; a.auto = nil; return JSON.encode(a) } ?? .null])
        versions = r.object.compactMapValues { $0.decode(Track.self) }
        if let c = current, c.id == id || c.orig == id {
            if var a = alt { a.orig = id; queue[idx] = a } else if let o = origTracks[id] { queue[idx] = o }
            load(autoplay: playing)
        }
    }
    private var origTracks: [String: Track] = [:]
    private func sub(_ t: Track?) -> Track? {
        guard let t, t.orig == nil, var v = versions[t.id] else { return t }
        origTracks[t.id] = t
        v.orig = t.id; v.auto = t.auto
        return v
    }

    /// Paroles / titres liés (get_watch_playlist).
    func trackInfo(_ id: String) async -> JSON {
        if let i = info[id] { return i }
        guard let w = try? await yt("/watch" + q(["videoId": id, "limit": 1])) else { return [:] }
        let i: JSON = ["lyrics": w["lyrics"], "related": w["related"]]
        info[id] = i
        return i
    }

    /// Reprend un état complet (transfert depuis un autre appareil).
    func loadState(_ st: JSON, autoplay ap: Bool = true) {
        let q = st["queue"].array.compactMap { $0.decode(Track.self) }
        guard !q.isEmpty else { return }
        mirror = nil
        queue = q
        idx = min(max(0, st["idx"].int ?? 0), q.count - 1)
        shuffle = st["shuffle"].bool ?? false
        repeatMode = st["repeat"].string ?? "off"
        source = st["source"].decode(Source.self)
        order = nil
        load(autoplay: ap, at: st["position"].double ?? 0)
    }

    // MARK: chargement
    private func startOf(_ t: Track?) -> Double { smart ? (trimNow(t)?["start"].double ?? 0) : 0 }
    private func trimNow(_ t: Track?) -> JSON? { guard smart, let t, let r = trims[t.id] else { return nil }; return r }
    private func loadTrim(_ t: Track?) async -> JSON? {
        guard let t, !t.isLive else { return nil }
        if let r = trims[t.id] { return r }
        if trimTasks.contains(t.id) { return nil }
        trimTasks.insert(t.id)
        defer { trimTasks.remove(t.id) }
        let r = try? await yt("/trim/\(t.id)" + q(["duration": t.duration.map { Int($0) }]), ttl: 86400)
        if let r { trims[t.id] = r }
        return r
    }

    func load(autoplay ap: Bool, at: Double = 0) {
        if let s = sub(current) { queue[idx] = s }
        guard let t = current else { return }
        loadSeq += 1
        let seq = loadSeq
        if fading { finishFadeNow() }
        resetMix()
        mixPlan = nil
        fading = false
        liveItem?.pause(); liveItem = nil
        stopStreamer()
        wanted = ap
        reported.remove(t.id)
        time = at
        if t.isLive {
            B.unload(); A.unload()
            let url = URL(string: baseURL.absoluteString + "/api/radio/live.mp3?t=\(Int(Date().timeIntervalSince1970 * 1000))")!
            let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: HTTPCookieStorage.shared.cookies(for: baseURL) ?? []])
            let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            p.automaticallyWaitsToMinimizeStalling = true
            liveItem = p
            loading = ap
            if ap { try? AVAudioSession.sharedInstance().setActive(true); p.play(); playing = true }
            changed()
            NowPlaying.update(self)
            return
        }
        // déjà préparé sur l'autre platine : bascule immédiate (sans blanc)
        let ready = preloaded == t.id && B.id == t.id
        loading = ap
        playing = ap
        changed()
        NowPlaying.update(self)
        Task {
            let tr = smart ? await loadTrim(t) : nil
            var start = at
            if start == 0, smart, let s = tr?["start"].double { start = s }
            do {
                if !ready {
                    if ap && AudioFiles.shared.cached(t.id) == nil { startStreamer(t, at: start) }
                    let f = try await AudioFiles.shared.file(t.id)
                    // le flux a avancé pendant le téléchargement : le moteur reprend au même endroit
                    if let st = streamer, seq == loadSeq {
                        let pos = st.currentTime().seconds
                        if pos.isFinite && pos > 0.2 { start = pos + 0.05 }
                        if st.rate == 0 && st.timeControlStatus == .paused && !loading { wanted = false }
                    }
                    guard seq == loadSeq else { return }
                    try A.load(f, id: t.id, engine: audio.engine)
                } else {
                    A.unload()
                    cur = 1 - cur
                }
                guard seq == loadSeq else { return }
                preloaded = nil
                A.volume = 1
                A.rate = 1
                audio.start()
                A.schedule(from: start, to: smart ? tr?["end"].double : nil)
                if !wanted { A.pause(); audio.pause() } else { try? AVAudioSession.sharedInstance().setActive(true) }
                stopStreamer()
                time = start
                loading = false
                playing = wanted
                errorRetry.remove(t.id)
                changed()
                NowPlaying.update(self)
                await maybeRadio()
                prefetch()
            } catch {
                guard seq == loadSeq else { return }
                if streamer != nil { return } // le flux continue : le titre reste écoutable sans son fichier
                loading = false
                if (error as? APIError)?.code == 401 { playing = false; changed(); return }
                Toast.show("Lecture impossible : \(t.title)", .err)
                try? await Task.sleep(nanoseconds: 600_000_000)
                if seq == loadSeq { next(auto: true) }
            }
        }
    }

    private func startStreamer(_ t: Track, at: Double) {
        stopStreamer()
        let url = baseURL.appendingPathComponent("api/audio/\(t.id)")
        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: HTTPCookieStorage.shared.cookies(for: baseURL) ?? []])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 4
        let s = AVPlayer(playerItem: item)
        s.volume = Float(volume)
        if at > 0 { s.seek(to: CMTime(seconds: at, preferredTimescale: 600)) }
        streamer = s
        streamEnd = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.streamer === s { self?.next(auto: true) } }
        }
        try? AVAudioSession.sharedInstance().setActive(true)
        s.play()
    }
    private func stopStreamer() {
        streamer?.pause()
        streamer = nil
        if let o = streamEnd { NotificationCenter.default.removeObserver(o); streamEnd = nil }
    }

    /// Le moteur a été reconfiguré (sortie audio changée) : reprise au même endroit.
    func engineRestarted() {
        guard current != nil, !(current?.isLive ?? false), A.file != nil else { return }
        let at = time
        A.schedule(from: at, to: trimNow(current)?["end"].double)
        if !playing { A.pause(); audio.pause() }
    }

    private func upcoming(_ n: Int) -> [Track] { Array(queue.dropFirst(idx + 1).prefix(n)) }

    /// Le serveur résout à l'avance les prochains titres ; l'appareil les récupère.
    private func prefetch() {
        if smart { for t in [current] + upcoming(2).map(Optional.some) { if let t = sub(t) { Task { _ = await loadTrim(t) } } } }
        let next = upcoming(3).filter { !Offline.shared.has($0.id) }
        let key = next.map(\.id).joined(separator: ",")
        if !next.isEmpty && key != lastPrefetch {
            lastPrefetch = key
            Task { _ = try? await yt("/prefetch", body: ["ids": .arr(next.map { .str($0.id) })]) }
        }
        AudioFiles.shared.prepare(upcoming(2).compactMap { sub($0)?.id })
    }

    /// Prépare le titre suivant sur l'autre platine (enchaînement sans blanc, fondu, Auto mix).
    private func preloadNext() {
        guard repeatMode != "one" else { return }
        let n = idx + 1 < queue.count ? idx + 1 : repeatMode == "all" ? 0 : -1
        guard n >= 0, let t = sub(queue[safe: n]) else { return }
        queue[n] = t
        guard preloaded != t.id else { return }
        preloaded = t.id
        Task {
            guard let f = try? await AudioFiles.shared.file(t.id), preloaded == t.id else { return }
            if smart { _ = await loadTrim(t) }
            guard preloaded == t.id, (try? B.load(f, id: t.id, engine: audio.engine)) != nil else { preloaded = nil; return }
        }
    }

    @discardableResult func fillRadio(_ id: String, replace: Bool = false, fresh: Bool = false) async -> Int {
        guard let w = try? await yt("/watch" + q(["videoId": id, "radio": replace ? nil : "true", "limit": 40]), ttl: 60, fresh: fresh) else { return 0 }
        info[id] = ["lyrics": w["lyrics"], "related": w["related"]]
        let have = Set(queue.map(\.id))
        let add = parseTracks(w["tracks"]).filter { !have.contains($0.id) }.map { var t = $0; t.auto = true; return t }
        queue.append(contentsOf: add)
        changed()
        prefetch()
        return add.count
    }
    private func maybeRadio() async {
        guard autoplay, !radioBusy, repeatMode == "off", queue.count - idx <= 6, let seed = queue.last, !(current?.isLive ?? false) else { return }
        radioBusy = true
        defer { radioBusy = false }
        var n = await fillRadio(seed.id)
        var i = queue.count - 2
        while n == 0 && i >= max(0, queue.count - 4) { n = await fillRadio(queue[i].id, fresh: true); i -= 1 }
    }

    // MARK: horloge (fin utile, préchargement, fondus, historique, sauvegarde)
    private func tick() {
        if let m = mirror { time = m(); return }
        guard let t = current else { return }
        if let l = liveItem {
            let p = l.timeControlStatus == .playing
            if loading && p { loading = false; changed() }
            return
        }
        if let st = streamer, A.id != t.id || A.file == nil {
            let p = st.timeControlStatus == .playing
            if p { time = st.currentTime().seconds }
            if loading && p { loading = false; changed() }
            return
        }
        guard A.file != nil, A.isPlaying, !loading else { return }
        time = A.time
        if fading { return }
        let tr = trimNow(t)
        let end = min(tr?["end"].double ?? .infinity, duration > 0 ? duration : .infinity, A.length > 0 ? A.length : .infinity)
        let left = end - time
        if left < (automix ? 120 : 25) { preloadNext() }
        if automix, repeatMode != "one", queue[safe: idx + 1] != nil, automixWatch(left: left, end: end) { return }
        if crossfade > 0, left < crossfade, left > 0.5, repeatMode != "one", let n = queue[safe: idx + 1], preloaded == n.id, B.id == n.id {
            startFade(dur: crossfade, entry: startOf(n))
        }
        if !reported.contains(t.id) && time > min(30, (duration > 0 ? duration : 60) / 2) {
            reported.insert(t.id)
            let plain = t.plain
            Task { _ = try? await yt("/history", body: ["videoId": .str(t.id), "track": JSON.encode(plain)]) }
            var recent = Store.get("recent", [Track]()).filter { $0.id != t.id }
            recent.insert(plain, at: 0)
            Store.set("recent", Array(recent.prefix(60)))
        }
        if Date().timeIntervalSince(lastSave) > 5 { save(now: true) }
        NowPlaying.tick(self)
    }

    // MARK: fondu enchaîné / Auto mix
    struct MixPlan { var key: String; var kind: String; var start: Double; var dur: Double; var entry: Double; var rate: Double; var beats = 0.0; var blA = 0.0; var nbl = 0.0; var a: JSON = nil; var b: JSON = nil; var armed = false }
    private(set) var mixPlan: MixPlan?
    private var analyses: [String: JSON] = [:]
    private var analysisTasks = Set<String>()
    /// Départ prévu de l'Auto mix dans le titre en cours (s), ou nil.
    var mixStart: Double? {
        guard automix, let p = mixPlan, let t = current, let n = queue[safe: idx + 1], p.key == "\(t.id)>\(n.id)" else { return nil }
        return p.start
    }

    private func analysisOf(_ t: Track?) -> JSON?? {
        guard let t, !t.isLive else { return .some(nil) }
        if let a = analyses[t.id] { return .some(a.isNull ? nil : a) }
        if !analysisTasks.contains(t.id) {
            analysisTasks.insert(t.id)
            Task {
                let a = try? await API.shared.raw("/api/automix/\(t.id)", timeout: 130)
                analyses[t.id] = a ?? .null
                analysisTasks.remove(t.id)
            }
        }
        return nil // analyse en cours
    }

    private func planMix(_ t: Track, _ n: Track, end: Double) -> MixPlan? {
        guard let a0 = analysisOf(t), let b0 = analysisOf(n) else { return nil }
        let fade = crossfade > 0 ? crossfade : 6
        let key = "\(t.id)>\(n.id)"
        guard let a = a0, let b = b0, let ab = a["bpm"].double, let bb = b["bpm"].double, ab > 0, bb > 0, abs(ab / bb - 1) <= 0.08 else {
            return MixPlan(key: key, kind: "fade", start: end - fade, dur: fade, entry: startOf(n), rate: 1)
        }
        let blA = 60 / ab, nbl = 60 / bb
        var beats = Double((ab < 105 ? 8 : 16) * 4)
        var entry = max(b["mix_in"].double ?? 0, startOf(n))
        if let drop = b["cues"].array.first(where: { ($0["l"].string ?? "").range(of: "drop", options: .caseInsensitive) != nil && ($0["t"].double ?? 0) > entry + 32 * nbl - 0.05 }), let dt = drop["t"].double {
            let intro = floor((dt - entry) / (nbl * 16) + 1e-6) * 16
            if intro >= 32 && intro < beats { beats = intro }
            entry = max(entry, dt - beats * nbl)
        }
        let out = min(end, a["mix_out"].double ?? end)
        let ref = a["mix_in"].double ?? a["beat0"].double ?? 0, ph = 16 * blA
        let start = ref + floor((out - beats * blA - ref) / ph + 1e-6) * ph
        return MixPlan(key: key, kind: "pro", start: start, dur: beats * blA, entry: entry, rate: ab / bb, beats: beats, blA: blA, nbl: nbl, a: a, b: b)
    }

    /// true = l'Auto mix s'en occupe (pas de fondu classique).
    private func automixWatch(left: Double, end: Double) -> Bool {
        guard let t = current, let n = queue[safe: idx + 1], !n.isLive else { return false }
        _ = analysisOf(t); _ = analysisOf(n)
        if mixPlan?.key != "\(t.id)>\(n.id)" {
            mixPlan = planMix(t, n, end: end)
            guard mixPlan != nil else { return left > 8 }
            emit("automix")
        }
        guard var plan = mixPlan else { return false }
        let lead = plan.start - time
        if lead > 0.6 || preloaded != n.id || B.id != n.id { return lead > 0.5 }
        if !plan.armed {
            plan.armed = true
            mixPlan = plan
            // départ au temps près : la platine B démarre à l'heure exacte du moteur
            let delay = max(0, lead)
            if plan.kind == "pro" { startPro(plan, delay: delay) } else { startFade(dur: plan.dur, entry: plan.entry, delay: delay) }
        }
        return true
    }

    private func hostTime(after s: Double) -> AVAudioTime? {
        guard s > 0.01 else { return nil }
        return AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: s))
    }

    private var fadeTimer: Timer?
    private var fadeNextIdx = 0
    private func startFade(dur: Double, entry: Double, delay: Double = 0) {
        fading = true
        fadeNextIdx = idx + 1
        let from = A, to = B
        to.volume = 0
        to.rate = 1
        to.schedule(from: entry, to: trimNow(queue[safe: fadeNextIdx])?["end"].double, at: hostTime(after: delay))
        if automix { mixing = true; emit("automix") }
        let t0 = Date().addingTimeInterval(delay)
        fadeTimer?.invalidate()
        fadeTimer = Timer.common(withTimeInterval: 0.03, repeats: true) { [weak self] tm in
            MainActor.assumeIsolated {
                guard let self, self.fading else { tm.invalidate(); return }
                let p = min(1, max(0, Date().timeIntervalSince(t0) / dur))
                to.volume = Float(sin(p * .pi / 2))
                from.volume = Float(cos(p * .pi / 2))
                if p >= 1 { tm.invalidate(); self.completeFade() }
            }
        }
    }

    private func startPro(_ plan: MixPlan, delay: Double) {
        fading = true
        fadeNextIdx = idx + 1
        mixing = true
        emit("automix")
        let from = A, to = B
        let KILL: Float = -26
        to.eq.bands[0].gain = KILL; to.eq.bands[2].gain = -8
        to.rate = Float(plan.rate)
        to.volume = 0
        to.schedule(from: plan.entry, to: trimNow(queue[safe: fadeNextIdx])?["end"].double, at: hostTime(after: delay))
        let dur = plan.dur
        func eqp(_ x: Double) -> Float { Float(sin(max(0, min(1, x)) * .pi / 2)) }
        func frac(_ x: Double) -> Double { x - floor(x) }
        var swapped = false
        fadeTimer?.invalidate()
        fadeTimer = Timer.common(withTimeInterval: 0.03, repeats: true) { [weak self] tm in
            MainActor.assumeIsolated {
                guard let self, self.fading else { tm.invalidate(); return }
                let p = min(1, max(0, (from.time - plan.start) / dur))
                to.volume = eqp(p / 0.3)
                from.volume = p < 0.75 ? 1 : Float(cos((p - 0.75) / 0.25 * .pi / 2))
                if p >= 0.25 && p < 0.5 { let x = Float((p - 0.25) / 0.25); to.eq.bands[2].gain = -8 * (1 - x); from.eq.bands[2].gain = -6 * x }
                if p >= 0.5 && !swapped { swapped = true; from.eq.bands[0].gain = KILL; to.eq.bands[0].gain = 0; to.eq.bands[2].gain = 0 }
                if p >= 0.5 {
                    let x = Float(min(1, (p - 0.5) / 0.25))
                    from.eq.bands[1].gain = -12 * x; from.eq.bands[2].gain = -6 - 12 * x
                    if p > 0.75 { from.eq.bands[3].frequency = Float(10 + 1200 * pow((p - 0.75) / 0.25, 2)) }
                }
                // calage de phase : écart des temps ramené par une légère correction de vitesse
                let phA = frac((from.time - (plan.a["beat0"].double ?? 0)) / plan.blA), phB = frac((to.time - (plan.b["beat0"].double ?? 0)) / plan.nbl)
                var d = phB - phA
                if d > 0.5 { d -= 1 }; if d < -0.5 { d += 1 }
                if abs(d) < 0.03 { d = 0 }
                to.rate = Float(plan.rate * (1 - max(-0.02, min(0.02, d * 0.1))))
                if p >= 1 || !from.isPlaying {
                    tm.invalidate()
                    self.completeFade()
                    // retour doux à la vitesse d'origine (30 s)
                    let r0 = to.rate, g0 = Date()
                    Timer.common(withTimeInterval: 0.2, repeats: true) { g in
                        MainActor.assumeIsolated {
                            guard self.A === to, !self.fading else { g.invalidate(); return }
                            let k = Float(min(1, Date().timeIntervalSince(g0) / 30))
                            to.rate = r0 + (1 - r0) * k
                            if k >= 1 { g.invalidate() }
                        }
                    }
                }
            }
        }
    }

    /// Le suivant devient le titre en cours.
    private func completeFade() {
        let from = A, to = B
        from.unload()
        from.resetMix(); from.volume = 1
        to.volume = 1
        for b in to.eq.bands.prefix(3) { b.gain = 0 }; to.eq.bands[3].frequency = 10
        cur = 1 - cur
        preloaded = nil
        fading = false
        mixPlan = nil
        mixing = false
        idx = fadeNextIdx
        playing = true
        changed()
        NowPlaying.update(self)
        emit("automix")
        Task { await maybeRadio(); prefetch() }
    }
    /// Pause, saut ou changement de titre pendant un fondu : on termine tout de suite sur le titre en cours.
    private func finishFadeNow() {
        fadeTimer?.invalidate()
        B.stop(); B.resetMix(); B.volume = 1
        A.volume = 1
        fading = false
        mixPlan = nil
        if mixing { mixing = false; emit("automix") }
    }
    private func resetMix() { for d in audio.decks { d.resetMix() } }

    // MARK: persistance
    func changed() { emit("queue"); emit("state"); save() }

    func save(now: Bool = false) {
        guard current?.isLive != true, mirror == nil, !queue.isEmpty else { return }
        lastSave = Date()
        let start = max(0, idx - 50)
        let st: JSON = ["queue": JSON.encode(Array(queue[start..<min(queue.count, idx + 150)])), "idx": .num(Double(idx - start)), "t": .num(time), "shuffle": .bool(shuffle), "repeat": .str(repeatMode), "source": JSON.encode(source), "at": .num(Date().timeIntervalSince1970 * 1000)]
        Store.set("session", st)
    }
    func restore() {
        let s = Store.get("session", JSON.null)
        let qq = s["queue"].array.compactMap { $0.decode(Track.self) }
        guard !qq.isEmpty else { return }
        queue = qq
        idx = min(s["idx"].int ?? 0, qq.count - 1)
        shuffle = s["shuffle"].bool ?? false
        repeatMode = s["repeat"].string ?? "off"
        source = s["source"].decode(Source.self)
        load(autoplay: false, at: s["t"].double ?? 0)
    }

    /// Instantané publié aux autres appareils (même forme que la PWA).
    func snapshot() -> JSON {
        let start = max(0, idx - 30)
        let q = idx >= 0 ? Array(queue[start..<min(queue.count, idx + 120)]) : []
        return ["queue": JSON.encode(q), "idx": .num(Double(idx - start)), "position": .num(time), "playing": .bool(playing), "shuffle": .bool(shuffle), "repeat": .str(repeatMode), "source": JSON.encode(source), "autoplay": .bool(autoplay), "volume": .num(volume), "device": .str(Live.shared.name), "eq": EQ.shared.json]
    }
    /// Affiche l'état d'un autre appareil sans jouer ici (miroir).
    func applyMirror(_ st: JSON, time tf: @escaping () -> Double) {
        if playing || A.isPlaying || liveItem != nil || streamer != nil { liveItem?.pause(); liveItem = nil; stopStreamer(); A.pause(); B.stop() }
        queue = st["queue"].array.compactMap { $0.decode(Track.self) }
        idx = st["idx"].int ?? 0
        playing = st["playing"].bool ?? false
        loading = false
        shuffle = st["shuffle"].bool ?? false
        repeatMode = st["repeat"].string ?? "off"
        source = st["source"].decode(Source.self)
        mirror = tf
        time = tf()
        emit("queue"); emit("state")
        NowPlaying.update(self)
    }
    var hasLocalAudio: Bool { A.isPlaying || liveItem?.timeControlStatus == .playing }
}

extension Timer {
    /// Minuteur qui continue pendant les défilements (mode « common » de la boucle principale).
    @discardableResult static func common(withTimeInterval i: TimeInterval, repeats: Bool, block: @escaping @Sendable (Timer) -> Void) -> Timer {
        let t = Timer(timeInterval: i, repeats: repeats, block: block)
        RunLoop.main.add(t, forMode: .common)
        return t
    }
}
