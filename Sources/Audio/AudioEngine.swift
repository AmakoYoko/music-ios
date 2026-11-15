import Accelerate
import AVFoundation

/// Platine : lecteur de fichier → vitesse (sans changer la hauteur) → voie de mixage (basses, médiums, aigus, passe-haut) → volume.
final class Deck {
    let node = AVAudioPlayerNode()
    let pitch = AVAudioUnitTimePitch()
    let eq = AVAudioUnitEQ(numberOfBands: 4)
    let mixer = AVAudioMixerNode()
    private(set) var file: AVAudioFile?
    private(set) var id: String?
    private var startFrame: AVAudioFramePosition = 0
    private var pausedAt: Double?
    private var token = 0
    var onEnd: (() -> Void)?

    init() {
        let b = eq.bands
        b[0].filterType = .lowShelf; b[0].frequency = 220
        b[1].filterType = .parametric; b[1].frequency = 1000; b[1].bandwidth = 1.6
        b[2].filterType = .highShelf; b[2].frequency = 3200
        b[3].filterType = .highPass; b[3].frequency = 10; b[3].bandwidth = 0.5
        for x in b { x.gain = 0; x.bypass = false }
    }

    var sampleRate: Double { file?.processingFormat.sampleRate ?? 44100 }
    var length: Double { file.map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0 }
    var isPlaying: Bool { node.isPlaying }
    var rate: Float { get { pitch.rate } set { pitch.rate = newValue } }
    var volume: Float { get { mixer.outputVolume } set { mixer.outputVolume = newValue } }

    /// Position dans le fichier (s).
    var time: Double {
        if let p = pausedAt { return p }
        guard file != nil, let nt = node.lastRenderTime, nt.isSampleTimeValid, let pt = node.playerTime(forNodeTime: nt) else { return Double(startFrame) / sampleRate }
        return Double(startFrame + pt.sampleTime) / pt.sampleRate
    }

    func load(_ url: URL, id: String, engine: AVAudioEngine) throws {
        stop()
        let f = try AVAudioFile(forReading: url)
        let fmt = f.processingFormat
        if file?.processingFormat != fmt { engine.connect(node, to: pitch, format: fmt) }
        file = f
        self.id = id
        startFrame = 0
        pausedAt = 0
    }

    /// Programme la lecture de `from` à `to` (fin du fichier par défaut), au moment `at` (tout de suite si nil).
    func schedule(from: Double, to: Double? = nil, at: AVAudioTime? = nil) {
        guard let f = file else { return }
        token += 1
        let tk = token
        node.stop()
        let sr = f.processingFormat.sampleRate
        let start = AVAudioFramePosition(max(0, min(from, length - 0.05)) * sr)
        var end = f.length
        if let to, to > from { end = min(end, AVAudioFramePosition(to * sr)) }
        let count = AVAudioFrameCount(max(1, end - start))
        startFrame = start
        node.scheduleSegment(f, startingFrame: start, frameCount: count, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.token == tk, self.pausedAt == nil else { return }
                self.onEnd?()
            }
        }
        pausedAt = nil
        node.play(at: at)
    }

    func pause() {
        guard pausedAt == nil else { return }
        pausedAt = time
        node.pause()
    }
    func resume() {
        guard let p = pausedAt else { return }
        // node.pause garde la position : on reprend simplement
        if node.lastRenderTime != nil { pausedAt = nil; node.play() } else { schedule(from: p) }
    }
    func stop() {
        token += 1
        node.stop()
        pausedAt = nil
    }
    func unload() { stop(); file = nil; id = nil; startFrame = 0 }
    func resetMix() {
        for b in eq.bands.prefix(3) { b.gain = 0 }
        eq.bands[3].frequency = 10
        rate = 1
    }
}

/// Moteur audio natif : deux platines (fondu enchaîné, enchaînement sans blanc, Auto mix), égaliseur 7 bandes,
/// analyse du son pour le lecteur animé.
final class AudioEngine {
    static let shared = AudioEngine()
    static let bands: [Float] = [60, 150, 400, 1000, 2400, 6000, 15000]
    let engine = AVAudioEngine()
    let decks = [Deck(), Deck()]
    let bus = AVAudioMixerNode()
    let master = AVAudioUnitEQ(numberOfBands: 7)
    /// Niveaux pour le lecteur animé : basses, médiums, aigus, attaque (0…1).
    private(set) var levels: (bass: Float, mid: Float, high: Float, hit: Float) = (0, 0, 0, 0)
    private var avgBass: Float = 0
    var analysing = false

    private init() {
        engine.attach(bus)
        engine.attach(master)
        for (i, b) in master.bands.enumerated() {
            b.filterType = i == 0 ? .lowShelf : i == 6 ? .highShelf : .parametric
            b.frequency = Self.bands[i]
            b.bandwidth = 1.1
            b.gain = 0
            b.bypass = false
        }
        for d in decks {
            engine.attach(d.node); engine.attach(d.pitch); engine.attach(d.eq); engine.attach(d.mixer)
            engine.connect(d.node, to: d.pitch, format: nil)
            engine.connect(d.pitch, to: d.eq, format: nil)
            engine.connect(d.eq, to: d.mixer, format: nil)
            engine.connect(d.mixer, to: bus, format: nil)
        }
        engine.connect(bus, to: master, format: nil)
        engine.connect(master, to: engine.mainMixerNode, format: nil)
        installTap()
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.start()
                Player.shared.engineRestarted()
            }
        }
    }

    func start() {
        guard !engine.isRunning else { return }
        engine.prepare()
        try? engine.start()
    }
    /// Moteur arrêté en pause : sinon il rend du silence et iOS affiche « en lecture ».
    func pause() { if engine.isRunning { engine.pause() } }

    func setEQ(on: Bool, gains: [Double]) {
        for (i, b) in master.bands.enumerated() { b.gain = on ? Float(gains[safe: i] ?? 0) : 0 }
    }

    private func installTap() {
        let fmt = master.outputFormat(forBus: 0)
        let n = 1024
        let log2n = vDSP_Length(10)
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else { return }
        master.installTap(onBus: 0, bufferSize: AVAudioFrameCount(n), format: nil) { [weak self] buf, _ in
            guard let self, self.analysing, let ch = buf.floatChannelData?[0], Int(buf.frameLength) >= n else { return }
            var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
            var window = [Float](repeating: 0, count: n)
            vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
            var x = [Float](repeating: 0, count: n)
            vDSP_vmul(ch, 1, window, 1, &x, 1, vDSP_Length(n))
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    x.withUnsafeBufferPointer { xp in
                        xp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &sc, 1, vDSP_Length(n / 2)) }
                    }
                    fft.forward(input: sc, output: &sc)
                    var mags = [Float](repeating: 0, count: n / 2)
                    vDSP_zvabs(&sc, 1, &mags, 1, vDSP_Length(n / 2))
                    let sr = Float(fmt.sampleRate > 0 ? fmt.sampleRate : 44100), hz = sr / Float(n)
                    func band(_ a: Float, _ b: Float) -> Float {
                        let i0 = max(1, Int(a / hz)), i1 = min(n / 2 - 1, max(i0 + 1, Int(b / hz)))
                        var s: Float = 0
                        vDSP_meanv(Array(mags[i0..<i1]), 1, &s, vDSP_Length(i1 - i0))
                        return min(1, s / 40)
                    }
                    let bass = band(30, 160), mid = band(300, 2000), high = band(4000, 12000)
                    self.avgBass = self.avgBass * 0.92 + bass * 0.08
                    let hit = max(0, min(1, (bass - self.avgBass * 1.3) * 4))
                    let l = self.levels
                    self.levels = (l.bass * 0.6 + bass * 0.4, l.mid * 0.6 + mid * 0.4, l.high * 0.6 + high * 0.4, max(hit, l.hit * 0.85))
                }
            }
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
