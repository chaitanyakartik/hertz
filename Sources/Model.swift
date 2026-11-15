import AVFoundation
import MediaPlayer
import ServiceManagement
import SwiftUI
import WidgetKit

enum Noise: String, CaseIterable, Identifiable {
    case off, pink, brown, rain, waves, fire
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .off: "speaker.slash"
        case .pink: "waveform"
        case .brown: "waveform.path"
        case .rain: "cloud.rain"
        case .waves: "water.waves"
        case .fire: "flame"
        }
    }
}

enum Genre: String, CaseIterable, Identifiable {
    case none, ambient, piano, lofi, drone
    var id: String { rawValue }
    var title: String { self == .lofi ? "Lo-fi" : rawValue.capitalized }
}

/// Brain.fm-style "neural effect": how deeply the music and nature bed pulse at the mode's rate.
enum Effect: String, CaseIterable, Identifiable {
    case off, low, medium, high
    var id: String { rawValue }
    var title: String { self == .medium ? "Med" : rawValue.capitalized }
    var depth: Double { [0, 0.3, 0.55, 0.8][Effect.allCases.firstIndex(of: self)!] }
}

enum Delivery: String, CaseIterable, Identifiable {
    case binaural, isochronic
    var id: String { rawValue }
}

enum Session: String, CaseIterable, Identifiable {
    case infinite, timer, intervals
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

final class ToneEngine {
    let params = Params()
    private let engine = AVAudioEngine()
    private var dsp: DSP!
    private(set) var loops: LoopPlayer!
    let spectrum = Spectrum()
    private var stopWork: DispatchWorkItem?

    init() {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sr = rate > 0 ? rate : 48_000
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let dsp = DSP(params: params, sampleRate: sr)
        self.dsp = dsp
        let src = AVAudioSourceNode(format: fmt) { _, _, frames, abl in
            let bufs = UnsafeMutableAudioBufferListPointer(abl)
            guard bufs.count >= 2,
                  let l = bufs[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = bufs[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            dsp.render(l, r, Int(frames))
            return noErr
        }
        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: fmt)   // synth path: now only the interval chime
        loops = LoopPlayer(engine: engine)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [spectrum] buf, _ in spectrum.feed(buf) }
        engine.prepare()
        // Headphones plugged in / AirPods connect: the engine stops itself and the players lose their queue.
        // Restart and reschedule the loop from where it was, if we were playing.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            let pos = self.loops.position()
            guard self.params.run > 0 else { self.loops.markStale(position: pos); return }
            try? self.engine.start()
            self.loops.recover(position: pos)
        }
    }

    func start() {
        stopWork?.cancel()
        if !engine.isRunning { try? engine.start() }
        params.run = 1
    }

    func stop() {
        params.run = 0
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.params.run == 0 else { return }
            self.engine.pause()   // idle at 0% CPU once the fade-out is done
        }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }
}

final class Model: ObservableObject {
    private let d = UserDefaults.standard
    private let engine: ToneEngine?
    private var ticker: Timer?

    @Published var playing = false { didSet { if playing != oldValue { playingChanged() } } }
    @Published var mode: Mode { didSet { d.set(mode.rawValue, forKey: "mode"); apply(); publish() } }
    @Published var volume: Double { didSet { d.set(volume, forKey: "volume"); apply() } }
    @Published var genre: Genre { didSet { d.set(genre.rawValue, forKey: "genre"); apply() } }
    @Published var musicLevel: Double { didSet { d.set(musicLevel, forKey: "musicLevel"); apply() } }
    @Published var noise: Noise { didSet { d.set(noise.rawValue, forKey: "noise2"); apply() } }
    @Published var noiseLevel: Double { didSet { d.set(noiseLevel, forKey: "noiseLevel"); apply() } }
    @Published var effect: Effect { didSet { d.set(effect.rawValue, forKey: "effect"); apply() } }
    @Published var tone: Double { didSet { d.set(tone, forKey: "tone2"); apply() } }
    @Published var delivery: Delivery { didSet { d.set(delivery.rawValue, forKey: "delivery"); apply() } }
    @Published var session: Session { didSet { d.set(session.rawValue, forKey: "session"); restartSession() } }
    @Published var timerMinutes: Int { didSet { d.set(timerMinutes, forKey: "timer2"); restartSession() } }
    @Published var workMinutes: Int { didSet { d.set(workMinutes, forKey: "work"); restartSession() } }

    @Published var mix: Mix { didSet { d.set(mix.id, forKey: "mix"); applyMix(); nowPlaying() } }
    @Published var category: Category { didSet { d.set(category.rawValue, forKey: "category") } }
    @Published var playFor: PlayFor { didSet { d.set(playFor.rawValue, forKey: "playFor"); applyPlayFor() } }

    // live session state
    @Published var startedAt: Date?
    @Published var phaseStart: Date?
    @Published var phaseEnd: Date?
    @Published var onBreak = false
    @Published var round = 1

    var breakMinutes: Int { max(1, workMinutes / 5) }
    var timerEnd: Date? { session == .infinite ? nil : phaseEnd }

    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do { launchAtLogin ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { NSLog("Lull: login item: \(error)"); DispatchQueue.main.async { self.launchAtLogin = SMAppService.mainApp.status == .enabled } }
        }
    }

    /// The live spectrum for the panel's display (nil in previews: the panel falls back to the loop's measured lines).
    var spectrum: Spectrum? { engine?.spectrum }

    /// Fired whenever play state changes, so the menu bar icon can follow.
    var onPlayingChange: ((Bool) -> Void)?

    init(preview: Bool = false) {
        engine = preview ? nil : ToneEngine()
        mode = Mode(rawValue: d.string(forKey: "mode") ?? "") ?? .calm
        volume = d.object(forKey: "volume") as? Double ?? 0.7
        genre = Genre(rawValue: d.string(forKey: "genre") ?? "") ?? .ambient
        musicLevel = d.object(forKey: "musicLevel") as? Double ?? 0.65
        noise = Noise(rawValue: d.string(forKey: "noise2") ?? "") ?? .rain
        noiseLevel = d.object(forKey: "noiseLevel") as? Double ?? 0.35
        effect = Effect(rawValue: d.string(forKey: "effect") ?? "") ?? .medium
        tone = d.object(forKey: "tone2") as? Double ?? 0.2
        delivery = Delivery(rawValue: d.string(forKey: "delivery") ?? "") ?? .binaural
        session = Session(rawValue: d.string(forKey: "session") ?? "") ?? .infinite
        timerMinutes = d.object(forKey: "timer2") as? Int ?? 45
        workMinutes = d.object(forKey: "work") as? Int ?? 25
        let savedMix = Mix.find(d.string(forKey: "mix") ?? "") ?? Mix.all[0]
        mix = savedMix
        category = Category(rawValue: d.string(forKey: "category") ?? "") ?? savedMix.category
        playFor = PlayFor(rawValue: d.string(forKey: "playFor") ?? "") ?? .untilStop
        applyMix()
        applyPlayFor()
        apply()
        publish()
        if !preview { remoteCommands() }
    }

    func toggle() { playing.toggle() }

    /// The keyboard's play/pause key (and AirPods, Control Centre) go to the "Now Playing" app; register as one.
    private func remoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        func on(_ cmd: MPRemoteCommand, _ f: @escaping () -> Void) {
            cmd.isEnabled = true
            cmd.addTarget { _ in DispatchQueue.main.async(execute: f); return .success }
        }
        on(c.togglePlayPauseCommand) { [weak self] in self?.toggle() }
        on(c.playCommand) { [weak self] in self?.playing = true }
        on(c.pauseCommand) { [weak self] in self?.playing = false }
        on(c.stopCommand) { [weak self] in self?.playing = false }
        nowPlaying()
    }

    private func nowPlaying() {
        guard engine != nil else { return }
        let info = MPNowPlayingInfoCenter.default()
        info.nowPlayingInfo = [MPMediaItemPropertyTitle: mix.name, MPMediaItemPropertyArtist: "Lull",
                               MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0]
        info.playbackState = playing ? .playing : .paused
    }

    /// Choosing a mix sets every sound parameter and starts playing.
    func choose(_ x: Mix) {
        let fresh = x != mix
        if fresh { mix = x }
        if !playing { playing = true }
        else if fresh { engine?.params.session &+= 1 }   // new key for the new mix
    }

    /// Mixes are recorded loops now: the synth layers stay silent (it only rings the interval chime).
    private func applyMix() {
        mode = mix.mode
        genre = .none
        musicLevel = 0
        noise = .off
        noiseLevel = 0
        effect = .off
        tone = 0
        delivery = .binaural
        updateLoop()
    }

    /// The loop player follows play state, the chosen mix, volume and interval breaks.
    private func updateLoop() {
        guard let loops = engine?.loops else { return }
        if playing && !onBreak { loops.select(mix.id) }
        loops.target = playing && !onBreak ? Float(volume * volume * mix.gain) : 0
    }

    private func applyPlayFor() {
        switch playFor {
        case .untilStop: session = .infinite
        case .min25: timerMinutes = 25; session = .timer
        case .min45: timerMinutes = 45; session = .timer
        case .min90: timerMinutes = 90; session = .timer
        case .pomo25: workMinutes = 25; session = .intervals
        case .pomo50: workMinutes = 50; session = .intervals
        }
    }

    private func publish() {
        guard engine != nil else { return }   // previews don't touch the widget
        SharedState(mode: mode.rawValue, playing: playing, timerEnd: timerEnd).save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func apply() {
        guard let p = engine?.params else { return }
        p.beat = Float(mode.beat)
        p.carrier = Float(mode.carrier)
        p.tempo = Float(mode.tempo)
        p.density = Float(mode.density)
        p.bright = Float(mode.bright)
        p.dark = mode.dark ? 1 : 0
        p.tone = Float(tone)
        p.noise = Float(noiseLevel)
        p.music = Float(musicLevel)
        p.master = Float(volume)
        p.noiseType = Int32(Noise.allCases.firstIndex(of: noise)!)
        p.genre = Int32(Genre.allCases.firstIndex(of: genre)!)
        p.depth = Float(effect.depth)
        p.iso = delivery == .isochronic ? 1 : 0
        updateLoop()
    }

    private func playingChanged() {
        if playing {
            engine?.params.session &+= 1      // fresh key and chord progression each time you press play
            engine?.start()
        } else {
            engine?.stop()
        }
        restartSession()
        nowPlaying()
        onPlayingChange?(playing)
    }

    /// (Re)starts the clock for the chosen session type. Called on play and when session settings change.
    private func restartSession() {
        ticker?.invalidate(); ticker = nil
        onBreak = false
        round = 1
        engine?.params.duck = 1
        updateLoop()
        guard playing else { startedAt = nil; phaseStart = nil; phaseEnd = nil; publish(); return }
        let now = Date()
        startedAt = now
        phaseStart = now
        switch session {
        case .infinite: phaseEnd = nil
        case .timer: phaseEnd = now.addingTimeInterval(Double(timerMinutes) * 60)
        case .intervals: phaseEnd = now.addingTimeInterval(Double(workMinutes) * 60)
        }
        publish()
        guard session != .infinite else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        guard let end = phaseEnd, Date() >= end else { return }
        if session == .timer { playing = false; return }
        // intervals: work → break → work …, a chime at each turn, music fades out for the break
        let now = Date()
        onBreak.toggle()
        if !onBreak { round += 1 }
        phaseStart = now
        phaseEnd = now.addingTimeInterval(Double(onBreak ? breakMinutes : workMinutes) * 60)
        engine?.params.duck = onBreak ? 0 : 1
        engine?.params.chime &+= 1
        updateLoop()
        publish()
    }

    /// lull://toggle, lull://play, lull://stop, lull://mode/<name>
    func handle(_ url: URL) {
        switch url.host {
        case "toggle": toggle()
        case "play": playing = true
        case "stop", "pause": playing = false
        case "mix":
            if let x = Mix.find(url.lastPathComponent.lowercased()) { choose(x) }
        case "mode":   // first mix in that mode
            if let m = Mode(rawValue: url.lastPathComponent.lowercased()), let x = Mix.all.first(where: { $0.mode == m }) { choose(x) }
        default: break
        }
    }
}

enum Category: String, CaseIterable, Identifiable {
    case focus, relax, sleep
    var id: String { rawValue }
    var title: String { self == .focus ? "Full Focus" : rawValue.capitalized }
}

/// Premade mixes: the only sound choice the panel offers. Each is a recorded loop, Resources/<id>.caf,
/// built by tools/make_loops.py (sources, loop points and seam checks in audio/loops/report.json).
struct Mix: Identifiable, Equatable {
    let id: String          // also the loop file name
    let name: String
    let symbol: String
    let category: Category
    let mode: Mode          // colours and the scope's rhythm
    let detail: String
    /// Trim, 0...1. Files are baked to -18 LUFS unless their peaks cap the boost (Sharp: -12 with 0.5 here).
    var gain: Double = 1
    var headphones = false  // binaural: each ear gets its own tone

    static let builtin: [Mix] = [
        // generated (tools/make_loops.py): pure 134 Hz left / 174 Hz right, a 40 Hz difference
        Mix(id: "sharp", name: "Sharp", symbol: "scope", category: .focus, mode: .focus,
            detail: "40 Hz binaural · 134 / 174 Hz", gain: 0.5, headphones: true),   // file baked at -12 LUFS
        // generated: 1/f² noise, synthesised as one period so it loops with no seam
        Mix(id: "brown", name: "Brown Noise", symbol: "waveform.path", category: .focus, mode: .flow,
            detail: "Deep, even noise"),
        // CC0: "Chill lofi inspired" by omfgdude (OpenGameArt), its end fading into its start
        Mix(id: "lofi", name: "Lofi", symbol: "headphones", category: .relax, mode: .calm,
            detail: "Chill lofi · omfgdude"),
        // CC0: "It's Pouring" by SpringySpringo (OpenGameArt), a steady 52 s stretch of the downpour
        Mix(id: "rain", name: "Rain", symbol: "cloud.rain", category: .sleep, mode: .sleep,
            detail: "Steady downpour"),
        // generated: 1/f noise, one period
        Mix(id: "pink", name: "Pink Noise", symbol: "waveform", category: .sleep, mode: .sleep,
            detail: "Soft, even noise"),
    ]
    static let all: [Mix] = builtin + personal
    /// Rows in the panel's list: the fullest tab, at least three.
    static let slots = max(3, Category.allCases.map { c in all.filter { $0.category == c }.count }.max() ?? 0)
    static func find(_ id: String) -> Mix? { all.first { $0.id == id } }
}

/// The one "how long" menu: replaces the session controls.
enum PlayFor: String, CaseIterable, Identifiable {
    case untilStop, min25, min45, min90, pomo25, pomo50
    var id: String { rawValue }
    var title: String {
        switch self {
        case .untilStop: "Until I stop"
        case .min25: "25 minutes"
        case .min45: "45 minutes"
        case .min90: "90 minutes"
        case .pomo25: "Pomodoro 25 / 5"
        case .pomo50: "Pomodoro 50 / 10"
        }
    }
}
