# MarketFlow V8 — MT5 signals dashboard

`MarketFlowV8.mq5` is a chart-window indicator that scans a list of symbols on one
timeframe and renders:

- a docked **signals dashboard** — `SYMBOL | TF | SIGNAL | AGE | ENTRY | SL | TP1 | TP2 | TP3 | CHART`,
  paginated with ▲/▼ and a `1-9 / 14` counter, one `OPEN` button per row that switches the
  chart to that symbol;
- the **trade projection** for the chart symbol — box from SL to TP3, entry line across the
  chart, SL/TP1/TP2/TP3 levels with price labels, an arrow on the signal bar, a dashed marker
  at the signal bar, and a `◈ TRADE / ▲ BUY+ CONTINUATION` legend;
- a symbol/timeframe watermark in the top-right corner.

## Install

1. Copy `MarketFlowV8.mq5` into `<MT5 data folder>/MQL5/Indicators/`
   (File → Open Data Folder in the terminal).
2. In MetaEditor press **F7** to compile.
3. Drag **MarketFlow V8** onto a chart. Enable *Allow Automated Trading* is **not** needed —
   this is an indicator, it places no orders.

Every symbol in the list must exist at the broker with that exact name. The indicator calls
`SymbolSelect()` to pull each one into Market Watch; symbols the broker does not offer are
shown as `n/a — not in market watch` instead of being silently dropped.

## Signal engine

Everything is evaluated on **closed bars only** (shift ≥ 1), on the scan timeframe.

| Concept | Rule |
| --- | --- |
| Trend | `EMA(21) > EMA(50)` = up, `<` = down |
| **BUY+** (continuation) | uptrend, bar dipped to/through the fast EMA, closed back above it, bullish body |
| **SELL+** (continuation) | downtrend, bar rallied to/through the fast EMA, closed back below it, bearish body |
| **BUY-** (reversal) | downtrend, `RSI(14) ≤ 30`, bullish body closing above the previous bar's high |
| **SELL-** (reversal) | uptrend, `RSI(14) ≥ 70`, bearish body closing below the previous bar's low |

The scan walks back up to `InpMaxAge` bars and reports the most recent hit, so a signal stays
on the board while it is still tradable. `AGE` reads `current` on the last closed bar, then
`1 bars ago`, `2 bars ago`, …

Suffix in the `SIGNAL` cell: `+` = continuation, `-` = reversal.

## Risk model

```
risk  = ATR(14) at the signal bar * InpSLAtrMult      (default 1.5)
entry = close of the signal bar
SL    = entry -/+ risk
TP1   = entry +/- risk * 1.5
TP2   = entry +/- risk * 2.5
TP3   = entry +/- risk * 4.0
```

The 1.5R / 2.5R / 4R ladder is the ratio the reference screenshots resolve to
(e.g. Boom 1000: entry 13878.1610, SL 13843.7815 → risk 34.3795 → TP1 13929.7302,
TP2 13964.1097, TP3 14015.6789). All four multipliers are inputs, so re-tune them if your
own ladder differs.

## Inputs worth knowing

| Input | Default | Notes |
| --- | --- | --- |
| `InpSymbols` | Deriv synthetics + BTCUSD/ETHUSD/EURUSD/AUDCHF | Comma separated; spaces inside a name are kept |
| `InpTimeframe` | `PERIOD_CURRENT` | Scan TF; `PERIOD_CURRENT` follows the chart |
| `InpMaxAge` | 12 | How long a signal stays on the board |
| `InpRefreshSeconds` | 2 | Rescan interval; the indicator also runs on a 1s timer so it updates on symbols the chart isn't showing |
| `InpOnlySignals` | false | Hide rows with no live signal |
| `InpSortFreshest` | false | Sort by age instead of list order |
| `InpRowsVisible` | 9 | Rows per page |
| `InpAlertPopup` / `InpAlertPush` | false | Fire once per symbol when a signal prints on the last closed bar |

## Known limitations

- The panel is laid out in pixels for `Consolas` at size 8. Changing `InpFontSize` or `InpFont`
  much may need `InpRowHeight` and the panel origin adjusted to match.
- The on-chart trade is drawn only when the chart symbol is in `InpSymbols`. If `InpTimeframe`
  is pinned to something other than the chart period, the box anchors to bar times of the scan
  timeframe and will look offset — keep them the same, or leave `InpTimeframe` on
  `PERIOD_CURRENT`.
- Scanning many symbols pulls history for each one; the first few seconds after attach can show
  blank rows while the terminal downloads bars.

## Relation to `config.json`

`config.json` in the repository root is the remote-control state for the EA
(`ea_status`, `mode`, `hedging`). This indicator is display-only and does not read or write it.
