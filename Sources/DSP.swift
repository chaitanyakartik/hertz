import Foundation

/// Parameters written by the UI thread, read by the audio thread.
/// Plain Float/Int32 stores are atomic enough on arm64 for this use; every value is smoothed per sample.
final class Params {
    var beat: Float = 10        // Hz: the rhythm everything locks to
    var carrier: Float = 200    // Hz: the binaural/isochronic tone
    var tone: Float = 0.3       // 0...1 tone layer level
    var noise: Float = 0.4      // 0...1 nature/noise level
    var music: Float = 0.6      // 0...1 music level
    var master: Float = 0.6     // 0...1
    var noiseType: Int32 = 2    // 0 off, 1 pink, 2 brown, 3 rain, 4 waves, 5 fire
    var genre: Int32 = 1        // 0 none, 1 ambient, 2 piano, 3 lo-fi, 4 drone
    var depth: Float = 0.55     // neural effect: amplitude-modulation depth on music + nature
    var iso: Float = 0          // 0 binaural, 1 isochronic
    var run: Float = 0          // 0 stopped, 1 playing (fade target)
    var duck: Float = 1         // 0 during an interval break
    var tempo: Float = 76
    var density: Float = 0.6
    var bright: Float = 1
    var dark: Int32 = 0
    var session: Int32 = 0      // bump → new key and progression
    var chime: Int32 = 0        // bump → bell
}

/// Tone layer + nature bed + generative music, with Brain.fm-style amplitude modulation
/// at the mode's rate. Pure DSP, no AVFoundation, so the self-test can render it offline.
final class DSP {
    let p: Params
    let sr: Float
    let music: Music

    private var sBeat: Float, sCarrier: Float, sTone: Float = 0, sNoise: Float = 0, sMusic: Float = 0, sMaster: Float = 0
    private var sIso: Float = 0, sRun: Float = 0, sDepth: Float = 0, sDuck: Float = 1
    private var w = [Float](repeating: 0, count: 6)
    private let kSlow: Float, kGain: Float, kRun: Float, kDuck: Float

    private var phL: Double = 0, phR: Double = 0, phB: Double = 0

    private var rng: [UInt32] = [0x9E3779B9, 0x7F4A7C15]
    private var pk = [[Float]](repeating: [0, 0, 0], count: 2)
    private var br: [Float] = [0, 0]
    private var lp: [Float] = [0, 0]
    private var lpLow: [Float] = [0, 0]
    private var drop: [Float] = [0, 0], dropK: [Float] = [0.99, 0.99], dropLP: [Float] = [0, 0]
    private var flick: [Float] = [1, 1]
    private var crack: [Float] = [0, 0], crackK: [Float] = [0.9, 0.9], burst: [Float] = [0, 0]
    private var rumble: [Float] = [0, 0]
    private var wavePh: Double = 0
    private var wavePeriod: Double = 10

    var fade: Float { sRun }

    init(params: Params, sampleRate: Double) {
        p = params
        sr = Float(sampleRate)
        sBeat = params.beat
        sCarrier = params.carrier
        music = Music(params: params, sampleRate: sampleRate)
        kSlow = 1 - expf(-1 / (1.2 * sr))
        kGain = 1 - expf(-1 / (0.12 * sr))
        kRun = 1 - expf(-1 / (0.7 * sr))
        kDuck = 1 - expf(-1 / (2.5 * sr))
    }

    @inline(__always) private func white(_ c: Int) -> Float {
        var x = rng[c]
        x ^= x << 13; x ^= x >> 17; x ^= x << 5
        rng[c] = x
        return Float(Int32(bitPattern: x)) / Float(Int32.max)
    }
    @inline(__always) private func unit(_ c: Int) -> Float { white(c) * 0.5 + 0.5 }

    func render(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ n: Int) {
        var done = 0
        while done < n {
            let m = min(Music.cap, n - done)
            renderChunk(L + done, R + done, m)
            done += m
        }
    }

    private func renderChunk(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ n: Int) {
        let musicActive = p.run > 0 || sRun > 0.0005
        if musicActive { music.render(n) } else { for i in 0..<n { music.L[i] = 0; music.R[i] = 0; music.chL[i] = 0; music.chR[i] = 0 } }
        let mL = music.L, mR = music.R, cL = music.chL, cR = music.chR

        let tBeat = p.beat, tCarrier = p.carrier, tTone = p.tone, tNoise = p.noise, tMusic = p.music
        let tMaster = p.master, tIso = p.iso, tRun = p.run, tDepth = p.depth, tDuck = p.duck
        let nt = Int(p.noiseType)
        let twoPi = Float.pi * 2
        let invSr = 1 / Double(sr)
        let lowK = 1 - expf(-2 * .pi * 420 / sr)
        let rumbleK = 1 - expf(-2 * .pi * 160 / sr)

        for i in 0..<n {
            sBeat += (tBeat - sBeat) * kSlow
            sCarrier += (tCarrier - sCarrier) * kSlow
            sTone += (tTone - sTone) * kGain
            sNoise += (tNoise - sNoise) * kGain
            sMusic += (tMusic - sMusic) * kGain
            sMaster += (tMaster - sMaster) * kGain
            sIso += (tIso - sIso) * kGain
            sDepth += (tDepth - sDepth) * kGain
            sRun += (tRun - sRun) * kRun
            sDuck += (tDuck - sDuck) * kDuck
            for t in 1..<6 { w[t] += ((t == nt ? 1 : 0) - w[t]) * kGain }

            // Shared rhythm: the binaural beat, the isochronic pulse and the neural modulation all ride phB.
            phB += Double(sBeat) * invSr; if phB >= 1 { phB -= 1 }
            let pulse = 0.5 - 0.5 * cosf(twoPi * Float(phB))

            // Tone layer
            let split = sBeat * 0.5 * (1 - sIso)
            phL += Double(sCarrier - split) * invSr; if phL >= 1 { phL -= 1 }
            phR += Double(sCarrier + split) * invSr; if phR >= 1 { phR -= 1 }
            let env = 1 + sIso * (pulse * pulse * 1.6 - 1)
            let toneAmp = sTone * sTone * 0.2 * env
            let toneL = sinf(twoPi * Float(phL)) * toneAmp
            let toneR = sinf(twoPi * Float(phR)) * toneAmp

            // Nature / noise bed
            var nz: (Float, Float) = (0, 0)
            if w[1] + w[2] + w[3] + w[4] + w[5] > 0.0005 {
                wavePh += invSr / wavePeriod
                if wavePh >= 1 { wavePh -= 1; wavePeriod = 8 + Double(unit(0)) * 5 }
                for c in 0..<2 {
                    let wn = white(c)
                    pk[c][0] = 0.99765 * pk[c][0] + wn * 0.0990460
                    pk[c][1] = 0.96300 * pk[c][1] + wn * 0.2965164
                    pk[c][2] = 0.57000 * pk[c][2] + wn * 1.0526913
                    let pink = (pk[c][0] + pk[c][1] + pk[c][2] + wn * 0.1848) * 0.14
                    br[c] = (br[c] + 0.02 * wn) / 1.02
                    let brown = br[c] * 3.5
                    lp[c] += (pink - lp[c]) * 0.08
                    let hiss = pink - lp[c]
                    var v = pink * w[1] + brown * w[2]

                    if w[3] > 0.0005 {   // rain: bright wash with flicker, plus individual drops
                        lpLow[c] += (pink - lpLow[c]) * lowK
                        if unit(c) < 1 / (0.05 * sr) { flick[c] = 0.75 + 0.25 * unit(c) }
                        let wash = (pink - lpLow[c]) * 1.5 * flick[c] + brown * 0.25
                        if unit(c) < 22 / sr { drop[c] = 0.3 + 0.7 * unit(c) * unit(c); dropK[c] = expf(-1 / ((0.004 + 0.012 * unit(c)) * sr)) }
                        drop[c] *= dropK[c]
                        dropLP[c] += (wn - dropLP[c]) * 0.3
                        v += (wash + (wn - dropLP[c]) * drop[c] * 0.5) * w[3]
                    }
                    if w[4] > 0.0005 {   // waves: brown surf with a slow 8–13 s swell
                        let ph = Float(wavePh) + (c == 0 ? 0 : 0.06)
                        let s = powf(0.5 - 0.5 * cosf(twoPi * ph), 1.6)
                        v += (brown * (0.35 + 0.65 * s) * 1.2 + hiss * s * s * 0.9) * w[4]
                    }
                    if w[5] > 0.0005 {   // fire: low roar plus clustered crackles
                        rumble[c] += (brown - rumble[c]) * rumbleK
                        burst[c] *= 0.9997
                        let rate: Float = 5 + 60 * burst[c]
                        if unit(c) < rate / sr {
                            let u = max(unit(c), 0.05)
                            crack[c] = min(1, 0.08 / u) * 0.6
                            crackK[c] = expf(-1 / ((0.0004 + 0.0025 * unit(c)) * sr))
                            if unit(c) < 0.3 { burst[c] = 1 }
                        }
                        crack[c] *= crackK[c]
                        v += (rumble[c] * 2.4 * (0.8 + 0.2 * flick[c]) + hiss * crack[c] * 6 + hiss * 0.08) * 0.65 * w[5]
                    }
                    if c == 0 { nz.0 = v } else { nz.1 = v }
                }
            }

            // Neural effect: rhythmic amplitude modulation of the music + nature bed, loudness-compensated.
            let shape = pulse * sqrtf(pulse)                 // pulse^1.5, mean ≈ 0.424
            let am = (1 - sDepth * (1 - shape)) / (1 - sDepth * 0.576)
            let nAmp = sNoise * sNoise * 0.8
            let mAmp = sMusic * sMusic * 1.5
            let bedL = (nz.0 * nAmp + mL[i] * mAmp) * am
            let bedR = (nz.1 * nAmp + mR[i] * mAmp) * am

            let g = sMaster * sMaster * sRun
            L[i] = soft(((toneL + bedL) * sDuck + cL[i]) * g)
            R[i] = soft(((toneR + bedR) * sDuck + cR[i]) * g)
        }
    }

    @inline(__always) private func soft(_ x: Float) -> Float {
        let a = abs(x)
        return a < 0.8 ? x : (x > 0 ? 1 : -1) * (0.8 + 0.2 * tanhf((a - 0.8) / 0.2))
    }
}

/// `Hertz --selftest`: render each configuration offline, report levels and CPU cost.
enum SelfTest {
    static func run() {
        let sr = 48_000, secs = 12
        let n = sr * secs
        let L = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let R = UnsafeMutablePointer<Float>.allocate(capacity: n)
        var ok = true
        func measure(_ label: String, _ setup: (Params) -> Void) {
            let p = Params()
            p.run = 1; p.master = 1; p.tone = 0; p.noise = 0; p.music = 0; p.genre = 0; p.noiseType = 0; p.depth = 0
            setup(p)
            let d = DSP(params: p, sampleRate: Double(sr))
            let t0 = Date()
            var done = 0
            while done < n { let m = min(512, n - done); d.render(L + done, R + done, m); done += m }
            let cpu = Date().timeIntervalSince(t0) / Double(secs) * 100
            var peak: Float = 0, sum: Double = 0, nan = false
            for i in (n / 4)..<n {
                let v = max(abs(L[i]), abs(R[i]))
                if v.isNaN { nan = true }
                peak = max(peak, v); sum += Double(L[i] * L[i] + R[i] * R[i]) / 2
            }
            let rms = sqrt(sum / Double(n - n / 4))
            if nan || peak > 1 || cpu > 15 { ok = false }
            print(String(format: "%-26@ rms=%.3f peak=%.3f cpu=%.1f%% %@", label as NSString, rms, peak, cpu, nan ? "NaN!" : ""))
        }
        measure("tone binaural") { $0.tone = 1 }
        measure("tone isochronic") { $0.tone = 1; $0.iso = 1 }
        for (i, name) in ["pink", "brown", "rain", "waves", "fire"].enumerated() {
            measure("nature \(name)") { $0.noise = 1; $0.noiseType = Int32(i + 1) }
        }
        for (i, name) in ["ambient", "piano", "lofi", "drone"].enumerated() {
            measure("music \(name)") { $0.music = 1; $0.genre = Int32(i + 1); $0.tempo = 92; $0.density = 0.9 }
        }
        measure("everything max, high AM") { $0.music = 1; $0.genre = 3; $0.noise = 1; $0.noiseType = 3; $0.tone = 1; $0.depth = 0.8; $0.density = 1 }
        measure("chime only (loop mixes)") { $0.chime = 1 }
        if !LoopCheck.run() { ok = false }
        print(ok ? "selftest ok" : "selftest FAILED")
        exit(ok ? 0 : 1)
    }
}
