import AVFoundation

/// Plays the premade loop files (Resources/<mix id>.caf, built by tools/make_loops.py).
/// Each file is [pad: loop tail] + loop + [pad: loop head]; only the interior is scheduled, back to back,
/// so the codec's edge frames never sound and the wrap is the loop's own crossfaded seam.
/// Two players: choosing another mix crossfades instead of cutting.
final class LoopPlayer {
    static let rate: Double = 48_000
    static let pad: AVAudioFramePosition = 48_000          // tools/make_loops.py PAD (1 s) at 48 kHz
    static let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    static func url(_ id: String) -> URL? { Bundle.main.url(forResource: id, withExtension: "caf") }

    private let players = [AVAudioPlayerNode(), AVAudioPlayerNode()]
    private unowned let engine: AVAudioEngine
    private var stale: AVAudioFramePosition??   // set by a route change while paused: queue is gone, refill on next select
    private var current = 0
    private var ids: [String?] = [nil, nil]
    private var loopLen: [AVAudioFramePosition] = [0, 0]
    private var startOffset: [AVAudioFramePosition] = [0, 0]   // loop frame the player's timeline 0 maps to
    private var gens = [0, 0]                                  // bump → that player's pending reschedules stop
    private let lock = NSLock()
    private var level: [Float] = [0, 0]
    private var ramp: Timer?

    /// Volume for the current loop (master² · trim · not-on-break · playing). The other player eases to 0.
    var target: Float = 0 { didSet { kick() } }

    init(engine: AVAudioEngine) {
        self.engine = engine
        for p in players {
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: Self.format)
            p.volume = 0
        }
    }

    /// Make `id` the sounding loop: resume it if it is already current, else crossfade to it.
    /// Call with the engine running.
    func select(_ id: String) {
        guard engine.isRunning else { NSLog("Lull: engine not running, loop \(id) not started"); return }   // play() would throw
        if ids[current] == id, let pos = stale { stale = nil; recover(position: pos); return }
        if ids[current] == id {
            if !players[current].isPlaying { players[current].play() }
            kick(); return
        }
        stale = nil   // the new loop is scheduled fresh below
        let next = 1 - current
        halt(next)
        guard schedule(next, id: id, from: 0) else { return }
        players[next].play()
        current = next
        kick()
    }

    /// After a route change (headphones, AirPods) the engine restarts with the players emptied:
    /// reschedule the current loop from where it was.
    func recover(position: AVAudioFramePosition?) {
        guard let id = ids[current], engine.isRunning else { return }
        let i = current
        halt(1 - i)
        halt(i)
        _ = schedule(i, id: id, from: position ?? 0)
        level[i] = 0; players[i].volume = 0
        players[i].play()
        kick()
    }

    /// Route change while paused/stopped: remember where we were; the next select() reschedules from there.
    func markStale(position: AVAudioFramePosition?) { if ids[current] != nil { stale = .some(position) } }

    /// Selftest only: full volume now, no ramp (offline rendering has no run loop to drive it).
    func forceFull() -> AVAudioFramePosition {
        level[current] = 1; players[current].volume = 1
        return loopLen[current]
    }

    /// Selftest only: stop rescheduling without touching the player (offline, a stop() here would wait on a
    /// completion handler that is itself waiting for the next offline render: render once more, then stop).
    func freeze() { lock.lock(); gens[current] &+= 1; lock.unlock() }

    /// Where the current loop is, in loop frames (nil if it has never rendered).
    func position() -> AVAudioFramePosition? {
        let p = players[current]
        guard loopLen[current] > 0, let nt = p.lastRenderTime, let pt = p.playerTime(forNodeTime: nt) else { return nil }
        return (startOffset[current] + pt.sampleTime) % loopLen[current]
    }

    // MARK: scheduling

    private func halt(_ i: Int) {
        lock.lock(); gens[i] &+= 1; lock.unlock()   // first, so the handlers stop() fires are ignored
        players[i].stop()
        players[i].volume = 0; level[i] = 0
        ids[i] = nil
    }

    private func schedule(_ i: Int, id: String, from offset: AVAudioFramePosition) -> Bool {
        guard let url = Self.url(id), let f = try? AVAudioFile(forReading: url) else {
            NSLog("Lull: missing loop \(id)"); return false
        }
        let len = f.length - 2 * Self.pad
        guard len > 0 else { NSLog("Lull: loop \(id) too short"); return false }
        lock.lock(); gens[i] &+= 1; let g = gens[i]; lock.unlock()
        ids[i] = id; loopLen[i] = len
        let off = max(0, offset) % len
        startOffset[i] = off
        // Always one full loop queued behind the one playing.
        enqueue(i, g, url, start: Self.pad + off, count: len - off, full: len)
        enqueue(i, g, url, start: Self.pad, count: len, full: len)
        return true
    }

    private func enqueue(_ i: Int, _ g: Int, _ url: URL, start: AVAudioFramePosition, count: AVAudioFramePosition, full: AVAudioFramePosition) {
        guard let f = try? AVAudioFile(forReading: url) else { return }
        players[i].scheduleSegment(f, startingFrame: start, frameCount: AVAudioFrameCount(count), at: nil,
                                   completionCallbackType: .dataConsumed) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); let live = self.gens[i] == g; self.lock.unlock()
            if live { self.enqueue(i, g, url, start: Self.pad, count: full, full: full) }
        }
    }

    // MARK: volume

    /// Ease both players toward their targets at 60 Hz; the timer stops once everything has settled.
    private func kick() {
        guard ramp == nil else { return }
        let t = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)
        ramp = t
    }

    private func step() {
        let k: Float = 1 - expf(-(1 / 60) / 0.6)     // 0.6 s time constant, like the old fade
        var settled = true
        for i in 0..<2 {
            let goal: Float = i == current ? target : 0
            level[i] += (goal - level[i]) * k
            if abs(goal - level[i]) < 0.0005 { level[i] = goal } else { settled = false }
            players[i].volume = level[i]
            // Silent: the current loop pauses (keeps its place), the old one is released.
            if level[i] == 0 && goal == 0 {
                if i == current { if players[i].isPlaying { players[i].pause() } }
                else if ids[i] != nil { halt(i) }
            }
        }
        if settled { ramp?.invalidate(); ramp = nil }
    }
}

/// `--selftest` part: every bundled loop decodes through AVAudioFile (the app's path) with the right
/// format and length, the trailing pad decodes to the same audio as the loop head (alignment),
/// and the wrap step is no bigger than the steps the loop already contains.
enum LoopCheck {
    static func run() -> Bool {
        var ok = true
        let pad = LoopPlayer.pad
        for mix in Mix.all {
            guard let url = LoopPlayer.url(mix.id), let f = try? AVAudioFile(forReading: url) else {
                print("loop \(mix.id): MISSING"); ok = false; continue
            }
            let fmt = f.processingFormat
            let L = f.length - 2 * pad
            guard fmt.sampleRate == LoopPlayer.rate, fmt.channelCount == 2, L > 4 * pad else {
                print("loop \(mix.id): bad format \(fmt) length \(f.length)"); ok = false; continue
            }
            func read(_ at: AVAudioFramePosition, _ n: AVAudioFrameCount) -> [[Float]] {
                f.framePosition = at
                let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
                try? f.read(into: b, frameCount: n)
                return (0..<2).map { Array(UnsafeBufferPointer(start: b.floatChannelData![$0], count: Int(b.frameLength))) }
            }
            let n = AVAudioFrameCount(pad)
            let tail = read(pad + L - AVAudioFramePosition(n), n)   // last second of the loop
            let head = read(pad, n)                                // first second of the loop
            let copy = read(pad + L, n)                            // the same audio, encoded again in the trailing pad
            guard tail[0].count == Int(n), head[0].count == Int(n), copy[0].count == Int(n) else {
                print("loop \(mix.id): short read"); ok = false; continue
            }
            var steps: [Float] = []
            for c in 0..<2 { for i in 1..<tail[c].count { steps.append(abs(tail[c][i] - tail[c][i - 1])) } }
            steps.sort()
            let wrap = max(abs(head[0][0] - tail[0][tail[0].count - 1]), abs(head[1][0] - tail[1][tail[1].count - 1]))
            let pct = Double(steps.firstIndex { $0 >= wrap } ?? steps.count) / Double(steps.count) * 100
            var e = 0.0, s = 0.0
            for c in 0..<2 { for i in 0..<head[c].count { let d = Double(head[c][i] - copy[c][i]); e += d * d; s += Double(head[c][i] * head[c][i]) } }
            let rel = (e / max(s, 1e-12)).squareRoot()
            let bad = rel > 0.3 || wrap > steps[steps.count - 1] * 1.5
            if bad { ok = false }
            print(String(format: "loop %-10@ %7.1fs  wrap step pct=%5.1f  head vs pad err=%.4f %@",
                         mix.id as NSString, Double(L) / LoopPlayer.rate, pct, rel, bad ? "FAIL" : ""))
        }
        // The player itself, offline: two wraps (the third pass is queued from a completion handler).
        // Lossless loops, so every pass must equal the first to the sample: no gap, no drift.
        for id in ["sharp", "rain"] where !playerRun(id) { ok = false }
        return ok
    }

    /// The panel's Spectrum, fed real rendered audio, must put its two loudest columns on the given lines.
    private static func spectrumFinds(_ hz: [Double], in out: [[Float]]) -> Bool {
        let sp = Spectrum()
        let buf = AVAudioPCMBuffer(pcmFormat: LoopPlayer.format, frameCapacity: 4096)!
        buf.frameLength = 4096
        for c in 0..<2 { for i in 0..<4096 { buf.floatChannelData![c][i] = out[c][96_000 + i] } }
        sp.feed(buf)
        let v = sp.read()
        let top = v.indices.sorted { v[$0] > v[$1] }
        let want = hz.map { Int(logX($0) / 1 * Double(Spectrum.cols)) }      // logX spans the same 40–600 Hz
        let got = Array(top.prefix(4))
        let ok = want.allSatisfy { w in got.contains { abs($0 - w) <= 1 } }
        print("spectrum  sharp: loudest columns \(got.prefix(2).sorted()) want ~\(want) \(ok ? "" : "FAIL")")
        return ok
    }

    private static func playerRun(_ id: String) -> Bool {
        let eng = AVAudioEngine()
        do { try eng.enableManualRenderingMode(.offline, format: LoopPlayer.format, maximumFrameCount: 4096) }
        catch { print("player \(id): manual rendering unavailable: \(error)"); return false }
        let lp = LoopPlayer(engine: eng)
        do { try eng.start() } catch { print("player \(id): engine start: \(error)"); return false }
        lp.select(id)
        let L = Int(lp.forceFull())
        guard L > 0 else { print("player \(id): did not schedule"); return false }
        let n = 48_000, total = 2 * L + n
        var out = [[Float]](repeating: [Float](repeating: 0, count: total), count: 2)
        let buf = AVAudioPCMBuffer(pcmFormat: eng.manualRenderingFormat, frameCapacity: 4096)!
        var done = 0
        while done < total {
            let want = AVAudioFrameCount(min(4096, total - done))
            guard (try? eng.renderOffline(want, to: buf)) == .success else { print("player \(id): render failed at \(done)"); return false }
            for c in 0..<2 { let p = buf.floatChannelData![c]; for i in 0..<Int(buf.frameLength) { out[c][done + i] = p[i] } }
            done += Int(buf.frameLength)
        }
        var worst = 0.0, energy = 0.0
        for pass in 1...2 {
            var e = 0.0
            for c in 0..<2 { for i in 0..<n { let d = Double(out[c][pass * L + i] - out[c][i]); e += d * d; if pass == 1 { energy += Double(out[c][i] * out[c][i]) } } }
            worst = max(worst, (e / max(energy, 1e-12)).squareRoot())
        }
        let silent = energy < 1e-6
        if id == "sharp" && !spectrumFinds([133.8, 173.8], in: out) { print("spectrum: Sharp's lines not where they belong FAIL"); return false }
        let bad = silent || worst > 1e-4
        print(String(format: "player %-8@ 2 wraps rendered: pass vs pass err=%.6f %@", id as NSString, worst, silent ? "SILENT" : bad ? "FAIL" : ""))
        fflush(stdout)
        lp.freeze()
        for _ in 0..<4 { _ = try? eng.renderOffline(4096, to: buf) }   // lets an in-flight reschedule finish
        eng.stop()
        return !bad
    }
}
