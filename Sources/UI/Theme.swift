import CryptoKit
import SwiftUI
import UIKit

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .alphanumerics.inverted)
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt64(s, radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
    static let accent = Color(hex: "#fa2d48")
}

/// Images du serveur (pochettes relayées par /api/img, avec la session) et d'ailleurs, en mémoire et sur disque.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let mem = NSCache<NSURL, UIImage>()
    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("img")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    init() { mem.countLimit = 400 }

    func cached(_ u: URL) -> UIImage? { mem.object(forKey: u as NSURL) }

    func image(_ u: URL) async -> UIImage? {
        if let i = mem.object(forKey: u as NSURL) { return i }
        let f = dir.appendingPathComponent(Insecure.SHA1.hash(data: Data(u.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined())
        if let d = try? Data(contentsOf: f), let i = UIImage(data: d) { mem.setObject(i, forKey: u as NSURL); return i }
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 800_000_000) }
            guard let (d, r) = try? await API.shared.session.data(from: u), (r as? HTTPURLResponse)?.statusCode == 200, let i = UIImage(data: d) else { continue }
            let small = i.preparingThumbnail(of: CGSize(width: min(i.size.width, 900), height: min(i.size.height, 900) * i.size.height / max(i.size.width, 1))) ?? i
            mem.setObject(small, forKey: u as NSURL)
            try? d.write(to: f)
            return small
        }
        return nil
    }

    /// Trois couleurs d'ambiance tirées de la pochette (fond du lecteur plein écran).
    func palette(_ i: UIImage) -> [Color] {
        guard let cg = i.cgImage else { return [] }
        let n = 12
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        func zone(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ k: Double) -> Color {
            var r = 0.0, g = 0.0, b = 0.0, c = 0.0
            for y in y0..<y1 { for x in x0..<x1 { let o = (y * n + x) * 4; r += Double(px[o]); g += Double(px[o + 1]); b += Double(px[o + 2]); c += 1 } }
            return Color(red: r / c / 255 * k, green: g / c / 255 * k, blue: b / c / 255 * k)
        }
        return [zone(0, 0, 12, 12, 0.7), zone(0, 0, 6, 6, 0.95), zone(6, 6, 12, 12, 0.6)]
    }

    func clear() { mem.removeAllObjects(); try? FileManager.default.removeItem(at: dir); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
}

struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @State private var img: UIImage?
    var body: some View {
        ZStack {
            if let img { Image(uiImage: img).resizable().aspectRatio(contentMode: contentMode) }
            else { Color(.secondarySystemFill).overlay(Image(systemName: "music.note").foregroundStyle(.tertiary)) }
        }
        .task(id: url) {
            guard let url else { img = nil; return }
            if let c = ImageCache.shared.cached(url) { img = c; return }
            img = await ImageCache.shared.image(url)
        }
    }
}

extension View {
    func cardShape(_ r: CGFloat = 8) -> some View { clipShape(RoundedRectangle(cornerRadius: r, style: .continuous)) }
    @ViewBuilder func `if`<V: View>(_ c: Bool, _ f: (Self) -> V) -> some View { if c { f(self) } else { self } }
}

/// Indicateur « en lecture » (trois barres animées).
struct EqBars: View {
    var playing: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !playing)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3) { i in
                    Capsule().fill(Color.accent)
                        .frame(width: 3, height: playing ? 4 + 10 * abs(sin(t * (3 + Double(i)) + Double(i))) : 4)
                }
            }
            .frame(width: 16, height: 14, alignment: .bottom)
        }
    }
}
