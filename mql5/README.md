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
- The turn dot is drawn at a past bar, but written once after that bar closed and never
  moved. See *Where the dots are placed* — the turn dot is a confirmed turn, the entry
  dot is the tradeable price, and everything downstream uses the entry.

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

**Each broker has its own synthetic family.** Boom/Crash/Step are Deriv's; PainX, GainX,
FlipX, SwitchX, BreakX, TrendX, FX Vol and SFX Vol are Weltrade's SyntX. Both naming
schemes are recognised. On a broker whose synthetics use neither naming, the layer stays
off and the structure engine runs normally on forex, metals, indices and crypto — or set
`Synthetic handling` to `Force spikes-up` / `Force spikes-down` / `Measured` to enable it
manually.

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

## Confirmed entries and drawdown control

Two separate things reduce heat on a trade: **how it confirms**, and **how much you are
allowed to lose in a day**. Both are built in.

### Entry confirmation

| Mode | Behaviour |
|---|---|
| `Touch` | Fires the moment price reaches the zone — a resting limit order. Best price, but no evidence the zone is holding. This is where most of the heat on a trade comes from. |
| `Close` **(default)** | Waits for the bar to **close back out of the zone** in the trade's direction. You enter after the reaction has started rather than into it. |
| `Reject` | As above, plus the bar must be a genuine rejection candle — right-way body, close in the far third of its range. Strictest, fewest signals, least heat. |

**The fill is re-priced honestly.** With confirmation on you are filled at the confirming
bar's *close*, not at the zone — so that is what the engine records. R, TP1, TP3, the lot
size and every statistic are recomputed from the real fill. Pretending you got the zone
price would flatter every number below.

**Anti-chase.** If the confirming close has already run more than `Max chase R` past the
zone (default 0.35R), the good price is gone and what remains is a worse trade wearing
the same setup's clothes. It is rejected, and counted as `chase` in the diagnostics. The
draw is also re-checked from the real fill, so a setup whose reward no longer clears
`Min RR` after confirmation is dropped rather than taken.

### Daily budget

- **Max signals per day** (default 3) — over-trading is a drawdown source in its own right.
- **Daily loss limit** (default 2R) — once the day is down that much, the engine stops
  producing signals until tomorrow.

Both reset on your calendar day, in your timezone. The panel shows
`today 2/3 trades +1.4R`, and `DONE FOR TODAY` once the budget is spent.

### Heat — the number that proves it

Every trade is followed bar by bar and its worst adverse excursion recorded. The panel
reports it in R:

```
heat 0.42R (winners 0.31R)
```

That reads: the average trade goes 0.42R against you before resolving, and trades that
eventually won only ever went 0.31R against you.

**Winners' heat is the number to tune your stop against.** If it settles at 0.31R, a stop
at 1R is carrying roughly three times the risk the winning trades actually needed — you
can tighten it, or size up, on evidence instead of feel. If it climbs toward 1R, entries
are not refined and the confirmation mode should go stricter.

## Your trading session

Set your window once — defaults are **08:00–12:00 at UTC+2** — and the engine works
around it.

**The broker clock is auto-detected.** Bar times in MT5 are broker server time, which is
almost never yours: most brokers run EET, some run UTC. Getting that wrong shifts the
whole window by hours, and it is the single most common bug in session filters. The
offset is read from the terminal, not assumed, and printed on attach:

```
ApexICT session | your window 08:00-12:00 at UTC+2 | broker clock detected as UTC+3
                | check this line if the window looks shifted
```

Override it with `Broker UTC offset` if that reads wrong.

What the window gives you:

- **A briefing when it opens.** On the first closed bar inside your window each day, one
  push notification summarises the state so you do not have to reconstruct it:
  `SESSION window open | structure bullish | EMA up | 31% of range (discount - longs
  favoured) | 2 armed | nearest: BUY A+ @ 7947.60`
- **Grade points** for setups inside the window, so in-session setups outrank identical
  ones at 3am.
- **A hard filter**, off by default. Turn on `Show setups ONLY inside the window` if you
  want the chart to contain nothing else.
- **Shading** on the chart so you can see at a glance which bars your window covered.

### Does your window actually perform better?

Once there are at least 5 resolved trades on each side, the panel compares them:

```
in-session 61% (23)  vs  outside 58% (41)
```

This matters most on synthetics, and it is worth being blunt about: **Boom, Crash, PainX,
GainX and the rest are generated by an algorithm that has no idea what time it is.** On
those instruments a session window is a convenience — it shows you setups while you are
at the desk — not an edge. On real markets, 08:00 UTC+2 sits at the London open, where
volume and liquidity raids genuinely cluster, and there the window is a real edge.

Rather than assert either, the engine measures it. If the two numbers stay close on your
instruments, the window is organising your day, not improving your odds — and you should
know which.

## Seeing past dots — how much history you get

Dots print across **all analysed history**, not just recent bars. They are buffer plots,
so thousands of them cost nothing.

Three settings control how far back that goes, and one of them is not in this indicator:

| Setting | Where | Effect |
|---|---|---|
| `Bars of history to analyse` | indicator inputs, default **5000** | how far back the engine runs. Set **0** for everything available. |
| **Max bars in chart** | MT5 → Tools → Options → Charts | the hard ceiling. If this is set to 5000, no indicator can see more. Set it to *Unlimited* if history looks short. |
| `Draw SL/TP lines only on the last x bars` | indicator inputs, default **800** | dots and BUY/SELL labels always print for all history; the full entry/SL/TP line set is drawn only on recent bars |

That last one matters for speed. One signal is about ten chart objects — a few hundred
historical signals means thousands of objects and a chart that crawls. The dots carry the
history; the lines only need to be readable where you are actually trading.

If you want the complete picture, set `Bars of history` to 0 and
`Draw SL/TP lines` to 0 — just expect the chart to be slower.

### The daily budget shapes history too

By default the 3-trades-a-day and −2R limits are applied to history as well, so the dots
you see are the trades you would actually have been **allowed** to take, not every setup
the strategy ever found. That keeps the win rate on the panel honest.

Turn off `Apply the daily budget to history too` to see every setup the strategy located,
which is useful for judging the raw strategy — but then the statistics describe a version
of you with no discipline limits.

## Seeing what is armed right now

A dot only prints once a bar closes into the entry. Before that, a setup can be fully
built and simply waiting for price — and you want to know that *before* it fires, not
after.

Top right of the chart, always in the same place:

```
2 ARMED | nearest BUY A+ @ 7947.60  (0.4 ATR away)
```

and on the chart itself, each armed setup draws a dashed entry line and a dotted stop,
rayed to the right edge, labelled:

```
  BUY A+ ARMED - 0.4 ATR away, 12 bars left, 3.2R
```

So one glance tells you: how many setups are live, which is closest to triggering, how
far price has to travel, how long before it expires, and what it pays.

**These are the only objects on the chart that move.** They have to — an armed setup
either fills, expires or is invalidated. They are drawn dashed and in their own colours
so they can never be mistaken for a confirmed signal. Nothing here is a signal yet: the
dot, the alert and the journal entry all wait for a bar to close into the entry.

If you would rather work purely from alerts, the **WATCH** alert fires the moment price
comes within 1.5 ATR of an armed entry, and `Draw setups that are armed and waiting`
turns the visuals off.

## Too few signals? Read the diagnostics line

The signal chain is a long AND: sweep, then displacement, then a gap, then room to the
draw, then grade. Any one link can silently eat everything, and "the indicator prints
nothing" is not a useful diagnosis. So every rejection is counted by stage and shown
under the panel:

```
candidates rejected 812  [sweep 640 | disp 92 | fvg 61 | RR 14 | PD 0 | spike 5 | grade 0]
   armed 23  expired 9  stopped-pre-entry 4   biggest blocker: no sweep
```

Read the blocker, then loosen that one input rather than everything at once:

| Biggest blocker | Loosen this |
|---|---|
| `no sweep` | raise `Sweep scan depth` (3 → 5) or `Reclaim bars` (2 → 3), or lower the preset's swing lookback |
| `against the EMA trend` | switch the EMA filter to score-only, or shorten the periods |
| `displacement too weak` | lower `Displacement ATR` (1.5 → 1.2) |
| `no FVG in the impulse` | lower `Min FVG ATR` (0.15 → 0.08) or raise `MSS grace bars` |
| `draw too close (Min RR)` | lower `Min RR` (2.0 → 1.5) |
| `below minimum grade` | drop `Minimum grade` to `B and better` |
| `outside your session window` | turn off `Show setups ONLY inside the window` — it stays a scoring bonus |
| high `expired` | raise `MSS valid bars`, or use `FVG near edge` entry so it fills more often |

## Key inputs

| Input | Effect |
|---|---|
| `Preset` | Scalp / Intraday / Swing / Custom — sets structure lookbacks and displacement |
| `Minimum grade` | `B and better` (most signals) → `A+ only` (fewest). Your tightness dial |
| `Entry mode` | FVG near edge (fills most) / 50% CE (default) / far edge (best price) |
| `Min RR` | Rejects a setup when the nearest opposing pool is closer than this in R |
| `Require discount` | Hard-blocks longs in premium and shorts in discount |
| `Synthetic handling` | Auto / Off / Force up / Force down / **Measured** (ignore the name, read the bars) |
| `Spike cycle style` | **Spike catch** (default) / Drip / Both — which side of the cycle you trade |
| `Spike ATR` | Bar range that counts as a jump |

## EMA trend filter

Advanced ICT sets *where* — the sweep, the shift, the gap, the premium/discount side.
The EMA sets *whether the tide is with you*.

- Fast/slow EMA (default **21/50**) computed inline from the chart's own bars — one
  multiply per bar, no indicator handle to fall out of sync, so it stays fast on any
  timeframe.
- Trend is called only when the stack agrees **and** price sits on the same side of the
  fast line. Requiring both removes the chop a bare crossover produces.
- Two ways it acts: a **hard filter** (default on) that refuses any signal taken into
  the trend's teeth, and a **score component** worth up to 15 points that scales with
  how cleanly the two lines are separated in ATR — a wide stack is a stronger trend
  than a tangle.

Turn the hard filter off if you want counter-trend reversals at range extremes; leave it
on for trend continuation only.

## Where the dots are placed — read this once

Two dots print per signal, and they mean different things. This is deliberate — the pair
gives you the clean look of a classic signal chart *and* the truth, side by side.

**Turn dot** — small, dim, sits on the bar that actually made the high or low. That is
the picture those flawless screenshots show. It is written once, after that bar closed,
and never moved, so nothing repaints. But it *appears* several bars later, because a
swing low is not knowable at the swing low — you only know it was the low once enough
bars have passed without a lower one. It marks a **confirmed turn**.

**Entry dot** — large, bright, sits on the bar whose close filled the entry. That is the
price that was genuinely takeable in real time, and it is what the **alert, the journal
and every statistic** are driven by.

The gap between the two dots is the honest cost of non-repainting, drawn on the chart
where you can see it instead of hidden. A tool showing only the turn dot is showing you
the first without the second.

`Dot anchor` switches to either one alone if you prefer a cleaner chart.

The location logic is the ICT stack, not decoration:

- **Buy dots only form in discount, sell dots only in premium** (hard filter, default
  on) — measured against the live dealing range, not the visible chart
- the swept wick sets the stop, so the dot always sits above its own invalidation
- the nearest opposing liquidity pool sets TP2, and a setup is rejected outright if that
  pool is closer than `Min RR`
- the EMA trend must not oppose the direction

## Grading

Scoring is **continuous, with no free base score**. Every point is earned by a measured
property, and each component scales with how good it actually is rather than stepping
over a threshold — so a mediocre setup cannot coast to a passing grade on the strength
of the pattern merely existing.

| Component | Max | Earned by |
|---|---|---|
| Structure alignment | 25 | major trend agrees (18), both tiers agree (+7) |
| EMA trend | 15 | 21/50 stack aligned, scaling with separation in ATR |
| Premium / discount | 15 | scales with how deep into the correct half the entry sits |
| Displacement | 20 | saturates at twice the required strength |
| Gap quality | 12 | scales with FVG size in ATR |
| Room to the draw | 15 | scales with R:R to the nearest opposing pool, saturating at 4R |
| Sweep decisiveness | 8 | how far past the level the wick actually reached |
| Level age | 5 | how long the taken level had been resting |
| Spike-cycle side | ±10 | trading with or against your chosen side |

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
