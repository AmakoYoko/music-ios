import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct NowEntry: TimelineEntry { let date: Date; let now: SharedNow.Now?; let art: UIImage? }

struct NowProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowEntry { NowEntry(date: .now, now: .init(title: "Music", artist: "En lecture", playing: false, live: false, id: ""), art: nil) }
    func getSnapshot(in context: Context, completion: @escaping (NowEntry) -> Void) { completion(entry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NowEntry>) -> Void) { completion(Timeline(entries: [entry()], policy: .never)) }
    private func entry() -> NowEntry {
        let art = SharedNow.artURL.flatMap { try? Data(contentsOf: $0) }.flatMap(UIImage.init(data:))
        return NowEntry(date: .now, now: SharedNow.read(), art: art)
    }
}

struct NowWidgetView: View {
    var e: NowEntry
    @Environment(\.widgetFamily) private var family
    let red = Color(red: 0.98, green: 0.18, blue: 0.28)
    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                Button(intent: TogglePlayIntent()) { Image(systemName: e.now?.playing == true ? "pause.fill" : "play.fill").font(.title2) }.buttonStyle(.plain)
            case .accessoryRectangular:
                VStack(alignment: .leading) {
                    Text(e.now?.title ?? "Music").font(.headline).lineLimit(1)
                    Text(e.now?.artist ?? "Rien en lecture").font(.caption).lineLimit(1)
                }
            case .systemSmall:
                VStack(alignment: .leading, spacing: 6) {
                    art.frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 10))
                    Spacer(minLength: 0)
                    Text(e.now?.title ?? "Music").font(.subheadline.bold()).lineLimit(2)
                    Text(e.now?.artist ?? "Rien en lecture").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                HStack(spacing: 14) {
                    art.frame(width: 110, height: 110).clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(e.now?.title ?? "Music").font(.headline).lineLimit(2)
                        Text(e.now?.artist ?? "Rien en lecture").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        HStack(spacing: 22) {
                            if e.now?.live != true { Button(intent: PrevTrackIntent()) { Image(systemName: "backward.fill") } }
                            Button(intent: TogglePlayIntent()) { Image(systemName: e.now?.playing == true ? "pause.fill" : "play.fill").font(.title2) }
                            if e.now?.live != true { Button(intent: NextTrackIntent()) { Image(systemName: "forward.fill") } }
                        }
                        .buttonStyle(.plain).foregroundStyle(red)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .containerBackground(for: .widget) { Color(.systemBackground) }
        .widgetURL(URL(string: "lamasmusic://now"))
    }
    @ViewBuilder var art: some View {
        if let a = e.art { Image(uiImage: a).resizable().scaledToFill() }
        else { LinearGradient(colors: [Color(red: 0.98, green: 0.36, blue: 0.45), red], startPoint: .top, endPoint: .bottom).overlay(Image(systemName: "music.note").font(.title).foregroundStyle(.white)) }
    }
}

struct NowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "now", provider: NowProvider()) { NowWidgetView(e: $0) }
            .configurationDisplayName("En lecture")
            .description("Le titre en cours et ses commandes.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

/// Activité en direct : écran verrouillé et Dynamic Island.
struct NowLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowAttributes.self) { ctx in
            HStack(spacing: 12) {
                ActArt(art: ctx.state.art, size: 54)
                VStack(alignment: .leading, spacing: 3) {
                    ActTitle(s: ctx.state)
                    ActProgress(s: ctx.state)
                }
                ActControls(s: ctx.state)
            }
            .padding(14)
            .activityBackgroundTint(Color.black.opacity(0.55))
            .activitySystemActionForegroundColor(.white)
            .foregroundStyle(.white)
            .widgetURL(URL(string: "lamasmusic://now"))
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { ActArt(art: ctx.state.art, size: 52) }
                DynamicIslandExpandedRegion(.center) { ActTitle(s: ctx.state) }
                DynamicIslandExpandedRegion(.trailing) { ActControls(s: ctx.state) }
                DynamicIslandExpandedRegion(.bottom) { ActProgress(s: ctx.state) }
            } compactLeading: {
                ActArt(art: ctx.state.art, size: 24)
            } compactTrailing: {
                Image(systemName: ctx.state.playing ? "waveform" : "pause.fill").foregroundStyle(lamasRed)
            } minimal: {
                ActArt(art: ctx.state.art, size: 22)
            }
            .widgetURL(URL(string: "lamasmusic://now"))
        }
    }
}
let lamasRed = Color(red: 0.98, green: 0.18, blue: 0.28)
struct ActArt: View {
    var art: String; var size: CGFloat
    var body: some View {
        Group {
            if !art.isEmpty, let d = SharedNow.smallArtURL.flatMap({ try? Data(contentsOf: $0) }), let i = UIImage(data: d) { Image(uiImage: i).resizable().scaledToFill() }
            else { lamasRed.overlay(Image(systemName: "music.note").foregroundStyle(.white)) }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size / 5))
    }
}
struct ActTitle: View {
    var s: NowAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(s.title).font(.headline).lineLimit(1)
            Text(s.artist).font(.subheadline).opacity(0.7).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct ActProgress: View {
    var s: NowAttributes.ContentState
    var body: some View {
        if s.live { Label("En direct", systemImage: "dot.radiowaves.left.and.right").font(.caption).foregroundStyle(lamasRed) }
        else if let st = s.start, s.dur > 0 { ProgressView(timerInterval: st...st.addingTimeInterval(s.dur), countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }.tint(lamasRed) }
        else if s.dur > 0 { ProgressView(value: min(s.pos, s.dur), total: s.dur).tint(lamasRed) }
    }
}
struct ActControls: View {
    var s: NowAttributes.ContentState
    var body: some View {
        HStack(spacing: 16) {
            Button(intent: TogglePlayIntent()) { Image(systemName: s.playing ? "pause.fill" : "play.fill").font(.title2) }
            if !s.live { Button(intent: NextTrackIntent()) { Image(systemName: "forward.fill").font(.title3) } }
        }
        .buttonStyle(.plain)
    }
}

@main struct MusicWidgets: WidgetBundle {
    var body: some Widget {
        NowWidget()
        NowLiveActivity()
    }
}
