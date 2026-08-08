//+------------------------------------------------------------------+
//|                                                 MarketFlowV8.mq5 |
//|              Market Watch signals scanner + trade projection (MT5) |
//+------------------------------------------------------------------+
//| Every number this indicator prints is derived from broker data:   |
//|                                                                   |
//|  * symbols come from Market Watch, not from a hardcoded list;     |
//|  * a row only shows a signal once its history is actually loaded  |
//|    - otherwise it says LOADING or NO DATA;                        |
//|  * SL/TP are normalised to the symbol tick size and pushed out to |
//|    respect SYMBOL_TRADE_STOPS_LEVEL, so they are placeable;       |
//|  * STATUS replays the bars after the signal and reports what the  |
//|    trade actually did (TP1/TP2/TP3/SL/ACTIVE);                    |
//|  * WR back-tests the identical rule over the last N bars of that  |
//|    symbol and shows the measured TP1-before-SL hit rate and the   |
//|    sample size, or n/a when the sample is too small to mean       |
//|    anything.                                                      |
//+------------------------------------------------------------------+
#property copyright "MarketFlow"
#property version   "8.10"
#property description "MarketFlow V8 - scans every Market Watch symbol in the background and"
#property description "publishes verified signals with entry, SL, TP1/TP2/TP3, live outcome"
#property description "status and a back-tested hit rate per symbol."
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

//+------------------------------------------------------------------+
//| Enums                                                            |
//+------------------------------------------------------------------+
enum ENUM_MF_SL
{
   MF_SL_ATR       = 0,  // ATR only
   MF_SL_STRUCTURE = 1,  // Swing structure only
   MF_SL_HYBRID    = 2   // Whichever of the two is further (safest)
};

enum ENUM_MF_SORT
{
   MF_SORT_LIST   = 0,   // Market Watch order
   MF_SORT_FRESH  = 1,   // Signals first, freshest, then score
   MF_SORT_SCORE  = 2    // Signals first, highest score
};

enum ENUM_MF_ENTRY
{
   MF_ENTRY_CLOSE  = 0,  // Close of the signal bar
   MF_ENTRY_MARKET = 1   // Live ask/bid captured when the signal prints
};

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Universe ==="
input bool              InpUseMarketWatch  = true;   // Scan every symbol in Market Watch
input string            InpSymbols         = "";     // Manual list (used when Market Watch is off)
input string            InpFilterInclude   = "";     // Only symbols containing this text ("" = all)
input string            InpFilterExclude   = "";     // Skip symbols containing this text
input bool              InpSkipUntradable  = true;   // Skip symbols with trading disabled
input int               InpMaxSymbols      = 250;    // Hard cap on scanned symbols
input int               InpSymbolsPerTick  = 6;      // Symbols analysed per second (background load)

input group "=== Scan ==="
input ENUM_TIMEFRAMES   InpTimeframe       = PERIOD_CURRENT; // Scan timeframe
input ENUM_TIMEFRAMES   InpHtfTimeframe    = PERIOD_CURRENT; // Confirmation timeframe (CURRENT = one step up)
input int               InpMaxAge          = 12;     // Keep a signal on the board for N bars
input int               InpMinScore        = 55;     // Minimum score to publish a signal (0-100)
input bool              InpOnlySignals     = false;  // Show only symbols that currently have a signal
input ENUM_MF_SORT      InpSortMode        = MF_SORT_FRESH; // Row order

input group "=== Signal engine ==="
input int               InpEmaFast         = 21;     // Fast EMA
input int               InpEmaSlow         = 50;     // Slow EMA
input int               InpAtrPeriod       = 14;     // ATR period
input int               InpRsiPeriod       = 14;     // RSI period
input double            InpRsiOverbought   = 70.0;   // RSI overbought (reversal sell)
input double            InpRsiOversold     = 30.0;   // RSI oversold (reversal buy)
input int               InpSwingLookback   = 12;     // Swing lookback for structure (bars)

input group "=== Risk model ==="
input ENUM_MF_ENTRY     InpEntryMode       = MF_ENTRY_CLOSE; // Entry price source
input ENUM_MF_SL        InpSLMode          = MF_SL_HYBRID;   // Stop loss placement
input double            InpSLAtrMult       = 1.5;    // ATR multiple for the stop
input double            InpTP1R            = 1.5;    // TP1 (R multiple)
input double            InpTP2R            = 2.5;    // TP2 (R multiple)
input double            InpTP3R            = 4.0;    // TP3 (R multiple)

input group "=== Measured hit rate ==="
input int               InpStatsBars       = 600;    // Back-test window in bars (0 = off)
input int               InpStatsMaxHold    = 60;     // Bars a back-tested trade may stay open
input int               InpStatsMinSamples = 8;      // Below this sample size WR shows n/a

input group "=== Panel ==="
input int               InpPanelX          = 6;      // Panel X (px from left)
input int               InpPanelY          = 6;      // Panel Y (px from bottom)
input int               InpRowsVisible     = 9;      // Visible rows
input int               InpRowHeight       = 18;     // Row height (px)
input string            InpFont            = "Consolas"; // Font
input int               InpFontSize        = 8;      // Font size
input bool              InpShowScore       = true;   // Show the SCORE column
input bool              InpShowWinRate     = true;   // Show the WR column
input bool              InpShowStatus      = true;   // Show the STATUS column

input group "=== Chart trade ==="
input bool              InpShowChartTrade  = true;   // Draw the chart symbol's trade
input bool              InpShowWatermark   = true;   // Draw the symbol/timeframe watermark
input int               InpBoxExtendBars   = 6;      // Extend the trade box N bars past the last bar

input group "=== Colors ==="
input color             InpClrPanelBg      = C'10,12,26';    // Panel background
input color             InpClrPanelBorder  = C'60,50,120';   // Panel border
input color             InpClrRowA         = C'16,18,38';    // Row background A
input color             InpClrRowB         = C'22,24,48';    // Row background B
input color             InpClrTitle        = C'190,180,255'; // Title text
input color             InpClrHeader       = C'130,120,190'; // Column header text
input color             InpClrText         = C'205,205,220'; // Row text
input color             InpClrDim          = C'110,110,130'; // Dimmed text
input color             InpClrBuy          = C'0,210,140';   // Buy color
input color             InpClrSell         = C'235,70,110';  // Sell color
input color             InpClrEntryLine    = C'160,45,60';   // Entry line color

input group "=== Alerts ==="
input bool              InpAlertPopup      = false;  // Popup alert on a new signal
input bool              InpAlertPush       = false;  // Push notification on a new signal

//+------------------------------------------------------------------+
//| Types                                                            |
//+------------------------------------------------------------------+
#define ST_SL      -1
#define ST_ACTIVE   0
#define ST_TP1      1
#define ST_TP2      2
#define ST_TP3      3

struct MFSignal
{
   bool     valid;
   int      dir;           // +1 buy, -1 sell
   bool     continuation;  // true continuation, false reversal
   int      barIndex;      // shift of the signal bar (1 = last closed bar)
   datetime time;
   double   entry;
   double   sl;
   double   tp1;
   double   tp2;
   double   tp3;
   int      score;         // 0..100
   bool     adjusted;      // levels widened to respect the broker stops level
   int      status;        // ST_*
};

struct MFSymbol
{
   string   name;
   bool     ok;            // resolved, selected, tradable
   bool     analysed;      // at least one completed analysis
   int      digits;
   double   point;
   double   tickSize;
   double   stopDist;      // SYMBOL_TRADE_STOPS_LEVEL in price units
   datetime lastBar;       // bar 0 time at the last full analysis
   datetime frozenSigTime; // signal the frozen market entry belongs to
   double   frozenEntry;
   int      statWins;
   int      statLosses;
   datetime lastAlert;
   string   note;          // LOADING / NO DATA / DISABLED, "" when analysed
   MFSignal sig;
};

//+------------------------------------------------------------------+
//| Column layout                                                    |
//+------------------------------------------------------------------+
#define NCOLS 13
#define C_SYMBOL 0
#define C_TF     1
#define C_SIGNAL 2
#define C_SCORE  3
#define C_WR     4
#define C_AGE    5
#define C_ENTRY  6
#define C_SL     7
#define C_TP1    8
#define C_TP2    9
#define C_TP3    10
#define C_STATUS 11
#define C_CHART  12

const string g_colTitle[NCOLS] = {"SYMBOL","TF","SIGNAL","SCORE","WR","AGE","ENTRY","SL","TP1","TP2","TP3","STATUS","CHART"};
const int    g_colWidth[NCOLS] = { 190,    44,  86,      52,     76,  92,   94,     94,  94,   94,   94,   76,      56 };

bool  g_colOn[NCOLS];
int   g_colX[NCOLS];
int   g_panelW = 900;

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
const string      g_prefix   = "MFV8_";
const int         g_titleH   = 24;
const int         g_headerH  = 20;

MFSymbol          g_syms[];
int               g_order[];
int               g_cursor   = 0;      // round-robin scan cursor
int               g_scroll   = 0;
ENUM_TIMEFRAMES   g_tf       = PERIOD_M15;
ENUM_TIMEFRAMES   g_htf      = PERIOD_H1;
string            g_tfText   = "";
datetime          g_lastUniverse = 0;

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
string TfToText(const ENUM_TIMEFRAMES tf)
{
   string s = EnumToString(tf);
   int p = StringFind(s, "_");
   return (p >= 0 ? StringSubstr(s, p + 1) : s);
}

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
      case PERIOD_M30: return PERIOD_H2;
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
bool EnsureObject(const string name, const ENUM_OBJECT type)
{
   if(ObjectFind(0, name) >= 0)
      return true;
   if(!ObjectCreate(0, name, type, 0, 0, 0))
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
//| Universe - Market Watch enumeration                              |
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
      int total = SymbolsTotal(true);          // true = Market Watch only
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

//--- returns true when the universe changed and rows were rebuilt
bool BuildUniverse()
{
   string names[];
   CollectNames(names);

   //--- unchanged?
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
         return false;
   }

   MFSymbol old[];
   ArrayResize(old, ArraySize(g_syms));
   for(int i = 0; i < ArraySize(g_syms); i++)
      old[i] = g_syms[i];

   ArrayResize(g_syms, ArraySize(names));
   for(int i = 0; i < ArraySize(names); i++)
   {
      MFSymbol r;
      r.name          = names[i];
      r.analysed      = false;
      r.lastBar       = 0;
      r.frozenSigTime = 0;
      r.frozenEntry   = 0.0;
      r.statWins      = 0;
      r.statLosses    = 0;
      r.lastAlert     = 0;
      r.note          = "LOADING";
      r.sig.valid     = false;
      r.sig.status    = ST_ACTIVE;

      r.ok = SymbolSelect(names[i], true);
      if(r.ok && InpSkipUntradable)
      {
         long mode = SymbolInfoInteger(names[i], SYMBOL_TRADE_MODE);
         if(mode == SYMBOL_TRADE_MODE_DISABLED)
         {
            r.ok   = false;
            r.note = "DISABLED";
         }
      }

      r.digits   = r.ok ? (int)SymbolInfoInteger(names[i], SYMBOL_DIGITS) : _Digits;
      r.point    = r.ok ? SymbolInfoDouble(names[i], SYMBOL_POINT) : _Point;
      r.tickSize = r.ok ? SymbolInfoDouble(names[i], SYMBOL_TRADE_TICK_SIZE) : r.point;
      if(r.tickSize <= 0.0)
         r.tickSize = r.point;
      r.stopDist = r.ok ? (double)SymbolInfoInteger(names[i], SYMBOL_TRADE_STOPS_LEVEL) * r.point : 0.0;

      //--- carry over anything we already computed for this symbol
      for(int j = 0; j < ArraySize(old); j++)
         if(old[j].name == r.name && old[j].analysed)
         {
            r.analysed      = old[j].analysed;
            r.lastBar       = old[j].lastBar;
            r.frozenSigTime = old[j].frozenSigTime;
            r.frozenEntry   = old[j].frozenEntry;
            r.statWins      = old[j].statWins;
            r.statLosses    = old[j].statLosses;
            r.lastAlert     = old[j].lastAlert;
            r.note          = old[j].note;
            r.sig           = old[j].sig;
            break;
         }

      g_syms[i] = r;
   }

   g_cursor = 0;
   g_scroll = 0;
   return true;
}

//+------------------------------------------------------------------+
//| Indicator math - computed inline so the scanner is not bound by   |
//| the terminal's per-chart indicator handle limit                   |
//| All arrays are series ordered: index 0 = newest bar               |
//+------------------------------------------------------------------+
void CalcEMA(const double &src[], const int n, const int period, double &out[])
{
   ArrayResize(out, n);
   if(n <= 0)
      return;
   double k = 2.0 / (period + 1.0);
   out[n - 1] = src[n - 1];
   for(int i = n - 2; i >= 0; i--)
      out[i] = src[i] * k + out[i + 1] * (1.0 - k);
}

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

void CalcRSI(const double &close[], const int n, const int period, double &out[])
{
   ArrayResize(out, n);
   if(n <= 0)
      return;
   double p  = (double)period;
   double ag = 0.0, al = 0.0;
   out[n - 1] = 50.0;
   for(int i = n - 2; i >= 0; i--)
   {
      double d = close[i] - close[i + 1];
      ag = (ag * (p - 1.0) + (d > 0.0 ?  d : 0.0)) / p;
      al = (al * (p - 1.0) + (d < 0.0 ? -d : 0.0)) / p;
      out[i] = (al <= 0.0) ? 100.0 : 100.0 - 100.0 / (1.0 + ag / al);
   }
}

//+------------------------------------------------------------------+
//| Structure helpers                                                |
//+------------------------------------------------------------------+
double SwingLow(const MqlRates &r[], const int n, const int i, const int look)
{
   double v = r[i].low;
   for(int k = i; k < MathMin(n, i + look); k++)
      v = MathMin(v, r[k].low);
   return v;
}

double SwingHigh(const MqlRates &r[], const int n, const int i, const int look)
{
   double v = r[i].high;
   for(int k = i; k < MathMin(n, i + look); k++)
      v = MathMax(v, r[k].high);
   return v;
}

bool IsSwingHigh(const MqlRates &r[], const int n, const int k)
{
   if(k < 2 || k > n - 3)
      return false;
   return (r[k].high > r[k - 1].high && r[k].high > r[k - 2].high &&
           r[k].high > r[k + 1].high && r[k].high > r[k + 2].high);
}

bool IsSwingLow(const MqlRates &r[], const int n, const int k)
{
   if(k < 2 || k > n - 3)
      return false;
   return (r[k].low < r[k - 1].low && r[k].low < r[k - 2].low &&
           r[k].low < r[k + 1].low && r[k].low < r[k + 2].low);
}

//--- is the path from entry to TP1 free of an opposing swing level?
bool PathIsClear(const MqlRates &r[], const int n, const int i, const int dir,
                 const double entry, const double tp1)
{
   int last = MathMin(n - 3, i + 50);
   for(int k = i + 1; k <= last; k++)
   {
      if(dir > 0 && IsSwingHigh(r, n, k) && r[k].high > entry && r[k].high < tp1)
         return false;
      if(dir < 0 && IsSwingLow(r, n, k) && r[k].low < entry && r[k].low > tp1)
         return false;
   }
   return true;
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
//| Setup detection - one place, used by both the live scan and the   |
//| back-test, so the published rule and the measured rule are the    |
//| same rule                                                         |
//+------------------------------------------------------------------+
bool DetectSetup(const MqlRates &r[], const double &emaF[], const double &emaS[],
                 const double &rsi[], const int n, const int i,
                 int &dir, bool &cont)
{
   if(i < 0 || i + 1 >= n)
      return false;

   bool up   = (emaF[i] > emaS[i]);
   bool down = (emaF[i] < emaS[i]);

   dir  = 0;
   cont = false;

   if(up && rsi[i] >= InpRsiOverbought &&
      r[i].close < r[i].open && r[i].close < r[i + 1].low)
   {
      dir = -1; cont = false;                       // reversal sell
   }
   else if(down && rsi[i] <= InpRsiOversold &&
           r[i].close > r[i].open && r[i].close > r[i + 1].high)
   {
      dir = +1; cont = false;                       // reversal buy
   }
   else if(up && r[i].low <= emaF[i] &&
           r[i].close > emaF[i] && r[i].close > r[i].open)
   {
      dir = +1; cont = true;                        // continuation buy
   }
   else if(down && r[i].high >= emaF[i] &&
           r[i].close < emaF[i] && r[i].close < r[i].open)
   {
      dir = -1; cont = true;                        // continuation sell
   }

   return (dir != 0);
}

//+------------------------------------------------------------------+
//| Full evaluation at bar i: levels + score                          |
//+------------------------------------------------------------------+
bool EvaluateAt(const MFSymbol &s, const MqlRates &r[], const int n, const int i,
                const double &emaF[], const double &emaS[],
                const double &rsi[], const double &atr[],
                const int &htfIdx[], const double &htfEmaF[], const double &htfEmaS[],
                const int m, MFSignal &out)
{
   out.valid = false;

   int  dir  = 0;
   bool cont = false;
   if(!DetectSetup(r, emaF, emaS, rsi, n, i, dir, cont))
      return false;
   if(atr[i] <= 0.0)
      return false;

   //--- entry
   double entry = r[i].close;

   //--- stop: ATR distance, structure distance, or the wider of the two
   double atrStop = atr[i] * InpSLAtrMult;
   double slPrice = 0.0;
   double buffer  = atr[i] * 0.15;

   if(dir > 0)
   {
      double byAtr    = entry - atrStop;
      double byStruct = SwingLow(r, n, i, InpSwingLookback) - buffer;
      if(InpSLMode == MF_SL_ATR)            slPrice = byAtr;
      else if(InpSLMode == MF_SL_STRUCTURE) slPrice = byStruct;
      else                                  slPrice = MathMin(byAtr, byStruct);
   }
   else
   {
      double byAtr    = entry + atrStop;
      double byStruct = SwingHigh(r, n, i, InpSwingLookback) + buffer;
      if(InpSLMode == MF_SL_ATR)            slPrice = byAtr;
      else if(InpSLMode == MF_SL_STRUCTURE) slPrice = byStruct;
      else                                  slPrice = MathMax(byAtr, byStruct);
   }

   double risk = MathAbs(entry - slPrice);
   if(risk <= 0.0)
      return false;

   //--- respect the broker's minimum stop distance so the levels are placeable
   bool adjusted = false;
   if(s.stopDist > 0.0 && risk < s.stopDist)
   {
      risk     = s.stopDist;
      slPrice  = entry - dir * risk;
      adjusted = true;
   }

   double tp1 = entry + dir * risk * InpTP1R;
   double tp2 = entry + dir * risk * InpTP2R;
   double tp3 = entry + dir * risk * InpTP3R;

   if(s.stopDist > 0.0)
   {
      if(MathAbs(tp1 - entry) < s.stopDist) { tp1 = entry + dir * s.stopDist; adjusted = true; }
      if(MathAbs(tp2 - tp1)   < s.stopDist) { tp2 = tp1   + dir * s.stopDist; adjusted = true; }
      if(MathAbs(tp3 - tp2)   < s.stopDist) { tp3 = tp2   + dir * s.stopDist; adjusted = true; }
   }

   //--- score
   int score = 40;

   int jj = MathMin(htfIdx[i] + 1, m - 1);          // last CLOSED htf bar: no look-ahead
   if(m > 1 && jj >= 0)
   {
      bool htfUp = (htfEmaF[jj] > htfEmaS[jj]);
      if((dir > 0 && htfUp) || (dir < 0 && !htfUp))
         score += 20;
   }

   double body = MathAbs(r[i].close - r[i].open);
   if(body >= atr[i] * 0.5)
      score += 10;

   double volAvg = 0.0;
   int    volN   = 0;
   for(int k = i + 1; k <= MathMin(n - 1, i + 20); k++)
   {
      volAvg += (double)r[k].tick_volume;
      volN++;
   }
   if(volN > 0)
   {
      volAvg /= volN;
      if(volAvg > 0.0 && (double)r[i].tick_volume >= volAvg * 1.2)
         score += 10;
   }

   if(cont)
   {
      if((dir > 0 && rsi[i] >= 45.0 && rsi[i] <= 70.0) ||
         (dir < 0 && rsi[i] >= 30.0 && rsi[i] <= 55.0))
         score += 10;
   }
   else
   {
      if((dir > 0 && rsi[i] <= 25.0) || (dir < 0 && rsi[i] >= 75.0))
         score += 10;
   }

   if(PathIsClear(r, n, i, dir, entry, tp1))
      score += 10;

   out.valid        = true;
   out.dir          = dir;
   out.continuation = cont;
   out.barIndex     = i;
   out.time         = r[i].time;
   out.entry        = NormPrice(s, entry);
   out.sl           = NormPrice(s, slPrice);
   out.tp1          = NormPrice(s, tp1);
   out.tp2          = NormPrice(s, tp2);
   out.tp3          = NormPrice(s, tp3);
   out.score        = (int)MathMin(100, score);
   out.adjusted     = adjusted;
   out.status       = ST_ACTIVE;
   return true;
}

//+------------------------------------------------------------------+
//| Replay the bars after a signal and report what actually happened  |
//| When a single bar touches both the stop and a target, the stop is |
//| counted first - the pessimistic reading, never the flattering one |
//+------------------------------------------------------------------+
int ReplayStatus(const MqlRates &r[], const int n, const MFSignal &sg, const int untilIndex)
{
   int st = ST_ACTIVE;
   for(int k = sg.barIndex - 1; k >= untilIndex; k--)
   {
      if(k < 0 || k >= n)
         continue;
      if(sg.dir > 0)
      {
         if(r[k].low  <= sg.sl)  return ST_SL;
         if(r[k].high >= sg.tp3) return ST_TP3;
         if(r[k].high >= sg.tp2) st = MathMax(st, ST_TP2);
         else if(r[k].high >= sg.tp1) st = MathMax(st, ST_TP1);
      }
      else
      {
         if(r[k].high >= sg.sl)  return ST_SL;
         if(r[k].low  <= sg.tp3) return ST_TP3;
         if(r[k].low  <= sg.tp2) st = MathMax(st, ST_TP2);
         else if(r[k].low <= sg.tp1) st = MathMax(st, ST_TP1);
      }
   }
   return st;
}

//--- +1 target first, -1 stop first, 0 unresolved inside the hold window
int BacktestOutcome(const MqlRates &r[], const int n, const MFSignal &sg)
{
   int stop = MathMax(0, sg.barIndex - InpStatsMaxHold);
   for(int k = sg.barIndex - 1; k >= stop; k--)
   {
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
//| Full analysis of one symbol (runs in the background scheduler)    |
//+------------------------------------------------------------------+
void AnalyseSymbol(MFSymbol &s)
{
   s.sig.valid = false;

   if(!s.ok)
   {
      if(s.note == "" || s.note == "LOADING")
         s.note = "DISABLED";
      return;
   }

   int warmup   = MathMax(InpEmaSlow * 4, 120);
   int statsWin = (InpStatsBars > 0 ? InpStatsBars + InpStatsMaxHold : 0);
   int need     = MathMax(InpMaxAge + warmup, statsWin + warmup);

   MqlRates r[];
   ArraySetAsSeries(r, true);
   int got = CopyRates(s.name, g_tf, 0, need, r);

   //--- never invent a signal from history we do not have
   if(got < warmup + InpMaxAge + 2)
   {
      s.note = (got <= 0 ? "LOADING" : "SHORT HIST");
      return;
   }
   int n = got;

   double close[];
   ArrayResize(close, n);
   for(int i = 0; i < n; i++)
      close[i] = r[i].close;

   double emaF[], emaS[], rsi[], atr[];
   CalcEMA(close, n, InpEmaFast, emaF);
   CalcEMA(close, n, InpEmaSlow, emaS);
   CalcRSI(close, n, InpRsiPeriod, rsi);
   CalcATR(r,     n, InpAtrPeriod, atr);

   //--- higher timeframe trend, mapped bar by bar without look-ahead
   MqlRates hr[];
   ArraySetAsSeries(hr, true);
   int m = CopyRates(s.name, g_htf, 0, (int)MathMax(120, need / 3), hr);

   double htfEmaF[], htfEmaS[];
   int    htfIdx[];
   ArrayResize(htfIdx, n);

   if(m > InpEmaSlow + 2)
   {
      double hclose[];
      ArrayResize(hclose, m);
      for(int i = 0; i < m; i++)
         hclose[i] = hr[i].close;
      CalcEMA(hclose, m, InpEmaFast, htfEmaF);
      CalcEMA(hclose, m, InpEmaSlow, htfEmaS);

      int j = m - 1;
      for(int i = n - 1; i >= 0; i--)
      {
         while(j > 0 && hr[j - 1].time <= r[i].time)
            j--;
         htfIdx[i] = j;
      }
   }
   else
   {
      m = 0;
      ArrayResize(htfEmaF, 1);
      ArrayResize(htfEmaS, 1);
      htfEmaF[0] = 0.0;
      htfEmaS[0] = 0.0;
      ArrayInitialize(htfIdx, 0);
   }

   //--- newest qualifying signal
   MFSignal sg;
   for(int i = 1; i <= InpMaxAge; i++)
   {
      if(!EvaluateAt(s, r, n, i, emaF, emaS, rsi, atr, htfIdx, htfEmaF, htfEmaS, m, sg))
         continue;
      if(sg.score < InpMinScore)
         continue;

      //--- optional live entry, captured once and then frozen
      if(InpEntryMode == MF_ENTRY_MARKET && i == 1)
      {
         if(s.frozenSigTime != sg.time)
         {
            double px = (sg.dir > 0 ? SymbolInfoDouble(s.name, SYMBOL_ASK)
                                    : SymbolInfoDouble(s.name, SYMBOL_BID));
            if(px > 0.0)
            {
               s.frozenSigTime = sg.time;
               s.frozenEntry   = px;
            }
         }
         if(s.frozenSigTime == sg.time && s.frozenEntry > 0.0)
         {
            double shift = s.frozenEntry - sg.entry;
            sg.entry = NormPrice(s, s.frozenEntry);
            sg.sl    = NormPrice(s, sg.sl  + shift);
            sg.tp1   = NormPrice(s, sg.tp1 + shift);
            sg.tp2   = NormPrice(s, sg.tp2 + shift);
            sg.tp3   = NormPrice(s, sg.tp3 + shift);
         }
      }

      sg.status = ReplayStatus(r, n, sg, 0);
      s.sig     = sg;
      break;
   }

   //--- measured hit rate of the exact same rule over the back-test window
   if(InpStatsBars > 0)
   {
      int wins = 0, losses = 0;
      int from = MathMin(n - 3, InpStatsBars + InpStatsMaxHold);
      MFSignal bs;
      int i = from;
      while(i > InpStatsMaxHold)
      {
         if(EvaluateAt(s, r, n, i, emaF, emaS, rsi, atr, htfIdx, htfEmaF, htfEmaS, m, bs) &&
            bs.score >= InpMinScore)
         {
            int res = BacktestOutcome(r, n, bs);
            if(res > 0)      wins++;
            else if(res < 0) losses++;
            i -= 3;                    // small cooldown so one move is not counted repeatedly
            continue;
         }
         i--;
      }
      s.statWins   = wins;
      s.statLosses = losses;
   }

   s.analysed = true;
   s.note     = "";
   s.lastBar  = r[0].time;

   //--- alert once, only for a signal that printed on the last closed bar
   if(s.sig.valid && s.sig.barIndex == 1 && s.sig.time != s.lastAlert)
   {
      s.lastAlert = s.sig.time;
      string msg = StringFormat("MarketFlow V8 | %s %s | %s %s (score %d) | entry %s  SL %s  TP1 %s",
                                s.name, g_tfText,
                                (s.sig.dir > 0 ? "BUY" : "SELL"),
                                (s.sig.continuation ? "CONTINUATION" : "REVERSAL"),
                                s.sig.score,
                                DoubleToString(s.sig.entry, s.digits),
                                DoubleToString(s.sig.sl,    s.digits),
                                DoubleToString(s.sig.tp1,   s.digits));
      if(InpAlertPopup) Alert(msg);
      if(InpAlertPush)  SendNotification(msg);
   }
}

//--- cheap intrabar refresh of the outcome status only
void RefreshStatus(MFSymbol &s)
{
   if(!s.ok || !s.sig.valid)
      return;
   int need = s.sig.barIndex + 2;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(s.name, g_tf, 0, need, r) < need)
      return;
   s.sig.status = ReplayStatus(r, need, s.sig, 0);
}

//+------------------------------------------------------------------+
//| Background scheduler                                             |
//+------------------------------------------------------------------+
void RunScanBudget()
{
   int total = ArraySize(g_syms);
   if(total == 0)
      return;

   int budget = MathMax(1, InpSymbolsPerTick);
   int looked = 0;

   while(budget > 0 && looked < total)
   {
      int i = g_cursor;
      g_cursor = (g_cursor + 1) % total;
      looked++;

      if(!g_syms[i].ok)
         continue;

      datetime bar0 = (datetime)SeriesInfoInteger(g_syms[i].name, g_tf, SERIES_LASTBAR_DATE);
      if(g_syms[i].analysed && bar0 != 0 && bar0 == g_syms[i].lastBar)
         continue;                       // nothing new on this symbol

      AnalyseSymbol(g_syms[i]);
      budget--;
   }

   //--- keep the live outcome column honest between bars
   for(int i = 0; i < total; i++)
      if(g_syms[i].sig.valid)
         RefreshStatus(g_syms[i]);
}

//+------------------------------------------------------------------+
//| Row ordering                                                     |
//+------------------------------------------------------------------+
int RankOf(const MFSymbol &s)
{
   if(!s.sig.valid)
      return 1000000;
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
string SignalText(const MFSignal &s)
{
   if(!s.valid)
      return "-";
   string head = (s.dir > 0 ? ShortToString(0x25B2) + " BUY" : ShortToString(0x25BC) + " SELL");
   return head + (s.continuation ? "+" : "-");
}

string AgeText(const MFSignal &s)
{
   if(!s.valid)
      return "-";
   if(s.barIndex <= 1)
      return "current";
   return StringFormat("%d bars ago", s.barIndex - 1);
}

string StatusText(const MFSignal &s)
{
   if(!s.valid)
      return "-";
   switch(s.status)
   {
      case ST_SL:  return "SL HIT";
      case ST_TP1: return "TP1 HIT";
      case ST_TP2: return "TP2 HIT";
      case ST_TP3: return "TP3 HIT";
   }
   return "ACTIVE";
}

color StatusColor(const MFSignal &s)
{
   if(!s.valid)
      return InpClrDim;
   if(s.status == ST_SL)
      return InpClrSell;
   if(s.status > ST_ACTIVE)
      return InpClrBuy;
   return InpClrText;
}

string WinRateText(const MFSymbol &s)
{
   if(InpStatsBars <= 0)
      return "off";
   int total = s.statWins + s.statLosses;
   if(total < InpStatsMinSamples)
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
   int H = PanelHeight();
   SetRect(g_prefix + "bg", InpPanelX, InpPanelY, g_panelW, H, InpClrPanelBg, InpClrPanelBorder);

   //--- counters, so the panel always says what it has and has not done
   int nSyms = ArraySize(g_syms);
   int nDone = 0, nSig = 0;
   for(int i = 0; i < nSyms; i++)
   {
      if(g_syms[i].analysed) nDone++;
      if(g_syms[i].sig.valid) nSig++;
   }

   string title = StringFormat("%s MARKETFLOW V8  |  SIGNALS DASHBOARD  |  %s  |  %s  |  %d signals  |  analysed %d/%d",
                               ShortToString(0x25C8), g_tfText,
                               TimeToString(TimeCurrent(), TIME_MINUTES),
                               nSig, nDone, nSyms);
   SetLabel(g_prefix + "title", InpPanelX + 8, InpPanelY + H - g_titleH + 7, title,
            InpClrTitle, InpFontSize + 1);

   int total = ArraySize(g_order);
   int shown = (int)MathMin(InpRowsVisible, (int)MathMax(0, total - g_scroll));
   int from  = (total == 0 ? 0 : g_scroll + 1);
   int to    = g_scroll + shown;

   int btnY = InpPanelY + H - g_titleH + 3;
   SetButton(g_prefix + "btn_up",   InpPanelX + g_panelW - 132, btnY, 18, 16,
             ShortToString(0x25B2), InpClrRowB, InpClrTitle);
   SetButton(g_prefix + "btn_down", InpPanelX + g_panelW - 112, btnY, 18, 16,
             ShortToString(0x25BC), InpClrRowB, InpClrTitle);
   SetLabel(g_prefix + "page", InpPanelX + g_panelW - 88, InpPanelY + H - g_titleH + 7,
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
      SetRect(rowBg, InpPanelX + 4, base - 4, g_panelW - 8, InpRowHeight,
              ((i % 2) == 0 ? InpClrRowA : InpClrRowB), InpClrPanelBg);
      ObjShow(rowBg, has);

      string btn = g_prefix + "btn_open" + suf;

      if(!has)
      {
         for(int c = 0; c < NCOLS; c++)
            ObjShow(g_prefix + "c" + IntegerToString(c) + "_" + suf, false);
         ObjShow(btn, false);
         continue;
      }

      MFSymbol s  = g_syms[g_order[idx]];
      bool     sv = s.sig.valid;
      color    sc = (!sv ? InpClrDim : (s.sig.dir > 0 ? InpClrBuy : InpClrSell));

      string cell[NCOLS];
      cell[C_SYMBOL] = s.name;
      cell[C_TF]     = g_tfText;
      cell[C_SIGNAL] = (s.note != "" ? s.note : SignalText(s.sig));
      cell[C_SCORE]  = sv ? IntegerToString(s.sig.score) : "-";
      cell[C_WR]     = s.analysed ? WinRateText(s) : "-";
      cell[C_AGE]    = (s.note != "" ? "" : AgeText(s.sig));
      cell[C_ENTRY]  = PriceText(s, s.sig.entry);
      cell[C_SL]     = PriceText(s, s.sig.sl) + (sv && s.sig.adjusted ? "*" : "");
      cell[C_TP1]    = PriceText(s, s.sig.tp1);
      cell[C_TP2]    = PriceText(s, s.sig.tp2);
      cell[C_TP3]    = PriceText(s, s.sig.tp3);
      cell[C_STATUS] = StatusText(s.sig);
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
         if(c == C_SYMBOL)                       clr = (sv ? InpClrTitle : InpClrDim);
         if(c == C_SIGNAL)                       clr = (s.note != "" ? InpClrDim : sc);
         if(c == C_SCORE || c == C_AGE)          clr = sc;
         if(c >= C_ENTRY && c <= C_TP3)          clr = (sv ? sc : InpClrDim);
         if(c == C_SL && sv)                     clr = InpClrSell;
         if(c == C_WR)                           clr = InpClrText;
         if(c == C_STATUS)                       clr = StatusColor(s.sig);

         SetLabel(cn, InpPanelX + g_colX[c], base, cell[c], clr, InpFontSize);
      }

      SetButton(btn, InpPanelX + g_colX[C_CHART], base - 3, 50, InpRowHeight - 3,
                "OPEN", InpClrRowB, InpClrTitle);
   }
}

//+------------------------------------------------------------------+
//| Chart trade projection                                           |
//+------------------------------------------------------------------+
void ClearChartTrade()
{
   ObjectsDeleteAll(0, g_prefix + "tr_");
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

   int legendY = InpPanelY + PanelHeight() + 8;
   SetLabel(g_prefix + "tr_leg1", InpPanelX + 8, legendY + 32,
            ShortToString(0x25C8) + " TRADE", InpClrTitle, InpFontSize + 1);
   SetLabel(g_prefix + "tr_leg2", InpPanelX + 8, legendY + 16,
            StringFormat("%s %s   score %d   %s",
                         SignalText(sg),
                         (sg.continuation ? "CONTINUATION" : "REVERSAL"),
                         sg.score, StatusText(sg)),
            clr, InpFontSize + 1);
   SetLabel(g_prefix + "tr_leg3", InpPanelX + 8, legendY,
            StringFormat("risk %s   R:R to TP1 %.1f   measured %s",
                         DoubleToString(MathAbs(sg.entry - sg.sl), s.digits),
                         (MathAbs(sg.entry - sg.sl) > 0.0
                            ? MathAbs(sg.tp1 - sg.entry) / MathAbs(sg.entry - sg.sl) : 0.0),
                         WinRateText(s)),
            InpClrDim, InpFontSize);
}

void DrawWatermark()
{
   string wm = g_prefix + "watermark";
   if(!InpShowWatermark)
   {
      ObjectDelete(0, wm);
      return;
   }
   SetLabel(wm, 20, 24, _Symbol + "   |   " + TfToText((ENUM_TIMEFRAMES)_Period),
            C'120,110,180', 14, CORNER_RIGHT_UPPER, ANCHOR_RIGHT_UPPER);
}

//+------------------------------------------------------------------+
//| Lifecycle                                                        |
//+------------------------------------------------------------------+
int OnInit()
{
   g_tf     = (InpTimeframe == PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : InpTimeframe);
   g_htf    = (InpHtfTimeframe == PERIOD_CURRENT ? NextTimeframeUp(g_tf) : InpHtfTimeframe);
   g_tfText = TfToText(g_tf);

   if(InpRowsVisible < 1 || InpRowHeight < 8)
   {
      Print("MarketFlow V8: invalid panel geometry.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpEmaFast < 1 || InpEmaSlow < 1 || InpEmaFast >= InpEmaSlow)
   {
      Print("MarketFlow V8: fast EMA must be shorter than slow EMA.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpMaxAge < 1 || InpAtrPeriod < 1 || InpRsiPeriod < 1 || InpSwingLookback < 2)
   {
      Print("MarketFlow V8: invalid signal engine parameters.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpStatsBars > 0 && InpStatsMaxHold < 1)
   {
      Print("MarketFlow V8: back-test hold window must be at least 1 bar.");
      return INIT_PARAMETERS_INCORRECT;
   }

   IndicatorSetString(INDICATOR_SHORTNAME, "MarketFlow V8");

   LayoutColumns();
   ArrayResize(g_syms, 0);
   BuildUniverse();
   g_lastUniverse = TimeCurrent();

   BuildOrder();
   DrawPanel();
   DrawWatermark();
   ChartRedraw();

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
   return rates_total;
}

void OnTimer()
{
   //--- Market Watch can change while we run
   if(TimeCurrent() - g_lastUniverse >= 30)
   {
      g_lastUniverse = TimeCurrent();
      BuildUniverse();
   }

   RunScanBudget();
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
