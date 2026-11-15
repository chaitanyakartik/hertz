import Foundation

// Generative music for Hertz: a small wavetable synth, a step sequencer that composes in a random key,
// percussion for lo-fi, and an 8-line FDN reverb. Runs on the audio thread, allocation-free after init.

struct Rand {
    var s: UInt32
    @inline(__always) mutating func next() -> UInt32 { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return s }
    @inline(__always) mutating func unit() -> Float { Float(next() >> 8) / Float(1 << 24) }
    @inline(__always) mutating func bi() -> Float { unit() * 2 - 1 }
    @inline(__always) mutating func chance(_ p: Float) -> Bool { unit() < p }
    mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt32(a.count))] }
}

final class Tables {
    static let size = 2048
    static let shared = Tables()
    let sine: UnsafeMutablePointer<Float>
    let warm: UnsafeMutablePointer<Float>   // soft saw for pads
    let keys: UnsafeMutablePointer<Float>   // electric-piano-ish

    private init() {
        func make(_ harmonics: Int, _ amp: (Int) -> Float) -> UnsafeMutablePointer<Float> {
            let n = Tables.size
            let t = UnsafeMutablePointer<Float>.allocate(capacity: n + 1)
            t.initialize(repeating: 0, count: n + 1)
            for h in 1...harmonics {
                let a = amp(h)
                for i in 0...n { t[i] += a * sinf(2 * .pi * Float(h * i) / Float(n)) }
            }
            var peak: Float = 0
            for i in 0...n { peak = max(peak, abs(t[i])) }
            for i in 0...n { t[i] /= peak }
            return t
        }
        sine = make(1) { _ in 1 }
        warm = make(18) { h in expf(-Float(h) / 7) / Float(h) }
        keys = make(10) { h in [1, 0.42, 0.22, 0.12, 0.09, 0.05, 0.035, 0.02, 0.012, 0.008][h - 1] }
    }

    @inline(__always) static func read(_ t: UnsafeMutablePointer<Float>, _ ph: Float) -> Float {
        let x = ph * Float(size)
        let i = Int(x)
        let f = x - Float(i)
        return t[i] + f * (t[i + 1] - t[i])
    }
}

enum Kind: UInt8 { case tone, kick, snare, hat, pop }

struct Voice {
    var on = false
    var kind: Kind = .tone
    var table: UInt8 = 0       // 0 sine, 1 warm, 2 keys
    var chime = false          // routed past the break duck
    var wait = 0
    var ph1: Float = 0, ph2: Float = 0, inc: Float = 0
    var ratio2: Float = 1, g2: Float = 0, g2k: Float = 1, table2Sine = false
    var env: Float = 0, stage: UInt8 = 0
    var aInc: Float = 1, sus: Float = 1, dK: Float = 0, rK: Float = 0.999
    var hold = 0
    var vel: Float = 1
    var pl: Float = 0.7, pr: Float = 0.7
    var lp1: Float = 0, lp2: Float = 0, cut: Float = 0.2, cutEnd: Float = 0.2, cutK: Float = 0
    var pe: Float = 1, peK: Float = 1      // kick pitch envelope
}

/// 8 delay lines, Hadamard feedback, damped. Adds `wet` × reverb to the buffers in place.
final class Reverb {
    private let buf: UnsafeMutablePointer<Float>       // all 8 lines, back to back
    private let start = UnsafeMutablePointer<Int>.allocate(capacity: 8)
    private let len = UnsafeMutablePointer<Int>.allocate(capacity: 8)
    private let idx = UnsafeMutablePointer<Int>.allocate(capacity: 8)
    private let damp = UnsafeMutablePointer<Float>.allocate(capacity: 8)
    private let y = UnsafeMutablePointer<Float>.allocate(capacity: 8)
    private let sr: Float
    private var g: Float = 0.9
    private let dampK: Float
    private var avgLen: Float = 0
    var decay: Float = 3.5 { didSet { if decay != oldValue { g = powf(10, -3 * avgLen / (sr * decay)) } } }

    init(sr: Float) {
        self.sr = sr
        let base = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
        var total = 0
        for (k, b) in base.enumerated() {
            let n = Int(Float(b) * sr / 44_100 * 1.6)
            start[k] = total; len[k] = n; idx[k] = 0; damp[k] = 0
            total += n
        }
        buf = UnsafeMutablePointer<Float>.allocate(capacity: total)
        buf.initialize(repeating: 0, count: total)
        avgLen = Float(total) / 8
        dampK = 1 - expf(-2 * .pi * 5200 / sr)
        g = powf(10, -3 * avgLen / (sr * decay))
    }

    func process(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ n: Int, wet: Float) {
        let s8: Float = 0.35355339
        for i in 0..<n {
            let x = (L[i] + R[i]) * 0.5
            for k in 0..<8 {
                let v = buf[start[k] + idx[k]]
                damp[k] += (v - damp[k]) * dampK
                y[k] = damp[k]
            }
            let a0 = y[0] + y[1], a1 = y[0] - y[1], a2 = y[2] + y[3], a3 = y[2] - y[3]
            let a4 = y[4] + y[5], a5 = y[4] - y[5], a6 = y[6] + y[7], a7 = y[6] - y[7]
            let b0 = a0 + a2, b1 = a1 + a3, b2 = a0 - a2, b3 = a1 - a3
            let b4 = a4 + a6, b5 = a5 + a7, b6 = a4 - a6, b7 = a5 - a7
            let gx = g * s8
            write(0, x + gx * (b0 + b4)); write(1, x + gx * (b1 + b5))
            write(2, x + gx * (b2 + b6)); write(3, x + gx * (b3 + b7))
            write(4, x + gx * (b0 - b4)); write(5, x + gx * (b1 - b5))
            write(6, x + gx * (b2 - b6)); write(7, x + gx * (b3 - b7))
            L[i] += wet * (y[0] + y[2] + y[4] + y[6]) * 0.3
            R[i] += wet * (y[1] + y[3] + y[5] + y[7]) * 0.3
        }
    }

    @inline(__always) private func write(_ k: Int, _ v: Float) {
        buf[start[k] + idx[k]] = v
        idx[k] += 1
        if idx[k] == len[k] { idx[k] = 0 }
    }
}

final class Music {
    static let cap = 4096
    let L = UnsafeMutablePointer<Float>.allocate(capacity: Music.cap)
    let R = UnsafeMutablePointer<Float>.allocate(capacity: Music.cap)
    let chL = UnsafeMutablePointer<Float>.allocate(capacity: Music.cap)
    let chR = UnsafeMutablePointer<Float>.allocate(capacity: Music.cap)

    private let p: Params
    private let sr: Float
    private let nv = 40
    private let v: UnsafeMutablePointer<Voice>
    private let verb: Reverb
    private var rng = Rand(s: 0x2545F491)

    // composition state
    private var step = 0
    private var toStep: Double = 0
    private var key = 50
    private var prog: [[Int]] = []
    private var chordIdx = 0
    private var chord: [Int] = [0, 4, 7, 11]
    private var melodyDeg = 5
    private var genre: Int32 = 0
    private var lastSession: Int32 = -1
    private var lastChime: Int32 = 0

    // bus colour
    private var wet: Float = 0.3
    private var lofiW: Float = 0
    private var bus = [Float](repeating: 0, count: 4)
    private var wowPh: Float = 0
    private var crackleLP: Float = 0
    private var genreGain: Float = 1

    private static let pent = [0, 2, 4, 7, 9]
    private static let I = [0, 4, 7, 11, 14], ii = [2, 5, 9, 12, 16], iii = [4, 7, 11, 14]
    private static let IV = [5, 9, 12, 16, 19], V = [7, 11, 14, 17], Vsus = [7, 12, 14, 17], vi = [9, 12, 16, 19, 23]
    private static let brightProgs = [[I, vi, IV, Vsus], [I, IV, vi, Vsus], [vi, IV, I, Vsus], [I, iii, IV, IV], [IV, I, vi, Vsus]]
    private static let lofiProgs = [[ii, V, I, vi], [IV, iii, ii, I], [I, vi, ii, V], [vi, ii, V, I]]
    private static let darkProgs = [[vi, IV], [I, IV], [IV, vi, I, IV], [vi, iii, IV, I]]

    init(params: Params, sampleRate: Double) {
        p = params
        sr = Float(sampleRate)
        v = UnsafeMutablePointer<Voice>.allocate(capacity: nv)
        v.initialize(repeating: Voice(), count: nv)
        verb = Reverb(sr: sr)
        _ = Tables.shared
    }

    private func newSession() {
        key = rng.pick([45, 46, 48, 50, 51, 53, 55])
        let g = p.genre
        prog = g == 3 ? rng.pick(Music.lofiProgs) : (p.dark != 0 ? rng.pick(Music.darkProgs) : rng.pick(Music.brightProgs))
        chordIdx = 0
        step = 0
        toStep = 0
        melodyDeg = 5
    }

    // MARK: - render

    func render(_ n: Int) {
        for i in 0..<n { L[i] = 0; R[i] = 0; chL[i] = 0; chR[i] = 0 }
        if p.session != lastSession { lastSession = p.session; newSession() }
        if p.chime != lastChime { lastChime = p.chime; chime() }
        if p.genre != genre { genre = p.genre; if genre == 3 || prog.isEmpty { newSession() } }

        // sequencer: schedule every step that starts inside this block
        let tempo = max(30, Double(genre == 3 ? min(max(p.tempo * 0.82, 66), 86) : p.tempo))
        let spStep = Double(sr) * 60 / tempo / 4
        var offset = toStep
        while offset < Double(n) {
            if genre != 0 && p.run > 0 { onStep(at: Int(offset), stepLen: spStep) }
            step += 1
            offset += spStep
        }
        toStep = offset - Double(n)

        // per-genre bus colour, eased per block
        let targetWet: Float = [0.3, 0.55, 0.32, 0.2, 0.6][Int(genre)]
        wet += (targetWet - wet) * 0.02
        verb.decay = genre == 4 ? 6 : (genre == 1 ? 4.5 : 3)
        lofiW += ((genre == 3 ? 1 : 0) - lofiW) * 0.02
        wowPh += 0.42 * Float(n) / sr; if wowPh > 1 { wowPh -= 1 }
        let wow = 1 + lofiW * 0.0028 * sinf(2 * .pi * wowPh)

        renderVoices(n, wow: wow)

        // level-match the genres (measured by the self-test)
        let targetGain: Float = [1, 0.85, 1.65, 1, 1.25][Int(genre)]
        let g0 = genreGain
        genreGain += (targetGain - genreGain) * 0.05
        let dg = (genreGain - g0) / Float(n)
        for i in 0..<n { let g = g0 + dg * Float(i); L[i] *= g; R[i] *= g }

        // lo-fi: dull the top end and lay vinyl dust on it
        if lofiW > 0.001 {
            let k = 1 - expf(-2 * .pi * 3000 / sr)
            for i in 0..<n {
                bus[0] += (L[i] - bus[0]) * k; bus[1] += (bus[0] - bus[1]) * k
                bus[2] += (R[i] - bus[2]) * k; bus[3] += (bus[2] - bus[3]) * k
                L[i] += (bus[1] - L[i]) * lofiW
                R[i] += (bus[3] - R[i]) * lofiW
                let w = rng.bi()
                crackleLP += (w - crackleLP) * 0.5
                var dust = (w - crackleLP) * 0.004
                if rng.unit() < 3 / sr { dust += rng.bi() * 0.25 }
                L[i] += dust * lofiW; R[i] += dust * lofiW
            }
        }
        verb.process(L, R, n, wet: wet)
    }

    private func renderVoices(_ n: Int, wow: Float) {
        let sine = Tables.shared.sine, warm = Tables.shared.warm, keys = Tables.shared.keys
        for vi in 0..<nv where v[vi].on {
            var x = v[vi]
            let tab = x.table == 0 ? sine : (x.table == 1 ? warm : keys)
            let tab2 = x.table2Sine ? sine : tab
            let outL = x.chime ? chL : L, outR = x.chime ? chR : R
            var i = 0
            while i < n {
                if x.wait > 0 { x.wait -= 1; i += 1; continue }
                switch x.stage {
                case 0: x.env += x.aInc; if x.env >= 1 { x.env = 1; x.stage = 1 }
                case 1:
                    x.env += (x.sus - x.env) * x.dK
                    x.hold -= 1; if x.hold <= 0 { x.stage = 2 }
                default:
                    x.env *= x.rK
                    if x.env < 0.0001 { x.on = false }
                }
                if !x.on { break }
                var s: Float
                switch x.kind {
                case .tone:
                    x.ph1 += x.inc * wow; if x.ph1 >= 1 { x.ph1 -= 1 }
                    x.ph2 += x.inc * x.ratio2 * wow; if x.ph2 >= 1 { x.ph2 -= floorf(x.ph2) }
                    s = Tables.read(tab, x.ph1) + x.g2 * Tables.read(tab2, x.ph2)
                    x.g2 *= x.g2k
                    x.cut += (x.cutEnd - x.cut) * x.cutK
                    x.lp1 += x.cut * (s - x.lp1); x.lp2 += x.cut * (x.lp1 - x.lp2)
                    s = x.lp2
                case .kick:
                    x.pe *= x.peK
                    x.ph1 += (44 + 120 * x.pe) / sr; if x.ph1 >= 1 { x.ph1 -= 1 }
                    s = Tables.read(sine, x.ph1)
                case .snare:
                    let w = rng.bi()
                    x.lp1 += 0.35 * (w - x.lp1)
                    x.ph1 += 190 / sr; if x.ph1 >= 1 { x.ph1 -= 1 }
                    let body = Tables.read(sine, x.ph1) * x.g2
                    x.g2 *= x.g2k
                    x.lp2 += 0.45 * ((w - x.lp1) * 0.9 + body - x.lp2)
                    s = x.lp2
                case .hat:
                    let w = rng.bi()
                    x.lp1 += 0.55 * (w - x.lp1)
                    s = w - x.lp1
                case .pop:
                    s = rng.bi()
                }
                let o = s * x.env * x.vel
                outL[i] += o * x.pl
                outR[i] += o * x.pr
                i += 1
            }
            v[vi] = x
        }
    }

    // MARK: - voices

    private func alloc() -> Int {
        if let i = (0..<nv).first(where: { !v[$0].on }) { return i }
        var best = 0, quiet: Float = .infinity
        for i in 0..<nv where !v[i].chime {
            let loud = v[i].env * v[i].vel + (v[i].stage == 2 ? 0 : 1)
            if loud < quiet { quiet = loud; best = i }
        }
        return best
    }

    private func k(_ seconds: Float) -> Float { 1 - expf(-1 / (max(seconds, 0.0005) * sr)) }
    private func rel(_ seconds: Float) -> Float { expf(-3 / (max(seconds, 0.001) * sr)) }
    private func cutK(_ hz: Float) -> Float { 1 - expf(-2 * .pi * min(hz, sr * 0.45) / sr) }

    private func pan(_ x: Float) -> (Float, Float) {
        let a = (x + 1) * 0.25 * .pi
        return (cosf(a), sinf(a))
    }

    @discardableResult
    private func tone(_ midi: Int, table: UInt8, vel: Float, attack: Float, hold: Float, release: Float,
                      cut: Float, cutEnd: Float? = nil, cutTime: Float = 0.3,
                      ratio2: Float = 1.004, g2: Float = 0.8, g2Time: Float = 0, sine2: Bool = false,
                      sus: Float = 1, decay: Float = 0.5, pan p: Float = 0, delay: Int = 0, chime: Bool = false) -> Int {
        let i = alloc()
        var x = Voice()
        x.on = true; x.kind = .tone; x.table = table; x.chime = chime; x.wait = max(0, delay)
        x.inc = 440 * powf(2, Float(midi - 69) / 12) / sr
        x.ph1 = rng.unit(); x.ph2 = rng.unit()
        x.ratio2 = ratio2; x.g2 = g2; x.g2k = g2Time > 0 ? expf(-1 / (g2Time * sr)) : 1; x.table2Sine = sine2
        x.aInc = 1 / max(1, attack * sr); x.sus = sus; x.dK = k(decay); x.rK = rel(release)
        x.hold = Int(hold * sr)
        x.vel = vel
        (x.pl, x.pr) = pan(p)
        x.cut = cutK(cut); x.cutEnd = cutK(cutEnd ?? cut); x.cutK = k(cutTime)
        v[i] = x
        return i
    }

    private func drum(_ kind: Kind, vel: Float, release: Float, delay: Int, pan p: Float = 0) {
        let i = alloc()
        var x = Voice()
        x.on = true; x.kind = kind; x.wait = max(0, delay)
        x.aInc = 1; x.hold = 0; x.stage = 0; x.rK = rel(release); x.vel = vel
        x.pe = 1; x.peK = expf(-1 / (0.035 * sr))
        x.g2 = 0.6; x.g2k = expf(-1 / (0.05 * sr))
        (x.pl, x.pr) = pan(p)
        v[i] = x
    }

    private func nextMelody() -> Int {
        let move = rng.pick([-2, -1, -1, 0, 1, 1, 2])
        melodyDeg = max(0, min(10, melodyDeg + move))
        return (melodyDeg / 5) * 12 + Music.pent[melodyDeg % 5]
    }

    private func voiced(_ chord: [Int], lo: Int, hi: Int) -> [Int] {
        var out: [Int] = []
        for t in chord {
            var m = key + t
            while m < lo { m += 12 }
            while m > hi { m -= 12 }
            if !out.contains(m) { out.append(m) }
        }
        return out.sorted()
    }

    func chime() {
        let base = key + 36
        for (j, iv) in [0, 7, 12].enumerated() {
            tone(base + iv, table: 0, vel: 0.16, attack: 0.004, hold: 0, release: 3.5, cut: 9000,
                 ratio2: 2.756, g2: 0.5, g2Time: 0.4, sine2: true, pan: Float(j - 1) * 0.4,
                 delay: Int(Float(j) * 0.16 * sr), chime: true)
        }
    }

    // MARK: - composition

    private func onStep(at off: Int, stepLen: Double) {
        let density = p.density
        let bright = p.bright
        let s16 = step % 16
        let barsPerChord = [2, 2, 2, 1, 8][Int(genre)]
        let chordLen = Float(stepLen * 16 * Double(barsPerChord)) / sr
        let newChord = step % (16 * barsPerChord) == 0
        if newChord {
            if prog.isEmpty { newSession() }
            chord = prog[chordIdx % prog.count]
            chordIdx += 1
        }
        let jitter = { (ms: Float) -> Int in Int(self.rng.bi() * ms * 0.001 * self.sr) }
        let swing = Int(stepLen * 0.33)

        switch genre {
        case 1: // ambient: breathing pads, scattered bells, a low root
            if newChord {
                for (j, m) in voiced(chord, lo: 55, hi: 74).enumerated() {
                    tone(m, table: 1, vel: 0.075, attack: 2.6, hold: chordLen, release: 4.5, cut: 700 * bright, cutEnd: 1300 * bright,
                         cutTime: 2.5, pan: Float(j % 2 == 0 ? -1 : 1) * 0.5 * rng.unit(), delay: off + j * 400)
                }
                tone(key + chord[0] - 12, table: 0, vel: 0.11, attack: 3, hold: chordLen, release: 4, cut: 400, delay: off)
            }
            if s16 % 2 == 0 && rng.chance(density * 0.11) {
                tone(key + 24 + nextMelody(), table: 0, vel: 0.06 + 0.04 * rng.unit(), attack: 0.003, hold: 0, release: 3.2,
                     cut: 7000, ratio2: 2.756, g2: 0.35, g2Time: 0.35, sine2: true, pan: rng.bi() * 0.8, delay: off + jitter(10))
            }
        case 2: // piano: rolled chords with pedal, a wandering right hand, soft pad underneath
            if newChord {
                tone(key + chord[0] - 12, table: 2, vel: 0.2, attack: 0.004, hold: chordLen * 0.95, release: 1.8,
                     cut: 2400 * bright, cutEnd: 600, cutTime: 0.5, ratio2: 2, g2: 0.2, g2Time: 0.3, sus: 0.35, decay: 1.2, delay: off)
                for (j, m) in voiced(chord, lo: 57, hi: 76).enumerated() {
                    tone(m, table: 2, vel: 0.11 + 0.04 * rng.unit(), attack: 0.003, hold: chordLen * 0.9, release: 1.6,
                         cut: 3200 * bright, cutEnd: 800, cutTime: 0.45, ratio2: 2, g2: 0.15, g2Time: 0.25, sus: 0.3, decay: 1.4,
                         pan: Float(j) * 0.15 - 0.3, delay: off + j * Int(0.045 * sr) + jitter(6))
                    tone(m, table: 1, vel: 0.022, attack: 2, hold: chordLen, release: 3, cut: 900 * bright, delay: off)
                }
            } else if s16 % 2 == 0 && rng.chance(density * 0.34) {
                tone(key + 12 + nextMelody(), table: 2, vel: 0.08 + 0.07 * rng.unit(), attack: 0.003, hold: 0.5, release: 1.4,
                     cut: 3800 * bright, cutEnd: 900, cutTime: 0.35, ratio2: 2, g2: 0.15, g2Time: 0.2, sus: 0.25, decay: 0.9,
                     pan: 0.3, delay: off + jitter(12))
            }
        case 3: // lo-fi: comped keys, walking-ish bass, swung boom-bap
            let beatLen = Float(stepLen * 4) / sr
            let swung = s16 % 4 == 2 ? swing : 0
            if s16 == 0 || s16 == 6 || (s16 == 11 && rng.chance(0.4)) {
                for (j, m) in voiced(chord, lo: 55, hi: 72).enumerated() {
                    tone(m, table: 2, vel: (s16 == 0 ? 0.1 : 0.075) + 0.02 * rng.unit(), attack: 0.004, hold: beatLen * (s16 == 0 ? 1.4 : 0.7),
                         release: 0.6, cut: 2200 * bright, cutEnd: 700, cutTime: 0.3, ratio2: 2, g2: 0.12, g2Time: 0.2,
                         sus: 0.4, decay: 0.6, pan: Float(j) * 0.12 - 0.2, delay: off + swung + j * Int(0.012 * sr) + jitter(5))
                }
            }
            if s16 == 0 || s16 == 8 || (s16 == 14 && rng.chance(0.5)) {
                let m = key + (s16 == 8 ? chord[0] + 7 : chord[0]) - 12
                tone(m, table: 0, vel: 0.26, attack: 0.006, hold: beatLen * 1.2, release: 0.25, cut: 500, ratio2: 2, g2: 0.25,
                     sus: 0.7, decay: 0.4, delay: off + swung)
            }
            let dv = 0.55 + 0.45 * density
            if s16 == 0 || s16 == 10 || (s16 == 7 && rng.chance(0.3)) { drum(.kick, vel: 0.5 * dv, release: 0.32, delay: off + jitter(3)) }
            if s16 == 4 || s16 == 12 { drum(.snare, vel: 0.2 * dv, release: 0.16, delay: off + jitter(4)) }
            if s16 % 2 == 0 && !rng.chance(0.08) {
                drum(.hat, vel: (s16 % 4 == 0 ? 0.075 : 0.045) * dv, release: 0.045, delay: off + swung + jitter(4), pan: 0.25)
            }
            if s16 % 4 == 2 && rng.chance(density * 0.12) {
                tone(key + 24 + nextMelody(), table: 2, vel: 0.06, attack: 0.003, hold: 0.3, release: 0.9, cut: 2600 * bright,
                     cutEnd: 800, cutTime: 0.3, ratio2: 2, g2: 0.1, g2Time: 0.2, sus: 0.3, decay: 0.5, pan: -0.3, delay: off + swung)
            }
        case 4: // drone: root, fifth and octave that swell for minutes, rare high glints
            if newChord {
                let r = key + chord[0] - 12
                for (j, m) in [r, r + 7, r + 12, r + 19].enumerated() {
                    tone(m, table: 1, vel: j < 2 ? 0.09 : 0.05, attack: 7, hold: chordLen, release: 7, cut: 380 * bright,
                         cutEnd: 900 * bright, cutTime: 8, ratio2: 1.006, g2: 0.9, pan: Float(j % 2 == 0 ? -1 : 1) * 0.4, delay: off + j * 1200)
                }
            }
            if s16 == 0 && rng.chance(density * 0.1) {
                tone(key + 36 + Music.pent[Int(rng.next() % 5)], table: 0, vel: 0.035, attack: 0.5, hold: 0, release: 5, cut: 6000,
                     ratio2: 2.01, g2: 0.2, pan: rng.bi() * 0.9, delay: off)
            }
        default: break
        }
    }
}
