import Accelerate
import AVFoundation

/// Live spectrum of what is actually playing, for the Glyph display: a tap on the main mixer,
/// 4096-point FFT, folded into `cols` log-spaced columns over 40–600 Hz. Auto-gained so the
/// picture keeps its shape at any volume. Written on the tap thread, read by the panel.
final class Spectrum {
    static let cols = 48
    static let lo = 40.0, hi = 600.0
    private static let n = 4096

    private let lock = NSLock()
    private var bins = [Float](repeating: 0, count: cols)
    private var history = [Float](repeating: 0, count: n)
    private var frame = [Float](repeating: 0, count: n)
    private var re = [Float](repeating: 0, count: n / 2)
    private var im = [Float](repeating: 0, count: n / 2)
    private var mag = [Float](repeating: 0, count: n / 2)
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
    private let fft = vDSP.FFT(log2n: 12, radix: .radix2, ofType: DSPSplitComplex.self)!
    private var ref: Float = 1e-3          // running peak magnitude (slow decay) = auto gain

    /// Column levels 0...1.
    func read() -> [Float] { lock.lock(); defer { lock.unlock() }; return bins }

    func feed(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData else { return }
        let len = Int(buf.frameLength), chans = Int(buf.format.channelCount)
        guard len > 0, chans > 0 else { return }
        let n = Self.n
        // Slide the mono history and append this buffer (latest n samples).
        let take = min(len, n)
        if take < n { history.withUnsafeMutableBufferPointer { h in h.baseAddress!.update(from: h.baseAddress! + take, count: n - take) } }
        for i in 0..<take {
            var s: Float = 0
            for c in 0..<chans { s += ch[c][len - take + i] }
            history[n - take + i] = s / Float(chans)
        }
        vDSP.multiply(history, window, result: &frame)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
                }
                fft.forward(input: split, output: &split)
                vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(n / 2))
            }
        }
        let binHz = buf.format.sampleRate / Double(n)
        var cols = [Float](repeating: 0, count: Self.cols)
        var top: Float = 0
        for i in 0..<Self.cols {
            let f0 = Self.lo * pow(Self.hi / Self.lo, Double(i) / Double(Self.cols))
            let f1 = Self.lo * pow(Self.hi / Self.lo, Double(i + 1) / Double(Self.cols))
            let fc = sqrt(f0 * f1) / binHz
            let a = Int(fc), t = Float(fc - Double(a))
            var v = mag[a] * (1 - t) + mag[min(a + 1, n / 2 - 1)] * t       // narrow columns: interpolate
            let b0 = Int(ceil(f0 / binHz)), b1 = Int(f1 / binHz)
            if b1 >= b0 { for b in b0...min(b1, n / 2 - 1) { v = max(v, mag[b]) } }   // wide columns: peak
            cols[i] = v; top = max(top, v)
        }
        ref = max(ref * 0.985, top, 1e-6)
        let silent = top < 1e-4
        for i in 0..<Self.cols {
            let db = 20 * log10(max(cols[i], 1e-9) / ref)                // 0 dB = the loudest recent column
            cols[i] = silent ? 0 : max(0, min(1, (db + 42) / 42))
        }
        lock.lock(); bins = cols; lock.unlock()
    }
}
