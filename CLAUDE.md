# PROJECT: Structure-Driven Adaptive Expert Advisor (MT5)

An MQL5 EA that trades purely from price action and market structure,
adapting its behaviour to each instrument's measured statistics and
each market's current condition.

## WORKING AGREEMENT
- You cannot compile MQL5 or run MetaEditor. Never claim code
  compiles or works. I compile and paste errors back.
- After each module, list the MetaEditor error codes I should
  expect if something is wrong.
- One module per session. Do not write ahead of the build order.
- Every module ships with its test script before we move on.

## GOVERNING PRINCIPLE — SIGNAL AUTHORITY
CStructure is the sole source of trade signals. No other module may
generate an entry.

Every decision must answer: "what structural fact justifies this?"
If it cannot be traced to a swing point, a break, a range boundary
or a zone origin, it does not belong in this EA.

FORBIDDEN:
- Any symbol name, family name or broker name in strategy logic
- Any direction lock or instrument prohibition
- Any entry from an indicator crossover, timer or schedule
- Any exit at a fixed R multiple where a structural level exists
- Any hard-coded constant that could instead be measured

PERMITTED (arithmetic, not strategy):
- Size from equity, VOLUME_MIN, tick value, margin
- Margin-level and stop-out protection
- Drawdown halts
These bound the SIZE of a structural decision. They never override
its DIRECTION.

## NON-NEGOTIABLE CODE RULES
1. Signals on CLOSED bars only. shift >= 1. Index 0 forbidden in
   any signal module. Repainting = broken build.
2. No hard-coded pip values, contract sizes or symbol names. Read
   everything from SymbolInfoDouble/Integer at runtime.
3. SYMBOL_FILLING_MODE is a BITMASK. Test with & never ==.
   Wrong mode returns retcode 10030.
4. All execution SYNCHRONOUS. CTrade::SetAsyncMode(false).
   Async forbidden for entries and all risk-triggered closes.
5. Every position query filtered by magic number AND symbol.
6. Every trade has a hard SL. No naked positions ever.
7. NEVER martingale, grid, or increase size after a loss.
8. Indicator handles created in OnInit or on tier promotion,
   cached, released via IndicatorRelease. Never in OnTick.
9. Before any CopyRates/CopyBuffer, verify
   SeriesInfoInteger(SERIES_SYNCHRONIZED). Unsynced is NOT
   "no signal" — skip and retry.
10. No PERIOD_ constants outside CStyle.

## ARCHITECTURE
Modular. One class per .mqh in /Include/SEA/. The .mq5 is thin
orchestration only. Build in this order — do not skip:

 1. CSymbolSpec.mqh      spec cache, suffix strip, filling mode,
                         lot normalization, calc-mode detection
 2. CRiskManager.mqh     sizing, DD tracking, halts, persistence
 3. CTradeExec.mqh       sync CTrade wrapper, retcodes, retries
 4. CStyle.mqh           scalp/intraday/swing/auto config
 5. CStructure.mqh       fractals, BOS, CHoCH, range, premium/discount
 6. CZones.mqh           OB, FVG, Breaker, IFVG + state machine
 7. CLiquidity.mqh       EQH/EQL, PDH/PDL, PWH/PWL, sweeps
 8. CPhase.mqh           accumulation / manipulation / distribution
 9. CRegime.mqh          trending / ranging / expansion / compression
10. CSymbolProfiler.mqh  8-metric statistical characterisation
11. CSpikeHazard.mqh     spike interval, hazard bands, stress stops
12. CAffordability.mqh   computed tradeability per symbol
13. CMTF.mqh             timeframe cascade, alignment score
14. CProbabilityMap.mqh  graded reversal/breakout levels
15. CGates.mqh           10 hard gates, no compensation
16. CScoring.mqh         confluence scoring among survivors
17. CScaling.mqh         pyramiding into winners only
18. CManagement.mqh      break-even, partials, structural trail
19. CScanner.mqh         tiered universe scan + ranking
20. CAlert.mqh           push/terminal notifications
21. CJournal.mqh         trade + rejection logging
22. CDashboard.mqh       on-chart HUD
23. SEA.mq5              orchestration only

## TRADING STYLE (CStyle)
InpTradingStyle: SCALP / INTRADAY / SWING / AUTO (default INTRADAY)

                SCALP        INTRADAY     SWING
Cascade         H4>H1>M15>   W1>D1>H4>    MN>W1>D1>
                M5>M1        H1>M15       H4>H1
Bias TF         H1           H4           D1
Exec TF         M5           M15          H4
Trigger TF      M1           M5           H1
Stop ATR mult   1.5          2.5          4.0
Max scale-ins   1            2            3
Spread/stop cap 0.08         0.15         0.25
Pending expiry  3 bars       5 bars       8 bars
Accum min bars  12           20           30
Max daily assert 20          8            3

- Every module reads timeframes from CStyle.
- CSymbolProfiler stores metrics per (symbol, style) pair.
- AUTO scores each style per symbol on spread/ATR, tick frequency
  and structural cleanliness at that style's exec TF.
- Style change at runtime: rebuild cascade, requalify universe,
  block while positions open.
- Warn at init if the style disqualifies >70% of universe at
  current equity, naming the constraint.

## SYMBOL PROFILER — measured, never assumed
Over InpProfileLookback bars (default 2000), per symbol per style:
 1. Trend persistence  variance ratio; >1.15 trending, <0.85 reverting
 2. Volatility character  StdDev(ATR)/Mean(ATR)
 3. Tail risk  max bar range / median ATR; count of >5x ATR per 1000
 4. Structural cleanliness  confirmed swings / fractal candidates
 5. Range cycle  median bars in compression before break
 6. Drift  mean return per bar
 7. Execution drag  median spread / median structural stop
 8. Session sensitivity  variance of hourly ATR

Derived behaviour: TREND_FOLLOWER, MEAN_REVERTER, BREAKOUT,
SPIKE_DRIVEN, NOISY_AVOID — from metrics only, no name matching.

Derived parameters:
  FractalBars    3 clean -> 7 noisy
  ImpulseATR     2.0 uniform -> 4.0 clustered
  StopATRMult    1.5 low tail -> 4.0 high tail
  MinConfluence  70 clean -> 90 noisy
  MaxScaleIns    0 reverter -> 3 trender
  AccumMinBars   from measured compression length

Require InpProfileMinBars (default 1000). Below that, mark
INCOMPLETE and exclude from trading. Never trade a guessed profile.
Persist to MQL5/Files/symbol_profiles.csv with last_updated.

## SPIKE HANDLING — no direction lock
Spike character detected statistically: single-bar range >
InpSpikeDetectATR (5.0) x median ATR, >=30 occurrences, directional
consistency >0.9. Works on any instrument, named or not.

Hazard = ticksSinceLastSpike / measured mean interval:
  <0.4   LOW      counter-spike fully permitted
  0.4-0.7 MEDIUM  counter-spike allowed, no scale-ins, tighter TP
  0.7-0.9 HIGH    close profitable counter-spike, no new entries
  >0.9   EXTREME  flat all counter-spike, arm with-spike setups

WITH-spike: structural stop, standard sizing, close on spike, no trail
AGAINST-spike: structural stop for PLACEMENT, measured spike
magnitude for SIZING, fixed TP, never trailed into rising hazard

Persist tick counter via GlobalVariables. On restart with no stored
count, assume hazard = 1.0. Never assume safe.
CSpikeHazard permits, sizes and times. It NEVER selects direction.

## AFFORDABILITY — computed, no whitelists
Per symbol, on every equity change >5%:
  pointValue     = (TICK_VALUE_LOSS / TICK_SIZE) * VOLUME_MIN
  marginAtMin    = OrderCalcMargin(symbol, VOLUME_MIN)
  affordableStop = (Equity * CurrentRiskPct) / pointValue
  requiredStop   = ATR(14) * StopATRMult (from profile)

TRADEABLE if all:
  marginAtMin <= Equity * InpMaxMarginUtil (25%)
  affordableStop >= requiredStop * 1.2
  affordableStop >= SYMBOL_TRADE_STOPS_LEVEL
  spread <= requiredStop * styleSpreadCap

If requiredStop > affordableStop: mark untradeable.
NEVER tighten a stop to fit a budget.
AffordabilityScore = affordableStop / requiredStop, feeds ranking.

## MICRO MODE (equity < InpMicroModeCeiling, default $50)
Binding constraint becomes margin, not risk %.
  lots = VOLUME_MIN (no choice)
  reject if margin > InpMaxMarginUtil of equity
  maxStopPoints = (Equity * Risk%) / pointValue
  if structural stop > maxStopPoints -> SKIP, log
     "stop exceeds micro budget"
Force MaxScaleIns=0, MaxConcurrent=1.

## STRUCTURE (the signal authority)
Swings: N-bar fractal, N from profile. A swing is CONFIRMED only
after N candles close beyond it. Unconfirmed swings never influence
signals.
BOS   = closed-bar break beyond last confirmed swing, trend direction
CHoCH = closed-bar break beyond last counter-trend swing
Dealing range = last confirmed swing low to high in current leg
Equilibrium 0.5. Discount <0.5. Premium >0.5. OTE 0.618-0.79.
RANGING if no BOS/CHoCH within InpStructureStaleBars (50).
Recompute on new bar only. Cache swing arrays.

## PRICE ACTION TRIGGERS
Bullish (mirror for bearish):
 - Rejection wick: lower wick >=60% of range, close in upper third
 - Bullish engulfing: body engulfs prior bearish body
 - Inside-bar break: inside bar then close above its high
 - Momentum close: close >75% of range, body >=1.2x avg body
Trigger candle must CLOSE. shift=1.

## ZONES
Impulse = move >= ImpulseATR (from profile) in <= 5 bars
Demand = body of last bearish candle before bullish impulse
Supply = body of last bullish candle before bearish impulse
FVG = 3-bar gap, Low[i] > High[i+2] or inverse
Breaker = failed OB revisited from the opposite side
IFVG = FVG closed through, acts as opposing S/R on retest
State: FRESH -> TAPPED -> MITIGATED -> INVERTED -> EXPIRED
Only FRESH is tradeable. Expire after InpZoneMaxAge (500 bars).

## PHASE — accumulation / manipulation / distribution
ACCUMULATION: ATR(14) < ATR(50)*0.7, ADX<20, contained within
  InpAccumRangeATR (1.5) for >= AccumMinBars. Store range high,
  low, equilibrium, liquidity beyond each side.
MANIPULATION requires the FULL ordered sequence:
  valid range -> wick beyond edge -> close back inside within
  InpSweepMaxBars (3) -> CHoCH opposite within InpChochWindow (12)
  Partial sequences return false. Never infer a sweep from a wick.
DISTRIBUTION: confirmed BOS out of range post-sweep, ADX rising,
  ATR expanding.
Phase resets to ACCUMULATION on new contraction after distribution.

## REGIME
TRENDING     ADX>25, structure directional, clean HH/HL or LH/LL
RANGING      ADX<20, oscillating inside dealing range
EXPANSION    ATR(14) > ATR(50)*1.5, impulsive displacement
COMPRESSION  ATR(14) < ATR(50)*0.7, inside bars stacking

                Trending   Ranging   Expansion   Compression
Scale-ins       max        0         1           0
Add trigger     new BOS    -         pullback    -
Break-even at   1.0R       0.5R      1.5R        -
Trail           structural none      ATR x3.0    -
Stop            zone wick  range ext ATR x2.5    -
Target          trail out  opp bound measured    -
Entries         yes        yes       yes         NO

Re-classify per bar for symbols with OPEN positions. On change,
apply new profile to trailing and block further scale-ins.
NEVER widen an existing stop.

## MTF CASCADE + PROBABILITY MAP
Build top-down. Each level stores state, range, equilibrium,
nearest untested zone both directions, unswept liquidity.
Rebuild a level ONLY on that timeframe's bar close.
Alignment score signed -100..+100, higher TFs weighted more.

Reversal probability HIGH (80+):
  at HTF swing extreme + inside untested HTF zone + premium/discount
  against HTF bias + liquidity swept and rejected + LTF CHoCH
  + impulse legs decreasing (exhaustion)
Breakout probability HIGH (80+):
  compression against HTF trend + 3rd or later boundary test
  + unswept liquidity beyond + range contracting + prior sweep taken

Reversal and breakout are COMPETING hypotheses at the same level.
Compute both, return the higher with its margin.
Stacking bonus: (levelsAgreeing - 1) * InpMTFStackWeight (12)
Track test count per level; each touch increments, close beyond
invalidates.
HARD: an LTF CHoCH with no HTF zone at that price scores below
threshold. Location gates the signal.

## HARD GATES (CGates) — ALL must pass, no compensation
 1. HTF structure != RANGING
 2. ProbabilityScore >= InpMinLocationScore (75)
 3. Zone state == FRESH
 4. Price action trigger on CLOSED bar
 5. Structural invalidation point definable
 6. RR to nearest opposing liquidity >= InpMinRR (2.0)
 7. affordableStop >= requiredStop * 1.2
 8. If ACCUMULATION: manipulation sweep confirmed
 9. spread <= requiredStop * styleSpreadCap
10. Spike hazard permits this direction

Fail any one -> no trade. Score is never consulted.
Evaluate cheap gates first (spread, affordability) to fail fast.
Return the FULL GateResult, not just first failure.

## SCORING — only among gate survivors
Decides WHICH qualified setup to take, never WHETHER to trade.
  HTF bias aligned                20
  Sweep preceded CHoCH            20
  Entry in OTE 0.618-0.79         15
  Zone FRESH and untested         15
  OB + FVG overlap                10
  Target = unswept liquidity      10
  RR >= 1:3                       10
  MTF stacking bonus              +12 per extra TF
  Follows confirmed manipulation  +25
  Distribution phase, with move   +20
  Entry in unresolved accumulation -40
  Range break with no prior sweep  -30
InpMinConfluenceScore default 80.

## SCALING — winners only
Gates: position >= InpScaleTriggerR (1.0R) AND initial SL at
break-even AND HTF structure unchanged AND aggregate risk <=
InpMaxBasketRisk (1.0R) AND legCount < style max.
Trigger: new BOS in trend direction, or pullback into FRESH
continuation zone + price action trigger.
Decay: leg[n] = leg[n-1] * InpScaleDecay (0.5). Never increase.
If a decayed leg < VOLUME_MIN, stop scaling. Do not round up.
After each add, trail ALL legs to the most recent confirmed swing.
HARD: never add to a position in drawdown. Never add before
break-even. CRiskManager::ApproveExposure must return true.
Persist basket state via GlobalVariables.

## RISK ENGINE
Sizing: lots = (Equity * Risk%) / (StopPoints * pointValue)
Round DOWN to VOLUME_STEP, clamp to min/max. Reject if < min.
Drawdown measured on EQUITY, never balance.
Two limits:
 - Max DD: static from initial balance, default 5% (3-10).
   Hard halt = close all, cancel pendings, persistent flag,
   MANUAL reset required.
 - Daily DD: from day-start equity, default 3% (2-5).
   Auto-resume at broker midnight.
Soft halt at 80% of either limit: block new entries, let open
trades run. Hard close at limit minus 0.5% slippage buffer.
Consecutive-loss breaker: pause InpBreakerHours after
InpMaxConsecutiveLosses (4).
Margin floor: refuse entry below InpMarginFloor (400%).
Correlation cap: one candidate per currency group,
InpMaxCurrencyExposure (2). Synthetics exempt.
Equity ladder: <$500 0.5% | $500-2k 0.75% | $2k-10k 1.0% | >$10k 1.0%
Dynamic risk from rolling 20-trade profit factor, within ladder
bounds. PF>1.4 -> top of band. PF<1.0 -> floor until recovered.
Risk responds to demonstrated edge, NEVER to a losing streak.
Persist HWM, day-start equity, halt flags, loss count via
GlobalVariableSet + GlobalVariablesFlush. Restore in OnInit BEFORE
first OnTick. A restart must NOT reset the kill switch.

## SCANNER — tiered
TIER 3 COLD  full universe, refresh on HTF bar close, bias only
TIER 2 WARM  ~15-30 symbols, LTF bar close, zones + freshness
TIER 1 HOT   max InpMaxHotSymbols (5), every tick, triggers only
Promotion on directional bias / price approaching FRESH zone.
Tier 1 full: only a higher-scoring candidate displaces an incumbent.
Handles created lazily on Tier 2 promotion, released on demotion.
Warn above 400 handles.
Ranking: collect all valid setups on LTF close, score, sort desc,
apply correlation collapse, return top N for open slots. Discard
the rest — do not queue.
Scanner returns candidates ONLY. Never executes.

## EXECUTION + LATENCY BUDGET
HTF bar close  <500ms  cascade, probability map, requalification
LTF bar close  <50ms   zones, candidate ranking, pending placement
Per tick hot   <1ms    trigger check, order fire

Entries are PENDING orders placed on LTF bar close at precomputed
levels — not market orders on arrival. Expire after style setting.
The tick path may ONLY read precomputed values and compare.
Any recomputation of structure, zones, scores or affordability in
OnTick is a bug.
Instrument every phase with GetMicrosecondCount. Log any overrun
naming the module.
Slippage: deviation cap InpMaxDeviation (20 points), max 3 retries
on requote, log requested vs filled every trade.
Explicit handling for retcodes 10030, 10016, 10019, 10006,
10004/10021.

## ALERTS
On entry, send symbol, direction, entry, lots, SL, TP, risk in $
and %, probability score + top 3 contributing factors, phase,
regime, MTF alignment, invalidation level, DD vs limit, leg number.
Also alert: soft halt, hard halt, hazard EXTREME, consecutive-loss
breaker, daily target. Not on every scale-in.
SendNotification for push, Alert for terminal, Print always.
Throttle InpAlertMinInterval (30s); halts bypass throttle.
Never call SendNotification in the tick hot path — queue and flush
on timer.

## JOURNAL
Every trade: structural event that triggered it, zone origin, full
confluence breakdown, phase, regime, MTF alignment, invalidation
level, requested vs filled price, MAE/MFE, outcome in R.
Every REJECTED setup: symbol, time, direction, full gate results,
score vs threshold, and price movement 20 bars later with whether
it would have hit TP or SL.
Weekly summary: rejections by failing gate, rejected-but-would-have-
won, accepted-but-lost.
If the journal cannot explain a trade structurally, that is a bug.
Assertion: if trades/day > style max, a gate is leaking — alert
immediately.

## TESTING
Every module ships with a test script before we proceed.
Repaint test mandatory on CStructure, CZones, CPhase,
CProbabilityMap: run twice on identical history, output must be
byte-identical.
Before live: real-tick backtests, walk-forward, out-of-sample,
Monte Carlo confirming the DD halt holds, and 4-8 weeks demo
forward test.
Deliberate DD-halt test including forced terminal restart.

## CODING STANDARDS
MQL5 strict. Classes C-prefixed, members m_, inputs Inp.
Every public method documented. Zero errors, zero warnings.
No magic numbers — all thresholds are inputs with documented ranges.
