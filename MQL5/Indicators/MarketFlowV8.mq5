//+------------------------------------------------------------------+
//|                                                 MarketFlowV8.mq5 |
//|                            Multi-symbol signals dashboard for MT5 |
//+------------------------------------------------------------------+
#property copyright "MarketFlow"
#property version   "8.00"
#property description "MarketFlow V8 - multi-symbol / single-timeframe signals dashboard"
#property description "with on-chart trade projection (entry, SL, TP1/TP2/TP3)."
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Scanner ==="
input string            InpSymbols        = "Volatility 10 (1s) Index,Volatility 90 (1s) Index,Boom 250 Index,Boom 1000 Index,Crash 300 Index,Crash 500 Index,Jump 30 Index,Step Index,Step Index 200,Step Index 400,BTCUSD,ETHUSD,EURUSD,AUDCHF"; // Symbols (comma separated)
input ENUM_TIMEFRAMES   InpTimeframe      = PERIOD_CURRENT;  // Scan timeframe
input int               InpMaxAge         = 12;              // Keep a signal alive for N bars
input int               InpRefreshSeconds = 2;               // Rescan interval (seconds)
input bool              InpOnlySignals    = false;           // Hide symbols without a live signal
input bool              InpSortFreshest   = false;           // Sort freshest signal first (else list order)

input group "=== Signal engine ==="
input int               InpEmaFast        = 21;              // Fast EMA
input int               InpEmaSlow        = 50;              // Slow EMA
input int               InpAtrPeriod      = 14;              // ATR period
input int               InpRsiPeriod      = 14;              // RSI period
input double            InpRsiOverbought  = 70.0;            // RSI overbought (reversal sell)
input double            InpRsiOversold    = 30.0;            // RSI oversold (reversal buy)

input group "=== Risk model ==="
input double            InpSLAtrMult      = 1.5;             // Stop loss = ATR x
input double            InpTP1R           = 1.5;             // TP1 (R multiple)
input double            InpTP2R           = 2.5;             // TP2 (R multiple)
input double            InpTP3R           = 4.0;             // TP3 (R multiple)

input group "=== Panel ==="
input int               InpPanelX         = 6;               // Panel X (px from left)
input int               InpPanelY         = 6;               // Panel Y (px from bottom)
input int               InpRowsVisible    = 9;               // Visible rows
input int               InpRowHeight      = 18;              // Row height (px)
input string            InpFont           = "Consolas";      // Font
input int               InpFontSize       = 8;               // Font size

input group "=== Chart trade ==="
input bool              InpShowChartTrade = true;            // Draw the trade of the chart symbol
input bool              InpShowWatermark  = true;            // Draw symbol/timeframe watermark
input int               InpBoxExtendBars  = 6;               // Extend trade box N bars past the last bar

input group "=== Colors ==="
input color             InpClrPanelBg     = C'10,12,26';     // Panel background
input color             InpClrPanelBorder = C'60,50,120';    // Panel border
input color             InpClrRowA        = C'16,18,38';     // Row background A
input color             InpClrRowB        = C'22,24,48';     // Row background B
input color             InpClrTitle       = C'190,180,255';  // Title text
input color             InpClrHeader      = C'130,120,190';  // Column header text
input color             InpClrText        = C'205,205,220';  // Row text
input color             InpClrBuy         = C'0,210,140';    // Buy color
input color             InpClrSell        = C'235,70,110';   // Sell color
input color             InpClrEntryLine   = C'160,45,60';    // Entry line color

input group "=== Alerts ==="
input bool              InpAlertPopup     = false;           // Popup alert on a new signal
input bool              InpAlertPush      = false;           // Push notification on a new signal

//+------------------------------------------------------------------+
//| Types                                                            |
//+------------------------------------------------------------------+
struct SignalInfo
{
   bool     valid;
   int      dir;           // +1 buy, -1 sell
   bool     continuation;  // true = continuation, false = reversal
   int      barIndex;      // shift of the signal bar (1 = last closed bar)
   datetime time;
   double   entry;
   double   sl;
   double   tp1;
   double   tp2;
   double   tp3;
};

struct SymbolRow
{
   string     name;
   bool       ok;          // symbol resolved and selected
   int        digits;
   int        hEmaFast;
   int        hEmaSlow;
   int        hAtr;
   int        hRsi;
   datetime   lastAlert;
   SignalInfo sig;
};

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
#define COLS 10

const string      g_prefix   = "MFV8_";
const string      g_colName[COLS] = {"SYMBOL","TF","SIGNAL","AGE","ENTRY","SL","TP1","TP2","TP3","CHART"};
const int         g_colX[COLS]    = {8,178,222,300,392,482,572,662,752,846};
const int         g_panelW        = 910;

SymbolRow         g_rows[];
int               g_order[];       // display order -> index into g_rows
int               g_scroll   = 0;
ENUM_TIMEFRAMES   g_tf       = PERIOD_CURRENT;
string            g_tfText   = "";
datetime          g_lastScan = 0;

const int         g_titleH   = 24;
const int         g_headerH  = 20;

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
string TfToText(const ENUM_TIMEFRAMES tf)
{
   string s = EnumToString(tf);          // "PERIOD_M15"
   int p = StringFind(s, "_");
   if(p >= 0)
      s = StringSubstr(s, p + 1);
   return s;
}

int PanelHeight()
{
   return g_titleH + g_headerH + InpRowsVisible * InpRowHeight + 6;
}

//--- y coordinate (from the chart bottom) of the baseline of visible row i
int RowBaseline(const int i)
{
   return InpPanelY + 3 + (InpRowsVisible - 1 - i) * InpRowHeight + 4;
}

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
              const color clr, const int fontSize, const ENUM_BASE_CORNER corner = CORNER_LEFT_LOWER,
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
   ObjectSetInteger(0, name, OBJPROP_CORNER,       CORNER_LEFT_LOWER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,    x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,    y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE,        w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE,        h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR,      bg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE,  BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_COLOR,        border);
   ObjectSetInteger(0, name, OBJPROP_BACK,         false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER,       0);
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
//| Symbol list                                                      |
//+------------------------------------------------------------------+
void CreateHandles(SymbolRow &r)
{
   if(r.hEmaFast == INVALID_HANDLE)
      r.hEmaFast = iMA(r.name, g_tf, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   if(r.hEmaSlow == INVALID_HANDLE)
      r.hEmaSlow = iMA(r.name, g_tf, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   if(r.hAtr == INVALID_HANDLE)
      r.hAtr = iATR(r.name, g_tf, InpAtrPeriod);
   if(r.hRsi == INVALID_HANDLE)
      r.hRsi = iRSI(r.name, g_tf, InpRsiPeriod, PRICE_CLOSE);
}

void BuildSymbols()
{
   string parts[];
   int n = StringSplit(InpSymbols, StringGetCharacter(",", 0), parts);
   if(n <= 0)
   {
      ArrayResize(parts, 1);
      parts[0] = _Symbol;
      n = 1;
   }

   ArrayResize(g_rows, 0);
   for(int i = 0; i < n; i++)
   {
      string s = parts[i];
      StringTrimLeft(s);
      StringTrimRight(s);
      if(s == "")
         continue;

      SymbolRow r;
      r.name      = s;
      r.ok        = SymbolSelect(s, true);
      r.digits    = r.ok ? (int)SymbolInfoInteger(s, SYMBOL_DIGITS) : _Digits;
      r.hEmaFast  = INVALID_HANDLE;
      r.hEmaSlow  = INVALID_HANDLE;
      r.hAtr      = INVALID_HANDLE;
      r.hRsi      = INVALID_HANDLE;
      r.lastAlert = 0;
      r.sig.valid = false;
      if(r.ok)
         CreateHandles(r);

      int k = ArraySize(g_rows);
      ArrayResize(g_rows, k + 1);
      g_rows[k] = r;
   }
}

void ReleaseHandles()
{
   for(int i = 0; i < ArraySize(g_rows); i++)
   {
      if(g_rows[i].hEmaFast != INVALID_HANDLE) IndicatorRelease(g_rows[i].hEmaFast);
      if(g_rows[i].hEmaSlow != INVALID_HANDLE) IndicatorRelease(g_rows[i].hEmaSlow);
      if(g_rows[i].hAtr     != INVALID_HANDLE) IndicatorRelease(g_rows[i].hAtr);
      if(g_rows[i].hRsi     != INVALID_HANDLE) IndicatorRelease(g_rows[i].hRsi);
   }
}

//+------------------------------------------------------------------+
//| Signal engine                                                    |
//|                                                                  |
//| Trend      : EMA(fast) vs EMA(slow)                              |
//| CONTINUATION: pullback into the fast EMA and rejection back in    |
//|               the direction of the trend                          |
//| REVERSAL    : RSI exhaustion against the trend plus a close       |
//|               through the previous bar's extreme                  |
//| Risk       : SL = ATR * mult, TP = 1.5R / 2.5R / 4R               |
//+------------------------------------------------------------------+
void ComputeSignal(SymbolRow &r)
{
   r.sig.valid = false;
   if(!r.ok)
      return;

   CreateHandles(r);
   if(r.hEmaFast == INVALID_HANDLE || r.hEmaSlow == INVALID_HANDLE ||
      r.hAtr == INVALID_HANDLE     || r.hRsi == INVALID_HANDLE)
      return;

   int need = InpMaxAge + 6;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(r.name, g_tf, 0, need, rates) < need)
      return;

   double emaF[], emaS[], atr[], rsi[];
   ArraySetAsSeries(emaF, true);
   ArraySetAsSeries(emaS, true);
   ArraySetAsSeries(atr,  true);
   ArraySetAsSeries(rsi,  true);

   if(CopyBuffer(r.hEmaFast, 0, 0, need, emaF) < need) return;
   if(CopyBuffer(r.hEmaSlow, 0, 0, need, emaS) < need) return;
   if(CopyBuffer(r.hAtr,     0, 0, need, atr)  < need) return;
   if(CopyBuffer(r.hRsi,     0, 0, need, rsi)  < need) return;

   for(int i = 1; i <= InpMaxAge; i++)
   {
      if(atr[i] <= 0.0)
         continue;

      bool up   = (emaF[i] > emaS[i]);
      bool down = (emaF[i] < emaS[i]);

      int  dir  = 0;
      bool cont = false;

      if(up && rsi[i] >= InpRsiOverbought &&
         rates[i].close < rates[i].open && rates[i].close < rates[i + 1].low)
      {
         dir = -1; cont = false;                     // reversal sell
      }
      else if(down && rsi[i] <= InpRsiOversold &&
              rates[i].close > rates[i].open && rates[i].close > rates[i + 1].high)
      {
         dir = +1; cont = false;                     // reversal buy
      }
      else if(up && rates[i].low <= emaF[i] &&
              rates[i].close > emaF[i] && rates[i].close > rates[i].open)
      {
         dir = +1; cont = true;                      // continuation buy
      }
      else if(down && rates[i].high >= emaF[i] &&
              rates[i].close < emaF[i] && rates[i].close < rates[i].open)
      {
         dir = -1; cont = true;                      // continuation sell
      }

      if(dir == 0)
         continue;

      double entry = rates[i].close;
      double risk  = atr[i] * InpSLAtrMult;
      if(risk <= 0.0)
         continue;

      r.sig.valid        = true;
      r.sig.dir          = dir;
      r.sig.continuation = cont;
      r.sig.barIndex     = i;
      r.sig.time         = rates[i].time;
      r.sig.entry        = NormalizeDouble(entry, r.digits);
      r.sig.sl           = NormalizeDouble(entry - dir * risk, r.digits);
      r.sig.tp1          = NormalizeDouble(entry + dir * risk * InpTP1R, r.digits);
      r.sig.tp2          = NormalizeDouble(entry + dir * risk * InpTP2R, r.digits);
      r.sig.tp3          = NormalizeDouble(entry + dir * risk * InpTP3R, r.digits);
      break;
   }

   if(r.sig.valid && r.sig.barIndex == 1 && r.sig.time != r.lastAlert)
   {
      r.lastAlert = r.sig.time;
      string msg = StringFormat("MarketFlow V8 | %s %s | %s %s | entry %s  SL %s  TP1 %s",
                                r.name, g_tfText,
                                (r.sig.dir > 0 ? "BUY" : "SELL"),
                                (r.sig.continuation ? "CONTINUATION" : "REVERSAL"),
                                DoubleToString(r.sig.entry, r.digits),
                                DoubleToString(r.sig.sl,    r.digits),
                                DoubleToString(r.sig.tp1,   r.digits));
      if(InpAlertPopup) Alert(msg);
      if(InpAlertPush)  SendNotification(msg);
   }
}

void ScanAll()
{
   for(int i = 0; i < ArraySize(g_rows); i++)
      ComputeSignal(g_rows[i]);
   BuildOrder();
}

//--- build the display order (filter + sort)
void BuildOrder()
{
   ArrayResize(g_order, 0);
   for(int i = 0; i < ArraySize(g_rows); i++)
   {
      if(InpOnlySignals && !g_rows[i].sig.valid)
         continue;
      int k = ArraySize(g_order);
      ArrayResize(g_order, k + 1);
      g_order[k] = i;
   }

   if(InpSortFreshest)
   {
      int n = ArraySize(g_order);
      for(int a = 0; a < n - 1; a++)
         for(int b = 0; b < n - 1 - a; b++)
         {
            int ia = g_order[b];
            int ib = g_order[b + 1];
            int ka = g_rows[ia].sig.valid ? g_rows[ia].sig.barIndex : 100000;
            int kb = g_rows[ib].sig.valid ? g_rows[ib].sig.barIndex : 100000;
            if(ka > kb)
            {
               g_order[b]     = ib;
               g_order[b + 1] = ia;
            }
         }
   }

   int maxScroll = (int)MathMax(0, ArraySize(g_order) - InpRowsVisible);
   g_scroll = (int)MathMin(MathMax(0, g_scroll), maxScroll);
}

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
string SignalText(const SignalInfo &s)
{
   if(!s.valid)
      return "-";
   string head = (s.dir > 0 ? ShortToString(0x25B2) + " BUY" : ShortToString(0x25BC) + " SELL");
   return head + (s.continuation ? "+" : "-");
}

string AgeText(const SignalInfo &s)
{
   if(!s.valid)
      return "-";
   if(s.barIndex <= 1)
      return "current";
   return StringFormat("%d bars ago", s.barIndex - 1);
}

void DrawPanel()
{
   int H = PanelHeight();

   SetRect(g_prefix + "bg", InpPanelX, InpPanelY, g_panelW, H, InpClrPanelBg, InpClrPanelBorder);

   //--- title
   string title = StringFormat("%s MARKETFLOW V8  |  SIGNALS DASHBOARD  |  %s  |  %s",
                               ShortToString(0x25C8), g_tfText,
                               TimeToString(TimeCurrent(), TIME_MINUTES));
   SetLabel(g_prefix + "title", InpPanelX + 8, InpPanelY + H - g_titleH + 7, title,
            InpClrTitle, InpFontSize + 1);

   //--- scroll controls + page counter
   int total = ArraySize(g_order);
   int shown = (int)MathMin(InpRowsVisible, (int)MathMax(0, total - g_scroll));
   int from  = (total == 0 ? 0 : g_scroll + 1);
   int to    = g_scroll + shown;

   int btnY = InpPanelY + H - g_titleH + 3;
   SetButton(g_prefix + "btn_up",   InpPanelX + g_panelW - 130, btnY, 18, 16,
             ShortToString(0x25B2), InpClrRowB, InpClrTitle);
   SetButton(g_prefix + "btn_down", InpPanelX + g_panelW - 110, btnY, 18, 16,
             ShortToString(0x25BC), InpClrRowB, InpClrTitle);
   SetLabel(g_prefix + "page", InpPanelX + g_panelW - 86, InpPanelY + H - g_titleH + 7,
            StringFormat("%d-%d / %d", from, to, total), InpClrHeader, InpFontSize);

   //--- column headers
   int headY = InpPanelY + H - g_titleH - g_headerH + 6;
   for(int c = 0; c < COLS; c++)
      SetLabel(g_prefix + "hdr" + IntegerToString(c), InpPanelX + g_colX[c], headY,
               g_colName[c], InpClrHeader, InpFontSize);

   //--- rows
   for(int i = 0; i < InpRowsVisible; i++)
   {
      string suf   = IntegerToString(i);
      int    base  = RowBaseline(i);
      int    idx   = g_scroll + i;
      bool   has   = (idx < total);

      string rowBg = g_prefix + "rowbg" + suf;
      SetRect(rowBg, InpPanelX + 4, base - 4, g_panelW - 8, InpRowHeight,
              ((i % 2) == 0 ? InpClrRowA : InpClrRowB), InpClrPanelBg);
      ObjShow(rowBg, has);

      string btn = g_prefix + "btn_open" + suf;

      if(!has)
      {
         for(int c = 0; c < COLS; c++)
            ObjShow(g_prefix + "c" + IntegerToString(c) + "_" + suf, false);
         ObjShow(btn, false);
         continue;
      }

      SymbolRow r = g_rows[g_order[idx]];
      color     sc = (!r.sig.valid ? InpClrText : (r.sig.dir > 0 ? InpClrBuy : InpClrSell));
      string    cells[COLS];

      cells[0] = r.name;
      cells[1] = g_tfText;
      cells[2] = SignalText(r.sig);
      cells[3] = AgeText(r.sig);
      cells[4] = r.sig.valid ? DoubleToString(r.sig.entry, r.digits) : "-";
      cells[5] = r.sig.valid ? DoubleToString(r.sig.sl,    r.digits) : "-";
      cells[6] = r.sig.valid ? DoubleToString(r.sig.tp1,   r.digits) : "-";
      cells[7] = r.sig.valid ? DoubleToString(r.sig.tp2,   r.digits) : "-";
      cells[8] = r.sig.valid ? DoubleToString(r.sig.tp3,   r.digits) : "-";
      cells[9] = "";

      if(!r.ok)
      {
         cells[2] = "n/a";
         cells[3] = "not in market watch";
      }

      for(int c = 0; c < COLS - 1; c++)
      {
         color clr = InpClrText;
         if(c == 0)                       clr = InpClrTitle;
         if(c == 2 || (c >= 4 && c <= 8)) clr = sc;
         if(c == 5 && r.sig.valid)        clr = InpClrSell;
         SetLabel(g_prefix + "c" + IntegerToString(c) + "_" + suf,
                  InpPanelX + g_colX[c], base, cells[c], clr, InpFontSize);
      }
      ObjShow(g_prefix + "c9_" + suf, false);

      SetButton(btn, InpPanelX + g_colX[9], base - 3, 50, InpRowHeight - 3,
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
   if(!InpShowChartTrade)
   {
      ClearChartTrade();
      return;
   }

   //--- find the chart symbol in the scan list
   int found = -1;
   for(int i = 0; i < ArraySize(g_rows); i++)
      if(g_rows[i].name == _Symbol && g_rows[i].sig.valid)
      {
         found = i;
         break;
      }

   if(found < 0)
   {
      ClearChartTrade();
      return;
   }

   SymbolRow r  = g_rows[found];
   SignalInfo s = r.sig;

   bool   buy   = (s.dir > 0);
   color  clr   = buy ? InpClrBuy : InpClrSell;
   int    ps    = PeriodSeconds(g_tf);
   datetime t1  = s.time;
   datetime t2  = (datetime)(TimeCurrent() + (long)ps * InpBoxExtendBars);

   //--- box between SL and TP3
   string box = g_prefix + "tr_box";
   if(EnsureObject(box, OBJ_RECTANGLE))
   {
      ObjectSetInteger(0, box, OBJPROP_TIME,  0, t1);
      ObjectSetDouble (0, box, OBJPROP_PRICE, 0, s.sl);
      ObjectSetInteger(0, box, OBJPROP_TIME,  1, t2);
      ObjectSetDouble (0, box, OBJPROP_PRICE, 1, s.tp3);
      ObjectSetInteger(0, box, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, box, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, box, OBJPROP_FILL,  false);
      ObjectSetInteger(0, box, OBJPROP_BACK,  true);
   }

   //--- signal bar marker
   string vl = g_prefix + "tr_vline";
   if(EnsureObject(vl, OBJ_VLINE))
   {
      ObjectSetInteger(0, vl, OBJPROP_TIME,  t1);
      ObjectSetInteger(0, vl, OBJPROP_COLOR, C'90,90,110');
      ObjectSetInteger(0, vl, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, vl, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, vl, OBJPROP_BACK,  true);
   }

   //--- entry line across the chart
   string hl = g_prefix + "tr_entry";
   if(EnsureObject(hl, OBJ_HLINE))
   {
      ObjectSetDouble (0, hl, OBJPROP_PRICE, s.entry);
      ObjectSetInteger(0, hl, OBJPROP_COLOR, InpClrEntryLine);
      ObjectSetInteger(0, hl, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, hl, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, hl, OBJPROP_BACK,  true);
   }

   //--- levels
   SetTradeLine(g_prefix + "tr_sl",  t1, t2, s.sl,  InpClrSell, STYLE_SOLID);
   SetTradeLine(g_prefix + "tr_tp1", t1, t2, s.tp1, clr,        STYLE_DOT);
   SetTradeLine(g_prefix + "tr_tp2", t1, t2, s.tp2, clr,        STYLE_DOT);
   SetTradeLine(g_prefix + "tr_tp3", t1, t2, s.tp3, clr,        STYLE_DOT);

   datetime tTxt = (datetime)(t1 + (long)ps * 2);
   SetTradeText(g_prefix + "tr_txt_entry", tTxt, s.entry,
                "ENTRY: " + DoubleToString(s.entry, r.digits), InpClrText);
   SetTradeText(g_prefix + "tr_txt_sl",  tTxt, s.sl,  "SL: "  + DoubleToString(s.sl,  r.digits), InpClrSell);
   SetTradeText(g_prefix + "tr_txt_tp1", tTxt, s.tp1, "TP1: " + DoubleToString(s.tp1, r.digits), clr);
   SetTradeText(g_prefix + "tr_txt_tp2", tTxt, s.tp2, "TP2: " + DoubleToString(s.tp2, r.digits), clr);
   SetTradeText(g_prefix + "tr_txt_tp3", tTxt, s.tp3, "TP3: " + DoubleToString(s.tp3, r.digits), clr);

   //--- arrow on the signal bar
   double hi = iHigh(_Symbol, g_tf, s.barIndex);
   double lo = iLow (_Symbol, g_tf, s.barIndex);
   double pad = MathAbs(s.entry - s.sl) * 0.35;
   string ar = g_prefix + "tr_arrow";
   if(EnsureObject(ar, OBJ_ARROW))
   {
      ObjectSetInteger(0, ar, OBJPROP_TIME,      t1);
      ObjectSetDouble (0, ar, OBJPROP_PRICE,     buy ? lo - pad : hi + pad);
      ObjectSetInteger(0, ar, OBJPROP_ARROWCODE, buy ? 233 : 234);
      ObjectSetInteger(0, ar, OBJPROP_ANCHOR,    buy ? ANCHOR_TOP : ANCHOR_BOTTOM);
      ObjectSetInteger(0, ar, OBJPROP_COLOR,     clr);
      ObjectSetInteger(0, ar, OBJPROP_WIDTH,     3);
   }

   //--- legend above the panel
   int legendY = InpPanelY + PanelHeight() + 8;
   SetLabel(g_prefix + "tr_leg1", InpPanelX + 8, legendY + 16,
            ShortToString(0x25C8) + " TRADE", InpClrTitle, InpFontSize + 1);
   SetLabel(g_prefix + "tr_leg2", InpPanelX + 8, legendY,
            StringFormat("%s %s", SignalText(s), (s.continuation ? "CONTINUATION" : "REVERSAL")),
            clr, InpFontSize + 1);
}

void DrawWatermark()
{
   string wm = g_prefix + "watermark";
   if(!InpShowWatermark)
   {
      ObjectDelete(0, wm);
      return;
   }
   SetLabel(wm, 20, 24, _Symbol + "   |   " + g_tfText, C'120,110,180', 14,
            CORNER_RIGHT_UPPER, ANCHOR_RIGHT_UPPER);
}

//+------------------------------------------------------------------+
//| Refresh                                                          |
//+------------------------------------------------------------------+
void Refresh(const bool force)
{
   if(!force && TimeCurrent() - g_lastScan < InpRefreshSeconds)
      return;
   g_lastScan = TimeCurrent();

   ScanAll();
   DrawPanel();
   DrawChartTrade();
   DrawWatermark();
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Lifecycle                                                        |
//+------------------------------------------------------------------+
int OnInit()
{
   g_tf     = (InpTimeframe == PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : InpTimeframe);
   g_tfText = TfToText(g_tf);

   if(InpRowsVisible < 1 || InpRowHeight < 8)
   {
      Print("MarketFlow V8: invalid panel geometry inputs.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpEmaFast < 1 || InpEmaSlow < 1 || InpEmaFast >= InpEmaSlow)
   {
      Print("MarketFlow V8: fast EMA must be shorter than slow EMA.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpMaxAge < 1)
   {
      Print("MarketFlow V8: 'Keep a signal alive' must be at least 1 bar.");
      return INIT_PARAMETERS_INCORRECT;
   }

   IndicatorSetString(INDICATOR_SHORTNAME, "MarketFlow V8");

   BuildSymbols();
   if(ArraySize(g_rows) == 0)
   {
      Print("MarketFlow V8: no usable symbols in the list.");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_scroll = 0;
   EventSetTimer(1);
   Refresh(true);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ReleaseHandles();
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
   Refresh(false);
   return rates_total;
}

void OnTimer()
{
   Refresh(false);
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
         string sym = g_rows[g_order[idx]].name;
         if(sym != _Symbol || g_tf != (ENUM_TIMEFRAMES)_Period)
            ChartSetSymbolPeriod(0, sym, g_tf);
      }
      ChartRedraw();
   }
}
//+------------------------------------------------------------------+
