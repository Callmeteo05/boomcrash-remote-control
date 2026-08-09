# Umoya — spiritual / soulful amapiano

An original instrumental in the soulful-amapiano lane (the spiritual, gospel-tinged
side of the genre rather than the hard private-school or sgija side). It is written
from scratch — no samples, no reference audio, no borrowed material. Everything is
synthesised in Python.

| | |
|---|---|
| **Key** | F# minor |
| **Tempo** | 112 BPM, 4/4 |
| **Length** | 88 bars ≈ 3:15 |
| **Feel** | 16ths with a 13% shuffle |

```
python3 song.py     # renders out/umoya.wav, out/stems/*.wav, out/midi/*.mid
```

Only dependency is numpy. Audio is written as 16-bit WAV through the stdlib, so
there is no encoder to install. If `lameenc` is present it also writes an MP3;
if not, that step is skipped.

---

## The harmony

The bed is a gospel-leaning turnaround — **i – VI – iv – (ii – V)**:

```
| F#m9 | Dmaj9 | Bm11 | C#m7  E9 |
```

The 9ths and 11ths are the whole point. A plain F#m–D–Bm–C#m loop reads as a sad
minor-key progression; adding the 9th to the tonic and the 11th to the iv opens
the voicings up and gives the prayerful, suspended quality the style lives on.
Nothing ever fully resolves to a bare triad.

The bridge lifts to the major side and comes home through an altered dominant:

```
| Dmaj9 | C#m7 | Bm11 | C#7#5  E9 |
```

That `C#7#5` is the one moment of real tension in the record — a borrowed
dominant pulling back to F#m. It is deliberately short (half a bar).

## The groove

**Log drum** is the signature and the hardest part to get right. Three things
matter:

1. *It is pitched and it moves.* A log drum hammering one note is the giveaway of
   a fake amapiano beat. Each chord in `CHORDS` carries an explicit three-note
   set — root, lower alt, upper alt — chosen per chord so the drum never lands on
   a note that fights the voicing. (Using a blanket "b7 below the root" offset
   instead would sound a C natural against the Dmaj9's C# — the kind of thing
   that makes a track feel subtly wrong without being obviously out of tune.)
2. *The pitch envelope.* A fast bend from ~3.2× down to the target over ~28 ms is
   what makes it read as a struck log rather than a bass note, plus saturation
   for the woody edge.
3. *It never sits on the grid.* The two alternating patterns place hits on the
   `&` and `a` of beats, leaving beat 1 exposed and beat 3 mostly open.

**Everything else** stays out of its way: four-to-the-floor kick, rim/clap on 2
and 4, continuous shaker 16ths with the accents on the offbeats, and offbeat
closed hats. Shakers do the work that trap hats would do in another genre.

## The arrangement

| Bars | Section | What happens |
|---|---|---|
| 0–8 | intro | Pad, choir, sparse keys, shaker only |
| 8–16 | build | Kick, bass and rim enter — still no log drum |
| 16–32 | groove A | Log drum drops, full groove |
| 32–40 | break | Drums out, kalimba motif enters over the choir |
| 40–56 | groove B | Full, with the kalimba carried over |
| 56–64 | bridge | Bridge progression, drums out, choir leads |
| 64–80 | groove C | Biggest section, bridge harmony under the full groove |
| 80–88 | outro | Groove holds four bars, then falls away to pad and choir |

Withholding the log drum until bar 16 is the single most important arrangement
decision. The genre's payoff is the drop into that pattern, and it only works if
the listener has spent time without it.

## Sound design

| Voice | Method |
|---|---|
| Log drum | Pitch-bent sine + 2nd harmonic, saturated, noise transient |
| Kick | Sine with 95 Hz → 52 Hz drop, short noise click |
| Bass | Additive sub, saturated so it survives phone speakers |
| Keys | 2-operator FM Rhodes, slight roll across the voicing so it plays like hands |
| Pad | Three detuned saw stacks, lowpassed at 2 kHz, slow bloom |
| Choir | Formant-shaped harmonics on an /a/ vowel, with vibrato and breath noise |
| Kalimba | FM at a 3.01 ratio, F# minor pentatonic |
| Shaker / hats | Spectrally shaped noise bursts |

The choir is the spiritual centre. It enters in the intro like a hymn and holds
*through* the drops rather than hooking on top of them — it behaves like a bed,
not a lead. If you drop a vocal on this record, that is the layer to duck.

## Mix

- Kick, bass and log drum are the low end; bass and pads duck under every kick
  (55% and 30% depth respectively) so the sub stays readable.
- Keys and choir go through stereo delay into a synthetic plate; drums stay
  mostly dry with a short room.
- Master chain: high shelf at 1.3 kHz, a bell cut at 700 Hz to keep the low mids
  from boxing up, a bell cut at 115 Hz where the kick and log drum pile up, a low
  shelf for weight, then glue saturation and a soft-clip limit.
- Lands at −0.7 dBFS peak, ≈ −13.6 dBFS RMS, with roughly 6 dB between the quiet
  sections and the drops.

## Files

- `out/umoya.mp3` — full mix (committed)
- `out/umoya.wav` — full mix, 16-bit/44.1k
- `out/stems/*.wav` — ten stems at matched levels, ready to import
- `out/midi/umoya_full.mid` — all parts as separate tracks
- `out/midi/umoya_<part>.mid` — keys, bass, log, choir, pad, kalimba individually

The WAV and stems are gitignored (large and regenerable); the MP3 and MIDI are
committed.

## Where to take it

The obvious next move is a vocal — the style is built around one, and the
arrangement leaves the bridge and the break open for it. The MIDI export is there
so the harmony can move into a DAW with real instruments: a sampled Rhodes and a
proper log drum sample will beat these synthesised voices, while the chords,
groove and arrangement carry over unchanged.
