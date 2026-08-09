# MarketFlow V8 — TradingView (Pine v6)

`MarketFlowV8.pine` is a port of the MT5 indicator. Same engine: higher-timeframe bias →
chart-timeframe structure shift → SMC leg or EMA/RSI leg → POI entry with premium/discount
enforced → liquidity targets → alert at the fill.

## Read this before comparing it to the MT5 build

TradingView is not MetaTrader, and three limits are the platform's, not choices made here.

| | MT5 | TradingView |
| --- | --- | --- |
| Symbols scanned | entire Market Watch, no cap | **16** |
| Bias timeframes | two real ones (H1 + H4) | one real + one derived |
| Jump chart to a row | `OPEN` button per row | not possible in Pine |
| Panel scrolling | ▲▼ and page jump | none — all 16 rows always shown |
| Measured hit rate (`WR`) | back-tested per symbol | not included |

**Why 16 and not 100+.** Pine permits a maximum of **40 `request.*()` calls per script**. This
scanner spends two per symbol — the engine on the chart timeframe and the bias on the bias
timeframe — plus one for the chart symbol's own bias, so 33 of 40 are used at 16 symbols. No
Pine script can scan 100 symbols. If a TradingView indicator claims it does, it is either
counting differently or not doing per-symbol analysis.

**Why one real bias timeframe.** A second real one would cost 16 more calls and drop the
universe to about 8 symbols. Instead the bias call returns two readings from one series: the
near bias at the configured pivot strength, and a *far* bias from the same series read with
pivots `farMult`× longer. That approximates the next timeframe up. It is an approximation, and
the MT5 build's two genuine timeframes are stricter.

**No `WR` column.** The MT5 version back-tests the identical rule per symbol and prints the
measured hit rate with its sample size. Doing that here would mean replaying the engine over
hundreds of bars inside every `request.security()` call, which exceeds Pine's execution budget.
Use TradingView's own bar replay, or trust the MT5 figure — it is the same rule.

## What is faithful

- Non-repainting on the same terms: `ta.pivothigh(L, L)` confirms a pivot only after `L` newer
  bars, exactly as the MT5 fractal walk does; bias is withheld until price has broken structure
  once and events until the second break, so no signal depends on where the series started.
- Entry is a **limit at the POI** — order block and/or fair value gap, overlap preferred.
- Premium/discount is a **hard rejection** on the chart timeframe's dealing range.
- One live setup per symbol, released at TP3 or the stop, then free to produce the next.
- Stop counted first when a bar touches both stop and target.
- Grades: **A+** both legs, **A** SMC leg, **B** trend leg.
- The alert fires when the limit becomes **fillable**, not when the setup is drawn.

## Install

1. TradingView → Pine Editor → paste `MarketFlowV8.pine` → **Add to chart**.
2. Fill the 16 symbol slots in settings. Blank slots are skipped.
3. Set the bias timeframe (default 240 = H4). Keep it above your chart timeframe.
4. Right-click the alert → **Add alert on MarketFlow V8** → condition *MarketFlow V8 entry*.

Alerts fire for the **chart symbol only** — Pine cannot raise an alert from inside a
`request.security()` call. To be alerted on all 16, put the indicator on 16 charts, or run the
MT5 build, which alerts across the whole Market Watch from one chart.

## Dashboard

`SYMBOL · TF · SIGNAL · GRADE · SCORE · AGE · ENTRY · SL · TP1 · TP2 · TP3 · STATUS`

A slot with no tradable setup still shows its directional lean and `WATCH`, with the price
columns blank — a lean is never dressed up as an entry.
