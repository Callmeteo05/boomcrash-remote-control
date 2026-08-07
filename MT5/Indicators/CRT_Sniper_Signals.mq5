//+------------------------------------------------------------------+
//|                                           CRT_Sniper_Signals.mq5 |
//|         Candle Range Theory (CRT) + HTF bias + MSS execution     |
//+------------------------------------------------------------------+
#property copyright   "CRT Sniper Signals"
#property version     "1.00"
#property description "BUY / SELL dots backed by Candle Range Theory, higher-timeframe bias,"
#property description "EMA 50/200 regime, premium-discount location and candlestick confirmation."
#property description "Signals are evaluated on closed bars only - the indicator does not repaint."
#property indicator_chart_window
#property indicator_buffers 6
#property indicator_plots   2

//--- plot 1 : BUY dot
#property indicator_label1  "CRT Buy"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrDodgerBlue
#property indicator_width1  3
//--- plot 2 : SELL dot
#property indicator_label2  "CRT Sell"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrOrangeRed
#property indicator_width2  3

#define PREFIX   "CRTS_"
#define MAXSIG   128

#define REG_RANGE 0
#define REG_BULL  1
#define REG_BEAR  2

//+------------------------------------------------------------------+
//| Enums                                                            |
//+------------------------------------------------------------------+
enum ENUM_EMAFILT
  {
   EMAF_OFF    = 0,  // Off
   EMAF_SOFT   = 1,  // Soft (price vs EMA 50)
   EMAF_STRICT = 2   // Strict (EMA50/200 stacked + price side)
  };

enum ENUM_ZONEMODE
  {
   ZM_FVG_THEN_OB = 0, // FVG first, then order block
   ZM_FVG_ONLY    = 1, // Fair value gap only
   ZM_OB_ONLY     = 2  // Order block only
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Higher timeframe (CRT anchor) ==="
input ENUM_TIMEFRAMES InpHTF              = PERIOD_CURRENT; // Anchor timeframe (PERIOD_CURRENT = auto)
input int             InpCrtValidBars     = 2;              // CRT stays valid for N anchor candles
input bool            InpRequireKeyLevel  = true;           // Anchor must sit on a key S/R (liquidity) level
input int             InpSRLookback       = 10;             // Key level lookback (anchor candles)
input double          InpKeyLevelTolATR   = 0.25;           // Key level tolerance (x HTF ATR)
input double          InpMinCloseBackPct  = 0.00;           // Min close-back inside range (0..0.5 of range)

input group "=== Trend / regime engine ==="
input int             InpEmaFast          = 50;             // EMA fast
input int             InpEmaSlow          = 200;            // EMA slow
input int             InpAdxPeriod        = 14;             // ADX period
input double          InpAdxTrend         = 20.0;           // ADX above this = trending
input double          InpMinSepATR        = 0.25;           // Min EMA50/200 separation (x ATR) to call a trend
input ENUM_EMAFILT    InpEmaFilter        = EMAF_SOFT;      // EMA filter on the signal timeframe
input bool            InpBlockInRange     = true;           // Block all signals while HTF is SIDEWAYS

input group "=== Premium / discount ==="
input double          InpMaxBuyPD         = 0.50;           // Buy only when CRT position <= this (0=low,1=high)
input double          InpMinSellPD        = 0.50;           // Sell only when CRT position >= this
input bool            InpUseHtfPD         = false;          // Also gate on the HTF dealing-range position
input double          InpHtfMaxBuyPD      = 0.60;           // HTF max position for buys
input double          InpHtfMinSellPD     = 0.40;           // HTF min position for sells

input group "=== Lower timeframe execution ==="
input int             InpSwingLen         = 3;              // Swing (fractal) strength, bars each side
input int             InpLegLookback      = 12;             // Displacement leg lookback (bars)
input double          InpDispATR          = 1.20;           // Min displacement of the MSS leg (x ATR)
input ENUM_ZONEMODE   InpZoneMode         = ZM_FVG_THEN_OB; // Retest zone source
input bool            InpAllowMssRetest   = true;           // Fall back to a retest of the MSS level
input bool            InpRequirePattern   = true;           // Require a candlestick pattern at the retest
input int             InpSetupExpiry      = 24;             // Cancel setup if no entry within N bars
input double          InpInvalidATR       = 0.35;           // Zone invalidation buffer (x ATR)
input bool            InpMultiEntry       = false;          // Allow several entries from one zone
input int             InpCooldownBars     = 3;              // Min bars between signals

input group "=== Risk : stop loss & targets ==="
input int             InpAtrPeriod        = 14;             // ATR period
input int             InpSlLookback       = 6;              // Structural SL lookback (bars)
input double          InpSlBufATR         = 0.30;           // SL buffer beyond structure (x ATR)
input double          InpMaxRiskATR       = 4.0;            // Skip signal if risk > this (x ATR, 0 = off)
input double          InpRR1              = 2.0;            // Take profit 1 (R multiple)
input double          InpRR2              = 3.5;            // Take profit 2 (R multiple)
input bool            InpUseLiquidityTP   = true;           // Push TP2 to the opposing liquidity if further
input int             InpLiqLookback      = 30;             // Opposing liquidity lookback (bars)

input group "=== Display ==="
input double          InpDotOffsetATR     = 0.55;           // Dot distance from the wick (x ATR)
input bool            InpShowSLTP         = true;           // Draw SL / TP lines
input int             InpShowLastSignals  = 6;              // Draw SL/TP for the last N signals
input int             InpProjectBars      = 28;             // SL/TP line length (bars)
input color           InpSLColor          = clrCrimson;     // SL colour
input color           InpTP1Color         = clrLimeGreen;   // TP1 colour
input color           InpTP2Color         = clrMediumSpringGreen; // TP2 colour
input bool            InpShowCrtBox       = false;          // Debug: draw the active CRT range
input int             InpMaxBars          = 4000;           // Max history bars to calculate (0 = all)

input group "=== Dashboard ==="
input bool            InpShowPanel        = true;           // Show dashboard
input ENUM_BASE_CORNER InpCorner          = CORNER_LEFT_UPPER; // Panel corner
input int             InpPanelX           = 12;             // Panel X offset
input int             InpPanelY           = 22;             // Panel Y offset
input int             InpFontSize         = 8;              // Panel font size
input string          InpFontName         = "Consolas";     // Panel font
input color           InpPanelBG          = C'18,20,28';    // Panel background
input color           InpPanelText        = clrGainsboro;   // Panel text

input group "=== Alerts ==="
input bool            InpAlertPopup       = true;           // Popup alert
input bool            InpAlertPush        = false;          // Push notification
input bool            InpAlertSound       = true;           // Sound alert
input string          InpSoundFile        = "alert.wav";    // Sound file

//+------------------------------------------------------------------+
//| Buffers                                                          |
//+------------------------------------------------------------------+
double BufBuy[];
double BufSell[];
double BufSL[];
double BufTP1[];
double BufTP2[];
double BufDir[];

//+------------------------------------------------------------------+
//| Indicator handles / globals                                      |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES g_htf = PERIOD_D1;

int g_hEmaF   = INVALID_HANDLE;   // signal TF EMA fast
int g_hEmaS   = INVALID_HANDLE;   // signal TF EMA slow
int g_hAtr    = INVALID_HANDLE;   // signal TF ATR
int g_hAdx    = INVALID_HANDLE;   // signal TF ADX
int g_hEmaFH  = INVALID_HANDLE;   // HTF EMA fast
int g_hEmaSH  = INVALID_HANDLE;   // HTF EMA slow
int g_hAtrH   = INVALID_HANDLE;   // HTF ATR
int g_hAdxH   = INVALID_HANDLE;   // HTF ADX

//--- HTF data (series indexed: 0 = current forming HTF bar)
MqlRates g_hr[];
double   g_hEmaFv[], g_hEmaSv[], g_hAtrv[], g_hAdxv[];

//--- signal TF indicator data (series indexed)
double   g_emaFv[], g_emaSv[], g_atrv[], g_adxv[];

//--- CRT / setup state machine
struct CRTInfo
  {
   bool     found;
   int      dir;        // +1 bullish CRT, -1 bearish CRT
   double   hi;
   double   lo;
   datetime raidTime;
   int      raidShift;
  };

datetime g_stRaid    = 0;
int      g_stDir     = 0;
double   g_stCrtHi   = 0.0;
double   g_stCrtLo   = 0.0;
bool     g_stMss     = false;
double   g_stMssLvl  = 0.0;
int      g_stMssBar  = -1;
bool     g_stZone    = false;
double   g_stZoneHi  = 0.0;
double   g_stZoneLo  = 0.0;
string   g_stZoneKind = "";
int      g_lastSigBar = -1000000;
int      g_lastProc   = -1;

//--- LTF swing tracking
double   g_swHigh = 0.0, g_swLow = 0.0;
int      g_swHighBar = -1, g_swLowBar = -1;

//--- signal history
struct SigRec
  {
   datetime t;
   int      dir;
   double   entry, sl, tp1, tp2;
   string   pattern;
  };
SigRec   g_sig[MAXSIG];
int      g_sigCount = 0;
datetime g_lastAlert = 0;

//--- dashboard snapshot
int      g_dHtfReg = REG_RANGE, g_dLtfReg = REG_RANGE;
double   g_dHtfAdx = 0.0, g_dLtfAdx = 0.0;
bool     g_dCrt = false;
int      g_dCrtDir = 0;
double   g_dCrtHi = 0.0, g_dCrtLo = 0.0;
double   g_dPD = 0.5, g_dHtfPD = 0.5;
double   g_dAtr = 0.0;
string   g_dPhase = "SEARCHING";

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
double SV(const double &a[], const int rt, const int i)
  {
   int j = rt - 1 - i;
   int n = ArraySize(a);
   if(j < 0 || j >= n)
      return 0.0;
   return a[j];
  }

double HighestOf(const double &a[], int from, int to, const int n)
  {
   if(from < 0)
      from = 0;
   if(to > n - 1)
      to = n - 1;
   double v = -DBL_MAX;
   for(int k = from; k <= to; k++)
      if(a[k] > v)
         v = a[k];
   return (v == -DBL_MAX ? 0.0 : v);
  }

double LowestOf(const double &a[], int from, int to, const int n)
  {
   if(from < 0)
      from = 0;
   if(to > n - 1)
      to = n - 1;
   double v = DBL_MAX;
   for(int k = from; k <= to; k++)
      if(a[k] < v)
         v = a[k];
   return (v == DBL_MAX ? 0.0 : v);
  }

ENUM_TIMEFRAMES ResolveHTF(const ENUM_TIMEFRAMES chart)
  {
   switch(chart)
     {
      case PERIOD_M1:
      case PERIOD_M2:
      case PERIOD_M3:
      case PERIOD_M4:
      case PERIOD_M5:   return PERIOD_H1;
      case PERIOD_M6:
      case PERIOD_M10:
      case PERIOD_M12:
      case PERIOD_M15:
      case PERIOD_M20:
      case PERIOD_M30:  return PERIOD_H4;
      case PERIOD_H1:
      case PERIOD_H2:
      case PERIOD_H3:
      case PERIOD_H4:   return PERIOD_D1;
      case PERIOD_H6:
      case PERIOD_H8:
      case PERIOD_H12:
      case PERIOD_D1:   return PERIOD_W1;
      case PERIOD_W1:
      case PERIOD_MN1:  return PERIOD_MN1;
     }
   return PERIOD_D1;
  }

string ScaleInHint(const ENUM_TIMEFRAMES htf)
  {
   switch(htf)
     {
      case PERIOD_MN1: return "W1 / D1 / H4";
      case PERIOD_W1:  return "D1 / H4 / H1";
      case PERIOD_D1:  return "H4 / H1 / M30";
      case PERIOD_H4:  return "H1 / M30 / M15";
      case PERIOD_H1:  return "M15 / M5";
      default:         return "M5 / M1";
     }
  }

string TfName(const ENUM_TIMEFRAMES tf)
  {
   string s = EnumToString(tf);
   StringReplace(s, "PERIOD_", "");
   return s;
  }

string RegName(const int r)
  {
   if(r == REG_BULL) return "BULLISH";
   if(r == REG_BEAR) return "BEARISH";
   return "SIDEWAYS";
  }

color RegColor(const int r)
  {
   if(r == REG_BULL) return clrDodgerBlue;
   if(r == REG_BEAR) return clrOrangeRed;
   return clrGoldenrod;
  }

//+------------------------------------------------------------------+
//| Market regime classifier                                         |
//+------------------------------------------------------------------+
int Regime(const double emaF, const double emaS, const double price,
           const double adx, const double atr)
  {
   if(atr <= 0.0 || emaF <= 0.0 || emaS <= 0.0)
      return REG_RANGE;

   double sep = MathAbs(emaF - emaS);
   bool trending = (adx >= InpAdxTrend) && (sep >= InpMinSepATR * atr);
   if(!trending)
      return REG_RANGE;
   if(emaF > emaS && price > emaS)
      return REG_BULL;
   if(emaF < emaS && price < emaS)
      return REG_BEAR;
   return REG_RANGE;
  }

//+------------------------------------------------------------------+
//| Candlestick patterns                                             |
//+------------------------------------------------------------------+
string BullishPattern(const double &o[], const double &h[], const double &l[],
                      const double &c[], const int i, const double atr)
  {
   if(i < 3 || atr <= 0.0)
      return "";

   double body = MathAbs(c[i] - o[i]);
   double rng  = h[i] - l[i];
   if(rng <= 0.0)
      return "";
   double up = h[i] - MathMax(o[i], c[i]);
   double dn = MathMin(o[i], c[i]) - l[i];

   if(c[i] > o[i] && c[i-1] < o[i-1] && c[i] >= o[i-1] && o[i] <= c[i-1] && body > 0.30 * atr)
      return "Bull Engulf";

   if(dn >= 2.0 * body && up <= 0.60 * body && c[i] >= l[i] + 0.60 * rng)
      return "Hammer";

   if(c[i-1] < o[i-1] && o[i] < c[i-1] && c[i] > (o[i-1] + c[i-1]) * 0.5 && c[i] < o[i-1])
      return "Piercing";

   if(c[i-2] < o[i-2] && MathAbs(c[i-2] - o[i-2]) > 0.40 * atr &&
      MathAbs(c[i-1] - o[i-1]) < 0.35 * MathAbs(c[i-2] - o[i-2]) &&
      c[i] > o[i] && c[i] > (o[i-2] + c[i-2]) * 0.5)
      return "Morning Star";

   if(MathAbs(l[i] - l[i-1]) <= 0.12 * atr && c[i] > o[i] && c[i-1] < o[i-1] && body > 0.25 * atr)
      return "Tweezer Btm";

   if(h[i-1] < h[i-2] && l[i-1] > l[i-2] && c[i] > h[i-1] && c[i] > o[i])
      return "IB Break Up";

   if(dn >= 0.55 * rng && c[i] > (h[i] + l[i]) * 0.5 && rng > 0.50 * atr)
      return "Rejection";

   return "";
  }

string BearishPattern(const double &o[], const double &h[], const double &l[],
                      const double &c[], const int i, const double atr)
  {
   if(i < 3 || atr <= 0.0)
      return "";

   double body = MathAbs(c[i] - o[i]);
   double rng  = h[i] - l[i];
   if(rng <= 0.0)
      return "";
   double up = h[i] - MathMax(o[i], c[i]);
   double dn = MathMin(o[i], c[i]) - l[i];

   if(c[i] < o[i] && c[i-1] > o[i-1] && c[i] <= o[i-1] && o[i] >= c[i-1] && body > 0.30 * atr)
      return "Bear Engulf";

   if(up >= 2.0 * body && dn <= 0.60 * body && c[i] <= h[i] - 0.60 * rng)
      return "Shooting Star";

   if(c[i-1] > o[i-1] && o[i] > c[i-1] && c[i] < (o[i-1] + c[i-1]) * 0.5 && c[i] > o[i-1])
      return "Dark Cloud";

   if(c[i-2] > o[i-2] && MathAbs(c[i-2] - o[i-2]) > 0.40 * atr &&
      MathAbs(c[i-1] - o[i-1]) < 0.35 * MathAbs(c[i-2] - o[i-2]) &&
      c[i] < o[i] && c[i] < (o[i-2] + c[i-2]) * 0.5)
      return "Evening Star";

   if(MathAbs(h[i] - h[i-1]) <= 0.12 * atr && c[i] < o[i] && c[i-1] > o[i-1] && body > 0.25 * atr)
      return "Tweezer Top";

   if(h[i-1] < h[i-2] && l[i-1] > l[i-2] && c[i] < l[i-1] && c[i] < o[i])
      return "IB Break Dn";

   if(up >= 0.55 * rng && c[i] < (h[i] + l[i]) * 0.5 && rng > 0.50 * atr)
      return "Rejection";

   return "";
  }

//+------------------------------------------------------------------+
//| CRT detection on the anchor timeframe                            |
//|  1. anchor candle closed at a key level                          |
//|  2. next candle raids CRT-High or CRT-Low                        |
//|  3. that raiding candle closes back inside the range             |
//+------------------------------------------------------------------+
bool FindCRT(const int hs, const int htfBias, CRTInfo &out)
  {
   out.found = false;
   out.dir = 0;
   out.hi = 0.0;
   out.lo = 0.0;
   out.raidTime = 0;
   out.raidShift = -1;

   int nH = ArraySize(g_hr);
   if(nH <= 0 || hs < 0)
      return false;

   int maxJ = hs + MathMax(1, InpCrtValidBars);

   for(int j = hs + 1; j <= maxJ; j++)
     {
      int a = j + 1;                                  // anchor candle
      if(a + InpSRLookback >= nH)
         break;
      if(j >= ArraySize(g_hAtrv) || a >= ArraySize(g_hAtrv))
         break;

      double aHi = g_hr[a].high;
      double aLo = g_hr[a].low;
      double aRng = aHi - aLo;
      if(aRng <= 0.0)
         continue;

      double atrH = g_hAtrv[a];
      if(atrH <= 0.0)
         continue;
      double tol = InpKeyLevelTolATR * atrH;
      double back = MathMax(0.0, MathMin(0.5, InpMinCloseBackPct)) * aRng;

      double rHi = g_hr[j].high;
      double rLo = g_hr[j].low;
      double rCl = g_hr[j].close;

      // Bullish CRT : sweep the CRT-Low, close back above it, still inside the range
      bool bull = (rLo < aLo) && (rCl > aLo + back) && (rCl < aHi);
      // Bearish CRT : sweep the CRT-High, close back below it, still inside the range
      bool bear = (rHi > aHi) && (rCl < aHi - back) && (rCl > aLo);

      if(InpRequireKeyLevel)
        {
         double lowestPrior = DBL_MAX, highestPrior = -DBL_MAX;
         for(int k = a + 1; k <= a + InpSRLookback; k++)
           {
            if(g_hr[k].low  < lowestPrior)  lowestPrior  = g_hr[k].low;
            if(g_hr[k].high > highestPrior) highestPrior = g_hr[k].high;
           }
         if(bull && lowestPrior  != DBL_MAX  && aLo > lowestPrior + tol)  bull = false;
         if(bear && highestPrior != -DBL_MAX && aHi < highestPrior - tol) bear = false;
        }

      if(bull && bear)
        {
         // Outside candle swept both sides - let the HTF bias decide.
         if(htfBias == REG_BULL)      bear = false;
         else if(htfBias == REG_BEAR) bull = false;
         else                         { bull = false; bear = false; }
        }

      if(!bull && !bear)
         continue;

      out.found     = true;
      out.dir       = (bull ? 1 : -1);
      out.hi        = aHi;
      out.lo        = aLo;
      out.raidTime  = g_hr[j].time;
      out.raidShift = j;
      return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Setup state helpers                                              |
//+------------------------------------------------------------------+
void ResetSetup()
  {
   g_stRaid    = 0;
   g_stDir     = 0;
   g_stCrtHi   = 0.0;
   g_stCrtLo   = 0.0;
   g_stMss     = false;
   g_stMssLvl  = 0.0;
   g_stMssBar  = -1;
   g_stZone    = false;
   g_stZoneHi  = 0.0;
   g_stZoneLo  = 0.0;
   g_stZoneKind = "";
  }

void ResetAll()
  {
   ResetSetup();
   g_lastSigBar = -1000000;
   g_swHigh = 0.0;
   g_swLow  = 0.0;
   g_swHighBar = -1;
   g_swLowBar  = -1;
   g_sigCount = 0;
  }

//+------------------------------------------------------------------+
//| Retest zone builders                                             |
//+------------------------------------------------------------------+
bool BuildBullZone(const double &o[], const double &h[], const double &l[],
                   const double &c[], const int i, const int n,
                   const double atr, double &zHi, double &zLo, string &kind)
  {
   int lo = MathMax(2, i - InpLegLookback);

   if(InpZoneMode != ZM_OB_ONLY)
     {
      for(int k = i; k >= lo; k--)                  // most recent gap first
        {
         if(k - 2 < 0)
            break;
         if(l[k] > h[k-2])
           {
            zHi = l[k];
            zLo = h[k-2];
            if(zHi < c[i] && zHi > zLo)
              {
               kind = "FVG";
               return true;
              }
           }
        }
      if(InpZoneMode == ZM_FVG_ONLY)
         return false;
     }

   for(int k = i - 1; k >= lo; k--)                 // last down candle before the push
     {
      if(c[k] < o[k])
        {
         zLo = l[k];
         zHi = MathMax(o[k], c[k]);
         if(zHi < c[i] && zHi > zLo)
           {
            kind = "Order Block";
            return true;
           }
        }
     }

   if(InpAllowMssRetest && g_stMssLvl > 0.0)
     {
      zLo = g_stMssLvl - InpInvalidATR * atr;
      zHi = g_stMssLvl + 0.15 * atr;
      kind = "MSS Retest";
      return (zHi > zLo);
     }
   return false;
  }

bool BuildBearZone(const double &o[], const double &h[], const double &l[],
                   const double &c[], const int i, const int n,
                   const double atr, double &zHi, double &zLo, string &kind)
  {
   int lo = MathMax(2, i - InpLegLookback);

   if(InpZoneMode != ZM_OB_ONLY)
     {
      for(int k = i; k >= lo; k--)
        {
         if(k - 2 < 0)
            break;
         if(h[k] < l[k-2])
           {
            zLo = h[k];
            zHi = l[k-2];
            if(zLo > c[i] && zHi > zLo)
              {
               kind = "FVG";
               return true;
              }
           }
        }
      if(InpZoneMode == ZM_FVG_ONLY)
         return false;
     }

   for(int k = i - 1; k >= lo; k--)                 // last up candle before the drop
     {
      if(c[k] > o[k])
        {
         zHi = h[k];
         zLo = MathMin(o[k], c[k]);
         if(zLo > c[i] && zHi > zLo)
           {
            kind = "Order Block";
            return true;
           }
        }
     }

   if(InpAllowMssRetest && g_stMssLvl > 0.0)
     {
      zHi = g_stMssLvl + InpInvalidATR * atr;
      zLo = g_stMssLvl - 0.15 * atr;
      kind = "MSS Retest";
      return (zHi > zLo);
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Signal storage                                                   |
//+------------------------------------------------------------------+
void PushSignal(const datetime t, const int dir, const double entry,
                const double sl, const double tp1, const double tp2,
                const string pat)
  {
   if(g_sigCount < MAXSIG)
     {
      g_sig[g_sigCount].t = t;
      g_sig[g_sigCount].dir = dir;
      g_sig[g_sigCount].entry = entry;
      g_sig[g_sigCount].sl = sl;
      g_sig[g_sigCount].tp1 = tp1;
      g_sig[g_sigCount].tp2 = tp2;
      g_sig[g_sigCount].pattern = pat;
      g_sigCount++;
     }
   else
     {
      for(int k = 1; k < MAXSIG; k++)
         g_sig[k-1] = g_sig[k];
      g_sig[MAXSIG-1].t = t;
      g_sig[MAXSIG-1].dir = dir;
      g_sig[MAXSIG-1].entry = entry;
      g_sig[MAXSIG-1].sl = sl;
      g_sig[MAXSIG-1].tp1 = tp1;
      g_sig[MAXSIG-1].tp2 = tp2;
      g_sig[MAXSIG-1].pattern = pat;
     }
  }

//+------------------------------------------------------------------+
//| Object drawing                                                   |
//+------------------------------------------------------------------+
void MakeSeg(const string name, const datetime t1, const datetime t2,
             const double price, const color col, const int style, const int width)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, price);
   ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 1, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void MakeText(const string name, const datetime t, const double price,
              const string txt, const color col)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, price);
   ObjectSetString(0, name, OBJPROP_TEXT, txt);
   ObjectSetString(0, name, OBJPROP_FONT, InpFontName);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpFontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void DrawSignalLevels(const bool force)
  {
   static int drawnCount = -1;
   if(!force && drawnCount == g_sigCount)
      return;                            // nothing new - avoid redrawing every tick
   drawnCount = g_sigCount;

   ObjectsDeleteAll(0, PREFIX + "lvl_");
   if(!InpShowSLTP || g_sigCount == 0)
      return;

   int show = MathMin(InpShowLastSignals, g_sigCount);
   int span = MathMax(4, InpProjectBars) * PeriodSeconds(_Period);

   for(int s = g_sigCount - show; s < g_sigCount; s++)
     {
      datetime t1 = g_sig[s].t;
      datetime t2 = t1 + span;
      string   id = PREFIX + "lvl_" + IntegerToString(s) + "_";

      MakeSeg(id + "sl",  t1, t2, g_sig[s].sl,  InpSLColor,  STYLE_DOT,  1);
      MakeSeg(id + "tp1", t1, t2, g_sig[s].tp1, InpTP1Color, STYLE_DOT,  1);
      MakeSeg(id + "tp2", t1, t2, g_sig[s].tp2, InpTP2Color, STYLE_DASH, 1);

      MakeText(id + "tsl",  t2, g_sig[s].sl,  " SL "  + DoubleToString(g_sig[s].sl,  _Digits), InpSLColor);
      MakeText(id + "ttp1", t2, g_sig[s].tp1, " TP1 " + DoubleToString(g_sig[s].tp1, _Digits), InpTP1Color);
      MakeText(id + "ttp2", t2, g_sig[s].tp2, " TP2 " + DoubleToString(g_sig[s].tp2, _Digits), InpTP2Color);
     }
  }

void DrawCrtBox()
  {
   string nm = PREFIX + "crtbox";
   if(!InpShowCrtBox || !g_dCrt)
     {
      ObjectDelete(0, nm);
      return;
     }
   datetime t1 = g_stRaid;
   datetime t2 = TimeCurrent() + 10 * PeriodSeconds(_Period);
   if(ObjectFind(0, nm) < 0)
      ObjectCreate(0, nm, OBJ_RECTANGLE, 0, t1, g_dCrtHi, t2, g_dCrtLo);
   ObjectSetInteger(0, nm, OBJPROP_TIME, 0, t1);
   ObjectSetDouble(0, nm, OBJPROP_PRICE, 0, g_dCrtHi);
   ObjectSetInteger(0, nm, OBJPROP_TIME, 1, t2);
   ObjectSetDouble(0, nm, OBJPROP_PRICE, 1, g_dCrtLo);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, (g_dCrtDir > 0 ? clrDodgerBlue : clrOrangeRed));
   ObjectSetInteger(0, nm, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, nm, OBJPROP_BACK, true);
   ObjectSetInteger(0, nm, OBJPROP_FILL, false);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
void PanelRow(const int idx, const string txt, const color col)
  {
   string nm = PREFIX + "row" + IntegerToString(idx);
   if(ObjectFind(0, nm) < 0)
      ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, nm, OBJPROP_CORNER, InpCorner);
   ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, InpPanelX + 10);
   ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, InpPanelY + 10 + idx * (InpFontSize + 7));
   ObjectSetString(0, nm, OBJPROP_TEXT, txt);
   ObjectSetString(0, nm, OBJPROP_FONT, InpFontName);
   ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, InpFontSize);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, col);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
  }

void DrawPanel()
  {
   if(!InpShowPanel)
     {
      ObjectsDeleteAll(0, PREFIX + "row");
      ObjectDelete(0, PREFIX + "bg");
      return;
     }

   const int rows = 19;
   int rowH = InpFontSize + 7;
   int w = InpFontSize * 40 + 30;
   int h = rows * rowH + 20;

   string bg = PREFIX + "bg";
   if(ObjectFind(0, bg) < 0)
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bg, OBJPROP_CORNER, InpCorner);
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, InpPanelX);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, InpPanelY);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, InpPanelBG);
   ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bg, OBJPROP_COLOR, C'60,66,86');
   ObjectSetInteger(0, bg, OBJPROP_BACK, false);
   ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);

   string pdTxt = (g_dPD < 0.45 ? "DISCOUNT" : (g_dPD > 0.55 ? "PREMIUM" : "EQUILIBRIUM"));
   color  pdCol = (g_dPD < 0.45 ? clrDodgerBlue : (g_dPD > 0.55 ? clrOrangeRed : clrGoldenrod));
   string hpdTxt = (g_dHtfPD < 0.45 ? "DISCOUNT" : (g_dHtfPD > 0.55 ? "PREMIUM" : "EQUILIBRIUM"));

   string crtTxt = "SEARCHING";
   color  crtCol = clrSilver;
   if(g_dCrt)
     {
      crtTxt = (g_dCrtDir > 0 ? "BULLISH CRT ARMED" : "BEARISH CRT ARMED");
      crtCol = (g_dCrtDir > 0 ? clrDodgerBlue : clrOrangeRed);
     }

   string lastTxt = "-", sltpTxt = "-", tp2Txt = "-";
   color  lastCol = clrSilver;
   if(g_sigCount > 0)
     {
      SigRec s = g_sig[g_sigCount-1];
      double risk = MathAbs(s.entry - s.sl);
      double rr   = (risk > 0.0 ? MathAbs(s.tp2 - s.entry) / risk : 0.0);
      lastTxt = StringFormat("%s %s  [%s]", (s.dir > 0 ? "BUY" : "SELL"),
                             DoubleToString(s.entry, _Digits), s.pattern);
      lastCol = (s.dir > 0 ? clrDodgerBlue : clrOrangeRed);
      sltpTxt = StringFormat("%s / %s", DoubleToString(s.sl, _Digits), DoubleToString(s.tp1, _Digits));
      tp2Txt  = StringFormat("%s   (1:%.1f)", DoubleToString(s.tp2, _Digits), rr);
     }

   string scale = "-";
   color  scaleCol = clrSilver;
   if(g_dCrt && g_dHtfReg != REG_RANGE &&
      ((g_dCrtDir > 0 && g_dHtfReg == REG_BULL) || (g_dCrtDir < 0 && g_dHtfReg == REG_BEAR)))
     {
      scale = StringFormat("%s on %s", (g_dCrtDir > 0 ? "LONGS" : "SHORTS"), ScaleInHint(g_htf));
      scaleCol = (g_dCrtDir > 0 ? clrDodgerBlue : clrOrangeRed);
     }

   double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   bool haveEma = (ArraySize(g_emaFv) > 0 && ArraySize(g_emaSv) > 0);
   string emaTxt = "-";
   color  emaCol = clrSilver;
   if(haveEma)
     {
      bool bullStack = (g_emaFv[0] > g_emaSv[0]);
      emaTxt = (bullStack ? "BULL STACK" : "BEAR STACK");
      emaCol = (bullStack ? clrDodgerBlue : clrOrangeRed);
     }

   int r = 0;
   PanelRow(r++, "  C R T   S N I P E R", clrWhite);
   PanelRow(r++, StringFormat("Market     : %s  %s", _Symbol, TfName((ENUM_TIMEFRAMES)_Period)), InpPanelText);
   PanelRow(r++, "-----------------------------------------", C'70,76,96');
   PanelRow(r++, StringFormat("HTF anchor : %s", TfName(g_htf)), InpPanelText);
   PanelRow(r++, StringFormat("HTF bias   : %s  (ADX %.1f)", RegName(g_dHtfReg), g_dHtfAdx), RegColor(g_dHtfReg));
   PanelRow(r++, StringFormat("Chart trend: %s  (ADX %.1f)", RegName(g_dLtfReg), g_dLtfAdx), RegColor(g_dLtfReg));
   PanelRow(r++, StringFormat("EMA %d/%d : %s", InpEmaFast, InpEmaSlow, emaTxt), emaCol);
   PanelRow(r++, "-----------------------------------------", C'70,76,96');
   PanelRow(r++, StringFormat("CRT state  : %s", crtTxt), crtCol);
   PanelRow(r++, StringFormat("CRT range  : %s / %s",
                              (g_dCrt ? DoubleToString(g_dCrtHi, _Digits) : "-"),
                              (g_dCrt ? DoubleToString(g_dCrtLo, _Digits) : "-")), InpPanelText);
   PanelRow(r++, StringFormat("Location   : %s %.0f%%", pdTxt, g_dPD * 100.0), pdCol);
   PanelRow(r++, StringFormat("HTF range  : %s %.0f%%", hpdTxt, g_dHtfPD * 100.0), InpPanelText);
   PanelRow(r++, StringFormat("Setup      : %s", g_dPhase), clrSilver);
   PanelRow(r++, "-----------------------------------------", C'70,76,96');
   PanelRow(r++, StringFormat("Last signal: %s", lastTxt), lastCol);
   PanelRow(r++, StringFormat("SL / TP1   : %s", sltpTxt), InpPanelText);
   PanelRow(r++, StringFormat("TP2        : %s", tp2Txt), InpPanelText);
   PanelRow(r++, StringFormat("Scale in   : %s", scale), scaleCol);
   PanelRow(r++, StringFormat("ATR/Spread : %s / %.0f", DoubleToString(g_dAtr, _Digits), spread), C'150,156,176');
  }

//+------------------------------------------------------------------+
//| Alerts                                                           |
//+------------------------------------------------------------------+
void FireAlert(const datetime t, const int dir, const double entry,
               const double sl, const double tp1, const double tp2, const string pat)
  {
   if(t <= g_lastAlert)
      return;
   g_lastAlert = t;

   string msg = StringFormat("%s %s %s | %s @ %s  SL %s  TP1 %s  TP2 %s  [%s]",
                             (dir > 0 ? "BUY" : "SELL"), _Symbol, TfName((ENUM_TIMEFRAMES)_Period),
                             (dir > 0 ? "CRT bullish" : "CRT bearish"),
                             DoubleToString(entry, _Digits), DoubleToString(sl, _Digits),
                             DoubleToString(tp1, _Digits), DoubleToString(tp2, _Digits), pat);

   if(InpAlertPopup) Alert(msg);
   if(InpAlertPush)  SendNotification(msg);
   if(InpAlertSound) PlaySound(InpSoundFile);
  }

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_htf = (InpHTF == PERIOD_CURRENT ? ResolveHTF((ENUM_TIMEFRAMES)_Period) : InpHTF);
   if(PeriodSeconds(g_htf) <= PeriodSeconds(_Period))
      g_htf = ResolveHTF((ENUM_TIMEFRAMES)_Period);

   SetIndexBuffer(0, BufBuy,  INDICATOR_DATA);
   SetIndexBuffer(1, BufSell, INDICATOR_DATA);
   SetIndexBuffer(2, BufSL,   INDICATOR_CALCULATIONS);
   SetIndexBuffer(3, BufTP1,  INDICATOR_CALCULATIONS);
   SetIndexBuffer(4, BufTP2,  INDICATOR_CALCULATIONS);
   SetIndexBuffer(5, BufDir,  INDICATOR_CALCULATIONS);

   ArraySetAsSeries(BufBuy,  false);
   ArraySetAsSeries(BufSell, false);
   ArraySetAsSeries(BufSL,   false);
   ArraySetAsSeries(BufTP1,  false);
   ArraySetAsSeries(BufTP2,  false);
   ArraySetAsSeries(BufDir,  false);

   PlotIndexSetInteger(0, PLOT_ARROW, 159);
   PlotIndexSetInteger(1, PLOT_ARROW, 159);
   PlotIndexSetInteger(0, PLOT_ARROW_SHIFT, 0);
   PlotIndexSetInteger(1, PLOT_ARROW_SHIFT, 0);
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetString(0, PLOT_LABEL, "CRT Buy");
   PlotIndexSetString(1, PLOT_LABEL, "CRT Sell");

   IndicatorSetString(INDICATOR_SHORTNAME,
                      StringFormat("CRT Sniper (HTF %s)", TfName(g_htf)));
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

   g_hEmaF  = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaS  = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hAtr   = iATR(_Symbol, _Period, InpAtrPeriod);
   g_hAdx   = iADX(_Symbol, _Period, InpAdxPeriod);
   g_hEmaFH = iMA(_Symbol, g_htf, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaSH = iMA(_Symbol, g_htf, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hAtrH  = iATR(_Symbol, g_htf, InpAtrPeriod);
   g_hAdxH  = iADX(_Symbol, g_htf, InpAdxPeriod);

   if(g_hEmaF == INVALID_HANDLE || g_hEmaS == INVALID_HANDLE || g_hAtr == INVALID_HANDLE ||
      g_hAdx == INVALID_HANDLE || g_hEmaFH == INVALID_HANDLE || g_hEmaSH == INVALID_HANDLE ||
      g_hAtrH == INVALID_HANDLE || g_hAdxH == INVALID_HANDLE)
     {
      Print("CRT Sniper: failed to create indicator handles");
      return INIT_FAILED;
     }

   ArraySetAsSeries(g_hr,     true);
   ArraySetAsSeries(g_hEmaFv, true);
   ArraySetAsSeries(g_hEmaSv, true);
   ArraySetAsSeries(g_hAtrv,  true);
   ArraySetAsSeries(g_hAdxv,  true);
   ArraySetAsSeries(g_emaFv,  true);
   ArraySetAsSeries(g_emaSv,  true);
   ArraySetAsSeries(g_atrv,   true);
   ArraySetAsSeries(g_adxv,   true);

   ResetAll();
   g_lastProc = -1;
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Load higher timeframe and signal timeframe series                |
//+------------------------------------------------------------------+
bool LoadSeries(const int rates_total, const int calcFrom)
  {
   int ltfNeed = rates_total - calcFrom + 5;
   if(ltfNeed < 50)
      ltfNeed = 50;

   ArraySetAsSeries(g_hr,     true);
   ArraySetAsSeries(g_hEmaFv, true);
   ArraySetAsSeries(g_hEmaSv, true);
   ArraySetAsSeries(g_hAtrv,  true);
   ArraySetAsSeries(g_hAdxv,  true);
   ArraySetAsSeries(g_emaFv,  true);
   ArraySetAsSeries(g_emaSv,  true);
   ArraySetAsSeries(g_atrv,   true);
   ArraySetAsSeries(g_adxv,   true);

   if(CopyBuffer(g_hEmaF, 0, 0, ltfNeed, g_emaFv) <= 0) return false;
   if(CopyBuffer(g_hEmaS, 0, 0, ltfNeed, g_emaSv) <= 0) return false;
   if(CopyBuffer(g_hAtr,  0, 0, ltfNeed, g_atrv)  <= 0) return false;
   if(CopyBuffer(g_hAdx,  0, 0, ltfNeed, g_adxv)  <= 0) return false;

   double ratio = (double)PeriodSeconds(_Period) / (double)PeriodSeconds(g_htf);
   int htfNeed = (int)MathCeil((rates_total - calcFrom) * ratio)
                 + InpEmaSlow + InpSRLookback + InpCrtValidBars + 20;
   htfNeed = MathMax(htfNeed, InpEmaSlow + 60);
   htfNeed = MathMin(htfNeed, 6000);

   if(CopyRates(_Symbol, g_htf, 0, htfNeed, g_hr) <= 0)   return false;
   if(CopyBuffer(g_hEmaFH, 0, 0, htfNeed, g_hEmaFv) <= 0) return false;
   if(CopyBuffer(g_hEmaSH, 0, 0, htfNeed, g_hEmaSv) <= 0) return false;
   if(CopyBuffer(g_hAtrH,  0, 0, htfNeed, g_hAtrv)  <= 0) return false;
   if(CopyBuffer(g_hAdxH,  0, 0, htfNeed, g_hAdxv)  <= 0) return false;

   return true;
  }

//+------------------------------------------------------------------+
//| Higher timeframe context for a given chart bar                   |
//+------------------------------------------------------------------+
bool HtfContext(const datetime barTime, int &hs, int &bias, double &htfPD, double &htfAdx)
  {
   hs = iBarShift(_Symbol, g_htf, barTime, false);
   if(hs < 0)
      return false;

   int nH = ArraySize(g_hr);
   int need = hs + 1 + InpSRLookback + InpCrtValidBars + 2;
   if(need >= nH)
      return false;
   if(hs + 1 >= ArraySize(g_hEmaFv) || hs + 1 >= ArraySize(g_hEmaSv) ||
      hs + 1 >= ArraySize(g_hAtrv)  || hs + 1 >= ArraySize(g_hAdxv))
      return false;

   double e50  = g_hEmaFv[hs+1];
   double e200 = g_hEmaSv[hs+1];
   double atrH = g_hAtrv[hs+1];
   htfAdx      = g_hAdxv[hs+1];
   bias        = Regime(e50, e200, g_hr[hs+1].close, htfAdx, atrH);

   double hi = -DBL_MAX, lo = DBL_MAX;
   for(int k = hs + 1; k <= hs + InpSRLookback; k++)
     {
      if(g_hr[k].high > hi) hi = g_hr[k].high;
      if(g_hr[k].low  < lo) lo = g_hr[k].low;
     }
   htfPD = (hi > lo ? (g_hr[hs].close - lo) / (hi - lo) : 0.5);
   htfPD = MathMax(0.0, MathMin(1.0, htfPD));
   return true;
  }

//+------------------------------------------------------------------+
//| OnCalculate                                                      |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   int minBars = InpEmaSlow + InpLegLookback + InpSwingLen * 2 + 30;
   if(rates_total < minBars + 10)
      return 0;

   ArraySetAsSeries(time,  false);
   ArraySetAsSeries(open,  false);
   ArraySetAsSeries(high,  false);
   ArraySetAsSeries(low,   false);
   ArraySetAsSeries(close, false);

   int calcFrom = minBars;
   if(InpMaxBars > 0)
      calcFrom = MathMax(calcFrom, rates_total - InpMaxBars);

   if(prev_calculated == 0 || g_lastProc < calcFrom - 1)
     {
      ArrayInitialize(BufBuy,  EMPTY_VALUE);
      ArrayInitialize(BufSell, EMPTY_VALUE);
      ArrayInitialize(BufSL,   0.0);
      ArrayInitialize(BufTP1,  0.0);
      ArrayInitialize(BufTP2,  0.0);
      ArrayInitialize(BufDir,  0.0);
      ResetAll();
      g_lastProc = calcFrom - 1;
     }

   if(!LoadSeries(rates_total, calcFrom))
      return prev_calculated;

   int start = MathMax(calcFrom, g_lastProc + 1);
   int last  = rates_total - 2;          // only fully closed bars

   for(int i = start; i < rates_total; i++)
     {
      BufBuy[i]  = EMPTY_VALUE;
      BufSell[i] = EMPTY_VALUE;
      BufSL[i]   = 0.0;
      BufTP1[i]  = 0.0;
      BufTP2[i]  = 0.0;
      BufDir[i]  = 0.0;
     }

   for(int i = start; i <= last; i++)
     {
      g_lastProc = i;

      double atr = SV(g_atrv, rates_total, i);
      if(atr <= 0.0)
         continue;

      //--- 1. maintain lower timeframe swing structure -------------
      int L = MathMax(1, InpSwingLen);
      int s = i - L;
      if(s - L >= 0)
        {
         bool isHigh = true, isLow = true;
         for(int k = s - L; k <= s + L; k++)
           {
            if(k == s)
               continue;
            if(high[k] >= high[s]) isHigh = false;
            if(low[k]  <= low[s])  isLow  = false;
           }
         if(isHigh) { g_swHigh = high[s]; g_swHighBar = s; }
         if(isLow)  { g_swLow  = low[s];  g_swLowBar  = s; }
        }

      //--- 2. higher timeframe context ------------------------------
      int hs = 0, bias = REG_RANGE;
      double htfPD = 0.5, htfAdx = 0.0;
      if(!HtfContext(time[i], hs, bias, htfPD, htfAdx))
         continue;

      //--- 3. CRT on the anchor timeframe ---------------------------
      CRTInfo crt;
      bool haveCrt = FindCRT(hs, bias, crt);

      if(!haveCrt)
        {
         ResetSetup();
         continue;
        }

      if(crt.raidTime != g_stRaid || crt.dir != g_stDir)
        {
         ResetSetup();
         g_stRaid  = crt.raidTime;
         g_stDir   = crt.dir;
         g_stCrtHi = crt.hi;
         g_stCrtLo = crt.lo;
        }

      double crtRng = g_stCrtHi - g_stCrtLo;
      if(crtRng <= 0.0)
         continue;

      //--- 4. market structure shift on the signal timeframe --------
      if(!g_stMss)
        {
         if(g_stDir > 0 && g_swHighBar > 0 && g_swHighBar < i && g_swHigh > 0.0)
           {
            double legLow = LowestOf(low, i - InpLegLookback + 1, i, rates_total);
            bool disp = (close[i] - legLow) >= InpDispATR * atr;
            if(close[i] > g_swHigh && disp)
              {
               g_stMss    = true;
               g_stMssLvl = g_swHigh;
               g_stMssBar = i;
               g_stZone   = BuildBullZone(open, high, low, close, i, rates_total, atr,
                                          g_stZoneHi, g_stZoneLo, g_stZoneKind);
              }
           }
         else
            if(g_stDir < 0 && g_swLowBar > 0 && g_swLowBar < i && g_swLow > 0.0)
              {
               double legHigh = HighestOf(high, i - InpLegLookback + 1, i, rates_total);
               bool disp = (legHigh - close[i]) >= InpDispATR * atr;
               if(close[i] < g_swLow && disp)
                 {
                  g_stMss    = true;
                  g_stMssLvl = g_swLow;
                  g_stMssBar = i;
                  g_stZone   = BuildBearZone(open, high, low, close, i, rates_total, atr,
                                             g_stZoneHi, g_stZoneLo, g_stZoneKind);
                 }
              }
         continue;                       // never enter on the MSS bar itself
        }

      if(!g_stZone)
        {
         ResetSetup();
         continue;
        }

      //--- 5. setup housekeeping ------------------------------------
      if(i - g_stMssBar > InpSetupExpiry)
        {
         ResetSetup();
         continue;
        }
      if(g_stDir > 0 && close[i] < g_stZoneLo - InpInvalidATR * atr)
        {
         ResetSetup();
         continue;
        }
      if(g_stDir < 0 && close[i] > g_stZoneHi + InpInvalidATR * atr)
        {
         ResetSetup();
         continue;
        }

      //--- 6. gates --------------------------------------------------
      double pd = (close[i] - g_stCrtLo) / crtRng;
      pd = MathMax(-0.5, MathMin(1.5, pd));

      double emaF = SV(g_emaFv, rates_total, i);
      double emaS = SV(g_emaSv, rates_total, i);
      double adx  = SV(g_adxv,  rates_total, i);
      int ltfReg  = Regime(emaF, emaS, close[i], adx, atr);

      if(InpBlockInRange && bias == REG_RANGE)
         continue;

      bool wantBuy  = (g_stDir > 0);
      bool wantSell = (g_stDir < 0);

      if(wantBuy  && bias != REG_BULL) continue;
      if(wantSell && bias != REG_BEAR) continue;

      if(wantBuy  && pd > InpMaxBuyPD)  continue;
      if(wantSell && pd < InpMinSellPD) continue;

      if(InpUseHtfPD)
        {
         if(wantBuy  && htfPD > InpHtfMaxBuyPD)  continue;
         if(wantSell && htfPD < InpHtfMinSellPD) continue;
        }

      if(InpEmaFilter == EMAF_SOFT)
        {
         if(wantBuy  && close[i] < emaF) continue;
         if(wantSell && close[i] > emaF) continue;
        }
      else
         if(InpEmaFilter == EMAF_STRICT)
           {
            if(wantBuy  && !(emaF > emaS && close[i] > emaF)) continue;
            if(wantSell && !(emaF < emaS && close[i] < emaF)) continue;
           }

      if(i - g_lastSigBar < InpCooldownBars)
         continue;

      //--- 7. retest of the zone + candlestick confirmation ---------
      bool tapped = false;
      if(wantBuy)
         tapped = (low[i] <= g_stZoneHi && close[i] > g_stZoneLo);
      else
         tapped = (high[i] >= g_stZoneLo && close[i] < g_stZoneHi);
      if(!tapped)
         continue;

      string pat = (wantBuy ? BullishPattern(open, high, low, close, i, atr)
                    : BearishPattern(open, high, low, close, i, atr));
      if(InpRequirePattern && pat == "")
         continue;
      if(pat == "")
         pat = (wantBuy ? "Zone Tap" : "Zone Tap");

      //--- 8. stop loss and targets ---------------------------------
      double entry = close[i], sl = 0.0, tp1 = 0.0, tp2 = 0.0;

      if(wantBuy)
        {
         double structLow = LowestOf(low, i - InpSlLookback + 1, i, rates_total);
         sl = MathMin(structLow, g_stZoneLo) - InpSlBufATR * atr;
        }
      else
        {
         double structHigh = HighestOf(high, i - InpSlLookback + 1, i, rates_total);
         sl = MathMax(structHigh, g_stZoneHi) + InpSlBufATR * atr;
        }

      double risk = MathAbs(entry - sl);
      if(risk <= 0.0)
         continue;
      if(InpMaxRiskATR > 0.0 && risk > InpMaxRiskATR * atr)
         continue;

      if(wantBuy)
        {
         tp1 = entry + risk * InpRR1;
         tp2 = entry + risk * InpRR2;
         if(InpUseLiquidityTP)
           {
            double liq = MathMax(g_stCrtHi, HighestOf(high, i - InpLiqLookback + 1, i, rates_total));
            if(liq > tp1)
               tp2 = liq;
           }
        }
      else
        {
         tp1 = entry - risk * InpRR1;
         tp2 = entry - risk * InpRR2;
         if(InpUseLiquidityTP)
           {
            double liq = MathMin(g_stCrtLo, LowestOf(low, i - InpLiqLookback + 1, i, rates_total));
            if(liq < tp1)
               tp2 = liq;
           }
        }

      //--- 9. print the signal --------------------------------------
      double off = InpDotOffsetATR * atr;
      if(wantBuy)
         BufBuy[i] = low[i] - off;
      else
         BufSell[i] = high[i] + off;

      BufSL[i]  = sl;
      BufTP1[i] = tp1;
      BufTP2[i] = tp2;
      BufDir[i] = (wantBuy ? 1.0 : -1.0);

      PushSignal(time[i], (wantBuy ? 1 : -1), entry, sl, tp1, tp2, pat);
      g_lastSigBar = i;

      if(i == rates_total - 2)
         FireAlert(time[i], (wantBuy ? 1 : -1), entry, sl, tp1, tp2, pat);

      if(!InpMultiEntry)
        {
         datetime keepRaid = g_stRaid;
         int      keepDir  = g_stDir;
         double   keepHi   = g_stCrtHi, keepLo = g_stCrtLo;
         ResetSetup();
         g_stRaid  = keepRaid;           // same CRT stays active, hunt a fresh MSS
         g_stDir   = keepDir;
         g_stCrtHi = keepHi;
         g_stCrtLo = keepLo;
        }
     }

   //--- dashboard snapshot from the last closed bar -----------------
   int snap = rates_total - 2;
   if(snap >= calcFrom)
     {
      double atrS = SV(g_atrv, rates_total, snap);
      double emaF = SV(g_emaFv, rates_total, snap);
      double emaS = SV(g_emaSv, rates_total, snap);
      double adxS = SV(g_adxv,  rates_total, snap);

      int hs = 0, bias = REG_RANGE;
      double htfPD = 0.5, htfAdx = 0.0;

      g_dAtr    = atrS;
      g_dLtfReg = Regime(emaF, emaS, close[snap], adxS, atrS);
      g_dLtfAdx = adxS;

      if(HtfContext(time[snap], hs, bias, htfPD, htfAdx))
        {
         g_dHtfReg = bias;
         g_dHtfAdx = htfAdx;
         g_dHtfPD  = htfPD;

         CRTInfo crt;
         g_dCrt = FindCRT(hs, bias, crt);
         if(g_dCrt)
           {
            g_dCrtDir = crt.dir;
            g_dCrtHi  = crt.hi;
            g_dCrtLo  = crt.lo;
            double rr = crt.hi - crt.lo;
            g_dPD = (rr > 0.0 ? (close[snap] - crt.lo) / rr : 0.5);
            g_dPD = MathMax(0.0, MathMin(1.0, g_dPD));
           }
        }

      if(!g_dCrt)                       g_dPhase = "waiting for a CRT raid";
      else if(!g_stMss)                 g_dPhase = "raid confirmed - waiting MSS";
      else if(g_stZone)                 g_dPhase = "MSS ok - waiting retest (" + g_stZoneKind + ")";
      else                              g_dPhase = "MSS ok - no valid zone";
     }

   DrawSignalLevels(prev_calculated == 0);
   DrawCrtBox();
   DrawPanel();
   ChartRedraw();

   return rates_total;
  }
//+------------------------------------------------------------------+
