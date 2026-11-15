import SwiftUI

/// Animation derrière le lecteur plein écran, aux couleurs de la pochette ; peut suivre les basses et les attaques.
enum Visual {
    static let styles = [("off", "Désactivé"), ("aurora", "Aurore"), ("halo", "Halo"), ("silk", "Soie"), ("glow", "Lumières")]
    static let modes = ["aurora": 0.0, "halo": 1, "silk": 2, "glow": 3]
}

struct VisualView: View {
    var colors: [Color]
    var playing: Bool
    var style = Store.get("vis-style", "off")
    var react = Store.get("vis-react", false)
    @State private var start = Date()
    var body: some View {
        let mode = Visual.modes[style] ?? 0
        let c = colors.count >= 3 ? colors + [colors[1]] : [Color(white: 0.2), Color(hue: 0.75, saturation: 0.5, brightness: 0.6), Color(hue: 0.58, saturation: 0.6, brightness: 0.6), Color(hue: 0.95, saturation: 0.5, brightness: 0.6)]
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing)) { tl in
            GeometryReader { g in
                let lv = react ? AudioEngine.shared.levels : (0, 0, 0, 0)
                Rectangle()
                    .colorEffect(ShaderLibrary.visual(.float2(g.size), .float(tl.date.timeIntervalSince(start)), .float(mode),
                                                      .color(c[0]), .color(c[1]), .color(c[2]), .color(c[3]),
                                                      .float(lv.0), .float(lv.1), .float(lv.2), .float(lv.3)))
            }
        }
        .onAppear { AudioEngine.shared.analysing = react }
        .onDisappear { AudioEngine.shared.analysing = false }
    }
}
