# CRT Sniper Pro

A graded buy/sell dot indicator built on **Candle Range Theory**, with a dedicated
**spike engine** for Boom, Crash, GainX and PainX that trades *with* the spike and
*against* it at the same time.

Every dot carries a 0–100 confluence score and a letter grade, so you know how much
the setup is worth before you click. The indicator also forward-tests its own
signals across your history and shows the resulting win rate, average R and profit
factor live on the dashboard.

| Platform | File |
| --- | --- |
| MetaTrader 5 | `MT5/Indicators/CRT_Sniper_Pro.mq5` |
| TradingView | `TradingView/CRT_Sniper_Pro.pine` |

On the chart you only see **dots, their grade, SL/TP lines, and the dashboard**.
Every EMA, ADX, swing, gap, channel and range used to produce a signal stays hidden.

---

## Three engines, one chart

| Engine | Direction | When it fires | Character |
| --- | --- | --- | --- |
| **CRT** | with the higher-timeframe trend | anchor candle at a key level → raid → close back inside → MSS → retest | the core engine, runs on every market |
| **FADE** | *against* the spike, with the drift | a spike just printed and is giving back its range, and the next spike is not due | high win rate, small targets |
| **HUNT** | *with* the spike, against the drift | a spike is statistically overdue and price sits at the far edge of the drift channel | low win rate, spike-sized targets |

FADE and HUNT only arm on spike indices. On everything else, CRT is the whole
indicator. The engines are evaluated in that priority order on each bar, so they
never contradict each other on the same candle.

---

## Scalp, day trade, swing

One `Trading style` input reshapes the whole indicator. On **Auto** it reads your
chart timeframe: M1–M5 → Scalp, M6–H1 → Intraday, H2 and above → Swing. Set it
explicitly to override.

| | Scalp | Intraday | Swing |
| --- | --- | --- | --- |
| Chart | M1 – M5 | M15 – H1 | H4 – D1 |
| CRT anchor | one rung **down** (M5 → M30) | standard (M15 → H4) | one rung **up** (H4 → W1) |
| TP1 / TP2 | 1.2R / 2.0R | 2.0R / 3.5R | 2.5R / 5.0R |
| SL buffer | 0.20 × ATR | 0.30 × ATR | 0.50 × ATR |
| Setup expiry | 8 bars | 24 bars | 60 bars |
| Cooldown | 2 bars | 3 bars | 6 bars |
| Min score | 68 | 62 | 62 |
| Liquidity TP | off — take the money | on | on |
| Cost gate | TP1 ≥ 6 × spread | ≥ 4 × spread | ≥ 3 × spread |

The differences are not cosmetic:

- **The anchor moves with the style.** A scalper anchoring CRT on the daily would
  wait days for a setup; a swing trader anchoring on H1 would get chopped to pieces.
  Shifting the anchor a rung in each direction is what makes the same sequence fit
  three horizons.
- **Targets match holding time.** Scalp takes 1.2R and disables the liquidity
  stretch, because reaching for a distant pool is how a scalp turns into a loss.
  Swing pushes to 5R and keeps it, because that stretch is the whole point of
  holding for days.
- **Patience matches horizon.** An 8-bar expiry on a scalp kills a stale setup fast.
  60 bars on swing lets a daily retest breathe.
- **Stops widen with the timeframe** — 0.20 × ATR would be inside the noise on D1;
  0.50 × ATR would be an unacceptable scalping cost.

### The cost gate

New, and the reason "it can scalp" is now an honest claim rather than a marketing
one. Before any dot prints, the indicator checks:

```
|TP1 - entry|  >=  minTpSpreadX  x  current spread
```

Scalping on M1 with a 1.2R target means the target may only be a few points wide.
If your broker's spread is a meaningful fraction of that, the setup has no edge left
no matter how good the structure looks. Signals that fail this test are dropped and
counted — the dashboard's `Cost gate` row shows how many, so you can see whether
your broker's spread is quietly deleting your scalping signals.

One honest limitation: MT5 does not expose historical spread, so the gate is
evaluated with the **live** spread and applied to history too. Set
`Override: TP1 must be >= this x spread` manually if you want to test against a
different assumption. On TradingView there is no spread data at all, so you enter
`Assumed spread in ticks` yourself; leave it at 0 to disable the gate.

### Spike engines and style

HUNT and FADE now require **at least 5 bars between spikes on average**, measured
from your feed. On an H4 Boom chart a spike is a single candle with nothing around
it — there is no interval to model and no exhaustion to read, so the spike engines
switch themselves off and CRT carries the chart. The dashboard says so directly.

Practically: **scalp and intraday the spike indices, swing them only with CRT.**

---

## The CRT sequence

Encoded step for step. Each step is a hard gate.

1. **Anchor on a higher timeframe.** The last *closed* HTF candle (auto-mapped:
   M15 → H4, H1/H4 → D1, D1 → W1). With `Anchor must sit on a key S/R level` on, the
   anchor's low must be at or below the lowest low of the previous 10 HTF candles
   for a bullish setup, or its high at or above the highest high for a bearish one —
   there has to be real liquidity resting there.
2. **Mark CRT-High and CRT-Low** — the anchor candle's high and low.
3. **Wait for the raid.** The next HTF candle must trade through the CRT-Low
   (bullish setup) or the CRT-High (bearish setup).
4. **Confirm the close.** The raiding candle must *close back inside* the range.
   Only closed HTF candles are ever read, which is what makes this non-repainting.
5. **Drop to the lower timeframe** — your chart timeframe.
6. **Look for an MSS.** A close through the last confirmed swing, with the leg into
   that break at least `1.2 × ATR`. A break without displacement is not an MSS.
7. **Enter on the retest.** Into the most recent fair value gap from the
   displacement leg; failing that the last opposing candle before the impulse
   (order block); failing that the broken MSS level. Price taps the zone and closes
   a confirming candlestick pattern.

### Gates on top of the sequence

- **HTF bias** — buys need the anchor timeframe reading BULLISH, sells BEARISH.
- **Premium / discount** — buys only at or below 50 % of the CRT range, sells only
  at or above 50 %. Optionally the HTF dealing range must agree too.
- **EMA 50/200** on the signal timeframe — Off / Soft / Strict.
- **Killzone** — optional Asia / London / New York filter (auto-disabled on 24/7
  symbols).
- **Cooldown** — a minimum bar gap per engine.

So by construction: a printed BUY means trend bullish **and** price in discount; a
printed SELL means trend bearish **and** price in premium.

### Bullish / bearish / sideways

```
separation = |EMA50 - EMA200|
trending   = ADX >= threshold  AND  separation >= minSep x ATR

BULLISH   trending AND EMA50 > EMA200 AND price > EMA200
BEARISH   trending AND EMA50 < EMA200 AND price < EMA200
SIDEWAYS  everything else
```

Both terms are measured in ATR, not points — that is what lets one settings file
work on EURUSD, XAUUSD, US30, BTC and Boom 1000 without retuning.

---

## The spike engine

### What it measures

The engine never assumes a fixed tick count. It measures your broker's actual feed:

- **Drift baseline** — the *median* bar range over the last 50 bars. A median, not
  an average, because spikes are outliers and would poison a mean.
- **Spike bar** — any bar whose range is ≥ 5 × the drift baseline (tunable).
- **Spike interval** — a rolling record of the bar gaps between the last 32 spikes,
  giving the average interval and its standard deviation.
- **Spike size** — the median range of the last 32 spikes. This is what sizes the
  HUNT targets.
- **Due-ness** — `bars since last spike ÷ average interval`. 0 % means one just
  fired; 100 % means one is due now.

All of it is causal — computed only from bars up to the one being evaluated.

### FADE — trading against the spike

The drift is the reliable part of these instruments, so fading a spike back into the
drift is the higher-probability side.

- Triggers 1–3 bars after a spike in the index's characteristic direction.
- Requires the spike to have given back ≥ 35 % of its range (exhaustion).
- **Blocked whenever due-ness ≥ 85 %** — never fade into a spike that is about to
  fire. This is the single most important guard in the engine.
- SL sits beyond the spike's own extreme plus a drift buffer.
- TP1 is the pre-spike price (the level the spike launched from); TP2 continues
  three drift-ranges further along the drift.

On **Boom** that means: spike up → **SELL**. On **Crash**: spike down → **BUY**.

### HUNT — trading with the spike

- Only arms when due-ness is between 70 % and 250 %.
- Price must be in the bottom 35 % of the 50-bar drift channel (Boom/GainX) or the
  top 35 % (Crash/PainX).
- Optionally requires a CRT raid in the spike direction as confirmation.
- Small stop — a few drift-ranges beyond the recent extreme — because if the spike
  does not come, the drift bleeds you slowly and you want out cheap.
- Targets are sized off the **measured median spike**, not an R multiple:
  TP1 at 50 % of it, TP2 at 100 %.

On **Boom/GainX** that means **BUY** before the up-spike; on **Crash/PainX**,
**SELL** before the down-spike.

### Why both can run at once

They are mutually exclusive in time, not in principle. Due-ness near zero means
FADE is open and HUNT is shut; due-ness above 0.7 means HUNT is open and FADE is
shut. The dashboard shows both windows live so you always know which one the market
is in.

---

## Confluence scoring

Each engine has its own weighting, all normalised to 0–100:

**CRT** — HTF bias aligned (14) · 3-timeframe agreement (12) · CRT quality: sweep
depth + reclaim strength (14) · premium/discount depth (12) · displacement size (12)
· zone type, FVG > OB > MSS retest (10) · candlestick pattern (10) · EMA + ADX
strength (10) · killzone (6)

**HUNT** — due-ness (24) · depth in the drift channel (18) · CRT confirmation (16) ·
spike-interval consistency (12) · pattern (10) · reward:risk (10) · spike size vs
drift (10)

**FADE** — spike size vs median (18) · exhaustion depth (20) · drift/HTF alignment
(18) · due-ness safety margin (16) · pattern (12) · dealing-range position (8) ·
reward:risk (8)

Grades: **A+** ≥ 85 · **A** ≥ 73 · **B** ≥ 62 · **C** below. Dots below
`Minimum confluence score` (default 62) are never printed, and A+ signals print as a
visibly larger dot. Raise the minimum to 75 for A-and-better only.

---

## Live performance tracker

Every printed signal is forward-tested against subsequent bars: did TP1 come before
SL? The dashboard shows win rate, average R, profit factor, current streak, worst
streak, and a **per-engine breakdown** so you can see whether CRT, HUNT or FADE is
carrying the symbol.

Two honest caveats: resolution is bar-by-bar, so when one bar covers both SL and TP1
it is scored as a **loss** (deliberately pessimistic), and the sample only covers
the bars the indicator has loaded (`Max history bars`, default 4000).

---

## Broker-agnostic symbol handling

The symbol name is uppercased and stripped of every separator, so `Boom 1000 Index`,
`BOOM1000`, `Boom_1000.raw`, `CRASH500m` and `GainX 800#` all resolve identically.

Detection order:

1. **Forced class** input, if you set one.
2. **Name match** — BOOM/GAINX → spikes up; CRASH/PAINX → spikes down; then metals,
   indices, crypto, synthetics, and FX by currency-code pairs.
3. **Statistical detection** — if the name says nothing, the indicator counts large
   up-range vs down-range bars over history and classifies the symbol as a spiker
   when one side outnumbers the other 3:1 with at least 5 occurrences.

That third step is why an unbranded or renamed spike index on an unfamiliar broker
still gets the spike engine. The dashboard's `Class` row always tells you which
route was used: `[name]`, `[stats]`, `[forced]` or `[unknown]`.

With `Auto-tune` on, the detected class also sets displacement, max risk, ADX
threshold, EMA separation and the session filter.

---

## Multi-timeframe scaling

The dashboard's **Scale in** row is the practical output of the bias gate. When a
bullish CRT is armed on D1 and D1 bias is bullish it reads `LONGS on H4 / H1 / M30`.

Load the same indicator on those timeframes: the D1 CRT is still the anchor
(auto-mapping sends H4 and H1 to D1), the bias gate is still bullish, so every
pullback that produces an MSS and a clean retest prints another buy dot. One
higher-timeframe dot becomes many lower-timeframe scale-in dots, all one direction.
To force the lower timeframes onto the *same* anchor as your D1 chart, set
`Anchor timeframe` explicitly to `D1` on each.

---

## Install — MetaTrader 5

1. **File → Open Data Folder → MQL5 → Indicators**
2. Copy `CRT_Sniper_Pro.mq5` in.
3. In MetaEditor press **F7** to compile.
4. Drag it onto a chart from the Navigator.

### EA integration

Ten buffers are exposed so the EA in this repo can consume the indicator directly:

| Buffer | Contents |
| --- | --- |
| 0 | Buy dot price, A+ grade (`EMPTY_VALUE` when none) |
| 1 | Buy dot price, standard grade |
| 2 | Sell dot price, A+ grade |
| 3 | Sell dot price, standard grade |
| 4 | Stop loss |
| 5 | Take profit 1 |
| 6 | Take profit 2 |
| 7 | Direction: `+1` buy, `-1` sell, `0` none |
| 8 | Confluence score, 0–100 |
| 9 | Engine: `0` CRT, `1` HUNT, `2` FADE |

```mql5
int h = iCustom(_Symbol, _Period, "CRT_Sniper_Pro");
double dir[1], sl[1], tp1[1], score[1], mode[1];
CopyBuffer(h, 7, 1, 1, dir);     // shift 1 = last closed bar
CopyBuffer(h, 4, 1, 1, sl);
CopyBuffer(h, 5, 1, 1, tp1);
CopyBuffer(h, 8, 1, 1, score);
CopyBuffer(h, 9, 1, 1, mode);

if(dir[0] != 0 && score[0] >= 75.0)
  {
   // mode[0]==2 (FADE) is the high-win-rate side on spike indices
   // mode[0]==1 (HUNT) is low win rate, large payoff - size it smaller
  }
```

The dashboard also prints a lot size for the configured `Account risk per trade (%)`
using the live SL distance and the symbol's tick value.

## Install — TradingView

1. Open the **Pine Editor**, paste `CRT_Sniper_Pro.pine`, click **Add to chart**.
2. For alerts use **Any alert() function call** — the message carries grade, score,
   engine, pattern, entry, SL and both targets. Separate `CRT Buy` / `CRT Sell` /
   `CRT Buy A+` / `CRT Sell A+` conditions are also available if you want to alert
   only on premium grades.

---

## Suggested settings

Auto-tune handles these; the table is what it applies, in case you want to override.

| Market | Anchor TF | Displacement | ADX | Max risk | Sessions |
| --- | --- | --- | --- | --- | --- |
| FX majors, XAUUSD | auto | 1.2–1.3 | 20 | 4.0–4.5 | on if you want them |
| Indices (US30, NAS100) | auto | 1.4 | 22 | 4.5 | on |
| Crypto | auto | 1.5 | 18 | 5.0 | off |
| Boom / Crash / GainX / PainX | H4 or D1 | 1.6 | 18 | 6.0 | off |

### Spike indices in practice

- Max risk goes to `6.0 × ATR` because a spike through your structural stop is
  normal and the default cap would silently drop good setups.
- EMA separation drops to `0.18 × ATR`: the drift is smooth and the EMAs sit close
  together, so the standard threshold would read SIDEWAYS almost permanently.
- Sessions off — these run 24/7.
- Start on **M1–M5**. The spike engine needs enough bars between spikes to measure an
  interval; on H1 a Boom 1000 spike may be a single bar with nothing in between.
- If HUNT prints too rarely, lower `HUNT: min spike due-ness` to 0.5. If it bleeds,
  raise it to 1.0 and only take A+ grades.
- If FADE gets caught by back-to-back spikes, lower `FADE: block when the next spike
  is this due` from 0.85 to 0.6.

## Tuning

| Symptom | Change |
| --- | --- |
| Too few signals | lower `Minimum confluence score`; `EMA filter` → Off; displacement → 1.0 |
| Too many weak signals | raise minimum score to 75; `EMA filter` → Strict |
| Only want the best | minimum score 85 — A+ dots only |
| Dots too far from the wick | `Dot distance from the wick` → 0.3 |
| Entries too deep in the pullback | `Retest zone source` → FVG only |
| Stops hit by noise | `SL buffer beyond structure` → 0.5 |
| Wrong spike direction detected | set `Force symbol class` explicitly |

Turn on `Debug: draw the active CRT range` to see the anchor range currently in use.

---

## Not yet verified

The MQL5 source has not been run through MetaEditor and the Pine source has not been
loaded into TradingView from this environment — neither toolchain is available here.
Compile both before trading them, and validate the settings on your own symbol and
broker feed. The built-in performance tracker is the fastest way to do that: load the
indicator, let it scan your history, and read the win rate and per-engine breakdown
off the dashboard before risking anything.
