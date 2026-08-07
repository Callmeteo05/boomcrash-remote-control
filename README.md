# CRT Sniper Signals

A non-repainting buy/sell dot indicator built on **Candle Range Theory**, gated by
higher-timeframe bias, market regime, and premium/discount location, and triggered
by a market structure shift plus a candlestick pattern.

Two implementations with identical logic:

| Platform | File |
| --- | --- |
| MetaTrader 5 | `MT5/Indicators/CRT_Sniper_Signals.mq5` |
| TradingView | `TradingView/CRT_Sniper_Signals.pine` |

On the chart you only ever see **dots, SL and TP lines, and the dashboard**. Every
EMA, ADX, swing, gap and range used to produce a signal stays hidden.

---

## The sequence the indicator runs

This is the CRT workflow, encoded step for step. A dot cannot print unless every
step passed.

1. **Anchor on a higher timeframe.** The last *closed* HTF candle (H4 / D1 / W1,
   auto-selected from your chart timeframe) becomes the anchor. With
   `Anchor must sit on a key S/R level` on, the anchor's low must be at or below the
   lowest low of the previous 10 HTF candles (bullish case), or its high at or above
   the highest high (bearish case) — i.e. there is real liquidity resting there.
2. **Mark CRT-High and CRT-Low.** The anchor candle's high and low define the range.
3. **Wait for the raid.** The next HTF candle must trade through the CRT-Low
   (bullish setup) or the CRT-High (bearish setup).
4. **Confirm the close.** That raiding candle must *close back inside* the range —
   above the CRT-Low for a bullish setup, below the CRT-High for a bearish setup.
   Only closed HTF candles are read, which is what makes the whole thing
   non-repainting.
5. **Drop to the lower timeframe.** Your chart timeframe becomes the execution
   timeframe.
6. **Look for an MSS.** A close through the last confirmed swing high (bullish) or
   swing low (bearish), where the leg into that break is at least `1.2 × ATR`.
   Break without displacement is not an MSS and is ignored.
7. **Enter on the retest.** The indicator takes the most recent fair value gap left
   by the displacement leg; if there is none, the last opposing candle before the
   impulse (order block); if there is none, the broken MSS level itself. Price must
   tap that zone and close a confirming candlestick pattern.

## The gates on top of the sequence

A valid CRT setup still gets rejected unless all of these agree:

- **HTF bias.** Buys need the anchor timeframe reading BULLISH, sells BEARISH.
  Bias comes from EMA 50 vs EMA 200, price vs EMA 200, EMA separation measured in
  ATR, and ADX. When it reads SIDEWAYS, nothing prints at all.
- **Premium / discount.** Position inside the CRT range, 0 % at the low and 100 % at
  the high. Buys only at or below 50 % (discount), sells only at or above 50 %
  (premium). Optionally the HTF dealing range must agree too.
- **EMA 50/200 on the signal timeframe.** Off / Soft (price on the right side of
  EMA 50) / Strict (EMAs stacked *and* price on the right side).
- **Cooldown.** A minimum bar gap between signals so one zone does not spray dots.

So by construction: a printed BUY means trend bullish + price in discount, and a
printed SELL means trend bearish + price in premium.

## How bullish / bearish / sideways is decided

```
separation = |EMA50 - EMA200|
trending   = ADX >= 20  AND  separation >= 0.25 x ATR

BULLISH   trending AND EMA50 > EMA200 AND price > EMA200
BEARISH   trending AND EMA50 < EMA200 AND price < EMA200
SIDEWAYS  everything else
```

Measuring separation in ATR rather than in points is what lets the same settings
work on EURUSD, XAUUSD, US30 and Boom/Crash without retuning.

## Multi-timeframe scaling

The dashboard's **Scale in** row is the practical output of the bias gate. When a
bullish CRT is armed on D1 and D1 bias is bullish, it reads `LONGS on H4 / H1 / M30`.

Drop the same indicator on those lower timeframes: the D1 CRT is still the anchor
(auto-selection maps H4 → D1 and H1 → D1), the bias gate is still bullish, so every
pullback that produces an MSS and a clean retest prints another buy dot. One
higher-timeframe dot becomes many lower-timeframe scale-in dots, all in one
direction. The same holds inverted for sells.

If you want the lower timeframes to keep using the *same* anchor as your D1 chart
rather than the auto-mapped one, set `Anchor timeframe` explicitly to `D1` on each
chart.

## Stop loss and targets

- **SL** — beyond the structural extreme: the lower of (lowest low of the last 6
  bars, zone low) for buys, minus `0.30 × ATR`. Mirrored for sells. A signal whose
  risk exceeds `4 × ATR` is dropped rather than taken at a bad price.
- **TP1** — 2.0 R.
- **TP2** — 3.5 R, or the opposing liquidity (CRT extreme / recent swing) when that
  sits further away and `Push TP2 to the opposing liquidity` is on.

---

## Install — MetaTrader 5

1. In MT5: **File → Open Data Folder → MQL5 → Indicators**
2. Copy `CRT_Sniper_Signals.mq5` in there.
3. In MetaEditor press **F7** to compile.
4. Drag it onto a chart from the Navigator.

### Reading the signals from an EA

Six buffers are exposed, so the EA in this repo can consume the indicator directly:

| Buffer | Contents |
| --- | --- |
| 0 | Buy dot price (`EMPTY_VALUE` when no signal) |
| 1 | Sell dot price (`EMPTY_VALUE` when no signal) |
| 2 | Stop loss |
| 3 | Take profit 1 |
| 4 | Take profit 2 |
| 5 | Direction: `+1` buy, `-1` sell, `0` none |

```mql5
int h = iCustom(_Symbol, _Period, "CRT_Sniper_Signals");
double dir[1], sl[1], tp1[1];
CopyBuffer(h, 5, 1, 1, dir);   // shift 1 = last closed bar
CopyBuffer(h, 2, 1, 1, sl);
CopyBuffer(h, 3, 1, 1, tp1);
if(dir[0] > 0) { /* buy at market, stop sl[0], target tp1[0] */ }
```

## Install — TradingView

1. Open the **Pine Editor**.
2. Paste `CRT_Sniper_Signals.pine`, click **Add to chart**.
3. For alerts, use **Any alert() function call** so the message carries entry, SL
   and both targets. `CRT Buy` / `CRT Sell` alert conditions are also available.

---

## Suggested settings

Defaults are tuned for FX and metals on M15–H1. Starting points elsewhere:

| Market | Anchor TF | Displacement | ADX trend | Max risk | Notes |
| --- | --- | --- | --- | --- | --- |
| FX majors, XAUUSD | auto | 1.2 | 20 | 4.0 | defaults |
| Indices (US30, NAS100) | auto | 1.4 | 22 | 4.5 | wider legs |
| Crypto | auto | 1.5 | 18 | 5.0 | trends persist, ADX gate can be looser |
| **Boom 500 / 1000** | H4 or D1 | 1.6 | 18 | 6.0 | see below |
| **Crash 500 / 1000** | H4 or D1 | 1.6 | 18 | 6.0 | see below |

### Boom and Crash

These indices drift one way and spike the other, so:

- Raise `Skip signal if risk > this (x ATR)` to about `6.0`. A spike through the
  structural low is normal and a tight cap would silently drop good setups.
- Raise `Min displacement of the MSS leg` to about `1.6` — ordinary drift bars
  otherwise register as displacement.
- On **Boom**, spikes are up: bullish CRT setups are the higher-quality side.
  On **Crash**, spikes are down, so bearish setups are.
- Keep `Block all signals while HTF is SIDEWAYS` on. The drift phase reads as
  sideways on ADX, which is exactly when you do not want to be taking the dots.

## Tuning

| Symptom | Change |
| --- | --- |
| Too few signals | `Anchor must sit on a key S/R level` off, `EMA filter` → Off, displacement → 1.0 |
| Too many signals | `EMA filter` → Strict, `Also gate on the HTF dealing-range position` on, cooldown → 5+ |
| Dots too far from the wick | `Dot distance from the wick` → 0.3 |
| Entries too deep in the pullback | `Retest zone source` → FVG only |
| Stops hit by noise | `SL buffer beyond structure` → 0.5 |

Turn on `Debug: draw the active CRT range` to see the anchor range the indicator is
currently working from. It is off by default so the chart stays clean.

---

## Not yet verified

The MQL5 source has not been run through MetaEditor and the Pine source has not
been loaded into TradingView from this environment — neither toolchain is available
here. Compile both before trading them, and backtest the settings on your own
symbol and broker feed.
