# How to compile and run the EA — step by step

**None of this has been compiled.** I cannot run MetaEditor. Everything about
expected errors below is a prediction, not a result. Follow the steps in order
and paste me whatever MetaEditor says.

---

## Step 1 — Find your data folder

In MetaTrader 5: **File → Open Data Folder**. A window opens. Inside it there
is an `MQL5` folder. That folder is where everything goes.

Leave that window open. You will need it in step 2.

---

## Step 2 — Copy the files in

Copy from this repo into the `MQL5` folder you just opened:

| From the repo | To |
|---|---|
| `Include/SEA/` (whole folder, 23 `.mqh` files) | `MQL5/Include/SEA/` |
| `Experts/SEA/SEA.mq5` | `MQL5/Experts/SEA/` |
| `Scripts/SEA/*.mq5` (3 files) | `MQL5/Scripts/SEA/` |

Create the `SEA` subfolders if they do not exist. Do **not** copy `Files/` —
the EA writes into the terminal's own `MQL5/Files/` at runtime.

Check afterwards that `MQL5/Include/SEA/CSymbolSpec.mqh` exists. If the path
is wrong you will get `cannot open source file` on every compile.

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

| File | What it does |
|---|---|
| `Test_CSymbolSpec.mq5` | Broker spec, lot rounding, filling bitmask |
| `Test_Repaint.mq5` | The mandatory repaint test |
| `Test_RiskHalt.mq5` | Drawdown halt persistence and sizing |

---

## Step 6 — Compile the EA

Open `SEA.mq5`, press **F7**. If steps 4 and 5 were clean this should be too.

---

## Step 7 — Run the tests BEFORE the EA

This order matters. Each test gates the next.

### 7a. Symbol spec

Drag `Test_CSymbolSpec` onto any chart. Read the **Experts** tab.

Look at **section 4** — the lot-rounding sweep. Any `FAIL` there means sizing
is unsafe and you must stop. Everything else in the EA trusts this module's
arithmetic.

### 7b. Repaint

Drag `Test_Repaint` onto a chart with plenty of history (scroll back first to
force the download, or the script will abort saying so).

Every check must pass. A repaint failure means a module read a forming bar and
the build is broken — not "slightly off". Send me the output if anything fails.

### 7c. Risk halt

**Demo account only.** The script refuses to run on a live account.

Run it in four passes using the `InpPhase` input:

1. `InpPhase = 4` (SIZING) — sizing, ladder and the "losses never raise risk"
   check. Run this first; it needs no restart.
2. `InpPhase = 1` (ARM) — writes a hard-halt flag.
3. **Fully close and reopen MetaTrader.** Not just the chart — the whole
   terminal. The point is proving the kill switch survives a process restart.
4. `InpPhase = 2` (VERIFY) — a fresh risk manager must come up already halted.
5. `InpPhase = 3` (RESET) — clears the flag.

If `InpMagicNumber` here does not match the EA's magic, the test writes to the
wrong key and proves nothing. Keep them the same.

---

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
   hot list work, but the tick path does not yet use hot membership to run
   trigger checks between bars. Entries currently arm on the LTF close only.
   That is safe — it just means the EA is slower to react than the tiering
   design allows.

3. **`CZones` and `CLiquidity` have no dedicated test scripts.** They are
   covered by `Test_Repaint` for determinism, but not for correctness of the
   zones and levels themselves.

4. **`CGates`, `CScoring`, `CScaling` have no unit tests.** Their logic is
   exercised only through the live pipeline.

5. **Latency is unmeasured.** The instrumentation is in place and will print
   overruns naming the phase, but nobody has seen a real number yet. Expect
   the HTF pass to be the one that complains first on a wide universe.

---

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
