import MediaPlayer
import UIKit

/// Écran verrouillé, Centre de contrôle, écouteurs (aussi pour le miroir d'un appareil distant).
@MainActor enum NowPlaying {
    private static var art: (id: String, a: MPMediaItemArtwork)?
    private static var lastTick = Date.distantPast

    static func setup(_ p: Player) {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { _ in p.play(); return .success }
        c.pauseCommand.addTarget { _ in p.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { _ in p.toggle(); return .success }
        c.nextTrackCommand.addTarget { _ in p.next(); return .success }
        c.previousTrackCommand.addTarget { _ in p.prev(); return .success }
        c.changePlaybackPositionCommand.addTarget { e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            p.seek(e.positionTime); return .success
        }
        c.likeCommand.addTarget { _ in Task { await Library.shared.toggleLike(p.current) }; return .success }
        c.likeCommand.localizedTitle = "J'aime"
        c.seekForwardCommand.isEnabled = false
        c.seekBackwardCommand.isEnabled = false
    }

    static func update(_ p: Player) {
        guard let t = p.current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        let live = t.isLive
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artistLine,
            MPNowPlayingInfoPropertyIsLiveStream: live,
            MPNowPlayingInfoPropertyPlaybackRate: p.playing && !p.loading ? 1.0 : 0.0,
        ]
        if !live {
            info[MPMediaItemPropertyPlaybackDuration] = p.duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = p.time
        }
        if let a = t.album?.name { info[MPMediaItemPropertyAlbumTitle] = a }
        if let art, art.id == t.thumb { info[MPMediaItemPropertyArtwork] = art.a } else { loadArt(t, p) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = p.playing ? .playing : .paused
        let c = MPRemoteCommandCenter.shared()
        c.nextTrackCommand.isEnabled = !live
        c.previousTrackCommand.isEnabled = !live
        c.changePlaybackPositionCommand.isEnabled = !live
        c.likeCommand.isActive = Library.shared.liked.contains(t.id)
    }

    /// Position recalée de temps en temps (l'écran verrouillé extrapole entre deux).
    static func tick(_ p: Player) {
        guard Date().timeIntervalSince(lastTick) > 5 else { return }
        lastTick = Date()
        update(p)
    }

    private static func loadArt(_ t: Track, _ p: Player) {
        guard let u = t.thumbURL else { return }
        let key = t.thumb
        Task {
            guard let img = await ImageCache.shared.image(u) else { return }
            art = (key, MPMediaItemArtwork(boundsSize: img.size) { _ in img })
            if p.current?.thumb == key { update(p) }
        }
    }
}
