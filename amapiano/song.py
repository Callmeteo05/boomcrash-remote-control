"""Umoya -- spiritual/soulful amapiano.

F# minor, 112 BPM, 4/4. Renders a full arrangement plus stems and MIDI.

    python3 song.py            # master + stems + midi into ./out

The musical decisions (voicings, groove, arrangement) live at the top of the
file so they are easy to edit; the synthesis voices are below them.
"""

import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from engine import dsp
from engine.dsp import SR, midi_to_hz, add_at
from engine.midiwrite import write_midi

# ---------------------------------------------------------------- time grid

BPM = 112.0
BEAT = 60.0 / BPM
BAR = 4 * BEAT
STEP = BEAT / 4.0            # 16th note
SWING = 0.13                 # subtle shuffle on the off-16ths
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out')


def step_time(bar, step):
    """Absolute seconds for a 16th-note step, with swing applied."""
    swing = SWING * STEP if step % 2 else 0.0
    return bar * BAR + step * STEP + swing


# ------------------------------------------------------------------ harmony
#
# The bed is a gospel-leaning i - VI - iv - (ii - V) turnaround in F# minor:
# the 9ths and 11ths are what give it the airy, prayerful quality rather than
# a plain minor-key loop. The bridge lifts to the relative-major side and
# comes home through an altered dominant.

CHORDS = {
    # `log` lists the three tones the log drum may play over each chord --
    # [root, lower alt, upper alt] -- picked per chord rather than as fixed
    # semitone offsets, so it never lands on a note that fights the voicing
    # (a blanket b7 below D would sound C natural against the Dmaj9).
    'F#m9':  dict(keys=[54, 57, 61, 64, 68], choir=[61, 64, 68], bass=30,
                  log=[42, 37, 40]),
    'Dmaj9': dict(keys=[50, 54, 57, 61, 64], choir=[61, 64, 66], bass=38,
                  log=[38, 33, 35]),
    'Bm11':  dict(keys=[47, 50, 54, 57, 64], choir=[59, 64, 66], bass=35,
                  log=[35, 30, 33]),
    'C#m7':  dict(keys=[49, 52, 56, 59, 63], choir=[59, 63, 64], bass=37,
                  log=[37, 32, 35]),
    'E9':    dict(keys=[52, 56, 59, 62, 66], choir=[59, 62, 66], bass=40,
                  log=[40, 35, 38]),
    # the altered dominant keeps its #5 in the keys only -- the log drum
    # takes the b7 and 11th so the low end stays clean
    'C#7#5': dict(keys=[49, 53, 57, 59, 63], choir=[57, 59, 65], bass=37,
                  log=[37, 35, 30]),
}

# (start_step, length_steps, chord) per bar of the 4-bar cycle
PROG_A = [
    [(0, 16, 'F#m9')],
    [(0, 16, 'Dmaj9')],
    [(0, 16, 'Bm11')],
    [(0, 8, 'C#m7'), (8, 8, 'E9')],
]
PROG_B = [
    [(0, 16, 'Dmaj9')],
    [(0, 16, 'C#m7')],
    [(0, 16, 'Bm11')],
    [(0, 8, 'C#7#5'), (8, 8, 'E9')],
]

# ---------------------------------------------------------------- structure

SECTIONS = [
    # name        bars  prog   elements
    ('intro',      8, 'A', dict(pad=.8, choir=.5, keys=.45, shaker=.4)),
    ('build',      8, 'A', dict(pad=1, choir=.8, keys=1, shaker=1, kick=1,
                                bass=1, rim=.7, log=.0, hats=.6)),
    ('groove_a',  16, 'A', dict(pad=1, choir=1, keys=1, shaker=1, kick=1,
                                bass=1, rim=1, log=1, hats=1)),
    ('break',      8, 'A', dict(pad=.9, choir=.85, keys=.6, kalimba=.9, shaker=.35)),
    ('groove_b',  16, 'A', dict(pad=1, choir=1, keys=1, shaker=1, kick=1,
                                bass=1, rim=1, log=1, hats=1, kalimba=.8)),
    ('bridge',     8, 'B', dict(pad=1, choir=1, keys=1, kalimba=1, shaker=.6,
                                bass=.7)),
    ('groove_c',  16, 'B', dict(pad=1, choir=1, keys=1, shaker=1, kick=1,
                                bass=1, rim=1, log=1, hats=1, kalimba=.8)),
    ('outro',      8, 'A', dict(pad=.85, choir=.6, keys=.5, shaker=.35,
                                kick=.9, log=.8, rim=.6, hats=.5, bass=.8)),
]

TOTAL_BARS = sum(s[1] for s in SECTIONS)
TAIL = 6.0
TOTAL_SEC = TOTAL_BARS * BAR + TAIL
N = int(TOTAL_SEC * SR)

# ------------------------------------------------------------------ grooves
#
# The log drum is the signature: syncopated, never on every beat, and it
# moves melodically instead of hammering one note. Entries are
# (step, tone index into the chord's `log` list, velocity).

LOG_A = [(0, 0, 1.00), (3, 0, 0.80), (6, 1, 0.90), (10, 0, 1.00), (13, 2, 0.78)]
LOG_B = [(0, 0, 1.00), (3, 0, 0.78), (6, 0, 0.85), (8, 1, 0.80),
         (11, 0, 0.95), (14, 2, 0.75)]

KICK = [0, 4, 8, 12]
RIM = [4, 12]
HATS = [2, 6, 10, 14]
SHAKER_ACC = {2: 1.0, 6: 1.0, 10: 1.0, 14: 1.0}

# keys comp: which chord tones fire on which step (index into the voicing)
KEYS_A = [(0, (0, 1, 2, 3, 4), 0.85), (6, (2, 3, 4), 0.55),
          (10, (1, 2, 3), 0.6), (14, (3, 4), 0.45)]
KEYS_B = [(0, (0, 1, 2), 0.8), (3, (3, 4), 0.5), (8, (1, 2, 3, 4), 0.7),
          (11, (2, 3), 0.45), (14, (4,), 0.4)]

# kalimba motif: F# minor pentatonic, (step, scale index, velocity)
PENTA = [66, 69, 71, 73, 76, 78]      # F#4 A4 B4 C#5 E5 F#5
KALIMBA = [[(0, 4, .8), (3, 2, .6), (6, 3, .7), (11, 1, .6), (14, 2, .5)],
           [(2, 5, .7), (5, 4, .6), (8, 2, .7), (12, 3, .6)],
           [(0, 3, .8), (4, 1, .6), (7, 2, .7), (10, 0, .6), (13, 1, .5)],
           [(1, 2, .7), (6, 3, .7), (9, 3, .6), (14, 5, .5)]]


def bar_chords(bar_index, prog_name):
    prog = PROG_A if prog_name == 'A' else PROG_B
    return prog[bar_index % 4]


def chord_at(bar_index, prog_name, step):
    """Chord sounding at a given step of a bar."""
    for start, length, name in bar_chords(bar_index, prog_name):
        if start <= step < start + length:
            return name
    return bar_chords(bar_index, prog_name)[0][2]


# ------------------------------------------------------------------- voices
#
# Rendered notes are cached: the arrangement reuses the same pitches many
# times, so this turns thousands of additive renders into a few dozen.

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
def v_logdrum(note, dur=0.42):
    """Amapiano log drum: a sine with a fast downward pitch bend, body and
    a touch of saturation for the woody 'donk'."""
    f = midi_to_hz(note)
    t = dsp.time_axis(dur)
    bend = 1.0 + 2.2 * np.exp(-t / 0.028)          # snap down to pitch
    phase = 2 * np.pi * np.cumsum(f * bend) / SR
    body = np.sin(phase)
    body += 0.28 * np.sin(2 * phase) * np.exp(-t / 0.05)
    env = dsp.perc_env(dur, attack=0.002, decay=0.16, curve=3.2)
    click = dsp.shaped_noise(dur, hp=1200, lp=6000, seed=int(note)) * \
        dsp.perc_env(dur, attack=0.0005, decay=0.006, curve=6.0) * 0.35
    out = dsp.saturate(body * env * 1.15, drive=2.4) + click
    return dsp.fade(out, 0.001, 0.02)


@cached
def v_kick(dur=0.55):
    t = dsp.time_axis(dur)
    f = 52.0 + 95.0 * np.exp(-t / 0.022)
    phase = 2 * np.pi * np.cumsum(f) / SR
    body = np.sin(phase) * dsp.perc_env(dur, 0.001, 0.13, 3.4)
    click = dsp.shaped_noise(dur, hp=900, lp=7000, seed=11) * \
        dsp.perc_env(dur, 0.0003, 0.004, 8.0) * 0.22
    return dsp.fade(dsp.saturate(body * 1.2, 2.0) + click, 0.0005, 0.03)


@cached
def v_bass(note, dur):
    """Round sub with saturated harmonics so it survives small speakers."""
    f = midi_to_hz(note)
    amps = [1.0, 0.30, 0.14, 0.07, 0.035, 0.02]
    tone = dsp.additive(f, dur + 0.25, amps, phase_rand=False)
    env = dsp.adsr(dur, a=0.012, d=0.18, s=0.72, r=0.22)[:len(tone)]
    tone = tone[:len(env)] * env
    return dsp.fade(dsp.saturate(tone * 1.1, 1.8, mix=0.7), 0.006, 0.03)


@cached
def v_keys(note, dur):
    """Warm Rhodes-ish FM electric piano."""
    f = midi_to_hz(note)
    y = dsp.fm_voice(f, dur, ratio=1.0, index=2.9, index_decay=0.26,
                     amp_decay=max(0.6, dur * 0.9),
                     extra=(4.02, 0.14, 0.14))
    y *= dsp.perc_env(dur, attack=0.004, decay=dur * 0.55, curve=2.2)
    return dsp.fade(y, 0.004, 0.05)


@cached
def v_pad(note, dur):
    """Wide detuned string/pad bed, filtered dark, slow to bloom."""
    f = midi_to_hz(note)
    amps = dsp.saw_amps(f, n_harm=_cap_harmonics(f, 8000), cutoff=2000,
                        order=2.0)
    y = dsp.additive(f, dur + 0.6, amps,
                     detune_cents=(-9.0, 0.0, 9.0),
                     spread_gain=(0.34, 0.4, 0.34),
                     seed=int(note))
    env = dsp.adsr(dur, a=0.42, d=0.5, s=0.75, r=0.55)[:len(y)]
    return dsp.fade(y[:len(env)] * env, 0.05, 0.2)


@cached
def v_choir(note, dur):
    """Wordless 'aah' choir -- formant-shaped harmonics with human drift.

    This is the spiritual centre of the record: it enters like a hymn and
    holds through the drops instead of hooking on top of them.
    """
    f = midi_to_hz(note)
    amps = dsp.formant_amps(f, n_harm=_cap_harmonics(f, 6500), tilt=0.85)
    y = dsp.additive(f, dur + 0.5, amps,
                     detune_cents=(-7.0, 0.0, 6.0),
                     spread_gain=(0.33, 0.4, 0.33),
                     vibrato_hz=4.8, vibrato_cents=16.0,
                     seed=int(note) + 40)
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
def v_shaker(dur=0.10, bright=1.0):
    n = dsp.shaped_noise(dur, hp=5200 * bright, lp=13000, seed=3)
    return dsp.fade(n * dsp.perc_env(dur, 0.002, 0.028, 4.0), 0.001, 0.02)


@cached
def v_hat(dur=0.13, open_hat=False):
    d = 0.42 if open_hat else 0.035
    n = dsp.shaped_noise(dur + (0.3 if open_hat else 0), hp=7000, lp=16000,
                         seed=5)
    return dsp.fade(n * dsp.perc_env(len(n) / SR, 0.001, d, 3.0), 0.001, 0.02)


@cached
def v_rim(dur=0.3):
    """Rimshot + soft clap layer on 2 and 4."""
    t = dsp.time_axis(dur)
    tone = np.sin(2 * np.pi * 320 * t) * dsp.perc_env(dur, 0.0005, 0.012, 6.0)
    tone += np.sin(2 * np.pi * 1750 * t) * dsp.perc_env(dur, 0.0005, 0.006, 8.0) * 0.5
    clap = np.zeros(len(t))
    for i, off in enumerate((0.0, 0.009, 0.019)):
        burst = dsp.shaped_noise(dur, hp=1100, lp=7000, seed=20 + i) * \
            dsp.perc_env(dur, 0.001, 0.022, 4.0)
        add_at(clap, int(off * SR), burst[:len(t) - int(off * SR)])
    return dsp.fade(tone * 0.8 + clap * 0.55, 0.0005, 0.04)


# ------------------------------------------------------------------- render

def render():
    buses = {k: np.zeros(N) for k in
             ('log', 'kick', 'bass', 'keys', 'pad', 'choir', 'kalimba',
              'shaker', 'hats', 'rim')}
    kick_hits = []
    midi = {k: [] for k in ('keys', 'bass', 'log', 'choir', 'pad', 'kalimba')}

    bar = 0
    for si, (name, length, prog, mix) in enumerate(SECTIONS):
        last_section = si == len(SECTIONS) - 1
        for b in range(length):
            abs_bar = bar + b
            beat0 = abs_bar * 4.0
            events = bar_chords(b, prog)
            phrase_end = (b % 8) == 7          # fills land at phrase ends
            drop_drums = last_section and b >= 4

            # ---- sustained harmony: pad, choir --------------------------
            for start, slen, cname in events:
                ch = CHORDS[cname]
                dur = slen * STEP - 0.02
                t0 = step_time(abs_bar, start)

                if mix.get('pad'):
                    for i, note in enumerate([ch['bass'] + 12] + ch['keys'][:4]):
                        sig = v_pad(note, round(dur, 3))
                        add_at(buses['pad'], t0 * SR, sig * mix['pad'] * 0.19)
                        midi['pad'].append((beat0 + start / 4, slen / 4, note, 62))

                if mix.get('choir'):
                    for note in ch['choir']:
                        sig = v_choir(note, round(dur, 3))
                        add_at(buses['choir'], t0 * SR, sig * mix['choir'] * 0.32)
                        midi['choir'].append((beat0 + start / 4, slen / 4, note, 70))

            # ---- keys comp ---------------------------------------------
            if mix.get('keys'):
                comp = KEYS_A if (b % 2 == 0) else KEYS_B
                for step, idxs, vel in comp:
                    cname = chord_at(b, prog, step)
                    voicing = CHORDS[cname]['keys']
                    t0 = step_time(abs_bar, step)
                    hold = 0.55 if len(idxs) > 3 else 0.35
                    for j, idx in enumerate(idxs):
                        note = voicing[idx % len(voicing)]
                        sig = v_keys(note, round(hold, 3))
                        # tiny roll across the voicing, like a played chord
                        off = (t0 + j * 0.011) * SR
                        add_at(buses['keys'], off, sig * vel * mix['keys'] * 0.27)
                        midi['keys'].append((beat0 + step / 4, hold / BEAT,
                                             note, int(60 + 50 * vel)))

            # ---- bass ---------------------------------------------------
            if mix.get('bass'):
                for step, slen in ((0, 9), (10, 6)):
                    cname = chord_at(b, prog, step)
                    note = CHORDS[cname]['bass']
                    dur = slen * STEP
                    sig = v_bass(note, round(dur, 3))
                    add_at(buses['bass'], step_time(abs_bar, step) * SR,
                           sig * mix['bass'] * 0.26)
                    midi['bass'].append((beat0 + step / 4, slen / 4, note, 96))

            # ---- kick ---------------------------------------------------
            if mix.get('kick') and not drop_drums:
                steps = list(KICK)
                if phrase_end:
                    steps.append(14)
                for step in steps:
                    pos = step_time(abs_bar, step) * SR
                    add_at(buses['kick'], pos, v_kick() * 0.52)
                    kick_hits.append(pos)

            # ---- log drum ------------------------------------------------
            if mix.get('log') and not drop_drums:
                pattern = LOG_A if (b % 2 == 0) else LOG_B
                for step, tone, vel in pattern:
                    cname = chord_at(b, prog, step)
                    note = CHORDS[cname]['log'][tone]
                    sig = v_logdrum(note)
                    add_at(buses['log'], step_time(abs_bar, step) * SR,
                           sig * vel * mix['log'] * 0.46)
                    midi['log'].append((beat0 + step / 4, 0.25, note,
                                        int(70 + 50 * vel)))

            # ---- percussion ---------------------------------------------
            if mix.get('shaker'):
                for step in range(16):
                    vel = SHAKER_ACC.get(step, 0.42)
                    if step % 4 == 0:
                        vel *= 0.6
                    add_at(buses['shaker'], step_time(abs_bar, step) * SR,
                           v_shaker() * vel * mix['shaker'] * 0.34)

            if mix.get('hats') and not drop_drums:
                for step in HATS:
                    op = phrase_end and step == 14
                    add_at(buses['hats'], step_time(abs_bar, step) * SR,
                           v_hat(open_hat=op) * (0.28 if op else 0.20) *
                           mix['hats'])

            if mix.get('rim') and not drop_drums:
                for step in RIM:
                    add_at(buses['rim'], step_time(abs_bar, step) * SR,
                           v_rim() * mix['rim'] * 0.55)
                if phrase_end:
                    for step in (13, 14, 15):
                        add_at(buses['rim'], step_time(abs_bar, step) * SR,
                               v_rim() * 0.3 * mix['rim'])

            # ---- kalimba ------------------------------------------------
            if mix.get('kalimba'):
                motif = KALIMBA[b % 4]
                for step, idx, vel in motif:
                    note = PENTA[idx]
                    add_at(buses['kalimba'], step_time(abs_bar, step) * SR,
                           v_kalimba(note) * vel * mix['kalimba'] * 0.38)
                    midi['kalimba'].append((beat0 + step / 4, 0.5, note,
                                            int(60 + 50 * vel)))
        bar += length

    return buses, kick_hits, midi


# ---------------------------------------------------------------------- mix

def mixdown(buses, kick_hits):
    plate = dsp.make_ir(dur=2.8, decay=2.3, damp=3800, predelay=0.028, seed=7)
    room = dsp.make_ir(dur=1.0, decay=0.8, damp=6000, predelay=0.008, seed=13)

    duck = dsp.sidechain_env(N, kick_hits, depth=0.55, release=0.26)
    duck_soft = dsp.sidechain_env(N, kick_hits, depth=0.30, release=0.20)

    stems = {}

    # low end stays mono and dry, ducked under the kick
    stems['bass'] = dsp.stereo(buses['bass'] * duck, 0.0) * 1.0
    stems['kick'] = dsp.stereo(buses['kick'], 0.0)

    # log drum: mostly dry with a short room so it keeps its punch
    log = dsp.highpass(buses['log'], 45)
    stems['logdrum'] = dsp.reverb(log, room, wet=0.10, dry=1.0)

    # keys: stereo delay into a plate -- the soulful smear
    keys = dsp.highpass(buses['keys'], 110)
    keys_st = dsp.ping_pong(keys, delay_s=BEAT * 0.75, feedback=0.34, mix=0.22)
    keys_rev = dsp.reverb(keys, plate, wet=0.34, dry=0.0)
    stems['keys'] = keys_st + keys_rev * 0.9

    # pad and choir: wide, wet, gently pumping under the kick
    pad = dsp.highpass(buses['pad'], 70) * duck_soft
    stems['pad'] = dsp.reverb(pad, plate, wet=0.45, dry=0.85)

    choir = dsp.highpass(buses['choir'], 150) * duck_soft
    choir_rev = dsp.reverb(choir, plate, wet=0.62, dry=0.8)
    stems['choir'] = choir_rev + dsp.ping_pong(choir * 0.25, BEAT * 1.5,
                                               feedback=0.3, mix=0.25) * 0.5

    kal = dsp.highpass(buses['kalimba'], 250)
    kal_st = dsp.ping_pong(kal, delay_s=BEAT * 0.375, feedback=0.42, mix=0.3)
    stems['kalimba'] = kal_st + dsp.reverb(kal, plate, wet=0.4, dry=0.0)

    # percussion spread across the field
    stems['shaker'] = dsp.stereo(dsp.highpass(buses['shaker'], 3000), 0.35,
                                 width=0.006)
    stems['hats'] = dsp.stereo(dsp.highpass(buses['hats'], 4000), -0.3,
                               width=0.005)
    rim = dsp.highpass(buses['rim'], 220)
    stems['rim'] = dsp.reverb(rim, room, wet=0.3, dry=1.0)

    gains = dict(kick=0.90, bass=0.78, logdrum=0.95, keys=0.75, pad=0.55,
                 choir=0.85, kalimba=0.78, shaker=0.95, hats=0.90, rim=0.85)

    master = np.zeros((N, 2))
    for name, sig in stems.items():
        s = sig[:N] if len(sig) >= N else np.pad(sig, ((0, N - len(sig)), (0, 0)))
        stems[name] = s * gains[name]
        master += stems[name]

    # master chain: low cut, glue saturation, safety limit
    master[:, 0] = dsp.highpass(master[:, 0], 26)
    master[:, 1] = dsp.highpass(master[:, 1], 26)
    # tilt: the genre lives on sub weight, but the top has to breathe
    for ch in (0, 1):
        master[:, ch] = dsp.shelf(master[:, ch], 1300, 5.5, 'high')
        master[:, ch] = dsp.peaking(master[:, ch], 700, -3.0, q=1.2)
        master[:, ch] = dsp.peaking(master[:, ch], 115, -2.5, q=1.4)
        master[:, ch] = dsp.shelf(master[:, ch], 55, 3.0, 'low')
    master = dsp.saturate(master * 0.85, drive=1.5, mix=0.35)
    master = dsp.soft_clip(master, 0.95)
    master *= 0.92 / (np.max(np.abs(master)) + 1e-9)

    # fade the very top and tail so nothing clicks
    ni, no = int(0.05 * SR), int(3.0 * SR)
    master[:ni] *= np.linspace(0, 1, ni)[:, None]
    master[-no:] *= np.linspace(1, 0, no)[:, None] ** 1.5
    return master, stems


def export_midi(midi):
    mdir = os.path.join(OUT, 'midi')
    os.makedirs(mdir, exist_ok=True)
    channels = dict(keys=0, bass=1, log=2, choir=3, pad=4, kalimba=5)
    for name, notes in midi.items():
        write_midi(os.path.join(mdir, f'umoya_{name}.mid'),
                   [(name, notes, channels[name])], tempo=BPM)
    write_midi(os.path.join(mdir, 'umoya_full.mid'),
               [(n, midi[n], channels[n]) for n in midi], tempo=BPM)
    return mdir


def main():
    os.makedirs(os.path.join(OUT, 'stems'), exist_ok=True)
    print(f'Umoya | {BPM:.0f} BPM | F# minor | '
          f'{TOTAL_BARS} bars | {TOTAL_SEC/60:.0f}:{TOTAL_SEC%60:04.1f}')

    print('rendering parts...')
    buses, kick_hits, midi = render()

    print('mixing...')
    master, stems = mixdown(buses, kick_hits)

    dsp.write_wav(os.path.join(OUT, 'umoya.wav'), master, peak=0.92)
    for name, sig in stems.items():
        dsp.write_wav(os.path.join(OUT, 'stems', f'{name}.wav'), sig, peak=0.9)
    export_midi(midi)

    peak = np.max(np.abs(master))
    rms = np.sqrt(np.mean(master ** 2))
    print(f'master peak {20*np.log10(peak):.2f} dBFS | '
          f'rms {20*np.log10(rms):.2f} dBFS')
    print(f'written to {OUT}')


if __name__ == '__main__':
    main()
