# Apex ICT Engine — v1 (MT5)

`Indicators/ApexICT_Engine.mq5`

Model v1: **Liquidity Sweep → Market Structure Shift → Fair Value Gap**, with
structure-derived stops and targets, graded setups, and split WATCH / TRIGGER alerts.

---

## Install

1. In MT5: **File → Open Data Folder**
2. Copy `ApexICT_Engine.mq5` into `MQL5/Indicators/`
3. In MetaEditor press **F7** to compile
4. Back in MT5, drag **Apex ICT Engine** onto a chart

For Telegram alerts, add `https://api.telegram.org` under
**Tools → Options → Expert Advisors → Allow WebRequest for listed URL**.

> This file has not been compiled — MetaEditor is Windows-only and this was written on
> Linux. Compile it and send me any errors or warnings and I will fix them.

---

## How a signal is produced

1. **Sweep** — price wicks through a confirmed major swing and closes back on the
   original side. The wick extreme becomes the stop reference.
2. **Shift** — internal structure breaks in the opposite direction, and price has
   travelled at least `Displacement × ATR` away from that swept wick.
3. **Gap** — the impulse must have left an unmitigated FVG. No gap, no setup.
4. **Arm** — entry is placed inside that gap (default: 50%, consequent encroachment).
   A **WATCH** alert fires when price comes within 1.5 ATR of it.
5. **Trigger** — when a closed bar trades into the entry, the arrow prints and the
   **TRIGGER** alert fires with entry, SL, TP1–TP3 and a suggested lot size.

A setup is discarded if the stop is taken before the entry fills, or if it is not
filled within `MSS valid bars`.

---

## Non-repaint guarantees

These are properties of the code, not a claim on a banner:

- The loop runs to `rates_total - 2`. **The live bar is never read.**
- A swing is published only once its `lookback` confirmation bars have closed, and it
  anchors to its true bar. Nothing already drawn moves.
- A structure break inside the confirmation window is impossible by construction — a
  valid swing high requires every high in that window to be lower than it, so no close
  in that window can exceed it. **The confirmation lag hides no breaks.**
- Each bar is analysed exactly once, guarded by timestamp, so MT5's per-tick overlap
  bar cannot duplicate swings, gaps or signals.
- The journal records **live signals only**. History rows are deliberately excluded, so
  the CSV can be diffed against a recalculated chart as an actual non-repaint audit.

The honest cost: signals arrive with a structural confirmation lag. That lag is what
buys the non-repainting. Any tool without it is choosing to lie to you instead.

---

## Key inputs

| Input | Effect |
|---|---|
| `Preset` | Scalp / Intraday / Swing / Custom — sets structure lookbacks and displacement |
| `Minimum grade` | `B and better` (most signals) → `A+ only` (fewest). Your tightness dial |
| `Entry mode` | FVG near edge (fills most) / 50% CE (default) / far edge (best price) |
| `Min RR` | Rejects a setup when the nearest opposing pool is closer than this in R |
| `Require discount` | Hard-blocks longs in premium and shorts in discount |
| `Synthetic handling` | Auto-detects Boom / Crash / Step from the symbol name |
| `Spike ATR` | Bar range that counts as a Boom/Crash spike |

## Grading

Points accumulate from: HTF trend alignment, premium/discount side, displacement
strength, gap cleanliness, room to the draw, age of the swept level, and — on
synthetics — whether the trade runs with or against the instrument's spike direction.

**A+ ≥ 85 · A ≥ 70 · B ≥ 55.** Below 55 is discarded.

Every signal carries a reason string into the alert and the journal, e.g.
`HTF trend aligned; entry in discount; strong displacement; clean FVG; 3.2R to draw;`

---

## Synthetic indices

Auto-detected from the symbol name:

- **Crash** — spikes down, grinds up. Shorts score `+Synth bias score`, longs score `-`.
- **Boom** — spikes up, grinds down. Mirror image.
- **Step Index** — a fixed-step random walk with equal up/down probability. Directional
  setups are scored **down by 15** and flagged on the panel, because no directional edge
  exists in that series. The engine says so rather than inventing signals.

Killzones, sessions and SMT are deliberately absent here — they describe human market
structure that algorithmic series do not have.

---

## Not built yet

Next in the build order:

- Spike-cycle hazard estimator (measure whether ticks-since-last-spike predicts anything)
- Remaining models: OTE continuation, Turtle Soup, breaker retest
- Stats panel: win rate, expectancy, profit factor per grade and per model
- Multi-symbol dashboard
- Execution EA wired to `config.json` (`ea_status`, `mode`, `hedging`)
