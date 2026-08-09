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

## Why it works on any symbol and any timeframe

Nothing in the engine is expressed in pips, and nothing is tuned to one instrument:

- **Every distance is ATR-relative.** Displacement, gap size, stop buffer and arrow
  offset are all multiples of the ATR *of the chart you attached to*. The same settings
  therefore mean the same thing on Crash 1000 H1 and on AUDCHF M5.
- **Structure is scale-free.** Swings, sweeps, BOS/CHoCH and FVGs are geometric
  relationships between bars. They carry no units at all.
- **Levels are snapped to the instrument's tick grid** via `SYMBOL_TRADE_TICK_SIZE`,
  not to `_Point`. Metals and synthetics do not always have tick size == point, and an
  off-grid level is one the server rejects.
- **Stops respect `SYMBOL_TRADE_STOPS_LEVEL` and the freeze level.** A structurally
  perfect stop that sits inside the broker's minimum distance is pushed out to the
  minimum. This is the difference between a level that looks right and a level you can
  actually submit.
- **Spread is priced in** through `SYMBOL_SPREAD` on the stop buffer, so wide-spread
  synthetics get proportionally more room.
- **Lot size comes from `SYMBOL_TRADE_TICK_VALUE`**, so the risk percent is correct in
  account currency on every instrument without a lookup table.
- **Timeframe independence is free**, because the engine only ever reads the bars it is
  given. Attach it to M1 and it reads M1 structure; attach it to D1 and it reads D1
  structure. The presets only change the lookback lengths.

The one thing that genuinely differs per instrument is spike behaviour, and that is
handled explicitly by the synthetic layer rather than being averaged away.

## Outcome tracking — the TP marks

Every emitted signal is followed forward bar by bar until it reaches TP2 or its stop.
When a target is reached, a `TP` mark is printed at that level on the bar that reached
it, and `SL` on a stop-out — which is what produces the labelled look of a classic arrow
system.

These marks are **results, not predictions**. They appear only after the bar that
produced them has closed, and they never move.

Accounting policy: a trade is scored as held to TP2 or the stop. If a single bar spans
both, it is recorded as **the loss** — the pessimistic reading, because bar data cannot
tell you which came first intrabar. The statistics are therefore a floor, not a
flattering estimate.

Because the engine is non-repainting, the statistics it computes over history are a
**genuine backtest** rather than hindsight: the logic that generated each historical
signal read only bars that had already closed at that moment.

The panel shows resolved count, win rate, expectancy in R, profit factor and TP1 hits,
updating live as trades resolve.

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

## Chart layout

The header block at the top left is fully editable through the inputs
(`Header line 1..4` and their colours), so the chart can carry whatever wording and
contact details you want.

Each signal prints: the arrow, the `BUY`/`SELL` word with its grade, a solid entry line
tagged `BUY 0.05 at 1.23456`, a red dotted stop line labelled `SL`, and dotted `TP1`,
`TP2`, `TP3` lines — plus the `TP` and `SL` outcome marks as they are reached. Set
`Shade the risk and reward zones` for filled zones instead of bare lines.

## Not built yet

Next in the build order:

- Spike-cycle hazard estimator (measure whether ticks-since-last-spike predicts anything)
- Remaining models: OTE continuation, Turtle Soup, breaker retest
- Per-grade and per-model breakdown of the statistics
- Multi-symbol dashboard
- Execution EA wired to `config.json` (`ea_status`, `mode`, `hedging`)
