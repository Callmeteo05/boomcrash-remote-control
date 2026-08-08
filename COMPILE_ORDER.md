# Compile order and expected errors

**None of this has been compiled.** I cannot run MetaEditor. Everything below
is a prediction about what the compiler will say, not a report of what it said.

## Install

Repo root maps to your terminal's `MQL5/` folder:

```
Include/SEA/*.mqh   ->  <MT5 Data Folder>/MQL5/Include/SEA/
Experts/SEA/SEA.mq5 ->  <MT5 Data Folder>/MQL5/Experts/SEA/
Scripts/SEA/*.mq5   ->  <MT5 Data Folder>/MQL5/Scripts/SEA/
```

`Files/` is where the EA writes at runtime — it uses the terminal's own
`MQL5/Files/`, so nothing needs copying.

## Compile one file at a time, in this order

Do **not** start with `SEA.mq5`. It includes all 22 headers, so one bad
header produces a wall of cascading errors. Compile each header on its own
first (open it in MetaEditor and press F7) and fix it before moving on.

| # | File | Depends on |
|---|------|-----------|
| 1 | `SEA_Common.mqh` | nothing |
| 2 | `CSymbolSpec.mqh` | nothing |
| 3 | `CStyle.mqh` | Common |
| 4 | `CRiskManager.mqh` | Common, SymbolSpec |
| 5 | `CTradeExec.mqh` | Common, SymbolSpec |
| 6 | `CStructure.mqh` | Common |
| 7 | `CZones.mqh` | Common |
| 8 | `CLiquidity.mqh` | Common |
| 9 | `CPhase.mqh` | Common, Structure |
| 10 | `CRegime.mqh` | Common, Structure |
| 11 | `CSymbolProfiler.mqh` | Common |
| 12 | `CSpikeHazard.mqh` | Common, Profiler |
| 13 | `CAffordability.mqh` | Common, SymbolSpec, Risk, Profiler |
| 14 | `CMTF.mqh` | Common, Style, Structure, Zones, Liquidity |
| 15 | `CProbabilityMap.mqh` | Common, MTF |
| 16 | `CGates.mqh` | Common, MTF, Phase, Regime, Hazard, Afford, Probability |
| 17 | `CScoring.mqh` | Common, MTF, Phase |
| 18 | `CManagement.mqh` | Common, SymbolSpec, TradeExec, Structure, Regime, Hazard |
| 19 | `CScaling.mqh` | + Management |
| 20 | `CScanner.mqh` | almost everything |
| 21 | `CAlert.mqh` | Common |
| 22 | `CJournal.mqh` | Common, Gates |
| 23 | `CDashboard.mqh` | Common |
| 24 | `SEA.mq5` | all |

A header compiled alone will report *"no executable code"* or similar. That
is expected and is not an error — you are only checking for syntax and
symbol errors.

## The error I most expect

**Passing an object pointer where a reference parameter is declared.**

Several call sites hold a `CStructure *` / `CPhase *` / `CMTF *` and pass it
to a method whose parameter is `CStructure &`. Examples:

- `CScanner::UpdateWarm` → `m_phase[s].Update(exec)`
- `CScanner::CollectCandidates` → `scoring.BuildContext(m_mtf[s], m_phase[s], ...)`
- `SEA.mq5 OnLTFBarClose` → `g_management.Manage(..., exec, regime, ...)`
- `SEA.mq5` scaling block → `g_scaling.MayAdd(..., exec, regime, ...)`

I believe MQL5 dereferences an object pointer automatically here. If it does
not, you will get errors like:

```
'exec' - object pointer expected / parameter conversion not allowed
```

**Fix:** change the *parameter* to a pointer in the callee, not the call
site. For example in `CPhase.mqh`:

```mql5
bool Update(const CStructure &structure, const bool force=false);
//  becomes
bool Update(CStructure *structure, const bool force=false);
```

and inside the body `structure.State()` already uses `.`, so nothing else
changes. Same edit for `CRegime::Update`, `CManagement::Manage`,
`CScaling::MayAdd`, `CScaling::TrailAllLegs`, `CScoring::BuildContext`,
`CProbabilityMap` (takes `CMTF &`), and `CGates::Evaluate` (takes
`CSpikeHazard &` — that one is passed as a real object, so it is fine).

Send me the exact messages and I will do the pass rather than you doing it
by hand.

## Other likely messages

| Message | Cause | Fix |
|---|---|---|
| `'ORDER_FILLING_BOC' - undeclared identifier` | Terminal build predates BOC | Tell me — three references in `CSymbolSpec.mqh` to strip. The mask flag is already build-independent |
| `'SYMBOL_EXIST' - undeclared identifier` | Very old build | Swap for a `SymbolSelect` probe |
| `'input group' - unexpected token` | Build below ~2000 | Replace `input group "..."` with a comment |
| `possible loss of data due to type conversion` | `long`→`int` narrowing I missed | Send the line number |
| `declaration of 'X' hides global declaration` | `SEA_*` const clashing with your Include tree | I will namespace further |
| `'m_lastGates' - array out of range` at runtime | `SEA_MAX_WARM*2` rejection buffer overflow | Raise the constant in `CScanner.mqh` |
| `cannot open source file 'SEA/...'` | Files not under `MQL5/Include/SEA/` | Fix the install paths above |

## Known gaps — things that are NOT finished

I am listing these rather than letting you find them in a live account.

1. **Rejection review data is empty.** `SEA.mq5` calls
   `g_journal.LogRejection(...)` with `0.0` for entry, stop and target,
   because `CScanner` does not expose a rejected setup's prices. The 20-bar
   follow-up therefore cannot decide whether a rejection would have won.
   The gate-mask statistics *are* real; the would-have-won column is not.
   Fix: have `CScanner` retain the full `SGateContext` alongside each
   `SGateResult`.

2. **The bar-close clock is the chart symbol.** `OnTick` detects HTF and LTF
   bar closes on `_Symbol` only. Symbols on different sessions will be
   updated on the chart symbol's cadence rather than their own. Correct for
   a single-symbol chart, approximate for a broad universe.

3. **AUTO style never resolves.** `CStyle::ResolveAuto` is implemented but
   nothing calls it, so `InpTradingStyle = AUTO` behaves as INTRADAY.
   Wiring it needs per-style profiling passes at init.

4. **No test scripts beyond module 1.** The working agreement says every
   module ships with its test script. Only `Test_CSymbolSpec.mq5` exists.
   The repaint tests that CLAUDE.md marks mandatory for `CStructure`,
   `CZones`, `CPhase` and `CProbabilityMap` are **not written** — each of
   those modules exposes a `Fingerprint()` method built for exactly that
   test, but the harness that runs it twice and compares is missing.

5. **`CStructure::ResolveState` is O(bars × swings).** With a 500-bar
   lookback and 128 swings that is ~64k comparisons per rebuild per level
   per symbol. It will likely blow the 500ms HTF budget on a wide universe.
   The instrumentation will tell you; the fix is to precompute a
   confirmation-ordered index.

6. **Correlation grouping is crude.** It keys on base/profit currency, so
   instruments that move together without sharing a currency are not
   collapsed.

## Before this goes anywhere near money

Per CLAUDE.md's own testing section, none of which has been done:

- repaint tests on the four modules that require them
- real-tick backtests, walk-forward, out-of-sample
- Monte Carlo confirming the drawdown halt holds
- a deliberate drawdown-halt test **including a forced terminal restart**,
  to prove the kill switch survives it
- 4–8 weeks demo forward test

Run it on a demo account first. The hard halt has never been fired in
anger, and `CRiskManager::ManualResetHardHalt` is the only way back once it
latches.
