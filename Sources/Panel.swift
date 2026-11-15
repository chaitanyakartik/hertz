import SwiftUI

// Glyph: a dot-matrix panel.
// THESIS: the panel is a black-glass dot-matrix display, not a utility window: one glance shows what is
//   playing, how the round is going, and the sound itself.
// OWN-WORLD: true-black ground, white lit dots, #242424 unlit dots, one red dot for "now"; the 5×7 dot
//   font is the display voice, SF for everything you read small.
// STORY: open, see the playing loop and the time left, tap a row, close. Nothing pulls back while working.
// FIRST VIEWPORT: status + dot clock; the loop's name in dots; its live spectrum (40–600 Hz) as dot
//   columns with the round's clock as the bottom row; play + volume dots; tabs; rows; play-for.

enum G {
    static let ground = rgb(0x070707), white = rgb(0xEDEDED), dim = rgb(0x242424), red = rgb(0xD71921), grey = rgb(0x8C8C8C)
}

struct PanelView: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            VStack(alignment: .leading, spacing: 10) {
                let name = m.mix.name.uppercased()
                DotText(text: name, cell: min(7, DotText.fit(name, 304)), color: G.white, off: G.dim)
                    .id(m.mix.id)
                    .transition(.opacity)
                Text(m.mix.detail).font(.system(size: 12)).foregroundStyle(G.grey)
            }
            .animation(.easeOut(duration: 0.25), value: m.mix.id)
            GlyphDisplay(m: m).frame(height: 304 / 48 * 10)
            HStack(spacing: 14) {
                PlayDot(playing: m.playing) { m.toggle() }
                VolumeDots(value: $m.volume)
            }
            Tabs(selection: $m.category)
            // As many slots as the fullest tab (at least three), so switching tabs never resizes the panel.
            let list = Mix.all.filter { $0.category == m.category }
            VStack(spacing: 0) {
                ForEach(0..<Mix.slots, id: \.self) { i in
                    if i < list.count {
                        let x = list[i]
                        MixRow(mix: x, current: m.mix == x, playing: m.playing && m.mix == x) {
                            withAnimation(.easeOut(duration: 0.25)) { m.choose(x) }
                        }
                    } else {
                        MixRow(mix: Mix.all[0], current: false, playing: false) {}
                            .hidden()
                            .accessibilityHidden(true)
                    }
                }
            }
            playFor
            footer
        }
        .padding(16)
        .frame(width: 336)
        .background(G.ground)
        .environment(\.colorScheme, .dark)
    }

    // MARK: header: status on the left, the clock in dots on the right

    private var header: some View {
        HStack(alignment: .center, spacing: 7) {
            Circle().fill(statusDot).frame(width: 8, height: 8)
            Text(statusText).font(.system(size: 11, weight: .medium)).tracking(1.6).foregroundStyle(G.grey).lineLimit(1)
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                DotText(text: clock(tl.date), cell: 3.4, color: m.playing ? G.white : G.dim)
            }
        }
    }

    private var statusDot: Color {
        if !m.playing { return G.dim }
        return m.onBreak ? G.white : G.red
    }

    private var statusText: String {
        if !m.playing { return "PAUSED" }
        if m.session == .intervals { return m.onBreak ? "BREAK · STRETCH, LOOK AWAY" : "PLAYING · ROUND \(m.round)" }
        return m.mix.headphones ? "PLAYING · HEADPHONES" : "PLAYING"
    }

    private func clock(_ now: Date) -> String {
        guard m.playing else { return "--:--" }
        let secs: TimeInterval
        if let end = m.phaseEnd { secs = end.timeIntervalSince(now) }
        else if let start = m.startedAt { secs = now.timeIntervalSince(start) }
        else { return "--:--" }
        let s = max(0, Int(secs))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: play for + footer

    private var playFor: some View {
        HStack(spacing: 8) {
            Text("PLAY FOR").font(.system(size: 11, weight: .medium)).tracking(1.6).foregroundStyle(G.grey)
            Menu {
                ForEach(PlayFor.allCases) { p in Button(p.title) { m.playFor = p } }
            } label: {
                Text(m.playFor.title).font(.system(size: 13, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .tint(G.white)
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Button { m.launchAtLogin.toggle() } label: {
                HStack(spacing: 7) {
                    Circle().fill(m.launchAtLogin ? G.white : G.dim).frame(width: 7, height: 7)
                    Text("Open at login")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(m.launchAtLogin ? "on" : "off")
            Spacer()
            Button("Quit Hertz") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .keyboardShortcut("q")
        }
        .font(.system(size: 12))
        .foregroundStyle(G.grey)
    }
}

// MARK: - the display

/// Per-frame easing state, so columns settle instead of flicker (calm while working).
private final class GlyphState {
    var level = [Double](repeating: 0, count: Spectrum.cols)
    var last: Double = 0
}

/// The loop's live spectrum (40–600 Hz, log) as lit dot columns; the bottom row is the round's clock
/// (white = done, red = now). In previews it shows the loop's measured lines instead.
struct GlyphDisplay: View {
    @ObservedObject var m: Model
    @State private var st = GlyphState()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !m.playing && st.level.allSatisfy { $0 < 0.01 })) { tl in
            Canvas { ctx, sz in draw(ctx, sz, t: tl.date) }
        }
        .accessibilityElement()
        .accessibilityLabel("Sound display")
        .accessibilityValue(m.playing ? "\(m.mix.name) playing" : "paused")
    }

    private func targets() -> [Double] {
        if let sp = m.spectrum { return sp.read().map(Double.init) }
        var lv = [Double](repeating: 0, count: Spectrum.cols)       // preview: the loop's measured peaks
        for (hz, a) in loopLines[m.mix.id] ?? [] {
            let c = logX(hz) * Double(Spectrum.cols - 1)
            for i in 0..<Spectrum.cols { lv[i] = max(lv[i], a * exp(-pow(Double(i) - c, 2) / 2.2)) }
        }
        return lv
    }

    private func progress(_ now: Date) -> Double? {
        guard m.playing else { return nil }
        if let s = m.phaseStart, let e = m.phaseEnd { return min(1, max(0, now.timeIntervalSince(s) / e.timeIntervalSince(s))) }
        if let s = m.startedAt { return now.timeIntervalSince(s).truncatingRemainder(dividingBy: 3600) / 3600 }   // until-stop: the hour
        return nil
    }

    private func draw(_ ctx: GraphicsContext, _ sz: CGSize, t: Date) {
        let now = t.timeIntervalSinceReferenceDate
        let dt = st.last == 0 ? 1 : min(0.2, now - st.last)
        st.last = now
        let goal = m.playing ? targets() : [Double](repeating: 0, count: Spectrum.cols)
        let up = 1 - exp(-dt / 0.12), down = 1 - exp(-dt / 0.45)       // quick to rise, slow to fall
        for i in 0..<Spectrum.cols { st.level[i] += (goal[i] - st.level[i]) * (goal[i] > st.level[i] ? up : down) }

        let cols = Spectrum.cols, rows = 10, cell = sz.width / CGFloat(cols), d = cell * 0.7, o = cell * 0.15
        func dot(_ x: Int, _ y: Int, _ c: Color) {
            ctx.fill(Path(ellipseIn: CGRect(x: CGFloat(x) * cell + o, y: CGFloat(y) * cell + o, width: d, height: d)), with: .color(c))
        }
        let bars = rows - 2
        for x in 0..<cols {
            let lit = Int((st.level[x] * Double(bars)).rounded())
            for y in 0..<bars { dot(x, y, (bars - 1 - y) < lit ? G.white : G.dim) }
        }
        let at = progress(t).map { min(cols - 1, Int($0 * Double(cols))) }
        let timed = m.phaseEnd != nil
        for x in 0..<cols {
            let c: Color = x == at ? G.red : (timed && at != nil && x < at!) ? G.white : G.dim
            dot(x, rows - 1, c)
        }
    }
}

// MARK: - controls

private struct PlayDot: View {
    let playing: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(G.white)
                if playing {
                    HStack(spacing: 5) { ForEach(0..<2) { _ in Rectangle().fill(G.ground).frame(width: 4.5, height: 16) } }
                } else {
                    Path { p in p.move(to: .init(x: 0, y: 0)); p.addLine(to: .init(x: 15, y: 9)); p.addLine(to: .init(x: 0, y: 18)); p.closeSubpath() }
                        .fill(G.ground).frame(width: 15, height: 18).offset(x: 2)
                }
            }
            .frame(width: 48, height: 48)
            .scaleEffect(hover ? 1.04 : 1)
            .animation(.easeOut(duration: 0.15), value: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .keyboardShortcut(.space, modifiers: [])
        .help(playing ? "Pause (Space)" : "Play (Space)")
        .accessibilityLabel(playing ? "Pause" : "Play")
    }
}

/// 20 dots; click or drag anywhere on the row to set the level.
private struct VolumeDots: View {
    @Binding var value: Double
    private let n = 20

    var body: some View {
        GeometryReader { g in
            Canvas { ctx, sz in
                let cell = sz.width / CGFloat(n)
                for i in 0..<n {
                    let r = CGRect(x: CGFloat(i) * cell + cell * 0.2, y: (sz.height - cell * 0.6) / 2, width: cell * 0.6, height: cell * 0.6)
                    ctx.fill(Path(ellipseIn: r), with: .color(Double(i) < (value * Double(n)).rounded() ? G.white : G.dim))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                value = min(1, max(0, Double(v.location.x / g.size.width)))
            })
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { dir in
            value = min(1, max(0, value + (dir == .increment ? 0.05 : -0.05)))
        }
    }
}

private struct Tabs: View {
    @Binding var selection: Category

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Category.allCases) { c in
                let on = c == selection
                Button { withAnimation(.easeOut(duration: 0.2)) { selection = c } } label: {
                    Text(c.title).font(.system(size: 12, weight: .semibold))
                        .frame(width: 96).padding(.vertical, 7)          // 3 × 96 + 2 × 4 gaps + 2 × 3 inset = 302
                        .foregroundStyle(on ? G.ground : G.grey)
                        .background(Capsule().fill(on ? G.white : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .overlay(Capsule().inset(by: 0.5).stroke(G.dim, lineWidth: 1))
    }
}

private struct MixRow: View {
    let mix: Mix
    let current: Bool
    let playing: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle().fill(playing ? G.red : current ? G.white : G.dim).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mix.name).font(.system(size: 14, weight: current ? .semibold : .regular))
                        .foregroundStyle(current || hover ? G.white : G.white.opacity(0.75))
                    Text(mix.detail).font(.system(size: 11)).foregroundStyle(G.grey)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
