#!/usr/bin/env python3
"""Build Lull's seamless loop files.

    /usr/bin/python3 tools/make_loops.py            # build every loop into audio/loops/
    /usr/bin/python3 tools/make_loops.py lofi rain  # just these

Sources: generated signals (tones, noise) and CC0 recordings in audio/src/ (see audio/src/CREDITS.md).
personal/tracks.py, if present (gitignored), adds PERSONAL_TRACKS and PERSONAL_YT: your own recordings or
YouTube tracks, downloaded into audio/cache/ on first run (yt-dlp needs a JS runtime: node).

Recorded sources are cut at a matched pair of points (a, b), refined to the sample at 48 kHz on L, R and
L-R, and closed with a crossfade: the last F seconds of x[a:b] blend into x[a-F:a], so the wrap lands on
x[a] exactly where the source itself would continue. Correlated material gets a linear crossfade,
uncorrelated (rain, a dissolve) equal-power. Playlists join whole tracks with crossfades, last into first.
Generated sources are synthesised as exactly one period, so they need no crossfade.

File layout: [PAD s of loop tail] + loop + [PAD s of loop head], 48 kHz stereo CAF.
The app plays only the interior (frames PAD ..< PAD+loop) with scheduleSegment, so the codec's
edge frames never sound. The decode check below goes through Apple's decoder (afconvert);
the Swift selftest repeats it through AVAudioFile, the path the app uses.

Writes audio/loops/<id>.caf and audio/loops/report.json (points, seam metrics, LUFS).
"""
import json, os, re, subprocess, sys
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC, CACHE, OUT = (os.path.join(ROOT, "audio", d) for d in ("src", "cache", "loops"))
SR = 48_000
PAD = 1.0          # seconds of wrap padding each side (the app's Loop.pad must match)
TARGET = -18.0     # LUFS every loop is baked to ...
CEIL = -1.0        # ... unless its true peak would pass this (dBTP)
NODE = "/opt/homebrew/opt/node@20/bin/node"

YT = {}

# src paths are relative to audio/. a/b: fixed points (s). search: (a range, b range) to search instead.
# F: crossfade (s). playlist: whole tracks (paths or YT ids) joined end to end. synth: generated.
TRACKS = {
    # 134 Hz L / 174 Hz R sines: the pair repeats every 0.5 s, so 60 s is phase-exact. Baked 6 dB hot
    # (-12 LUFS) with Mix.gain 0.5 in the app: LUFS can't say how loud a 134 Hz tone feels.
    "sharp": dict(synth="binaural", seconds=60.0, F=0.0, codec="alac", target=-12.0),
    "brown": dict(synth="brown", seconds=60.0, F=0.0, codec="aac"),
    "pink":  dict(synth="pink", seconds=60.0, F=0.0, codec="alac"),   # AAC smears pure noise past the pad check
    # CC0, "Chill lofi inspired" by omfgdude (opengameart.org/content/chill-lofi-inspired): end fades into start.
    "lofi":  dict(playlist=["src/lofi-chill-omfgdude.ogg"], F=4.0, codec="aac"),
    # CC0, "It's Pouring" (opengameart.org/content/its-pouring), its steady 75-140 s: noise-like, so any
    # equal-power crossfade is inaudible; take the longest well-matched span.
    "rain":  dict(src="src/rain-its-pouring.flac", search=((5, 8), (58, 64)), F=4.0, codec="alac"),
}

_personal = os.path.join(ROOT, "personal", "tracks.py")
if os.path.exists(_personal):
    _ns = {}
    exec(open(_personal).read(), _ns)
    YT.update(_ns.get("PERSONAL_YT", {})); TRACKS.update(_ns.get("PERSONAL_TRACKS", {}))


def ensure_youtube(vid):
    path = os.path.join(CACHE, vid + ".webm")
    if not os.path.exists(path):
        os.makedirs(CACHE, exist_ok=True)
        subprocess.run(["yt-dlp", "-q", "--no-playlist", "--js-runtimes", f"node:{NODE}", "--remote-components", "ejs:github",
                        "-f", "bestaudio", "-o", os.path.join(CACHE, "%(id)s.%(ext)s"), YT[vid]], check=True)
    return path


def synth(cfg):
    """One exact period of a generated signal, stereo at SR."""
    n = int(cfg["seconds"] * SR); t = np.arange(n) / SR
    if cfg["synth"] == "binaural":
        return np.stack([np.sin(2 * np.pi * 134 * t), np.sin(2 * np.pi * 174 * t)], 1) * 0.5
    # Coloured noise built in the frequency domain over n samples is periodic in n: no seam to hide.
    rng = np.random.default_rng(1)
    f = np.fft.rfftfreq(n, 1 / SR)
    slope = {"pink": 0.5, "brown": 1.0}[cfg["synth"]]           # amplitude ~ f^-slope (power 1/f, 1/f^2)
    mag = np.zeros_like(f); band = f >= 20
    mag[band] = f[band] ** -slope
    mag *= np.clip((f - 20) / 20, 0, 1)                           # fade in 20-40 Hz: no rumble, no DC
    ch = [np.fft.irfft(mag * np.exp(2j * np.pi * rng.random(len(f))), n) for _ in range(2)]   # independent L/R
    x = np.stack(ch, 1)
    return x / np.abs(x).max() * 0.5


def trim_silence(x, db=-75.0, win=0.05):
    """Drop leading/trailing audio quieter than db (50 ms RMS windows)."""
    n = int(win * SR); k = len(x) // n
    rms = np.sqrt((x[:k * n] ** 2).mean(1).reshape(k, n).mean(1))
    on = np.nonzero(rms > 10 ** (db / 20))[0]
    return x[on[0] * n:(on[-1] + 1) * n] if len(on) else x


def build_playlist(cfg):
    """Concatenate the tracks with equal-power crossfades and close the loop (last into first)."""
    n = int(cfg["F"] * SR)
    t = (np.arange(n) + 0.5) / n; gi, go = np.sin(t * np.pi / 2)[:, None], np.cos(t * np.pi / 2)[:, None]
    path = lambda v: os.path.join(ROOT, "audio", v) if "/" in v else os.path.join(CACHE, v + ".webm")   # file or YT id
    parts = [trim_silence(decode(path(v))) for v in cfg["playlist"]]
    seq = parts[0]
    for x in parts[1:]:
        seq = np.concatenate([seq[:-n], seq[-n:] * go + x[:n] * gi, x[n:]])
    loop = seq[n:].copy()
    loop[-n:] = seq[-n:] * go + seq[:n] * gi        # wrap lands on seq[n], right where the head continues
    info = [dict(id=v, seconds=round(len(x) / SR, 2), lufs=lufs(x)[0]) for v, x in zip(cfg["playlist"], parts)]
    return loop, info


def decode(path, t0=None, dur=None, sr=SR, ch=2):
    cmd = ["ffmpeg", "-v", "error"]
    if t0 is not None: cmd += ["-ss", f"{t0:.6f}"]
    if dur is not None: cmd += ["-t", f"{dur:.6f}"]
    cmd += ["-i", path, "-ac", str(ch), "-af", f"aresample={sr}:filter_size=256:phase_shift=10:cutoff=0.97", "-f", "f32le", "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.float32).reshape(-1, ch).astype(np.float64)


def ncorr(u, v):
    u = u - u.mean(); v = v - v.mean()
    return float((u * v).sum() / (np.sqrt((u * u).sum() * (v * v).sum()) + 1e-12))


def spec_frames(m, sr, hop=0.05):
    n = int(hop * sr); k = len(m) // n
    fr = np.abs(np.fft.rfft(m[:k * n].reshape(k, n) * np.hanning(n), axis=1))
    # 24 log-spaced bands, 60 Hz .. sr/2
    edges = np.geomspace(60, sr / 2, 25); f = np.fft.rfftfreq(n, 1 / sr)
    bands = np.stack([fr[:, (f >= lo) & (f < hi)].mean(1) for lo, hi in zip(edges[:-1], edges[1:])], 1)
    return np.log(bands + 1e-7), hop


def search(x, a_rng, b_rng, F):
    """Coarse pair search at 8 kHz mono: waveform correlation of the F-second windows ending at a and b,
    plus spectral similarity (for material with no waveform match). Returns best (a, b, r_wave, spec_dist)."""
    sr = 8000; k = SR // sr
    mono = x.mean(1); m = mono[:len(mono) // k * k].reshape(-1, k).mean(1)   # 6-sample box = crude anti-alias
    S, hop = spec_frames(m, sr); w = int(F / hop)
    best = None
    for a in np.arange(max(a_rng[0], F + PAD), a_rng[1], 0.1):
        qa = m[int((a - F) * sr):int(a * sr)]
        sa = S[int(a / hop) - w:int(a / hop)].mean(0)
        for b in np.arange(b_rng[0], b_rng[1], 0.1):
            if int(b * sr) > len(m): break
            sb = S[int(b / hop) - w:int(b / hop)].mean(0)
            dist = float(np.sqrt(((sa - sb) ** 2).mean()))
            score = -dist
            if best is None or score > best[0]: best = (score, a, b, dist)
    # waveform refinement of b around the spectral best (±0.5 s), and a global waveform pass
    _, a, b, dist = best
    qa = m[int((a - F) * sr):int(a * sr)]
    rbest, bbest = -2, b
    for bb in np.arange(b - 0.5, b + 0.5, 1 / sr):
        e = int(bb * sr)
        if e > len(m): break
        r = ncorr(qa, m[e - len(qa):e])
        if r > rbest: rbest, bbest = r, bb
    # global waveform search over the whole grid (catches true repeats the spectral pass ranks lower)
    wbest = (-2, a, b)
    for a2 in np.arange(max(a_rng[0], F + PAD), a_rng[1], 0.5):
        q = m[int((a2 - F) * sr):int(a2 * sr)]; q = q - q.mean()
        lo, hi = int(b_rng[0] * sr), min(int(b_rng[1] * sr), len(m))
        seg = m[lo - len(q):hi]; seg = seg - seg.mean()
        N = 1 << int(np.ceil(np.log2(len(seg) + len(q))))
        c = np.fft.irfft(np.fft.rfft(seg, N) * np.fft.rfft(q[::-1], N), N)[len(q) - 1:len(seg)]
        cs = np.concatenate([[0], np.cumsum(seg ** 2)]); en = np.sqrt(cs[len(q):] - cs[:-len(q)])[:len(c)]
        r = c / (en * np.sqrt((q * q).sum()) + 1e-12)
        i = int(np.argmax(r))
        if r[i] > wbest[0]: wbest = (float(r[i]), a2, (lo + i) / sr)
    if wbest[0] > max(rbest, 0.6):
        return wbest[1], wbest[2], wbest[0], None
    return a, bbest, rbest, dist


def refine(x, a, b, F, span=0.02):
    """Sample-exact b at 48 kHz: maximise L+R+side correlation of the F windows ending at a and at b."""
    A = int(round(a * SR)); n = int(F * SR); B0 = int(round(b * SR)); s = int(span * SR)
    qa = x[A - n:A]
    def score(B):
        qb = x[B - n:B]
        return ncorr(qa[:, 0], qb[:, 0]) + ncorr(qa[:, 1], qb[:, 1]) + ncorr(qa[:, 0] - qa[:, 1], qb[:, 0] - qb[:, 1])
    cands = range(max(n, B0 - s), min(len(x), B0 + s + 1))
    # coarse step 8, then fine
    B = max(cands[::8], key=score); B = max(range(B - 8, B + 9), key=score)
    qb = x[B - n:B]
    r = dict(L=ncorr(qa[:, 0], qb[:, 0]), R=ncorr(qa[:, 1], qb[:, 1]), side=ncorr(qa[:, 0] - qa[:, 1], qb[:, 0] - qb[:, 1]))
    return A, B, r


def build_loop(x, A, B, F, linear):
    n = int(F * SR)
    loop = x[A:B].copy()
    t = (np.arange(n) + 0.5) / n
    gi, go = (t, 1 - t) if linear else (np.sin(t * np.pi / 2), np.cos(t * np.pi / 2))
    loop[-n:] = x[B - n:B] * go[:, None] + x[A - n:A] * gi[:, None]
    return loop


def seam_metrics(loop):
    """Where the wrap (end -> start) ranks among every sample step and every 20 ms spectral flux in the loop.
    A seamless loop's wrap is unremarkable: percentile well under 99."""
    w = np.concatenate([loop[-SR // 10:], loop[:SR // 10]])            # 100 ms either side of the wrap
    steps = np.abs(np.diff(loop, axis=0)).max(1)
    seam_step = float(np.abs(w[SR // 10] - w[SR // 10 - 1]).max())
    step_pct = float((steps < seam_step).mean() * 100)
    hop = SR // 50; m = loop.mean(1)
    k = len(m) // hop
    fr = np.abs(np.fft.rfft(m[:k * hop].reshape(k, hop) * np.hanning(hop), axis=1))
    flux = np.sqrt(((np.diff(np.log(fr + 1e-6), axis=0)) ** 2).mean(1))
    wm = w.mean(1); a = wm[SR // 10 - hop:SR // 10]; b = wm[SR // 10:SR // 10 + hop]
    fa, fb = (np.abs(np.fft.rfft(v * np.hanning(hop))) for v in (a, b))
    seam_flux = float(np.sqrt(((np.log(fb + 1e-6) - np.log(fa + 1e-6)) ** 2).mean()))
    flux_pct = float((flux < seam_flux).mean() * 100)
    return dict(step_percentile=round(step_pct, 2), flux_percentile=round(flux_pct, 2))


def lufs(x):
    """Integrated loudness (LUFS) and true peak (dBTP) of a float stereo array at SR."""
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-f", "f32le", "-ar", str(SR), "-ac", "2", "-i", "-",
                        "-af", "ebur128=peak=true", "-f", "null", "-"],
                       input=x.astype(np.float32).tobytes(), capture_output=True).stderr.decode()
    i = float(re.findall(r"I:\s+(-?[\d.]+) LUFS", r)[-1]); tp = float(re.findall(r"Peak:\s+(-?[\d.]+) dBFS", r)[-1])
    return i, tp


def write_wav(path, x):
    import wave
    pcm = np.clip(x, -1, 1)
    pcm = (pcm * 8388607).astype(np.int32)
    b = (pcm.reshape(-1, 1).view(np.uint8).reshape(-1, 4)[:, :3]).tobytes()
    with wave.open(path, "wb") as w:
        w.setnchannels(2); w.setsampwidth(3); w.setframerate(SR); w.writeframes(b)


def main(ids):
    os.makedirs(OUT, exist_ok=True)
    rep_path = os.path.join(OUT, "report.json")
    report = json.load(open(rep_path)) if os.path.exists(rep_path) else {}
    for vid in YT:
        if any(vid in str(TRACKS[t].get("src", "")) or vid in TRACKS[t].get("playlist", []) for t in ids): ensure_youtube(vid)
    for tid in ids:
        cfg = TRACKS[tid]; F = cfg["F"]
        if "synth" in cfg:
            loop, info = synth(cfg), "generated: " + cfg["synth"]; t0 = 0.0
            A, B, r, rw, dist, linear = 0, len(loop), {}, None, None, False
        elif "playlist" in cfg:
            loop, info = build_playlist(cfg); t0 = 0.0
            A, B, r, rw, dist, linear = 0, len(loop), {}, None, None, False
        else:
            loop, info, src = None, None, os.path.join(ROOT, "audio", cfg["src"])
        if loop is not None: pass
        elif "search" in cfg:
            x = decode(src); t0 = 0.0
            a, b, rw, dist = search(x, *cfg["search"], F)
        else:
            t0 = cfg["a"] - F - PAD - 2
            x = decode(src, t0, cfg["b"] - t0 + 2); a, b, rw, dist = cfg["a"] - t0, cfg["b"] - t0, None, None
        if loop is None:
            A, B, r = refine(x, a, b, F)
            rmean = (r["L"] + r["R"]) / 2
            linear = rmean > 0.7
            loop = build_loop(x, A, B, F, linear)
        p = int(PAD * SR)
        padded = np.concatenate([loop[-p:], loop, loop[:p]])
        # Bake loudness: TARGET LUFS, unless that pushes the true peak over CEIL (then as loud as the ceiling allows).
        # The app's per-mix gain (player volume, max 1.0) can only trim down from here.
        src_lufs, src_tp = lufs(loop)
        gain_db = min(cfg.get("target", TARGET) - src_lufs, CEIL - src_tp)
        loop = loop * 10 ** (gain_db / 20); padded = padded * 10 ** (gain_db / 20)
        peak = float(np.abs(padded).max())
        wav = os.path.join(OUT, f"{tid}.wav"); caf = os.path.join(OUT, f"{tid}.caf")
        write_wav(wav, padded)
        enc = ["-d", "alac"] if cfg["codec"] == "alac" else ["-d", "aac", "-b", "192000", "-q", "127"]
        subprocess.run(["afconvert", "-f", "caff", *enc, wav, caf], check=True)
        # decode through Apple's decoder and check the interior is the loop, sample-aligned
        dec_wav = os.path.join(OUT, f"{tid}.dec.wav")
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEF32", caf, dec_wav], check=True)
        dec = decode(dec_wav)
        inner = dec[p:p + len(loop)]
        align_err = float(np.sqrt(((inner - loop) ** 2).mean()) / (np.sqrt((loop ** 2).mean()) + 1e-12))
        i_lufs, tp = lufs(loop)
        os.remove(dec_wav)
        rec = dict(src=cfg.get("src") or info, codec=cfg["codec"], start_s=round((A / SR) + t0, 4), end_s=round((B / SR) + t0, 4),
                   loop_s=round(len(loop) / SR, 4), loop_frames=len(loop), pad_frames=p, decoded_frames=len(dec),
                   crossfade_s=F, crossfade="linear" if linear else "equal-power",
                   match_r={k: round(v, 4) for k, v in r.items()}, coarse_wave_r=None if rw is None else round(rw, 4),
                   spec_dist=None if dist is None else round(dist, 4),
                   seam_source=seam_metrics(loop), seam_decoded=seam_metrics(inner),
                   decode_rel_err=round(align_err, 4), source_lufs=src_lufs, applied_gain_db=round(gain_db, 2),
                   lufs=i_lufs, true_peak_dbtp=tp, sample_peak=round(peak, 3), mb=round(os.path.getsize(caf) / 1e6, 1))
        os.remove(wav)
        report[tid] = rec
        print(tid, json.dumps(rec))
        json.dump(report, open(rep_path, "w"), indent=1)


if __name__ == "__main__":
    main(sys.argv[1:] or list(TRACKS))
