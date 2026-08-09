# MarketFlow V8 — top-down SMC scanner for MT5

`MarketFlowV8.mq5` scans **every Market Watch symbol on the timeframe your chart is on**, and
publishes a setup only when higher-timeframe bias, market structure, SMC confluence and the
EMA/RSI trend filter all point the same way.

The dashboard lives in its **own indicator sub-window**, so it never sits on top of your
candles. The trade drawing still goes on the price chart where it belongs.

## The top-down sequence

Setups are always found on the **current chart timeframe**. The two bias timeframes ride one
and two steps above it, so the hierarchy moves with you:

| Chart | Nearer bias | Higher bias |
| --- | --- | --- |
| M15 | H1 | H4 |
| H1 | H4 | D1 |
| H4 | D1 | W1 |

So a bullish H4 pushes the M15 and H1 rows bullish, and when you move to the H4 chart you get
the H4 setup itself, confirmed by D1 and W1. `InpBiasAuto = false` pins them to fixed
timeframes instead.

```
1. bias        market structure (BOS / CHoCH) on both bias timeframes
               -> direction is fixed here. Nothing trades against it.
2. chart TF    a setup in that direction only:
                 . liquidity sweep    - a prior swing raided, stops taken, close back inside
                 . CHoCH / BOS        - structure actually shifts
                 . displacement       - the break is driven (body >= 1.0 x ATR), not drifted
                 . POI                - order block and/or fair value gap left by that leg
                 . premium / discount - buy in discount, sell in premium of the dealing range
                 . EMA + RSI          - momentum must not be fighting the setup
3. entry       a LIMIT at the POI. The setup WAITS for price to return to the zone.
4. targets     resting liquidity - prior swing highs / lows - not arbitrary multiples
5. alert       fires when price actually reaches the entry, not when the setup was drawn
```

`InpBiasMode` defaults to **Both** — both bias timeframes must agree. That is the strictest
setting and the reason a board can hold more `WATCH` rows than live setups.

## Market structure

Swings are fractals of `InpSwingStrength` bars each side. A fractal is only used once it is
**confirmed** — i.e. once enough newer bars exist — so no part of this can see the future.

- **BOS** (break of structure): close beyond the last confirmed swing in the same direction as
  the current state — continuation. Shown as `BUY+` / `SELL+`.
- **CHoCH** (change of character): the same break, but it flips the state — reversal. Shown as
  plain `BUY` / `SELL`.

The same walk produces the **dealing range** (`rangeHigh`/`rangeLow`), whose midpoint is
equilibrium. Below it is discount, above it is premium.

The bias timeframes get their own independent structure walk, and each entry bar is mapped to
the **last closed** D1/H4 bar — so the back-test cannot peek at a bias that had not formed yet.

## POI selection

| Found | Zone used |
| --- | --- |
| Order block **and** FVG that overlap | the overlap — the strongest POI |
| Both, but disjoint | the order block |
| FVG only | the gap |
| Order block only | the candle range |
| Neither | no setup — the bar is rejected |

Order block = last opposing candle before the impulse. FVG = three-candle imbalance
(`low[k-1] > high[k+1]` for bullish). Entry defaults to **consequent encroachment** (zone
midpoint); `InpPoiEntry = Proximal` enters at the near edge instead.

## Stops and targets

```
stop    = behind the POI, and behind the swept low/high if a sweep occurred, ± ATR buffer
          floored at InpMinRiskAtr × ATR, then widened if the broker stop level demands it
risk    = |entry − stop|
TP1     = nearest resting liquidity at least InpMinTp1R (1R) beyond entry
TP2     = the next liquidity level beyond TP1
TP3     = the H4 dealing-range extreme when it sits beyond TP2
fallback= 1.5R / 2.5R / 4R whenever no liquidity is found in range
```

The legend on the chart says which was used — `targets liquidity` or `targets R fallback` —
so you always know whether a target is a real level or a placeholder.

## Confluence score (gate: `InpMinScore`, default 70)

| Points | Test |
| --- | --- |
| 15 | D1 bias agrees |
| 15 | H4 bias agrees |
| 10 | EMA trend agrees |
| 10 | RSI not fighting the setup |
| 15 | liquidity sweep before the shift |
| 10 / 5 | CHoCH / BOS |
| 10 | displacement |
| 15 / 10 | POI is an OB **and** FVG / only one of them |
| 10 | entry on the right side of equilibrium |

Turning on the `SMC` column (`InpShowSmc`) shows which of these actually fired, e.g.
`D1 H4 SW CH OB FVG DISC`, so a score is never just a number you have to trust.

`InpBiasMode` controls strictness: **Both** (D1 and H4 must agree — fewest, strongest setups),
**H4 led** (default: H4 agrees, D1 must not oppose), or **Any**.

## Trend filter (EMA + RSI)

Structure tells you *where*; the trend filter refuses the trades where structure looks right
but momentum does not. Both are hard gates by default and also feed the score.

| | Continuation (BOS) | Reversal (CHoCH) |
| --- | --- | --- |
| **EMA** | price on the correct side of **both** EMAs, and EMA21/EMA50 stacked that way | price has reclaimed the **fast** EMA only — on a genuine turn the slow EMA still points the old way |
| **RSI** | buys need RSI 45–75, sells need 25–55 — it will not buy something already exhausted upward | buy needs RSI ≤ 45, sell ≥ 55 — the turn has to come from the stretched side |

`InpUseEmaFilter` / `InpUseRsiFilter` switch each off; thresholds are all inputs.

## Quality gates

Three hard rejections exist purely to keep low-quality setups off the board:

- **`InpMaxRiskAtr` (4.0)** — a stop wider than this means the structure is not clean enough
  to trade, whatever the confluence says.
- **`InpMaxZoneAtr` (2.5)** — a POI wider than this is not a level, it is a guess; a huge order
  block would give a meaningless entry price.
- **`InpHideFinished` (on)** — a setup that has already hit SL or TP3 stops being a signal. The
  dashboard will not advertise a trade that is over.

Setups stopped out before they ever filled are dropped as well (`INVALID`), so they can never
appear as a live entry.

## Real time, and no repainting

**Real time**

| Element | Refresh |
| --- | --- |
| Market Watch contents | re-read every 10 s — added or removed symbols follow |
| Scan | round-robin, `InpSymbolsPerTick` symbols per second, each re-analysed when it prints a new bar |
| `AGE` | recomputed at draw time from the signal bar's own timestamp against that symbol's current bar, so it is never a number frozen at scan time. `InpAgeMode = Clock` shows `1h 05m ago` instead of bars |
| `STATUS` | every second for every signalled symbol, and **every tick** for the charted symbol |
| Chart drawing | every tick |

**No repainting.** Five separate mechanisms, because one is not enough:

1. **Closed bars only.** Signals are only ever evaluated on bar 1 and older. The forming bar
   never produces a signal.
2. **No forward reads.** Every input to a decision at bar `i` comes from bar `i` or older.
   Fractals are used only once confirmed by `InpSwingStrength` *newer* bars, so the confirming
   bars are themselves at or before `i`. HTF bias reads the last **closed** D1/H4 bar.
3. **Seed guard.** The structure walk starts from an unknown state at the oldest bar of a
   window that slides forward each scan. Until price has actually broken structure, the state
   still carries a trace of that seed — so bias is only published after the first real break,
   and signals only from the second. A seed-dependent signal is a signal that can change under
   you.
4. **Held setups.** A live setup is held exactly as published until it finishes, so a rescan
   is never even given the chance to replace it with a recomputed version.
5. **Frozen levels.** ATR/EMA/RSI are seeded from the oldest bar in the window, so a recomputed
   value can differ in its last decimals — enough to nudge a stop by a tick. Once a setup is
   published for a given signal bar, its entry, SL and targets are **locked**. A rescan of that
   same bar reuses the original numbers; only the outcome is allowed to move.

What *does* change, by design, and is not repainting: a setup leaves the board when it ages
past `InpMaxAge`, when it is invalidated before filling, or when it finishes at SL/TP3.

## Alerts — fired at the fill, not at the drawing

This is the part that decides whether an alert is useful or noise.

A setup is drawn when structure shifts, but the entry is a limit sitting back at the POI —
price has not reached it yet. Alerting there gives you a heads-up for a trade you cannot take,
and by the time price arrives the alert is old news.

So the alert fires on the **fill condition, checked against the live quote**:

- a buy needs the **ask** down at the entry
- a sell needs the **bid** up at the entry

When it fires, the entry is available at that moment and the setup is still valid. That is the
"ready to serve" alert: `MarketFlow V8 >> ENTER NOW  Boom 1000 Index M15  BUY CONTINUATION
score 85 | entry ... SL ... TP1 ... TP2 ... | H4 H1 EMA RSI SW CH OB FVG DISC`.

| Input | Default | |
| --- | --- | --- |
| `InpAlertMinScore` | 75 | Only setups scoring at least this alert |
| `InpAlertMaxScore` | 100 | Upper bound — set 95 to skip perfect-score outliers |
| `InpAlertPopup` / `InpAlertPush` / `InpAlertSound` | on / off / on | Where the alert goes |
| `InpAlertOnForming` | false | Optional quiet heads-up when the setup first appears |

One entry alert per setup. Checked every second for every symbol, every tick for the charted
one.

## One setup at a time per pair, no daily cap

A pair holds one live setup. While it is running the pair produces nothing new — and holding it
untouched is also what makes the numbers non-repainting, since a rescan cannot recompute a
setup it is not allowed to replace.

Once that setup reaches its recycle target or the stop, the pair is free and the next setup can
appear immediately. There is no limit of one per day: a pair can produce several in a session
whenever conditions genuinely line up.

`InpRecycleAt` sets when the pair is freed — `TP1` (default), `TP2` or `TP3`. The stop always
frees it, and so does invalidation before fill.

## Why the numbers are real

| Concern | How it is handled |
| --- | --- |
| Symbol list | Live Market Watch (`SymbolsTotal(true)`), re-read every 30 s |
| Missing history | Row shows `LOADING`, `LOADING D1`, `SHORT HIST` — never a partial calculation |
| Untradable symbols | `SYMBOL_TRADE_MODE_DISABLED` → `DISABLED`, skipped |
| Unplaceable prices | Every level rounded to `SYMBOL_TRADE_TICK_SIZE` and widened past `SYMBOL_TRADE_STOPS_LEVEL`; `*` on the SL marks an adjusted level |
| "Did it work?" | `STATUS` replays the bars after the setup: `WAITING → ACTIVE → TP1/TP2/TP3 HIT`, or `SL HIT`, or `INVALID` |
| Optimistic accounting | If one bar touches both stop and target, the **stop counts first** — live and in the back-test |
| "Is this any good here?" | `WR` back-tests this identical rule (same `EvaluateAt` function) over the last `InpStatsBars` bars and shows the measured TP1-before-SL rate **and sample size**: `64% 28`, or `n/a 5` when too thin to mean anything |

**What it is not:** a predictor. `WR 64% 28` means this rule filled and then reached TP1 before
SL on 18 of 28 past occurrences on that symbol. It is a measured track record of a fixed rule,
which is a far better basis than an unbacked signal — but past structure is not future
structure, and synthetic indices in particular change character. Read the percentage together
with its sample size, and treat a thin sample as no information.

## Dashboard

The dashboard is drawn in its **own indicator sub-window** (`#property indicator_separate_window`),
so it never overlaps the candles. If you add or remove other indicators the sub-window index
shifts; the panel detects that and rebuilds itself. Set its height with
`#property indicator_height` (200 by default) or drag the divider.

The default view is the reference layout, exactly ten columns:

`SYMBOL · TF · SIGNAL · AGE · ENTRY · SL · TP1 · TP2 · TP3 · CHART`

Title reads `◈ MARKETFLOW V8 | SIGNALS DASHBOARD | M15 | 13:08`, with ▲/▼ and the `1-9 / 14`
page counter on the right. `SIGNAL` shows `▲ BUY+` / `▼ SELL+` for a BOS continuation and
`▲ BUY` / `▼ SELL` for a CHoCH reversal. `AGE` reads `current`, `1 bars ago`, … The row of the
symbol currently on the chart is highlighted. `OPEN` switches the chart to that row's symbol.

Rows sort live setups first, then the `WATCH` rows by strength, so page 1 is always the
actionable page even with 250 symbols loaded.

**Every pair always shows a direction.** A pair with no tradable setup right now still shows
`▲ BUY` or `▼ SELL` with a score — that is the current directional read from the two bias
timeframes, the chart-timeframe structure, EMA and RSI. Its `STATUS` says `WATCH` and its
ENTRY/SL/TP stay blank, because there is no setup to quote yet. A lean is never dressed up as
an entry: if the price columns are empty, there is nothing to place.

When a real setup qualifies, the row fills in completely and becomes alert-eligible.

**One deliberate deviation:** while symbols are still warming up the title appends
`| scanning 84/132`. It disappears once every symbol has been analysed, so the steady-state
title is the reference title — but a blank row is never ambiguous between "no setup" and
"not looked at yet".

The analysis columns are switched **off** by default and can be turned on individually:

| Input | Adds |
| --- | --- |
| `InpShowBias` | `BIAS` — `D▲ H▲`, green only when both agree with the signal |
| `InpShowSmc` | `SMC` — which confluences fired, e.g. `D1 H4 SW CH OB FVG DISC` |
| `InpShowScore` | `SCORE` — the confluence total |
| `InpShowWinRate` | `WR` — measured hit rate and sample size |
| `InpShowStatus` | `STATUS` — `WATCH / WAITING / ACTIVE / TP1 HIT / SL HIT / INVALID` |

### Chart

Default drawing matches the reference: the SL→TP3 box from the signal bar, the `ENTRY:`,
`SL:`, `TP1:`, `TP2:`, `TP3:` labels inside it, the entry line across the chart, the dashed
marker at the signal bar, the direction arrow, the top-right `Symbol | TF` watermark (tinted
with the signal direction, `InpWatermarkTint`), and the two-line legend:

```
◈ TRADE
▲ BUY+  CONTINUATION
```

Two opt-in extras:

- `InpShowSmcMarkup` — draws the POI zone (order block / FVG), the swept-liquidity line marked
  `SWEEP`, and the `CHoCH` / `BOS` tag at the shift bar.
- `InpShowTradeDetail` — adds a third legend line with bias, confluence tags, score, status,
  risk, R:R and the measured hit rate.

## Performance

- Symbols are analysed **round-robin, `InpSymbolsPerTick` per second** (default 6), and only
  when that symbol prints a new bar; otherwise the cached result is shown.
- Three `CopyRates` per symbol per new bar (entry TF + D1 + H4). ATR and all structure walks
  are computed inline rather than through `iMA`/`iATR` handles, so the scan is not capped by
  the terminal's per-chart indicator-handle limit — that limit is what makes large scanner
  panels show blank rows.
- The back-test only evaluates bars where a structure break actually occurred, and **only runs
  at all when its result is on screen** (`InpShowWinRate` or `InpShowTradeDetail`). It is by far
  the most expensive part of a scan, and computing a number nobody is looking at is what makes
  a scanner slow. With it off, a scan reads roughly 350 entry bars instead of 800.
- The title shows `analysed 128/132`, so a blank row is never ambiguous between "no setup" and
  "not scanned yet". First attach on a fresh terminal takes a while: MT5 must download D1, H4
  and entry-TF history for every symbol.

## Key inputs

| Input | Default | Notes |
| --- | --- | --- |
| `InpBiasTF1` / `InpBiasTF2` | D1 / H4 | A bias TF at or below the entry TF is ignored automatically |
| `InpBiasMode` | H4 led | Strictness of the bias filter |
| `InpMinScore` | 70 | Raise for fewer, higher-conviction setups |
| `InpUseEmaFilter` / `InpUseRsiFilter` | true | Hard trend gates on top of the SMC logic |
| `InpMaxRiskAtr` / `InpMaxZoneAtr` | 4.0 / 2.5 | Quality rejections |
| `InpAgeMode` | Bars | `Clock` shows elapsed time instead of bar count |
| `InpSymbolsPerTick` | 10 | Scan throughput |
| `InpBiasAuto` | true | Bias follows the chart (1 and 2 steps up) |
| `InpBiasMode` | Both | Both bias timeframes must agree |
| `InpRecycleAt` | TP1 | When a pair may produce its next setup |
| `InpAlertMinScore` | 75 | Alert threshold |
| `InpRequireSweep` | false | Set true to demand a liquidity sweep on every setup |
| `InpRequireDisp` | true | Reject breaks without displacement |
| `InpRequirePD` | false | Set true to refuse entries on the wrong side of equilibrium |
| `InpPoiEntry` | CE | Zone midpoint, or proximal edge |
| `InpMaxAge` | 25 | How long a setup stays on the board waiting for its fill |
| `InpStatsBars` | 600 | Back-test window; `0` disables the WR column |
| `InpShowSmcMarkup` | false | POI zone, sweep line and BOS/CHoCH tag on the chart |
| `InpShowTradeDetail` | false | Third legend line with the full SMC read |

## Limitations

- The on-chart drawing only appears when the chart timeframe matches the entry timeframe.
  Otherwise the box would anchor to the wrong bars, so it is hidden rather than drawn wrong.
- The panel is pixel-laid-out for `Consolas` 8 / 18 px rows. The default ten columns are about
  990 px wide; turning every analysis column on takes it to roughly 1300 px.
- ATR is seeded from the oldest bar in the copied window, so it can differ from `iATR` in the
  last decimals on the oldest bars. Warm-up is `6 × ATR period` bars, far outside where signals
  are read.
- Back-tested setups that never filled, or that were still open after `InpStatsMaxHold` bars,
  are excluded from `WR` rather than counted either way.

## Install

1. Copy `MarketFlowV8.mq5` to `<MT5 data folder>/MQL5/Indicators/` (File → Open Data Folder).
2. Compile with **F7** in MetaEditor.
3. Drag **MarketFlow V8** onto any chart.

It places no orders and needs no trading permissions.

## Relation to `config.json`

`config.json` in the repository root is the remote-control state for the EA (`ea_status`,
`mode`, `hedging`). This indicator is display-only and does not read or write it.
