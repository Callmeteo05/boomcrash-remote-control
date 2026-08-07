//+------------------------------------------------------------------+
//|                                            CRT_Sniper_Lite.mq5   |
//|        Clean BUY / SELL signals with SL and TP marked on chart   |
//+------------------------------------------------------------------+
#property copyright   "CRT Sniper Lite"
#property version     "1.00"
#property description "Two verified price-action models, one quality dial."
#property description "Prints BUY / SELL with SL and TP levels drawn on the chart."
#property description "Signals are decided on the close of a bar and never move afterwards."
#property indicator_chart_window
#property indicator_buffers 7
#property indicator_plots   2

#property indicator_label1  "Buy"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrRoyalBlue
#property indicator_width1  2
#property indicator_label2  "Sell"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrRed
#property indicator_width2  2

#define PFX     "CRTL_"
#define MAXSIG  256

#define TR_RANGE 0
#define TR_UP    1
#define TR_DOWN  2

#define M_TPB   0   // trend pullback
#define M_SWEEP 1   // liquidity sweep + reclaim

//+------------------------------------------------------------------+
//| Inputs - deliberately few                                        |
//+------------------------------------------------------------------+
input group "=== Signal quality ==="
input int             InpMinScore     = 70;              // Signal quality 0-100 (higher = fewer, stronger)
input int             InpCooldown     = 5;               // Minimum bars between signals

input group "=== Entry models ==="
input bool            InpUseTPB       = true;            // Trend pullback to EMA 50
input bool            InpUseSweep     = true;            // Liquidity sweep + reclaim

input group "=== Trend ==="
input ENUM_TIMEFRAMES InpHTF          = PERIOD_CURRENT;  // Higher timeframe (PERIOD_CURRENT = auto)
input int             InpEmaFast      = 50;              // EMA fast
input int             InpEmaSlow      = 200;             // EMA slow
input double          InpMinSepATR    = 0.15;            // Min EMA gap to call a trend (x ATR)

input group "=== Entry location ==="
input int             InpRangeLook    = 50;              // Range lookback for premium / discount (bars)
input double          InpMaxBuyLoc    = 0.55;            // Buy only below this point in the range
input double          InpMinSellLoc   = 0.45;            // Sell only above this point in the range

input group "=== Stop loss and targets ==="
input int             InpAtrPeriod    = 14;              // ATR period
input int             InpSwingLen     = 3;               // Swing strength (bars each side)
input int             InpSlLookback   = 6;               // Structural SL lookback (bars)
input double          InpSlBufATR     = 0.30;            // SL buffer beyond structure (x ATR)
input double          InpRR1          = 2.0;             // TP1 (R multiple)
input double          InpRR2          = 3.0;             // TP2 (R multiple)

input group "=== Display ==="
input bool            InpShowArrows   = true;            // Arrows at the signal
input bool            InpShowLabels   = true;            // BUY / SELL text
input bool            InpShowLevels   = true;            // SL and TP lines with labels
input int             InpLastN        = 12;              // Draw levels for the last N signals
input int             InpLevelBars    = 20;              // Level line length (bars)
input bool            InpShowPanel    = true;            // Show the small info panel
input color           InpBuyColor     = clrRoyalBlue;    // Buy colour
input color           InpSellColor    = clrRed;          // Sell colour
input color           InpTPColor      = clrRed;          // TP colour
input color           InpSLColor      = clrGray;         // SL colour
input int             InpFontSize     = 8;               // Font size
input int             InpMaxBars      = 5000;            // History bars to calculate

input group "=== Alerts ==="
input bool            InpAlertPopup   = true;            // Popup alert
input bool            InpAlertPush    = false;           // Push notification
input bool            InpAlertSound   = true;            // Sound alert

//+------------------------------------------------------------------+
//| Buffers                                                          |
//+------------------------------------------------------------------+
double BufBuy[], BufSell[], BufSL[], BufTP1[], BufTP2[], BufDir[], BufScore[];

//+------------------------------------------------------------------+
//| State                                                            |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES g_htf = PERIOD_H4;
int g_hFast = INVALID_HANDLE, g_hSlow = INVALID_HANDLE, g_hAtr = INVALID_HANDLE;
int g_hHtfEma = INVALID_HANDLE;

double g_fast[], g_slow[], g_atr[], g_htfEma[];

double g_swHigh = 0.0, g_swLow = 0.0;
int    g_swHighBar = -1, g_swLowBar = -1;
int    g_lastSigBar = -100000;
int    g_lastProc = -1;

struct Sig
  {
   datetime t;
   int      dir;
   int      model;
   int      score;
   double   entry, sl, tp1, tp2;
   string   why;
  };
Sig      g_sig[MAXSIG];
int      g_sigN = 0;
datetime g_lastAlert = 0;

int      g_dTrend = TR_RANGE, g_dHtf = TR_RANGE;
double   g_dLoc = 0.5, g_dAtr = 0.0;

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
double SV(const double &a[], const int rt, const int i)
  {
   int j = rt - 1 - i;
   int n = ArraySize(a);
   return (j < 0 || j >= n ? 0.0 : a[j]);
  }

double Hi(const double &a[], int f, int t, const int n)
  {
   if(f < 0) f = 0;
   if(t > n - 1) t = n - 1;
   double v = -DBL_MAX;
   for(int k = f; k <= t; k++) if(a[k] > v) v = a[k];
   return (v == -DBL_MAX ? 0.0 : v);
  }

double Lo(const double &a[], int f, int t, const int n)
  {
   if(f < 0) f = 0;
   if(t > n - 1) t = n - 1;
   double v = DBL_MAX;
   for(int k = f; k <= t; k++) if(a[k] < v) v = a[k];
   return (v == DBL_MAX ? 0.0 : v);
  }

double Clamp01(const double v) { return (v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v)); }

string TfName(const ENUM_TIMEFRAMES tf)
  {
   string s = EnumToString(tf);
   StringReplace(s, "PERIOD_", "");
   return s;
  }

ENUM_TIMEFRAMES AutoHTF(const ENUM_TIMEFRAMES c)
  {
   int s = PeriodSeconds(c);
   if(s <= 300)   return PERIOD_H1;
   if(s <= 1800)  return PERIOD_H4;
   if(s <= 14400) return PERIOD_D1;
   return PERIOD_W1;
  }

string ModelName(const int m)
  {
   if(m == M_SWEEP) return "Liquidity sweep";
   return "Trend pullback";
  }

string TrendName(const int t)
  {
   if(t == TR_UP)   return "BULLISH";
   if(t == TR_DOWN) return "BEARISH";
   return "NO TREND";
  }

color TrendColor(const int t)
  {
   if(t == TR_UP)   return InpBuyColor;
   if(t == TR_DOWN) return InpSellColor;
   return clrGoldenrod;
  }

//+------------------------------------------------------------------+
//| Candlestick confirmation - returns "" when there is none         |
//+------------------------------------------------------------------+
string BullCandle(const double &o[], const double &h[], const double &l[],
                  const double &c[], const int i, const double atr)
  {
   if(i < 2 || atr <= 0.0) return "";
   double body = MathAbs(c[i] - o[i]);
   double rng  = h[i] - l[i];
   if(rng <= 0.0) return "";
   double up = h[i] - MathMax(o[i], c[i]);
   double dn = MathMin(o[i], c[i]) - l[i];

   if(c[i] > o[i] && c[i-1] < o[i-1] && c[i] >= o[i-1] && o[i] <= c[i-1] && body > 0.3 * atr)
      return "bullish engulfing";
   if(dn >= 2.0 * body && up <= 0.6 * body && c[i] >= l[i] + 0.6 * rng)
      return "hammer";
   if(c[i-1] < o[i-1] && o[i] < c[i-1] && c[i] > (o[i-1] + c[i-1]) * 0.5 && c[i] < o[i-1])
      return "piercing";
   if(dn >= 0.45 * rng && c[i] > o[i] && rng > 0.45 * atr)
      return "rejection wick";
   if(h[i-1] < h[i-2] && l[i-1] > l[i-2] && c[i] > h[i-1] && c[i] > o[i])
      return "inside bar break";
   if(MathAbs(l[i] - l[i-1]) <= 0.12 * atr && c[i] > o[i] && c[i-1] < o[i-1])
      return "double bottom bar";
   if(body > 0.45 * rng && c[i] >= l[i] + 0.7 * rng && body > 0.35 * atr)
      return "momentum close";
   return "";
  }

string BearCandle(const double &o[], const double &h[], const double &l[],
                  const double &c[], const int i, const double atr)
  {
   if(i < 2 || atr <= 0.0) return "";
   double body = MathAbs(c[i] - o[i]);
   double rng  = h[i] - l[i];
   if(rng <= 0.0) return "";
   double up = h[i] - MathMax(o[i], c[i]);
   double dn = MathMin(o[i], c[i]) - l[i];

   if(c[i] < o[i] && c[i-1] > o[i-1] && c[i] <= o[i-1] && o[i] >= c[i-1] && body > 0.3 * atr)
      return "bearish engulfing";
   if(up >= 2.0 * body && dn <= 0.6 * body && c[i] <= h[i] - 0.6 * rng)
      return "shooting star";
   if(c[i-1] > o[i-1] && o[i] > c[i-1] && c[i] < (o[i-1] + c[i-1]) * 0.5 && c[i] > o[i-1])
      return "dark cloud";
   if(up >= 0.45 * rng && c[i] < o[i] && rng > 0.45 * atr)
      return "rejection wick";
   if(h[i-1] < h[i-2] && l[i-1] > l[i-2] && c[i] < l[i-1] && c[i] < o[i])
      return "inside bar break";
   if(MathAbs(h[i] - h[i-1]) <= 0.12 * atr && c[i] < o[i] && c[i-1] > o[i-1])
      return "double top bar";
   if(body > 0.45 * rng && c[i] <= h[i] - 0.7 * rng && body > 0.35 * atr)
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
//| Score : five equal parts, 20 points each                         |
//+------------------------------------------------------------------+
//--- five parts, 20 points each. Every part must be able to vary, otherwise
//--- it contributes nothing and silently shrinks the usable score range.
int Score(const double trendQ, const double locDepth, const string candle,
          const double trigger, const double rrToTp2)
  {
   return (int)MathRound(20.0 * Clamp01(trendQ))
          + (int)MathRound(20.0 * Clamp01(locDepth))
          + CandleStrength(candle)
          + (int)MathRound(20.0 * Clamp01(trigger))
          + (int)MathRound(20.0 * Clamp01(rrToTp2 / 3.0));
  }

//+------------------------------------------------------------------+
//| Drawing                                                          |
//+------------------------------------------------------------------+
void Txt(const string nm, const datetime t, const double p, const string s,
         const color c, const int size, const ENUM_ANCHOR_POINT a)
  {
   if(ObjectFind(0, nm) < 0) ObjectCreate(0, nm, OBJ_TEXT, 0, t, p);
   ObjectSetInteger(0, nm, OBJPROP_TIME, 0, t);
   ObjectSetDouble(0, nm, OBJPROP_PRICE, 0, p);
   ObjectSetString(0, nm, OBJPROP_TEXT, s);
   ObjectSetString(0, nm, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, c);
   ObjectSetInteger(0, nm, OBJPROP_ANCHOR, a);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
  }

void Seg(const string nm, const datetime t1, const double p1,
         const datetime t2, const double p2, const color c,
         const int style, const int width)
  {
   if(ObjectFind(0, nm) < 0) ObjectCreate(0, nm, OBJ_TREND, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, nm, OBJPROP_TIME, 0, t1);
   ObjectSetDouble(0, nm, OBJPROP_PRICE, 0, p1);
   ObjectSetInteger(0, nm, OBJPROP_TIME, 1, t2);
   ObjectSetDouble(0, nm, OBJPROP_PRICE, 1, p2);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, c);
   ObjectSetInteger(0, nm, OBJPROP_STYLE, style);
   ObjectSetInteger(0, nm, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, nm, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, nm, OBJPROP_RAY_LEFT, false);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
  }

void DrawSignals(const bool force)
  {
   static int drawn = -1;
   if(!force && drawn == g_sigN) return;
   drawn = g_sigN;

   ObjectsDeleteAll(0, PFX + "s_");
   if(g_sigN == 0) return;

   int span = MathMax(4, InpLevelBars) * PeriodSeconds(_Period);
   int show = (InpLastN < g_sigN ? InpLastN : g_sigN);

   for(int k = g_sigN - show; k < g_sigN; k++)
     {
      Sig s = g_sig[k];
      string id = PFX + "s_" + IntegerToString(k) + "_";
      color  cc = (s.dir > 0 ? InpBuyColor : InpSellColor);
      datetime t2 = s.t + span;

      //--- BUY / SELL wording at the signal candle
      if(InpShowLabels)
         Txt(id + "tag", s.t, (s.dir > 0 ? s.sl : s.tp2), (s.dir > 0 ? "BUY" : "SELL"),
             cc, InpFontSize + 2, (s.dir > 0 ? ANCHOR_UPPER : ANCHOR_LOWER));

      if(!InpShowLevels)
         continue;

      //--- the vertical run from entry out to the far target
      Seg(id + "v", s.t, s.entry, s.t, s.tp2, cc, STYLE_SOLID, 1);

      //--- stop and targets, each with its own tick and wording
      Seg(id + "sl",  s.t, s.sl,  t2, s.sl,  InpSLColor, STYLE_DOT,   1);
      Seg(id + "tp1", s.t, s.tp1, t2, s.tp1, InpTPColor, STYLE_SOLID, 1);
      Seg(id + "tp2", s.t, s.tp2, t2, s.tp2, InpTPColor, STYLE_SOLID, 1);

      Txt(id + "lsl",  t2, s.sl,  " SL",  InpSLColor, InpFontSize, ANCHOR_LEFT);
      Txt(id + "ltp1", t2, s.tp1, " TP",  InpTPColor, InpFontSize, ANCHOR_LEFT);
      Txt(id + "ltp2", t2, s.tp2, " TP",  InpTPColor, InpFontSize, ANCHOR_LEFT);
     }
  }

void Row(const int idx, const string s, const color c)
  {
   string nm = PFX + "r" + IntegerToString(idx);
   if(ObjectFind(0, nm) < 0) ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, 16 + idx * (InpFontSize + 6));
   ObjectSetString(0, nm, OBJPROP_TEXT, s);
   ObjectSetString(0, nm, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, InpFontSize);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, c);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
  }

void DrawPanel()
  {
   if(!InpShowPanel)
     {
      ObjectsDeleteAll(0, PFX + "r");
      return;
     }

   int r = 0;
   Row(r++, "CRT Sniper Lite  -  " + _Symbol + " " + TfName((ENUM_TIMEFRAMES)_Period), clrWhite);
   Row(r++, "Trend " + TfName(g_htf) + ": " + TrendName(g_dHtf) +
       "   Chart: " + TrendName(g_dTrend), TrendColor(g_dHtf));
   Row(r++, StringFormat("Location: %.0f%% of range   (buy low, sell high)", g_dLoc * 100.0),
       (g_dLoc < 0.45 ? InpBuyColor : (g_dLoc > 0.55 ? InpSellColor : clrGoldenrod)));

   if(g_sigN > 0)
     {
      Sig s = g_sig[g_sigN-1];
      color cc = (s.dir > 0 ? InpBuyColor : InpSellColor);
      Row(r++, StringFormat("Last: %s %s   quality %d/100   %s",
                            (s.dir > 0 ? "BUY" : "SELL"), DoubleToString(s.entry, _Digits),
                            s.score, ModelName(s.model)), cc);
      Row(r++, StringFormat("SL %s   TP1 %s   TP2 %s",
                            DoubleToString(s.sl, _Digits), DoubleToString(s.tp1, _Digits),
                            DoubleToString(s.tp2, _Digits)), clrSilver);
      Row(r++, "Why: " + s.why, C'170,190,220');
     }
   else
      Row(r++, "Waiting for a setup...", clrSilver);

   Row(r++, StringFormat("Quality filter: %d   Signals on bar close, never repaint", InpMinScore),
       C'130,140,160');

   static int last = 0;
   for(int k = r; k < last; k++) ObjectDelete(0, PFX + "r" + IntegerToString(k));
   last = r;
  }

//+------------------------------------------------------------------+
//| Alerts                                                           |
//+------------------------------------------------------------------+
void Fire(const Sig &s)
  {
   if(s.t <= g_lastAlert) return;
   g_lastAlert = s.t;
   string m = StringFormat("%s %s %s  quality %d\nEntry %s  SL %s  TP1 %s  TP2 %s\nWhy: %s",
                           (s.dir > 0 ? "BUY" : "SELL"), _Symbol,
                           TfName((ENUM_TIMEFRAMES)_Period), s.score,
                           DoubleToString(s.entry, _Digits), DoubleToString(s.sl, _Digits),
                           DoubleToString(s.tp1, _Digits), DoubleToString(s.tp2, _Digits), s.why);
   if(InpAlertPopup) Alert(m);
   if(InpAlertPush)  SendNotification(m);
   if(InpAlertSound) PlaySound("alert.wav");
  }

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_htf = (InpHTF == PERIOD_CURRENT ? AutoHTF((ENUM_TIMEFRAMES)_Period) : InpHTF);
   if(PeriodSeconds(g_htf) <= PeriodSeconds(_Period))
      g_htf = AutoHTF((ENUM_TIMEFRAMES)_Period);

   SetIndexBuffer(0, BufBuy,   INDICATOR_DATA);
   SetIndexBuffer(1, BufSell,  INDICATOR_DATA);
   SetIndexBuffer(2, BufSL,    INDICATOR_CALCULATIONS);
   SetIndexBuffer(3, BufTP1,   INDICATOR_CALCULATIONS);
   SetIndexBuffer(4, BufTP2,   INDICATOR_CALCULATIONS);
   SetIndexBuffer(5, BufDir,   INDICATOR_CALCULATIONS);
   SetIndexBuffer(6, BufScore, INDICATOR_CALCULATIONS);

   ArraySetAsSeries(BufBuy, false);   ArraySetAsSeries(BufSell, false);
   ArraySetAsSeries(BufSL, false);    ArraySetAsSeries(BufTP1, false);
   ArraySetAsSeries(BufTP2, false);   ArraySetAsSeries(BufDir, false);
   ArraySetAsSeries(BufScore, false);

   PlotIndexSetInteger(0, PLOT_ARROW, 233);   // up arrow
   PlotIndexSetInteger(1, PLOT_ARROW, 234);   // down arrow
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   IndicatorSetString(INDICATOR_SHORTNAME, "CRT Sniper Lite");
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

   g_hFast   = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hSlow   = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hAtr    = iATR(_Symbol, _Period, InpAtrPeriod);
   //--- only EMA 50 on the higher timeframe, so 50 bars of history is enough
   g_hHtfEma = iMA(_Symbol, g_htf, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);

   if(g_hFast == INVALID_HANDLE || g_hSlow == INVALID_HANDLE ||
      g_hAtr == INVALID_HANDLE || g_hHtfEma == INVALID_HANDLE)
     {
      Print("CRT Sniper Lite: handle creation failed");
      return INIT_FAILED;
     }

   ArraySetAsSeries(g_fast, true);  ArraySetAsSeries(g_slow, true);
   ArraySetAsSeries(g_atr, true);   ArraySetAsSeries(g_htfEma, true);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, PFX);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Calculate                                                        |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[], const double &high[],
                const double &low[], const double &close[], const long &tick_volume[],
                const long &volume[], const int &spread[])
  {
   int need = InpEmaSlow + InpRangeLook + 30;
   if(rates_total < need + 10) return 0;

   ArraySetAsSeries(time, false);  ArraySetAsSeries(open, false);
   ArraySetAsSeries(high, false);  ArraySetAsSeries(low, false);
   ArraySetAsSeries(close, false);

   int from = need;
   if(InpMaxBars > 0) from = MathMax(from, rates_total - InpMaxBars);

   if(prev_calculated == 0 || g_lastProc < from - 1)
     {
      ArrayInitialize(BufBuy, EMPTY_VALUE);  ArrayInitialize(BufSell, EMPTY_VALUE);
      ArrayInitialize(BufSL, 0.0);  ArrayInitialize(BufTP1, 0.0);
      ArrayInitialize(BufTP2, 0.0); ArrayInitialize(BufDir, 0.0);
      ArrayInitialize(BufScore, 0.0);
      g_sigN = 0; g_lastSigBar = -100000;
      g_swHigh = 0.0; g_swLow = 0.0; g_swHighBar = -1; g_swLowBar = -1;
      g_lastProc = from - 1;
     }

   int cnt = rates_total - from + 5;
   if(cnt < 60) cnt = 60;
   ArraySetAsSeries(g_fast, true); ArraySetAsSeries(g_slow, true);
   ArraySetAsSeries(g_atr, true);  ArraySetAsSeries(g_htfEma, true);
   if(CopyBuffer(g_hFast, 0, 0, cnt, g_fast) <= 0) return prev_calculated;
   if(CopyBuffer(g_hSlow, 0, 0, cnt, g_slow) <= 0) return prev_calculated;
   if(CopyBuffer(g_hAtr,  0, 0, cnt, g_atr)  <= 0) return prev_calculated;

   double ratio = (double)PeriodSeconds(_Period) / (double)PeriodSeconds(g_htf);
   int hcnt = (int)MathCeil((rates_total - from) * ratio) + InpEmaFast + 20;
   hcnt = MathMax(hcnt, InpEmaFast + 40);
   hcnt = MathMin(hcnt, 5000);
   if(CopyBuffer(g_hHtfEma, 0, 0, hcnt, g_htfEma) <= 0) return prev_calculated;

   int start = MathMax(from, g_lastProc + 1);
   int last  = rates_total - 2;          // closed bars only

   for(int i = start; i < rates_total; i++)
     {
      BufBuy[i] = EMPTY_VALUE; BufSell[i] = EMPTY_VALUE;
      BufSL[i] = 0.0; BufTP1[i] = 0.0; BufTP2[i] = 0.0;
      BufDir[i] = 0.0; BufScore[i] = 0.0;
     }

   for(int i = start; i <= last; i++)
     {
      g_lastProc = i;

      double atr  = SV(g_atr,  rates_total, i);
      double fast = SV(g_fast, rates_total, i);
      double slow = SV(g_slow, rates_total, i);
      if(atr <= 0.0 || fast <= 0.0 || slow <= 0.0) continue;

      //--- swing structure -------------------------------------------
      int L = MathMax(1, InpSwingLen);
      int sB = i - L;
      if(sB - L >= 0)
        {
         bool isH = true, isL = true;
         for(int k = sB - L; k <= sB + L; k++)
           {
            if(k == sB) continue;
            if(high[k] >= high[sB]) isH = false;
            if(low[k]  <= low[sB])  isL = false;
           }
         if(isH) { g_swHigh = high[sB]; g_swHighBar = sB; }
         if(isL) { g_swLow  = low[sB];  g_swLowBar  = sB; }
        }

      //--- trend : chart EMAs plus one higher-timeframe check --------
      int hs = iBarShift(_Symbol, g_htf, time[i], false);
      if(hs < 0 || hs + 1 >= ArraySize(g_htfEma)) continue;
      double hEma = g_htfEma[hs+1];
      double hCl[1];
      if(CopyClose(_Symbol, g_htf, hs + 1, 1, hCl) <= 0) continue;
      if(hEma <= 0.0) continue;

      int htfTrend = (hCl[0] > hEma ? TR_UP : (hCl[0] < hEma ? TR_DOWN : TR_RANGE));

      int chartTrend = TR_RANGE;
      if(MathAbs(fast - slow) >= InpMinSepATR * atr)
        {
         if(fast > slow && close[i] > slow) chartTrend = TR_UP;
         if(fast < slow && close[i] < slow) chartTrend = TR_DOWN;
        }

      //--- both must agree, otherwise no trade ------------------------
      int trend = TR_RANGE;
      if(chartTrend == TR_UP   && htfTrend == TR_UP)   trend = TR_UP;
      if(chartTrend == TR_DOWN && htfTrend == TR_DOWN) trend = TR_DOWN;

      //--- where price sits in the recent range -----------------------
      double rHi = Hi(high, i - InpRangeLook + 1, i, rates_total);
      double rLo = Lo(low,  i - InpRangeLook + 1, i, rates_total);
      double loc = (rHi > rLo ? (close[i] - rLo) / (rHi - rLo) : 0.5);

      if(i == last)
        {
         g_dTrend = chartTrend; g_dHtf = htfTrend; g_dLoc = loc; g_dAtr = atr;
        }

      if(trend == TR_RANGE) continue;
      if(i - g_lastSigBar < InpCooldown) continue;

      bool buy = (trend == TR_UP);
      if(buy  && loc > InpMaxBuyLoc)  continue;
      if(!buy && loc < InpMinSellLoc) continue;

      string candle = (buy ? BullCandle(open, high, low, close, i, atr)
                       : BearCandle(open, high, low, close, i, atr));

      //--- which model triggered --------------------------------------
      int    model = -1;
      double trig  = 0.0;
      string trigTxt = "";

      // 1. sweep of a prior swing, then reclaim
      if(InpUseSweep)
        {
         double lvl = (buy ? Lo(low, i - 20, i - 1, rates_total)
                       : Hi(high, i - 20, i - 1, rates_total));
         double pen = (buy ? lvl - low[i] : high[i] - lvl);
         bool swept = (buy ? (low[i] < lvl && close[i] > lvl)
                       : (high[i] > lvl && close[i] < lvl));
         if(swept && pen >= 0.15 * atr)
           {
            model = M_SWEEP;
            trig  = Clamp01(pen / (0.8 * atr));
            trigTxt = StringFormat("swept the %s at %s",
                                   (buy ? "low" : "high"), DoubleToString(lvl, _Digits));
           }
        }

      // 2. pullback into EMA 50 while trending
      if(InpUseTPB && model < 0)
        {
         bool touch = (buy ? (low[i] <= fast && close[i] > fast)
                       : (high[i] >= fast && close[i] < fast));
         if(touch)
           {
            model = M_TPB;
            trig  = Clamp01(MathAbs(fast - slow) / (1.5 * atr));
            trigTxt = StringFormat("pullback into EMA %d", InpEmaFast);
           }
        }

      if(model < 0) continue;
      //--- a candle is required unless the structural trigger is strong alone
      if(candle == "" && trig < 0.75) continue;

      //--- stop and targets -------------------------------------------
      double entry = close[i];
      double sl = (buy ? Lo(low, i - InpSlLookback + 1, i, rates_total) - InpSlBufATR * atr
                   : Hi(high, i - InpSlLookback + 1, i, rates_total) + InpSlBufATR * atr);
      double risk = MathAbs(entry - sl);
      if(risk <= 0.0) continue;

      double tp1 = entry + (buy ? 1.0 : -1.0) * risk * InpRR1;
      double tp2 = entry + (buy ? 1.0 : -1.0) * risk * InpRR2;

      double locDepth = (buy ? Clamp01((InpMaxBuyLoc - loc) / MathMax(InpMaxBuyLoc, 0.01))
                         : Clamp01((loc - InpMinSellLoc) / MathMax(1.0 - InpMinSellLoc, 0.01)));

      //--- trend strength: EMA separation plus the HTF distance from its EMA
      double sepQ  = Clamp01(MathAbs(fast - slow) / (1.2 * atr));
      double htfQ  = Clamp01(MathAbs(hCl[0] - hEma) / MathMax(MathAbs(hEma) * 0.004, 1e-9));
      double trendQ = 0.6 * sepQ + 0.4 * htfQ;

      int sc = Score(trendQ, locDepth, candle, trig, MathAbs(tp2 - entry) / risk);
      if(sc < InpMinScore) continue;

      //--- publish -----------------------------------------------------
      if(InpShowArrows)
        {
         if(buy) BufBuy[i]  = low[i]  - 0.8 * atr;
         else    BufSell[i] = high[i] + 0.8 * atr;
        }
      BufSL[i] = sl; BufTP1[i] = tp1; BufTP2[i] = tp2;
      BufDir[i] = (buy ? 1.0 : -1.0);
      BufScore[i] = (double)sc;

      int idx = g_sigN;
      if(g_sigN >= MAXSIG)
        {
         for(int k = 1; k < MAXSIG; k++) g_sig[k-1] = g_sig[k];
         idx = MAXSIG - 1;
        }
      else
         g_sigN++;

      g_sig[idx].t = time[i];
      g_sig[idx].dir = (buy ? 1 : -1);
      g_sig[idx].model = model;
      g_sig[idx].score = sc;
      g_sig[idx].entry = entry;
      g_sig[idx].sl = sl;
      g_sig[idx].tp1 = tp1;
      g_sig[idx].tp2 = tp2;
      g_sig[idx].why = StringFormat("%s trend on %s and chart, %s in the range, %s%s",
                                    (buy ? "bullish" : "bearish"), TfName(g_htf),
                                    (buy ? "low" : "high"), trigTxt,
                                    (candle == "" ? "" : ", " + candle));

      g_lastSigBar = i;
      if(i == rates_total - 2) Fire(g_sig[idx]);
     }

   DrawSignals(prev_calculated == 0);
   DrawPanel();
   ChartRedraw();
   return rates_total;
  }
//+------------------------------------------------------------------+
