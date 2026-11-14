import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// Lecteur : AVPlayer, file d'attente, écran verrouillé et Centre de contrôle.
@Observable final class Player {
    static let shared = Player()
    private(set) var queue: [Track] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }

    private let player = AVPlayer()
    private var artwork: MPMediaItemArtwork?
    private var endObserver: Any?

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self else { return }
            self.elapsed = t.seconds
            if let d = self.player.currentItem?.duration.seconds, d.isFinite { self.duration = d }
            self.isPlaying = self.player.timeControlStatus != .paused
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let raw = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume) else { return }
            self?.player.play()
        }
        remoteCommands()
    }

    func play(_ tracks: [Track], at i: Int = 0) {
        queue = tracks
        start(i)
    }

    func toggle() { isPlaying ? pause() : resume() }
    func pause() { player.pause(); isPlaying = false; nowPlaying() }
    func resume() { player.play(); isPlaying = true; nowPlaying() }
    func next() { if index + 1 < queue.count { start(index + 1) } else { pause() } }
    func previous() { elapsed > 3 || index == 0 ? seek(0) : start(index - 1) }
    func seek(_ s: Double) {
        player.seek(to: CMTime(seconds: s, preferredTimescale: 600))
        elapsed = s
        nowPlaying()
    }

    private func start(_ i: Int) {
        guard queue.indices.contains(i) else { return }
        index = i
        let t = queue[i]
        let off = Offline.shared
        let url = off.has(t.videoId) ? off.file(t.videoId) : API.audioURL(t.videoId)
        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: HTTPCookieStorage.shared.cookies(for: baseURL) ?? []])
        let item = AVPlayerItem(asset: asset)
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in self?.next() }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.replaceCurrentItem(with: item)
        elapsed = 0
        duration = Double(t.duration_seconds ?? 0)
        resume()
        artwork = nil
        nowPlaying()
        if let u = t.art(600) {
            Task {
                guard let (d, _) = try? await URLSession.shared.data(from: u), let img = UIImage(data: d) else { return }
                await MainActor.run {
                    guard self.current?.videoId == t.videoId else { return }
                    self.artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                    self.nowPlaying()
                }
            }
        }
    }

    private func nowPlaying() {
        guard let t = current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artistLine,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let a = t.album?.name { info[MPMediaItemPropertyAlbumTitle] = a }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func remoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(e.positionTime); return .success
        }
    }
}
