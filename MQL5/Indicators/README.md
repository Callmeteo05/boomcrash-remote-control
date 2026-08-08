# MarketFlow V8 — MT5 Market Watch scanner

`MarketFlowV8.mq5` analyses **every symbol in your Market Watch** in the background and
publishes signals with entry, SL and TP1/TP2/TP3, plus the trade projection on the chart.

## What makes the numbers real

The indicator never prints a level it cannot justify from broker data:

| Concern | How it is handled |
| --- | --- |
| Where symbols come from | `SymbolsTotal(true)` / `SymbolName(i, true)` — the live Market Watch, re-read every 30 s so added or removed symbols follow automatically |
| Missing history | A row shows `LOADING` or `SHORT HIST` until enough bars have actually downloaded. It never falls back to a partial calculation |
| Untradable symbols | `SYMBOL_TRADE_MODE_DISABLED` symbols are marked `DISABLED` and skipped |
| Prices that can't be placed | Every level is rounded to `SYMBOL_TRADE_TICK_SIZE` and widened to clear `SYMBOL_TRADE_STOPS_LEVEL`. A level that had to be widened is flagged with `*` next to the SL |
| "Did it work?" | The `STATUS` column replays the bars **after** the signal and reports what the trade actually did: `ACTIVE`, `TP1 HIT`, `TP2 HIT`, `TP3 HIT`, `SL HIT` |
| "Is this setup any good on this symbol?" | The `WR` column back-tests the identical rule over the last `InpStatsBars` bars of that symbol and shows the measured TP1-before-SL rate and the sample size, e.g. `64% 28`. Below `InpStatsMinSamples` it shows `n/a 3` rather than a meaningless percentage |
| Optimistic accounting | When one bar touches both the stop and a target, the **stop is counted first** — in the live status and in the back-test |
| Look-ahead bias | Higher-timeframe confirmation maps each scan bar to the last **closed** HTF bar, so the back-test cannot see the future |

The rule that gets published and the rule that gets measured are the same function
(`EvaluateAt`), called from both paths. A `WR` figure therefore describes the signals you are
actually being shown.

**What it still is:** a rules engine measuring its own historical hit rate. A `70% 30` reading
means that rule resolved TP1 before SL on 21 of 30 past occurrences on that symbol — it is a
track record, not a prediction, and synthetic indices in particular can change character. Read
`WR` together with the sample size.

## Signal rules

Evaluated on **closed bars only**, on the scan timeframe.

| | Rule |
| --- | --- |
| Trend | `EMA(21)` vs `EMA(50)` |
| **BUY+** continuation | uptrend, bar dipped to/through the fast EMA, closed back above it, bullish body |
| **SELL+** continuation | downtrend, bar rallied to/through the fast EMA, closed back below it, bearish body |
| **BUY-** reversal | downtrend, `RSI(14) ≤ 30`, bullish body closing above the previous bar's high |
| **SELL-** reversal | uptrend, `RSI(14) ≥ 70`, bearish body closing below the previous bar's low |

`+` = continuation, `-` = reversal. The scanner reports the newest hit within `InpMaxAge` bars,
so `AGE` reads `current`, then `1 bars ago`, `2 bars ago`, …

### Score (0–100), gate `InpMinScore` (default 55)

| Points | Test |
| --- | --- |
| 40 | the setup fired |
| +20 | higher-timeframe EMA trend agrees with the direction |
| +10 | signal-bar body ≥ 0.5 × ATR (real momentum, not a doji) |
| +10 | tick volume ≥ 1.2 × its 20-bar average |
| +10 | RSI in a healthy zone for the setup type |
| +10 | no opposing swing level sitting between entry and TP1 |

The HTF defaults to one step above the scan timeframe (M15 → H1) and is configurable.

## Risk model

```
entry = close of the signal bar          (or live ask/bid, frozen at signal time)
stop  = ATR(14) × 1.5   or   swing structure ± buffer   or   whichever is further  (default)
risk  = |entry − stop|
TP1   = entry ± risk × 1.5
TP2   = entry ± risk × 2.5
TP3   = entry ± risk × 4.0
```

The 1.5R / 2.5R / 4R ladder is the ratio the reference screenshots resolve to (Boom 1000:
entry 13878.1610, SL 13843.7815 → risk 34.3795 → TP1 13929.7302, TP2 13964.1097,
TP3 14015.6789). Set `InpSLMode = ATR only` to reproduce those SL numbers exactly; the default
`HYBRID` also respects swing structure, which moves the stop behind a real level rather than a
fixed distance.

## Performance

Scanning 250 symbols cannot happen in one tick without freezing the terminal, so:

- symbols are analysed **round-robin, `InpSymbolsPerTick` per second** (default 6), and only
  when that symbol has printed a new bar — the rest of the time the cached result is displayed;
- indicators (EMA/ATR/RSI, Wilder smoothing) are computed inline from `CopyRates` rather than
  through `iMA`/`iATR`/`iRSI` handles, so the scan is not capped by the terminal's per-chart
  indicator-handle limit — that limit is what makes big scanner dashboards show blank rows;
- the panel title shows `analysed 128/132` so you can see the warm-up finish instead of
  guessing whether a blank row means "no signal" or "not scanned yet".

First attach on a fresh terminal takes a little while: MT5 has to download history for every
symbol before anything can be computed. Rows fill in as that lands.

## Columns

`SYMBOL · TF · SIGNAL · SCORE · WR · AGE · ENTRY · SL · TP1 · TP2 · TP3 · STATUS · CHART`

`SCORE`, `WR` and `STATUS` can be switched off (`InpShowScore`, `InpShowWinRate`,
`InpShowStatus`) to get back to the original ten-column layout. `OPEN` switches the chart to
that symbol. ▲/▼ page through the list; rows are sorted signals-first by default, so page 1 is
the actionable page even with 250 symbols loaded.

## Key inputs

| Input | Default | Notes |
| --- | --- | --- |
| `InpUseMarketWatch` | true | Off = use `InpSymbols` instead |
| `InpFilterInclude` / `InpFilterExclude` | "" | Substring filters, e.g. include `Index` for Deriv synthetics only |
| `InpMaxSymbols` | 250 | Hard cap |
| `InpSymbolsPerTick` | 6 | Raise to warm up faster, lower if the terminal feels heavy |
| `InpTimeframe` | `PERIOD_CURRENT` | Scan TF |
| `InpHtfTimeframe` | `PERIOD_CURRENT` | `CURRENT` = one step above the scan TF |
| `InpMinScore` | 55 | Raise for fewer, higher-quality signals |
| `InpOnlySignals` | false | Hide symbols with no live signal |
| `InpStatsBars` | 600 | Back-test window; `0` disables the WR column |
| `InpAlertPopup` / `InpAlertPush` | false | Fire once when a signal prints on the last closed bar |

## Limitations

- The on-chart trade box only draws when the chart timeframe matches the scan timeframe. If
  they differ the box would anchor to the wrong bars, so it is hidden rather than drawn wrong.
- The panel is pixel-laid-out for `Consolas` 8 / 18 px rows. Changing font size usually needs
  `InpRowHeight` adjusted too; with all columns on it is about 1150 px wide.
- Inline EMA/ATR/RSI are seeded from the oldest bar in the copied window rather than from the
  full symbol history, so values can differ from `iMA`/`iATR`/`iRSI` in the last decimals on the
  oldest bars of the window. Warm-up is `4 × slow EMA` bars, which puts the difference far
  outside the range that signals are read from.
- Back-tested trades that neither hit TP1 nor SL within `InpStatsMaxHold` bars are excluded from
  `WR` rather than counted as wins.

## Install

1. Copy `MarketFlowV8.mq5` to `<MT5 data folder>/MQL5/Indicators/` (File → Open Data Folder).
2. Compile with **F7** in MetaEditor.
3. Drag **MarketFlow V8** onto any chart.

It places no orders and needs no trading permissions.

## Relation to `config.json`

`config.json` in the repository root is the remote-control state for the EA (`ea_status`,
`mode`, `hedging`). This indicator is display-only and does not read or write it.
