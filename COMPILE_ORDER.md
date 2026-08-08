# How to compile and run the EA — step by step

**None of this has been compiled.** I cannot run MetaEditor. Everything about
expected errors below is a prediction, not a result. Follow the steps in order
and paste me whatever MetaEditor says.

---

## Steps 1-3 — Install the files

See **`INSTALL.md`** for downloading from GitHub, finding the MetaTrader data
folder, and copying the files into place.

Short version: **File → Open Data Folder** in MT5, then

```
Include/SEA/*.mqh   (23 files)  ->  MQL5/Include/SEA/
Experts/SEA/SEA.mq5 (1 file)    ->  MQL5/Experts/SEA/
Scripts/SEA/*.mq5   (8 files)   ->  MQL5/Scripts/SEA/
```

`MQL5/Include/SEA/CSymbolSpec.mqh` must exist before you go on.

---

## Step 3 — Open MetaEditor

In MetaTrader: **Tools → MetaQuotes Language Editor**, or press **F4**.

In the Navigator panel on the left you should now see your `SEA` folders under
Include, Experts and Scripts. If not, right-click the Navigator root and pick
**Refresh**.

---

## Step 4 — Compile the headers one at a time, in this order

**Do not start with `SEA.mq5`.** It pulls in all 22 headers, so a single bad
header buries you in hundreds of cascading errors that all point at the wrong
place.

Open each file below, press **F7**, and fix it before moving to the next.

| # | File |
|---|---|
| 1 | `SEA_Common.mqh` |
| 2 | `CSymbolSpec.mqh` |
| 3 | `CStyle.mqh` |
| 4 | `CRiskManager.mqh` |
| 5 | `CTradeExec.mqh` |
| 6 | `CStructure.mqh` |
| 7 | `CZones.mqh` |
| 8 | `CLiquidity.mqh` |
| 9 | `CPhase.mqh` |
| 10 | `CRegime.mqh` |
| 11 | `CSymbolProfiler.mqh` |
| 12 | `CSpikeHazard.mqh` |
| 13 | `CAffordability.mqh` |
| 14 | `CMTF.mqh` |
| 15 | `CProbabilityMap.mqh` |
| 16 | `CGates.mqh` |
| 17 | `CScoring.mqh` |
| 18 | `CManagement.mqh` |
| 19 | `CScaling.mqh` |
| 20 | `CScanner.mqh` |
| 21 | `CAlert.mqh` |
| 22 | `CJournal.mqh` |
| 23 | `CDashboard.mqh` |

**A header compiled on its own will say something like "no executable code" or
produce an empty `.ex5`. That is expected and is not a failure.** You are only
checking that the Errors tab is empty.

When you hit an error, copy the whole Errors tab — file, line, and message —
and send it to me. Do not guess at fixes; several of these interlock.

---

## Step 5 — Compile the scripts

| File | What it does | Needs market data? |
|---|---|---|
| `Test_CSymbolSpec.mq5` | Broker spec, lot rounding, filling bitmask | live spec |
| `Test_CGates.mq5` | All ten gates, no-compensation | **no** — pure unit test |
| `Test_CScoring.mq5` | Every point value against the documented scale | **no** — pure unit test |
| `Test_CScaling.mq5` | Decay ladder and every refusal | synthetic positions |
| `Test_CZones.mq5` | Zones re-derived from raw bars | live bars |
| `Test_CLiquidity.mq5` | Levels and sweeps re-derived from raw bars | live bars |
| `Test_Repaint.mq5` | The mandatory repaint test | live bars |
| `Test_RiskHalt.mq5` | Drawdown halt persistence and sizing | demo account |

---

## Step 6 — Compile the EA

Open `SEA.mq5`, press **F7**. If steps 4 and 5 were clean this should be too.

---

## Step 7 — Run the tests BEFORE the EA

This order matters. Each test gates the next.

### 7a. Pure unit tests — run these first, they need nothing

`Test_CGates` and `Test_CScoring` build every input by hand and know every
expected answer. No market data, no account, no history. If either fails, the
decision layer is wrong and nothing downstream is worth running.

- **`Test_CGates`** — builds a context that passes all ten gates, then breaks
  exactly one field at a time and asserts that *that* gate fails, that the
  setup is rejected, and that **no other gate failed**. That last clause is
  what catches a gate reading the wrong field. It also proves a maximal
  score cannot buy a failed gate, and that with-spike entries stay permitted
  at EXTREME hazard while counter-spike entries are refused.

- **`Test_CScoring`** — pins every point value against the scale in CLAUDE.md,
  including the boundaries (RR exactly 3.0 earns the bonus, 2.99 does not) and
  the rule that a noisy profile can *raise* the confluence threshold but never
  lower it.

### 7b. Symbol spec

Drag `Test_CSymbolSpec` onto any chart. **Section 4 is the one that matters** —
the lot-rounding sweep. Any FAIL there means sizing is unsafe; stop.

### 7c. Zones and liquidity — independent recomputation

`Test_CZones` and `Test_CLiquidity` re-derive the answers straight from the raw
`MqlRates` array using their own arithmetic and compare. Two engines agreeing
by accident is unlikely; disagreement means one is wrong.

`Test_CZones` checks that every FVG in the bars was found and no phantom exists,
that each order block spans exactly its origin candle body and came from a
candle of the right colour, that FRESH zones were genuinely never entered, and
that a stricter impulse threshold never produces *more* order blocks.

`Test_CLiquidity` re-reads PDH/PDL/PWH/PWL from the daily and weekly series and
confirms they came from the **closed** bar, then re-derives every swept flag
from the bars. It also verifies the sweep-versus-break distinction: a reported
sweep must have both a wick beyond *and* a close back inside within the window.
Get that wrong and CPhase sees false manipulation, which is how an EA ends up
buying every dip out of a range.

### 7d. Scaling — the martingale check

`Test_CScaling` tracks positions **synthetically** — it places no orders and
touches nothing live. Entry prices are set relative to the current market price
so the winner and loser branches fire deterministically.

It walks the decay ladder past the broker minimum looking for a rounding bug,
and asserts every refusal: a position in drawdown, a winner before break-even,
a direction mismatch, a changed structure, a leg ceiling, and NULL engines.

Use a `InpTestMagic` that is **not** your EA's magic. The script refuses the
default and cleans up its GlobalVariables afterwards.

### 7e. Repaint

Drag `Test_Repaint` onto a chart with plenty of history. Every check must pass.
A repaint failure means a module read a forming bar — broken, not "slightly
off".

### 7f. Risk halt

**Demo account only.** The script refuses to run on a live account.

1. `InpPhase = 4` (SIZING) — sizing, ladder, and the "losses never raise risk"
   check. Needs no restart.
2. `InpPhase = 1` (ARM) — writes a hard-halt flag.
3. **Fully close and reopen MetaTrader.** Not just the chart.
4. `InpPhase = 2` (VERIFY) — a fresh risk manager must come up already halted.
5. `InpPhase = 3` (RESET) — clears the flag.

Keep `InpMagicNumber` the same as the EA's, or the test writes to the wrong key
and proves nothing.

## Step 8 — Attach the EA, on demo

1. Enable **AutoTrading** (the toolbar button).
2. Drag `SEA` onto a chart.
3. On the **Common** tab, tick *Allow Algo Trading*.
4. On the **Inputs** tab, set `InpMagicNumber` — and if you ran the risk test,
   make it the same number you reset in phase 3.
5. Set `InpVerbose = true` for the first session. It is noisy and that is the
   point.

Watch the Experts tab at startup. You should see the universe size, how many
symbols are tradeable, and — if most of them are not — a warning naming the
constraint responsible.

**If the EA reports a hard halt at startup, that is a persisted flag from an
earlier drawdown breach or from the risk test. It will not trade until you
clear it with `Test_RiskHalt` phase 3. That is deliberate.**

---

## What I fixed in this pass

| Was | Now |
|---|---|
| Object pointers passed to reference parameters — the most likely compile failure | Every such parameter converted to a pointer, with NULL guards inside. No ambiguity left |
| `CStructure::ResolveState` was O(bars × swings) — ~64k comparisons per rebuild | Single forward pass, O(bars + swings). Swings activate in confirmation order |
| Rejection journal logged zeros for entry/stop/target, so the 20-bar review could not decide anything | `CScanner` retains the full `SGateContext`; the journal replays real prices |
| `CStyle::ResolveAuto` existed but nothing called it — AUTO silently ran as INTRADAY | `ResolveAutoStyle()` measures each candidate style at its own exec timeframe across a 12-symbol sample and resolves at init |
| No repaint test, despite CLAUDE.md marking it mandatory | `Test_Repaint.mq5` — repeated-rebuild determinism, historical stability under a growing lookback, and the shift-0 refusal |
| No drawdown-halt test | `Test_RiskHalt.mq5` — including the forced-restart persistence check |
| Correlation collapse grouped by currency *pair*, so three trades sharing one currency all passed | Counts exposure per individual currency, both sides. Synthetics still exempt |
| `CSymbolProfiler` had no way to measure style fitness | `MeasureStyleFitness()` returns spread/ATR, ticks per bar and cleanliness at any timeframe |
| `AllocateWarm` took five unused parameters | Reduced to the one it uses |

---
| `CZones`, `CLiquidity`, `CGates`, `CScoring`, `CScaling` had no correctness tests | Five new scripts. `CGates` and `CScoring` are pure unit tests; `CZones` and `CLiquidity` independently re-derive their answers from raw bars; `CScaling` walks the decay ladder and every refusal with synthetic positions |
| `PERIOD_CURRENT` appeared as a member initialiser in five modules, against RULE 10 | Replaced with `SEA_TF_UNSET`. Only `CStyle` names a `PERIOD_` constant now |
| Nothing stopped this untested EA being attached to a real account | `InpAllowLiveTrading` and `InpAcknowledgeUntested`, both defaulting to false. `OnInit` returns `INIT_FAILED` on a real account unless both are set, and logs the account it is attached to either way |

## Errors I still expect

| Message | Cause | Fix |
|---|---|---|
| `'ORDER_FILLING_BOC' - undeclared identifier` | Terminal build predates BOC | Tell me — three references in `CSymbolSpec.mqh`. The mask flag is already build-independent |
| `'SYMBOL_EXIST' - undeclared identifier` | Very old build | Swap for a `SymbolSelect` probe |
| `'input group' - unexpected token` | Build below ~2000 | Replace each `input group "..."` line with a comment |
| `possible loss of data due to type conversion` | A `long`→`int` narrowing I missed | Send the line number |
| `declaration of 'X' hides global declaration` | An `SEA_*` constant clashing with something already in your Include tree | I will namespace it further |
| `'m_lastGateCtx' - not enough memory` | 64 `SGateContext` structs is a large static array | Lower `SEA_MAX_WARM` in `CScanner.mqh` |

---

## What is still not done

Honest list. None of this is hidden in the code.

1. **The bar-close clock is the chart symbol.** `OnTick` detects HTF and LTF
   closes on `_Symbol` only, so symbols on other sessions update on the chart
   symbol's cadence rather than their own. Correct for a single-symbol chart,
   approximate across a broad universe.

2. **Tier 1 (hot) is allocated but not driving anything.** `PromoteHot` and the
   hot list work, but the tick path does not use hot membership to run trigger
   checks between bars. Entries arm on the LTF close only — safe, just slower
   than the tiering design allows.

3. **`CMTF`, `CProbabilityMap`, `CManagement`, `CSymbolProfiler` and
   `CTradeExec` have no dedicated tests.** `CMTF` and `CProbabilityMap` are
   exercised through the live pipeline; `CTradeExec` cannot be unit-tested
   without placing orders, so its retcode paths are unverified until a demo
   trade actually requotes or returns 10030.

4. **Latency is unmeasured.** Instrumentation is in place and prints overruns
   naming the phase, but nobody has seen a real number. Expect the HTF pass to
   complain first on a wide universe.

## Before this touches real money

From CLAUDE.md's own testing section. None of it has been done:

- real-tick backtests, walk-forward, out-of-sample
- Monte Carlo confirming the drawdown halt holds
- the deliberate drawdown-halt test **with a forced terminal restart** (step 7c
  covers the persistence half; the live version still needs doing)
- 4–8 weeks demo forward test

The hard halt has never fired in anger. `Test_RiskHalt` phase 3 is the only way
back once it latches — that is by design, and you should confirm you can do it
before you need to.

The EA now refuses to start on a real account by default. Turning that guard
off is a deliberate two-switch action, and it should be the LAST thing you do,
not the first.
