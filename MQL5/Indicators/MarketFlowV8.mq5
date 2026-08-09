//+------------------------------------------------------------------+
//|                                                 MarketFlowV8.mq5 |
//|        Top-down SMC scanner: D1 + H4 bias -> entry timeframe setup |
//+------------------------------------------------------------------+
//| Read top-down, exactly the way the setup is meant to be built:     |
//|                                                                    |
//|  1. DAILY  bias   - market structure (BOS / CHoCH) on D1           |
//|  2. H4     bias   - market structure on H4                         |
//|  3. entry TF      - only setups pointing the same way as the bias  |
//|       . liquidity sweep of a prior swing (stops taken)             |
//|       . CHoCH / BOS with displacement (intent)                     |
//|       . POI to enter from: order block and/or fair value gap       |
//|       . premium / discount check against the dealing range         |
//|  4. entry is a LIMIT at the POI, not a market chase - the setup    |
//|     waits for price to come back to it (WAITING -> ACTIVE)         |
//|  5. targets are resting liquidity (prior swing highs / lows), with |
//|     R multiples only as a fallback when no liquidity is in range   |
//|                                                                    |
//| Nothing is printed that the data does not support: rows say        |
//| LOADING until history is really there, levels are tick-normalised  |
//| and stop-level aware, STATUS replays what the trade actually did,  |
//| and WR back-tests this identical rule and shows its sample size.   |
//+------------------------------------------------------------------+
#property copyright "MarketFlow"
#property version   "8.20"
#property description "MarketFlow V8 - D1/H4 bias + SMC (sweep, CHoCH/BOS, order block, FVG,"
#property description "premium/discount) scanner over the whole Market Watch, with liquidity"
#property description "based targets, live trade status and a measured hit rate per symbol."
#property indicator_separate_window
#property indicator_buffers 0
#property indicator_plots   0
#property indicator_height  200
#property indicator_minimum 0.0
#property indicator_maximum 1.0

//+------------------------------------------------------------------+
//| Enums                                                            |
//+------------------------------------------------------------------+
enum ENUM_MF_BIAS
{
   MF_BIAS_BOTH   = 0,  // D1 and H4 must both agree
   MF_BIAS_H4LED  = 1,  // H4 must agree, D1 must not oppose
   MF_BIAS_ANY    = 2   // either one agrees
};

enum ENUM_MF_POI
{
   MF_POI_CE      = 0,  // Consequent encroachment (zone midpoint)
   MF_POI_PROXIMAL= 1   // Proximal edge (first touch)
};

enum ENUM_MF_RECYCLE
{
   MF_RECYCLE_TP1 = 0,  // free the pair once the setup reaches TP1 (or SL)
   MF_RECYCLE_TP2 = 1,  // ...TP2
   MF_RECYCLE_TP3 = 2   // ...TP3
};

enum ENUM_MF_AGE
{
   MF_AGE_BARS  = 0,    // "3 bars ago" / "current"
   MF_AGE_CLOCK = 1     // "1h 05m ago"
};

enum ENUM_MF_SORT
{
   MF_SORT_LIST   = 0,  // Market Watch order
   MF_SORT_FRESH  = 1,  // Signals first, freshest, then score
   MF_SORT_SCORE  = 2   // Signals first, highest score
};

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Universe ==="
input bool            InpUseMarketWatch = true;  // Scan every symbol in Market Watch
input string          InpSymbols        = "";    // Manual list (used when Market Watch is off)
input string          InpFilterInclude  = "";    // Only symbols containing this text
input string          InpFilterExclude  = "";    // Skip symbols containing this text
input bool            InpSkipUntradable = true;  // Skip symbols with trading disabled
input int             InpMaxSymbols     = 0;     // Cap on scanned symbols (0 = every Market Watch symbol)
input int             InpSymbolsPerTick = 10;    // Symbols analysed per second once warm
input int             InpWarmupPerTick  = 60;    // Symbols analysed per second during first fill
input int             InpBiasBars       = 260;   // Bars fetched per bias timeframe
input int             InpMaxTries       = 25;    // Attempts before a symbol stops holding up the warm-up

input group "=== Timeframes ==="
input ENUM_TIMEFRAMES InpTimeframe      = PERIOD_CURRENT; // Entry timeframe
input bool            InpBiasAuto       = true;          // Bias follows the chart (1 and 2 steps up)
input ENUM_TIMEFRAMES InpBiasTF1        = PERIOD_D1;      // Higher bias TF (when auto is off)
input ENUM_TIMEFRAMES InpBiasTF2        = PERIOD_H4;      // Nearer bias TF (when auto is off)
input ENUM_MF_BIAS    InpBiasMode       = MF_BIAS_H4LED;  // How strict the bias must be

input group "=== Market structure (SMC) ==="
input int             InpSwingStrength  = 2;     // Fractal strength (bars each side)
input int             InpSweepWindow    = 6;     // Sweep must be within N bars of the shift
input int             InpSweepLookback  = 20;    // Liquidity pool lookback for the sweep
input bool            InpRequireSweep   = false; // Force a liquidity sweep on every setup
input double          InpDispAtrMult    = 1.0;   // Displacement body >= ATR x
input bool            InpRequireDisp    = false; // Force displacement on every setup
input bool            InpRequireBothLegs= false; // Demand SMC *and* EMA/RSI, not either
input int             InpPoiLookback    = 10;    // Bars back to find the OB / FVG
input ENUM_MF_POI     InpPoiEntry       = MF_POI_CE; // Where in the zone to enter
input bool            InpRequirePD      = true;  // HARD: no buys in premium, no sells in discount
input bool            InpPdUseBiasRange = false; // Measure premium/discount on the bias timeframe range
input double          InpPdMaxPct       = 0.50;  // Buy must sit in the lowest x of the range (0.40 = deeper)

input group "=== Trend filter (EMA + RSI) ==="
input bool            InpUseEmaFilter   = true;  // EMA trend must agree with the setup
input int             InpEmaFast        = 21;    // Fast EMA
input int             InpEmaSlow        = 50;    // Slow EMA
input bool            InpUseRsiFilter   = true;  // RSI must not be exhausted against the setup
input int             InpRsiPeriod      = 14;    // RSI period
input double          InpRsiMaxBuy      = 75.0;  // Never buy a continuation above this RSI
input double          InpRsiMinSell     = 25.0;  // Never sell a continuation below this RSI
input double          InpRsiRevBuy      = 45.0;  // Reversal buy needs RSI at or below this
input double          InpRsiRevSell     = 55.0;  // Reversal sell needs RSI at or above this

input group "=== Quality gates ==="
input double          InpMaxRiskAtr     = 4.0;   // Reject setups whose stop is wider than ATR x
input double          InpMaxZoneAtr     = 2.5;   // Reject POI zones wider than ATR x
input bool            InpHideFinished   = true;  // Drop a finished setup instead of leaving it on the board
input ENUM_MF_RECYCLE InpRecycleAt      = MF_RECYCLE_TP3; // When a pair may produce its next setup
input int             InpMaxHoldBars    = 500;   // Safety cap on how long a FILLED trade is tracked

input group "=== Signal selection ==="
input int             InpMaxAge         = 25;    // Bars an UNFILLED limit waits before it is dropped
input int             InpMinScore       = 65;    // Minimum confluence score (0-100)
input bool            InpOnlySignals    = false; // Show only symbols with a live setup
input bool            InpShowOnlyAnalysed= true; // A pair appears only once it has been analysed
input ENUM_MF_SORT    InpSortMode       = MF_SORT_FRESH; // Row order
input ENUM_MF_AGE     InpAgeMode        = MF_AGE_BARS;   // How AGE is displayed

input group "=== Risk and targets ==="
input int             InpAtrPeriod      = 14;    // ATR period
input double          InpMinRiskAtr     = 0.5;   // Minimum stop distance in ATR
input double          InpSlBufferAtr    = 0.15;  // Extra stop buffer in ATR
input double          InpMinTp1R        = 1.0;   // TP1 must be at least this many R away
input int             InpLiquidityLook  = 150;   // Bars searched for target liquidity
input double          InpTP1R           = 1.5;   // TP1 fallback (R multiple)
input double          InpTP2R           = 2.5;   // TP2 fallback (R multiple)
input double          InpTP3R           = 4.0;   // TP3 fallback (R multiple)

input group "=== Measured hit rate ==="
input int             InpStatsBars      = 600;   // Back-test window in bars (0 = off)
input int             InpStatsMaxHold   = 60;    // Bars a back-tested setup may stay open
input int             InpStatsMinSamples= 8;     // Below this sample size WR shows n/a

input group "=== Panel ==="
input int             InpPanelX         = 6;     // Panel X (px from left)
input int             InpPanelY         = 6;     // Panel Y (px from bottom)
input int             InpRowsVisible    = 9;     // Visible rows
input int             InpRowHeight      = 18;    // Row height (px)
input string          InpFont           = "Consolas"; // Font
input int             InpFontSize       = 8;     // Font size
input bool            InpShowBias       = false; // Show the BIAS column
input bool            InpShowSmc        = false; // Show the SMC confluence column
input bool            InpShowScore      = false; // Show the SCORE column
input bool            InpShowWinRate    = false; // Show the WR column
input bool            InpShowStatus     = false; // Show the STATUS column

input group "=== Chart drawing ==="
input bool            InpShowChartTrade = true;  // Draw the chart symbol's setup
input bool            InpShowSmcMarkup  = false; // Draw the SMC markup (POI zone, sweep line, BOS/CHoCH tag)
input bool            InpShowWatermark  = true;  // Draw the symbol/timeframe watermark
input bool            InpWatermarkTint  = true;  // Tint the watermark with the signal direction
input bool            InpShowTradeDetail= false; // Extra legend line (bias, score, R:R, hit rate)
input int             InpBoxExtendBars  = 6;     // Extend the trade box N bars past the last bar

input group "=== Colors ==="
input color           InpClrPanelBg     = C'8,10,24';    // Panel background
input color           InpClrPanelBorder = C'70,55,130';   // Panel border
input color           InpClrRowA        = C'14,16,34';    // Row background A
input color           InpClrRowB        = C'20,22,46';    // Row background B
input color           InpClrRowActive   = C'46,36,96';    // Row background of the charted symbol
input color           InpClrTitle       = C'200,190,255'; // Title text
input color           InpClrHeader      = C'140,125,205'; // Column header text
input color           InpClrText        = C'210,210,228'; // Row text
input color           InpClrDim         = C'108,108,134'; // Dimmed text
input color           InpClrBuy         = C'0,214,140';   // Buy color
input color           InpClrSell        = C'236,72,112';  // Sell color
input color           InpClrEntryLine   = C'160,45,60';   // Entry line color
input color           InpClrWatermark   = C'190,185,200'; // Watermark color (when not tinted)
input color           InpClrOpen        = C'150,170,255'; // "OPEN" button text

input group "=== Alerts ==="
input bool            InpAlertPopup     = true;  // Popup when price reaches the entry
input bool            InpAlertPush      = false; // Push notification when price reaches the entry
input bool            InpAlertSound     = true;  // Play a sound with the entry alert
input int             InpAlertMinScore  = 75;    // Only alert setups scoring at least this
input int             InpAlertMaxScore  = 100;   // ...and at most this
input bool            InpAlertOnForming = false; // Extra heads-up when the setup first appears

input group "=== Diagnostics ==="
input bool            InpLogRejects     = false; // Log why setups are being rejected (Experts tab)
input int             InpLogSeconds     = 30;    // How often to print the tally

//+------------------------------------------------------------------+
//| Status codes                                                     |
//+------------------------------------------------------------------+
#define ST_INVALID -2   // stop taken out before price ever reached the entry
#define ST_SL      -1
#define ST_WAIT     0   // limit not filled yet
#define ST_ACTIVE   1
#define ST_TP1      2
#define ST_TP2      3
#define ST_TP3      4

//+------------------------------------------------------------------+
//| Types                                                            |
//+------------------------------------------------------------------+
struct MFPoi
{
   bool     valid;
   double   hi;
   double   lo;
   bool     isOB;
   bool     isFVG;
   datetime time;
};

struct MFSignal
{
   bool     valid;
   int      dir;            // +1 buy, -1 sell
   bool     choch;          // true CHoCH (reversal), false BOS (continuation)
   int      barIndex;       // shift of the structure-shift bar
   datetime time;
   double   entry;
   double   sl;
   double   tp1;
   double   tp2;
   double   tp3;
   double   zoneHi;
   double   zoneLo;
   double   sweepPrice;     // 0 when no sweep
   int      biasD1;
   int      biasH4;
   bool     hasOB;
   bool     hasFVG;
   bool     hasSweep;
   bool     pdOk;
   bool     displaced;
   bool     liquidityTp;    // targets came from real liquidity, not R fallback
   int      score;
   string   grade;          // A+ both legs, A smc leg, B trend leg
   bool     adjusted;       // levels widened for the broker stop level
   int      status;
   string   tags;
};

struct MFSymbol
{
   string   name;
   bool     ok;
   bool     analysed;
   int      digits;
   double   point;
   double   tickSize;
   double   stopDist;
   datetime lastBar;
   datetime curBar;         // newest bar time, refreshed every cycle
   int      statWins;
   int      statLosses;
   int      tries;           // consecutive analyses that found no usable history
   datetime lastAlert;       // heads-up already sent for this setup
   datetime alertedEntry;    // entry alert already sent for this setup
   int      scoutDir;        // directional read when there is no tradable setup
   int      scoutScore;
   int      scoutB1;
   int      scoutB2;
   string   scoutWhy;        // why this pair has no setup right now
   string   note;
   MFSignal sig;
};

//--- working set for one symbol; holds dynamic arrays so it is only ever
//--- passed by reference, never copied
struct MFCtx
{
   int      n;
   MqlRates r[];
   double   atr[];
   double   emaF[];
   double   emaS[];
   double   rsi[];
   int      bias[];
   int      evDir[];
   int      evChoch[];
   double   rHigh[];
   double   rLow[];

   int      n1;             // bias timeframe 1 (daily by default)
   MqlRates r1[];
   int      bias1[];
   double   rHigh1[];
   double   rLow1[];
   int      idx1[];

   int      n2;             // bias timeframe 2 (H4 by default)
   MqlRates r2[];
   int      bias2[];
   double   rHigh2[];
   double   rLow2[];
   int      idx2[];
};

//+------------------------------------------------------------------+
//| Column layout                                                    |
//+------------------------------------------------------------------+
#define NCOLS 15
#define C_SYMBOL 0
#define C_TF     1
#define C_BIAS   2
#define C_SIGNAL 3
#define C_SMC    4
#define C_SCORE  5
#define C_WR     6
#define C_AGE    7
#define C_ENTRY  8
#define C_SL     9
#define C_TP1    10
#define C_TP2    11
#define C_TP3    12
#define C_STATUS 13
#define C_CHART  14

const string g_colTitle[NCOLS] = {"SYMBOL","TF","BIAS","SIGNAL","SMC","SCORE","WR","AGE","ENTRY","SL","TP1","TP2","TP3","STATUS","CHART"};
const int    g_colWidth[NCOLS] = { 210,    46,  86,    78,      132,  50,     72,  88,   100,    96,  96,   96,   96,   76,      60 };

bool  g_colOn[NCOLS];
int   g_colX[NCOLS];
int   g_panelW = 900;

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
//--- why the last evaluation failed, kept so a pair with no setup can say so
int               g_rejStage = 0;
string            g_rejWhy   = "";

bool Reject(const int stage, const string why)
{
   if(stage > g_rejStage)
   {
      g_rejStage = stage;
      g_rejWhy   = why;
   }
   return false;
}

const string      g_prefix  = "MFV8_";
const int         g_titleH  = 24;
const int         g_headerH = 20;

int               g_win     = -1;  // sub-window this indicator occupies (-1 = not resolved)
int               g_objWin   = 0;  // window new objects are created in
bool              g_tradeDrawn = false;  // are the price-chart trade objects up?

MFSymbol          g_syms[];
int               g_order[];
int               g_cursor  = 0;
int               g_scroll  = 0;
ENUM_TIMEFRAMES   g_tf      = PERIOD_M15;
ENUM_TIMEFRAMES   g_bias1   = PERIOD_D1;
ENUM_TIMEFRAMES   g_bias2   = PERIOD_H4;
bool              g_use1    = true;
bool              g_use2    = true;
string            g_tfText  = "";
string            g_b1Text  = "D1";
string            g_b2Text  = "H4";
datetime          g_lastUniverse = 0;
datetime          g_lastLog      = 0;

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
string TfToText(const ENUM_TIMEFRAMES tf)
{
   string s = EnumToString(tf);
   int p = StringFind(s, "_");
   return (p >= 0 ? StringSubstr(s, p + 1) : s);
}

//--- one step up the timeframe ladder, used when the bias follows the chart
ENUM_TIMEFRAMES NextTimeframeUp(const ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M1:  return PERIOD_M5;
      case PERIOD_M2:  return PERIOD_M10;
      case PERIOD_M3:  return PERIOD_M15;
      case PERIOD_M4:  return PERIOD_M20;
      case PERIOD_M5:  return PERIOD_M30;
      case PERIOD_M6:  return PERIOD_M30;
      case PERIOD_M10: return PERIOD_H1;
      case PERIOD_M12: return PERIOD_H1;
      case PERIOD_M15: return PERIOD_H1;
      case PERIOD_M20: return PERIOD_H2;
      case PERIOD_M30: return PERIOD_H4;
      case PERIOD_H1:  return PERIOD_H4;
      case PERIOD_H2:  return PERIOD_H8;
      case PERIOD_H3:  return PERIOD_H12;
      case PERIOD_H4:  return PERIOD_D1;
      case PERIOD_H6:  return PERIOD_D1;
      case PERIOD_H8:  return PERIOD_D1;
      case PERIOD_H12: return PERIOD_D1;
      case PERIOD_D1:  return PERIOD_W1;
      case PERIOD_W1:  return PERIOD_MN1;
      default:         return PERIOD_MN1;
   }
}

string ArrowFor(const int dir)
{
   if(dir > 0) return ShortToString(0x25B2);
   if(dir < 0) return ShortToString(0x25BC);
   return "-";
}

int PanelHeight()
{
   return g_titleH + g_headerH + InpRowsVisible * InpRowHeight + 6;
}

int RowBaseline(const int i)
{
   return InpPanelY + 3 + (InpRowsVisible - 1 - i) * InpRowHeight + 4;
}

//+------------------------------------------------------------------+
//| Object helpers                                                   |
//+------------------------------------------------------------------+
//--- objects are created in g_objWin: the sub-window for the dashboard, window 0
//--- for everything drawn on the price chart
bool EnsureObject(const string name, const ENUM_OBJECT type)
{
   if(ObjectFind(0, name) >= 0)
      return true;
   if(!ObjectCreate(0, name, type, g_objWin, 0, 0))
      return false;
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTED,   false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
   return true;
}

void ObjShow(const string name, const bool show)
{
   if(ObjectFind(0, name) < 0)
      return;
   ObjectSetInteger(0, name, OBJPROP_TIMEFRAMES, show ? OBJ_ALL_PERIODS : OBJ_NO_PERIODS);
}

void SetLabel(const string name, const int x, const int y, const string text,
              const color clr, const int fontSize,
              const ENUM_BASE_CORNER corner = CORNER_LEFT_LOWER,
              const ENUM_ANCHOR_POINT anchor = ANCHOR_LEFT_LOWER)
{
   if(!EnsureObject(name, OBJ_LABEL))
      return;
   ObjectSetInteger(0, name, OBJPROP_CORNER,    corner);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR,    anchor);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  fontSize);
   ObjectSetInteger(0, name, OBJPROP_ZORDER,    10);
   ObjectSetString (0, name, OBJPROP_FONT,      InpFont);
   ObjectSetString (0, name, OBJPROP_TEXT,      text);
   ObjShow(name, true);
}

void SetRect(const string name, const int x, const int y, const int w, const int h,
             const color bg, const color border)
{
   if(!EnsureObject(name, OBJ_RECTANGLE_LABEL))
      return;
   ObjectSetInteger(0, name, OBJPROP_CORNER,      CORNER_LEFT_LOWER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,   x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,   y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE,       w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE,       h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR,     bg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_COLOR,       border);
   ObjectSetInteger(0, name, OBJPROP_BACK,        false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER,      0);
   ObjShow(name, true);
}

void SetButton(const string name, const int x, const int y, const int w, const int h,
               const string text, const color bg, const color txt)
{
   if(!EnsureObject(name, OBJ_BUTTON))
      return;
   ObjectSetInteger(0, name, OBJPROP_CORNER,       CORNER_LEFT_LOWER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,    x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,    y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE,        w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE,        h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR,      bg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, InpClrPanelBorder);
   ObjectSetInteger(0, name, OBJPROP_COLOR,        txt);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,     InpFontSize);
   ObjectSetInteger(0, name, OBJPROP_STATE,        false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER,       20);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,       true);
   ObjectSetString (0, name, OBJPROP_FONT,         InpFont);
   ObjectSetString (0, name, OBJPROP_TEXT,         text);
   ObjShow(name, true);
}

//+------------------------------------------------------------------+
//| Universe                                                         |
//+------------------------------------------------------------------+
bool PassesFilter(const string sym)
{
   if(InpFilterInclude != "" && StringFind(sym, InpFilterInclude) < 0)
      return false;
   if(InpFilterExclude != "" && StringFind(sym, InpFilterExclude) >= 0)
      return false;
   return true;
}

void CollectNames(string &names[])
{
   ArrayResize(names, 0);

   if(InpUseMarketWatch)
   {
      int total = SymbolsTotal(true);
      for(int i = 0; i < total; i++)
      {
         string s = SymbolName(i, true);
         if(s == "" || !PassesFilter(s))
            continue;
         int k = ArraySize(names);
         ArrayResize(names, k + 1);
         names[k] = s;
      }
   }
   else
   {
      string parts[];
      int n = StringSplit(InpSymbols, StringGetCharacter(",", 0), parts);
      for(int i = 0; i < n; i++)
      {
         string s = parts[i];
         StringTrimLeft(s);
         StringTrimRight(s);
         if(s == "" || !PassesFilter(s))
            continue;
         int k = ArraySize(names);
         ArrayResize(names, k + 1);
         names[k] = s;
      }
   }

   if(ArraySize(names) == 0)
   {
      ArrayResize(names, 1);
      names[0] = _Symbol;
   }
   if(InpMaxSymbols > 0 && ArraySize(names) > InpMaxSymbols)
      ArrayResize(names, InpMaxSymbols);
}

void BuildUniverse()
{
   string names[];
   CollectNames(names);

   if(ArraySize(names) == ArraySize(g_syms))
   {
      bool same = true;
      for(int i = 0; i < ArraySize(names); i++)
         if(names[i] != g_syms[i].name)
         {
            same = false;
            break;
         }
      if(same)
         return;
   }

   MFSymbol old[];
   ArrayResize(old, ArraySize(g_syms));
   for(int i = 0; i < ArraySize(g_syms); i++)
      old[i] = g_syms[i];

   ArrayResize(g_syms, ArraySize(names));
   for(int i = 0; i < ArraySize(names); i++)
   {
      MFSymbol r;
      r.name       = names[i];
      r.analysed   = false;
      r.lastBar    = 0;
      r.curBar     = 0;
      r.statWins   = 0;
      r.statLosses = 0;
      r.tries        = 0;
      r.lastAlert    = 0;
      r.alertedEntry = 0;
      r.scoutDir     = 0;
      r.scoutScore   = 0;
      r.scoutB1      = 0;
      r.scoutB2      = 0;
      r.scoutWhy     = "";
      r.note         = "LOADING";
      r.sig.valid  = false;
      r.sig.status = ST_WAIT;
      r.sig.tags   = "";
      r.sig.grade  = "";

      r.ok = SymbolSelect(names[i], true);
      if(r.ok && InpSkipUntradable &&
         SymbolInfoInteger(names[i], SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
      {
         r.ok   = false;
         r.note = "DISABLED";
      }

      r.digits   = r.ok ? (int)SymbolInfoInteger(names[i], SYMBOL_DIGITS) : _Digits;
      r.point    = r.ok ? SymbolInfoDouble(names[i], SYMBOL_POINT) : _Point;
      r.tickSize = r.ok ? SymbolInfoDouble(names[i], SYMBOL_TRADE_TICK_SIZE) : r.point;
      if(r.tickSize <= 0.0)
         r.tickSize = r.point;
      r.stopDist = r.ok ? (double)SymbolInfoInteger(names[i], SYMBOL_TRADE_STOPS_LEVEL) * r.point : 0.0;

      for(int j = 0; j < ArraySize(old); j++)
         if(old[j].name == r.name && old[j].analysed)
         {
            r.analysed   = old[j].analysed;
            r.lastBar    = old[j].lastBar;
            r.statWins   = old[j].statWins;
            r.statLosses = old[j].statLosses;
            r.tries        = old[j].tries;
            r.lastAlert    = old[j].lastAlert;
            r.alertedEntry = old[j].alertedEntry;
            r.scoutDir     = old[j].scoutDir;
            r.scoutScore   = old[j].scoutScore;
            r.scoutB1      = old[j].scoutB1;
            r.scoutB2      = old[j].scoutB2;
            r.scoutWhy     = old[j].scoutWhy;
            r.note       = old[j].note;
            r.sig        = old[j].sig;
            break;
         }

      g_syms[i] = r;
   }

   g_cursor = 0;
   g_scroll = 0;
}

//+------------------------------------------------------------------+
//| ATR (Wilder), computed inline so the scanner is not limited by    |
//| the terminal's per-chart indicator handle count                   |
//| Arrays are series ordered: index 0 = newest bar                   |
//+------------------------------------------------------------------+
void CalcATR(const MqlRates &r[], const int n, const int period, double &out[])
{
   ArrayResize(out, n);
   if(n <= 0)
      return;
   double p = (double)period;
   out[n - 1] = r[n - 1].high - r[n - 1].low;
   for(int i = n - 2; i >= 0; i--)
   {
      double pc = r[i + 1].close;
      double tr = MathMax(r[i].high - r[i].low,
                          MathMax(MathAbs(r[i].high - pc), MathAbs(r[i].low - pc)));
      out[i] = (out[i + 1] * (p - 1.0) + tr) / p;
   }
}

void CalcEMA(const MqlRates &r[], const int n, const int period, double &out[])
{
   ArrayResize(out, n);
   if(n <= 0)
      return;
   double k = 2.0 / (period + 1.0);
   out[n - 1] = r[n - 1].close;
   for(int i = n - 2; i >= 0; i--)
      out[i] = r[i].close * k + out[i + 1] * (1.0 - k);
}

void CalcRSI(const MqlRates &r[], const int n, const int period, double &out[])
{
   ArrayResize(out, n);
   if(n <= 0)
      return;
   double p  = (double)period;
   double ag = 0.0, al = 0.0;
   out[n - 1] = 50.0;
   for(int i = n - 2; i >= 0; i--)
   {
      double d = r[i].close - r[i + 1].close;
      ag = (ag * (p - 1.0) + (d > 0.0 ?  d : 0.0)) / p;
      al = (al * (p - 1.0) + (d < 0.0 ? -d : 0.0)) / p;
      out[i] = (al <= 0.0) ? 100.0 : 100.0 - 100.0 / (1.0 + ag / al);
   }
}

//+------------------------------------------------------------------+
//| Fractals                                                         |
//+------------------------------------------------------------------+
bool IsFractalHigh(const MqlRates &r[], const int n, const int j, const int s)
{
   if(j - s < 0 || j + s >= n)
      return false;
   for(int k = 1; k <= s; k++)
      if(r[j].high <= r[j - k].high || r[j].high <= r[j + k].high)
         return false;
   return true;
}

bool IsFractalLow(const MqlRates &r[], const int n, const int j, const int s)
{
   if(j - s < 0 || j + s >= n)
      return false;
   for(int k = 1; k <= s; k++)
      if(r[j].low >= r[j - k].low || r[j].low >= r[j + k].low)
         return false;
   return true;
}

//+------------------------------------------------------------------+
//| Market structure walk                                             |
//|                                                                   |
//| Produces, for every bar, the structural state AS OF THAT BAR:      |
//|   bias[i]    +1 bullish / -1 bearish / 0 undecided                 |
//|   evDir[i]   +1 / -1 when a break happened on that bar             |
//|   evChoch[i] 1 when that break flipped the state (CHoCH), else 0   |
//|   rHigh/rLow the current dealing range                             |
//|                                                                   |
//| A fractal at bar j is only used once it is confirmed, i.e. once s  |
//| newer bars exist - so nothing here can see the future.             |
//+------------------------------------------------------------------+
void StructureSeries(const MqlRates &r[], const int n, const int s,
                     int &bias[], int &evDir[], int &evChoch[],
                     double &rHigh[], double &rLow[])
{
   ArrayResize(bias,    n);
   ArrayResize(evDir,   n);
   ArrayResize(evChoch, n);
   ArrayResize(rHigh,   n);
   ArrayResize(rLow,    n);
   if(n <= 0)
      return;

   double lastH = 0.0, lastL = 0.0;
   bool   haveH = false, haveL = false;
   int    state = 0;
   int    breaks = 0;
   double rh = r[n - 1].high, rl = r[n - 1].low;

   for(int i = n - 1; i >= 0; i--)
   {
      int j = i + s;                      // fractal candidate confirmed by bar i
      if(j + s < n)
      {
         if(IsFractalHigh(r, n, j, s)) { lastH = r[j].high; haveH = true; }
         if(IsFractalLow (r, n, j, s)) { lastL = r[j].low;  haveL = true; }
      }

      int ev = 0, ch = 0;

      if(haveH && r[i].close > lastH)
      {
         ch    = (state == -1 ? 1 : 0);
         state = +1;
         ev    = +1;
         breaks++;
         if(haveL) rl = lastL;
         rh    = r[i].high;
         haveH = false;
      }
      else if(haveL && r[i].close < lastL)
      {
         ch    = (state == +1 ? 1 : 0);
         state = -1;
         ev    = -1;
         breaks++;
         if(haveH) rh = lastH;
         rl    = r[i].low;
         haveL = false;
      }
      else
      {
         if(state > 0) rh = MathMax(rh, r[i].high);
         if(state < 0) rl = MathMin(rl, r[i].low);
      }

      //--- The walk starts from an unknown state at the oldest bar in the window,
      //--- and that window slides forward by one bar each time we rescan. Until a
      //--- couple of real breaks have happened, the state carries a trace of the
      //--- seed rather than of price, and a seed-dependent signal is a signal that
      //--- can change under you. So bias is only published once price has broken
      //--- structure at least once, and events only from the second break on.
      bias[i]    = (breaks >= 1 ? state : 0);
      evDir[i]   = (breaks >= 2 ? ev : 0);
      evChoch[i] = (breaks >= 2 ? ch : 0);
      rHigh[i]   = rh;
      rLow[i]    = rl;
   }
}

//--- map every entry-TF bar to the last CLOSED bar of a higher timeframe
void MapHigher(const MqlRates &lo[], const int n, const MqlRates &hi[], const int m, int &idx[])
{
   ArrayResize(idx, n);
   if(m <= 0)
   {
      ArrayInitialize(idx, 0);
      return;
   }
   int j = m - 1;
   for(int i = n - 1; i >= 0; i--)
   {
      while(j > 0 && hi[j - 1].time <= lo[i].time)
         j--;
      idx[i] = (int)MathMin(j + 1, m - 1);
   }
}

//+------------------------------------------------------------------+
//| SMC building blocks                                              |
//+------------------------------------------------------------------+
//--- did bar k raid the liquidity resting beyond the last `look` bars
//--- and close back inside? (stop hunt / sweep)
bool SweepAt(const MqlRates &r[], const int n, const int k, const int dir, const int look)
{
   int last = MathMin(n - 1, k + look);
   if(last <= k)
      return false;

   if(dir > 0)                                   // bullish: sell-side liquidity taken
   {
      double pool = r[k + 1].low;
      for(int q = k + 1; q <= last; q++)
         pool = MathMin(pool, r[q].low);
      return (r[k].low < pool && r[k].close > pool);
   }

   double pool = r[k + 1].high;                  // bearish: buy-side liquidity taken
   for(int q = k + 1; q <= last; q++)
      pool = MathMax(pool, r[q].high);
   return (r[k].high > pool && r[k].close < pool);
}

//--- order block + fair value gap left behind by the leg that broke structure
MFPoi FindPoi(const MqlRates &r[], const int n, const int i, const int dir)
{
   MFPoi p;
   p.valid = false;
   p.isOB  = false;
   p.isFVG = false;
   p.hi    = 0.0;
   p.lo    = 0.0;
   p.time  = 0;

   int last = MathMin(n - 2, i + InpPoiLookback);

   //--- order block: last opposing candle before the impulse
   double obHi = 0.0, obLo = 0.0;
   datetime obT = 0;
   for(int k = i; k <= last; k++)
   {
      bool opposing = (dir > 0 ? r[k].close < r[k].open : r[k].close > r[k].open);
      if(opposing)
      {
         obHi = r[k].high;
         obLo = r[k].low;
         obT  = r[k].time;
         break;
      }
   }

   //--- fair value gap inside the impulse (three-candle imbalance)
   double fvHi = 0.0, fvLo = 0.0;
   datetime fvT = 0;
   for(int k = i + 1; k <= last; k++)
   {
      if(k - 1 < 0 || k + 1 >= n)
         continue;
      if(dir > 0 && r[k - 1].low > r[k + 1].high)
      {
         fvLo = r[k + 1].high;
         fvHi = r[k - 1].low;
         fvT  = r[k].time;
         break;
      }
      if(dir < 0 && r[k - 1].high < r[k + 1].low)
      {
         fvLo = r[k - 1].high;
         fvHi = r[k + 1].low;
         fvT  = r[k].time;
         break;
      }
   }

   bool hasOB  = (obHi > obLo);
   bool hasFVG = (fvHi > fvLo);

   if(hasOB && hasFVG)
   {
      //--- prefer the overlap of the two: the strongest kind of POI
      double lo = MathMax(obLo, fvLo);
      double hi = MathMin(obHi, fvHi);
      if(hi > lo)
      {
         p.valid = true; p.isOB = true; p.isFVG = true;
         p.lo = lo; p.hi = hi; p.time = (obT > fvT ? obT : fvT);
         return p;
      }
      p.valid = true; p.isOB = true; p.isFVG = true;      // both exist but disjoint
      p.lo = obLo; p.hi = obHi; p.time = obT;
      return p;
   }
   if(hasFVG)
   {
      p.valid = true; p.isFVG = true;
      p.lo = fvLo; p.hi = fvHi; p.time = fvT;
      return p;
   }
   if(hasOB)
   {
      p.valid = true; p.isOB = true;
      p.lo = obLo; p.hi = obHi; p.time = obT;
      return p;
   }
   return p;
}

//--- nearest resting liquidity (confirmed swing) beyond a price
double LiquidityAbove(const MqlRates &r[], const int n, const int i, const int s, const double from)
{
   double best = 0.0;
   int last = MathMin(n - s - 1, i + InpLiquidityLook);
   for(int k = i + s; k <= last; k++)
      if(IsFractalHigh(r, n, k, s) && r[k].high > from)
         if(best == 0.0 || r[k].high < best)
            best = r[k].high;
   return best;
}

double LiquidityBelow(const MqlRates &r[], const int n, const int i, const int s, const double from)
{
   double best = 0.0;
   int last = MathMin(n - s - 1, i + InpLiquidityLook);
   for(int k = i + s; k <= last; k++)
      if(IsFractalLow(r, n, k, s) && r[k].low < from)
         if(best == 0.0 || r[k].low > best)
            best = r[k].low;
   return best;
}

//+------------------------------------------------------------------+
//| Price normalisation against the real symbol specification        |
//+------------------------------------------------------------------+
double NormPrice(const MFSymbol &s, const double p)
{
   double v = p;
   if(s.tickSize > 0.0)
      v = MathRound(v / s.tickSize) * s.tickSize;
   return NormalizeDouble(v, s.digits);
}

//+------------------------------------------------------------------+
//| Full evaluation at bar i - the single source of truth, called by  |
//| the live scan and by the back-test alike                          |
//+------------------------------------------------------------------+
bool EvaluateAt(const MFSymbol &s, MFCtx &c, const int i, MFSignal &out)
{
   out.valid = false;

   int n = c.n;
   if(i < 1 || i + 2 >= n)
      return Reject(1, "no bars");

   //--- 1. a structure shift has to happen on this bar
   int dir = c.evDir[i];
   if(dir == 0)
      return Reject(1, "no shift");
   if(c.atr[i] <= 0.0)
      return Reject(1, "no ATR");

   bool choch = (c.evChoch[i] != 0);

   //--- 2. higher timeframe bias, read from the last CLOSED bias bar
   int b1 = 0, b2 = 0;
   if(g_use1 && c.n1 > 0) b1 = c.bias1[c.idx1[i]];
   if(g_use2 && c.n2 > 0) b2 = c.bias2[c.idx2[i]];

   bool agree1 = (b1 == dir);
   bool agree2 = (b2 == dir);

   if(InpBiasMode == MF_BIAS_BOTH)
   {
      if(g_use1 && !agree1) return Reject(2, "bias " + g_b1Text);
      if(g_use2 && !agree2) return Reject(2, "bias " + g_b2Text);
   }
   else if(InpBiasMode == MF_BIAS_H4LED)
   {
      if(g_use2 && !agree2) return Reject(2, "bias " + g_b2Text);
      if(g_use1 && b1 == -dir) return Reject(2, "bias " + g_b1Text);
   }
   else
   {
      bool any = (g_use1 && agree1) || (g_use2 && agree2);
      if((g_use1 || g_use2) && !any) return Reject(2, "bias");
   }

   //--- 3. displacement: the break has to be driven, not drifted into
   double body = MathAbs(c.r[i].close - c.r[i].open);
   bool displaced = (body >= c.atr[i] * InpDispAtrMult);
   if(InpRequireDisp && !displaced)
      return Reject(3, "no push");

   //--- 3b. EMA trend filter. A continuation has to sit on the right side of both
   //--- EMAs; a reversal only has to have reclaimed the fast one, because on a
   //--- genuine turn the slow EMA is still pointing the old way.
   bool emaUp = (c.emaF[i] > c.emaS[i]);
   bool emaOk;
   if(choch)
      emaOk = (dir > 0 ? c.r[i].close > c.emaF[i] : c.r[i].close < c.emaF[i]);
   else
      emaOk = (dir > 0 ? (emaUp  && c.r[i].close > c.emaS[i])
                       : (!emaUp && c.r[i].close < c.emaS[i]));
   if(InpUseEmaFilter && InpRequireBothLegs && !emaOk)
      return Reject(3, "EMA");

   //--- 3c. RSI filter. Refuses to buy something already exhausted upwards, and
   //--- demands that a reversal actually come from the stretched side.
   double rs = c.rsi[i];
   bool rsiOk;
   if(choch)
      rsiOk = (dir > 0 ? rs <= InpRsiRevBuy : rs >= InpRsiRevSell);
   else
      rsiOk = (dir > 0 ? (rs >= 45.0 && rs <= InpRsiMaxBuy)
                       : (rs <= 55.0 && rs >= InpRsiMinSell));
   if(InpUseRsiFilter && InpRequireBothLegs && !rsiOk)
      return Reject(3, "RSI");

   //--- 4. liquidity sweep shortly before the shift
   bool   hasSweep    = false;
   double sweepPrice  = 0.0;
   int    sweepEnd    = (int)MathMin(n - 2, i + InpSweepWindow);
   for(int k = i; k <= sweepEnd; k++)
      if(SweepAt(c.r, n, k, dir, InpSweepLookback))
      {
         hasSweep   = true;
         sweepPrice = (dir > 0 ? c.r[k].low : c.r[k].high);
         break;
      }
   if(InpRequireSweep && !hasSweep)
      return Reject(3, "no sweep");

   //--- Two independent ways to confirm a break, either of which is enough on
   //--- top of an agreeing bias:
   //---   SMC leg   - liquidity was taken and the break was driven
   //---   trend leg - EMA and RSI both back the direction
   //--- One leg plus bias is a strong setup. Both legs at once is the strong
   //--- one, and it is graded and scored higher rather than merely allowed.
   //--- Gating here, before the POI and liquidity searches, also means a bar
   //--- that cannot qualify costs almost nothing to reject.
   bool smcOk   = (hasSweep && displaced);
   bool trendOk = (InpUseEmaFilter || InpUseRsiFilter) &&
                  (!InpUseEmaFilter || emaOk) &&
                  (!InpUseRsiFilter || rsiOk);

   if(InpRequireBothLegs)
   {
      if(!smcOk || !trendOk)
         return Reject(4, "one leg only");
   }
   else if(!smcOk && !trendOk)
      return Reject(4, "no leg");

   //--- 5. point of interest to enter from
   MFPoi poi = FindPoi(c.r, n, i, dir);
   if(!poi.valid || poi.hi <= poi.lo)
      return Reject(5, "no POI");

   //--- a zone wider than this is not a level, it is a guess
   if((poi.hi - poi.lo) > c.atr[i] * InpMaxZoneAtr)
      return Reject(5, "POI wide");

   double entry = (InpPoiEntry == MF_POI_CE)
                  ? (poi.hi + poi.lo) * 0.5
                  : (dir > 0 ? poi.hi : poi.lo);

   //--- 6. Premium / discount. A day trade taken at the wrong half of the range
   //--- is the short, useless kind: you buy where the move is already spent and
   //--- your target is the part of the leg someone else took. So this is a hard
   //--- rule - buys only in discount, sells only in premium - measured on the
   //--- bias timeframe's dealing range, which is the range the move belongs to.
   double rangeHi = c.rHigh[i];
   double rangeLo = c.rLow[i];
   if(InpPdUseBiasRange && g_use2 && c.n2 > 0)
   {
      int j2 = c.idx2[i];
      if(c.rHigh2[j2] > c.rLow2[j2])
      {
         rangeHi = c.rHigh2[j2];
         rangeLo = c.rLow2[j2];
      }
   }

   bool pdOk = false;
   if(rangeHi > rangeLo)
   {
      double pos = (entry - rangeLo) / (rangeHi - rangeLo);   // 0 = range low, 1 = range high
      pdOk = (dir > 0 ? pos <= InpPdMaxPct : pos >= 1.0 - InpPdMaxPct);
   }
   if(InpRequirePD && !pdOk)
      return Reject(6, (dir > 0 ? "in premium" : "in discount"));

   //--- 7. stop behind the zone and behind the swept low/high
   double buffer = c.atr[i] * InpSlBufferAtr;
   double sl;
   if(dir > 0)
   {
      sl = poi.lo;
      if(hasSweep && sweepPrice > 0.0)
         sl = MathMin(sl, sweepPrice);
      sl -= buffer;
   }
   else
   {
      sl = poi.hi;
      if(hasSweep && sweepPrice > 0.0)
         sl = MathMax(sl, sweepPrice);
      sl += buffer;
   }

   double risk = MathAbs(entry - sl);
   double minRisk = c.atr[i] * InpMinRiskAtr;
   if(risk < minRisk)
   {
      risk = minRisk;
      sl   = entry - dir * risk;
   }

   if(risk <= 0.0)
      return Reject(7, "no risk");

   //--- judge the STRUCTURAL stop before the broker gets a say
   if(risk > c.atr[i] * InpMaxRiskAtr)
      return Reject(7, "stop wide");

   //--- now widen to whatever the broker demands. This can push the stop past
   //--- InpMaxRiskAtr and that is fine: it is a venue constraint, not a reason
   //--- to throw away a clean setup. The row flags it with * so the real R:R is
   //--- never hidden from you.
   bool adjusted = false;
   if(s.stopDist > 0.0 && risk < s.stopDist)
   {
      risk     = s.stopDist;
      sl       = entry - dir * risk;
      adjusted = true;
   }

   //--- 8. targets: resting liquidity first, R multiples only as fallback
   double minTp1 = entry + dir * risk * InpMinTp1R;
   double tp1 = 0.0, tp2 = 0.0, tp3 = 0.0;
   bool   liqTp = false;

   if(dir > 0)
   {
      tp1 = LiquidityAbove(c.r, n, i, InpSwingStrength, minTp1);
      if(tp1 > 0.0)
      {
         liqTp = true;
         tp2 = LiquidityAbove(c.r, n, i, InpSwingStrength, tp1 + risk * 0.25);
         if(g_use2 && c.n2 > 0)
         {
            double hr = c.rHigh2[c.idx2[i]];
            if(hr > MathMax(tp1, tp2) + risk * 0.25)
               tp3 = hr;
         }
      }
   }
   else
   {
      tp1 = LiquidityBelow(c.r, n, i, InpSwingStrength, minTp1);
      if(tp1 > 0.0)
      {
         liqTp = true;
         tp2 = LiquidityBelow(c.r, n, i, InpSwingStrength, tp1 - risk * 0.25);
         if(g_use2 && c.n2 > 0)
         {
            double lr = c.rLow2[c.idx2[i]];
            if(lr > 0.0 && lr < MathMin(tp1, (tp2 > 0.0 ? tp2 : tp1)) - risk * 0.25)
               tp3 = lr;
         }
      }
   }

   if(tp1 <= 0.0) tp1 = entry + dir * risk * InpTP1R;
   if(tp2 <= 0.0) tp2 = entry + dir * risk * InpTP2R;
   if(tp3 <= 0.0) tp3 = entry + dir * risk * InpTP3R;

   //--- keep the ladder ordered and each step meaningful
   if(dir > 0)
   {
      tp2 = MathMax(tp2, tp1 + risk * 0.25);
      tp3 = MathMax(tp3, tp2 + risk * 0.25);
   }
   else
   {
      tp2 = MathMin(tp2, tp1 - risk * 0.25);
      tp3 = MathMin(tp3, tp2 - risk * 0.25);
   }

   if(s.stopDist > 0.0 && MathAbs(tp1 - entry) < s.stopDist)
   {
      tp1 = entry + dir * s.stopDist;
      adjusted = true;
   }

   //--- 9. confluence score and grade
   int score = 0;
   if(agree1)           score += 12;     // higher bias
   if(agree2)           score += 18;     // nearer bias - closer to the trade
   if(smcOk)            score += 15;     // SMC leg
   if(trendOk)          score += 18;     // EMA/RSI leg
   if(smcOk && trendOk) score += 10;     // both at once - the strong case
   score += (choch ? 12 : 8);            // CHoCH over BOS
   score += ((poi.isOB && poi.isFVG) ? 15 : 12);
   if(pdOk)             score += 12;     // discount buy / premium sell
   if(score > 100) score = 100;

   string grade = (smcOk && trendOk) ? "A+" : (smcOk ? "A" : "B");

   //--- 10. compact confluence tags for the dashboard
   string tags = grade + " ";
   if(agree1) tags += g_b1Text + " ";
   if(agree2) tags += g_b2Text + " ";
   if(emaOk) tags += "EMA ";
   if(rsiOk) tags += "RSI ";
   if(hasSweep) tags += "SW ";
   tags += (choch ? "CH " : "BOS ");
   if(poi.isOB)  tags += "OB ";
   if(poi.isFVG) tags += "FVG ";
   if(pdOk) tags += (dir > 0 ? "DISC" : "PREM");
   StringTrimRight(tags);

   out.valid       = true;
   out.dir         = dir;
   out.choch       = choch;
   out.barIndex    = i;
   out.time        = c.r[i].time;
   out.entry       = NormPrice(s, entry);
   out.sl          = NormPrice(s, sl);
   out.tp1         = NormPrice(s, tp1);
   out.tp2         = NormPrice(s, tp2);
   out.tp3         = NormPrice(s, tp3);
   out.zoneHi      = NormPrice(s, poi.hi);
   out.zoneLo      = NormPrice(s, poi.lo);
   out.sweepPrice  = (hasSweep ? NormPrice(s, sweepPrice) : 0.0);
   out.biasD1      = b1;
   out.biasH4      = b2;
   out.hasOB       = poi.isOB;
   out.hasFVG      = poi.isFVG;
   out.hasSweep    = hasSweep;
   out.pdOk        = pdOk;
   out.displaced   = displaced;
   out.liquidityTp = liqTp;
   out.score       = score;
   out.grade       = grade;
   out.adjusted    = adjusted;
   out.status      = ST_WAIT;
   out.tags        = tags;
   return true;
}

int RecycleThreshold()
{
   if(InpRecycleAt == MF_RECYCLE_TP2) return ST_TP2;
   if(InpRecycleAt == MF_RECYCLE_TP3) return ST_TP3;
   return ST_TP1;
}

//+------------------------------------------------------------------+
//| Directional read for a pair that has no tradable setup right now. |
//| This is a lean, not a trade: it fills SIGNAL and SCORE so every    |
//| row says something, while ENTRY/SL/TP stay empty because there is  |
//| no setup to quote. A direction is never presented as an entry.     |
//+------------------------------------------------------------------+
void ComputeScout(MFCtx &c, MFSymbol &s)
{
   int i = 1;
   if(c.n <= i + 2)
      return;

   int b1 = (g_use1 && c.n1 > 0) ? c.bias1[c.idx1[i]] : 0;
   int b2 = (g_use2 && c.n2 > 0) ? c.bias2[c.idx2[i]] : 0;
   int lt = c.bias[i];
   bool emaUp = (c.emaF[i] > c.emaS[i]);

   int dir;
   if(b1 != 0 && b1 == b2) dir = b1;          // both bias timeframes agree
   else if(b2 != 0)        dir = b2;          // nearer bias leads
   else if(lt != 0)        dir = lt;          // entry timeframe structure
   else                    dir = (emaUp ? +1 : -1);

   int sc = 0;
   if(b1 == dir)            sc += 25;
   if(b2 == dir)            sc += 25;
   if(lt == dir)            sc += 20;
   if((dir > 0) == emaUp)   sc += 15;

   double rs = c.rsi[i];
   if(dir > 0 ? (rs >= 45.0 && rs <= InpRsiMaxBuy)
              : (rs <= 55.0 && rs >= InpRsiMinSell))
      sc += 15;

   s.scoutDir   = dir;
   s.scoutScore = sc;
   s.scoutB1    = b1;
   s.scoutB2    = b2;
}

//+------------------------------------------------------------------+
//| Replay the bars after the setup and report what really happened.  |
//| The entry is a limit: price must come back to it first. If the    |
//| stop is taken out before that, the setup died without a trade.    |
//| When one bar touches both the stop and a target, the stop counts  |
//| first - the pessimistic reading, never the flattering one.        |
//+------------------------------------------------------------------+
int ReplayStatus(const MqlRates &r[], const int n, const MFSignal &sg)
{
   bool entered = false;
   int  st = ST_WAIT;

   for(int k = sg.barIndex - 1; k >= 0; k--)
   {
      if(k >= n)
         continue;

      if(!entered)
      {
         if(sg.dir > 0)
            entered = (r[k].low  <= sg.entry);
         else
            entered = (r[k].high >= sg.entry);
         if(!entered)
            continue;
         st = ST_ACTIVE;
         // fall through: the same bar may also have hit the stop or a target
      }

      if(sg.dir > 0)
      {
         if(r[k].low  <= sg.sl)  return ST_SL;
         if(r[k].high >= sg.tp3) return ST_TP3;
         if(r[k].high >= sg.tp2) st = (int)MathMax(st, ST_TP2);
         else if(r[k].high >= sg.tp1) st = (int)MathMax(st, ST_TP1);
      }
      else
      {
         if(r[k].high >= sg.sl)  return ST_SL;
         if(r[k].low  <= sg.tp3) return ST_TP3;
         if(r[k].low  <= sg.tp2) st = (int)MathMax(st, ST_TP2);
         else if(r[k].low <= sg.tp1) st = (int)MathMax(st, ST_TP1);
      }
   }
   return st;
}

//--- +1 target first, -1 stop first, 0 no trade (never filled, killed
//--- before fill, or still open at the end of the hold window)
int BacktestOutcome(const MqlRates &r[], const int n, const MFSignal &sg)
{
   bool entered = false;
   int  stop = (int)MathMax(0, sg.barIndex - InpStatsMaxHold);

   for(int k = sg.barIndex - 1; k >= stop; k--)
   {
      if(k >= n)
         continue;

      if(!entered)
      {
         if(sg.dir > 0)
            entered = (r[k].low  <= sg.entry);
         else
            entered = (r[k].high >= sg.entry);
         if(!entered)
            continue;
         // fall through: the filling bar may also have hit the stop or TP1
      }

      if(sg.dir > 0)
      {
         if(r[k].low  <= sg.sl)  return -1;
         if(r[k].high >= sg.tp1) return +1;
      }
      else
      {
         if(r[k].high >= sg.sl)  return -1;
         if(r[k].low  <= sg.tp1) return +1;
      }
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Analysis of one symbol                                           |
//+------------------------------------------------------------------+
void AnalyseSymbol(MFSymbol &s)
{
   MFSignal prev = s.sig;      // whatever is already on the board
   s.sig.valid = false;

   if(!s.ok)
   {
      if(s.note == "" || s.note == "LOADING")
         s.note = "DISABLED";
      return;
   }

   MFCtx c;
   c.n = 0; c.n1 = 0; c.n2 = 0;

   //--- the back-test is only run when its result is actually on screen; it is
   //--- by far the most expensive part of a scan, and computing a number nobody
   //--- is looking at is what makes a scanner slow
   bool wantStats = (InpStatsBars > 0 && (InpShowWinRate || InpShowTradeDetail));

   int warmup = (int)MathMax(MathMax(InpAtrPeriod * 5, InpEmaSlow * 3), 150);
   int stats  = (wantStats ? InpStatsBars + InpStatsMaxHold : 0);
   //--- Only stretch the history window when a trade is actually still running.
   //--- Sizing every scan for the worst case would double the bars read on every
   //--- symbol to cover a situation that is usually not happening.
   int holdNeed = 0;
   if(prev.valid)
   {
      int ps = iBarShift(s.name, g_tf, prev.time, false);
      if(ps > 0)
         holdNeed = (int)MathMin(ps + 8, InpMaxHoldBars + 8);
   }

   int want   = (int)MathMax(MathMax(InpMaxAge + InpLiquidityLook + warmup, stats + warmup),
                             holdNeed + warmup);

   ArraySetAsSeries(c.r, true);
   int got = CopyRates(s.name, g_tf, 0, want, c.r);
   if(got < warmup + InpMaxAge + 4)
   {
      s.tries++;
      s.note = (got <= 0 ? (s.tries >= InpMaxTries ? "NO DATA" : "LOADING") : "SHORT HIST");
      return;
   }
   c.n = got;

   CalcATR(c.r, c.n, InpAtrPeriod, c.atr);
   CalcEMA(c.r, c.n, InpEmaFast,   c.emaF);
   CalcEMA(c.r, c.n, InpEmaSlow,   c.emaS);
   CalcRSI(c.r, c.n, InpRsiPeriod, c.rsi);

   //--- entry timeframe structure
   StructureSeries(c.r, c.n, InpSwingStrength, c.bias, c.evDir, c.evChoch, c.rHigh, c.rLow);

   //--- bias timeframes, each with its own structure walk, then mapped
   //--- onto the entry bars using the last CLOSED bias bar
   if(g_use1)
   {
      ArraySetAsSeries(c.r1, true);
      int g1 = CopyRates(s.name, g_bias1, 0, InpBiasBars, c.r1);
      if(g1 >= 60)
      {
         c.n1 = g1;
         int ed1[], ec1[];
         StructureSeries(c.r1, g1, InpSwingStrength, c.bias1, ed1, ec1, c.rHigh1, c.rLow1);
         MapHigher(c.r, c.n, c.r1, c.n1, c.idx1);
      }
      else
      {
         s.tries++;
         s.note = (s.tries >= InpMaxTries ? "NO " + g_b1Text : "LOADING " + g_b1Text);
         return;
      }
   }

   if(g_use2)
   {
      ArraySetAsSeries(c.r2, true);
      int g2 = CopyRates(s.name, g_bias2, 0, InpBiasBars, c.r2);
      if(g2 >= 60)
      {
         c.n2 = g2;
         int ed2[], ec2[];
         StructureSeries(c.r2, g2, InpSwingStrength, c.bias2, ed2, ec2, c.rHigh2, c.rLow2);
         MapHigher(c.r, c.n, c.r2, c.n2, c.idx2);
      }
      else
      {
         s.tries++;
         s.note = (s.tries >= InpMaxTries ? "NO " + g_b2Text : "LOADING " + g_b2Text);
         return;
      }
   }

   ComputeScout(c, s);

   //--- A pair carries one live setup at a time. While that setup is still
   //--- running it is held exactly as published - which is also what makes the
   //--- numbers non-repainting, since a rescan can never recompute them. Once it
   //--- reaches its recycle target or the stop, the pair is free again and the
   //--- scan looks for the next one. There is no cap on setups per day.
   bool held = false;
   int  done = RecycleThreshold();

   if(prev.valid)
   {
      int pshift = iBarShift(s.name, g_tf, prev.time, false);
      if(pshift >= 0 && pshift < c.n - 2)
      {
         prev.barIndex = pshift;
         int st = ReplayStatus(c.r, c.n, prev);
         prev.status = st;

         bool finished = (st == ST_INVALID || st == ST_SL || st >= done);

         //--- A filled trade runs until TP3 or the stop, however long that takes -
         //--- no clock kills it. An UNFILLED limit is different: if price never
         //--- comes back to the zone the setup is just clutter, so it is dropped
         //--- after InpMaxAge bars. InpMaxHoldBars is only a safety stop so a
         //--- forgotten trade cannot be tracked forever.
         bool expired = (st == ST_WAIT ? (pshift > InpMaxAge)
                                       : (pshift > InpMaxHoldBars));

         if(!finished && !expired)
         {
            s.sig = prev;             // still running - the pair stays occupied
            held  = true;
         }
         else if(finished && !InpHideFinished)
         {
            s.sig = prev;             // keep it visible until something replaces it
         }
      }
   }

   //--- newest qualifying setup
   if(!held)
   {
      //--- track how far the best candidate got, so a pair with no setup can say
      //--- which gate stopped it rather than just showing a blank row
      g_rejStage = 0;
      g_rejWhy   = "";
      int  events = 0;
      int  bestScore = -1;
      bool published = false;

      MFSignal sg;
      for(int i = 1; i <= InpMaxAge; i++)
      {
         if(c.evDir[i] == 0)
            continue;
         events++;
         if(!EvaluateAt(s, c, i, sg))
            continue;
         if(sg.score > bestScore)
            bestScore = sg.score;
         if(sg.score < InpMinScore)
            continue;

         sg.status = ReplayStatus(c.r, c.n, sg);
         if(sg.status == ST_INVALID)   // stopped out before it ever filled
            continue;
         if(sg.status >= done || sg.status == ST_SL)
            continue;                  // discovered already over - never tradable

         s.sig = sg;
         published = true;
         break;
      }

      if(published)
         s.scoutWhy = "";
      else if(events == 0)
         s.scoutWhy = "no shift";
      else if(bestScore >= 0)
         s.scoutWhy = StringFormat("score %d", bestScore);
      else
         s.scoutWhy = (g_rejWhy == "" ? "no setup" : g_rejWhy);
   }

   //--- measured hit rate of this exact rule on this symbol
   if(wantStats)
   {
      int wins = 0, losses = 0;
      int from = (int)MathMin(c.n - InpSwingStrength - 3, InpStatsBars + InpStatsMaxHold);
      MFSignal bs;
      int i = from;
      while(i > InpStatsMaxHold)
      {
         if(c.evDir[i] != 0 && EvaluateAt(s, c, i, bs) && bs.score >= InpMinScore)
         {
            int res = BacktestOutcome(c.r, c.n, bs);
            if(res > 0)      wins++;
            else if(res < 0) losses++;
            i -= 3;
            continue;
         }
         i--;
      }
      s.statWins   = wins;
      s.statLosses = losses;
   }

   s.analysed = true;
   s.tries    = 0;
   s.note     = "";
   s.lastBar  = c.r[0].time;

   //--- optional heads-up when a setup first appears. This is NOT the trade
   //--- alert: at this moment price is still away from the entry.
   if(InpAlertOnForming && s.sig.valid && s.sig.barIndex <= 2 &&
      s.sig.time != s.lastAlert &&
      s.sig.score >= InpAlertMinScore && s.sig.score <= InpAlertMaxScore)
   {
      s.lastAlert = s.sig.time;
      string msg = StringFormat("MarketFlow V8 | forming: %s %s %s %s | score %d | waiting for %s",
                                s.name, g_tfText,
                                (s.sig.dir > 0 ? "BUY" : "SELL"),
                                (s.sig.choch ? "CHoCH" : "BOS"),
                                s.sig.score,
                                DoubleToString(s.sig.entry, s.digits));
      if(InpAlertPopup) Alert(msg);
      if(InpAlertPush)  SendNotification(msg);
   }
}

//--- THE trade alert. Fires the moment the entry becomes fillable at the live
//--- quote - a buy limit needs the ask down at the entry, a sell limit needs the
//--- bid up at it - not when the setup was first drawn. When this fires the
//--- setup is confirmed and the entry is available right now.
void FireEntryAlert(MFSymbol &s)
{
   if(s.sig.score < InpAlertMinScore || s.sig.score > InpAlertMaxScore)
      return;
   if(s.alertedEntry == s.sig.time)
      return;
   s.alertedEntry = s.sig.time;

   string msg = StringFormat("MarketFlow V8 >> ENTER NOW  %s %s  %s %s  score %d | entry %s  SL %s  TP1 %s  TP2 %s | %s",
                             s.name, g_tfText,
                             (s.sig.dir > 0 ? "BUY" : "SELL"),
                             (s.sig.choch ? "REVERSAL" : "CONTINUATION"),
                             s.sig.score,
                             DoubleToString(s.sig.entry, s.digits),
                             DoubleToString(s.sig.sl,    s.digits),
                             DoubleToString(s.sig.tp1,   s.digits),
                             DoubleToString(s.sig.tp2,   s.digits),
                             s.sig.tags);
   Print(msg);
   if(InpAlertPopup) Alert(msg);
   if(InpAlertPush)  SendNotification(msg);
   if(InpAlertSound) PlaySound("alert2.wav");
}

//--- one line to the Experts tab saying what the scan is actually doing
void LogRejects()
{
   if(!InpLogRejects)
      return;
   if(TimeCurrent() - g_lastLog < InpLogSeconds)
      return;
   g_lastLog = TimeCurrent();

   int total = ArraySize(g_syms);
   int live = 0, watch = 0, loading = 0;
   string why = "";
   for(int i = 0; i < total; i++)
   {
      if(g_syms[i].sig.valid)
      {
         live++;
         continue;
      }
      if(!g_syms[i].analysed)
      {
         loading++;
         continue;
      }
      watch++;
      if(g_syms[i].scoutWhy != "" && StringFind(why, g_syms[i].scoutWhy) < 0)
         why += g_syms[i].scoutWhy + ", ";
   }
   PrintFormat("MarketFlow V8 | %s %s | %d symbols: %d setups, %d watching, %d loading | reasons: %s",
               g_tfText, (g_use1 || g_use2 ? g_b1Text + "+" + g_b2Text + " bias" : "no bias"),
               total, live, watch, loading, (why == "" ? "-" : why));
}

//--- cheap intrabar refresh of the outcome only
void RefreshStatus(MFSymbol &s)
{
   if(!s.ok || !s.sig.valid)
      return;

   //--- re-derive the signal bar's shift from its timestamp: it moves every time
   //--- a new bar prints, and a stale shift would replay the wrong bars
   int shift = iBarShift(s.name, g_tf, s.sig.time, false);
   if(shift < 0)
      return;
   s.sig.barIndex = shift;

   int need = shift + 2;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(s.name, g_tf, 0, need, r) < need)
      return;

   int before = s.sig.status;
   int st     = ReplayStatus(r, need, s.sig);

   //--- live fillability, checked against the actual quote rather than bar lows
   if(st == ST_WAIT)
   {
      double ask = SymbolInfoDouble(s.name, SYMBOL_ASK);
      double bid = SymbolInfoDouble(s.name, SYMBOL_BID);
      if(s.sig.dir > 0 ? (ask > 0.0 && ask <= s.sig.entry)
                       : (bid > 0.0 && bid >= s.sig.entry))
         st = ST_ACTIVE;
   }

   s.sig.status = st;

   if(before == ST_WAIT && st >= ST_ACTIVE)
      FireEntryAlert(s);
}

//+------------------------------------------------------------------+
//| Background scheduler                                             |
//+------------------------------------------------------------------+
void RunScanBudget()
{
   int total = ArraySize(g_syms);
   if(total == 0)
      return;

   //--- until every symbol has been analysed once, run at the burst rate so the
   //--- board fills quickly; after that only new bars need work, so drop back
   bool warm = true;
   for(int i = 0; i < total; i++)
      if(g_syms[i].ok && !g_syms[i].analysed && g_syms[i].tries < InpMaxTries)
      {
         warm = false;
         break;
      }

   //--- The first fill is not limited by arithmetic, it is limited by MetaTrader
   //--- downloading history. Round-robin alone discovers that need one symbol at
   //--- a time, so each download starts only when its turn comes up. Asking for a
   //--- single bar on every pending symbol costs nothing and makes the terminal
   //--- fetch them all concurrently, which is what actually shortens the wait.
   if(!warm)
   {
      MqlRates probe[];
      for(int i = 0; i < total; i++)
      {
         if(!g_syms[i].ok || g_syms[i].analysed || g_syms[i].tries >= InpMaxTries)
            continue;
         CopyRates(g_syms[i].name, g_tf, 0, 1, probe);
         if(g_use1) CopyRates(g_syms[i].name, g_bias1, 0, 1, probe);
         if(g_use2) CopyRates(g_syms[i].name, g_bias2, 0, 1, probe);
      }
   }

   int budget = (int)MathMax(1, warm ? InpSymbolsPerTick : InpWarmupPerTick);
   int looked = 0;

   while(budget > 0 && looked < total)
   {
      int i = g_cursor;
      g_cursor = (g_cursor + 1) % total;
      looked++;

      if(!g_syms[i].ok)
         continue;

      datetime bar0 = (datetime)SeriesInfoInteger(g_syms[i].name, g_tf, SERIES_LASTBAR_DATE);
      if(bar0 != 0)
         g_syms[i].curBar = bar0;      // keeps AGE live even between analyses
      if(g_syms[i].analysed && bar0 != 0 && bar0 == g_syms[i].lastBar)
         continue;

      AnalyseSymbol(g_syms[i]);
      budget--;
   }

   for(int i = 0; i < total; i++)
      if(g_syms[i].sig.valid)
         RefreshStatus(g_syms[i]);
}

//+------------------------------------------------------------------+
//| Ordering                                                         |
//+------------------------------------------------------------------+
int RankOf(const MFSymbol &s)
{
   //--- real setups first, then the directional reads by strength
   if(!s.sig.valid)
      return 500000 + (100 - s.scoutScore);
   if(InpSortMode == MF_SORT_SCORE)
      return 1000 - s.sig.score;
   return s.sig.barIndex * 1000 + (100 - s.sig.score);
}

void BuildOrder()
{
   ArrayResize(g_order, 0);
   for(int i = 0; i < ArraySize(g_syms); i++)
   {
      if(InpOnlySignals && !g_syms[i].sig.valid)
         continue;

      //--- a row on the board means real analysis sits behind it. Symbols still
      //--- downloading are held back rather than shown as placeholders; ones that
      //--- failed for a reason (DISABLED, SHORT HIST) still show, so nothing
      //--- disappears silently.
      if(InpShowOnlyAnalysed && !g_syms[i].analysed &&
         StringFind(g_syms[i].note, "LOADING") == 0)
         continue;
      int k = ArraySize(g_order);
      ArrayResize(g_order, k + 1);
      g_order[k] = i;
   }

   if(InpSortMode != MF_SORT_LIST)
   {
      int n = ArraySize(g_order);
      for(int a = 0; a < n - 1; a++)
         for(int b = 0; b < n - 1 - a; b++)
            if(RankOf(g_syms[g_order[b]]) > RankOf(g_syms[g_order[b + 1]]))
            {
               int t          = g_order[b];
               g_order[b]     = g_order[b + 1];
               g_order[b + 1] = t;
            }
   }

   int maxScroll = (int)MathMax(0, ArraySize(g_order) - InpRowsVisible);
   g_scroll = (int)MathMin(MathMax(0, g_scroll), maxScroll);
}

//+------------------------------------------------------------------+
//| Cell text                                                        |
//+------------------------------------------------------------------+
string DirText(const int dir)
{
   if(dir == 0)
      return "-";
   return (dir > 0 ? ShortToString(0x25B2) + " BUY" : ShortToString(0x25BC) + " SELL");
}

string SignalText(const MFSignal &s)
{
   if(!s.valid)
      return "-";
   string head = (s.dir > 0 ? ShortToString(0x25B2) + " BUY" : ShortToString(0x25BC) + " SELL");
   return head + (s.choch ? "" : "+");          // CHoCH reversal plain, BOS continuation "+"
}

string BiasPair(const int b1, const int b2)
{
   string t = "";
   if(g_use1)           t += g_b1Text + ArrowFor(b1);
   if(g_use1 && g_use2) t += " ";
   if(g_use2)           t += g_b2Text + ArrowFor(b2);
   if(t == "")          t = "-";
   return t;
}

string BiasText(const MFSignal &s)
{
   if(!s.valid)
      return "-";
   return BiasPair(s.biasD1, s.biasH4);
}

color BiasColor(const MFSignal &s)
{
   if(!s.valid)
      return InpClrDim;
   bool a1 = (!g_use1 || s.biasD1 == s.dir);
   bool a2 = (!g_use2 || s.biasH4 == s.dir);
   if(a1 && a2)
      return (s.dir > 0 ? InpClrBuy : InpClrSell);
   return InpClrDim;
}

//--- AGE is derived from the signal bar's own timestamp against the symbol's
//--- current bar, so it stays correct no matter when that symbol was last
//--- analysed - it is never a number frozen at scan time.
string AgeText(const MFSymbol &sym)
{
   if(!sym.sig.valid)
      return "-";

   if(InpAgeMode == MF_AGE_CLOCK)
   {
      long secs = (long)(TimeCurrent() - sym.sig.time);
      if(secs < 60)
         return "just now";
      long mins = secs / 60;
      if(mins < 60)
         return StringFormat("%dm ago", (int)mins);
      return StringFormat("%dh %02dm ago", (int)(mins / 60), (int)(mins % 60));
   }

   int ps   = PeriodSeconds(g_tf);
   int bars = sym.sig.barIndex;
   if(sym.curBar > 0 && ps > 0)
      bars = (int)((sym.curBar - sym.sig.time) / ps);
   if(bars <= 1)
      return "current";
   return StringFormat("%d bars ago", bars - 1);
}

string StatusText(const MFSignal &s)
{
   if(!s.valid)
      return "-";
   switch(s.status)
   {
      case ST_INVALID: return "INVALID";
      case ST_SL:      return "SL HIT";
      case ST_WAIT:    return "WAITING";
      case ST_TP1:     return "TP1 HIT";
      case ST_TP2:     return "TP2 HIT";
      case ST_TP3:     return "TP3 HIT";
   }
   return "ACTIVE";
}

color StatusColor(const MFSignal &s)
{
   if(!s.valid)
      return InpClrDim;
   if(s.status == ST_SL || s.status == ST_INVALID)
      return InpClrSell;
   if(s.status >= ST_TP1)
      return InpClrBuy;
   if(s.status == ST_WAIT)
      return InpClrDim;
   return InpClrText;
}

string WinRateText(const MFSymbol &s)
{
   if(InpStatsBars <= 0)
      return "off";
   int total = s.statWins + s.statLosses;
   if(total <= 0 || total < InpStatsMinSamples)
      return StringFormat("n/a %d", total);
   return StringFormat("%d%% %d", (int)MathRound(100.0 * s.statWins / total), total);
}

string PriceText(const MFSymbol &s, const double v)
{
   if(!s.sig.valid)
      return "-";
   return DoubleToString(v, s.digits);
}

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
void LayoutColumns()
{
   for(int c = 0; c < NCOLS; c++)
      g_colOn[c] = true;
   g_colOn[C_BIAS]   = InpShowBias;
   g_colOn[C_SMC]    = InpShowSmc;
   g_colOn[C_SCORE]  = InpShowScore;
   g_colOn[C_WR]     = InpShowWinRate;
   g_colOn[C_STATUS] = InpShowStatus;

   int x = 8;
   for(int c = 0; c < NCOLS; c++)
   {
      g_colX[c] = x;
      if(g_colOn[c])
         x += g_colWidth[c];
   }
   g_panelW = x + 8;
}

void DrawPanel()
{
   g_objWin = g_win;                 // dashboard lives in its own sub-window
   int H = PanelHeight();
   SetRect(g_prefix + "bg", InpPanelX, InpPanelY, g_panelW, H, InpClrPanelBg, InpClrPanelBorder);

   int nSyms = ArraySize(g_syms);
   int nDone = 0;
   for(int i = 0; i < nSyms; i++)
      if(g_syms[i].analysed)
         nDone++;

   string title = StringFormat("%s MARKETFLOW V8  |  SIGNALS DASHBOARD  |  %s  |  %s",
                               ShortToString(0x25C8), g_tfText,
                               TimeToString(TimeCurrent(), TIME_MINUTES));
   //--- the steady-state title matches the reference exactly; the scan counter
   //--- only shows while symbols are still warming up, so a blank row is never
   //--- ambiguous between "no setup" and "not looked at yet"
   if(nDone < nSyms)
      title += StringFormat("  |  scanning %d/%d", nDone, nSyms);
   SetLabel(g_prefix + "title", InpPanelX + 8, InpPanelY + H - g_titleH + 7, title,
            InpClrTitle, InpFontSize + 1);

   int total = ArraySize(g_order);
   int shown = (int)MathMin(InpRowsVisible, (int)MathMax(0, total - g_scroll));
   int from  = (total == 0 ? 0 : g_scroll + 1);
   int to    = g_scroll + shown;

   int btnY = InpPanelY + H - g_titleH + 3;
   string dblUp = ShortToString(0x25B2) + ShortToString(0x25B2);
   string dblDn = ShortToString(0x25BC) + ShortToString(0x25BC);

   SetButton(g_prefix + "btn_pgup", InpPanelX + g_panelW - 200, btnY, 26, 16,
             dblUp, InpClrRowB, InpClrTitle);
   SetButton(g_prefix + "btn_up",   InpPanelX + g_panelW - 170, btnY, 18, 16,
             ShortToString(0x25B2), InpClrRowB, InpClrTitle);
   SetButton(g_prefix + "btn_down", InpPanelX + g_panelW - 148, btnY, 18, 16,
             ShortToString(0x25BC), InpClrRowB, InpClrTitle);
   SetButton(g_prefix + "btn_pgdn", InpPanelX + g_panelW - 126, btnY, 26, 16,
             dblDn, InpClrRowB, InpClrTitle);
   SetLabel(g_prefix + "page", InpPanelX + g_panelW - 94, InpPanelY + H - g_titleH + 7,
            StringFormat("%d-%d / %d", from, to, total), InpClrHeader, InpFontSize);

   int headY = InpPanelY + H - g_titleH - g_headerH + 6;
   for(int c = 0; c < NCOLS; c++)
   {
      string hn = g_prefix + "hdr" + IntegerToString(c);
      if(!g_colOn[c])
      {
         ObjShow(hn, false);
         continue;
      }
      SetLabel(hn, InpPanelX + g_colX[c], headY, g_colTitle[c], InpClrHeader, InpFontSize);
   }

   for(int i = 0; i < InpRowsVisible; i++)
   {
      string suf  = IntegerToString(i);
      int    base = RowBaseline(i);
      int    idx  = g_scroll + i;
      bool   has  = (idx < total);

      string rowBg = g_prefix + "rowbg" + suf;
      string btn   = g_prefix + "btn_open" + suf;

      if(!has)
      {
         ObjShow(rowBg, false);
         for(int c = 0; c < NCOLS; c++)
            ObjShow(g_prefix + "c" + IntegerToString(c) + "_" + suf, false);
         ObjShow(btn, false);
         continue;
      }

      MFSymbol s  = g_syms[g_order[idx]];

      color rowClr = ((i % 2) == 0 ? InpClrRowA : InpClrRowB);
      if(s.name == _Symbol)
         rowClr = InpClrRowActive;
      SetRect(rowBg, InpPanelX + 4, base - 4, g_panelW - 8, InpRowHeight, rowClr, InpClrPanelBg);
      bool     sv    = s.sig.valid;
      bool     scout = (!sv && s.analysed && s.scoutDir != 0);
      int      rdir  = (sv ? s.sig.dir : (scout ? s.scoutDir : 0));
      color    sc    = (rdir == 0 ? InpClrDim : (rdir > 0 ? InpClrBuy : InpClrSell));

      string cell[NCOLS];
      cell[C_SYMBOL] = s.name;
      cell[C_TF]     = g_tfText;
      cell[C_BIAS]   = (s.note != "" ? "" :
                        (sv ? BiasText(s.sig) : (scout ? BiasPair(s.scoutB1, s.scoutB2) : "-")));
      cell[C_SIGNAL] = (s.note != "" ? s.note :
                        (sv ? SignalText(s.sig) : DirText(s.scoutDir)));
      cell[C_SMC]    = (sv ? s.sig.tags : (scout && s.scoutWhy != "" ? s.scoutWhy : "-"));
      cell[C_SCORE]  = (sv ? IntegerToString(s.sig.score)
                           : (scout ? IntegerToString(s.scoutScore) : "-"));
      cell[C_WR]     = (s.analysed ? WinRateText(s) : "-");
      cell[C_AGE]    = (s.note != "" ? "" : AgeText(s));
      cell[C_ENTRY]  = PriceText(s, s.sig.entry);
      cell[C_SL]     = PriceText(s, s.sig.sl) + (sv && s.sig.adjusted ? "*" : "");
      cell[C_TP1]    = PriceText(s, s.sig.tp1);
      cell[C_TP2]    = PriceText(s, s.sig.tp2);
      cell[C_TP3]    = PriceText(s, s.sig.tp3);
      cell[C_STATUS] = (sv ? StatusText(s.sig) : (scout ? "WATCH" : "-"));
      cell[C_CHART]  = "";

      for(int c = 0; c < NCOLS; c++)
      {
         string cn = g_prefix + "c" + IntegerToString(c) + "_" + suf;
         if(!g_colOn[c] || c == C_CHART)
         {
            ObjShow(cn, false);
            continue;
         }

         color clr = InpClrText;
         if(c == C_SYMBOL)                    clr = (sv ? InpClrTitle : InpClrDim);
         if(c == C_BIAS)                      clr = (sv ? BiasColor(s.sig) : InpClrDim);
         if(c == C_SIGNAL)                    clr = (s.note != "" ? InpClrDim : sc);
         if(c == C_SMC)                       clr = (sv ? InpClrHeader : InpClrDim);
         if(c == C_SCORE || c == C_AGE)       clr = sc;
         if(c >= C_ENTRY && c <= C_TP3)       clr = (sv ? sc : InpClrDim);
         if(c == C_SL && sv)                  clr = InpClrSell;
         if(c == C_WR)                        clr = InpClrText;
         if(c == C_STATUS)                    clr = (sv ? StatusColor(s.sig) : InpClrDim);

         SetLabel(cn, InpPanelX + g_colX[c], base, cell[c], clr, InpFontSize);
      }

      SetButton(btn, InpPanelX + g_colX[C_CHART], base - 3, 50, InpRowHeight - 3,
                "OPEN", InpClrPanelBg, InpClrOpen);
   }
}

//+------------------------------------------------------------------+
//| Chart drawing                                                    |
//+------------------------------------------------------------------+
void ClearChartTrade()
{
   if(!g_tradeDrawn)
      return;                     // nothing up: skip the sweep entirely
   ObjectsDeleteAll(0, g_prefix + "tr_");
   g_tradeDrawn = false;
}

void SetTradeLine(const string name, const datetime t1, const datetime t2, const double price,
                  const color clr, const ENUM_LINE_STYLE style)
{
   if(!EnsureObject(name, OBJ_TREND))
      return;
   ObjectSetInteger(0, name, OBJPROP_TIME,      0, t1);
   ObjectSetDouble (0, name, OBJPROP_PRICE,     0, price);
   ObjectSetInteger(0, name, OBJPROP_TIME,      1, t2);
   ObjectSetDouble (0, name, OBJPROP_PRICE,     1, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE,     style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,     1);
   ObjectSetInteger(0, name, OBJPROP_RAY_LEFT,  false);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_BACK,      true);
}

void SetTradeText(const string name, const datetime t, const double price,
                  const string text, const color clr)
{
   if(!EnsureObject(name, OBJ_TEXT))
      return;
   ObjectSetInteger(0, name, OBJPROP_TIME,     t);
   ObjectSetDouble (0, name, OBJPROP_PRICE,    price);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR,   ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, name, OBJPROP_COLOR,    clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpFontSize + 1);
   ObjectSetString (0, name, OBJPROP_FONT,     InpFont);
   ObjectSetString (0, name, OBJPROP_TEXT,     text);
}

void DrawChartTrade()
{
   g_objWin = 0;                     // trade drawing belongs on the price chart
   if(!InpShowChartTrade || g_tf != (ENUM_TIMEFRAMES)_Period)
   {
      ClearChartTrade();
      return;
   }

   int found = -1;
   for(int i = 0; i < ArraySize(g_syms); i++)
      if(g_syms[i].name == _Symbol && g_syms[i].sig.valid)
      {
         found = i;
         break;
      }

   if(found < 0)
   {
      ClearChartTrade();
      return;
   }

   MFSymbol s  = g_syms[found];
   MFSignal sg = s.sig;

   bool     buy = (sg.dir > 0);
   color    clr = buy ? InpClrBuy : InpClrSell;
   int      ps  = PeriodSeconds(g_tf);
   datetime t1  = sg.time;
   datetime t2  = (datetime)(TimeCurrent() + (long)ps * InpBoxExtendBars);

   //--- POI zone the entry is taken from
   string zone = g_prefix + "tr_zone";
   if(InpShowSmcMarkup && EnsureObject(zone, OBJ_RECTANGLE))
   {
      ObjectSetInteger(0, zone, OBJPROP_TIME,  0, t1);
      ObjectSetDouble (0, zone, OBJPROP_PRICE, 0, sg.zoneLo);
      ObjectSetInteger(0, zone, OBJPROP_TIME,  1, t2);
      ObjectSetDouble (0, zone, OBJPROP_PRICE, 1, sg.zoneHi);
      ObjectSetInteger(0, zone, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, zone, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, zone, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, zone, OBJPROP_FILL,  true);
      ObjectSetInteger(0, zone, OBJPROP_BACK,  true);
   }
   else if(!InpShowSmcMarkup)
      ObjectDelete(0, zone);

   string box = g_prefix + "tr_box";
   if(EnsureObject(box, OBJ_RECTANGLE))
   {
      ObjectSetInteger(0, box, OBJPROP_TIME,  0, t1);
      ObjectSetDouble (0, box, OBJPROP_PRICE, 0, sg.sl);
      ObjectSetInteger(0, box, OBJPROP_TIME,  1, t2);
      ObjectSetDouble (0, box, OBJPROP_PRICE, 1, sg.tp3);
      ObjectSetInteger(0, box, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, box, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, box, OBJPROP_FILL,  false);
      ObjectSetInteger(0, box, OBJPROP_BACK,  true);
   }

   string vl = g_prefix + "tr_vline";
   if(EnsureObject(vl, OBJ_VLINE))
   {
      ObjectSetInteger(0, vl, OBJPROP_TIME,  t1);
      ObjectSetInteger(0, vl, OBJPROP_COLOR, C'90,90,110');
      ObjectSetInteger(0, vl, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, vl, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, vl, OBJPROP_BACK,  true);
   }

   string hl = g_prefix + "tr_entry";
   if(EnsureObject(hl, OBJ_HLINE))
   {
      ObjectSetDouble (0, hl, OBJPROP_PRICE, sg.entry);
      ObjectSetInteger(0, hl, OBJPROP_COLOR, InpClrEntryLine);
      ObjectSetInteger(0, hl, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, hl, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, hl, OBJPROP_BACK,  true);
   }

   SetTradeLine(g_prefix + "tr_sl",  t1, t2, sg.sl,  InpClrSell, STYLE_SOLID);
   SetTradeLine(g_prefix + "tr_tp1", t1, t2, sg.tp1, clr,        STYLE_DOT);
   SetTradeLine(g_prefix + "tr_tp2", t1, t2, sg.tp2, clr,        STYLE_DOT);
   SetTradeLine(g_prefix + "tr_tp3", t1, t2, sg.tp3, clr,        STYLE_DOT);

   datetime tTxt = (datetime)(t1 + (long)ps * 2);
   SetTradeText(g_prefix + "tr_txt_entry", tTxt, sg.entry,
                "ENTRY: " + DoubleToString(sg.entry, s.digits), InpClrText);
   SetTradeText(g_prefix + "tr_txt_sl",  tTxt, sg.sl,  "SL: "  + DoubleToString(sg.sl,  s.digits), InpClrSell);
   SetTradeText(g_prefix + "tr_txt_tp1", tTxt, sg.tp1, "TP1: " + DoubleToString(sg.tp1, s.digits), clr);
   SetTradeText(g_prefix + "tr_txt_tp2", tTxt, sg.tp2, "TP2: " + DoubleToString(sg.tp2, s.digits), clr);
   SetTradeText(g_prefix + "tr_txt_tp3", tTxt, sg.tp3, "TP3: " + DoubleToString(sg.tp3, s.digits), clr);

   //--- structure shift and swept liquidity: analysis markup, off by default so
   //--- the chart carries only what the reference layout shows
   string bosTag = g_prefix + "tr_txt_bos";
   string sw     = g_prefix + "tr_sweep";
   string swTag  = g_prefix + "tr_txt_sweep";

   if(InpShowSmcMarkup)
   {
      SetTradeText(bosTag, t1, (buy ? sg.zoneHi : sg.zoneLo),
                   (sg.choch ? "CHoCH" : "BOS"), clr);

      if(sg.sweepPrice > 0.0)
      {
         SetTradeLine(sw, (datetime)(t1 - (long)ps * InpSweepWindow), t2, sg.sweepPrice,
                      InpClrDim, STYLE_DASH);
         SetTradeText(swTag, (datetime)(t1 - (long)ps * InpSweepWindow),
                      sg.sweepPrice, "SWEEP", InpClrDim);
      }
      else
      {
         ObjectDelete(0, sw);
         ObjectDelete(0, swTag);
      }
   }
   else
   {
      ObjectDelete(0, bosTag);
      ObjectDelete(0, sw);
      ObjectDelete(0, swTag);
   }

   double hi  = iHigh(_Symbol, g_tf, sg.barIndex);
   double lo  = iLow (_Symbol, g_tf, sg.barIndex);
   double pad = MathAbs(sg.entry - sg.sl) * 0.35;
   string ar  = g_prefix + "tr_arrow";
   if(EnsureObject(ar, OBJ_ARROW))
   {
      ObjectSetInteger(0, ar, OBJPROP_TIME,      t1);
      ObjectSetDouble (0, ar, OBJPROP_PRICE,     buy ? lo - pad : hi + pad);
      ObjectSetInteger(0, ar, OBJPROP_ARROWCODE, buy ? 233 : 234);
      ObjectSetInteger(0, ar, OBJPROP_ANCHOR,    buy ? ANCHOR_TOP : ANCHOR_BOTTOM);
      ObjectSetInteger(0, ar, OBJPROP_COLOR,     clr);
      ObjectSetInteger(0, ar, OBJPROP_WIDTH,     3);
   }

   //--- reference legend: "TRADE" over "<arrow> BUY+ CONTINUATION", nothing else.
   //--- the SMC read moves to an opt-in third line so the default view matches.
   g_tradeDrawn = true;

   //--- the legend sits on the price chart, so it is measured from that chart's
   //--- bottom edge - the panel's height is in a different window now
   int legendY = InpPanelY + 4;
   int yTrade  = legendY + (InpShowTradeDetail ? 32 : 16);
   int ySignal = legendY + (InpShowTradeDetail ? 16 : 0);

   SetLabel(g_prefix + "tr_leg1", InpPanelX + 8, yTrade,
            ShortToString(0x25C8) + " TRADE", InpClrTitle, InpFontSize + 1);
   SetLabel(g_prefix + "tr_leg2", InpPanelX + 8, ySignal,
            SignalText(sg) + "  " + (sg.choch ? "REVERSAL" : "CONTINUATION"),
            clr, InpFontSize + 1);

   string leg3 = g_prefix + "tr_leg3";
   if(InpShowTradeDetail)
      SetLabel(leg3, InpPanelX + 8, legendY,
               StringFormat("%s  %s  score %d  %s   risk %s   R:R %.1f   targets %s   measured %s",
                            BiasText(sg), sg.tags, sg.score, StatusText(sg),
                            DoubleToString(MathAbs(sg.entry - sg.sl), s.digits),
                            (MathAbs(sg.entry - sg.sl) > 0.0
                               ? MathAbs(sg.tp1 - sg.entry) / MathAbs(sg.entry - sg.sl) : 0.0),
                            (sg.liquidityTp ? "liquidity" : "R fallback"),
                            WinRateText(s)),
               InpClrDim, InpFontSize);
   else
      ObjectDelete(0, leg3);
}

void DrawWatermark()
{
   g_objWin = 0;
   string wm = g_prefix + "watermark";
   if(!InpShowWatermark)
   {
      ObjectDelete(0, wm);
      return;
   }
   color wc = InpClrWatermark;
   if(InpWatermarkTint)
      for(int i = 0; i < ArraySize(g_syms); i++)
         if(g_syms[i].name == _Symbol && g_syms[i].sig.valid)
         {
            wc = (g_syms[i].sig.dir > 0 ? InpClrBuy : InpClrSell);
            break;
         }

   SetLabel(wm, 20, 24, _Symbol + "   |   " + TfToText((ENUM_TIMEFRAMES)_Period),
            wc, 14, CORNER_RIGHT_UPPER, ANCHOR_RIGHT_UPPER);
}

//+------------------------------------------------------------------+
//| Lifecycle                                                        |
//+------------------------------------------------------------------+
int OnInit()
{
   g_tf     = (InpTimeframe == PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : InpTimeframe);
   //--- Setups are always found on the CURRENT chart timeframe. The two bias
   //--- timeframes ride one and two steps above it, so an M15 chart is confirmed
   //--- by H1 + H4, and an H4 chart is the H4 setup itself confirmed by D1 + W1.
   if(InpBiasAuto)
   {
      g_bias2 = NextTimeframeUp(g_tf);          // nearer bias
      g_bias1 = NextTimeframeUp(g_bias2);       // higher bias
   }
   else
   {
      g_bias1 = InpBiasTF1;
      g_bias2 = InpBiasTF2;
   }
   g_tfText = TfToText(g_tf);
   g_b1Text = TfToText(g_bias1);
   g_b2Text = TfToText(g_bias2);

   //--- a bias timeframe must actually be higher than the entry timeframe
   g_use1 = (PeriodSeconds(g_bias1) > PeriodSeconds(g_tf));
   g_use2 = (PeriodSeconds(g_bias2) > PeriodSeconds(g_tf));
   if(!g_use1 && !g_use2)
      Print("MarketFlow V8: both bias timeframes are at or below the entry timeframe - ",
            "running on entry-timeframe structure only.");

   if(InpRowsVisible < 1 || InpRowHeight < 8)
   {
      Print("MarketFlow V8: invalid panel geometry.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpEmaFast < 1 || InpEmaSlow < 1 || InpEmaFast >= InpEmaSlow || InpRsiPeriod < 2)
   {
      Print("MarketFlow V8: invalid EMA/RSI filter parameters.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpSwingStrength < 1 || InpAtrPeriod < 1 || InpMaxAge < 1 || InpPoiLookback < 2)
   {
      Print("MarketFlow V8: invalid structure parameters.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpStatsBars > 0 && InpStatsMaxHold < 1)
   {
      Print("MarketFlow V8: back-test hold window must be at least 1 bar.");
      return INIT_PARAMETERS_INCORRECT;
   }

   IndicatorSetString(INDICATOR_SHORTNAME, "MarketFlow V8");

   g_win = ChartWindowFind();      // may still be -1 here; the timer resolves it

   LayoutColumns();
   ArrayResize(g_syms, 0);
   BuildUniverse();
   g_lastUniverse = TimeCurrent();

   BuildOrder();
   if(g_win >= 0)
   {
      DrawPanel();
      DrawWatermark();
      ChartRedraw();
   }

   EventSetTimer(1);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0, g_prefix);
   ChartRedraw();
}

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
   //--- the timer drives the scan; this keeps the charted symbol's outcome and
   //--- drawing live on every tick rather than once a second
   if(rates_total > 0)
   {
      for(int i = 0; i < ArraySize(g_syms); i++)
         if(g_syms[i].name == _Symbol)
         {
            RefreshStatus(g_syms[i]);
            break;
         }
      DrawChartTrade();
      ChartRedraw();
   }
   return rates_total;
}

bool SyncWindow()
{
   int w = ChartWindowFind();
   if(w < 0)
      return false;               // sub-window not established yet, do not draw
   if(w != g_win)
   {
      //--- our sub-window moved; objects cannot change window, so rebuild them
      g_win = w;
      ObjectsDeleteAll(0, g_prefix);
      g_tradeDrawn = false;
   }
   return true;
}

void OnTimer()
{
   if(!SyncWindow())
      return;

   if(TimeCurrent() - g_lastUniverse >= 10)
   {
      g_lastUniverse = TimeCurrent();
      BuildUniverse();
   }

   RunScanBudget();
   LogRejects();
   BuildOrder();
   DrawPanel();
   DrawChartTrade();
   DrawWatermark();
   ChartRedraw();
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK)
      return;
   if(StringFind(sparam, g_prefix) != 0)
      return;

   ObjectSetInteger(0, sparam, OBJPROP_STATE, false);

   int total     = ArraySize(g_order);
   int maxScroll = (int)MathMax(0, total - InpRowsVisible);

   if(sparam == g_prefix + "btn_up")
   {
      g_scroll = (int)MathMax(0, g_scroll - 1);
      DrawPanel();
      ChartRedraw();
      return;
   }
   if(sparam == g_prefix + "btn_down")
   {
      g_scroll = (int)MathMin(maxScroll, g_scroll + 1);
      DrawPanel();
      ChartRedraw();
      return;
   }
   if(sparam == g_prefix + "btn_pgup")
   {
      g_scroll = (int)MathMax(0, g_scroll - InpRowsVisible);
      DrawPanel();
      ChartRedraw();
      return;
   }
   if(sparam == g_prefix + "btn_pgdn")
   {
      g_scroll = (int)MathMin(maxScroll, g_scroll + InpRowsVisible);
      DrawPanel();
      ChartRedraw();
      return;
   }

   string openPrefix = g_prefix + "btn_open";
   if(StringFind(sparam, openPrefix) == 0)
   {
      int vis = (int)StringToInteger(StringSubstr(sparam, StringLen(openPrefix)));
      int idx = g_scroll + vis;
      if(idx >= 0 && idx < total)
      {
         string sym = g_syms[g_order[idx]].name;
         if(sym != _Symbol || g_tf != (ENUM_TIMEFRAMES)_Period)
            ChartSetSymbolPeriod(0, sym, g_tf);
      }
      ChartRedraw();
   }
}
//+------------------------------------------------------------------+
