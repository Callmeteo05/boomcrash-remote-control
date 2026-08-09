# Isibani — spiritual / soulful amapiano

An original instrumental in the soulful-amapiano lane — the spiritual,
gospel-tinged side of the genre. Written from scratch: no samples, no reference
audio, no borrowed material. Everything is synthesised in Python.

| | |
|---|---|
| **Key** | A major (Mixolydian-inflected gospel walk) |
| **Tempo** | 113 BPM, 4/4 |
| **Length** | 168 bars ≈ 6:00 |
| **Feel** | 16ths with a 16% shuffle |

```
python3 song.py     # renders out/isibani.{wav,mp3}, out/stems/, out/midi/
```

Only dependency is numpy. Audio is written as 16-bit WAV through the stdlib; if
`lameenc` is present it also writes an MP3.

---

## What this version fixed

The first draft of this track was, correctly, called out as deep house with a
log drum bolted on. Researching how these records are actually built turned up
six concrete faults, and each one is a real structural difference between the
genres rather than a matter of taste:

| Fault | Deep house behaviour (v1) | Amapiano behaviour (now) |
|---|---|---|
| **Log drum placement** | Hits on step 0, on top of the kick | Never lands on a kick — bounces through the gaps |
| **Who carries the bass** | Separate sustained bassline | The log drum *is* the bassline; sub only reinforces |
| **Harmony** | Minor i–VI–iv–ii–V | I–IV–♭VII gospel walk (Mixolydian) |
| **Hats** | Closed hats on the offbeats | Open hats on the offbeats, over 16th shakers |
| **Percussion** | Shaker and rim only | Congas, quinto, bell, tambourine, rim — live feel |
| **Length / shape** | 3:15, intro→build→drop→breakdown | 6:00, elements entering one at a time |

The single biggest one is the log drum. In deep house the kick drives the
record; in amapiano the log drum drives it and the kick just holds the pulse
underneath. Getting that hierarchy backwards is what made v1 sound like house.

## The harmony

The gospel walk — **I – IV – ♭VII – I** — is the harmonic signature of the
style:

```
| Amaj9 | Dmaj9 | Gmaj9 | Amaj9  E9 |
```

That **G major in the key of A** is the whole trick. It is the flat seventh,
borrowed from Mixolydian, and it is what makes a progression read as South
African gospel instead of as house or neo-soul. A minor-key loop — which is
what v1 used — cannot produce that feeling no matter how it is voiced.
Extending everything to maj9 is the "amapiano jazz" colour this lane works in.

The bridge drops to the relative minor for the emotional lift, then walks home
through the V:

```
| F#m9 | Dmaj9 | Bm9 | E9  Amaj9 |
```

## The groove

**The log drum is doing three jobs at once** — sub-bass, rhythm and melody —
and each one shaped the synthesis:

1. *It is the bassline.* That is why it gets a long tail and why the sub is
   reduced to sparse reinforcement under the biggest sections. Two competing
   low-end parts is a house arrangement.
2. *It never lands on a kick.* The kick holds 0/4/8/12; the log drum plays
   2/6/9/11/14 and variants. Three alternating patterns rotate so the groove
   never locks into a one-bar loop.
3. *It moves melodically.* Each chord carries an explicit three-note set —
   root plus two consonant alternates — so the drum walks A–D–G with the
   harmony instead of hammering one note.

**Around it**: soft four-on-the-floor kick, continuous 16th shakers accented on
the offbeats, **open** hats on those same offbeats, congas in three tunings
(tumba/conga/quinto) playing a clave-ish figure, rimshot on 2 and 4, plus bell
and tambourine for the metallic texture layer. That percussion stack is what
gives the genre its live, hand-played feel.

## The arrangement

Records in this lane run five to seven minutes and introduce elements one at a
time. There is no EDM-style drop — the track accumulates.

| Bar | Time | Section | What happens |
|---|---|---|---|
| 0 | 0:00 | intro_perc | Percussion and pads only |
| 16 | 0:34 | intro_keys | Piano and choir enter |
| 32 | 1:08 | log_enters | **Kick and log drum arrive** |
| 48 | 1:42 | groove_1 | Sax melody, sub reinforcement |
| 64 | 2:16 | break_1 | Drums out, kalimba over the choir |
| 72 | 2:33 | groove_2 | Full groove, 24 bars |
| 96 | 3:24 | bridge | Relative-minor progression, drums out |
| 112 | 3:58 | groove_3 | Biggest section, bridge harmony under full groove |
| 136 | 4:49 | break_2 | Stripped to piano and choir |
| 144 | 5:06 | outro | Groove returns, then peels apart bar by bar |

Holding the log drum back until **1:08** is the most important decision here.
The genre's payoff is that entrance, and it only works if the listener has
spent real time without it.

## Instruments

Everything is synthesised, but each voice is modelled on the real instrument
these records use:

| Voice | Method |
|---|---|
| Log drum | Pitch-bent sine + 2nd/3rd harmonics, saturated, long tail |
| Kick | Sine, 128 Hz → 48 Hz drop; soft but bold |
| Acoustic piano | Inharmonic partials (stiff-string model), per-partial decay, hammer noise |
| Saxophone | Formant-weighted reed harmonics, breath noise, vibrato that opens as the note holds |
| Choir | Formant-synthesised /a/ vowel, three detuned voices, breath |
| Strings | Four detuned saw stacks with slow bloom and vibrato |
| Congas | Pitched membrane with fast bend + skin slap, three tunings |
| Kalimba | FM at a 3.01 ratio, A major pentatonic |
| Bell / tambourine | Inharmonic partial stack / offset metallic noise bursts |

The **piano is the melodic centre** and the **choir is the spiritual one** — it
enters early and holds *through* the grooves rather than hooking on top of
them. If you add a vocal, that is the layer to duck.

## Mix

- Log drum and kick own the low end; the sub and pads duck under every kick.
- Piano, sax, choir and kalimba go through stereo delay into a synthetic plate;
  the log drum stays nearly dry so it keeps working as a bassline.
- Master: high shelf at 1.3 kHz, bell cut at 700 Hz (low-mid boxiness), bell
  cut at 115 Hz (where kick and log drum pile up), low shelf for weight, glue
  saturation, soft-clip limit.

## Files

- `out/isibani.mp3` — full mix (committed)
- `out/isibani.wav` — 16-bit/44.1k
- `out/stems/*.wav` — 15 stems at mix levels
- `out/midi/isibani_full.mid` — all parts as separate tracks
- `out/midi/isibani_<part>.mid` — piano, sax, log, choir, pad, strings, kalimba, sub

WAV and stems are gitignored (large, regenerable); MP3 and MIDI are committed.

## A note on the render

Every frequency-domain filter runs a full-length FFT, and numpy is drastically
slower on lengths with large prime factors. At this tempo the natural buffer
length factors as `2² × 7 × 573007`, which sent every filter down a Bluestein
fallback path — the first render of this arrangement took over eleven minutes
and had not finished the master chain. Rounding the buffer up to the nearest
5-smooth length fixed it.

## Where to take it

A vocal is the obvious next move — the style is built around one, and the
bridge and both breaks are left open for it. The MIDI export is there so the
harmony can move into a DAW: a sampled grand, a real log drum one-shot and live
percussion will beat these synthesised voices, while the chords, groove and
arrangement carry over unchanged.

## Sources

Research that informed the rebuild:

- [How to Make Amapiano Music — BeatKey](https://beatkey.app/how-to-make-amapiano-music)
- [Beatmakers Guide: How to make an Amapiano Beat — RouteNote](http://create.routenote.com/blog/beatmakers-guide-how-to-make-an-amapiano-beat/)
- [Production Hacks: Creating Amapiano Tracks — Roland](https://articles.roland.com/production-hacks-creating-amapiano-tracks/)
- [What Is Amapiano? The Sound, Origins, and Production — Orphiq](https://orphiq.com/resources/what-is-amapiano)
- [Amapiano Production: How the Log Drum Sound is Created](https://www.inspiredbybeatz.com/en/amapiano-production-how-the-log-drum-sound-is-created/)
- [Kabza De Small — KOA II Part 1 (The Native)](https://thenativemag.com/kabza-de-small-koa-ii-part-1-essentials/)
- [Kabza De Small: The King of Amapiano and South Africa's Soul](https://blackpimpernel.com/kabza-de-small-king-of-amapiano/)
- [BPM/key for "Imithandazo" — Tunebat](https://tunebat.com/Info/Imithandazo-feat-Young-Stunna-DJ-Maphorisa-Sizwe-Alakine-Umthakathi-Kush-Kabza-De-Small-Mthunzi-DJ-Maphorisa-Young-Stunna-Sizwe-Alakine-Umthakathi-Kush/6Kijtp0DB6VwcoJIw7PJ9W)
