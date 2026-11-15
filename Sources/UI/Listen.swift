import AVFoundation
import SwiftUI

/// « Quel est ce titre ? » : le micro enregistre 7 s (2 essais au plus) → /api/recognize (empreinte locale, sinon Shazam).
struct ListenView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var msg = "Touche pour écouter"
    @State private var sub = ""
    @State private var level: Float = 0
    @State private var busy = false
    @State private var result: Track?
    @State private var past = Store.get("recognized", [Track]())
    @State private var task: Task<Void, Never>?
    @State private var progress = 0.0

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "#1a73e8"), Color(hex: "#5e5ce6"), Color(hex: "#0a0a2a")], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 24) {
                HStack { Spacer(); Button { stop(); dismiss() } label: { Image(systemName: "xmark").font(.title3.bold()).padding(10).background(.white.opacity(0.15), in: Circle()) }.accessibilityLabel("Fermer") }
                Spacer()
                Button { busy ? stop() : start() } label: {
                    ZStack {
                        ForEach(0..<3) { i in Circle().stroke(.white.opacity(0.25 - Double(i) * 0.07), lineWidth: 2).scaleEffect(1 + CGFloat(level) * CGFloat(i + 1) * 0.35) }
                        Circle().trim(from: 0, to: progress).stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90)).padding(-8)
                        Circle().fill(.white.opacity(0.2)).overlay(Image(systemName: "waveform").font(.system(size: 64, weight: .semibold)))
                    }
                    .frame(width: 180, height: 180)
                    .animation(.easeOut(duration: 0.12), value: level)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Écouter")
                VStack(spacing: 4) { Text(msg).font(.title3.bold()); Text(sub).font(.subheadline).opacity(0.8) }.multilineTextAlignment(.center)
                if let r = result {
                    HStack(spacing: 12) {
                        RemoteImage(url: r.thumbURL).frame(width: 64, height: 64).cardShape(8)
                        VStack(alignment: .leading) { Text(r.title).bold().lineLimit(2); Text(r.artistLine).font(.subheadline).opacity(0.8) }
                        Spacer()
                        Button { Player.shared.playRadio(r); dismiss() } label: { Image(systemName: "play.fill").padding(12).background(.white, in: Circle()).foregroundStyle(.black) }.accessibilityLabel("Lire")
                    }
                    .padding(12).background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                    .contextMenu { TrackMenuItems(t: r) }
                }
                Spacer()
                if !past.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Derniers titres reconnus").font(.footnote.weight(.semibold)).opacity(0.8)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(past.prefix(15)) { t in
                                    Button { Player.shared.playRadio(t); dismiss() } label: {
                                        VStack(alignment: .leading) { RemoteImage(url: t.thumbURL).frame(width: 90, height: 90).cardShape(6); Text(t.title).font(.caption).lineLimit(1) }.frame(width: 90)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu { TrackMenuItems(t: t) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .foregroundStyle(.white)
        }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    private func start() {
        result = nil
        task = Task { await run() }
    }
    private func stop() {
        task?.cancel(); task = nil
        busy = false; level = 0; progress = 0
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
    }

    private func run() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            msg = "Micro refusé"; sub = "Autorise le micro pour Music dans Réglages."; return
        }
        busy = true
        defer { if !Task.isCancelled { busy = false; level = 0; progress = 0; try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio) } }
        for attempt in 0..<2 {
            msg = attempt == 0 ? "J'écoute…" : "J'écoute encore…"
            sub = "Approche le téléphone de la musique"
            guard let f = await record(seconds: 7), !Task.isCancelled else { return }
            msg = "Recherche…"; sub = ""
            do {
                var req = URLRequest(url: baseURL.appendingPathComponent("api/recognize"))
                req.httpMethod = "POST"
                req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                req.timeoutInterval = 40
                let (d, r) = try await API.shared.session.upload(for: req, fromFile: f)
                guard (r as? HTTPURLResponse)?.statusCode == 200, let j = JSON.parse(d) else { throw APIError(code: 0, message: "server") }
                if let t = track(j["track"]) {
                    result = t; msg = "Trouvé !"; sub = ""
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    past = [t] + past.filter { $0.id != t.id }
                    Store.set("recognized", Array(past.prefix(30)))
                    return
                }
                if let title = j["track"]["title"].string { msg = title; sub = j["track"]["artists"][0]["name"].string ?? ""; return }
            } catch {
                if Task.isCancelled { return }
                msg = "Reconnaissance indisponible"; sub = "Réessaie dans un instant."; return
            }
        }
        msg = "Rien trouvé"; sub = "Touche pour réessayer, plus près de la source."
    }

    private func record(seconds: Double) async -> URL? {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try? s.setActive(true)
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("listen.m4a")
        try? FileManager.default.removeItem(at: f)
        guard let rec = try? AVAudioRecorder(url: f, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96000]) else { return nil }
        rec.isMeteringEnabled = true
        rec.record()
        let t0 = Date()
        while Date().timeIntervalSince(t0) < seconds && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 60_000_000)
            rec.updateMeters()
            level = max(0, min(1, (rec.averagePower(forChannel: 0) + 50) / 50))
            progress = Date().timeIntervalSince(t0) / seconds
        }
        rec.stop()
        level = 0
        return Task.isCancelled ? nil : f
    }
}
