# Apex ICT Engine — Design Document

MT5 (MQL5) indicator + optional execution EA. Works on any symbol and any timeframe
available in the terminal. Chart output mirrors a clean arrow system: BUY / SELL arrow,
entry line, SL band, TP labels — but every level is derived, never fixed.

---

## 0. Design principles

1. **Non-repainting is a mechanical property, not a label.** Every signal is computed
   from bar `[1]` and older, emitted on bar close, and written to a journal at emit time.
   Nothing already drawn on the chart is ever moved or deleted.
2. **No fixed pip values anywhere.** SL and TP are derived from structure, the swept
   wick, ATR and spread, per symbol. A 10-pip stop on Crash 1000 is not a stop.
3. **Graded output, not binary.** A+/A/B tiers so the tool prints setups daily without
   being so strict it goes silent, and the trader chooses their own threshold.
4. **Every signal carries its reason.** A plain-English string: what was swept, which
   array was entered, where the draw on liquidity is.
5. **Provable performance.** Built-in journal + stats panel + a non-repaint self-audit.

---

## 1. Market Structure Engine

Two-tier structure, which is what separates a real structure engine from a fractal toy.

- **Swing structure** (major) — sets bias and the dealing range.
- **Internal structure** (minor) — sets entries inside that range.

Detection:
- Swing points confirmed by an N-bar fractal, but a swing is only *published* once
  confirmed. It anchors backward to its true bar; it never relocates afterwards.
- **BOS** — close beyond the last confirmed swing *in the direction of the current leg*
  = continuation.
- **CHoCH** — first break against the prevailing leg = potential reversal.
- **MSS** — a CHoCH that comes with **displacement** (candle/leg range >= k x ATR) and
  leaves an FVG behind. A CHoCH without displacement is noise and is labelled as such.
- Configurable break definition: body close vs wick. Default: body close.

Output per timeframe: `trend ∈ {bullish, bearish, ranging}`, last BOS/CHoCH/MSS with
time and price, current leg origin.

---

## 2. Daily Bias Engine

Bias is a composite score in `[-100, +100]`, not a single moving average.

Inputs:
- **Draw on Liquidity (DOL)** — nearest untapped pool: PDH/PDL, PWH/PWL, equal
  highs/lows, prior session high/low, old unmitigated daily wicks.
- **HTF PD array in play** — which daily/weekly FVG, OB or breaker price is currently
  reacting to.
- **Midnight NY open** — price above = day trading in premium, below = discount.
- **Previous day's close** relative to previous day's range.
- **SMT divergence** vs a correlated symbol (EURUSD/DXY, US100/US30, AUDCHF/AUDJPY).
  Multi-symbol data pulled directly in MQL5. This is one of the strongest bias tools
  that almost no retail indicator implements.
- **Weekly profile** — which day of week, and where in the weekly range price sits.

Output: `Bullish 74 — took Asia low 03:12, D1 in discount, DOL = PDH 1.0842, SMT
confirmed vs DXY`.

---

## 3. Premium / Discount (real)

Not "50% of the visible chart".

- Anchored to the **dealing range**: the confirmed swing low → swing high that price is
  currently trading inside, on the selected bias timeframe.
- Equilibrium = 50%. Premium above, discount below.
- **OTE band** = 62%–79% retracement (0.618 / 0.705 / 0.79) shaded on chart.
- Longs only from discount, shorts only from premium — unless it is a continuation
  entry into an aligned HTF PD array.
- **Standard deviation projections** (-1, -2, -2.5, -4) off the manipulation leg, which
  is where real ICT profit targets come from.

---

## 4. PD Array Inventory

Every array is tracked with state, age and HTF alignment.

- **FVG / BISI / SIBI** — with mitigation state (untouched / partial / consumed) and
  **inversion FVG** handling when one fails and flips polarity.
- **Order Blocks** — the last opposing candle before displacement, *validated only if*
  it caused a BOS and left an FVG. This filter removes the ~90% of junk order blocks
  that other indicators paint.
- **Breaker Blocks** — a failed OB that price traded through and now returns to.
- **Rejection blocks, volume imbalance, opening gaps.**
- **Liquidity pools** — equal highs/lows within an ATR tolerance, PDH/PDL, PWH/PWL,
  session highs/lows, trendline liquidity.

Arrays overlapping across timeframes stack into a **confluence count** used by scoring.

---

## 5. Time Engine (killzones)

- Asia range, London KZ, NY AM KZ, Lunch, NY PM, and the three **Silver Bullet**
  windows.
- Computed in **New York time with correct DST**, then translated to broker server time
  via an auto-detected offset — broker offsets shift twice a year and this is the single
  most common bug in ICT indicators.
- Killzones are a **weight**, not a hard block, so the tool does not go silent outside
  them.
- Not applied to synthetic indices, which have no sessions (see §6.7).

---

## 6. Setup Models

Each named model has its own trigger, SL and TP logic. Toggle individually.

1. **Sweep → MSS → FVG** (primary): liquidity pool taken, displacement reverses and
   breaks internal structure, entry on the retrace into the FVG/OB that displacement left.
2. **OTE continuation**: with HTF bias, retracement into 62–79% overlapping a PD array.
3. **Silver Bullet**: within the SB hour, first FVG after a sweep, targeting opposing liquidity.
4. **Turtle Soup**: false break of a prior high/low with immediate reclaim.
5. **Breaker retest continuation.**
6. **Power of 3 / AMD**: Asia accumulation → judas swing at London/NY open → reversal entry.
7. **Synthetic model** (Boom / Crash / Step): sessions and liquidity raids do not exist
   on algorithmically generated series, so these get a separate spike-cycle engine —
   ticks-since-last-spike hazard estimate, spike detection at range > k x ATR, and two
   distinct sub-modes: **drip** (trade with the grind, high hit rate, small target) and
   **spike** (catch the spike, low hit rate, large R). Step Index is a fixed-step random
   walk with no trend edge; the engine will say so rather than invent signals.

---

## 7. Scoring & Grading

Confluence points from: HTF bias alignment, correct premium/discount side, killzone,
liquidity swept before entry, displacement quality, FVG cleanliness, SMT divergence,
R:R to the draw on liquidity, absence of an opposing HTF array in the path.

- **A+** ≥ 85 — **A** 70–84 — **B** 55–69.

The trader sets the minimum grade to display and to alert on. This is the direct answer
to "print setups every day but don't be too tight."

---

## 8. Risk Engine (SL / TP)

- **SL** — beyond the swept wick or the origin of the entry array, plus
  `spread x k + ATR buffer`. Per symbol, never a fixed pip count.
- **TP1** — nearest opposing liquidity pool, or the -1 SD projection.
- **TP2** — the draw on liquidity itself.
- **TP3** — -2 / -2.5 SD extension.
- **Minimum R:R filter** — reject setups below the configured threshold (default 1:2.5).
- **Auto lot sizing** for a chosen risk %, using exact per-symbol tick value.
- **Management plan**: partial at TP1, break-even move, then trail behind each newly
  confirmed swing.

---

## 9. Alerts — on time, not early, not late

The "too early / too late" problem is solved by splitting alerts into two classes:

- **WATCH** — a valid zone has formed and price is approaching it (N x ATR away).
  Gives advance warning without any repaint risk.
- **TRIGGER** — entry conditions confirmed **on the close of the entry-timeframe bar**.
  This is the tradeable alert. Never fires mid-bar.
- Optional intrabar trigger mode for scalping, explicitly labelled as provisional
  until bar close.

Channels: MT5 popup, phone push notification, email, Telegram bot (WebRequest),
plus the CSV/JSON journal.

---

## 10. Journal & Proof

- Every signal appended at emit time: timestamp, symbol, TF, model, grade, entry, SL,
  TP1–3, reason string.
- **Stats panel**: win rate, average R, profit factor, expectancy, max drawdown —
  broken down per model, per symbol, per session, per grade.
- **Non-repaint self-audit**: recompute history and diff against the live journal; any
  mismatch is reported on the chart. A testable claim rather than a sticker.

---

## 11. Dashboard

Multi-symbol / multi-timeframe scanner grid: bias, armed model, grade, distance to
entry, R:R. Click a cell to open that chart.

---

## 12. Repo integration

`config.json` already carries `ea_status`, `mode`, `hedging` — wire the remote control in:

- `ea_status: ON/OFF` — arms or disarms the execution EA.
- `mode: CALM/AGGRESSIVE` — maps to the minimum signal grade (CALM = A+ only).
- `hedging` — whether opposite-direction positions may be held simultaneously.

The indicator writes signals to a JSON file; the EA reads and executes them when armed.

---

## 13. Build order

1. Structure engine + non-repaint harness + journal (the foundation everything rests on).
2. Dealing range, premium/discount, OTE, SD projections.
3. PD array inventory (FVG, OB, breaker, liquidity pools).
4. Daily bias engine + SMT.
5. Model #1 (Sweep → MSS → FVG) end to end with risk engine and chart visuals.
6. Alerts (WATCH / TRIGGER) + Telegram.
7. Remaining models.
8. Stats panel + dashboard.
9. EA + config.json remote control.

---

## 14. Decisions (locked)

| Question | Decision |
|---|---|
| Primary market | Synthetics first: Boom / Crash / Step (Deriv) |
| Style | All three presets selectable: Scalp / Intraday / Swing |
| Scope | Indicator + alerts (MT5 popup, push, Telegram). No auto-execution in v1 |
| First model | Sweep -> MSS -> FVG |

### 14.1 What changes for synthetics

Synthetic indices are algorithmically generated. They have no sessions, no news, no
correlated instruments and no institutional order flow. So:

**Disabled on synthetics**
- Killzones / Silver Bullet windows / Power of 3 (no sessions exist)
- SMT divergence (no correlated series)
- PDH/PDL treated as "liquidity pools" in the stop-run sense

**Still valid on synthetics** (these are pure price geometry and transfer cleanly)
- Swing structure, BOS / CHoCH / MSS with displacement
- Fair value gaps — spikes leave very large, very clean ones
- Dealing-range premium / discount, equilibrium, OTE
- Equal highs / lows as resting-order clusters
- Nearest opposing swing as the realistic profit target

**Added for synthetics**
- **Spike detection**: bar range >= k x ATR in the instrument's spike direction.
- **Directional asymmetry**: Crash spikes down and grinds up; Boom spikes up and grinds
  down. The engine auto-detects this from the symbol name and scores with the
  asymmetry rather than against it. A symmetric indicator on Boom/Crash is simply wrong.
- **Two sub-modes** — *drip* (trade the grind: high hit rate, small target, tail risk)
  and *spike* (catch the spike: low hit rate, small stop, large R, positive skew).
- **Spike-cycle hazard estimator**: Deriv documents "one spike on average every 1000
  ticks". If that arrival process is memoryless, ticks-since-last-spike carries **no**
  predictive information and any indicator claiming otherwise is selling a myth. So the
  engine *measures* the empirical hazard from collected data and reports whether the
  edge exists, instead of assuming it. If the hazard is flat, it says so.

### 14.2 Style presets

Presets set the bias/entry timeframe pair and the structure lookbacks. On synthetics
they are additionally calibrated in **ticks**, not clock time, because spike frequency
is defined per tick and does not care what the candle duration is.

| Preset | Bias TF | Entry TF | Expected frequency |
|---|---|---|---|
| Scalp | M15 | M1 / M5 | many per day |
| Intraday | H4 | M15 | 1-3 per day per symbol |
| Swing | D1/W1 | H4 | a few per week |

### 14.3 Alert timing contract

- **WATCH** — setup armed, entry zone published, price approaching. Zero repaint risk.
- **TRIGGER** — entry conditions met on the **close** of the entry-timeframe bar. Never
  mid-bar. This is the tradeable alert.
