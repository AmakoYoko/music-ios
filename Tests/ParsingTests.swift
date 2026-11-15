import AVFoundation
import XCTest
@testable import LamasMusic

/// Réponses réelles du moteur (catalogue public) → modèles de l'appli.
final class ParsingTests: XCTestCase {
    func fx(_ name: String) throws -> JSON {
        let u = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"), "fixture \(name)")
        return try XCTUnwrap(JSON.parse(Data(contentsOf: u)))
    }
    func checkTracks(_ ts: [Track], min: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(ts.count, min, file: file, line: line)
        for t in ts {
            XCTAssertEqual(t.id.count, 11, "id \(t.id)", file: file, line: line)
            XCTAssertFalse(t.title.isEmpty, file: file, line: line)
            XCTAssertTrue(t.thumb.hasPrefix("/api/img?u=https"), "pochette \(t.thumb)", file: file, line: line)
            XCTAssertNotNil(t.thumbURL, file: file, line: line)
        }
    }

    func testSearch() throws {
        let songs = parseTracks(try fx("search_songs"))
        checkTracks(songs, min: 5)
        XCTAssertTrue(songs.allSatisfy { ($0.duration ?? 0) > 0 })
        XCTAssertTrue(songs.allSatisfy { !$0.artists.isEmpty })
        let all = try fx("search").array
        let kinds = all.map(kindOf)
        XCTAssertTrue(kinds.contains { if case .artist = $0 { return true }; return false }, "artiste dans la recherche")
        XCTAssertTrue(kinds.contains { if case .album = $0 { return true }; return false }, "album dans la recherche")
        XCTAssertTrue(kinds.contains(.song))
        XCTAssertNotNil(all.first { $0["category"].string == "Top result" })
    }

    func testAlbum() throws {
        let a = try fx("album")
        let ctx = TrackCtx(album: AlbumRef(name: a["title"].string ?? "", id: "x"), thumbs: a["thumbnails"], artists: a["artists"].decode([Artist].self))
        let ts = parseTracks(a["tracks"], ctx)
        checkTracks(ts, min: 5)
        XCTAssertTrue(ts.allSatisfy { $0.album?.name == a["title"].string })
        XCTAssertFalse(img(a["thumbnails"], 800).isEmpty)
    }

    func testArtist() throws {
        let a = try fx("artist")
        XCTAssertFalse((a["name"].string ?? "").isEmpty)
        checkTracks(parseTracks(a["songs"]["results"]), min: 3)
        for it in a["albums"]["results"].array { if case .album = kindOf(it) {} else { XCTFail("album attendu : \(itemTitle(it))") } }
        XCTAssertNotNil(a["radioId"].string ?? a["shuffleId"].string, "radio de l'artiste")
    }

    func testPlaylistAndWatch() throws {
        checkTracks(parseTracks(try fx("playlist")["tracks"]), min: 5)
        let w = try fx("watch")
        let ts = parseTracks(w["tracks"])
        checkTracks(ts, min: 10)
        XCTAssertTrue(ts.allSatisfy { ($0.duration ?? 0) > 0 }, "durée « length » lue")
        XCTAssertNotNil(w["lyrics"].string)
    }

    func testExploreAndMoods() throws {
        let ex = try fx("explore")
        XCTAssertFalse(ex["new_releases"].array.isEmpty)
        for it in ex["new_releases"].array { XCTAssertNotEqual(kindOf(it), .other, itemTitle(it)) }
        checkTracks(parseTracks(ex["trending"]["items"]), min: 5)
        let m = try fx("moods")
        XCTAssertFalse(m.object.isEmpty)
        XCTAssertTrue(m.object.values.allSatisfy { $0.array.allSatisfy { $0["params"].string != nil } })
    }

    func testLyrics() throws {
        let l = try fx("lyrics")["lines"].array
        XCTAssertGreaterThan(l.count, 10)
        let times = l.compactMap { $0["t"].double }
        XCTAssertEqual(times, times.sorted())
    }

    func testCleanTitle() {
        let d = [Artist(name: "Daft Punk")]
        XCTAssertEqual(cleanTitle("Daft Punk - Get Lucky (Official Video)", d), "Get Lucky")
        XCTAssertEqual(cleanTitle("Get Lucky [HD]", d), "Get Lucky")
        XCTAssertEqual(cleanTitle("One More Time | Official Audio", d), "One More Time")
        XCTAssertEqual(cleanTitle("Instant Crush (feat. Julian Casablancas)", d), "Instant Crush (feat. Julian Casablancas)")
        XCTAssertEqual(cleanTitle("Autre - Titre", d), "Autre - Titre")
    }

    func testRoutes() {
        XCTAssertEqual(Route(href: "#/album/MPREb_abc"), .album("MPREb_abc"))
        XCTAssertEqual(Route(href: "#/playlist/LM"), .playlist("LM"))
        XCTAssertEqual(Route(href: "#/mpl/mu123"), .mpl("mu123"))
        XCTAssertEqual(Route(href: "#/smart/mix"), .smart("mix"))
        XCTAssertEqual(Route(href: "#/stats?d=7"), .stats(7))
        XCTAssertEqual(Route(href: "#/mood/ggMP%3D%3D?t=Rock"), .mood("ggMP==", "Rock"))
        XCTAssertEqual(Route(href: "#/search?q=daft%20punk&f=songs"), .search("daft punk", "songs"))
        XCTAssertEqual(Route(href: "#/radio"), .radio)
        XCTAssertNil(Route(href: nil))
        XCTAssertNil(Route(href: "https://x"))
    }

    /// Les titres circulent entre la PWA et l'appli (playlists Music, historique, état publié) : même format.
    func testTrackWebFormat() throws {
        let web = #"{"id":"1tSxR5_FfeM","title":"tout à la fois","artists":[{"name":"satine","id":"UC1"}],"album":{"name":"A","id":null},"thumb":"/api/img?u=x","duration":166,"explicit":false,"key":"5ece","available":true,"auto":true}"#
        let t = try JSONDecoder().decode(Track.self, from: Data(web.utf8))
        XCTAssertEqual(t.id, "1tSxR5_FfeM"); XCTAssertEqual(t.key, "5ece"); XCTAssertEqual(t.auto, true); XCTAssertEqual(t.duration, 166)
        let minimal = try JSONDecoder().decode(Track.self, from: Data(#"{"id":"abcdefghijk"}"#.utf8))
        XCTAssertTrue(minimal.available)
        let back = JSON.encode(t)
        XCTAssertEqual(back["thumb"].string, "/api/img?u=x")
        XCTAssertEqual(back["artists"][0]["name"].string, "satine")
        XCTAssertEqual(track(back)?.id, t.id, "un titre déjà normalisé se relit")
    }

    func testImgSizes() {
        let u = img(.str("https://lh3.googleusercontent.com/abc=w60-h60-l90-rj"), 800)
        XCTAssertTrue(u.removingPercentEncoding!.hasSuffix("=w800-h800-l90-rj"), u)
        let v = img(.str("https://i.ytimg.com/vi/xyz/sddefault.jpg"))
        XCTAssertTrue(v.removingPercentEncoding!.hasSuffix("/vi/xyz/hqdefault.jpg"), v)
        XCTAssertEqual(img(.null), "")
    }

    func testQuery() {
        XCTAssertEqual(q(["a": "x y", "b": nil, "c": 3, "d": ""]), "?a=x%20y&c=3")
        XCTAssertEqual(q(["a": nil]), "")
    }
}

/// File d'attente (sans son : les titres ne sont pas chargés).
@MainActor final class QueueTests: XCTestCase {
    func mk(_ n: Int) -> [Track] { (0..<n).map { Track(id: String(format: "t%010d", $0), title: "T\($0)") } }

    func testInsertMoveRemove() {
        let p = Player.shared
        p.queue = mk(5); p.idx = 1
        p.playNext([Track(id: "nnnnnnnnnnn", title: "N")])
        XCTAssertEqual(p.queue[2].id, "nnnnnnnnnnn")
        var auto = Track(id: "aaaaaaaaaaa", title: "A"); auto.auto = true
        p.queue.append(auto)
        p.addToQueue([Track(id: "eeeeeeeeeee", title: "E")])
        XCTAssertEqual(p.queue.firstIndex { $0.id == "eeeeeeeeeee" }, p.queue.firstIndex { $0.id == "aaaaaaaaaaa" }! - 1, "avant la radio automatique")
        let cur = p.current
        p.move(4, 0)
        XCTAssertEqual(p.current, cur, "le titre en cours reste le même")
        p.remove(p.idx)
        XCTAssertEqual(p.current, cur, "on ne retire pas le titre en cours")
        let n = p.queue.count
        p.remove(p.queue.count - 1)
        XCTAssertEqual(p.queue.count, n - 1)
        p.clearUpcoming()
        XCTAssertEqual(p.queue.count, p.idx + 1)
    }

    func testShuffleRestoresOrder() {
        let p = Player.shared
        let ts = mk(30)
        p.queue = ts; p.idx = 4; p.shuffle = false
        p.toggleShuffle(true)
        XCTAssertEqual(p.idx, 0)
        XCTAssertEqual(p.current?.id, ts[4].id)
        XCTAssertEqual(Set(p.queue.map(\.id)), Set(ts.map(\.id)))
        p.toggleShuffle(false)
        XCTAssertEqual(p.queue.map(\.id), ts.map(\.id))
        XCTAssertEqual(p.idx, 4)
    }

    func testRepeatCycle() {
        let p = Player.shared
        p.repeatMode = "off"
        p.cycleRepeat(); XCTAssertEqual(p.repeatMode, "all")
        p.cycleRepeat(); XCTAssertEqual(p.repeatMode, "one")
        p.cycleRepeat(); XCTAssertEqual(p.repeatMode, "off")
    }

    func testSnapshotMatchesWeb() {
        let p = Player.shared
        p.queue = mk(3); p.idx = 1
        let s = p.snapshot()
        for k in ["queue", "idx", "position", "playing", "shuffle", "repeat", "autoplay", "volume", "device", "eq"] { XCTAssertTrue(s[k].exists || k == "source", k) }
        XCTAssertEqual(s["queue"].array.count, 3)
        XCTAssertEqual(s["eq"]["gains"].array.count, 7)
    }
}

/// Fichiers audio : MP4 fragmenté (format DASH des fichiers du serveur) → lisible par AVAudioEngine ; la platine avance.
final class AudioTests: XCTestCase {
    let frag = URL(fileURLWithPath: "/tmp/music-test/frag.m4a")

    func testFragmentedFileBecomesReadable() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: frag.path), "pas de fichier de test")
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("frag-\(UUID()).m4a")
        try FileManager.default.copyItem(at: frag, to: f)
        try await AudioFiles.makeReadable(f)
        let a = try AVAudioFile(forReading: f)
        let secs = Double(a.length) / a.processingFormat.sampleRate
        XCTAssertEqual(secs, 6, accuracy: 0.5, "durée lue")
    }

    @MainActor func testDeckPlaysAndSeeks() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: frag.path), "pas de fichier de test")
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("deck-\(UUID()).m4a")
        try FileManager.default.copyItem(at: frag, to: f)
        try await AudioFiles.makeReadable(f)
        let e = AudioEngine.shared
        e.start()
        try XCTSkipUnless(e.engine.isRunning, "pas de sortie audio sur ce simulateur")
        let d = e.decks[1]
        try d.load(f, id: "test", engine: e.engine)
        XCTAssertEqual(d.length, 6, accuracy: 0.5)
        d.schedule(from: 2)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertGreaterThan(d.time, 2.6, "la lecture avance")
        d.pause()
        let t = d.time
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(d.time, t, accuracy: 0.05, "pause")
        d.rate = 1.05
        d.resume()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertGreaterThan(d.time, t + 0.3)
        var ended = false
        d.onEnd = { ended = true }
        d.schedule(from: 5.5)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(ended, "fin de titre signalée")
        d.unload()
    }
}
