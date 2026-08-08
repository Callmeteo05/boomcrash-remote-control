//+------------------------------------------------------------------+
//|                                                          SEA.mq5  |
//|                                                                   |
//|   Structure-Driven Adaptive Expert Advisor.                       |
//|                                                                   |
//|   Module 23. ORCHESTRATION ONLY.                                  |
//|                                                                   |
//|   This file contains no strategy logic. It wires the modules      |
//|   together, routes events to them in the right order, and         |
//|   enforces the latency budget:                                    |
//|                                                                   |
//|     HTF bar close  <500ms  cascade, probability map, requalify    |
//|     LTF bar close  <50ms   zones, ranking, pending placement      |
//|     per tick hot   <1ms    trigger check, order fire              |
//|                                                                   |
//|   The tick path READS PRECOMPUTED VALUES AND COMPARES. Any        |
//|   recomputation of structure, zones, scores or affordability in   |
//|   OnTick is a bug, and the instrumentation below is there to      |
//|   catch it if one creeps in.                                      |
//+------------------------------------------------------------------+
#property copyright "Structure-Driven Adaptive EA"
#property version   "1.00"
#property description "Trades purely from price action and market structure."
#property description "Adapts to each instrument's measured statistics."
#property description "NOT YET COMPILED OR TESTED - see CLAUDE.md working agreement."
#property description "Refuses to start on a REAL account unless deliberately enabled."

#include <SEA/SEA_Common.mqh>
#include <SEA/CSymbolSpec.mqh>
#include <SEA/CRiskManager.mqh>
#include <SEA/CTradeExec.mqh>
#include <SEA/CStyle.mqh>
#include <SEA/CStructure.mqh>
#include <SEA/CZones.mqh>
#include <SEA/CLiquidity.mqh>
#include <SEA/CPhase.mqh>
#include <SEA/CRegime.mqh>
#include <SEA/CSymbolProfiler.mqh>
#include <SEA/CSpikeHazard.mqh>
#include <SEA/CAffordability.mqh>
#include <SEA/CMTF.mqh>
#include <SEA/CProbabilityMap.mqh>
#include <SEA/CGates.mqh>
#include <SEA/CScoring.mqh>
#include <SEA/CScaling.mqh>
#include <SEA/CManagement.mqh>
#include <SEA/CScanner.mqh>
#include <SEA/CAlert.mqh>
#include <SEA/CJournal.mqh>
#include <SEA/CDashboard.mqh>

//+------------------------------------------------------------------+
//| INPUTS                                                            |
//|                                                                   |
//| Every threshold in the EA is an input with a documented range.    |
//| There are no magic numbers buried in strategy logic.              |
//+------------------------------------------------------------------+

input group "=== SAFETY ==="
input bool   InpAllowLiveTrading    = false; // Allow REAL money. Leave false until tested
input bool   InpAcknowledgeUntested = false; // I have read the warning below

input group "=== IDENTITY ==="
input long   InpMagicNumber         = 20260808;  // Magic number
input string InpTradeComment        = "SEA";     // Order comment

input group "=== STYLE ==="
input ENUM_SEA_STYLE InpTradingStyle = SEA_STYLE_INTRADAY; // Trading style

input group "=== RISK ==="
input double InpMaxDDPercent        = 5.0;   // Max drawdown %, static from initial balance (3-10)
input double InpDailyDDPercent      = 3.0;   // Daily drawdown %, from day-start equity (2-5)
input int    InpMaxConsecutiveLosses= 4;     // Consecutive losses before the breaker (2-10)
input int    InpBreakerHours        = 4;     // Breaker pause, hours (1-48)
input double InpMarginFloor         = 400.0; // Refuse entry below this margin level % (200-1000)
input int    InpMaxCurrencyExposure = 2;     // Max candidates per currency group (1-10)
input double InpMicroModeCeiling    = 50.0;  // Equity below which micro mode binds (0-1000)
input double InpMaxMarginUtil       = 0.25;  // Max margin utilisation, fraction (0.05-0.90)
input double InpStopSafetyFactor    = 1.2;   // affordableStop >= requiredStop * this (1.0-3.0)

input group "=== PROFILER ==="
input int    InpProfileLookback     = 2000;  // Bars measured per profile (200-10000)
input int    InpProfileMinBars      = 1000;  // Below this a profile is INCOMPLETE (100-10000)
input double InpSpikeDetectATR      = 5.0;   // Single-bar range multiple counting as a spike (2-20)
input int    InpSpikeMinCount       = 30;    // Spike occurrences before believing it (5-500)
input double InpSpikeConsistency    = 0.90;  // Directional consistency required (0.5-1.0)

input group "=== STRUCTURE ==="
input int    InpStructureStaleBars  = 50;    // No break within this many bars = RANGING (5-500)
input int    InpStructureLookback   = 500;   // Bars scanned per structure rebuild (50-5000)
input int    InpZoneMaxAge          = 500;   // Zone expiry, bars (20-5000)
input double InpEqualTolerance      = 0.10;  // EQH/EQL tolerance as an ATR fraction (0.02-0.50)

input group "=== PHASE ==="
input double InpAccumATRRatio       = 0.70;  // ATR14 < ATR50 * this for accumulation (0.40-0.95)
input double InpAccumADXMax         = 20.0;  // ADX below this for accumulation (10-30)
input double InpAccumRangeATR       = 1.50;  // Containment width in ATR (0.5-5.0)
input int    InpSweepMaxBars        = 3;     // Close back inside within this many bars (1-10)
input int    InpChochWindow         = 12;    // CHoCH must follow within this many bars (3-50)

input group "=== REGIME ==="
input double InpADXTrending         = 25.0;  // ADX above this is trending (20-40)
input double InpADXRanging          = 20.0;  // ADX below this is ranging (10-25)
input double InpExpansionRatio      = 1.50;  // ATR14 > ATR50 * this is expansion (1.1-3.0)
input double InpCompressionRatio    = 0.70;  // ATR14 < ATR50 * this is compression (0.3-0.9)
input int    InpATRPeriod           = 14;    // Fast ATR period (2-200)
input int    InpATRSlowPeriod       = 50;    // Slow ATR period (3-500)
input int    InpADXPeriod           = 14;    // ADX period (2-200)

input group "=== GATES AND SCORING ==="
input double InpMinLocationScore    = 75.0;  // Minimum probability score, GATE 8 (50-95)
input double InpMinRR               = 2.0;   // Minimum reward to risk, GATE 9 (1.0-5.0)
input double InpMinConfluenceScore  = 80.0;  // Minimum confluence score (50-150)
input double InpMTFStackWeight      = 12.0;  // Bonus per extra agreeing timeframe (4-25)
input double InpNoLocationCeiling   = 40.0;  // Score cap with no HTF zone at price (0-74)

input group "=== SCALING ==="
input double InpScaleTriggerR       = 1.0;   // R at which a scale-in becomes possible (0.5-5.0)
input double InpScaleDecay          = 0.5;   // Each leg times this. Must be below 1.0 (0.1-0.9)
input double InpMaxBasketRisk       = 1.0;   // Max aggregate basket risk in R (0.5-3.0)

input group "=== MANAGEMENT ==="
input bool   InpUsePartials         = true;  // Take a partial at InpPartialAtR
input double InpPartialAtR          = 1.0;   // R at which the partial is taken (0.5-5.0)
input double InpPartialFraction     = 0.5;   // Fraction closed at the partial (0.1-0.9)

input group "=== SCANNER ==="
input int    InpMaxHotSymbols       = 5;     // Tier 1 hot symbols (1-10)
input int    InpMaxWarmSymbols      = 24;    // Tier 2 warm symbols (4-32)
input int    InpMaxConcurrent       = 3;     // Max concurrent positions (1-20)
input bool   InpMarketWatchOnly     = true;  // Scan Market Watch only, not every symbol

input group "=== EXECUTION ==="
input int    InpMaxDeviation        = 20;    // Slippage cap in points (0-200)
input int    InpMaxRetries          = 3;     // Retries on a requote (0-10)

input group "=== ALERTS AND LOGGING ==="
input bool   InpPushNotifications   = false; // Send push notifications
input bool   InpTerminalAlerts      = true;  // Raise terminal alerts
input int    InpAlertMinInterval    = 30;    // Throttle, seconds. Halts bypass it (0-600)
input int    InpJournalReviewBars   = 20;    // Bars before a rejection is reviewed (5-200)
input bool   InpShowDashboard       = true;  // Draw the on-chart HUD
input bool   InpVerbose             = false; // Verbose module diagnostics

//+------------------------------------------------------------------+
//| MODULES                                                           |
//+------------------------------------------------------------------+
CIndicatorPool   g_pool;
CSymbolSpec      g_spec;
CRiskManager     g_risk;
CTradeExec       g_exec;
CStyle           g_style;
CSymbolProfiler  g_profiler;
CSpikeHazard     g_hazard;
CAffordability   g_afford;
CProbabilityMap  g_probability;
CGates           g_gates;
CScoring         g_scoring;
CScaling         g_scaling;
CManagement      g_management;
CScanner         g_scanner;
CAlert           g_alert;
CJournal         g_journal;
CDashboard       g_dashboard;

//--- bar-close tracking
datetime g_lastHTFBar = 0;
datetime g_lastLTFBar = 0;

//--- precomputed for the tick path. NOTHING here is recalculated on tick.
SSetup   g_armed[];
int      g_armedCount = 0;

//--- latency instrumentation
ulong    g_worstHTF = 0;
ulong    g_worstLTF = 0;
ulong    g_worstTick= 0;

//--- housekeeping
datetime g_lastSummary = 0;
bool     g_haltAlerted = false;

//+------------------------------------------------------------------+
//| Report a latency overrun, naming the phase.                       |
//+------------------------------------------------------------------+
void CheckBudget(const string phase,const ulong micros,const ulong budgetMicros,ulong &worst)
  {
   if(micros>worst)
      worst=micros;

   if(micros>budgetMicros)
      PrintFormat("[SEA] LATENCY OVERRUN in %s: %I64u us against a %I64u us budget",
                  phase,micros,budgetMicros);
  }

//+------------------------------------------------------------------+
//| Name the structural fact behind a setup, for the journal.         |
//|                                                                   |
//| If this cannot produce a sentence, the trade should not be taken. |
//+------------------------------------------------------------------+
string StructuralExplanation(const SSetup &s)
  {
   string breakText=(s.breakType==SEA_BREAK_BOS ? "BOS"
                     : (s.breakType==SEA_BREAK_CHOCH ? "CHoCH" : "no break"));

   if(s.zoneType==SEA_ZONE_NONE)
      return("");

   return(StringFormat("%s %s into %s formed %s, %s trigger, %s phase, MTF %+d",
                       breakText,
                       SeaDirectionToString(s.direction),
                       SeaZoneTypeToString(s.zoneType),
                       TimeToString(s.zoneOriginTime,TIME_DATE|TIME_MINUTES),
                       SeaTriggerToString(s.trigger),
                       SeaPhaseToString(s.phase),
                       s.mtfAlignment));
  }

//+------------------------------------------------------------------+
//| Report the account profile, and shout when it has CHANGED.        |
//|                                                                   |
//| The trading logic is identical on demo and live - account type is  |
//| read once, in the guard above, and never again. But this EA is     |
//| deliberately EQUITY-ADAPTIVE, so the same code behaves very        |
//| differently at $300 and at $10,000:                                |
//|                                                                   |
//|   the ladder sets a different risk percentage                     |
//|   micro mode may force VOLUME_MIN, no scale-ins, one position     |
//|   affordableStop scales with equity, which decides WHICH SYMBOLS  |
//|     are tradeable at all                                          |
//|                                                                   |
//| So a demo run at one equity tells you very little about a live     |
//| account at another. That is not a bug and it is not the market     |
//| turning against you - it is the affordability arithmetic doing     |
//| its job on a different number.                                    |
//|                                                                   |
//| This prints the band every startup, and warns loudly when the      |
//| login or the band has moved since last time.                      |
//+------------------------------------------------------------------+
void ReportAccountProfile(void)
  {
   const long   login  = AccountInfoInteger(ACCOUNT_LOGIN);
   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   const int    band   = g_risk.EquityBand();
   const bool   micro  = g_risk.IsMicroMode();

   Print("--------------------------------------------------------");
   Print("  ACCOUNT PROFILE - what the equity-adaptive rules will do");
   Print("--------------------------------------------------------");
   PrintFormat("  equity        %.2f %s",equity,AccountInfoString(ACCOUNT_CURRENCY));
   PrintFormat("  ladder band   %s",g_risk.EquityBandName());
   PrintFormat("  risk in force %.3f%% per trade",g_risk.CurrentRiskPercent());
   PrintFormat("  micro mode    %s (ceiling %.2f)",
               (micro ? "ACTIVE" : "off"),g_risk.MicroModeCeiling());

   if(micro)
     {
      Print("");
      Print("  MICRO MODE IS ACTIVE. Margin, not risk percentage, is the");
      Print("  binding constraint:");
      Print("    every trade is VOLUME_MIN - size is not a choice");
      Print("    scale-ins forced to 0");
      Print("    one position at a time");
      Print("    any structural stop wider than the risk budget is SKIPPED");
      Print("  Expect far fewer trades than a larger account would take.");
     }

   //--- has the account or the band moved since the last run?
   const string loginKey = StringFormat("SEA_%d_LASTLOGIN",(int)InpMagicNumber);
   const string bandKey  = StringFormat("SEA_%d_LASTBAND",(int)InpMagicNumber);
   const string eqKey    = StringFormat("SEA_%d_LASTEQUITY",(int)InpMagicNumber);

   bool haveHistory = GlobalVariableCheck(loginKey);
   long  lastLogin  = (haveHistory ? (long)GlobalVariableGet(loginKey) : 0);
   int   lastBand   = (GlobalVariableCheck(bandKey) ? (int)GlobalVariableGet(bandKey) : -1);
   double lastEquity= (GlobalVariableCheck(eqKey)   ? GlobalVariableGet(eqKey)        : 0.0);

   if(haveHistory && lastLogin!=login)
     {
      Print("");
      Print("  ####################################################");
      Print("  #  DIFFERENT ACCOUNT THAN LAST RUN                 #");
      Print("  ####################################################");
      PrintFormat("  last run on login %I64d, now on %I64d",lastLogin,login);
      PrintFormat("  equity then %.2f, now %.2f",lastEquity,equity);
      Print("");
      Print("  The trading LOGIC is identical - but the equity-adaptive");
      Print("  rules above are not, so results from the other account do");
      Print("  NOT carry over. Risk percentage, micro mode and the");
      Print("  tradeable universe are all recomputed from THIS equity.");
      Print("");
      Print("  Persisted state (drawdown high-water mark, halt flags,");
      Print("  loss streak) is keyed on the MAGIC NUMBER, not the login,");
      Print("  so it has followed you across. If that is not what you");
      Print("  wanted, use a different InpMagicNumber for this account.");
     }
   else
      if(haveHistory && lastBand!=band)
        {
         Print("");
         Print("  ** EQUITY BAND CHANGED SINCE THE LAST RUN **");
         PrintFormat("  equity moved %.2f -> %.2f, band is now %s",
                     lastEquity,equity,g_risk.EquityBandName());
         Print("  Risk percentage and the tradeable universe have shifted");
         Print("  with it. This is the ladder working, not a fault.");
        }

   if(haveHistory && lastEquity>0.0)
     {
      double ratio=equity/lastEquity;
      if(ratio>3.0 || ratio<0.34)
         PrintFormat("  NOTE: equity is %.1fx the last run. Comparing results "
                     "across that gap is not meaningful.",ratio);
     }

   GlobalVariableSet(loginKey,(double)login);
   GlobalVariableSet(bandKey,(double)band);
   GlobalVariableSet(eqKey,equity);
   GlobalVariablesFlush();

   Print("--------------------------------------------------------");
  }

//+------------------------------------------------------------------+
//| Resolve AUTO style.                                               |
//|                                                                   |
//| Measures each candidate style at its OWN execution timeframe over  |
//| a sample of the universe, averages, and lets CStyle pick. Scoring  |
//| weighs execution drag heaviest, then tick liquidity, then          |
//| structural cleanliness.                                            |
//|                                                                   |
//| Sampling rather than measuring every symbol keeps init bounded;    |
//| the style is a universe-wide setting, so a sample is the right     |
//| granularity.                                                       |
//+------------------------------------------------------------------+
void ResolveAutoStyle(const int sampleSize)
  {
   if(InpTradingStyle!=SEA_STYLE_AUTO)
      return;

   Print("[SEA] AUTO style: measuring candidate styles across the universe");

   //--- indexed by ENUM_SEA_STYLE ordinal: 0 SCALP, 1 INTRADAY, 2 SWING
   double dragSum[3],tickSum[3],cleanSum[3];
   int    samples[3];

   for(int s=0; s<3; s++)
     {
      dragSum[s]=0.0;
      tickSum[s]=0.0;
      cleanSum[s]=0.0;
      samples[s]=0;
     }

   //--- a probe CStyle, so we read each candidate's own exec timeframe
   //--- rather than naming a PERIOD_ constant here (RULE 10)
   CStyle probe;

   int taken=0;
   for(int i=0; i<g_scanner.UniverseSize() && taken<sampleSize; i++)
     {
      SScanEntry e;
      if(!g_scanner.GetEntry(i,e))
         continue;
      if(e.specIndex<0 || e.exclusion!="")
         continue;

      bool contributed=false;

      for(int s=0; s<3; s++)
        {
         probe.SetStyle((ENUM_SEA_STYLE)s);

         double drag,ticks,clean;
         if(!g_profiler.MeasureStyleFitness(e.symbol,probe.ExecTF(),g_pool,
                                            1000,drag,ticks,clean))
            continue;

         dragSum[s] +=drag;
         tickSum[s] +=ticks;
         cleanSum[s]+=clean;
         samples[s]++;
         contributed=true;
        }

      if(contributed)
         taken++;
     }

   double drag[3],ticks[3],clean[3];
   for(int s=0; s<3; s++)
     {
      drag[s] =(samples[s]>0 ? dragSum[s]/(double)samples[s]  : 1.0);
      ticks[s]=(samples[s]>0 ? tickSum[s]/(double)samples[s]  : 0.0);
      clean[s]=(samples[s]>0 ? cleanSum[s]/(double)samples[s] : 0.0);
     }

   if(taken<1)
     {
      Print("[SEA] AUTO style: nothing measurable, holding INTRADAY");
      return;
     }

   g_style.SetVerbose(true);
   ENUM_SEA_STYLE chosen=g_style.ResolveAuto(drag,ticks,clean);
   g_style.SetVerbose(InpVerbose);

   PrintFormat("[SEA] AUTO style resolved to %s from %d sampled symbols",
               g_style.Name(),taken);
   PrintFormat("[SEA]   SCALP    drag %.4f ticks %.0f clean %.2f",drag[0],ticks[0],clean[0]);
   PrintFormat("[SEA]   INTRADAY drag %.4f ticks %.0f clean %.2f",drag[1],ticks[1],clean[1]);
   PrintFormat("[SEA]   SWING    drag %.4f ticks %.0f clean %.2f",drag[2],ticks[2],clean[2]);

   //--- silence the unused-return warning while keeping the value visible
   if(chosen==SEA_STYLE_AUTO)
      Print("[SEA] AUTO failed to resolve - this should not happen");
  }

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   Print("========================================================");
   Print("  Structure-Driven Adaptive EA starting");
   Print("========================================================");

   //--- LIVE ACCOUNT GUARD.
   //---
   //--- This EA has not been through the testing its own CLAUDE.md
   //--- demands: no real-tick backtest, no walk-forward, no Monte Carlo
   //--- on the drawdown halt, no demo forward test. CTradeExec's retcode
   //--- paths - requotes, 10030 filling rejections, partial fills - are
   //--- the code that actually moves money, and none of them has been
   //--- exercised against a live server.
   //---
   //--- So a real account is refused unless the operator deliberately
   //--- turns both switches on. The default is to refuse.
   ENUM_ACCOUNT_TRADE_MODE accountMode=
      (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE);

   string modeName="UNKNOWN";
   switch(accountMode)
     {
      case ACCOUNT_TRADE_MODE_DEMO:    modeName="DEMO";    break;
      case ACCOUNT_TRADE_MODE_CONTEST: modeName="CONTEST"; break;
      case ACCOUNT_TRADE_MODE_REAL:    modeName="REAL";    break;
     }

   PrintFormat("[SEA] account %I64d (%s) at %s - mode %s",
               AccountInfoInteger(ACCOUNT_LOGIN),
               AccountInfoString(ACCOUNT_NAME),
               AccountInfoString(ACCOUNT_SERVER),
               modeName);

   if(accountMode==ACCOUNT_TRADE_MODE_REAL)
     {
      if(!InpAllowLiveTrading || !InpAcknowledgeUntested)
        {
         Print("========================================================");
         Print("  REFUSED TO START ON A REAL ACCOUNT");
         Print("========================================================");
         Print("  This EA has never completed the testing its own");
         Print("  specification requires:");
         Print("    - no real-tick backtest");
         Print("    - no walk-forward or out-of-sample run");
         Print("    - no Monte Carlo on the drawdown halt");
         Print("    - no demo forward test");
         Print("    - CTradeExec retcode handling never exercised live");
         Print("");
         Print("  The drawdown hard halt has never actually fired. If it");
         Print("  does not work, nothing stops the losses.");
         Print("");
         Print("  Run it on DEMO first. When you have genuinely finished");
         Print("  testing, set BOTH inputs to true:");
         Print("    InpAllowLiveTrading    = true");
         Print("    InpAcknowledgeUntested = true");
         Print("========================================================");
         return(INIT_FAILED);
        }

      //--- both switches are on. Say so loudly rather than starting quietly.
      Print("========================================================");
      Print("  RUNNING ON A REAL ACCOUNT BY EXPLICIT OPERATOR CONSENT");
      PrintFormat("  balance %.2f  equity %.2f  %s",
                  AccountInfoDouble(ACCOUNT_BALANCE),
                  AccountInfoDouble(ACCOUNT_EQUITY),
                  AccountInfoString(ACCOUNT_CURRENCY));
      PrintFormat("  max drawdown halt at %.2f%%, daily at %.2f%%",
                  InpMaxDDPercent,InpDailyDDPercent);
      Print("  A hard halt requires a MANUAL reset - it will not clear");
      Print("  itself, and it survives a terminal restart.");
      Print("========================================================");
     }

   g_pool.SetVerbose(InpVerbose);
   g_pool.SetWarnThreshold(400);

   //--- module 1: spec cache
   g_spec.SetVerbose(InpVerbose);
   if(!g_spec.DetectAffixes())
      Print("[SEA] affix detection found nothing; proceeding with raw symbol names");
   PrintFormat("[SEA] broker prefix='%s' suffix='%s'",g_spec.Prefix(),g_spec.Suffix());

   //--- module 2: risk. RESTORED BEFORE THE FIRST TICK.
   //--- a persisted hard halt must survive this restart.
   g_risk.SetVerbose(InpVerbose);
   if(!g_risk.Init(InpMagicNumber,InpMaxDDPercent,InpDailyDDPercent,
                   InpMaxConsecutiveLosses,InpBreakerHours,InpMarginFloor,
                   InpMaxCurrencyExposure,InpMicroModeCeiling,InpMaxMarginUtil))
     {
      Print("[SEA] risk manager failed to initialise");
      return(INIT_FAILED);
     }
   Print("[SEA] risk: ",g_risk.Describe());

   //--- equity band, micro mode, and a loud warning if the account or
   //--- the band has moved since the last run
   ReportAccountProfile();

   //--- module 3: execution
   g_exec.SetVerbose(InpVerbose);
   g_exec.Init(g_spec,InpMagicNumber,InpMaxDeviation,InpMaxRetries);

   //--- module 4: style
   g_style.SetVerbose(InpVerbose);
   g_style.SetStyle(InpTradingStyle);
   Print("[SEA] ",g_style.Describe());

   //--- modules 10-12
   g_profiler.SetVerbose(InpVerbose);
   g_profiler.Configure(InpProfileLookback,InpProfileMinBars,InpSpikeDetectATR,
                        InpSpikeMinCount,InpSpikeConsistency,InpATRPeriod);
   int loaded=g_profiler.Load();
   if(loaded>0)
      PrintFormat("[SEA] loaded %d persisted profiles",loaded);

   g_hazard.SetVerbose(InpVerbose);
   g_hazard.Init(InpMagicNumber,InpSpikeDetectATR,InpATRPeriod);

   g_afford.SetVerbose(InpVerbose);
   g_afford.Configure(InpMaxMarginUtil,InpStopSafetyFactor,5.0);

   //--- modules 14-18
   g_probability.SetVerbose(InpVerbose);
   g_probability.Configure(InpMTFStackWeight,InpNoLocationCeiling);

   g_gates.SetVerbose(InpVerbose);
   g_gates.Configure(InpMinLocationScore,InpMinRR,InpStopSafetyFactor);

   g_scoring.SetVerbose(InpVerbose);
   g_scoring.Configure(InpMinConfluenceScore,InpMTFStackWeight);

   g_scaling.SetVerbose(InpVerbose);
   g_scaling.Configure(InpMagicNumber,InpScaleTriggerR,InpScaleDecay,InpMaxBasketRisk);

   g_management.SetVerbose(InpVerbose);
   g_management.Configure(InpPartialAtR,InpPartialFraction,InpUsePartials);

   //--- modules 19-22
   g_scanner.SetVerbose(InpVerbose);
   g_scanner.Configure(InpMaxHotSymbols,InpMaxWarmSymbols);

   g_alert.SetVerbose(InpVerbose);
   g_alert.Configure(InpAlertMinInterval,InpPushNotifications,InpTerminalAlerts);

   g_journal.SetVerbose(InpVerbose);
   g_journal.Configure(InpJournalReviewBars);

   g_dashboard.Configure(10,20,9,InpShowDashboard);

   //--- build the universe
   int universe=g_scanner.BuildUniverse(g_spec,InpMarketWatchOnly);
   PrintFormat("[SEA] universe: %d symbols",universe);

   //--- AUTO resolves against measured statistics before anything is
   //--- profiled, because the profile is keyed by (symbol, style)
   ResolveAutoStyle(12);
   if(InpTradingStyle==SEA_STYLE_AUTO)
      Print("[SEA] ",g_style.Describe());

   //--- first cold pass
   int tradeable=g_scanner.RefreshCold(g_spec,g_style,g_pool,g_profiler,
                                       g_afford,g_risk,g_hazard);

   //--- WARN when the style disqualifies most of the universe, naming
   //--- the constraint responsible
   double fraction=g_afford.TradeableFraction();
   if(fraction<0.30 && g_afford.Count()>0)
      PrintFormat("[SEA] WARNING: style %s leaves only %.0f%% of the universe tradeable "
                  "at this equity. Dominant constraint: %s",
                  g_style.Name(),fraction*100.0,g_afford.DominantConstraint());

   PrintFormat("[SEA] %d of %d symbols tradeable",tradeable,universe);

   g_scanner.PromoteWarm(g_spec,g_style,g_pool,g_profiler,InpATRPeriod,
                         InpStructureStaleBars,InpZoneMaxAge,InpEqualTolerance,
                         InpSweepMaxBars,InpStructureLookback,
                         InpAccumATRRatio,InpAccumADXMax,InpAccumRangeATR,InpChochWindow,
                         InpADXTrending,InpADXRanging,InpExpansionRatio,InpCompressionRatio,
                         InpATRSlowPeriod,InpADXPeriod);

   g_profiler.Save();

   ArrayResize(g_armed,InpMaxConcurrent>0 ? InpMaxConcurrent : 1);

   EventSetTimer(5);

   Print("[SEA] ",g_scanner.Describe());
   Print("[SEA] initialisation complete");

   //--- a restored hard halt is announced immediately
   if(g_risk.MustFlatten())
      g_alert.HaltAlert(SEA_HALT_HARD,g_risk.HaltReason());

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();

   //--- persist everything that must survive a restart
   g_risk.Persist();
   g_hazard.Persist();
   g_scaling.Persist();
   g_profiler.Save();

   g_alert.Flush();
   g_dashboard.Destroy();

   //--- RULE 8: every handle released
   g_pool.ReleaseAll();

   PrintFormat("[SEA] stopped (reason %d). Worst latencies: HTF %I64u us, LTF %I64u us, tick %I64u us",
               reason,g_worstHTF,g_worstLTF,g_worstTick);
  }

//+------------------------------------------------------------------+
//| HTF bar close: cascade, requalification, profiling. Budget 500ms. |
//+------------------------------------------------------------------+
void OnHTFBarClose()
  {
   ulong t0=GetMicrosecondCount();

   //--- re-evaluate affordability when equity has moved materially
   if(g_afford.NeedsReevaluation())
     {
      g_scanner.RefreshCold(g_spec,g_style,g_pool,g_profiler,g_afford,g_risk,g_hazard);

      g_scanner.PromoteWarm(g_spec,g_style,g_pool,g_profiler,InpATRPeriod,
                            InpStructureStaleBars,InpZoneMaxAge,InpEqualTolerance,
                            InpSweepMaxBars,InpStructureLookback,
                            InpAccumATRRatio,InpAccumADXMax,InpAccumRangeATR,InpChochWindow,
                            InpADXTrending,InpADXRanging,InpExpansionRatio,InpCompressionRatio,
                            InpATRSlowPeriod,InpADXPeriod);
     }

   //--- refresh spike hazard on the warm set
   for(int i=0; i<g_scanner.UniverseSize(); i++)
     {
      SScanEntry e;
      if(!g_scanner.GetEntry(i,e))
         continue;
      if(e.tier!=SEA_TIER_WARM)
         continue;
      g_hazard.Update(e.symbol,g_style.ExecTF(),g_pool);
     }

   CheckBudget("HTF bar close",GetMicrosecondCount()-t0,500000,g_worstHTF);
  }

//+------------------------------------------------------------------+
//| LTF bar close: zones, ranking, pending placement. Budget 50ms.    |
//+------------------------------------------------------------------+
void OnLTFBarClose()
  {
   ulong t0=GetMicrosecondCount();

   //--- 1. update the warm cascade set
   g_scanner.UpdateWarm();

   //--- 2. manage open positions against the refreshed structure
   for(int i=g_management.Count()-1; i>=0; i--)
     {
      SManagedPosition p;
      if(!g_management.At(i,p))
         continue;

      int specIndex=g_spec.IndexOf(p.symbol);
      if(specIndex<0)
         continue;

      CMTF    *mtf   =g_scanner.MTFOf(p.symbol);
      CRegime *regime=g_scanner.RegimeOf(p.symbol);
      if(mtf==NULL || regime==NULL)
         continue;

      CStructure *exec=mtf.Structure(mtf.Levels()-1);
      if(exec==NULL)
         continue;

      g_management.Manage(p.ticket,g_spec,specIndex,g_exec,exec,regime,g_hazard);
     }

   g_management.Reconcile(g_exec);

   //--- 3. the risk engine has the final say on new entries
   ENUM_SEA_HALT halt=g_risk.Evaluate();

   if(halt==SEA_HALT_HARD)
     {
      int closed=g_exec.CloseAll("max drawdown hard halt");
      int cancelled=g_exec.CancelAllPendings("max drawdown hard halt");
      if(closed>0 || cancelled>0)
         PrintFormat("[SEA] hard halt: closed %d positions, cancelled %d pendings",
                     closed,cancelled);

      if(!g_haltAlerted)
        {
         g_alert.HaltAlert(SEA_HALT_HARD,g_risk.HaltReason());
         g_haltAlerted=true;
        }

      CheckBudget("LTF bar close",GetMicrosecondCount()-t0,50000,g_worstLTF);
      return;
     }

   if(halt!=SEA_HALT_NONE)
     {
      if(!g_haltAlerted)
        {
         g_alert.HaltAlert(halt,g_risk.HaltReason());
         g_haltAlerted=true;
        }
      g_armedCount=0;   // disarm everything
      CheckBudget("LTF bar close",GetMicrosecondCount()-t0,50000,g_worstLTF);
      return;
     }
   g_haltAlerted=false;

   //--- 4. collect candidates. THE SCANNER NEVER EXECUTES.
   int candidates=g_scanner.CollectCandidates(g_spec,g_style,g_probability,g_gates,
                                              g_scoring,g_hazard,g_afford,g_risk,
                                              g_profiler);

   //--- 5. journal every rejection with its full gate results AND the
   //--- prices it was judged at, so the 20-bar follow-up can replay it
   for(int i=0; i<g_scanner.GateRecordCount(); i++)
     {
      SGateContext ctx;
      SGateResult  gr;
      if(!g_scanner.GateRecordAt(i,ctx,gr))
         continue;
      if(gr.allPassed)
         continue;

      g_journal.LogRejection(ctx.symbol,g_style.ExecTF(),ctx.direction,
                             ctx.entryPrice,ctx.stopPrice,ctx.targetPrice,
                             ctx.probability,InpMinLocationScore,gr,g_gates);
     }

   //--- 6. collapse correlated candidates
   g_scanner.ApplyCorrelationCollapse(g_spec,InpMaxCurrencyExposure);

   //--- 7. arm the top candidates for the open slots.
   //--- The remainder are DISCARDED, not queued.
   int open=g_exec.TotalPositions();
   int slots=InpMaxConcurrent-open;

   //--- micro mode forces one position at a time
   if(g_risk.IsMicroMode() && slots>1-open)
      slots=1-open;
   if(slots<0)
      slots=0;

   g_armedCount=g_scanner.TopCandidates(slots,g_armed);

   //--- 8. place the pendings now, on the bar close, at precomputed levels
   for(int i=0; i<g_armedCount; i++)
     {
      if(!g_armed[i].valid)
         continue;

      //--- a symbol already carrying a position is left to CScaling
      if(g_exec.HasPosition(g_armed[i].symbol))
         continue;
      if(g_exec.PendingCount(g_armed[i].symbol)>0)
         continue;

      string explanation=StructuralExplanation(g_armed[i]);
      if(explanation=="")
        {
         Print("[SEA] REFUSED: candidate has no structural explanation - ",
               g_armed[i].symbol);
         continue;
        }

      bool placed=g_exec.PlacePending(g_armed[i].specIndex,g_armed[i].direction,
                                      g_armed[i].entryPrice,g_armed[i].stopPrice,
                                      g_armed[i].targetPrice,g_armed[i].lots,
                                      g_style.ExecTF(),g_armed[i].expiryBars,
                                      InpTradeComment);

      SExecResult r=g_exec.LastResult();

      if(placed)
        {
         g_journal.LogTrade(g_armed[i],r.requestedPrice,r.filledPrice,
                            r.slippagePoints,1,explanation);

         int today=g_journal.NoteTradeToday();
         if(g_journal.AssertDailyLimit(g_style.MaxDailyAssert()))
            g_alert.LeakAlert(today,g_style.MaxDailyAssert());

         g_alert.EntryAlert(g_armed[i],g_armed[i].scoreBreakdown,
                            g_risk.DrawdownPercent(),InpMaxDDPercent,1);
        }
      else
         PrintFormat("[SEA] %s pending not placed: %s",
                     g_armed[i].symbol,g_exec.DescribeLast());
     }

   //--- 9. scale into winners. CScaling refuses everything that is not
   //--- a winner; nothing here can talk it round.
   for(int i=g_management.Count()-1; i>=0; i--)
     {
      SManagedPosition p;
      if(!g_management.At(i,p))
         continue;

      int specIndex=g_spec.IndexOf(p.symbol);
      if(specIndex<0)
         continue;

      CMTF    *mtf   =g_scanner.MTFOf(p.symbol);
      CRegime *regime=g_scanner.RegimeOf(p.symbol);
      if(mtf==NULL || regime==NULL)
         continue;

      CStructure *exec=mtf.Structure(mtf.Levels()-1);
      if(exec==NULL)
         continue;

      SProfile profile;
      int profileMaxLegs=-1;
      if(g_profiler.Get(p.symbol,g_style.StyleId(),profile) && profile.complete)
         profileMaxLegs=profile.maxScaleIns;

      string reason;
      if(!g_scaling.MayAdd(p.symbol,p.direction,p.ticket,g_management,exec,regime,
                           g_hazard,g_risk,g_style.MaxScaleIns(),profileMaxLegs,reason))
        {
         if(InpVerbose && reason!="")
            PrintFormat("[SEA] no scale-in on %s: %s",p.symbol,reason);
         continue;
        }

      double addLots=g_scaling.NextLegLots(p.symbol,g_spec,specIndex);
      if(addLots<=0.0)
         continue;   // decayed below VOLUME_MIN: scaling stops, never rounds up

      //--- the added leg gets its own structural stop, never a wider one
      double invalidation=0.0;
      if(!exec.InvalidationLevel(p.direction,invalidation))
         continue;

      double pad=g_spec.SpreadPrice(specIndex);
      double addStop=(p.direction==SEA_DIR_LONG ? invalidation-pad : invalidation+pad);

      if(g_exec.OpenMarket(specIndex,p.direction,addStop,0.0,addLots,
                           InpTradeComment+"-add"))
        {
         g_scaling.RecordLeg(p.symbol,addLots,1.0);

         //--- after each add, EVERY leg trails to the most recent
         //--- confirmed swing. ModifyPosition refuses any widening.
         g_scaling.TrailAllLegs(p.symbol,g_spec,specIndex,g_exec,exec);

         PrintFormat("[SEA] scaled into %s: leg %d, %s lots",
                     p.symbol,g_scaling.LegCount(p.symbol),
                     DoubleToString(addLots,4));
        }
     }

   //--- 10. rejection follow-ups
   g_journal.ProcessReviews();

   CheckBudget("LTF bar close",GetMicrosecondCount()-t0,50000,g_worstLTF);
  }

//+------------------------------------------------------------------+
//| OnTick.                                                           |
//|                                                                   |
//| HOT PATH. Budget one millisecond.                                 |
//|                                                                   |
//| This function may ONLY:                                           |
//|   detect a bar close and delegate                                 |
//|   update excursion records (two double comparisons)               |
//|   check hazard-driven forced exits against precomputed state      |
//|                                                                   |
//| It must NEVER recompute structure, zones, scores or               |
//| affordability. If you find yourself adding such a call here,      |
//| it belongs in OnLTFBarClose.                                      |
//+------------------------------------------------------------------+
void OnTick()
  {
   ulong t0=GetMicrosecondCount();

   //--- bar-close detection is a datetime comparison, nothing more
   datetime htfBar=(datetime)SeriesInfoInteger(_Symbol,g_style.CascadeTF(0),SERIES_LASTBAR_DATE);
   datetime ltfBar=(datetime)SeriesInfoInteger(_Symbol,g_style.ExecTF(),SERIES_LASTBAR_DATE);

   if(htfBar!=g_lastHTFBar)
     {
      g_lastHTFBar=htfBar;
      OnHTFBarClose();
     }

   if(ltfBar!=g_lastLTFBar)
     {
      g_lastLTFBar=ltfBar;
      OnLTFBarClose();
     }

   //--- excursion tracking: reads a price, compares two doubles
   for(int i=g_management.Count()-1; i>=0; i--)
     {
      SManagedPosition p;
      if(!g_management.At(i,p))
         continue;

      double price=(p.direction==SEA_DIR_LONG
                    ? SymbolInfoDouble(p.symbol,SYMBOL_BID)
                    : SymbolInfoDouble(p.symbol,SYMBOL_ASK));
      if(price<=0.0)
         continue;

      g_management.UpdateExcursion(p.ticket,price);

      //--- hazard forced exit, read from PRECOMPUTED hazard state
      if(g_hazard.MustFlattenCounter(p.symbol,p.direction))
         g_exec.ClosePosition(p.ticket,"hazard EXTREME: counter-spike flattened");
     }

   CheckBudget("tick",GetMicrosecondCount()-t0,1000,g_worstTick);
  }

//+------------------------------------------------------------------+
//| OnTimer.                                                          |
//|                                                                   |
//| Everything that blocks lives here: notifications, the HUD, the    |
//| weekly summary. None of it belongs in the tick path.              |
//+------------------------------------------------------------------+
void OnTimer()
  {
   //--- flush queued notifications. SendNotification is NEVER called
   //--- from OnTick.
   g_alert.Flush();

   //--- dashboard
   if(g_dashboard.IsEnabled())
     {
      g_dashboard.Begin();
      g_dashboard.Header("STRUCTURE-DRIVEN ADAPTIVE EA");
      g_dashboard.Line(StringFormat("style      %s  exec %s",
                                    g_style.Name(),g_style.TFName(g_style.ExecTF())));

      ENUM_SEA_HALT halt=g_risk.HaltState();
      int severity=(halt==SEA_HALT_NONE ? 0 : (halt==SEA_HALT_SOFT ? 1 : 2));
      g_dashboard.Severity("halt",
                           (halt==SEA_HALT_NONE ? "none" : g_risk.HaltReason()),
                           severity);

      g_dashboard.Severity("drawdown",
                           StringFormat("%.2f%% of %.2f%%",
                                        g_risk.DrawdownPercent(),InpMaxDDPercent),
                           (g_risk.DrawdownPercent()>InpMaxDDPercent*0.8 ? 2 :
                            (g_risk.DrawdownPercent()>InpMaxDDPercent*0.5 ? 1 : 0)));

      g_dashboard.Severity("daily DD",
                           StringFormat("%.2f%% of %.2f%%",
                                        g_risk.DailyDrawdownPercent(),InpDailyDDPercent),
                           (g_risk.DailyDrawdownPercent()>InpDailyDDPercent*0.8 ? 2 : 0));

      g_dashboard.Line(StringFormat("risk       %.2f%%  PF %.2f  losses %d",
                                    g_risk.CurrentRiskPercent(),
                                    g_risk.RollingProfitFactor(),
                                    g_risk.LossStreak()));

      g_dashboard.Line(StringFormat("equity     %.2f %s",
                                    AccountInfoDouble(ACCOUNT_EQUITY),
                                    AccountInfoString(ACCOUNT_CURRENCY)));

      //--- the equity band is on the HUD because it silently changes what
      //--- the EA will and will not trade
      g_dashboard.Severity("ladder band",g_risk.EquityBandName(),0);
      g_dashboard.Severity("micro mode",
                           (g_risk.IsMicroMode()
                            ? "ACTIVE - VOLUME_MIN, no scale-ins, 1 position"
                            : "off"),
                           (g_risk.IsMicroMode() ? 1 : 0));

      g_dashboard.Line(g_scanner.Describe());

      g_dashboard.Line(StringFormat("positions  %d / %d   handles %d",
                                    g_exec.TotalPositions(),InpMaxConcurrent,
                                    g_pool.LiveHandles()));

      g_dashboard.Line(StringFormat("trades today %d / %d",
                                    g_journal.TradesToday(),g_style.MaxDailyAssert()));

      g_dashboard.Line(StringFormat("latency    HTF %I64uus LTF %I64uus tick %I64uus",
                                    g_worstHTF,g_worstLTF,g_worstTick));

      //--- armed candidates
      for(int i=0; i<g_armedCount && i<5; i++)
         g_dashboard.Line(StringFormat("  %s %s score %.0f prob %.0f RR %.2f",
                                       g_armed[i].symbol,
                                       SeaDirectionToString(g_armed[i].direction),
                                       g_armed[i].score,g_armed[i].probability,
                                       g_armed[i].rr));

      g_dashboard.End();
     }

   //--- weekly summary
   if(g_lastSummary==0)
      g_lastSummary=TimeCurrent();
   if(TimeCurrent()-g_lastSummary>=604800)
     {
      g_journal.WriteWeeklySummary(g_gates);
      g_lastSummary=TimeCurrent();
     }
  }

//+------------------------------------------------------------------+
//| OnTradeTransaction.                                               |
//|                                                                   |
//| Fills start position tracking; closes feed the risk engine's      |
//| loss streak and the journal's outcome record.                     |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD)
      return;

   if(!HistoryDealSelect(trans.deal))
      return;

   //--- RULE 5: magic AND symbol
   if(HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=InpMagicNumber)
      return;

   string symbol =HistoryDealGetString(trans.deal,DEAL_SYMBOL);
   long   entry  =HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
   double price  =HistoryDealGetDouble(trans.deal,DEAL_PRICE);
   double volume =HistoryDealGetDouble(trans.deal,DEAL_VOLUME);
   double profit =HistoryDealGetDouble(trans.deal,DEAL_PROFIT);
   long   dealType=HistoryDealGetInteger(trans.deal,DEAL_TYPE);
   ulong  posId  =(ulong)HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);

   if(entry==DEAL_ENTRY_IN)
     {
      ENUM_SEA_DIRECTION dir=(dealType==DEAL_TYPE_BUY ? SEA_DIR_LONG : SEA_DIR_SHORT);

      //--- recover the stop from the live position
      double stop=0.0;
      if(PositionSelectByTicket(posId))
         stop=PositionGetDouble(POSITION_SL);

      bool counterSpike=g_hazard.IsCounterSpike(symbol,dir);

      g_management.Track(posId,symbol,dir,price,stop,volume,counterSpike);

      //--- open a scaling basket for the first leg
      CMTF *mtf=g_scanner.MTFOf(symbol);
      ENUM_SEA_STRUCT_STATE state=SEA_STRUCT_UNKNOWN;
      if(mtf!=NULL)
         state=mtf.HTFState();

      if(g_scaling.LegCount(symbol)==0)
         g_scaling.OpenBasket(symbol,dir,volume,1.0,state);

      return;
     }

   if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY)
     {
      SManagedPosition p;
      double rMultiple=0.0;
      double mae=0.0,mfe=0.0;

      if(g_management.Get(posId,p))
        {
         rMultiple=g_management.OutcomeR(p,price);
         mae=p.maxAdverse;
         mfe=p.maxFavourable;
        }

      //--- the risk engine records the outcome. A loss extends the
      //--- streak and can arm the breaker; it never raises risk.
      g_risk.RecordTrade(profit,rMultiple);

      g_journal.LogOutcome(symbol,posId,profit,rMultiple,mae,mfe,"closed");

      //--- release tracking when the position is fully gone
      if(!PositionSelectByTicket(posId))
        {
         SManagedPosition dropped;
         g_management.Untrack(posId,dropped);

         if(g_exec.PositionCount(symbol)==0)
            g_scaling.CloseBasket(symbol);
        }

      //--- announce a newly armed breaker
      if(g_risk.LossStreak()>=InpMaxConsecutiveLosses)
         g_alert.BreakerAlert(g_risk.LossStreak(),TimeCurrent());
     }
  }
//+------------------------------------------------------------------+
