"""Isibani -- spiritual / soulful amapiano.

A major (Mixolydian-inflected gospel walk), 113 BPM, 168 bars ~ 5:57.

    python3 song.py            # master + stems + midi into ./out

Written against how records in this lane are actually built -- the Kabza De
Small KOA II / Isimo / Bab'Motha side of the genre. The decisions that matter,
and why, are documented in README.md; the short version is that the log drum
carries the low end and the arrangement takes its time.
"""

import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from engine import dsp
from engine.dsp import SR, midi_to_hz, add_at
from engine.midiwrite import write_midi

# ---------------------------------------------------------------- time grid

BPM = 113.0                  # Imithandazo sits at 113; the lane runs 108-116
BEAT = 60.0 / BPM
BAR = 4 * BEAT
STEP = BEAT / 4.0
SWING = 0.16                 # shuffle on the off-16ths -- the genre bounces
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out')
TITLE = 'isibani'


def step_time(bar, step):
    swing = SWING * STEP if step % 2 else 0.0
    return bar * BAR + step * STEP + swing


# ------------------------------------------------------------------ harmony
#
# The gospel walk -- I - IV - bVII - I -- is the harmonic signature of the
# style. That bVII (G major in the key of A) is borrowed from Mixolydian and
# is what makes a progression read as South African gospel rather than as
# house or neo-soul. Extending everything to maj9 is the "amapiano jazz"
# colour this lane works in.
#
#   log = [root, alt, alt] : the tones the log drum may take over each chord.
#   Roots sit in the 55-100 Hz window so the log drum can carry the low end
#   on its own, walking up A - D - G and dropping back for the turnaround.

CHORDS = {
    'Amaj9': dict(keys=[57, 61, 64, 68, 71], choir=[64, 68, 71],
                  log=[33, 40, 45], sub=33),
    'Dmaj9': dict(keys=[57, 61, 62, 66, 69], choir=[62, 66, 69],
                  log=[38, 45, 33], sub=38),
    'Gmaj9': dict(keys=[55, 59, 62, 66, 69], choir=[62, 66, 69],
                  log=[43, 38, 47], sub=31),
    'Bm9':   dict(keys=[59, 62, 66, 69, 73], choir=[62, 66, 69],
                  log=[35, 42, 38], sub=35),
    'E9':    dict(keys=[56, 59, 62, 64, 66], choir=[59, 64, 66],
                  log=[40, 35, 44], sub=40),
    'F#m9':  dict(keys=[57, 61, 64, 66, 68], choir=[61, 64, 68],
                  log=[42, 37, 33], sub=30),
}

# A: the gospel walk itself. B: the bridge drops to the relative minor for the
# emotional lift, then walks home through the V.
PROG_A = [
    [(0, 16, 'Amaj9')],
    [(0, 16, 'Dmaj9')],
    [(0, 16, 'Gmaj9')],
    [(0, 8, 'Amaj9'), (8, 8, 'E9')],
]
PROG_B = [
    [(0, 16, 'F#m9')],
    [(0, 16, 'Dmaj9')],
    [(0, 16, 'Bm9')],
    [(0, 8, 'E9'), (8, 8, 'Amaj9')],
]

# ------------------------------------------------------------------ grooves
#
# The log drum never lands on a kick. The kick holds the pulse on 0/4/8/12 and
# the log drum bounces through the gaps -- that displacement is the whole
# difference between this and a four-to-the-floor house groove.
# Entries are (step, index into the chord's `log` list, velocity).

LOG_A = [(2, 0, 0.95), (6, 1, 0.85), (9, 0, 1.00), (11, 2, 0.72), (14, 0, 0.90)]
LOG_B = [(2, 0, 0.92), (3, 0, 0.70), (6, 1, 0.88), (10, 0, 1.00),
         (13, 2, 0.75), (14, 0, 0.85)]
LOG_C = [(2, 0, 0.95), (6, 0, 0.85), (7, 1, 0.65), (10, 0, 1.00),
         (14, 2, 0.80), (15, 0, 0.60)]

KICK = [0, 4, 8, 12]
RIM = [4, 12]
OPEN_HAT = [2, 6, 10, 14]          # open hat on the offbeats, not closed
# congas: 0 = tumba (low), 1 = conga (mid), 2 = quinto (high)
CONGA = [(2, 2, .7), (3, 2, .5), (6, 0, .8), (10, 2, .7), (11, 1, .6),
         (14, 0, .75)]
CONGA_ALT = [(0, 0, .7), (3, 2, .6), (6, 2, .5), (7, 1, .7), (11, 2, .6),
             (13, 1, .5), (14, 2, .7)]
BELL = [(6, .55), (14, .45)]
TAMB = [4, 12]

# piano comp: (step, chord-tone indices, velocity). Broken and syncopated --
# amapiano piano is played, not held.
PIANO_A = [(0, (0, 1, 2), .85), (3, (3, 4), .55), (6, (2, 3), .6),
           (8, (0, 1, 2, 3), .7), (11, (4,), .5), (14, (2, 3, 4), .55)]
PIANO_B = [(0, (0, 2, 4), .8), (2, (1, 3), .5), (6, (0, 1, 2, 3), .75),
           (10, (3, 4), .55), (12, (1, 2), .6), (15, (4,), .45)]

# saxophone: an eight-bar phrase over the four-bar loop, so it never lines up
# the same way twice. (bar within phrase, step, midi, length in steps, vel)
SAX = [
    (0, 8, 76, 4, .8), (0, 12, 73, 4, .7),
    (1, 0, 74, 6, .85), (1, 6, 78, 4, .75), (1, 10, 76, 6, .7),
    (2, 0, 71, 8, .8), (2, 8, 69, 4, .65), (2, 12, 71, 4, .6),
    (3, 0, 73, 10, .75),
    (4, 4, 81, 6, .85), (4, 10, 80, 6, .75),
    (5, 0, 78, 8, .8), (5, 8, 76, 8, .7),
    (6, 0, 74, 6, .8), (6, 6, 71, 4, .65), (6, 10, 73, 6, .7),
    (7, 0, 69, 12, .75),
]

# kalimba: A major pentatonic
PENTA = [69, 71, 73, 76, 78, 81]
KALIMBA = [[(0, 3, .8), (3, 1, .6), (6, 2, .7), (11, 0, .6), (14, 1, .5)],
           [(2, 4, .7), (5, 3, .6), (8, 1, .7), (12, 2, .6)],
           [(0, 2, .8), (4, 0, .6), (7, 1, .7), (10, 3, .6), (13, 0, .5)],
           [(1, 1, .7), (6, 2, .7), (9, 0, .6), (14, 3, .5)]]

# ---------------------------------------------------------------- structure
#
# Real records in this lane run 5-7 minutes and introduce elements one at a
# time across the first couple of minutes. The log drum -- the thing the whole
# track is about -- does not arrive until bar 32, a full minute in.

SECTIONS = [
    ('intro_perc',  16, 'A', dict(shaker=.65, conga=.75, bell=.7, pad=.85,
                                  strings=.7)),
    ('intro_keys',  16, 'A', dict(shaker=.85, conga=.9, bell=.8, pad=1,
                                  strings=.9, piano=.85, choir=.75, rim=.6)),
    ('log_enters',  16, 'A', dict(shaker=1, conga=1, bell=.7, pad=1,
                                  strings=.9, piano=.9, choir=.8, rim=.9,
                                  kick=1, log=1, hat=.8, tamb=.7)),
    ('groove_1',    16, 'A', dict(shaker=1, conga=1, bell=.7, pad=1,
                                  strings=1, piano=1, choir=.9, rim=1,
                                  kick=1, log=1, hat=1, tamb=.8, sub=.8,
                                  sax=.85)),
    ('break_1',      8, 'A', dict(pad=1, strings=1, piano=.8, choir=1,
                                  shaker=.35, kalimba=.9)),
    ('groove_2',    24, 'A', dict(shaker=1, conga=1, bell=.8, pad=1,
                                  strings=1, piano=1, choir=1, rim=1,
                                  kick=1, log=1, hat=1, tamb=.9, sub=1,
                                  sax=1, kalimba=.7)),
    ('bridge',      16, 'B', dict(pad=1, strings=1, piano=.9, choir=1,
                                  shaker=.7, conga=.6, kalimba=1, bell=.4,
                                  rim=.5)),
    ('groove_3',    24, 'B', dict(shaker=1, conga=1, bell=.8, pad=1,
                                  strings=1, piano=1, choir=1, rim=1,
                                  kick=1, log=1, hat=1, tamb=1, sub=1,
                                  sax=.9, kalimba=.8)),
    ('break_2',      8, 'A', dict(pad=1, strings=1, piano=.85, choir=1,
                                  shaker=.3)),
    ('outro',       24, 'A', dict(shaker=1, conga=.9, bell=.6, pad=1,
                                  strings=1, piano=.9, choir=.9, rim=.8,
                                  kick=1, log=1, hat=.9, tamb=.7, sub=.8,
                                  sax=.7, kalimba=.6)),
]

TOTAL_BARS = sum(s[1] for s in SECTIONS)
TAIL = 7.0
TOTAL_SEC = TOTAL_BARS * BAR + TAIL
# round the buffer up to a 5-smooth length: every frequency-domain filter runs
# a full-length FFT, and numpy is drastically slower on awkward sizes
N = dsp.next_fast_len(int(TOTAL_SEC * SR))

BUSES = ('log', 'kick', 'sub', 'piano', 'pad', 'strings', 'choir', 'sax',
         'kalimba', 'shaker', 'hat', 'rim', 'conga', 'bell', 'tamb')


def bar_chords(bar_index, prog_name):
    return (PROG_A if prog_name == 'A' else PROG_B)[bar_index % 4]


def chord_at(bar_index, prog_name, step):
    for start, length, name in bar_chords(bar_index, prog_name):
        if start <= step < start + length:
            return name
    return bar_chords(bar_index, prog_name)[0][2]


# ------------------------------------------------------------------- voices

_cache = {}


def cached(fn):
    def wrapper(*args, **kwargs):
        key = (fn.__name__, args, tuple(sorted(kwargs.items())))
        if key not in _cache:
            _cache[key] = fn(*args, **kwargs)
        return _cache[key]
    return wrapper


def _cap_harmonics(freq, limit_hz=9000, hard=64):
    return int(max(4, min(hard, limit_hz / max(freq, 1e-6))))


@cached
def v_logdrum(note, dur=0.6):
    """The log drum. It does three jobs at once -- sub-bass, groove and melody
    -- so it gets a long tail (it *is* the bassline), a hard pitch snap for the
    struck-wood attack, and saturation for the woody edge."""
    f = midi_to_hz(note)
    t = dsp.time_axis(dur)
    bend = 1.0 + 3.0 * np.exp(-t / 0.022)
    phase = 2 * np.pi * np.cumsum(f * bend) / SR
    body = np.sin(phase)
    body += 0.30 * np.sin(2 * phase) * np.exp(-t / 0.045)
    body += 0.10 * np.sin(3 * phase) * np.exp(-t / 0.02)
    env = dsp.perc_env(dur, attack=0.002, decay=0.30, curve=2.6)
    knock = dsp.shaped_noise(dur, hp=800, lp=5000, seed=int(note)) * \
        dsp.perc_env(dur, attack=0.0005, decay=0.008, curve=6.0) * 0.30
    return dsp.fade(dsp.saturate(body * env * 1.25, drive=2.6) + knock,
                    0.001, 0.05)


@cached
def v_kick(dur=0.5):
    """Soft but bold: holds the pulse, stays out of the log drum's way."""
    t = dsp.time_axis(dur)
    f = 48.0 + 80.0 * np.exp(-t / 0.025)
    phase = 2 * np.pi * np.cumsum(f) / SR
    body = np.sin(phase) * dsp.perc_env(dur, 0.001, 0.11, 3.6)
    click = dsp.shaped_noise(dur, hp=800, lp=6000, seed=11) * \
        dsp.perc_env(dur, 0.0003, 0.004, 8.0) * 0.16
    return dsp.fade(dsp.saturate(body * 1.1, 1.8) + click, 0.0005, 0.03)


@cached
def v_sub(note, dur):
    """Sparse reinforcement only -- the log drum owns the low end."""
    f = midi_to_hz(note)
    tone = dsp.additive(f, dur + 0.3, [1.0, 0.18, 0.06], phase_rand=False)
    env = dsp.adsr(dur, a=0.06, d=0.3, s=0.6, r=0.3)[:len(tone)]
    return dsp.fade(tone[:len(env)] * env, 0.02, 0.06)


@cached
def v_piano(note, dur):
    """Acoustic grand: inharmonic partials (stiff strings), per-partial decay
    so the top dies first, and hammer noise on the attack."""
    f0 = midi_to_hz(note)
    n = dsp.n_samples(dur + 0.4)
    t = np.arange(n) / SR
    rng = np.random.default_rng(int(note))
    out = np.zeros(n)
    B = 0.0004                                   # inharmonicity coefficient
    for k in range(1, 34):
        fk = k * f0 * np.sqrt(1.0 + B * k * k)
        if fk > 0.45 * SR:
            break
        amp = 1.0 / (k ** 1.25)
        decay = 2.2 + 0.75 * k                   # partials thin out with time
        out += amp * np.exp(-t * decay / max(dur * 3.5, 1.0)) * \
            np.sin(2 * np.pi * fk * t + rng.uniform(0, 2 * np.pi))
    hammer = dsp.shaped_noise(len(out) / SR, hp=1500, lp=9000,
                              seed=int(note) + 3) * \
        dsp.perc_env(len(out) / SR, 0.0008, 0.006, 6.0) * 0.10
    out = out * dsp.perc_env(len(out) / SR, 0.003, dur * 0.7, 2.0) + hammer
    return dsp.fade(out, 0.003, 0.06)


@cached
def v_sax(note, dur):
    """Tenor-ish reed: formant-weighted harmonics, breath, and vibrato that
    opens up as the note is held."""
    f = midi_to_hz(note)
    n_harm = _cap_harmonics(f, 9000)
    k = np.arange(1, n_harm + 1)
    fk = f * k
    amps = 1.0 / (k ** 0.85)
    for ff, bw, g in ((700, 400, 1.1), (1500, 600, 0.8), (2600, 800, 0.4)):
        amps += g / (1.0 + ((fk - ff) / (bw / 2.0)) ** 2) / (k ** 0.5)
    y = dsp.additive(f, dur + 0.35, amps, detune_cents=(-3.0, 3.0),
                     spread_gain=(0.5, 0.5), vibrato_hz=5.1,
                     vibrato_cents=28.0, seed=int(note) + 90)
    breath = dsp.shaped_noise(len(y) / SR, hp=2200, lp=8000,
                              seed=int(note)) * 0.10
    env = dsp.adsr(dur, a=0.055, d=0.25, s=0.8, r=0.28)[:len(y)]
    return dsp.fade((y[:len(env)] + breath[:len(env)]) * env, 0.03, 0.1)


@cached
def v_pad(note, dur):
    f = midi_to_hz(note)
    amps = dsp.saw_amps(f, n_harm=_cap_harmonics(f, 8000), cutoff=1900,
                        order=2.0)
    y = dsp.additive(f, dur + 0.6, amps, detune_cents=(-10.0, 0.0, 10.0),
                     spread_gain=(0.34, 0.4, 0.34), seed=int(note))
    env = dsp.adsr(dur, a=0.5, d=0.6, s=0.75, r=0.6)[:len(y)]
    return dsp.fade(y[:len(env)] * env, 0.06, 0.25)


@cached
def v_strings(note, dur):
    """Reverb-soaked string bed -- the layer stacked under everything."""
    f = midi_to_hz(note)
    amps = dsp.saw_amps(f, n_harm=_cap_harmonics(f, 9000), cutoff=3000,
                        order=1.5, tilt=1.1)
    y = dsp.additive(f, dur + 0.7, amps, detune_cents=(-14.0, -5.0, 5.0, 14.0),
                     spread_gain=(0.25, 0.25, 0.25, 0.25),
                     vibrato_hz=5.6, vibrato_cents=10.0, seed=int(note) + 20)
    env = dsp.adsr(dur, a=0.6, d=0.7, s=0.72, r=0.7)[:len(y)]
    return dsp.fade(y[:len(env)] * env, 0.1, 0.3)


@cached
def v_choir(note, dur):
    f = midi_to_hz(note)
    amps = dsp.formant_amps(f, n_harm=_cap_harmonics(f, 6500), tilt=0.85)
    y = dsp.additive(f, dur + 0.5, amps, detune_cents=(-7.0, 0.0, 6.0),
                     spread_gain=(0.33, 0.4, 0.33), vibrato_hz=4.8,
                     vibrato_cents=16.0, seed=int(note) + 40)
    breath = dsp.shaped_noise(len(y) / SR, hp=1800, lp=6500,
                              seed=int(note)) * 0.09
    env = dsp.adsr(dur, a=0.35, d=0.6, s=0.7, r=0.6)[:len(y)]
    return dsp.fade((y[:len(env)] + breath[:len(env)]) * env, 0.06, 0.25)


@cached
def v_kalimba(note, dur=1.1):
    f = midi_to_hz(note)
    y = dsp.fm_voice(f, dur, ratio=3.01, index=1.5, index_decay=0.06,
                     amp_decay=0.42, extra=(6.4, 0.12, 0.07))
    y *= dsp.perc_env(dur, attack=0.002, decay=0.3, curve=2.6)
    return dsp.fade(y, 0.002, 0.06)


@cached
def v_conga(pitch, dur=0.45):
    """Hand drum: pitched membrane with a fast bend plus a skin slap. Three
    tunings -- tumba, conga, quinto -- give the live feel."""
    f = midi_to_hz(pitch)
    t = dsp.time_axis(dur)
    bend = 1.0 + 0.75 * np.exp(-t / 0.014)
    body = np.sin(2 * np.pi * np.cumsum(f * bend) / SR)
    body += 0.35 * np.sin(2 * np.pi * np.cumsum(f * 2.7 * bend) / SR) * \
        np.exp(-t / 0.03)
    body *= dsp.perc_env(dur, 0.001, 0.075, 3.4)
    slap = dsp.shaped_noise(dur, hp=1800, lp=9000, seed=int(pitch)) * \
        dsp.perc_env(dur, 0.0006, 0.014, 5.0) * 0.32
    return dsp.fade(dsp.saturate(body, 1.6) + slap, 0.0008, 0.04)


@cached
def v_bell(dur=0.5):
    """Small metallic bell -- the texture layer over the percussion."""
    t = dsp.time_axis(dur)
    y = np.zeros(len(t))
    for f, g, d in ((540, 1.0, 0.10), (812, 0.6, 0.07), (1290, 0.35, 0.05),
                    (2100, 0.15, 0.03)):
        y += g * np.sin(2 * np.pi * f * t) * np.exp(-t / d)
    return dsp.fade(y * 0.5, 0.0008, 0.05)


@cached
def v_tamb(dur=0.35):
    """Jingles: several offset noise bursts with a metallic tilt."""
    n = dsp.n_samples(dur)
    out = np.zeros(n)
    for i, off in enumerate((0.0, 0.004, 0.009, 0.015)):
        b = dsp.shaped_noise(dur, hp=5500, lp=15000, seed=60 + i) * \
            dsp.perc_env(dur, 0.0008, 0.045 - i * 0.008, 4.0)
        add_at(out, int(off * SR), b[:n - int(off * SR)])
    return dsp.fade(out * 0.5, 0.001, 0.05)


@cached
def v_shaker(dur=0.10):
    n = dsp.shaped_noise(dur, hp=5200, lp=13000, seed=3)
    return dsp.fade(n * dsp.perc_env(dur, 0.002, 0.026, 4.0), 0.001, 0.02)


@cached
def v_openhat(dur=0.45):
    n = dsp.shaped_noise(dur, hp=6500, lp=16000, seed=5)
    return dsp.fade(n * dsp.perc_env(dur, 0.001, 0.14, 2.4), 0.001, 0.04)


@cached
def v_rim(dur=0.3):
    t = dsp.time_axis(dur)
    tone = np.sin(2 * np.pi * 340 * t) * dsp.perc_env(dur, 0.0005, 0.011, 6.0)
    tone += np.sin(2 * np.pi * 1820 * t) * \
        dsp.perc_env(dur, 0.0005, 0.005, 8.0) * 0.5
    clap = np.zeros(len(t))
    for i, off in enumerate((0.0, 0.008, 0.017)):
        burst = dsp.shaped_noise(dur, hp=1100, lp=7000, seed=20 + i) * \
            dsp.perc_env(dur, 0.001, 0.020, 4.0)
        add_at(clap, int(off * SR), burst[:len(t) - int(off * SR)])
    return dsp.fade(tone * 0.75 + clap * 0.5, 0.0005, 0.04)


CONGA_PITCH = (48, 55, 62)          # tumba, conga, quinto

# ------------------------------------------------------------------- render


def render():
    buses = {k: np.zeros(N, dtype=np.float32) for k in BUSES}
    kick_hits = []
    midi = {k: [] for k in ('piano', 'sax', 'log', 'choir', 'pad', 'strings',
                            'kalimba', 'sub')}

    bar = 0
    for name, length, prog, mix in SECTIONS:
        for b in range(length):
            abs_bar = bar + b
            beat0 = abs_bar * 4.0
            events = bar_chords(b, prog)
            phrase_end = (b % 8) == 7
            # the last eight bars of the outro peel the arrangement apart
            fade_out = name == 'outro' and b >= 16
            trim = max(0.0, 1.0 - (b - 15) / 9.0) if fade_out else 1.0

            # ---- sustained harmony -------------------------------------
            for start, slen, cname in events:
                ch = CHORDS[cname]
                dur = round(slen * STEP - 0.02, 3)
                t0 = step_time(abs_bar, start) * SR

                if mix.get('pad'):
                    for note in [ch['log'][0] + 12] + ch['keys'][:4]:
                        add_at(buses['pad'], t0,
                               v_pad(note, dur) * mix['pad'] * 0.17 * trim)
                        midi['pad'].append((beat0 + start / 4, slen / 4,
                                            note, 60))
                if mix.get('strings'):
                    for note in ch['keys'][1:]:
                        add_at(buses['strings'], t0,
                               v_strings(note, dur) * mix['strings'] * 0.10 * trim)
                        midi['strings'].append((beat0 + start / 4, slen / 4,
                                                note, 64))
                if mix.get('choir'):
                    for note in ch['choir']:
                        add_at(buses['choir'], t0,
                               v_choir(note, dur) * mix['choir'] * 0.28 * trim)
                        midi['choir'].append((beat0 + start / 4, slen / 4,
                                              note, 70))
                if mix.get('sub'):
                    add_at(buses['sub'], t0,
                           v_sub(ch['sub'], dur) * mix['sub'] * 0.16 * trim)
                    midi['sub'].append((beat0 + start / 4, slen / 4,
                                        ch['sub'], 90))

            # ---- piano comp ---------------------------------------------
            if mix.get('piano'):
                comp = PIANO_A if (b % 2 == 0) else PIANO_B
                for step, idxs, vel in comp:
                    voicing = CHORDS[chord_at(b, prog, step)]['keys']
                    t0 = step_time(abs_bar, step)
                    hold = round(0.8 if len(idxs) > 2 else 0.5, 3)
                    for j, idx in enumerate(idxs):
                        note = voicing[idx % len(voicing)]
                        add_at(buses['piano'], (t0 + j * 0.010) * SR,
                               v_piano(note, hold) * vel * mix['piano'] *
                               0.22 * trim)
                        midi['piano'].append((beat0 + step / 4, hold / BEAT,
                                              note, int(58 + 52 * vel)))

            # ---- saxophone -----------------------------------------------
            if mix.get('sax'):
                for sbar, step, note, slen, vel in SAX:
                    if sbar != (b % 8):
                        continue
                    dur = round(slen * STEP, 3)
                    add_at(buses['sax'], step_time(abs_bar, step) * SR,
                           v_sax(note, dur) * vel * mix['sax'] * 0.20 * trim)
                    midi['sax'].append((beat0 + step / 4, slen / 4, note,
                                        int(60 + 50 * vel)))

            # ---- kick + log drum -----------------------------------------
            if mix.get('kick'):
                for step in KICK:
                    pos = step_time(abs_bar, step) * SR
                    add_at(buses['kick'], pos, v_kick() * 0.55 * trim)
                    kick_hits.append(pos)

            if mix.get('log'):
                pattern = (LOG_A, LOG_B, LOG_C)[b % 3]
                for step, tone, vel in pattern:
                    note = CHORDS[chord_at(b, prog, step)]['log'][tone]
                    add_at(buses['log'], step_time(abs_bar, step) * SR,
                           v_logdrum(note) * vel * mix['log'] * 0.42 * trim)
                    midi['log'].append((beat0 + step / 4, 0.25, note,
                                        int(72 + 50 * vel)))

            # ---- percussion ----------------------------------------------
            if mix.get('shaker'):
                for step in range(16):
                    vel = 0.95 if step % 4 == 2 else 0.45
                    if step % 4 == 0:
                        vel *= 0.6
                    add_at(buses['shaker'], step_time(abs_bar, step) * SR,
                           v_shaker() * vel * mix['shaker'] * 0.30 * trim)
            if mix.get('hat'):
                for step in OPEN_HAT:
                    add_at(buses['hat'], step_time(abs_bar, step) * SR,
                           v_openhat() * mix['hat'] * 0.13 * trim)
            if mix.get('conga'):
                pat = CONGA if (b % 4 < 2) else CONGA_ALT
                for step, drum, vel in pat:
                    add_at(buses['conga'], step_time(abs_bar, step) * SR,
                           v_conga(CONGA_PITCH[drum]) * vel * mix['conga'] *
                           0.26 * trim)
            if mix.get('rim'):
                for step in RIM:
                    add_at(buses['rim'], step_time(abs_bar, step) * SR,
                           v_rim() * mix['rim'] * 0.5 * trim)
                if phrase_end:
                    for step in (13, 14, 15):
                        add_at(buses['rim'], step_time(abs_bar, step) * SR,
                               v_rim() * 0.28 * mix['rim'] * trim)
            if mix.get('bell') and (b % 2) == 0:
                for step, vel in BELL:
                    add_at(buses['bell'], step_time(abs_bar, step) * SR,
                           v_bell() * vel * mix['bell'] * 0.30 * trim)
            if mix.get('tamb'):
                for step in TAMB:
                    add_at(buses['tamb'], step_time(abs_bar, step) * SR,
                           v_tamb() * mix['tamb'] * 0.22 * trim)

            # ---- kalimba --------------------------------------------------
            if mix.get('kalimba'):
                for step, idx, vel in KALIMBA[b % 4]:
                    note = PENTA[idx]
                    add_at(buses['kalimba'], step_time(abs_bar, step) * SR,
                           v_kalimba(note) * vel * mix['kalimba'] * 0.34 * trim)
                    midi['kalimba'].append((beat0 + step / 4, 0.5, note,
                                            int(58 + 50 * vel)))
        bar += length

    return buses, kick_hits, midi


# ---------------------------------------------------------------------- mix

GAINS = dict(kick=0.80, log=0.85, sub=0.70, piano=1.00, pad=0.48,
             strings=0.80, choir=0.85, sax=0.95, kalimba=0.80, shaker=0.95,
             hat=1.00, rim=0.90, conga=1.00, bell=1.00, tamb=0.85)


def mixdown(buses, kick_hits, stem_dir):
    plate = dsp.make_ir(dur=3.0, decay=2.4, damp=3800, predelay=0.03, seed=7)
    room = dsp.make_ir(dur=1.0, decay=0.8, damp=6000, predelay=0.008, seed=13)
    duck = dsp.sidechain_env(N, kick_hits, depth=0.45, release=0.24)
    duck_soft = dsp.sidechain_env(N, kick_hits, depth=0.25, release=0.20)

    master = np.zeros((N, 2), dtype=np.float32)
    levels = {}

    def place(name, sig):
        """Gain, write the stem, fold into the master, then free it."""
        s = sig[:N].astype(np.float32) * GAINS[name]
        dsp.write_wav(os.path.join(stem_dir, f'{name}.wav'), s, peak=0.9)
        levels[name] = (float(np.max(np.abs(s))),
                        float(np.sqrt(np.mean(s.astype(np.float64) ** 2))))
        master[:] += s

    def take(name):
        return buses.pop(name).astype(np.float64)

    # low end: mono and dry. The log drum gets only a whisper of room -- it has
    # to stay tight enough to work as the bassline.
    place('kick', dsp.stereo(take('kick'), 0.0))
    place('sub', dsp.stereo(take('sub') * duck, 0.0))
    log = dsp.highpass(take('log'), 40)
    place('log', dsp.reverb(log, room, wet=0.08, dry=1.0))
    del log

    # piano: the melodic centre, wide and lightly delayed
    piano = dsp.highpass(take('piano'), 100)
    place('piano', dsp.ping_pong(piano, BEAT * 0.75, feedback=0.30, mix=0.18) +
          dsp.reverb(piano, plate, wet=0.30, dry=0.0) * 0.9)
    del piano

    sax = dsp.highpass(take('sax'), 180)
    place('sax', dsp.ping_pong(sax, BEAT * 0.5, feedback=0.30, mix=0.20) +
          dsp.reverb(sax, plate, wet=0.34, dry=0.0) * 0.9)
    del sax

    pad = dsp.highpass(take('pad'), 75) * duck_soft
    place('pad', dsp.reverb(pad, plate, wet=0.48, dry=0.8))
    del pad

    strings = dsp.highpass(take('strings'), 170) * duck_soft
    place('strings', dsp.reverb(strings, plate, wet=0.55, dry=0.8))
    del strings

    choir = dsp.highpass(take('choir'), 150) * duck_soft
    place('choir', dsp.reverb(choir, plate, wet=0.60, dry=0.8) +
          dsp.ping_pong(choir * 0.22, BEAT * 1.5, feedback=0.3, mix=0.25) * 0.5)
    del choir

    kal = dsp.highpass(take('kalimba'), 250)
    place('kalimba', dsp.ping_pong(kal, BEAT * 0.375, feedback=0.40, mix=0.28) +
          dsp.reverb(kal, plate, wet=0.38, dry=0.0))
    del kal

    # percussion: spread wide, short room so they share one space
    conga = dsp.highpass(take('conga'), 90)
    place('conga', dsp.reverb(conga, room, wet=0.22, dry=1.0))
    del conga
    rim = dsp.highpass(take('rim'), 220)
    place('rim', dsp.reverb(rim, room, wet=0.28, dry=1.0))
    del rim
    place('shaker', dsp.stereo(dsp.highpass(take('shaker'), 3000), 0.35,
                               width=0.006))
    place('hat', dsp.stereo(dsp.highpass(take('hat'), 4000), -0.32,
                            width=0.005))
    place('bell', dsp.stereo(dsp.highpass(take('bell'), 350), -0.5,
                             width=0.004))
    place('tamb', dsp.stereo(dsp.highpass(take('tamb'), 3500), 0.5,
                             width=0.005))

    # master: low cut, tone shaping, glue saturation, soft-clip limit
    m = master.astype(np.float64)
    del master
    for ch in (0, 1):
        m[:, ch] = dsp.highpass(m[:, ch], 26)
        m[:, ch] = dsp.shelf(m[:, ch], 1300, 5.5, 'high')
        m[:, ch] = dsp.peaking(m[:, ch], 700, -2.5, q=1.2)
        m[:, ch] = dsp.peaking(m[:, ch], 115, -3.0, q=1.4)
        m[:, ch] = dsp.shelf(m[:, ch], 55, 2.5, 'low')
    m = dsp.saturate(m * 0.85, drive=1.5, mix=0.35)
    m = dsp.soft_clip(m, 0.95)
    m *= 0.92 / (np.max(np.abs(m)) + 1e-9)
    ni, no = int(0.05 * SR), int(4.0 * SR)
    m[:ni] *= np.linspace(0, 1, ni)[:, None]
    m[-no:] *= np.linspace(1, 0, no)[:, None] ** 1.5
    return m, levels


def export_midi(midi):
    mdir = os.path.join(OUT, 'midi')
    os.makedirs(mdir, exist_ok=True)
    channels = dict(piano=0, sub=1, log=2, choir=3, pad=4, kalimba=5, sax=6,
                    strings=7)
    for name, notes in midi.items():
        write_midi(os.path.join(mdir, f'{TITLE}_{name}.mid'),
                   [(name, notes, channels[name])], tempo=BPM)
    write_midi(os.path.join(mdir, f'{TITLE}_full.mid'),
               [(n, midi[n], channels[n]) for n in midi], tempo=BPM)
    return mdir


def export_mp3(wav_path, mp3_path, bitrate=256):
    """Optional MP3 export -- skipped silently if lameenc isn't installed."""
    try:
        import lameenc
        import wave
    except ImportError:
        return None
    with wave.open(str(wav_path)) as w:
        pcm = w.readframes(w.getnframes())
        sr, ch = w.getframerate(), w.getnchannels()
    enc = lameenc.Encoder()
    enc.set_bit_rate(bitrate)
    enc.set_in_sample_rate(sr)
    enc.set_channels(ch)
    enc.set_quality(2)
    with open(mp3_path, 'wb') as f:
        f.write(enc.encode(pcm) + enc.flush())
    return mp3_path


def main():
    stem_dir = os.path.join(OUT, 'stems')
    os.makedirs(stem_dir, exist_ok=True)
    print(f'{TITLE.title()} | {BPM:.0f} BPM | A major (gospel walk) | '
          f'{TOTAL_BARS} bars | {int(TOTAL_SEC//60)}:{TOTAL_SEC%60:04.1f}')

    print('rendering parts...')
    buses, kick_hits, midi = render()
    print('mixing...')
    master, levels = mixdown(buses, kick_hits, stem_dir)

    wav = os.path.join(OUT, f'{TITLE}.wav')
    dsp.write_wav(wav, master, peak=0.92)
    export_midi(midi)
    if export_mp3(wav, os.path.join(OUT, f'{TITLE}.mp3')) is None:
        print('(pip install lameenc for an mp3 export)')

    for name in sorted(levels):
        pk, rms = levels[name]
        print(f'  {name:<9} peak {20*np.log10(pk+1e-12):7.2f}  '
              f'rms {20*np.log10(rms+1e-12):7.2f}')
    peak = np.max(np.abs(master))
    rms = np.sqrt(np.mean(master ** 2))
    print(f'master peak {20*np.log10(peak):.2f} dBFS | '
          f'rms {20*np.log10(rms):.2f} dBFS -> {OUT}')


if __name__ == '__main__':
    main()
