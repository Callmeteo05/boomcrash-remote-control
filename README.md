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

## Seven entry models

CRT alone waits for a specific higher-timeframe sequence, which is why quiet days
were quiet. Six more models now run alongside it, each a distinct, well-defined
price-action setup. All of them inherit the same gates: HTF bias, session, news,
spread, score.

| Model | Tag | Trigger |
| --- | --- | --- |
| Candle Range Theory | `CRT` | anchor raid → close back inside → MSS → FVG/OB retest |
| Liquidity Sweep + Reclaim | `SWEEP` | takes out a prior swing low/high, then closes back through it |
| Break and Retest | `BRT` | displacement break of a swing level, then price returns and holds it |
| Trend Pullback | `TPB` | trending market pulls back to EMA 50, holds, and prints a rejection |
| Asian Range Sweep | `ASIA` | London sweeps the Asian session low/high and reclaims it (Judas swing) |
| Spike Hunt | `HUNT` | overdue spike, price at the far edge of the drift channel |
| Spike Fade | `FADE` | spike prints and gives back part of its range |

They fire in priority order, so only one signal prints per bar. `SWEEP`, `BRT` and
`TPB` are the high-frequency models that fill in the days CRT skips. `ASIA` is FX
and index oriented and switches itself off on spike indices. Each model has its own
toggle.

The chart tag on every dot names the model that fired: `A+ 91 BRT`.

## Why this trade — the reason stack

Every signal carries a plain-language explanation, shown on the dashboard and
included in the alert:

```
BRT | H4 BEARISH | 3/3 MTF | premium 71% | LONDON | retest 1.09420
    | Bear Engulf | 2.0R
```

That is assembled from the same components the scorer uses, so the score and the
explanation can never disagree. It tells you which model fired, what the anchor bias
is, how many timeframes agree, where price sits in the range, which session you are
in, the structural trigger, the confirming candle, and the reward on offer.

## Trading the news, not just dodging it

Two more models fire **during** a release. They are the only engines allowed to run
inside a blackout — everything else stays blocked.

The indicator builds a **pre-news range** from the 30 minutes before the release,
then watches how price treats it:

| Model | Tag | Setup |
| --- | --- | --- |
| News Breakout | `NEWS-BO` | price closes beyond the pre-news range by ≥ 1 ATR and holds — the release created direction. SL on the far side of the range. |
| News Reversal | `NEWS-REV` | price spikes ≥ 1.5 ATR out of the range then closes back inside — the classic release whipsaw. SL beyond the spike, TP the far side of the range. |

Both wait `News delay` (default 2 minutes) after the release before they can fire, so
you are not trading the first tick of chaos. Each fires **once per event**. The
dashboard shows `TRADING THE RELEASE` and prints the pre-news range while the window
is live.

Set `Breakout must agree with the HTF bias` if you only want continuation trades.
It is off by default because a release frequently *creates* the new direction rather
than following the old one.

**Read this before enabling it.** News trading is the highest-slippage activity in
this indicator. Spreads widen violently at the release, fills go far from the price
on your screen, and the cost gate uses the *current* spread — which on historical
bars is not the spread that existed during the release. The performance tracker will
therefore be **more optimistic on news models than on any other engine**. Treat
`NEWS-BO` and `NEWS-REV` results as an upper bound, not an estimate, and demo them
specifically before risking anything.

## News awareness

**MT5 reads the real economic calendar** via `CalendarEventByCurrency` /
`CalendarValueHistory`, keeps high-impact events (medium too, optionally), and blocks
every non-news engine for a window before and after each release. The dashboard shows
the currencies watched, minutes to the next event, and how many signals were blocked.

### Currency resolution — any pair, any broker

Which calendar applies is resolved from four sources, unioned:

1. The symbol's `BASE`, `PROFIT` and `MARGIN` currency properties.
2. The **symbol name**, scanned for 22 currency codes — the eight majors plus SEK,
   NOK, DKK, PLN, CZK, HUF, TRY, ZAR, MXN, SGD, HKD, CNH, ILS, THB. This catches
   crosses and exotics on brokers that leave the properties blank or wrong on CFDs.
3. The **index home economy** — US30/NAS100/SPX → USD, GER40/DAX → EUR, UK100 → GBP,
   JP225 → JPY, HK50 → HKD, AUS200 → AUD. Metals and crypto pick up USD.
4. Anything you add in `Extra currencies to watch`.

So GBPJPY watches both GBP and JPY releases, USDZAR watches USD and ZAR, XAUUSD
watches USD, and NAS100 watches USD even though its "base currency" may be reported
as something unhelpful.

Two honest limits. The calendar needs a terminal connected to a MetaQuotes server —
if it returns nothing the dashboard says `calendar unavailable` and the filter fails
**open**, so check that row rather than assuming you are protected. And the filter
disables itself on synthetics, because Boom's base currency is USD and US news has
nothing to do with it.

**TradingView has no economic calendar at all.** Pine cannot see events. The Pine
build offers a manual daily blackout window instead, off by default. This is a
platform limitation, not something I can code around.

## Session engine

Beyond killzone filtering, the indicator now tracks the **Asian session range** each
GMT day and carries it forward. That range powers the `ASIA` model and is displayed
live. The dashboard names the active session and marks off-session hours.

## Freshness — what makes a dot actionable

A dot prints at bar close. By the time you see it, price has moved. The indicator now
measures that directly and gives a verdict on the most recent signal:

```
Status : TAKEABLE  (chased 0.08R, 1 bars)
Status : TOO LATE  (chased 0.41R)
Status : EXPIRED   (5 bars old)
```

`chased` is how far price has run *against your entry price* in R. Past
`Max adverse chase` (default 0.30R), the trade you'd get is no longer the trade the
indicator scored, and the panel says so. Past `Signal TTL` bars, it expires. The
alert carries the same window in text.

This is the closest an indicator can honestly get to "dots printed = enter now": the
dot means every rule passed, and the status line tells you whether the price you can
still get is one worth taking.

**The large A+ dot** now requires more than a high score — it also requires every
hard gate clear, including sufficient anchor history for the bias to be meaningful.
Small dots are watch-list; large dots are the ones the system considers complete.

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

---

# CRT Sniper Lite

A deliberately small indicator, built after Pro turned out to be too much. Use this
one first.

| | Pro | **Lite** |
| --- | --- | --- |
| Settings | 110 | **32** |
| Lines of code | 3,281 | **689** |
| Entry models | 9 | **2** |
| Chart output | 35-row dashboard | **BUY / SELL, SL, TP, 6-line panel** |
| Logic verified | no | **yes, see below** |

`MT5/Indicators/CRT_Sniper_Lite.mq5`

## What it draws

Exactly what the reference screenshot shows and nothing else: the word **BUY** or
**SELL** at the signal candle, a vertical line from entry out to the far target, and
horizontal **SL** / **TP** lines with labels. A six-line panel at the top left gives
trend, location, the last signal and why it fired.

## What it looks for

Two models, both requiring the chart **and** the higher timeframe to agree:

- **Liquidity sweep** — price takes out a prior swing low or high, then closes back
  through it.
- **Trend pullback** — price pulls back into EMA 50 inside an established trend and
  holds.

Then: buys only in the lower half of the recent range, sells only in the upper half,
plus a candlestick confirmation. A signal skips the candle requirement only when the
structural trigger is strong on its own.

Quality is scored out of 100 from five equal parts — trend strength, entry location,
candle, trigger quality and reward — with one dial (`Signal quality`, default 70)
controlling how strict it is.

## Why the higher-timeframe check is different from Pro

Pro asks for **EMA 200 on the anchor timeframe** — 200 daily candles. Synthetics and
newer symbols often do not have that, so the bias read wrong or stuck, and every
model downstream inherited the error. That is the most likely reason Pro's signals
looked wrong.

Lite uses **EMA 50 on the higher timeframe** instead. Fifty bars, which every broker
has, on every symbol.

## Verified, not just written

`tools/verify_lite_logic.py` re-implements the decision chain in Python and runs it
against synthetic series whose correct answer is known in advance. Run it with
`python3 tools/verify_lite_logic.py`.

It checks that buys appear only in uptrends, sells only in downtrends, almost nothing
in a range, that stops always sit on the losing side of entry and targets on the
winning side, and that R multiples come out as configured.

Three real bugs were found and fixed this way:

1. **Signals were far too rare** — one per 145 bars. The candle filter was rejecting
   88% of otherwise valid setups. Broadening confirmation to include inside-bar
   breaks, tweezers and momentum closes took it to one per 45 bars.
2. **The trend component of the score was a constant 20**, so it contributed nothing
   and compressed the usable range to 70–81. Now it measures EMA separation and the
   higher-timeframe distance from its own EMA, and the range is 70–88.
3. **Break-and-retest was removed.** It fired zero times in trends — price does not
   return to the broken level — and fired constantly in ranges on meaningless
   micro-breaks. Two models that work beat three where one is a noise generator.

This proves the rules behave as described. It does **not** prove they are profitable
— that still needs your broker's data.

---

# CRT Sniper EA

`MT5/Experts/CRT_Sniper_EA.mq5`

An expert advisor built on the **verified** Lite signal engine — the same two
models, the same trend and location gates, the same scoring. Nothing new was
invented for the EA; what was added is everything around the entry.

**Trading is OFF by default.** `Enable live trading` starts at `false`. Until you
turn it on the EA runs in monitor mode: it evaluates every slot, logs what it would
have done and why, and sends no orders. Leave it there until you have watched it on
demo for a few weeks.

## Scalp, intraday and swing at the same time

Each symbol gets up to three independent slots, each with its own timeframe, anchor
and reward profile:

| Style | Chart | Anchor | TP1 / TP2 |
| --- | --- | --- | --- |
| Scalp | M5 | H1 | 1.2R / 2.0R |
| Intraday | M15 | H4 | 2.0R / 3.0R |
| Swing | H4 | D1 | 2.5R / 5.0R |

A scalp cannot wait for 3R and a swing should not settle for 1.2R, so the targets
move with the horizon rather than being one setting for all three.

## Which symbols

By default it trades **everything in your Market Watch**, capped at `Max symbols`
(12) to protect both CPU and exposure. Symbols the account cannot actually trade
(disabled, close-only) are skipped automatically. You can supply an explicit list
instead, or an exclusion list.

## Position sizing — verified, not assumed

`tools/verify_risk_math.py` checks the sizing against cases worked out by hand.
Three results worth knowing:

- **Rounding can only ever reduce risk.** Across 400 sizes the worst overshoot was
  exactly 0. Lots always round *down* to the broker's step.
- **Cent accounts are read at real value.** A balance of 50,000 on a cent account is
  $500, not $50,000. Without that division a small cent account lands in the lowest
  risk tier and trades far too large. This is the single most dangerous bug for the
  accounts you described, and it is tested.
- **An account too small for an instrument is refused, not forced.** $2 of risk on
  US30 needs 0.044 lots against a 0.1 minimum, so the EA declines rather than taking
  five times the intended risk at minimum size.

### Risk falls as the account grows

| Equity (real) | Risk per trade |
| --- | --- |
| under $200 | 2.0% |
| under $1,000 | 1.5% |
| under $10,000 | 1.0% |
| above | 0.75% |

Small accounts get more aggression because the absolute loss is small and growth
needs compounding. Large accounts get less because preservation matters more than
speed. There is a hard ceiling of 2% per trade regardless of tier.

## The honest part about "grow fast with low drawdown"

Those are the same dial turned in opposite directions. Risk 5% a trade and you can
double an account in a good month and halve it in a bad week. Risk 0.5% and neither
happens. No code resolves that trade-off — it only decides where you sit on it.

What the EA does instead is make the downside *bounded and automatic*:

- **Total live risk cap** (4%) across all open positions. A position whose stop has
  moved to breakeven stops counting toward it, which is what frees room for the next
  trade — this is tested in the verifier.
- **Daily loss halt** (3%) — stops opening for the rest of the day.
- **Drawdown halt** (12% from peak equity) — stops entirely and alerts you.
- **Max 6 concurrent positions**, max 2 per symbol.
- **Spread gate** — skips when spread exceeds 25% of ATR.

## Position registry — why management needs its own memory

An open position carries no memory of how it was opened. MT5 has no writable
per-position storage, and a comment cannot be edited after the fact. Everything
management needs — the **original** stop distance, the style, whether a partial has
already been taken — must be tracked by the EA itself.

The first version didn't, and auditing it for this produced four real bugs:

1. **The partial was taken repeatedly.** The "already taken" flag was looked for in
   the position comment, which never contained it. At 2R the EA banked 50%, then 50%
   of the remainder on the next tick, and again — **slicing the position down to the
   volume minimum**.
2. **R was wrong for two styles out of three.** After breakeven the original stop
   distance is gone, so it was rebuilt from the target using one hardcoded reward
   multiple. Measured: a **swing trade used risk 8.33 instead of 5.00, a 67% error**;
   a scalp was 33% out. Every downstream trigger — partial, trail, time stop — fired
   at the wrong price.
3. **The trail used a fixed M15 ATR** regardless of style, so an H4 swing was trailed
   with a scalper's stop — 4.50 tighter in the test case, which is noise-stopped.
4. **Scale-in had the same defect.** It measured R from the *live* stop, so a trade
   sitting at breakeven read roughly ten times further ahead than it was, and added
   far too early.

All four are fixed by a registry keyed on ticket, and verified in
`tools/verify_trade_mgmt.py`. Positions that survive an EA restart are adopted, with
the style read back from the comment and the risk distance recovered from the target
using the **correct** style. The one thing a restart cannot recover is whether a
partial was already taken, so that is logged rather than assumed.

## Trade management, and the reasoning

| Stage | Trigger | Why |
| --- | --- | --- |
| **Breakeven** | +1.0R | Removes the risk once the trade has proved itself. Locks 0.1R so it is a small win, not a scratch. |
| **Partial** | +2.0R, close 50% | Banks real money at the level most trades reach, leaves the rest to run. Stamped in the comment so it can never fire twice. |
| **Trail** | after the partial, 1.5× ATR | Only follows in the winning direction, never retreats — verified. |
| **Time stop** | optional, off by default | Capital stuck in a trade going nowhere is capital not working. |
| **Scale-in** | first trade ≥ +1R | Adds **half size**, never a full second bet, never against an open trade, and never if it would breach the 4% cap. |

Scaling in is how the account grows faster without raising per-trade risk: you add
only to positions the market has already confirmed, funded by risk the first trade
has already released by moving to breakeven.

## News — avoid it and trade it

Reads the real MT5 economic calendar for every currency in your symbol universe.

- **Avoid:** no new trades from 30 minutes before to 30 minutes after a high-impact
  release. Optionally closes open trades before one.
- **Trade:** with `Trade the release` on, it marks the 30-minute pre-news range, waits
  2 minutes after the print, and takes a break of that range by more than 1 ATR. Stop
  goes on the far side of the range. One trade per event per slot. This is the only
  model allowed to fire inside a blackout.

News trading is off by default, and it carries the worst slippage of anything here.

## Structure, SMC and the spike engine

Three layers were added on top of the two original models. All of it is verified in
`tools/verify_structure_smc.py` before it reaches the EA.

### Market structure — BOS and CHoCH

The EA tracks swings and classifies every break:

- **BOS** (break of structure) — price continues the prevailing direction.
- **CHoCH** (change of character) — price breaks the *other* side first, the
  earliest sign the leg is finished.

The idea that makes this work is the **protected low** (or high). In a bullish leg,
price breaking some minor swing low is only a pullback. Only the low that produced
the last break of structure is protected, and breaking *that* is a CHoCH.

This mattered: the first implementation treated every fractal as structural and
**flipped direction on every pullback** — 4 of 7 breaks in a clean uptrend were
labelled bearish. With protected swings it reads 10 of 11 correctly, and the
reversal test produces exactly one CHoCH, at the turn.

### SMC entries — displacement, then the imbalance

On a structural break the EA looks for what the move left behind:

1. **Fair value gap** — a three-candle imbalance where price moved too fast to trade
   back. Preferred, because it is direct evidence of displacement.
2. **Order block** — the last opposing candle before the impulse, used when there is
   no gap.

Only zones price can still *return to* are armed. A second bug caught in testing:
returning the nearest opposing candle regardless of side handed back zones price had
already passed, which can never be retested.

Entry is the retest of that zone, and it must be in **discount** of the dealing range
for a buy, **premium** for a sell. The dealing range is the current leg — swing low
to swing high — and it resets on every BOS. Anchoring it to the start of the whole
trend was a third bug: every pullback read as premium and no buy could ever qualify.

Zones are armed on **every** structural break, before any model claims the bar. Arming
inside a model branch loses breaks that coincide with another signal.

### Spike engine — Boom, Crash, GainX, PainX

Ported from Pro and now measured rather than assumed. On each symbol the EA scans
history and works out the spike direction, the median spike size, and the average
interval between spikes. Verification against synthetic Boom and Crash feeds:
direction correct both ways, interval measured at 60.0 bars against a true 60, median
size 6.15 against a true 6.0, and an ordinary trending market correctly **not**
classified as a spike index.

| Model | Direction | Fires when |
| --- | --- | --- |
| **FADE** | with the drift, against the spike | a spike has printed and given back ≥35% of its range, and the next one is not due |
| **HUNT** | with the spike, against the drift | a spike is 70–250% overdue and price sits at the far edge of the drift channel |

On Boom, FADE sells the spike and rides the drift down; HUNT buys ahead of the next
spike. Mirrored on Crash. The spike models run **before** the trend filter, because a
spike index has no meaningful EMA trend for the models to agree with.

**HUNT is off by default.** Its premise is that spikes become "due", which only holds
if the interval is regular rather than memoryless. FADE is the higher-probability
side and is on.

## Sessions and news in the EA

### Killzones, with the broker clock solved

Broker servers are rarely on GMT — GMT+2 and GMT+3 are the usual offsets. A killzone
computed from raw bar times lands on the wrong hours and **silently blocks the
sessions it was meant to allow**. The EA measures the offset instead of asking for it
(`TimeCurrent() − TimeGMT()`), and the panel shows what it detected.

Verified: a GMT+3 server showing 10:00 correctly resolves to 07:00 GMT — London open.
The same 10:00 reads London on GMT+0 and Asia on GMT+8.

| Session | GMT | Default |
| --- | --- | --- |
| Asia | 00:00–06:00 | off |
| London | 07:00–12:00 | on |
| New York | 12:00–17:00 | on |

The filter is **per style**: on for scalp and intraday, off for swing, because an H4
bar spans several sessions and filtering it by the hour of its close is meaningless.

### Asian range sweep (Judas swing)

During London, if price sweeps the Asian session low and closes back above it — with
the higher timeframe bullish — that is a Judas swing and the EA buys the reclaim.
Mirrored for sells. The Asian range is read straight from the bars each time rather
than accumulated, so restarting the EA mid-session never loses it.

### News reversal

The EA already traded the pre-news range breakout. It now also trades the release
that **spikes out and fails back in** — the classic whipsaw.

Testing caught a real conflict here: the reversal originally only asked "did price
spike out", so a two-sided whipsaw fired **both** models at once. The reversal now
requires price to actually be back **inside** the range, which makes the two mutually
exclusive by construction — breakout needs price outside, reversal needs it inside.
Verified across 26 closing prices with zero conflicts. When a release whipsaws both
ways, the larger excursion is the one that failed, so that is the side faded.

News and spike models **bypass the killzone filter** — they carry their own timing.
An NFP print does not care whether it lands inside your London window.

## The smallest account that can actually trade

The broker's **minimum lot is a hard floor**. Below a certain equity the smallest
trade you are allowed to place already risks more than your configured percentage,
and no setting gets underneath it.

| Symbol | Min lot | Cost if the stop hits | Equity needed at 2% | at 5% | at 10% |
| --- | --- | --- | --- | --- | --- |
| USDJPY | 0.01 | $1.70 | $85 | $34 | $17 |
| Boom 1000 | 0.20 | $1.60 | $80 | $32 | $16 |
| EURUSD | 0.01 | $2.00 | $100 | $40 | $20 |
| GBPUSD | 0.01 | $2.50 | $125 | $50 | $25 |
| XAUUSD | 0.01 | $3.50 | $175 | $70 | $35 |
| US30 | 0.10 | $4.50 | $225 | $90 | $45 |

An account of **$0.25 cannot place a trade at all**. The cheapest minimum-lot trade
anywhere in that list costs $1.60, so a quarter of a dollar cannot survive one
stop-out even at 100% risk. This is arithmetic, not a limitation of the EA.

Realistically: **$80–$225 is the entry point** for one symbol at sane risk. Accept
5% risk per trade and it drops to roughly $32–$90, with the drawdown that implies.

### The EA tells you where you stand

On startup it prints a capability report — every symbol, its minimum lot, the cost of
one minimum-lot stop-out, and the equity needed to size it properly:

```
CRT Sniper EA capability report - equity 45.00 USD, risk 2.00% per trade
  symbol        min lot   one min-lot stop   equity needed   status
  EURUSD           0.01               2.00          100.00   ACCOUNT TOO SMALL
  USDJPY           0.01               1.70           85.00   ACCOUNT TOO SMALL
CRT Sniper EA: this account cannot size ANY symbol at 2.00% risk.
  The cheapest is USDJPY, which needs 85.00 USD at that risk.
  The broker minimum lot is a hard floor - no setting gets under it.
  Either fund to 85.00 USD, or accept a higher risk per trade.
```

The panel carries the live count (`Affordable : N symbols sizeable at 2.00% risk`),
and symbols the account cannot size are skipped rather than repeatedly attempted.

So the EA never silently does nothing. If it is not trading, it says why, and tells
you the number that would change it.

## Before you run it

1. Compile in MetaEditor (**F7**).
2. Attach to **one** chart — it manages every symbol from there. Enable AutoTrading.
3. Leave `Enable live trading` **false**. Watch the log and the panel for a week.
4. Move to a demo account with the same balance you plan to trade.
5. Only then consider going live, and start at the smallest size your broker allows.

The signal logic is verified. The money math is verified. **The profitability is
not** — no backtest has been run on real data. The EA will do exactly what it is
told, faithfully, on rules whose edge is still unproven.
