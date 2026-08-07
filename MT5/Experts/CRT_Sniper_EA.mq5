//+------------------------------------------------------------------+
//|                                                CRT_Sniper_EA.mq5 |
//|   Multi-symbol, multi-style expert built on the verified Lite    |
//|   signal engine, with risk and trade management as the priority. |
//+------------------------------------------------------------------+
#property copyright "CRT Sniper EA"
#property version   "1.00"
#property description "Trades every symbol in your Market Watch, scalp + intraday + swing at once."
#property description "Risk falls as the account grows. Hard daily-loss and drawdown halts."
#property description "TRADING IS OFF BY DEFAULT - set Enable live trading to true once you have demoed it."

#include <Trade\Trade.mqh>

#define STY_SCALP 0
#define STY_INTRA 1
#define STY_SWING 2
#define NSTYLE    3

#define M_SWEEP 0
#define M_TPB   1
#define M_SMC   2   // BOS/CHoCH -> displacement -> retest of FVG or order block
#define M_FADE  3   // spike fade  : against the spike, with the drift
#define M_HUNT  4   // spike hunt  : with the spike, against the drift
#define M_ASIA  5   // Judas swing : London sweeps the Asian range and reclaims it
#define M_NREV  6   // news reversal : the release spikes out and fails back in

#define SESS_OFF 0
#define SESS_ASIA 1
#define SESS_LON  2
#define SESS_NY   3

#define ST_RANGE 0
#define ST_BULL  1
#define ST_BEAR  2

#define TR_RANGE 0
#define TR_UP    1
#define TR_DOWN  2

#define PFX "CSEA_"

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== SAFETY ==="
input bool   InpEnableTrading   = false;   // Enable live trading (leave false until demoed)
input long   InpMagic           = 770101;  // Magic number
input int    InpSlippage        = 20;      // Max slippage (points)

input group "=== Symbols ==="
input bool   InpUseWatchlist    = true;    // Trade every symbol in Market Watch
input string InpSymbolList      = "";      // ...or only these (comma separated)
input string InpExclude         = "";      // Never trade these (comma separated)
input int    InpMaxSymbols      = 12;      // Cap on symbols (protects CPU and exposure)

input group "=== Styles (all three can run at once) ==="
input bool   InpScalp           = true;    // Scalp   (M5,  anchor H1)
input bool   InpIntraday        = true;    // Intraday(M15, anchor H4)
input bool   InpSwing           = true;    // Swing   (H4,  anchor D1)

input group "=== Structure / SMC ==="
input bool   InpUseSMC          = true;    // BOS/CHoCH -> retest of the FVG or order block
input int    InpSwingLen        = 3;       // Swing strength (bars each side)
input double InpDispATR         = 1.0;     // Displacement needed to call it a real break (x ATR)
input int    InpZoneLookback    = 12;      // How far back to look for the FVG / order block
input double InpZoneTolATR      = 0.20;    // Tolerance when price taps the zone (x ATR)
input int    InpZoneExpiry      = 30;      // Zone stays armed for N bars
input double InpMaxBuyPD        = 0.50;    // Buy only below this point of the dealing range
input double InpMinSellPD       = 0.50;    // Sell only above this point of the dealing range
input bool   InpAllowCHoCH      = true;    // Allow reversal entries on a change of character

input group "=== SPIKE ENGINE (Boom / Crash / GainX / PainX) ==="
input bool   InpUseSpike        = true;    // Enable the spike models on spike indices
input bool   InpSpikeFade       = true;    // FADE : trade against the spike, with the drift
input bool   InpSpikeHunt       = false;   // HUNT : trade with the spike (low win rate, big payoff)
input double InpSpikeMult       = 5.0;     // A spike is a bar this many x the median drift range
input int    InpDriftWin        = 50;      // Median drift-range window (bars)
input int    InpSpikeScanBars   = 1500;    // History scanned to measure the spike rhythm
input int    InpMinSpikes       = 5;       // Minimum spikes observed before the engine arms
input int    InpFadeWindow      = 3;       // FADE : enter within N bars of the spike
input double InpFadeExhaust     = 0.35;    // FADE : spike must give back this fraction
input double InpFadeBlockDue    = 0.85;    // FADE : blocked when the next spike is this due
input double InpFadeSlBuf       = 0.50;    // FADE : stop beyond the spike extreme (x drift)
input double InpHuntMinDue      = 0.70;    // HUNT : minimum due-ness
input double InpHuntMaxDue      = 2.50;    // HUNT : maximum due-ness
input double InpHuntMaxPos      = 0.35;    // HUNT : max position in the drift channel
input double InpHuntSlDrift     = 3.0;     // HUNT : stop distance (x drift range)
input double InpSpikeTP1        = 0.50;    // HUNT : TP1 as a fraction of the median spike
input double InpSpikeTP2        = 1.00;    // HUNT : TP2 as a fraction of the median spike

input group "=== Signal quality ==="
input int    InpMinScore        = 70;      // Minimum quality 0-100
input int    InpCooldownBars    = 5;       // Minimum bars between signals per slot
input int    InpEmaFast         = 50;      // EMA fast
input int    InpEmaSlow         = 200;     // EMA slow
input int    InpAtrPeriod       = 14;      // ATR period
input double InpMinSepATR       = 0.15;    // Min EMA gap to call a trend (x ATR)
input int    InpRangeLook       = 50;      // Range lookback (bars)
input double InpMaxBuyLoc       = 0.55;    // Buy only below this point in the range
input double InpMinSellLoc      = 0.45;    // Sell only above this point in the range
input int    InpSlLookback      = 6;       // Structural SL lookback (bars)
input double InpSlBufATR        = 0.30;    // SL buffer beyond structure (x ATR)

input group "=== Risk : the account tiers ==="
input bool   InpCentAccount     = false;   // Force cent-account handling (auto-detected otherwise)
input double InpTier1Below      = 200.0;   // Tier 1 : equity below this
input double InpTier1Risk       = 2.0;     // Tier 1 risk %
input double InpTier2Below      = 1000.0;  // Tier 2 : equity below this
input double InpTier2Risk       = 1.5;     // Tier 2 risk %
input double InpTier3Below      = 10000.0; // Tier 3 : equity below this
input double InpTier3Risk       = 1.0;     // Tier 3 risk %
input double InpTier4Risk       = 0.75;    // Tier 4 risk % (above tier 3)
input double InpRiskCapPct      = 2.0;     // Hard ceiling on risk per trade (%)

input group "=== Risk : exposure and halts ==="
input double InpMaxOpenRiskPct  = 4.0;     // Max total live risk across all trades (%)
input int    InpMaxTrades       = 6;       // Max concurrent positions
input int    InpMaxPerSymbol    = 2;       // Max concurrent positions per symbol
input double InpMaxDailyLossPct = 3.0;     // Stop trading for the day after this loss (%)
input double InpMaxDrawdownPct  = 12.0;    // Halt entirely at this drawdown from peak equity (%)
input double InpMaxSpreadATR    = 0.25;    // Skip if spread exceeds this fraction of ATR

input group "=== Trade management ==="
input double InpBreakevenR      = 1.0;     // Move to breakeven at this many R
input double InpBreakevenLockR  = 0.10;    // Lock this much R when moving to breakeven
input double InpPartialAtR      = 2.0;     // Take partial profit at this many R
input double InpPartialPct      = 50.0;    // Percent of the position to close there
input bool   InpTrailAfterPartial = true;  // Trail the remainder after the partial
input double InpTrailATR        = 1.5;     // Trailing distance (x ATR)
input int    InpTimeStopBars    = 0;       // Close if flat after N bars (0 = off)
input double InpTimeStopMinR    = 0.30;    // "Flat" means less than this many R

input group "=== Scaling in ==="
input bool   InpAllowScaleIn    = true;    // Add to a winner
input double InpScaleInAfterR   = 1.0;     // Only once the first trade is this far ahead
input int    InpMaxScaleIns     = 1;       // Max additions per symbol

input group "=== Sessions (killzones, in GMT) ==="
input bool   InpUseSessions    = true;    // Only trade inside the selected killzones
input bool   InpSessScalp      = true;    // Apply the filter to scalp signals
input bool   InpSessIntraday   = true;    // Apply the filter to intraday signals
input bool   InpSessSwing      = false;   // Apply it to swing too (an H4 bar spans sessions)
input int    InpGmtOverride    = 99;      // Server GMT offset, 99 = detect automatically
input bool   InpAsiaOn         = false;   // Trade the Asian session itself
input int    InpAsiaStart      = 0;       // Asia start (GMT hour)
input int    InpAsiaEnd        = 6;       // Asia end (GMT hour)
input bool   InpLondonOn       = true;    // Trade London
input int    InpLonStart       = 7;       // London start (GMT hour)
input int    InpLonEnd         = 12;      // London end (GMT hour)
input bool   InpNYOn           = true;    // Trade New York
input int    InpNYStart        = 12;      // New York start (GMT hour)
input int    InpNYEnd          = 17;      // New York end (GMT hour)
input bool   InpUseJudas       = true;    // Asian range sweep model (Judas swing)
input int    InpJudasStart     = 7;       // Judas hunt window start (GMT hour)
input int    InpJudasEnd       = 12;      // Judas hunt window end (GMT hour)

input group "=== News ==="
input bool   InpUseNews         = true;    // Use the MT5 economic calendar
input bool   InpNewsHighOnly    = true;    // High impact only
input int    InpNewsBefore      = 30;      // Stop opening this many minutes before
input int    InpNewsAfter       = 30;      // Stay out this many minutes after
input bool   InpCloseBeforeNews = false;   // Close open trades before a release
input bool   InpTradeNews       = false;   // Trade the release (breakout of the pre-news range)
input int    InpNewsPreRange    = 30;      // Pre-news range length (minutes)
input int    InpNewsDelay       = 2;       // Wait this long after the release (minutes)
input int    InpNewsWindow      = 60;      // News models stay live this long (minutes)
input double InpNewsDispATR     = 1.0;     // Breakout must clear the range by this (x ATR)
input bool   InpNewsReversal    = true;    // Also trade the release that spikes out and fails back
input double InpNewsSpikeATR    = 1.5;     // Reversal : excursion beyond the range (x ATR)

input group "=== Account capability ==="
input bool   InpAffordableOnly  = true;    // Skip symbols the account is too small to size properly
input double InpTypicalStopATR  = 1.5;     // Assumed stop size for the affordability check (x ATR)
input bool   InpReportOnInit    = true;    // Log the capability report on startup

input group "=== Display ==="
input bool   InpShowPanel       = true;    // Show the panel
input int    InpFontSize        = 9;       // Panel font size

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade   g_trade;

struct Slot
  {
   string          sym;
   ENUM_TIMEFRAMES tf;
   ENUM_TIMEFRAMES htf;
   int             style;
   int             hFast, hSlow, hAtr, hHtfEma;
   datetime        lastBar;
   datetime        lastSigTime;
   datetime        newsDone;      // event already traded on this slot

   //--- market structure, carried forward bar to bar
   int             stState;       // ST_RANGE / ST_BULL / ST_BEAR
   double          swHigh, swLow;
   int             swHighBar, swLowBar;
   double          protLow, protHigh;   // breaking these is a CHoCH
   double          legLo, legHi;        // the current dealing range
   int             structBar;

   //--- an armed SMC zone waiting for price to come back
   bool            zoneOn;
   int             zoneDir;
   double          zoneLo, zoneHi;
   int             zoneBar;
   string          zoneKind;
  };
Slot g_slot[];
int  g_slots = 0;

struct SigOut
  {
   bool   valid;
   int    dir;
   int    model;
   int    score;
   double entry, sl, tp1, tp2, atr;
   string why;
  };

//--- account / session state
bool     g_cent          = false;
double   g_dayStartEq    = 0.0;
int      g_dayStamp      = -1;
double   g_peakEq        = 0.0;
bool     g_haltDrawdown  = false;
bool     g_haltDaily     = false;
string   g_haltReason    = "";

//--- news
datetime g_newsTimes[];
int      g_newsCount = 0;
string   g_newsCcy   = "";
datetime g_newsLoaded = 0;

//--- stats
int      g_opened = 0, g_closedWin = 0, g_closedLoss = 0;
double   g_lastError = 0;
string   g_lastAction = "starting up";

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
string StyleName(const int s)
  {
   if(s == STY_SCALP) return "Scalp";
   if(s == STY_SWING) return "Swing";
   return "Intraday";
  }

string ModelName(const int m)
  {
   switch(m)
     {
      case M_SWEEP: return "Liquidity sweep";
      case M_TPB:   return "Trend pullback";
      case M_SMC:   return "Structure + zone";
      case M_FADE:  return "Spike fade";
      case M_HUNT:  return "Spike hunt";
      case M_ASIA:  return "Asian sweep";
      case M_NREV:  return "News reversal";
     }
   return "?";
  }

double Clamp01(const double v) { return (v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v)); }

ENUM_TIMEFRAMES StyleTF(const int s)
  {
   if(s == STY_SCALP) return PERIOD_M5;
   if(s == STY_SWING) return PERIOD_H4;
   return PERIOD_M15;
  }

ENUM_TIMEFRAMES StyleHTF(const int s)
  {
   if(s == STY_SCALP) return PERIOD_H1;
   if(s == STY_SWING) return PERIOD_D1;
   return PERIOD_H4;
  }

//--- per-style reward profile: a scalp cannot wait for 3R, a swing should
double StyleRR1(const int s) { return (s == STY_SCALP ? 1.2 : (s == STY_SWING ? 2.5 : 2.0)); }
double StyleRR2(const int s) { return (s == STY_SCALP ? 2.0 : (s == STY_SWING ? 5.0 : 3.0)); }

bool InList(const string list, const string sym)
  {
   if(list == "") return false;
   string parts[];
   int n = StringSplit(list, ',', parts);
   for(int i = 0; i < n; i++)
     {
      string p = parts[i];
      StringTrimLeft(p); StringTrimRight(p);
      if(p != "" && StringCompare(p, sym, false) == 0) return true;
     }
   return false;
  }

//--- cent accounts carry 100 units per real currency unit; without this every
//--- small cent account is misread as a large one and risks far too much
bool DetectCent()
  {
   if(InpCentAccount) return true;
   string c = AccountInfoString(ACCOUNT_CURRENCY);
   StringToUpper(c);
   return (c == "USC" || c == "EUC" || c == "RUC" || c == "USDC" || c == "EURC");
  }

double RealEquity()
  {
   double e = AccountInfoDouble(ACCOUNT_EQUITY);
   return (g_cent ? e / 100.0 : e);
  }

double RiskPctForEquity(const double realEq)
  {
   double p = InpTier4Risk;
   if(realEq < InpTier1Below)      p = InpTier1Risk;
   else if(realEq < InpTier2Below) p = InpTier2Risk;
   else if(realEq < InpTier3Below) p = InpTier3Risk;
   return MathMin(p, InpRiskCapPct);
  }

//+------------------------------------------------------------------+
//| Position sizing - mirrors tools/verify_risk_math.py exactly      |
//+------------------------------------------------------------------+
double LotFor(const string sym, const double slDistance, const double riskMoney, string &why)
  {
   why = "";
   if(slDistance <= 0.0 || riskMoney <= 0.0) { why = "no stop distance"; return 0.0; }

   double tickVal = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSz  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0.0 || tickSz <= 0.0) { why = "instrument data unusable"; return 0.0; }

   double lossPerLot = slDistance / tickSz * tickVal;
   if(lossPerLot <= 0.0) { why = "instrument data unusable"; return 0.0; }

   double raw  = riskMoney / lossPerLot;
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(step <= 0.0) step = 0.01;

   //--- always round DOWN so rounding can never add risk
   double lots = MathFloor(raw / step) * step;
   lots = NormalizeDouble(lots, 8);

   if(lots < vmin)
     {
      why = StringFormat("needs %.4f lots, broker minimum is %.2f", raw, vmin);
      return 0.0;
     }
   if(vmax > 0.0 && lots > vmax) lots = vmax;
   return lots;
  }

double RiskOfPosition(const string sym, const double lots, const double slDistance)
  {
   double tickVal = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSz  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0.0 || tickSz <= 0.0) return 0.0;
   return lots * slDistance / tickSz * tickVal;
  }

//--- risk still live across every open position; a trade whose stop is at or
//--- beyond breakeven contributes nothing, exactly as the verifier asserts
double OpenRiskMoney()
  {
   double total = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      string sym  = PositionGetString(POSITION_SYMBOL);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double vol  = PositionGetDouble(POSITION_VOLUME);
      long   type = PositionGetInteger(POSITION_TYPE);
      if(sl <= 0.0) { total += RiskOfPosition(sym, vol, open * 0.01); continue; }

      if(type == POSITION_TYPE_BUY  && sl >= open) continue;
      if(type == POSITION_TYPE_SELL && sl <= open) continue;
      total += RiskOfPosition(sym, vol, MathAbs(open - sl));
     }
   return total;
  }

int CountPositions(const string sym = "")
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(sym != "" && PositionGetString(POSITION_SYMBOL) != sym) continue;
      n++;
     }
   return n;
  }

//+------------------------------------------------------------------+
//| News                                                             |
//+------------------------------------------------------------------+
void CollectNews(const string ccy, const datetime from, const datetime to)
  {
   if(ccy == "" || StringLen(ccy) != 3) return;
   MqlCalendarEvent ev[];
   int ne = CalendarEventByCurrency(ccy, ev);
   if(ne <= 0) return;
   MqlCalendarValue vals[];
   int nv = CalendarValueHistory(vals, from, to, NULL, ccy);
   if(nv <= 0) return;

   for(int v = 0; v < nv; v++)
      for(int e = 0; e < ne; e++)
        {
         if(ev[e].id != vals[v].event_id) continue;
         bool keep = (ev[e].importance == CALENDAR_IMPORTANCE_HIGH) ||
                     (!InpNewsHighOnly && ev[e].importance == CALENDAR_IMPORTANCE_MODERATE);
         if(keep)
           {
            int n = ArraySize(g_newsTimes);
            ArrayResize(g_newsTimes, n + 1);
            g_newsTimes[n] = vals[v].time;
           }
         break;
        }
  }

void AddCcy(string &l[], int &n, const string c)
  {
   if(c == "" || StringLen(c) != 3) return;
   for(int i = 0; i < n; i++) if(l[i] == c) return;
   ArrayResize(l, n + 1); l[n] = c; n++;
  }

void LoadNewsForUniverse()
  {
   ArrayResize(g_newsTimes, 0);
   g_newsCount = 0;
   g_newsCcy = "";
   if(!InpUseNews) return;

   string ccy[]; int n = 0;
   for(int s = 0; s < g_slots; s++)
     {
      AddCcy(ccy, n, SymbolInfoString(g_slot[s].sym, SYMBOL_CURRENCY_BASE));
      AddCcy(ccy, n, SymbolInfoString(g_slot[s].sym, SYMBOL_CURRENCY_PROFIT));
     }

   datetime from = TimeCurrent() - 3 * 86400;
   datetime to   = TimeCurrent() + 8 * 86400;
   for(int i = 0; i < n; i++)
     {
      CollectNews(ccy[i], from, to);
      g_newsCcy += (g_newsCcy == "" ? "" : "/") + ccy[i];
     }
   g_newsCount = ArraySize(g_newsTimes);
   if(g_newsCount > 0) ArraySort(g_newsTimes);
   g_newsLoaded = TimeCurrent();
  }

bool NewsBlackout(const datetime t)
  {
   if(!InpUseNews || g_newsCount <= 0) return false;
   for(int k = 0; k < g_newsCount; k++)
     {
      long d = (long)g_newsTimes[k] - (long)t;
      if(d >= 0 && d <= (long)InpNewsBefore * 60) return true;
      if(d < 0 && -d <= (long)InpNewsAfter * 60)  return true;
     }
   return false;
  }

int MinutesToNews(const datetime t)
  {
   for(int k = 0; k < g_newsCount; k++)
      if(g_newsTimes[k] >= t) return (int)(((long)g_newsTimes[k] - (long)t) / 60);
   return -1;
  }

//+------------------------------------------------------------------+
//| Candlestick confirmation (series indexing: 1 = last closed bar)  |
//+------------------------------------------------------------------+
string BullCandle(const double &o[], const double &h[], const double &l[],
                  const double &c[], const double atr)
  {
   double body = MathAbs(c[1] - o[1]);
   double rng  = h[1] - l[1];
   if(rng <= 0.0 || atr <= 0.0) return "";
   double up = h[1] - MathMax(o[1], c[1]);
   double dn = MathMin(o[1], c[1]) - l[1];

   if(c[1] > o[1] && c[2] < o[2] && c[1] >= o[2] && o[1] <= c[2] && body > 0.30 * atr)
      return "bullish engulfing";
   if(dn >= 2.0 * body && up <= 0.60 * body && c[1] >= l[1] + 0.60 * rng)
      return "hammer";
   if(c[2] < o[2] && o[1] < c[2] && c[1] > (o[2] + c[2]) * 0.5 && c[1] < o[2])
      return "piercing";
   if(dn >= 0.45 * rng && c[1] > o[1] && rng > 0.45 * atr)
      return "rejection wick";
   if(h[2] < h[3] && l[2] > l[3] && c[1] > h[2] && c[1] > o[1])
      return "inside bar break";
   if(MathAbs(l[1] - l[2]) <= 0.12 * atr && c[1] > o[1] && c[2] < o[2])
      return "double bottom bar";
   if(body > 0.45 * rng && c[1] >= l[1] + 0.7 * rng && body > 0.35 * atr)
      return "momentum close";
   return "";
  }

string BearCandle(const double &o[], const double &h[], const double &l[],
                  const double &c[], const double atr)
  {
   double body = MathAbs(c[1] - o[1]);
   double rng  = h[1] - l[1];
   if(rng <= 0.0 || atr <= 0.0) return "";
   double up = h[1] - MathMax(o[1], c[1]);
   double dn = MathMin(o[1], c[1]) - l[1];

   if(c[1] < o[1] && c[2] > o[2] && c[1] <= o[2] && o[1] >= c[2] && body > 0.30 * atr)
      return "bearish engulfing";
   if(up >= 2.0 * body && dn <= 0.60 * body && c[1] <= h[1] - 0.60 * rng)
      return "shooting star";
   if(c[2] > o[2] && o[1] > c[2] && c[1] < (o[2] + c[2]) * 0.5 && c[1] > o[2])
      return "dark cloud";
   if(up >= 0.45 * rng && c[1] < o[1] && rng > 0.45 * atr)
      return "rejection wick";
   if(h[2] < h[3] && l[2] > l[3] && c[1] < l[2] && c[1] < o[1])
      return "inside bar break";
   if(MathAbs(h[1] - h[2]) <= 0.12 * atr && c[1] < o[1] && c[2] > o[2])
      return "double top bar";
   if(body > 0.45 * rng && c[1] <= h[1] - 0.7 * rng && body > 0.35 * atr)
      return "momentum close";
   return "";
  }

int CandleStrength(const string p)
  {
   if(p == "bullish engulfing" || p == "bearish engulfing") return 20;
   if(p == "hammer" || p == "shooting star")                return 17;
   if(p == "piercing" || p == "dark cloud")                 return 15;
   if(p == "inside bar break")                              return 14;
   if(p == "double bottom bar" || p == "double top bar")    return 13;
   if(p == "rejection wick")                                return 12;
   if(p == "momentum close")                                return 10;
   return 0;
  }

//+------------------------------------------------------------------+
//| Sessions                                                         |
//|                                                                  |
//| Verified in tools/verify_sessions_news.py. Broker servers are    |
//| rarely on GMT - GMT+2 and GMT+3 are the usual offsets - so bar   |
//| times must be converted or every killzone lands on the wrong     |
//| hours and the filter silently blocks the sessions it should let  |
//| through. The offset is measured, not asked for.                  |
//+------------------------------------------------------------------+
int g_gmtOffset = 0;

void UpdateGmtOffset()
  {
   if(InpGmtOverride != 99) { g_gmtOffset = InpGmtOverride; return; }
   g_gmtOffset = (int)MathRound((double)(TimeCurrent() - TimeGMT()) / 3600.0);
  }

int GmtHourOf(const datetime serverTime)
  {
   MqlDateTime dt;
   TimeToStruct(serverTime, dt);
   return ((dt.hour - g_gmtOffset) % 24 + 24) % 24;
  }

int SessionOf(const datetime t)
  {
   int g = GmtHourOf(t);
   if(g >= InpAsiaStart && g < InpAsiaEnd) return SESS_ASIA;
   if(g >= InpLonStart  && g < InpLonEnd)  return SESS_LON;
   if(g >= InpNYStart   && g < InpNYEnd)   return SESS_NY;
   return SESS_OFF;
  }

string SessionName(const int x)
  {
   if(x == SESS_ASIA) return "ASIA";
   if(x == SESS_LON)  return "LONDON";
   if(x == SESS_NY)   return "NEW YORK";
   return "OFF-SESSION";
  }

bool SessionAllows(const int style, const datetime t)
  {
   if(!InpUseSessions) return true;
   if(style == STY_SCALP && !InpSessScalp)    return true;
   if(style == STY_INTRA && !InpSessIntraday) return true;
   if(style == STY_SWING && !InpSessSwing)    return true;

   int x = SessionOf(t);
   if(x == SESS_ASIA) return InpAsiaOn;
   if(x == SESS_LON)  return InpLondonOn;
   if(x == SESS_NY)   return InpNYOn;
   return false;
  }

//--- today's Asian range, read straight from the bars rather than accumulated,
//--- so a restart mid-session never loses it
bool AsianRange(const string sym, const ENUM_TIMEFRAMES tf, double &hi, double &lo)
  {
   hi = 0.0; lo = 0.0;
   int need = (int)(24 * 3600 / MathMax(PeriodSeconds(tf), 60)) + 10;
   need = MathMin(need, 600);

   datetime tm[];
   double hh[], ll[];
   ArraySetAsSeries(tm, true); ArraySetAsSeries(hh, true); ArraySetAsSeries(ll, true);
   if(CopyTime(sym, tf, 0, need, tm) < 10) return false;
   if(CopyHigh(sym, tf, 0, need, hh) < 10) return false;
   if(CopyLow(sym, tf, 0, need, ll) < 10)  return false;

   MqlDateTime nowDt;
   TimeToStruct(tm[0], nowDt);
   int today = nowDt.day_of_year;
   bool any = false;

   for(int i = 1; i < ArraySize(tm); i++)
     {
      MqlDateTime dt;
      TimeToStruct(tm[i], dt);
      if(dt.day_of_year != today) break;          // only today's session
      int g = GmtHourOf(tm[i]);
      if(g < InpAsiaStart || g >= InpAsiaEnd) continue;
      if(!any) { hi = hh[i]; lo = ll[i]; any = true; }
      else     { hi = MathMax(hi, hh[i]); lo = MathMin(lo, ll[i]); }
     }
   return (any && hi > lo);
  }

//+------------------------------------------------------------------+
//| Market structure                                                 |
//|                                                                  |
//| Verified in tools/verify_structure_smc.py. The important idea is |
//| the PROTECTED low: in a bull leg, breaking some minor swing low  |
//| is only a pullback. Only the low that produced the last break of |
//| structure counts, and breaking that is a change of character.    |
//| Treating every fractal as structural makes the read flip on      |
//| every pullback, which is the classic way this goes wrong.        |
//+------------------------------------------------------------------+
void UpdateStructure(Slot &s, const double &o[], const double &h[],
                     const double &l[], const double &c[], const double atr,
                     int &evType, int &evDir)
  {
   evType = 0;                       // 0 none, 1 BOS, 2 CHoCH
   evDir  = 0;

   //--- confirm the swing that sits InpSwingLen bars back
   int k = 1 + InpSwingLen;
   bool isHigh = true, isLow = true;
   for(int j = k - InpSwingLen; j <= k + InpSwingLen; j++)
     {
      if(j == k) continue;
      if(h[j] >= h[k]) isHigh = false;
      if(l[j] <= l[k]) isLow  = false;
     }
   if(isHigh) { s.swHigh = h[k]; s.swHighBar = k; }
   if(isLow)  { s.swLow  = l[k]; s.swLowBar  = k; }

   //--- the dealing range extends with the leg
   if(s.stState == ST_BULL && s.legHi > 0.0) s.legHi = MathMax(s.legHi, h[1]);
   if(s.stState == ST_BEAR && s.legLo > 0.0) s.legLo = MathMin(s.legLo, l[1]);

   double disp = InpDispATR * atr;

   if(s.stState == ST_BULL)
     {
      if(s.protLow > 0.0 && c[1] < s.protLow)
        {
         evType = 2; evDir = -1;
         s.stState = ST_BEAR;
         s.legHi = (s.legHi > 0.0 ? s.legHi : h[1]);
         s.legLo = l[1];
         s.protHigh = s.legHi;
         s.protLow = 0.0;
         s.swLow = 0.0;
        }
      else
         if(s.swHigh > 0.0 && c[1] > s.swHigh && (c[1] - s.swHigh) >= disp)
           {
            evType = 1; evDir = 1;
            if(s.swLow > 0.0) { s.protLow = s.swLow; s.legLo = s.swLow; }
            s.legHi = h[1];
            s.swHigh = 0.0;
           }
     }
   else
      if(s.stState == ST_BEAR)
        {
         if(s.protHigh > 0.0 && c[1] > s.protHigh)
           {
            evType = 2; evDir = 1;
            s.stState = ST_BULL;
            s.legLo = (s.legLo > 0.0 ? s.legLo : l[1]);
            s.legHi = h[1];
            s.protLow = s.legLo;
            s.protHigh = 0.0;
            s.swHigh = 0.0;
           }
         else
            if(s.swLow > 0.0 && c[1] < s.swLow && (s.swLow - c[1]) >= disp)
              {
               evType = 1; evDir = -1;
               if(s.swHigh > 0.0) { s.protHigh = s.swHigh; s.legHi = s.swHigh; }
               s.legLo = l[1];
               s.swLow = 0.0;
              }
        }
      else
        {
         if(s.swHigh > 0.0 && c[1] > s.swHigh && (c[1] - s.swHigh) >= disp)
           {
            evType = 1; evDir = 1;
            s.stState = ST_BULL;
            s.legLo = (s.swLow > 0.0 ? s.swLow : l[1]);
            s.legHi = h[1];
            s.protLow = s.legLo;
            s.swHigh = 0.0;
           }
         else
            if(s.swLow > 0.0 && c[1] < s.swLow && (s.swLow - c[1]) >= disp)
              {
               evType = 1; evDir = -1;
               s.stState = ST_BEAR;
               s.legHi = (s.swHigh > 0.0 ? s.swHigh : h[1]);
               s.legLo = l[1];
               s.protHigh = s.legHi;
               s.swLow = 0.0;
              }
        }
  }

//--- 0 = at the origin of the leg (deep discount), 1 = at its extreme
double RangePosition(Slot &s, const double price)
  {
   if(s.legHi <= 0.0 || s.legLo <= 0.0) return 0.5;
   double span = s.legHi - s.legLo;
   return (span > 0.0 ? (price - s.legLo) / span : 0.5);
  }

//+------------------------------------------------------------------+
//| SMC zones : the imbalance or order block left by displacement    |
//| Only zones price can still return to are accepted.               |
//+------------------------------------------------------------------+
bool FindZone(const double &o[], const double &h[], const double &l[], const double &c[],
              const bool bullish, double &zLo, double &zHi, string &kind)
  {
   //--- fair value gap first: the cleanest evidence of displacement
   for(int k = 1; k <= InpZoneLookback; k++)
     {
      if(k + 2 >= ArraySize(h)) break;
      if(bullish && l[k] > h[k+2])
        {
         zLo = h[k+2]; zHi = l[k];
         if(zHi <= c[1] && zHi > zLo) { kind = "FVG"; return true; }
        }
      if(!bullish && h[k] < l[k+2])
        {
         zHi = l[k+2]; zLo = h[k];
         if(zLo >= c[1] && zHi > zLo) { kind = "FVG"; return true; }
        }
     }
   //--- otherwise the last opposing candle before the impulse
   for(int k = 2; k <= InpZoneLookback; k++)
     {
      if(k >= ArraySize(c)) break;
      if(bullish && c[k] < o[k])
        {
         double top = MathMax(o[k], c[k]);
         if(top <= c[1]) { zLo = l[k]; zHi = top; kind = "order block"; return true; }
        }
      if(!bullish && c[k] > o[k])
        {
         double bot = MathMin(o[k], c[k]);
         if(bot >= c[1]) { zHi = h[k]; zLo = bot; kind = "order block"; return true; }
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Spike engine : measures the feed, never trusts the symbol name   |
//+------------------------------------------------------------------+
struct SpikeState
  {
   string   sym;
   int      dir;            // +1 spikes up (Boom/GainX), -1 spikes down (Crash/PainX)
   int      seen;
   double   medSpike;
   double   avgGap;
   double   drift;
   int      barsSince;
   double   lastHigh, lastLow, lastRange, preClose;
   int      lastDir;
   datetime updated;
  };
SpikeState g_spike[];

int SpikeIndexOf(const string sym)
  {
   for(int i = 0; i < ArraySize(g_spike); i++)
      if(g_spike[i].sym == sym) return i;
   int n = ArraySize(g_spike);
   ArrayResize(g_spike, n + 1);
   g_spike[n].sym = sym; g_spike[n].dir = 0; g_spike[n].seen = 0;
   g_spike[n].medSpike = 0.0; g_spike[n].avgGap = 0.0; g_spike[n].drift = 0.0;
   g_spike[n].barsSince = -1; g_spike[n].updated = 0;
   return n;
  }

double MedianOf(double &a[], const int n)
  {
   if(n <= 0) return 0.0;
   double tmp[];
   ArrayResize(tmp, n);
   ArrayCopy(tmp, a, 0, 0, n);
   ArraySort(tmp);
   return tmp[n / 2];
  }

//--- rebuilt from history once per bar of the measuring timeframe
void UpdateSpikeState(const string sym, const ENUM_TIMEFRAMES tf)
  {
   int idx = SpikeIndexOf(sym);
   if(TimeCurrent() - g_spike[idx].updated < PeriodSeconds(tf)) return;
   g_spike[idx].updated = TimeCurrent();

   int need = MathMin(InpSpikeScanBars, 5000);
   double o[], h[], l[], c[];
   ArraySetAsSeries(o, false); ArraySetAsSeries(h, false);
   ArraySetAsSeries(l, false); ArraySetAsSeries(c, false);
   if(CopyOpen(sym, tf, 0, need, o) < InpDriftWin + 50) return;
   if(CopyHigh(sym, tf, 0, need, h) < InpDriftWin + 50) return;
   if(CopyLow(sym, tf, 0, need, l)  < InpDriftWin + 50) return;
   if(CopyClose(sym, tf, 0, need, c) < InpDriftWin + 50) return;
   int n = ArraySize(c);

   double rng[];
   ArrayResize(rng, n);
   for(int i = 0; i < n; i++) rng[i] = h[i] - l[i];

   double sizes[], win[];
   ArrayResize(sizes, 0);
   ArrayResize(win, InpDriftWin);
   int up = 0, dn = 0, gapSum = 0, gapN = 0, last = -1, lastIdx = -1;
   double lastDrift = 0.0;

   for(int i = InpDriftWin; i < n - 1; i++)
     {
      for(int j = 0; j < InpDriftWin; j++) win[j] = rng[i - InpDriftWin + j];
      double drift = MedianOf(win, InpDriftWin);
      lastDrift = drift;
      if(drift <= 0.0) continue;
      if(rng[i] < InpSpikeMult * drift) continue;

      int d = ((h[i] - o[i]) >= (o[i] - l[i]) ? 1 : -1);
      if(d > 0) up++; else dn++;
      int ns = ArraySize(sizes);
      ArrayResize(sizes, ns + 1);
      sizes[ns] = rng[i];
      if(last >= 0) { gapSum += (i - last); gapN++; }
      last = i;
      lastIdx = i;
     }

   int dir = 0;
   if(up >= InpMinSpikes && up >= 3 * MathMax(1, dn))      dir = 1;
   else if(dn >= InpMinSpikes && dn >= 3 * MathMax(1, up)) dir = -1;

   g_spike[idx].dir      = dir;
   g_spike[idx].seen     = up + dn;
   g_spike[idx].medSpike = MedianOf(sizes, ArraySize(sizes));
   g_spike[idx].avgGap   = (gapN > 0 ? (double)gapSum / gapN : 0.0);
   g_spike[idx].drift    = lastDrift;
   if(lastIdx >= 0)
     {
      g_spike[idx].barsSince = (n - 1) - lastIdx;
      g_spike[idx].lastHigh  = h[lastIdx];
      g_spike[idx].lastLow   = l[lastIdx];
      g_spike[idx].lastRange = rng[lastIdx];
      g_spike[idx].preClose  = (lastIdx > 0 ? c[lastIdx - 1] : c[lastIdx]);
      g_spike[idx].lastDir   = ((h[lastIdx] - o[lastIdx]) >= (o[lastIdx] - l[lastIdx]) ? 1 : -1);
     }
   else
      g_spike[idx].barsSince = -1;
  }

//+------------------------------------------------------------------+
//| Spike models : FADE rides the drift, HUNT rides the spike        |
//+------------------------------------------------------------------+
bool SpikeSignal(Slot &s, const double &o[], const double &h[], const double &l[],
                 const double &c[], const double atr, SigOut &out)
  {
   if(!InpUseSpike) return false;
   int idx = SpikeIndexOf(s.sym);
   SpikeState sp = g_spike[idx];
   if(sp.dir == 0 || sp.seen < InpMinSpikes) return false;
   if(sp.avgGap < 5.0 || sp.drift <= 0.0 || sp.medSpike <= 0.0) return false;
   if(sp.barsSince < 0) return false;

   double dueness = sp.barsSince / sp.avgGap;
   double rr1 = StyleRR1(s.style), rr2 = StyleRR2(s.style);

   //--- FADE : the spike has fired and is giving back; ride the drift home
   if(InpSpikeFade && sp.barsSince >= 1 && sp.barsSince <= InpFadeWindow &&
      sp.lastDir == sp.dir && dueness < InpFadeBlockDue)
     {
      double exhaust = (sp.dir > 0 ? (sp.lastHigh - c[1]) : (c[1] - sp.lastLow)) / sp.lastRange;
      if(exhaust >= InpFadeExhaust)
        {
         int dir = -sp.dir;                       // with the drift
         double entry = c[1];
         double sl = (dir > 0 ? sp.lastLow - InpFadeSlBuf * sp.drift
                      : sp.lastHigh + InpFadeSlBuf * sp.drift);
         double risk = MathAbs(entry - sl);
         if(risk > 0.0)
           {
            //--- the level the spike launched from is the natural target
            double tp1 = (dir > 0 ? MathMax(sp.preClose, entry + risk * 1.0)
                          : MathMin(sp.preClose, entry - risk * 1.0));
            out.valid = true; out.dir = dir; out.model = M_FADE;
            out.score = InpMinScore;
            out.entry = entry; out.sl = sl; out.tp1 = tp1;
            out.tp2 = entry + (dir > 0 ? 1.0 : -1.0) * risk * rr2;
            out.atr = atr;
            out.why = StringFormat("spike %d bars ago gave back %.0f%%, next spike only %.0f%% due, riding the drift",
                                   sp.barsSince, exhaust * 100.0, dueness * 100.0);
            return true;
           }
        }
     }

   //--- HUNT : a spike is overdue and price sits at the far edge of the drift
   if(InpSpikeHunt && dueness >= InpHuntMinDue && dueness <= InpHuntMaxDue)
     {
      int look = MathMin(50, ArraySize(h) - 2);
      double chHi = h[ArrayMaximum(h, 1, look)];
      double chLo = l[ArrayMinimum(l, 1, look)];
      double pos = (chHi > chLo ? (c[1] - chLo) / (chHi - chLo) : 0.5);
      if(sp.dir < 0) pos = 1.0 - pos;             // Crash hunts from the top

      if(pos <= InpHuntMaxPos)
        {
         int dir = sp.dir;                        // with the spike
         double entry = c[1];
         double sl = (dir > 0 ? l[ArrayMinimum(l, 1, 10)] - InpHuntSlDrift * sp.drift
                      : h[ArrayMaximum(h, 1, 10)] + InpHuntSlDrift * sp.drift);
         double risk = MathAbs(entry - sl);
         double tp1 = entry + dir * InpSpikeTP1 * sp.medSpike;
         if(risk > 0.0 && MathAbs(tp1 - entry) / risk >= 1.0)
           {
            out.valid = true; out.dir = dir; out.model = M_HUNT;
            out.score = InpMinScore;
            out.entry = entry; out.sl = sl; out.tp1 = tp1;
            out.tp2 = entry + dir * InpSpikeTP2 * sp.medSpike;
            out.atr = atr;
            out.why = StringFormat("spike %.0f%% overdue, price at %.0f%% of the drift channel",
                                   dueness * 100.0, pos * 100.0);
            return true;
           }
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| The signal engine - the logic verified in verify_lite_logic.py   |
//+------------------------------------------------------------------+
bool Evaluate(Slot &s, SigOut &out)
  {
   out.valid = false;
   int need = InpRangeLook + 40;

   double o[], h[], l[], c[], fast[], slow[], atrb[];
   ArraySetAsSeries(o, true); ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true); ArraySetAsSeries(c, true);
   ArraySetAsSeries(fast, true); ArraySetAsSeries(slow, true); ArraySetAsSeries(atrb, true);

   if(CopyOpen(s.sym, s.tf, 0, need, o)  < need) return false;
   if(CopyHigh(s.sym, s.tf, 0, need, h)  < need) return false;
   if(CopyLow(s.sym, s.tf, 0, need, l)   < need) return false;
   if(CopyClose(s.sym, s.tf, 0, need, c) < need) return false;
   if(CopyBuffer(s.hFast, 0, 0, 5, fast) < 5)    return false;
   if(CopyBuffer(s.hSlow, 0, 0, 5, slow) < 5)    return false;
   if(CopyBuffer(s.hAtr,  0, 0, 5, atrb) < 5)    return false;

   double atr = atrb[1];
   if(atr <= 0.0 || fast[1] <= 0.0 || slow[1] <= 0.0) return false;

   //--- higher timeframe: EMA 50 only, so 50 bars is enough on any symbol
   datetime bt = iTime(s.sym, s.tf, 1);
   int hs = iBarShift(s.sym, s.htf, bt, false);
   if(hs < 0) return false;
   double hEmaArr[], hClArr[];
   ArraySetAsSeries(hEmaArr, true); ArraySetAsSeries(hClArr, true);
   if(CopyBuffer(s.hHtfEma, 0, hs + 1, 1, hEmaArr) < 1) return false;
   if(CopyClose(s.sym, s.htf, hs + 1, 1, hClArr) < 1)   return false;
   double hEma = hEmaArr[0], hCl = hClArr[0];
   if(hEma <= 0.0) return false;

   //--- structure and the spike engine run before the trend filter, because
   //--- a spike index has no meaningful EMA trend to agree with
   int evType = 0, evDir = 0;
   UpdateStructure(s, o, h, l, c, atr, evType, evDir);

   UpdateSpikeState(s.sym, s.tf);
   if(SpikeSignal(s, o, h, l, c, atr, out)) return true;

   int htfTrend = (hCl > hEma ? TR_UP : (hCl < hEma ? TR_DOWN : TR_RANGE));

   int chartTrend = TR_RANGE;
   if(MathAbs(fast[1] - slow[1]) >= InpMinSepATR * atr)
     {
      if(fast[1] > slow[1] && c[1] > slow[1]) chartTrend = TR_UP;
      if(fast[1] < slow[1] && c[1] < slow[1]) chartTrend = TR_DOWN;
     }

   int trend = TR_RANGE;
   if(chartTrend == TR_UP   && htfTrend == TR_UP)   trend = TR_UP;
   if(chartTrend == TR_DOWN && htfTrend == TR_DOWN) trend = TR_DOWN;
   if(trend == TR_RANGE) return false;

   bool buy = (trend == TR_UP);

   //--- where price sits in the recent range (used by the two simple models;
   //--- the structure model judges location against its own dealing range)
   double rHi = h[ArrayMaximum(h, 1, InpRangeLook)];
   double rLo = l[ArrayMinimum(l, 1, InpRangeLook)];
   double loc = (rHi > rLo ? (c[1] - rLo) / (rHi - rLo) : 0.5);

   string candle = (buy ? BullCandle(o, h, l, c, atr) : BearCandle(o, h, l, c, atr));

   int    model = -1;
   double trig  = 0.0;
   double locDepth = 0.0;
   string trigTxt = "";

   //--- Zones are armed on EVERY structural break, before any model can claim
   //--- the bar. Arming inside a model branch means a break that happens to
   //--- coincide with another signal is lost and never retested.
   if(InpUseSMC)
     {
      bool wantEv = (evType == 1) || (evType == 2 && InpAllowCHoCH);
      if(wantEv)
        {
         bool evBuy = (evDir > 0);
         double zl = 0.0, zh = 0.0;
         string kd = "";
         if(FindZone(o, h, l, c, evBuy, zl, zh, kd))
           {
            s.zoneOn = true; s.zoneDir = evDir;
            s.zoneLo = zl; s.zoneHi = zh; s.zoneBar = 0; s.zoneKind = kd;
            s.structBar = (evType == 2 ? 2 : 1);
           }
        }
      else
         if(s.zoneOn) s.zoneBar++;
      if(s.zoneOn && s.zoneBar > InpZoneExpiry) s.zoneOn = false;
     }

   //--- model 1: structure break, then a retest of the imbalance it left
   if(InpUseSMC && s.zoneOn && s.zoneBar > 0 && s.zoneDir == (buy ? 1 : -1))
     {
      double tol = InpZoneTolATR * atr;
      bool tapped = (buy ? (l[1] <= s.zoneHi + tol && c[1] > s.zoneLo)
                     : (h[1] >= s.zoneLo - tol && c[1] < s.zoneHi));
      double pd = RangePosition(s, c[1]);
      bool located = (buy ? pd <= InpMaxBuyPD : pd >= InpMinSellPD);
      if(tapped && located)
        {
         model = M_SMC;
         trig  = Clamp01(1.0 - MathAbs(c[1] - (buy ? s.zoneHi : s.zoneLo)) / MathMax(tol, 1e-9));
         locDepth = (buy ? Clamp01((InpMaxBuyPD - pd) / MathMax(InpMaxBuyPD, 0.01))
                     : Clamp01((pd - InpMinSellPD) / MathMax(1.0 - InpMinSellPD, 0.01)));
         trigTxt = StringFormat("%s then %s retest, %s of the leg",
                                (s.structBar == 2 ? "CHoCH" : "BOS"), s.zoneKind,
                                (pd < 0.5 ? "discount" : "premium"));
         s.zoneOn = false;
        }
     }

   //--- model 4: London sweeps the Asian range and reclaims it (Judas swing)
   if(InpUseJudas && model < 0 && s.style != STY_SWING)
     {
      int gh = GmtHourOf(iTime(s.sym, s.tf, 1));
      if(gh >= InpJudasStart && gh < InpJudasEnd)
        {
         double aHi = 0.0, aLo = 0.0;
         if(AsianRange(s.sym, s.tf, aHi, aLo))
           {
            bool sweptLo = (buy  && l[1] < aLo && c[1] > aLo);
            bool sweptHi = (!buy && h[1] > aHi && c[1] < aHi);
            if(sweptLo || sweptHi)
              {
               model = M_ASIA;
               double depth = (buy ? (aLo - l[1]) : (h[1] - aHi));
               trig = Clamp01(depth / MathMax(0.8 * atr, 1e-9));
               locDepth = 0.75;
               trigTxt = StringFormat("London swept the Asian %s at %s and reclaimed it",
                                      (buy ? "low" : "high"),
                                      DoubleToString((buy ? aLo : aHi),
                                                     (int)SymbolInfoInteger(s.sym, SYMBOL_DIGITS)));
              }
           }
        }
     }

   //--- the two simple models are judged against the plain range instead
   if(model < 0)
     {
      if(buy  && loc > InpMaxBuyLoc)  return false;
      if(!buy && loc < InpMinSellLoc) return false;
      locDepth = (buy ? Clamp01((InpMaxBuyLoc - loc) / MathMax(InpMaxBuyLoc, 0.01))
                  : Clamp01((loc - InpMinSellLoc) / MathMax(1.0 - InpMinSellLoc, 0.01)));

      //--- model 2: sweep of the prior 20-bar extreme, then reclaim
      double lvl = (buy ? l[ArrayMinimum(l, 2, 20)] : h[ArrayMaximum(h, 2, 20)]);
      double pen = (buy ? lvl - l[1] : h[1] - lvl);
      bool swept = (buy ? (l[1] < lvl && c[1] > lvl) : (h[1] > lvl && c[1] < lvl));
      if(swept && pen >= 0.15 * atr)
        {
         model = M_SWEEP;
         trig  = Clamp01(pen / (0.8 * atr));
         trigTxt = StringFormat("swept the %s at %s", (buy ? "low" : "high"),
                                DoubleToString(lvl, (int)SymbolInfoInteger(s.sym, SYMBOL_DIGITS)));
        }

      //--- model 3: pullback into EMA 50 while trending
      if(model < 0)
        {
         bool touch = (buy ? (l[1] <= fast[1] && c[1] > fast[1])
                       : (h[1] >= fast[1] && c[1] < fast[1]));
         if(touch)
           {
            model = M_TPB;
            trig  = Clamp01(MathAbs(fast[1] - slow[1]) / (1.5 * atr));
            trigTxt = StringFormat("pullback into EMA %d", InpEmaFast);
           }
        }
     }

   if(model < 0) return false;
   if(candle == "" && trig < 0.75) return false;

   //--- stop and targets
   double entry = c[1];
   double sl = (buy ? l[ArrayMinimum(l, 1, InpSlLookback)] - InpSlBufATR * atr
                : h[ArrayMaximum(h, 1, InpSlLookback)] + InpSlBufATR * atr);
   double risk = MathAbs(entry - sl);
   if(risk <= 0.0) return false;

   double rr1 = StyleRR1(s.style), rr2 = StyleRR2(s.style);
   double tp1 = entry + (buy ? 1.0 : -1.0) * risk * rr1;
   double tp2 = entry + (buy ? 1.0 : -1.0) * risk * rr2;

   double sepQ  = Clamp01(MathAbs(fast[1] - slow[1]) / (1.2 * atr));
   double htfQ  = Clamp01(MathAbs(hCl - hEma) / MathMax(MathAbs(hEma) * 0.004, 1e-9));
   double trendQ = 0.6 * sepQ + 0.4 * htfQ;

   int score = (int)MathRound(20.0 * trendQ)
               + (int)MathRound(20.0 * locDepth)
               + CandleStrength(candle)
               + (int)MathRound(20.0 * trig)
               + (int)MathRound(20.0 * Clamp01(rr2 / 3.0));
   if(score < InpMinScore) return false;

   out.valid = true;
   out.dir   = (buy ? 1 : -1);
   out.model = model;
   out.score = score;
   out.entry = entry;
   out.sl    = sl;
   out.tp1   = tp1;
   out.tp2   = tp2;
   out.atr   = atr;
   out.why   = StringFormat("%s: %s trend on %s and chart, %s in range, %s%s",
                            StyleName(s.style), (buy ? "bullish" : "bearish"),
                            EnumToString(s.htf), (buy ? "low" : "high"), trigTxt,
                            (candle == "" ? "" : ", " + candle));
   return true;
  }

//+------------------------------------------------------------------+
//| Trading the release : break of the pre-news range                |
//| This is the only model allowed to fire inside a news blackout.   |
//+------------------------------------------------------------------+
int ActiveNewsIdx(const datetime t)
  {
   for(int k = 0; k < g_newsCount; k++)
     {
      long d = (long)t - (long)g_newsTimes[k];
      if(d >= 0 && d <= (long)InpNewsWindow * 60) return k;
     }
   return -1;
  }

bool NewsBreakout(Slot &s, SigOut &out)
  {
   out.valid = false;
   if(!InpUseNews || !InpTradeNews || g_newsCount <= 0) return false;

   int idx = ActiveNewsIdx(TimeCurrent());
   if(idx < 0) return false;
   datetime T = g_newsTimes[idx];
   if(s.newsDone == T) return false;                       // one trade per event

   long since = (long)TimeCurrent() - (long)T;
   if(since < (long)InpNewsDelay * 60) return false;        // do not touch the first tick

   //--- the pre-news range: the bars between T - preRange and T
   int iFrom = iBarShift(s.sym, s.tf, T - (datetime)(InpNewsPreRange * 60), false);
   int iTo   = iBarShift(s.sym, s.tf, T, false);
   if(iFrom <= iTo || iFrom < 0 || iTo < 0) return false;
   int count = iFrom - iTo + 1;
   if(count < 2) return false;

   double hh[], ll[], atrb[], o[], h[], l[], c[];
   ArraySetAsSeries(hh, true); ArraySetAsSeries(ll, true); ArraySetAsSeries(atrb, true);
   ArraySetAsSeries(o, true); ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true); ArraySetAsSeries(c, true);

   if(CopyHigh(s.sym, s.tf, iTo, count, hh) < count) return false;
   if(CopyLow(s.sym, s.tf, iTo, count, ll)  < count) return false;
   if(CopyBuffer(s.hAtr, 0, 0, 3, atrb) < 3) return false;
   if(CopyOpen(s.sym, s.tf, 0, 4, o) < 4) return false;
   if(CopyHigh(s.sym, s.tf, 0, 4, h) < 4) return false;
   if(CopyLow(s.sym, s.tf, 0, 4, l) < 4) return false;
   if(CopyClose(s.sym, s.tf, 0, 4, c) < 4) return false;

   double preHi = hh[ArrayMaximum(hh, 0, count)];
   double preLo = ll[ArrayMinimum(ll, 0, count)];
   double atr = atrb[1];
   if(atr <= 0.0 || preHi <= preLo) return false;

   //--- how far the release pushed beyond the range in each direction
   int postFrom = iBarShift(s.sym, s.tf, T, false);
   double postHi = preHi, postLo = preLo;
   if(postFrom >= 1)
     {
      int pc = postFrom;
      double ph[], pl[];
      ArraySetAsSeries(ph, true); ArraySetAsSeries(pl, true);
      if(CopyHigh(s.sym, s.tf, 1, pc, ph) == pc && CopyLow(s.sym, s.tf, 1, pc, pl) == pc)
        {
         postHi = ph[ArrayMaximum(ph, 0, pc)];
         postLo = pl[ArrayMinimum(pl, 0, pc)];
        }
     }

   bool up   = (c[1] > preHi + InpNewsDispATR * atr);
   bool down = (c[1] < preLo - InpNewsDispATR * atr);

   //--- reversal : the spike failed and price is back INSIDE the range.
   //--- Requiring "inside" is what keeps this from firing against a live
   //--- breakout; without it the two models contradict each other.
   if(!up && !down && InpNewsReversal && c[1] > preLo && c[1] < preHi)
     {
      double upEx = postHi - preHi;
      double dnEx = preLo - postLo;
      int rdir = 0;
      if(upEx >= InpNewsSpikeATR * atr && upEx >= dnEx)      rdir = -1;
      else if(dnEx >= InpNewsSpikeATR * atr && dnEx > upEx)  rdir = 1;

      if(rdir != 0)
        {
         double rEntry = c[1];
         double rSl = (rdir > 0 ? postLo - 0.2 * atr : postHi + 0.2 * atr);
         double rRisk = MathAbs(rEntry - rSl);
         if(rRisk > 0.0)
           {
            //--- the far side of the pre-news range is the natural target
            double rTp1 = (rdir > 0 ? preHi : preLo);
            if(MathAbs(rTp1 - rEntry) / rRisk < 0.8)
               rTp1 = rEntry + rdir * rRisk * StyleRR1(s.style);
            out.valid = true; out.dir = rdir; out.model = M_NREV;
            out.score = InpMinScore;
            out.entry = rEntry; out.sl = rSl; out.tp1 = rTp1;
            out.tp2 = rEntry + rdir * rRisk * StyleRR2(s.style);
            out.atr = atr;
            out.why = StringFormat("release spiked %.1f x ATR out of the pre-news range and failed back inside",
                                   MathMax(upEx, dnEx) / MathMax(atr, 1e-9));
            s.newsDone = T;
            return true;
           }
        }
     }

   if(!up && !down) return false;

   double entry = c[1];
   double sl = (up ? preLo : preHi);
   double risk = MathAbs(entry - sl);
   if(risk <= 0.0) return false;

   double rr1 = StyleRR1(s.style), rr2 = StyleRR2(s.style);
   out.valid = true;
   out.dir   = (up ? 1 : -1);
   out.model = M_SWEEP;
   out.score = InpMinScore;                                 // gated by structure, not by score
   out.entry = entry;
   out.sl    = sl;
   out.tp1   = entry + (up ? 1.0 : -1.0) * risk * rr1;
   out.tp2   = entry + (up ? 1.0 : -1.0) * risk * rr2;
   out.atr   = atr;
   out.why   = StringFormat("news release %d min ago, broke the %d-min pre-news range %s-%s",
                            (int)(since / 60), InpNewsPreRange,
                            DoubleToString(preLo, (int)SymbolInfoInteger(s.sym, SYMBOL_DIGITS)),
                            DoubleToString(preHi, (int)SymbolInfoInteger(s.sym, SYMBOL_DIGITS)));
   s.newsDone = T;
   return true;
  }

//+------------------------------------------------------------------+
//| Broker constraints                                               |
//+------------------------------------------------------------------+
double MinStopDistance(const string sym)
  {
   long lvl = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   return (double)lvl * SymbolInfoDouble(sym, SYMBOL_POINT);
  }

bool SpreadOk(const string sym, const double atr)
  {
   if(atr <= 0.0) return false;
   double sp = (double)SymbolInfoInteger(sym, SYMBOL_SPREAD) * SymbolInfoDouble(sym, SYMBOL_POINT);
   return (sp <= InpMaxSpreadATR * atr);
  }

void SetFilling(const string sym)
  {
   long mode = SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((mode & SYMBOL_FILLING_FOK) != 0)      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((mode & SYMBOL_FILLING_IOC) != 0) g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else                                      g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
  }

//+------------------------------------------------------------------+
//| Account capability                                               |
//|                                                                  |
//| The broker's minimum lot is a hard floor. Below a certain equity |
//| the smallest trade allowed already risks more than the configured|
//| percentage, and there is no way to size correctly. Rather than   |
//| sit silent, the EA works out that floor per symbol and says so.  |
//+------------------------------------------------------------------+
double TypicalStopFor(Slot &s)
  {
   double atrb[];
   ArraySetAsSeries(atrb, true);
   if(CopyBuffer(s.hAtr, 0, 0, 3, atrb) < 3) return 0.0;
   if(atrb[1] <= 0.0) return 0.0;
   return InpTypicalStopATR * atrb[1];
  }

//--- money lost if one minimum-lot trade hits its stop
double MinLotCost(const string sym, const double stopDist)
  {
   if(stopDist <= 0.0) return 0.0;
   double tickVal = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSz  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double vmin    = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   if(tickVal <= 0.0 || tickSz <= 0.0 || vmin <= 0.0) return 0.0;
   return vmin * stopDist / tickSz * tickVal;
  }

//--- equity required before this symbol can be sized at the configured risk
double MinEquityFor(Slot &s, const double riskPct)
  {
   double stopDist = TypicalStopFor(s);
   double cost = MinLotCost(s.sym, stopDist);
   if(cost <= 0.0 || riskPct <= 0.0) return 0.0;
   return cost / (riskPct / 100.0);
  }

bool Affordable(Slot &s)
  {
   if(!InpAffordableOnly) return true;
   double need = MinEquityFor(s, RiskPctForEquity(RealEquity()));
   if(need <= 0.0) return true;                 // cannot judge, let the sizer decide
   return (AccountInfoDouble(ACCOUNT_EQUITY) >= need);
  }

int g_affordable = 0;

void CapabilityReport(const bool toLog)
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskPct = RiskPctForEquity(RealEquity());
   string ccy = AccountInfoString(ACCOUNT_CURRENCY);

   g_affordable = 0;
   double cheapest = 0.0;
   string cheapestSym = "";

   if(toLog)
     {
      PrintFormat("CRT Sniper EA capability report - equity %.2f %s, risk %.2f%% per trade",
                  eq, ccy, riskPct);
      Print("  symbol        min lot   one min-lot stop   equity needed   status");
     }

   //--- one line per symbol, not per slot
   string seen = "";
   for(int i = 0; i < g_slots; i++)
     {
      if(StringFind(seen, "|" + g_slot[i].sym + "|") >= 0) continue;
      seen += "|" + g_slot[i].sym + "|";

      double stopDist = TypicalStopFor(g_slot[i]);
      double cost = MinLotCost(g_slot[i].sym, stopDist);
      double need = (cost > 0.0 && riskPct > 0.0 ? cost / (riskPct / 100.0) : 0.0);
      double vmin = SymbolInfoDouble(g_slot[i].sym, SYMBOL_VOLUME_MIN);
      bool okNow = (need <= 0.0 || eq >= need);
      if(okNow) g_affordable++;

      if(cost > 0.0 && (cheapest == 0.0 || need < cheapest))
        { cheapest = need; cheapestSym = g_slot[i].sym; }

      if(toLog)
         PrintFormat("  %-12s  %7.2f   %16.2f   %13.2f   %s",
                     g_slot[i].sym, vmin, cost, need,
                     (okNow ? "tradable" : "ACCOUNT TOO SMALL"));
     }

   if(toLog)
     {
      if(g_affordable == 0 && cheapest > 0.0)
        {
         PrintFormat("CRT Sniper EA: this account cannot size ANY symbol at %.2f%% risk.", riskPct);
         PrintFormat("  The cheapest is %s, which needs %.2f %s at that risk.",
                     cheapestSym, cheapest, ccy);
         PrintFormat("  The broker minimum lot is a hard floor - no setting gets under it.");
         PrintFormat("  Either fund to %.2f %s, or accept a higher risk per trade.",
                     cheapest, ccy);
        }
      else
         PrintFormat("CRT Sniper EA: %d symbol(s) tradable at the current equity.", g_affordable);
     }
  }

//+------------------------------------------------------------------+
//| Guards                                                           |
//+------------------------------------------------------------------+
void UpdateAccountGuards()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > g_peakEq) g_peakEq = eq;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int stamp = dt.year * 1000 + dt.day_of_year;
   if(stamp != g_dayStamp)
     {
      g_dayStamp   = stamp;
      g_dayStartEq = eq;
      g_haltDaily  = false;
     }

   if(g_dayStartEq > 0.0)
     {
      double dayLoss = (g_dayStartEq - eq) / g_dayStartEq * 100.0;
      if(dayLoss >= InpMaxDailyLossPct && !g_haltDaily)
        {
         g_haltDaily = true;
         g_haltReason = StringFormat("daily loss %.2f%% reached", dayLoss);
         Print("CRT Sniper EA: ", g_haltReason, " - no new trades today");
        }
     }

   if(g_peakEq > 0.0)
     {
      double dd = (g_peakEq - eq) / g_peakEq * 100.0;
      if(dd >= InpMaxDrawdownPct && !g_haltDrawdown)
        {
         g_haltDrawdown = true;
         g_haltReason = StringFormat("drawdown %.2f%% from peak", dd);
         Print("CRT Sniper EA: HALTED - ", g_haltReason);
         Alert("CRT Sniper EA halted: ", g_haltReason);
        }
     }
  }

bool CanOpenNewTrade(string &blockedBy)
  {
   blockedBy = "";
   if(!InpEnableTrading)   { blockedBy = "live trading is off";       return false; }
   if(g_haltDrawdown)      { blockedBy = "drawdown halt";             return false; }
   if(g_haltDaily)         { blockedBy = "daily loss halt";           return false; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) { blockedBy = "terminal blocks trading"; return false; }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))   { blockedBy = "account blocks trading";  return false; }
   if(CountPositions() >= InpMaxTrades) { blockedBy = "max trades open"; return false; }

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq <= 0.0) { blockedBy = "no equity"; return false; }
   if(OpenRiskMoney() >= eq * InpMaxOpenRiskPct / 100.0)
     { blockedBy = "total open risk at the cap"; return false; }
   return true;
  }

//+------------------------------------------------------------------+
//| Execution                                                        |
//+------------------------------------------------------------------+
bool OpenTrade(Slot &s, SigOut &sig, const bool isScaleIn)
  {
   string sym = s.sym;
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double price = (sig.dir > 0 ? ask : bid);
   if(price <= 0.0) return false;

   //--- honour the broker's minimum stop distance
   double minDist = MinStopDistance(sym);
   double sl = sig.sl, tp = sig.tp2;
   if(sig.dir > 0)
     {
      if(price - sl < minDist) sl = price - minDist;
      if(tp - price < minDist) tp = price + minDist;
     }
   else
     {
      if(sl - price < minDist) sl = price + minDist;
      if(price - tp < minDist) tp = price - minDist;
     }
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   double slDist = MathAbs(price - sl);
   if(slDist <= 0.0) return false;

   //--- size it
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskPct = RiskPctForEquity(RealEquity());
   double riskMoney = eq * riskPct / 100.0;

   //--- a scale-in is a half-size add, never a full second bet
   if(isScaleIn) riskMoney *= 0.5;

   //--- never let this trade push total live risk past the cap
   double room = eq * InpMaxOpenRiskPct / 100.0 - OpenRiskMoney();
   if(room <= 0.0) return false;
   if(riskMoney > room) riskMoney = room;

   string why = "";
   double lots = LotFor(sym, slDist, riskMoney, why);
   if(lots <= 0.0)
     {
      g_lastAction = sym + ": " + why;
      return false;
     }

   //--- margin sanity
   double margin = 0.0;
   ENUM_ORDER_TYPE ot = (sig.dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(OrderCalcMargin(ot, sym, lots, price, margin))
      if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.5)
        {
         g_lastAction = sym + ": margin too tight";
         return false;
        }

   SetFilling(sym);
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippage);

   string cmt = StringFormat("CRT %s %s %d", StyleName(s.style), ModelName(sig.model), sig.score);
   bool okOrder = (sig.dir > 0 ? g_trade.Buy(lots, sym, 0.0, sl, tp, cmt)
                   : g_trade.Sell(lots, sym, 0.0, sl, tp, cmt));

   if(!okOrder)
     {
      g_lastError = (double)g_trade.ResultRetcode();
      g_lastAction = StringFormat("%s: order failed %d %s", sym,
                                  g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
      Print("CRT Sniper EA: ", g_lastAction);
      return false;
     }

   g_opened++;
   g_lastAction = StringFormat("%s %s %.2f lots @ %s  risk %.2f (%.2f%%)  %s",
                               (sig.dir > 0 ? "BUY" : "SELL"), sym, lots,
                               DoubleToString(price, digits), riskMoney, riskPct, sig.why);
   Print("CRT Sniper EA: ", g_lastAction);
   return true;
  }

//+------------------------------------------------------------------+
//| Trade management                                                 |
//| breakeven -> partial -> trail, in that order, once each          |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      string sym  = PositionGetString(POSITION_SYMBOL);
      long   type = PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      double vol  = PositionGetDouble(POSITION_VOLUME);
      int    dir  = (type == POSITION_TYPE_BUY ? 1 : -1);
      int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

      double px = (dir > 0 ? SymbolInfoDouble(sym, SYMBOL_BID)
                   : SymbolInfoDouble(sym, SYMBOL_ASK));
      if(px <= 0.0) continue;

      //--- R is measured from the ORIGINAL stop; once the stop has moved to
      //--- breakeven that distance is gone, so reconstruct it from the target
      double riskDist = MathAbs(open - sl);
      if(sl == 0.0 || (dir > 0 && sl >= open) || (dir < 0 && sl <= open))
        {
         if(tp != 0.0) riskDist = MathAbs(tp - open) / MathMax(StyleRR2(STY_INTRA), 0.1);
        }
      if(riskDist <= 0.0) continue;

      double rNow = (dir > 0 ? (px - open) : (open - px)) / riskDist;

      double atrBuf[];
      ArraySetAsSeries(atrBuf, true);
      double atr = 0.0;
      int hAtr = iATR(sym, PERIOD_M15, InpAtrPeriod);
      if(hAtr != INVALID_HANDLE && CopyBuffer(hAtr, 0, 0, 2, atrBuf) >= 2) atr = atrBuf[1];

      double minDist = MinStopDistance(sym);
      bool   atBreakeven = (dir > 0 ? (sl >= open) : (sl <= open && sl > 0.0));

      //--- 1. breakeven: remove the risk once the trade has proved itself
      if(!atBreakeven && rNow >= InpBreakevenR)
        {
         double newSl = open + dir * InpBreakevenLockR * riskDist;
         if(MathAbs(px - newSl) >= minDist &&
            ((dir > 0 && newSl > sl) || (dir < 0 && (newSl < sl || sl == 0.0))))
           {
            newSl = NormalizeDouble(newSl, digits);
            if(g_trade.PositionModify(ticket, newSl, tp))
              {
               Print("CRT Sniper EA: ", sym, " to breakeven at ", DoubleToString(newSl, digits));
               atBreakeven = true;
               sl = newSl;
              }
           }
        }

      //--- 2. partial: bank part of the move, let the rest run
      double closedFlag = 0.0;
      if(InpPartialPct > 0.0 && rNow >= InpPartialAtR)
        {
         //--- the comment is stamped once so a partial is never taken twice
         string cmt = PositionGetString(POSITION_COMMENT);
         if(StringFind(cmt, "|P") < 0)
           {
            double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
            double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
            double part = MathFloor((vol * InpPartialPct / 100.0) / step) * step;
            if(part >= vmin && (vol - part) >= vmin)
              {
               if(g_trade.PositionClosePartial(ticket, part))
                 {
                  Print("CRT Sniper EA: ", sym, " partial ", DoubleToString(part, 2),
                        " lots at ", DoubleToString(rNow, 2), "R");
                  closedFlag = 1.0;
                 }
              }
           }
        }

      //--- 3. trail the remainder
      if(closedFlag == 0.0 && atr > 0.0 && InpTrailATR > 0.0 &&
         (!InpTrailAfterPartial || rNow >= InpPartialAtR))
        {
         double cand = px - dir * InpTrailATR * atr;
         bool better = (dir > 0 ? (cand > sl) : (cand < sl || sl == 0.0));
         if(better && MathAbs(px - cand) >= minDist)
           {
            cand = NormalizeDouble(cand, digits);
            g_trade.PositionModify(ticket, cand, tp);
           }
        }

      //--- 4. time stop: capital sitting in a trade that is going nowhere
      if(InpTimeStopBars > 0)
        {
         datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
         int bars = iBarShift(sym, PERIOD_M15, opened, false);
         if(bars >= InpTimeStopBars && rNow < InpTimeStopMinR && rNow > -0.5)
           {
            if(g_trade.PositionClose(ticket))
               Print("CRT Sniper EA: ", sym, " time stop after ", bars, " bars at ",
                     DoubleToString(rNow, 2), "R");
           }
        }
     }
  }

//--- optionally flatten before a high-impact release
void CloseBeforeNews()
  {
   if(!InpCloseBeforeNews || g_newsCount <= 0) return;
   int mins = MinutesToNews(TimeCurrent());
   if(mins < 0 || mins > InpNewsBefore) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(g_trade.PositionClose(t))
         Print("CRT Sniper EA: closed ", PositionGetString(POSITION_SYMBOL),
               " ahead of news in ", mins, " minutes");
     }
  }

//+------------------------------------------------------------------+
//| Scale-in : add only to a trade that is already winning           |
//+------------------------------------------------------------------+
bool ScaleInAllowed(const string sym, const int dir)
  {
   if(!InpAllowScaleIn) return false;
   int same = 0;
   bool winnerFound = false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      int  pdir = (type == POSITION_TYPE_BUY ? 1 : -1);
      if(pdir != dir) return false;          // never add against an open trade
      same++;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double px   = (pdir > 0 ? SymbolInfoDouble(sym, SYMBOL_BID)
                     : SymbolInfoDouble(sym, SYMBOL_ASK));
      double rd = MathAbs(open - sl);
      if(rd > 0.0)
        {
         double r = (pdir > 0 ? (px - open) : (open - px)) / rd;
         if(r >= InpScaleInAfterR) winnerFound = true;
        }
     }
   if(same == 0) return false;
   if(same > InpMaxScaleIns) return false;
   return winnerFound;
  }

//+------------------------------------------------------------------+
//| Symbol universe                                                  |
//+------------------------------------------------------------------+
void BuildSlots()
  {
   g_slots = 0;
   ArrayResize(g_slot, 0);

   string syms[];
   int ns = 0;

   if(!InpUseWatchlist && InpSymbolList != "")
     {
      string parts[];
      int n = StringSplit(InpSymbolList, ',', parts);
      for(int i = 0; i < n; i++)
        {
         string p = parts[i];
         StringTrimLeft(p); StringTrimRight(p);
         if(p == "") continue;
         if(!SymbolSelect(p, true)) continue;
         ArrayResize(syms, ns + 1); syms[ns] = p; ns++;
        }
     }
   else
     {
      int total = SymbolsTotal(true);      // true = Market Watch only
      for(int i = 0; i < total && ns < InpMaxSymbols; i++)
        {
         string p = SymbolName(i, true);
         if(p == "") continue;
         if(InList(InpExclude, p)) continue;
         if(!SymbolInfoInteger(p, SYMBOL_SELECT)) continue;
         //--- skip anything the account cannot actually trade
         long mode = SymbolInfoInteger(p, SYMBOL_TRADE_MODE);
         if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY) continue;
         ArrayResize(syms, ns + 1); syms[ns] = p; ns++;
        }
     }

   if(ns > InpMaxSymbols) ns = InpMaxSymbols;

   for(int i = 0; i < ns; i++)
      for(int st = 0; st < NSTYLE; st++)
        {
         if(st == STY_SCALP && !InpScalp)    continue;
         if(st == STY_INTRA && !InpIntraday) continue;
         if(st == STY_SWING && !InpSwing)    continue;

         Slot s;
         s.sym   = syms[i];
         s.style = st;
         s.tf    = StyleTF(st);
         s.htf   = StyleHTF(st);
         s.hFast   = iMA(s.sym, s.tf,  InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
         s.hSlow   = iMA(s.sym, s.tf,  InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
         s.hAtr    = iATR(s.sym, s.tf, InpAtrPeriod);
         s.hHtfEma = iMA(s.sym, s.htf, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
         s.lastBar = 0;
         s.lastSigTime = 0;
         s.newsDone = 0;
         s.stState = ST_RANGE;
         s.swHigh = 0.0; s.swLow = 0.0; s.swHighBar = -1; s.swLowBar = -1;
         s.protLow = 0.0; s.protHigh = 0.0;
         s.legLo = 0.0; s.legHi = 0.0; s.structBar = -1;
         s.zoneOn = false; s.zoneDir = 0; s.zoneLo = 0.0; s.zoneHi = 0.0;
         s.zoneBar = -1; s.zoneKind = "";
         if(s.hFast == INVALID_HANDLE || s.hSlow == INVALID_HANDLE ||
            s.hAtr == INVALID_HANDLE || s.hHtfEma == INVALID_HANDLE)
            continue;

         ArrayResize(g_slot, g_slots + 1);
         g_slot[g_slots] = s;
         g_slots++;
        }

   PrintFormat("CRT Sniper EA: %d symbols x styles = %d slots", ns, g_slots);
  }

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
void PanelRow(const int idx, const string txt, const color col)
  {
   string nm = PFX + "r" + IntegerToString(idx);
   if(ObjectFind(0, nm) < 0) ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, 18 + idx * (InpFontSize + 6));
   ObjectSetString(0, nm, OBJPROP_TEXT, txt);
   ObjectSetString(0, nm, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, InpFontSize);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, col);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
  }

void DrawPanel()
  {
   if(!InpShowPanel) { ObjectsDeleteAll(0, PFX); return; }

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double realEq = RealEquity();
   double riskPct = RiskPctForEquity(realEq);
   double liveRisk = OpenRiskMoney();
   double dd = (g_peakEq > 0.0 ? (g_peakEq - eq) / g_peakEq * 100.0 : 0.0);
   double dayPL = (g_dayStartEq > 0.0 ? (eq - g_dayStartEq) / g_dayStartEq * 100.0 : 0.0);

   string blocked = "";
   bool can = CanOpenNewTrade(blocked);

   int r = 0;
   PanelRow(r++, "CRT SNIPER EA", clrWhite);
   PanelRow(r++, StringFormat("Mode        : %s", (InpEnableTrading ? "LIVE TRADING" : "MONITOR ONLY - trading disabled")),
            (InpEnableTrading ? clrLimeGreen : clrGoldenrod));
   PanelRow(r++, StringFormat("Slots       : %d  (%s%s%s)", g_slots,
                              (InpScalp ? "scalp " : ""), (InpIntraday ? "intraday " : ""),
                              (InpSwing ? "swing" : "")), clrGainsboro);
   PanelRow(r++, StringFormat("Equity      : %.2f %s%s", eq, AccountInfoString(ACCOUNT_CURRENCY),
                              (g_cent ? StringFormat("  (= %.2f real)", realEq) : "")), clrGainsboro);
   PanelRow(r++, StringFormat("Risk/trade  : %.2f%%   live risk %.2f (cap %.2f)",
                              riskPct, liveRisk, eq * InpMaxOpenRiskPct / 100.0), clrAqua);
   PanelRow(r++, StringFormat("Open trades : %d / %d", CountPositions(), InpMaxTrades), clrGainsboro);
   PanelRow(r++, StringFormat("Affordable  : %d symbols sizeable at %.2f%% risk", g_affordable, riskPct),
            (g_affordable > 0 ? clrGainsboro : clrOrangeRed));
   int sNow = SessionOf(TimeCurrent());
   PanelRow(r++, StringFormat("Session     : %s   (server is GMT%+d)", SessionName(sNow), g_gmtOffset),
            (sNow == SESS_OFF ? clrGoldenrod : clrAqua));
   PanelRow(r++, StringFormat("Day P/L     : %+.2f%%   (halt at -%.1f%%)", dayPL, InpMaxDailyLossPct),
            (dayPL >= 0.0 ? clrLimeGreen : clrOrangeRed));
   PanelRow(r++, StringFormat("Drawdown    : %.2f%%   (halt at %.1f%%)", dd, InpMaxDrawdownPct),
            (dd < InpMaxDrawdownPct * 0.5 ? clrGainsboro : clrOrangeRed));

   string newsTxt = "off";
   if(InpUseNews)
     {
      if(g_newsCount <= 0) newsTxt = "calendar unavailable";
      else
        {
         int m = MinutesToNews(TimeCurrent());
         newsTxt = StringFormat("%d events  %s", g_newsCount,
                                (NewsBlackout(TimeCurrent()) ? "BLACKOUT"
                                 : (m >= 0 ? StringFormat("next in %dm", m) : "clear")));
        }
     }
   PanelRow(r++, StringFormat("News        : %s", newsTxt),
            (NewsBlackout(TimeCurrent()) ? clrOrangeRed : clrGainsboro));
   PanelRow(r++, StringFormat("Status      : %s", (can ? "ready for signals" : blocked)),
            (can ? clrLimeGreen : clrGoldenrod));
   PanelRow(r++, StringFormat("Last        : %s", g_lastAction), C'160,180,210');

   static int lastN = 0;
   for(int k = r; k < lastN; k++) ObjectDelete(0, PFX + "r" + IntegerToString(k));
   lastN = r;
  }

//+------------------------------------------------------------------+
//| Lifecycle                                                        |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_cent = DetectCent();
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetAsyncMode(false);

   g_peakEq = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayStartEq = g_peakEq;

   UpdateGmtOffset();
   BuildSlots();
   if(g_slots == 0)
     {
      Print("CRT Sniper EA: no tradable symbols found - add symbols to Market Watch");
      return INIT_FAILED;
     }

   LoadNewsForUniverse();
   CapabilityReport(InpReportOnInit);

   if(!InpEnableTrading)
      Print("CRT Sniper EA: MONITOR ONLY. Signals are logged but no orders are sent. "
            "Set 'Enable live trading' to true once you have tested on demo.");

   EventSetTimer(5);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, PFX);
   ChartRedraw();
  }

void OnTimer()
  {
   CapabilityReport(false);
   DrawPanel();
   ChartRedraw();
  }

void OnTick()
  {
   UpdateGmtOffset();
   UpdateAccountGuards();
   ManagePositions();
   CloseBeforeNews();

   //--- refresh the calendar hourly
   if(InpUseNews && TimeCurrent() - g_newsLoaded > 3600) LoadNewsForUniverse();

   string blocked = "";
   bool canOpen = CanOpenNewTrade(blocked);

   for(int i = 0; i < g_slots; i++)
     {
      //--- one evaluation per closed bar, per slot
      datetime bt = iTime(g_slot[i].sym, g_slot[i].tf, 0);
      if(bt == 0 || bt == g_slot[i].lastBar) continue;
      g_slot[i].lastBar = bt;

      if(!Affordable(g_slot[i])) continue;

      SigOut sig;
      bool inBlackout = NewsBlackout(TimeCurrent());
      bool got = NewsBreakout(g_slot[i], sig);          // allowed during a blackout
      if(!got && !inBlackout) got = Evaluate(g_slot[i], sig);
      if(!got || !sig.valid) continue;

      //--- cooldown per slot
      int cdSec = InpCooldownBars * PeriodSeconds(g_slot[i].tf);
      if(g_slot[i].lastSigTime > 0 && (bt - g_slot[i].lastSigTime) < cdSec) continue;

      if(!SpreadOk(g_slot[i].sym, sig.atr)) continue;
      //--- news and spike models set their own timing, so they bypass killzones
      bool timingOwn = (sig.model == M_NREV || sig.model == M_FADE || sig.model == M_HUNT);
      if(!timingOwn && !SessionAllows(g_slot[i].style, TimeCurrent())) continue;

      //--- monitor-only mode still reports what it would have done
      if(!canOpen)
        {
         g_lastAction = StringFormat("%s %s %s  [%s]", (sig.dir > 0 ? "BUY" : "SELL"),
                                     g_slot[i].sym, sig.why, blocked);
         if(!InpEnableTrading) Print("CRT Sniper EA [monitor]: ", g_lastAction);
         continue;
        }

      int have = CountPositions(g_slot[i].sym);
      bool scaleIn = false;
      if(have > 0)
        {
         if(!ScaleInAllowed(g_slot[i].sym, sig.dir)) continue;
         if(have >= InpMaxPerSymbol) continue;
         scaleIn = true;
        }

      if(OpenTrade(g_slot[i], sig, scaleIn))
         g_slot[i].lastSigTime = bt;
     }
  }
//+------------------------------------------------------------------+
