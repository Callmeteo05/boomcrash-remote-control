# Flag Structure Pro

Non-repainting bull/bear flag detection for MetaTrader 5, with breakout +
retest confirmation and higher-timeframe bias filtering. Symbol- and
broker-agnostic.

**File:** `FlagStructurePro.mq5` → compile into `MQL5/Indicators/`.

---

## What it does

Per closed bar, in order:

1. **HTF bias gate.** Reads a higher timeframe (auto-mapped from the chart
   TF, or set explicitly) and resolves BULLISH / BEARISH / NEUTRAL from two
   independent tests that must agree:
   - EMA(50) slope over the last 3 *closed* HTF bars, normalised to HTF ATR,
     exceeding `InpHTF_SlopeATR` per bar;
   - the last 2 confirmed HTF swing highs **and** swing lows both ascending
     (bullish) or both descending (bearish), searched over a **fixed**
     `InpHTF_SwingLookback` window.

   Disagreement → NEUTRAL → all signals suppressed.

2. **Stage 1 — pole.** Anchors on a K-bar-confirmed swing low (bull) or
   swing high (bear), then requires a move to the extreme within
   `InpPoleMaxBars` that is:
   - ≥ `InpPoleMinATR` × ATR(14) tall,
   - ≥ `InpPoleEfficiency` directionally efficient
     (`|net move| / Σ|bar ranges|`),
   - free of any counter-retracement deeper than `InpPoleMaxRetrace`.

3. **Stage 2 — flag.** 3–15 closed bars retracing 23.6–61.8% of the pole,
   sloping counter-trend or flat (flags sloping *with* the pole are
   rejected), with **tightness** = `flag_range / pole_height` ≤
   `InpMaxTightness`. Upper and lower boundaries are least-squares fits over
   the flag bars only, then shifted to envelope the extremes — a raw LS line
   sits in the middle of the highs and is not a boundary.

4. **State machine.**

   ```
   IDLE → FLAG_FORMED → BROKEN → RETESTING → CONFIRMED
                          │          │
                          └──────────┴──→ INVALIDATED / BREAKOUT_ONLY
   ```

   - **BROKEN** — a bar *closes* beyond the boundary by
     `InpBreakBufferATR` × ATR. Wick-only breaks do not qualify.
   - **RETESTING** — within `InpRetestWindow` bars, price trades back to
     within `InpRetestToleranceATR` × ATR of the broken level.
   - **CONFIRMED** — a closed bar rejects from the retest zone: it closes in
     the breakout direction *and* beyond the broken level. The signal is
     emitted on **this** bar.
   - **INVALIDATED** — close beyond the opposite flag boundary, close past
     the pole origin, HTF bias flip before confirmation, or no break inside
     the break window.
   - **BREAKOUT_ONLY** — the retest window expired without confirmation.
     Emitted on a separate buffer, not discarded: you need both populations
     to compare.

5. **Quality score (0–100)**, weighted from tightness (20), pole ATR
   multiple (15), pole efficiency (15), retracement depth (15), flag bar
   count (10), HTF bias strength (15) and breakout close strength (10).
   Written to a buffer, the log, and the CSV.

### Asymmetry

Bear flags underperform bull flags materially in published data, so bear
thresholds are **independent inputs**, not mirrored logic, and default
stricter:

| | Bull | Bear |
|---|---|---|
| Pole min ATR | 2.5 | 3.0 |
| Pole efficiency | 0.55 | 0.62 |
| Pole max counter-retrace | 38.2% | 30.0% |
| Max retracement | 61.8% | 50.0% |
| Max tightness | 0.50 | 0.40 |
| Break buffer | 0.25 ATR | 0.35 ATR |
| Retest window | 10 bars | 8 bars |
| Min flag bars | 3 | 4 |

---

## Non-repaint contract

This is the primary requirement, and it shapes everything else.

| Rule | Implementation |
|---|---|
| Closed bars only | `ProcessBar(i)` is called for `i ≤ rates_total-2`. Buffers at `rates_total-1` are forced to `EMPTY_VALUE` on every call. |
| Immutable verdicts | Signals are appended to `g_sigs[]`, keyed by bar open time, and written once. The incremental path resumes strictly after `g_lastProcessedTime` (a *datetime*, immune to index shifts). |
| HTF reads closed bars only | `hshift = iBarShift(...)` gives the **forming** HTF bar; everything downstream uses `hshift + 1`. HTF swings additionally require their K-bar confirmation to have elapsed by `hshift+1`. |
| No look-ahead in swings | A swing at bar `j` is confirmed at `j+K` and used from `j+K` onward. Never backdated. |
| Partial data | If any `CopyBuffer` / `CopyHigh` / `CopyLow` returns fewer bars than requested, `OnCalculate` returns `prev_calculated` and computes nothing. |
| New bar only | Gated by the stored `g_lastProcessedTime`. |

Two consequences are deliberate:

- **BREAKOUT_ONLY prints on the window-expiry bar**, not the breakout bar.
  The breakout bar cannot know that no retest will follow.
- **CONFIRMED prints on the rejection bar**, typically several bars after
  the break. That lateness is what the contract costs.

Because full recalculation (`prev_calculated == 0`) replays the identical
causal sequence from scratch, a history reload cannot change any past bar's
value.

### Two subtleties that would otherwise repaint the HTF bias

Both are handled, and both are easy to reintroduce if this code is edited:

1. **The swing search window must be fixed width.** Searching "backwards
   until 2 swings are found" makes the answer depend on how many HTF bars
   happen to be loaded — a short snapshot finds fewer swings than a long one
   and returns NEUTRAL where the long one returns a bias. The search is
   bounded to exactly `InpHTF_SwingLookback` bars starting at `hshift+1+K`,
   so the same absolute HTF bars are consulted in every run.

2. **The HTF snapshot must span the whole chart range.** With a fixed recent
   window, an old chart bar sits outside it and falls back to NEUTRAL on a
   history reload, while the same bar in a forward tester run — where it was
   once the *current* bar, close to the snapshot's end — resolved to a real
   bias. The snapshot is therefore sized from `rates_total` and the chart/HTF
   period ratio, not from a constant.

   If the broker's HTF history is shallower than the chart range, the oldest
   chart bars resolve to NEUTRAL and emit nothing (the conservative
   direction), and the log says so once. **Download full HTF history before
   running the A/B test**, or the two runs may cover different spans.

---

## Validation harness

### CSV export (`InpExportCSV`)

`MQL5/Files/FSP_signals_<SYMBOL>_<TF>.csv`, one row per signal:

```
datetime, symbol, timeframe, direction, pole_ATR, tightness,
retracement_pct, flag_bars, htf_bias, quality_score, break_bar_time,
retest_bar_time, confirmed_bool, MFE_10, MFE_20, MFE_50,
MAE_10, MAE_20, MAE_50, pole_efficiency
```

MFE/MAE are in ATR units and **forward-looking by definition**. A row is
only written once its full 50-bar horizon is closed history, it goes to file
only, and nothing in the signal path ever reads it back. It exists for
offline analysis.

The file is truncated and re-headed on every full recalculation, so it never
accumulates duplicates.

### Repaint self-test (`InpRepaintTest`)

Dumps every signal — bar time, type, price, quality — at `OnDeinit`, i.e.
once a run is complete.

1. Delete any existing `MQL5/Files/FSP_repaint_<SYM>_<TF>_*.csv`.
2. Run in **Strategy Tester visual mode** over the target range, forward,
   to the end. At deinit the dump is written as `..._A.csv` and the log
   prints `REPAINT TEST: baseline written`.
3. Attach to a normal chart (or re-run the tester non-visual) over the
   **same range**, so the whole range arrives as closed history in one shot.
   At deinit `..._B.csv` is written and compared to A byte for byte.
4. The log prints `REPAINT TEST: PASS` or `REPAINT TEST: FAIL` with the
   first differing byte offset.

The comparison is deliberately at `OnDeinit` and not mid-run: comparing a
partial A against a complete B would report a false FAIL.

### Acceptance

The indicator is not done until the repaint test prints **PASS on 3 symbols
across 3 timeframes**, including at least one symbol with weekend gaps
(EURUSD, XAUUSD) and at least one 24/7 synthetic. Nine runs, nine PASSes.

---

## Symbol / broker agnosticism

- Every threshold is an ATR multiple or a point value. There are zero
  hardcoded pip constants.
- `SYMBOL_DIGITS`, `SYMBOL_POINT` and `SYMBOL_TRADE_TICK_SIZE` are read once
  at init. 3- and 5-digit brokers need no special casing.
- Suffixed symbols (`EURUSD.m`, `XAUUSDx`, `R_100`) work because the symbol
  name is never parsed — it is only sanitised character-by-character for
  filenames.
- **Gaps:** at init the indicator samples up to 5000 bar time deltas. If any
  exceeds `2 × PeriodSeconds()`, the instrument has session breaks and
  patterns are forbidden from spanning one. 24/7 synthetics report no gaps
  and the check becomes a no-op — detected from the series, never from a
  symbol name.

---

## Drawing

Bounded objects only. Every `OBJ_TREND` has `OBJPROP_RAY_LEFT` and
`OBJPROP_RAY_RIGHT` set to `false`; no `OBJ_TRENDBYANGLE`, no rays, no
full-chart horizontal lines.

| Object | Extent | Style |
|---|---|---|
| Pole | anchor bar → pole extreme bar, no extension | width 1, `STYLE_DOT` |
| Flag channel (2 lines) | flag bars + `InpProjectBars` forward, then stop | width 1, `STYLE_SOLID` |
| Break level | break bar → `InpProjectBars` forward | width 1, `STYLE_SOLID` |
| Retest zone | `OBJ_RECTANGLE` bounded to the retest window bars | `OBJPROP_BACK = true` |

- Objects freeze at their final extent once a setup reaches CONFIRMED or
  INVALIDATED.
- `InpMaxVisibleSetups` (5) — objects for the oldest setup beyond this count
  are deleted.
- `InpHistoryBarsToDraw` (500) — setups older than this are never drawn.
  **Buffers still hold their signals.**
- Everything is `OBJPROP_SELECTABLE = false` and `OBJPROP_HIDDEN = true`, so
  it cannot be dragged out of alignment. Full cleanup in `OnDeinit` via the
  `FSP_` prefix.

---

## Buffers

| # | Name | Notes |
|---|---|---|
| 0 | `BullConfirmed` | arrow below the rejection bar |
| 1 | `BearConfirmed` | arrow above the rejection bar |
| 2 | `BullBreakoutOnly` | window expired without confirmation |
| 3 | `BearBreakoutOnly` | window expired without confirmation |
| 4 | `HTFBias` | −1 / 0 / +1 per bar — Data Window |
| 5 | `QualityScore` | 0–100 at signal bars — Data Window |

Buffers 4 and 5 are `DRAW_NONE`: an indicator lives in one window, and
plotting a −1…+1 series on a price chart is unreadable. Their values are
visible per-bar in the Data Window and readable via `iCustom`, which is what
"verify visually" needs in practice.

---

## Notes on what is deliberately absent

- **No win-rate or accuracy display.** There is no honest fixed number to
  show. Use the CSV and the MFE/MAE columns.
- **No smoothing that looks ahead.**
- **Volume is not a hard filter.** `InpUseVolume` defaults to `false`: MT5
  tick volume is broker-dependent and meaningless on synthetics.
- **Defaults are not tuned to make history look clean.** They come from the
  geometry described in the flag literature. Tune them against the CSV, not
  against the chart's appearance.

---

## Known behaviour worth knowing before you tune

- One live setup per direction at a time. A new pole+flag is not searched
  for while a setup in that direction is still travelling the state machine.
- `InpBreakWindow` (bull 20 / bear 15 bars) bounds how long a formed flag
  waits for a break before being abandoned. It is not in the original
  geometry spec but is needed so stale flags don't linger indefinitely.
- `InpFlagSlopeTolATR` sets how much *with-pole* slope counts as "flat"
  before the flag is rejected. At 0 you reject any upward drift in a bull
  flag, which is stricter than most published definitions.
