"""Small DSP toolkit for the Umoya render.

Everything is vectorised numpy -- no per-sample python loops -- so a full
3-minute arrangement renders in a few seconds. Filtering is done in the
frequency domain (or baked into per-harmonic amplitudes for the additive
voices), which keeps the whole thing dependency-free apart from numpy.
"""

import numpy as np

SR = 44100


# ---------------------------------------------------------------- utilities

def n_samples(dur):
    return max(1, int(round(dur * SR)))


def time_axis(dur):
    return np.arange(n_samples(dur)) / SR


def midi_to_hz(note):
    return 440.0 * 2.0 ** ((note - 69) / 12.0)


def db(x):
    return 10.0 ** (x / 20.0)


def add_at(buf, pos, sig):
    """Mix `sig` into `buf` at sample offset `pos`, clipping at the tail."""
    start = int(pos)
    if start >= len(buf):
        return
    if start < 0:
        sig = sig[-start:]
        start = 0
        if len(sig) == 0:
            return
    end = min(len(buf), start + len(sig))
    buf[start:end] += sig[: end - start]


# ------------------------------------------------------------------ envelopes

def perc_env(dur, attack=0.003, decay=None, curve=3.0):
    """Fast-attack exponential decay -- drums, plucks, log drum."""
    n = n_samples(dur)
    t = np.arange(n) / SR
    decay = decay if decay is not None else dur
    atk = np.clip(t / max(attack, 1e-6), 0, 1)
    dec = np.exp(-curve * np.clip((t - attack) / max(decay, 1e-6), 0, None))
    return atk * dec


def adsr(dur, a=0.01, d=0.1, s=0.7, r=0.2):
    """Standard ADSR; `dur` is the sustained length, release is appended."""
    n = n_samples(dur)
    na, nd = n_samples(a), n_samples(d)
    nr = n_samples(r)
    env = np.full(n + nr, float(s))
    if na:
        env[:na] = np.linspace(0.0, 1.0, na)
    if nd:
        seg = min(nd, max(0, n - na))
        if seg > 0:
            env[na:na + seg] = np.linspace(1.0, s, nd)[:seg]
    tail = env[n - 1] if n > 0 else s
    if nr:
        env[n:] = tail * np.exp(-4.0 * np.arange(nr) / nr)
    return env


def fade(sig, fade_in=0.005, fade_out=0.02):
    n = len(sig)
    ni, no = min(n_samples(fade_in), n), min(n_samples(fade_out), n)
    out = sig.copy()
    if ni:
        out[:ni] *= np.linspace(0, 1, ni)
    if no:
        out[-no:] *= np.linspace(1, 0, no)
    return out


# ---------------------------------------------------------------- oscillators

def additive(freq, dur, amps, detune_cents=(0.0,), spread_gain=None,
             vibrato_hz=0.0, vibrato_cents=0.0, phase_rand=True, seed=0):
    """Sum of harmonics with per-harmonic amplitudes.

    Baking the filter curve into `amps` is why no runtime filtering is needed:
    a lowpassed saw is just a saw whose harmonics were pre-scaled.
    """
    rng = np.random.default_rng(seed)
    n = n_samples(dur)
    t = np.arange(n) / SR
    out = np.zeros(n)
    if spread_gain is None:
        spread_gain = [1.0 / len(detune_cents)] * len(detune_cents)

    vib_int = None
    if vibrato_cents:
        # slight delay on the vibrato so onsets stay clean; the phase integral
        # is computed once here and scaled per harmonic below
        depth = np.clip(t / 0.35, 0, 1) * (vibrato_cents / 1200.0)
        vib_int = np.cumsum(depth * np.sin(2 * np.pi * vibrato_hz * t)) / SR

    for det, g in zip(detune_cents, spread_gain):
        f = freq * 2.0 ** (det / 1200.0)
        for k, a in enumerate(amps, start=1):
            if a <= 1e-5:
                continue
            fk = f * k
            if fk > 0.45 * SR:
                break
            ph = rng.uniform(0, 2 * np.pi) if phase_rand else 0.0
            inst = 2 * np.pi * fk * t
            if vib_int is not None:
                inst = inst + 2 * np.pi * fk * vib_int
            out += g * a * np.sin(inst + ph)
    return out


def saw_amps(freq, n_harm=48, cutoff=2000.0, order=2.0, tilt=1.0):
    """Amplitudes for a lowpassed sawtooth."""
    k = np.arange(1, n_harm + 1)
    fk = freq * k
    base = 1.0 / (k ** tilt)
    lp = 1.0 / np.sqrt(1.0 + (fk / cutoff) ** (2 * order))
    return base * lp


def formant_amps(freq, n_harm=60, formants=((730, 130, 1.0),
                                            (1090, 190, 0.5),
                                            (2440, 400, 0.22),
                                            (3400, 500, 0.06)),
                 tilt=1.0):
    """Vowel-ish harmonic profile -- resonant peaks over a glottal rolloff.

    Defaults are an /a/ ("aah") vowel, which is what the choir bed sings.
    """
    k = np.arange(1, n_harm + 1)
    fk = freq * k
    amp = np.zeros_like(fk)
    for f0, bw, g in formants:
        amp += g / (1.0 + ((fk - f0) / (bw / 2.0)) ** 2)
    return amp * (1.0 / (k ** tilt))


def fm_voice(freq, dur, ratio=1.0, index=3.0, index_decay=0.35,
             amp_decay=1.6, extra=None):
    """Two-operator FM -- the Rhodes/e-piano and bell tones."""
    n = n_samples(dur)
    t = np.arange(n) / SR
    idx = index * np.exp(-t / max(index_decay, 1e-4))
    mod = idx * np.sin(2 * np.pi * freq * ratio * t)
    y = np.sin(2 * np.pi * freq * t + mod)
    if extra:
        e_ratio, e_gain, e_decay = extra
        y += e_gain * np.exp(-t / e_decay) * np.sin(2 * np.pi * freq * e_ratio * t)
    return y * np.exp(-t / max(amp_decay, 1e-4))


# --------------------------------------------------------------------- noise

def shaped_noise(dur, hp=0.0, lp=20000.0, order=2.0, seed=0, tilt=0.0):
    """White noise shaped by a frequency-domain HP/LP pair."""
    n = n_samples(dur)
    rng = np.random.default_rng(seed)
    x = rng.standard_normal(n)
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(n, 1.0 / SR)
    resp = np.ones_like(f)
    if hp > 0:
        resp *= (f / hp) ** order / np.sqrt(1.0 + (f / hp) ** (2 * order))
    if lp < 20000:
        resp *= 1.0 / np.sqrt(1.0 + (f / lp) ** (2 * order))
    if tilt:
        resp *= (1.0 + f / 1000.0) ** tilt
    return np.fft.irfft(X * resp, n)


# ------------------------------------------------------------------- effects

def saturate(x, drive=1.0, mix=1.0):
    return (1 - mix) * x + mix * np.tanh(x * drive) / np.tanh(drive)


def soft_clip(x, ceiling=0.99):
    return ceiling * np.tanh(x / max(ceiling, 1e-6))


def make_ir(dur=2.6, decay=2.0, damp=4200.0, predelay=0.02, seed=7):
    """Synthetic stereo reverb impulse -- decaying, spectrally damped noise."""
    n = n_samples(dur)
    t = np.arange(n) / SR
    rng = np.random.default_rng(seed)
    ir = np.zeros((n, 2))
    for ch in range(2):
        x = rng.standard_normal(n)
        X = np.fft.rfft(x)
        f = np.fft.rfftfreq(n, 1.0 / SR)
        # dark, gently rolled-off tail + a little low cut so it stays clean
        X *= 1.0 / np.sqrt(1.0 + (f / damp) ** 4)
        X *= (f / 120.0) ** 2 / np.sqrt(1.0 + (f / 120.0) ** 4)
        x = np.fft.irfft(X, n)
        env = np.exp(-t * (6.0 / max(decay, 1e-3)))
        env *= np.clip(t / 0.012, 0, 1)          # soften the very front
        ir[:, ch] = x * env
    pre = n_samples(predelay)
    ir = np.vstack([np.zeros((pre, 2)), ir])
    ir /= np.max(np.abs(ir)) + 1e-12
    return ir


def _next_pow2(x):
    return 1 << (int(x) - 1).bit_length()


def fft_convolve(x, h):
    """Overlap-add convolution of mono `x` with mono `h`."""
    n, m = len(x), len(h)
    B = _next_pow2(max(4 * m, 4096))
    L = B - m + 1
    H = np.fft.rfft(h, B)
    out = np.zeros(n + m - 1)
    for start in range(0, n, L):
        block = x[start:start + L]
        Y = np.fft.rfft(block, B) * H
        y = np.fft.irfft(Y, B)
        end = min(len(out), start + len(y))
        out[start:end] += y[: end - start]
    return out[:n]


def reverb(mono, ir, wet=0.3, dry=1.0):
    """Return a stereo bus: dry centre + convolved stereo tail."""
    left = fft_convolve(mono, ir[:, 0])
    right = fft_convolve(mono, ir[:, 1])
    peak = max(np.max(np.abs(left)), np.max(np.abs(right)), 1e-9)
    left, right = left / peak, right / peak
    scale = np.max(np.abs(mono)) + 1e-9
    out = np.stack([dry * mono + wet * scale * left,
                    dry * mono + wet * scale * right], axis=1)
    return out


def feedback_delay(x, delay_s, feedback=0.38, taps=7, mix=0.28):
    """Vectorised feedback delay -- a sum of decaying shifted copies."""
    d = n_samples(delay_s)
    wet = np.zeros_like(x)
    for i in range(1, taps + 1):
        g = feedback ** i
        if g < 1e-3:
            break
        shift = d * i
        if shift >= len(x):
            break
        wet[shift:] += g * x[:-shift]
    return x + mix * wet


def ping_pong(x, delay_s, feedback=0.4, taps=7, mix=0.3):
    """Stereo delay that alternates channels -- widens keys and chants."""
    d = n_samples(delay_s)
    out = np.stack([x, x], axis=1)
    for i in range(1, taps + 1):
        g = feedback ** i
        if g < 1e-3:
            break
        shift = d * i
        if shift >= len(x):
            break
        ch = i % 2
        out[shift:, ch] += mix * g * x[:-shift]
    return out


def sidechain_env(length, trigger_samples, depth=0.75, release=0.28,
                  hold=0.012):
    """Classic pump: hard duck on each kick, exponential recovery."""
    env = np.ones(length)
    nr = n_samples(release)
    nh = n_samples(hold)
    shape = np.concatenate([np.full(nh, 1.0 - depth),
                            1.0 - depth * np.exp(-4.0 * np.arange(nr) / nr)])
    for pos in trigger_samples:
        p = int(pos)
        if p >= length:
            continue
        end = min(length, p + len(shape))
        env[p:end] = np.minimum(env[p:end], shape[: end - p])
    return env


def stereo(mono, pan=0.0, width=0.0, seed=0):
    """Pan a mono signal; `width` adds a tiny Haas offset for size."""
    l_gain = np.cos((pan + 1) * np.pi / 4)
    r_gain = np.sin((pan + 1) * np.pi / 4)
    left, right = mono * l_gain, mono * r_gain
    if width > 0:
        off = n_samples(width)
        right = np.concatenate([np.zeros(off), right])[: len(mono)]
    return np.stack([left, right], axis=1)


def highpass(x, cutoff, order=2.0):
    """Frequency-domain highpass for whole buses (keeps the low end tidy)."""
    n = len(x)
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(n, 1.0 / SR)
    resp = (f / cutoff) ** order / np.sqrt(1.0 + (f / cutoff) ** (2 * order))
    return np.fft.irfft(X * resp, n)


def shelf(x, freq, gain_db, kind='high', order=1.0):
    """Frequency-domain shelving EQ for master/bus tone shaping."""
    n = len(x)
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(n, 1.0 / SR)
    g = db(gain_db)
    ratio = (np.maximum(f, 1e-6) / freq) ** order
    frac = ratio / (1.0 + ratio) if kind == 'high' else 1.0 / (1.0 + ratio)
    return np.fft.irfft(X * (1.0 + (g - 1.0) * frac), n)


def peaking(x, freq, gain_db, q=1.0):
    """Frequency-domain bell EQ -- used to unclutter the low mids."""
    n = len(x)
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(n, 1.0 / SR)
    bw = max(freq / max(q, 1e-3), 1e-6)
    bell = 1.0 / (1.0 + ((f - freq) / (bw / 2.0)) ** 2)
    return np.fft.irfft(X * (1.0 + (db(gain_db) - 1.0) * bell), n)


def write_wav(path, audio, sr=SR, peak=0.97):
    """16-bit PCM writer (stdlib `wave`, so no encoder dependency)."""
    import wave

    a = np.asarray(audio, dtype=np.float64)
    if a.ndim == 1:
        a = np.stack([a, a], axis=1)
    m = np.max(np.abs(a))
    if m > 0:
        a = a * (peak / m) if m > peak else a
    data = (np.clip(a, -1.0, 1.0) * 32767.0).astype('<i2')
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(a.shape[1])
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(data.tobytes())
    return path
