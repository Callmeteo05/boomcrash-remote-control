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

## Broker compatibility

The engine reads nothing from a hardcoded list. Every number it needs comes from the
symbol's own specification in your terminal, so it runs on **any MT5 broker** —
Weltrade, Deriv, JustMarkets, IC Markets, whoever — on any instrument they list.

On attach it prints a spec line to the Experts tab:

```
ApexICT spec | EURUSD.m | digits 5 | point 0.00001 | tick size 0.00001 |
tick value(loss) 1.00000 | stops level 0 | freeze 0 | spread 12
```

Check that line first on an unfamiliar broker. It is exactly what the risk engine is
working from, and it warns you if the symbol reports no tick value (lot suggestion will
read 0) or has trading disabled for your account.

### Two things to know per broker

**Symbol suffixes are handled.** Brokers append their own tags — `EURUSD.m`,
`AUDCHF.m`, `US100.s`. Detection uses substring matching, so a suffix never breaks it.

**Boom / Crash / Step are Deriv-proprietary instruments.** If your broker does not list
them, the synthetic layer simply stays off and the structure engine runs normally on
forex, metals, indices and crypto. If a broker lists equivalent spike instruments under
different names, set `Synthetic handling` to `Force Boom` or `Force Crash` rather than
relying on auto-detect.

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
| `Synthetic handling` | Auto / Off / Force up / Force down / **Measured** (ignore the name, read the bars) |
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

Auto-detected from the symbol name, across both naming conventions. Full sources and
confidence levels are in [`docs/BROKER_RESEARCH.md`](../docs/BROKER_RESEARCH.md).

| Family | Broker | Behaviour | Engine treatment |
|---|---|---|---|
| **Crash** | Deriv | grinds up, drops sharply | shorts score `+bias`, longs `-` |
| **Boom** | Deriv | drifts down, spikes up | longs score `+bias`, shorts `-` |
| **Step Index** | Deriv | fixed-step random walk | scored **down 15**, flagged |
| **PainX** 400-1200 | Weltrade SyntX | gradual rise, sharp drops | shorts score `+bias` |
| **GainX** 400-1200 | Weltrade SyntX | steady decline, sudden spikes up | longs score `+bias` |
| **FlipX** 1-5 | Weltrade SyntX | 50/50 each tick, random walk | scored **down 15**, flagged |
| **SwitchX** | Weltrade SyntX | alternates mode after every jump | next jump = opposite of last |
| **BreakX** | Weltrade SyntX | flips only on a breach of the prior jump | mode state machine |
| **TrendX** | Weltrade SyntX | follows momentum of the last two jumps | mode state machine |
| **FX Vol / SFX Vol** | Weltrade SyntX | no spike mechanic | structure engine only |

### The number in the symbol means opposite things

`Crash 1000` = one spike per ~1000 ticks. `PainX 400` = **400% leverage** — a 0.01 price
jump moves 4 points. Same-looking number, unrelated meaning. **The engine derives
nothing from the number**, only from the family name. Volatility differences are already
captured by ATR, which is what the risk engine actually uses.

### The engine checks its own assumption

The PainX/GainX spike directions above are documented at *medium-high* confidence —
Weltrade's own pages are unreachable from the build environment, so they come from
secondary sources. Rather than encode that as a silent constant, the engine counts
observed up-spikes and down-spikes and prints a warning if the data disagrees:

```
ApexICT WARNING: PainX is assumed to spike down, but the bars show
41 up-spikes and 6 down-spikes. Set 'Synthetic handling' to Measured...
```

The counts are always shown on the panel as `[spikes up 6 / down 41]`. If you ever see
that warning, set `Synthetic handling` to **Measured** and the engine ignores the name
entirely, taking the bias from the bars.

### Mode-switching instruments score their own model

`SwitchX`, `BreakX` and `TrendX` change mode by design, each by a different documented
rule, so each gets its own state machine rather than a fixed bias:

- **SwitchX** — alternates after every jump, so the next jump is the opposite of the last
- **BreakX** — mode persists and flips only when a jump breaches the previous jump's extreme
- **TrendX** — compares the extremes of the last two jumps and follows that momentum

Those rules come from Weltrade's descriptions at *medium* confidence — the fine print
(what exactly counts as a jump, whether "price level" means origin or extreme) is not
published anywhere reachable. So the state machine **records its prediction before each
jump and scores it against what actually happens**:

```
SwitchX: next jump DOWN  model 78% (32/41)  [spikes up 19 / down 22]
```

If that rate sits near 50% the panel says so outright —
`<< NO BETTER THAN A COIN, IGNORE THE BIAS` — and you should set `Synthetic handling` to
`Off` and trade the structure alone on that instrument. An unverifiable assumption
becomes a number you can watch.

### Drip or spike — pick your side

On any spike instrument there are two opposite trades, and the engine cannot guess which
you want:

- **Spike catch** (default) — trade the jump. Low hit rate, small stop, large R.
- **Drip** — trade the grind between jumps. High hit rate, small target, tail risk that
  one jump erases many wins.
- **Both** — no directional preference; structure alone decides.

Set this with `Which side of the spike cycle to trade`. It flips which direction earns
the grade bonus, so the engine works *with* your style instead of fighting half your
trades.

Killzones, sessions and SMT are deliberately absent for all synthetics — they describe
human market structure that algorithmic series do not have.

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
