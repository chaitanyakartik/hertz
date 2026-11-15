import SwiftUI
import WidgetKit

struct Entry: TimelineEntry {
    let date: Date
    let mode: Mode
    let playing: Bool
    let timerEnd: Date?
}

struct Provider: TimelineProvider {
    func current() -> Entry {
        let s = SharedState.load()
        return Entry(date: .now,
                     mode: Mode(rawValue: s?.mode ?? "") ?? .calm,
                     playing: s?.playing ?? false,
                     timerEnd: s?.timerEnd)
    }
    func placeholder(in context: Context) -> Entry { Entry(date: .now, mode: .calm, playing: true, timerEnd: nil) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(context.isPreview ? placeholder(in: context) : current()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let e = current()
        // The app reloads timelines on every change; the timer end is the only scheduled flip.
        if let end = e.timerEnd, e.playing, end > .now {
            completion(Timeline(entries: [e, Entry(date: end, mode: e.mode, playing: false, timerEnd: nil)], policy: .never))
        } else {
            completion(Timeline(entries: [e], policy: .never))
        }
    }
}

/// The binaural beat envelope, frozen: two tones interfering, as on the app's scope.
struct BeatWave: Shape {
    var cycles: Double = 9
    var humps: Double = 2
    var flat: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        let n = Int(r.width / 1.5)
        for k in 0...n {
            let x = Double(k) / Double(n)
            let taper = pow(sin(.pi * x), 0.35)
            let y = sin(2 * .pi * cycles * x) * cos(.pi * humps * x + 0.6) * taper * (flat ? 0.06 : 1)
            let pt = CGPoint(x: r.minX + x * r.width, y: r.midY - y * r.height / 2)
            k == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }
}

struct PlayDisc: View {
    let playing: Bool
    let color: Color
    var size: CGFloat = 34
    var body: some View {
        Image(systemName: playing ? "pause.fill" : "play.fill")
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(.black.opacity(0.82))
            .offset(x: playing ? 0 : size * 0.035)
            .frame(width: size, height: size)
            .background(Circle().fill(color))
            .widgetAccentable()
    }
}

struct Hero: View {
    let e: Entry
    var compact: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.mode.title)
                        .font(.system(size: compact ? 20 : 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("\(e.mode.beatLabel) \(e.mode.band)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                }
                Spacer(minLength: 4)
                PlayDisc(playing: e.playing, color: e.mode.glow)
            }
            Spacer(minLength: 6)
            BeatWave(flat: !e.playing)
                .stroke(e.mode.glow.opacity(e.playing ? 1 : 0.55), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .frame(height: compact ? 30 : 34)
                .widgetAccentable()
            Spacer(minLength: 6)
            Group {
                if let end = e.timerEnd, e.playing {
                    Label { Text(end, style: .timer).monospacedDigit() } icon: { Image(systemName: "timer") }
                } else {
                    Text(e.playing ? "Playing" : "Paused")
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
        }
    }
}

struct ModeChip: View {
    let mode: Mode
    let selected: Bool
    var body: some View {
        Link(destination: URL(string: "hertz://mode/\(mode.rawValue)")!) {
            HStack(spacing: 7) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? mode.glow : .white.opacity(0.55))
                    .frame(width: 16)
                Text(mode.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .white : .white.opacity(0.7))
                Spacer(minLength: 0)
                Text(mode.beatLabel)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(selected ? 0.7 : 0.4))
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? mode.glow.opacity(0.2) : .white.opacity(0.04)))
        }
    }
}

struct HertzWidgetView: View {
    let e: Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        Group {
            if family == .systemSmall {
                Hero(e: e, compact: true)
                    .widgetURL(URL(string: "hertz://toggle"))
            } else {
                HStack(spacing: 14) {
                    Link(destination: URL(string: "hertz://toggle")!) { Hero(e: e, compact: false) }
                    VStack(spacing: 4) {
                        ForEach(Mode.allCases) { ModeChip(mode: $0, selected: $0 == e.mode) }
                    }
                    .frame(width: 128)
                }
            }
        }
        .containerBackground(for: .widget) {
            ZStack {
                rgb(0x0D1015)
                RadialGradient(colors: [e.mode.glow.opacity(e.playing ? 0.28 : 0.12), .clear],
                               center: .init(x: 0.3, y: 1.1), startRadius: 4, endRadius: 220)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

struct HertzWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LullWidget"   /* kind kept: widgets already placed stay put */, provider: Provider()) { HertzWidgetView(e: $0) }
            .configurationDisplayName("Hertz")
            .description("Play, pause and switch focus modes.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct HertzWidgets: WidgetBundle {
    var body: some Widget { HertzWidget() }
}
