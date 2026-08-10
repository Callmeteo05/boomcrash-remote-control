//+------------------------------------------------------------------+
//|                                             FlagStructurePro.mq5 |
//|  Non-repainting bull/bear flag detection with breakout + retest  |
//|  confirmation and higher-timeframe bias filtering.               |
//|  Symbol- and broker-agnostic.                                    |
//+------------------------------------------------------------------+
//
// ============================ NON-REPAINT CONTRACT =================
//
// One invariant governs this file: the value written to a buffer for
// the bar whose open time is T never changes after that bar closed -
// no matter how many ticks arrive, whether the terminal reloads
// history, or whether the run is live, tester-visual, or offline.
//
// How it is enforced:
//
//  1. ProcessBar(i) is strictly causal. Pattern detection, swing
//     detection, boundary fitting and state-machine advancement read
//     bar data at indices <= i only. There is no read of high[i+1],
//     time[i+1] or any later bar anywhere in the signal path. The
//     forward-looking MFE/MAE figures exist only inside FlushCsvRows,
//     are written to file, and are never read back.
//
//  2. The forming bar (index rates_total-1) is never evaluated and
//     never written. The highest index ProcessBar can receive is
//     rates_total-2. All six buffers are explicitly forced to
//     EMPTY_VALUE at rates_total-1 on every single call.
//
//  3. Emitted signals are appended to g_sigs[] - a ConfirmedSignal
//     store keyed by bar open time - and written to their buffer once.
//     The incremental path resumes strictly after g_lastProcessedTime
//     (a datetime, not an index, so index shifts cannot cause a
//     re-evaluation), and additionally refuses to touch any bar that
//     already carries a verdict. On prev_calculated == 0 (what MT5
//     does when history changes underneath us) the whole causal
//     sequence is replayed from scratch, which by construction
//     reproduces the identical store.
//
//  4. HTF bias reads CLOSED HTF bars only:
//         int hshift = iBarShift(_Symbol, InpHTF, time[i], false);
//         // hshift is the HTF bar CONTAINING time[i] - still forming.
//         // hshift+1 is the last HTF bar already closed at time[i].
//     Everything downstream uses hshift+1. HTF swing structure is
//     further restricted to swings whose K-bar confirmation had fully
//     elapsed by hshift+1 (see HtfBiasAt).
//
//  5. Swings are confirmed with lag. A swing at bar j is only known at
//     bar j+K (InpSwingConfirmBars). It becomes usable as a pole anchor
//     from bar j+K onward and is never backdated. Same rule for HTF
//     swings in HTF bar units.
//
//  6. If CopyRates / CopyBuffer / CopyHigh / CopyLow return fewer bars
//     than requested, OnCalculate returns prev_calculated immediately.
//     Partial data never produces a signal.
//
//  7. Detection advances on new closed bars only, gated by the stored
//     datetime g_lastProcessedTime.
//
// Two consequences are deliberate, not defects:
//
//  * BREAKOUT_ONLY is plotted on the bar where the retest window
//    EXPIRES, not on the breakout bar. The breakout bar cannot know
//    that no retest will follow; plotting it there would be backdating.
//  * CONFIRMED is plotted on the rejection bar, typically several bars
//    after the break. That lateness is the price of the contract.
//
// ============================ REPAINT SELF-TEST ====================
//
// InpRepaintTest dumps every signal (bar time, type, price, quality)
// to file at OnDeinit - i.e. once the run is complete.
//
//   Procedure:
//     1. Delete any existing MQL5/Files/FSP_repaint_<SYM>_<TF>_*.csv.
//     2. Run the indicator in Strategy Tester VISUAL mode over the
//        target range, forward tick by tick, to the end. At deinit the
//        dump is written as ..._A.csv and the log prints
//        "REPAINT TEST: baseline written".
//     3. Attach the indicator to a normal chart, or re-run the tester
//        non-visual, over the SAME range - so the whole range is
//        present as closed history in one shot. At deinit the dump is
//        written as ..._B.csv and A vs B are compared byte for byte.
//     4. The log prints "REPAINT TEST: PASS" or "REPAINT TEST: FAIL"
//        with the first differing byte offset.
//
//   A and B are produced by the same causal replay over the same bars.
//   Any difference means a look-ahead leaked in.
//
//   ACCEPTANCE: repeat on 3 symbols x 3 timeframes, including at least
//   one symbol with weekend gaps (e.g. EURUSD, XAUUSD) and at least one
//   24/7 synthetic. All nine runs must print PASS.
//
// ===================================================================

#property copyright   "Flag Structure Pro"
#property version     "1.00"
#property description "Non-repainting bull/bear flag detection: pole + flag geometry,"
#property description "breakout + retest state machine, HTF bias filter, quality score."
#property description "All thresholds in ATR multiples or points. No hardcoded pip values."

#property indicator_chart_window
#property indicator_buffers 6
#property indicator_plots   6

//--- plot 1: bull confirmed
#property indicator_label1  "BullConfirmed"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrDodgerBlue
#property indicator_width1  2
//--- plot 2: bear confirmed
#property indicator_label2  "BearConfirmed"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrOrangeRed
#property indicator_width2  2
//--- plot 3: bull breakout only (window expired without confirmation)
#property indicator_label3  "BullBreakoutOnly"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrSteelBlue
#property indicator_width3  1
//--- plot 4: bear breakout only
#property indicator_label4  "BearBreakoutOnly"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrIndianRed
#property indicator_width4  1
//--- plot 5: HTF bias (-1 / 0 / +1) - Data Window
#property indicator_label5  "HTFBias"
#property indicator_type5   DRAW_NONE
//--- plot 6: quality score 0..100 at signal bars - Data Window
#property indicator_label6  "QualityScore"
#property indicator_type6   DRAW_NONE

//+------------------------------------------------------------------+
//| Constants                                                        |
//+------------------------------------------------------------------+
#define ST_IDLE          0
#define ST_FLAG_FORMED   1
#define ST_BROKEN        2
#define ST_RETESTING     3
#define ST_CONFIRMED     4   // terminal
#define ST_INVALIDATED   5   // terminal

#define BIAS_BEARISH   (-1)
#define BIAS_NEUTRAL    (0)
#define BIAS_BULLISH    (1)

#define SIG_BULL_CONFIRMED  0
#define SIG_BEAR_CONFIRMED  1
#define SIG_BULL_BREAKONLY  2
#define SIG_BEAR_BREAKONLY  3

#define FSP_H1   10
#define FSP_H2   20
#define FSP_H3   50
#define FSP_HMAX 50

//+------------------------------------------------------------------+
//| Inputs - higher timeframe bias                                   |
//+------------------------------------------------------------------+
input group           "=== HTF BIAS ==="
input ENUM_TIMEFRAMES InpHTF              = PERIOD_CURRENT; // HTF (PERIOD_CURRENT = auto-map)
input int             InpHTF_EMA          = 50;             // HTF EMA period
input double          InpHTF_SlopeATR     = 0.10;           // Min |EMA slope| per HTF bar, in HTF ATR
input int             InpHTF_ATR          = 14;             // HTF ATR period
input int             InpHTF_SwingBars    = 2;              // HTF swing confirmation bars (K)
input int             InpHTF_SwingLookback= 60;             // HTF bars searched for the 2 swings (FIXED window)
input int             InpHTF_Bars         = 600;            // Minimum HTF bars to load

//+------------------------------------------------------------------+
//| Inputs - pole / flag, bull side                                  |
//+------------------------------------------------------------------+
input group           "=== POLE / FLAG (BULL) ==="
input int             InpATRPeriod        = 14;             // ATR period (chart TF)
input int             InpSwingConfirmBars = 2;              // Swing confirmation bars K (chart TF)
input int             InpPoleMaxBars      = 15;             // Max bars anchor -> pole extreme
input double          InpPoleMinATR       = 2.5;            // Min pole height, in ATR
input double          InpPoleEfficiency   = 0.55;           // Min directional efficiency
input double          InpPoleMaxRetrace   = 0.382;          // Max counter-move inside pole (fraction)
input int             InpFlagMinBars      = 3;              // Min flag bars
input int             InpFlagMaxBars      = 15;             // Max flag bars
input double          InpMinRetrace       = 0.236;          // Min flag retracement of pole
input double          InpMaxRetrace       = 0.618;          // Max flag retracement of pole
input double          InpMaxTightness     = 0.50;           // Max flag_range / pole_height
input double          InpFlagSlopeTolATR  = 0.05;           // Slope tolerance per bar (ATR) before "with pole"

//+------------------------------------------------------------------+
//| Inputs - pole / flag, bear side (independent, stricter defaults) |
//| Bear flags underperform bull flags materially in published data. |
//| These are NOT mirrored from the bull block.                      |
//+------------------------------------------------------------------+
input group           "=== POLE / FLAG (BEAR - independent) ==="
input int             InpBear_PoleMaxBars     = 15;         // Bear: max bars anchor -> pole extreme
input double          InpBear_PoleMinATR      = 3.0;        // Bear: min pole height, in ATR
input double          InpBear_PoleEfficiency  = 0.62;       // Bear: min directional efficiency
input double          InpBear_PoleMaxRetrace  = 0.300;      // Bear: max counter-move inside pole
input int             InpBear_FlagMinBars     = 4;          // Bear: min flag bars
input int             InpBear_FlagMaxBars     = 15;         // Bear: max flag bars
input double          InpBear_MinRetrace      = 0.236;      // Bear: min flag retracement
input double          InpBear_MaxRetrace      = 0.500;      // Bear: max flag retracement
input double          InpBear_MinTightness    = 0.40;       // Bear: max flag_range / pole_height
input double          InpBear_FlagSlopeTolATR = 0.03;       // Bear: slope tolerance per bar (ATR)

//+------------------------------------------------------------------+
//| Inputs - breakout / retest state machine                         |
//+------------------------------------------------------------------+
input group           "=== BREAKOUT / RETEST ==="
input double          InpBreakBufferATR          = 0.25;    // Bull: close beyond boundary, in ATR
input double          InpRetestToleranceATR      = 0.30;    // Bull: retest proximity, in ATR
input int             InpRetestWindow            = 10;      // Bull: bars allowed for retest + confirm
input int             InpBreakWindow             = 20;      // Bull: bars after flag allowed for break
input double          InpBear_BreakBufferATR     = 0.35;    // Bear: close beyond boundary, in ATR
input double          InpBear_RetestToleranceATR = 0.25;    // Bear: retest proximity, in ATR
input int             InpBear_RetestWindow       = 8;       // Bear: bars allowed for retest + confirm
input int             InpBear_BreakWindow        = 15;      // Bear: bars after flag allowed for break
input bool            InpUseVolume               = false;   // Optional breakout tick-volume filter

//+------------------------------------------------------------------+
//| Inputs - drawing (bounded objects only)                          |
//+------------------------------------------------------------------+
input group           "=== DRAWING ==="
input bool            InpDraw               = true;         // Draw objects
input int             InpProjectBars        = 5;            // Forward projection bars (clamped to 15)
input int             InpMaxVisibleSetups   = 5;            // Max setups with objects on chart
input int             InpHistoryBarsToDraw  = 500;          // Do not draw setups older than this
input color           InpBullColor          = clrDodgerBlue;// Bull object colour
input color           InpBearColor          = clrOrangeRed; // Bear object colour
input bool            InpShowBiasLabel      = true;         // Show HTF bias label

//+------------------------------------------------------------------+
//| Inputs - validation harness                                      |
//+------------------------------------------------------------------+
input group           "=== VALIDATION HARNESS ==="
input bool            InpExportCSV          = true;         // Export one CSV row per signal
input bool            InpRepaintTest        = true;         // Write repaint dump + compare A/B
input bool            InpVerboseLog         = true;         // Log setup events and quality scores

//+------------------------------------------------------------------+
//| Buffers                                                          |
//+------------------------------------------------------------------+
double BufBullConf[];
double BufBearConf[];
double BufBullBO[];
double BufBearBO[];
double BufBias[];
double BufQuality[];

//+------------------------------------------------------------------+
//| Per-direction parameter block                                    |
//+------------------------------------------------------------------+
struct DirParams
  {
   int      poleMaxBars;
   double   poleMinATR;
   double   poleEff;
   double   poleMaxRetrace;
   int      flagMinBars;
   int      flagMaxBars;
   double   minRetrace;
   double   maxRetrace;
   double   maxTightness;
   double   slopeTolATR;
   double   breakBufATR;
   double   retestTolATR;
   int      retestWindow;
   int      breakWindow;
  };

DirParams g_bull;
DirParams g_bear;

//+------------------------------------------------------------------+
//| Setup - one pole+flag candidate travelling the state machine     |
//+------------------------------------------------------------------+
struct Setup
  {
   int      id;
   bool     isBull;
   int      state;
   int      lastDrawnState;
   //--- pole
   int      anchorIdx;
   datetime anchorTime;
   double   anchorPrice;      // swing low (bull) / swing high (bear)
   int      poleEndIdx;
   datetime poleEndTime;
   double   poleEndPrice;
   double   poleHeight;
   double   poleATRmult;
   double   poleEff;
   //--- flag
   int      flagStartIdx;
   int      flagEndIdx;
   datetime flagStartTime;
   datetime flagEndTime;
   int      flagBars;
   double   upSlope, upInter; // upper boundary, x measured from flagStartIdx
   double   dnSlope, dnInter; // lower boundary
   double   flagRange;
   double   tightness;
   double   retracePct;
   double   atrAtFlag;
   //--- break
   int      breakIdx;
   datetime breakTime;
   double   breakLevel;
   double   breakStrength;    // |close - boundary| / ATR at the break bar
   double   atrAtBreak;
   //--- retest
   int      retestIdx;
   datetime retestTime;
   //--- context
   int      biasAtForm;
   double   biasStrength;
   double   quality;
   //--- drawing
   bool     drawn;
  };

Setup g_setups[];
int   g_nextSetupId = 1;
int   g_liveBull    = -1;      // index into g_setups, -1 = none live
int   g_liveBear    = -1;

//+------------------------------------------------------------------+
//| Signal store - append only, keyed by bar open time               |
//+------------------------------------------------------------------+
struct SigRec
  {
   datetime t;                // bar open time the signal is plotted on
   int      idx;              // bar index at emit time
   int      type;             // SIG_*
   bool     isBull;
   bool     confirmed;
   double   plotPrice;
   double   entryPrice;       // close of the signal bar
   double   atr;              // ATR at the signal bar
   double   quality;
   //--- geometry snapshot for the CSV row
   double   poleATRmult;
   double   tightness;
   double   retracePct;
   double   poleEff;
   int      flagBars;
   int      bias;
   datetime breakTime;
   datetime retestTime;
   bool     flushed;
  };

SigRec g_sigs[];
int    g_csvRowsWritten = 0;

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
string          g_prefix            = "FSP_";
int             g_hATR              = INVALID_HANDLE;
int             g_hHtfEMA           = INVALID_HANDLE;
int             g_hHtfATR           = INVALID_HANDLE;
ENUM_TIMEFRAMES g_htf               = PERIOD_CURRENT;
datetime        g_lastProcessedTime = 0;
int             g_projectBars       = 5;
bool            g_gapAware          = false;
int             g_periodSeconds     = 0;
int             g_warmup            = 0;

//--- symbol properties, read once at init. No symbol-name parsing
//--- anywhere, so EURUSD.m / XAUUSDx / R_100 behave identically.
int             g_digits            = 5;
double          g_point             = 0.00001;
double          g_tickSize          = 0.00001;

//--- HTF snapshots, refreshed once per pass, SERIES indexed
//--- (index 0 = forming HTF bar, which is never read)
double          g_htfHigh[];
double          g_htfLow[];
double          g_htfEma[];
double          g_htfAtr[];
int             g_htfCopied         = 0;
bool            g_htfShortWarned    = false;

//--- HTF bias cache: bias only changes when the closed HTF bar changes
int             g_biasCacheShift    = -1;
int             g_biasCacheVal      = BIAS_NEUTRAL;
double          g_biasCacheStr      = 0.0;

//--- chart-TF ATR snapshot, NON-series indexed
double          g_atr[];

//--- drawing bookkeeping
int             g_drawnIds[];

//--- file names
string          g_csvFile = "";
string          g_dumpA   = "";
string          g_dumpB   = "";

//+------------------------------------------------------------------+
//| Forward declarations                                             |
//+------------------------------------------------------------------+
bool RefreshHtf(const int want);
void DetectGapAwareness(void);
void CsvWriteHeader(void);

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
double Clamp01(const double v)
  {
   if(v < 0.0) return(0.0);
   if(v > 1.0) return(1.0);
   return(v);
  }

int IMax(const int a, const int b) { return(a > b ? a : b); }
int IMin(const int a, const int b) { return(a < b ? a : b); }

string TfToString(const ENUM_TIMEFRAMES tf) { return(EnumToString(tf)); }

//--- filename-safe rendering of a symbol name. Purely character-class
//--- based: no broker suffix knowledge, no name parsing.
string SanitizeName(const string s)
  {
   string out = "";
   int n = StringLen(s);
   for(int k = 0; k < n; k++)
     {
      ushort c = StringGetCharacter(s, k);
      bool ok = (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') ||
                (c >= 'a' && c <= 'z') || c == '_' || c == '-';
      out += (ok ? ShortToString(c) : "_");
     }
   return(out);
  }

//--- chart TF -> HTF auto-map
ENUM_TIMEFRAMES AutoMapHTF(const ENUM_TIMEFRAMES chart)
  {
   switch(chart)
     {
      case PERIOD_M1:  return(PERIOD_M15);
      case PERIOD_M5:  return(PERIOD_H1);
      case PERIOD_M15: return(PERIOD_H4);
      case PERIOD_M30: return(PERIOD_H4);
      case PERIOD_H1:  return(PERIOD_D1);
      case PERIOD_H4:  return(PERIOD_D1);
      case PERIOD_D1:  return(PERIOD_W1);
      default:         break;
     }
   //--- anything else (M2/M3/M6/M10/M12/M20/H2/H3/H6/H8/H12/W1/MN1)
   int ps = PeriodSeconds(chart);
   if(ps < PeriodSeconds(PERIOD_H1)) return(PERIOD_H1);
   if(ps < PeriodSeconds(PERIOD_D1)) return(PERIOD_D1);
   if(ps < PeriodSeconds(PERIOD_W1)) return(PERIOD_W1);
   return(PERIOD_MN1);
  }

//--- bar time, extrapolated for the bounded forward projection
datetime BarTime(const datetime &time[], const int rates_total, const int idx)
  {
   if(rates_total <= 0) return(0);
   if(idx < 0)                return(time[0]);
   if(idx <= rates_total - 1) return(time[idx]);
   return((datetime)(time[rates_total - 1] + (long)(idx - (rates_total - 1)) * (long)g_periodSeconds));
  }

//--- session-break detection over an inclusive bar range
bool RangeHasGap(const datetime &time[], const int from, const int to)
  {
   if(!g_gapAware) return(false);
   for(int k = from + 1; k <= to; k++)
      if((long)(time[k] - time[k - 1]) > 2 * (long)g_periodSeconds)
         return(true);
   return(false);
  }

//+------------------------------------------------------------------+
//| Least-squares fit over the flag bars only, then shifted to        |
//| envelope the extremes. A plain LS line through the highs sits in  |
//| the MIDDLE of them, which is not a boundary; the shift makes the  |
//| break test mean what it says. x is measured from index i0.        |
//+------------------------------------------------------------------+
void FitBoundary(const double &price[], const int i0, const int n,
                 const bool upper, double &slope, double &inter)
  {
   slope = 0.0;
   inter = 0.0;
   if(n <= 0) return;
   if(n == 1) { inter = price[i0]; return; }

   double sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0;
   for(int k = 0; k < n; k++)
     {
      double x = (double)k;
      double y = price[i0 + k];
      sx  += x;
      sy  += y;
      sxx += x * x;
      sxy += x * y;
     }
   double den = (double)n * sxx - sx * sx;
   if(MathAbs(den) < DBL_EPSILON)
     {
      slope = 0.0;
      inter = sy / (double)n;
     }
   else
     {
      slope = ((double)n * sxy - sx * sy) / den;
      inter = (sy - slope * sx) / (double)n;
     }

   //--- envelope shift
   double best = price[i0] - inter;
   for(int k = 1; k < n; k++)
     {
      double resid = price[i0 + k] - (inter + slope * (double)k);
      if(upper) { if(resid > best) best = resid; }
      else      { if(resid < best) best = resid; }
     }
   inter += best;
  }

//--- plain LS slope, no envelope - used for the flag slope test
double LsSlope(const double &price[], const int i0, const int n)
  {
   if(n < 2) return(0.0);
   double sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0;
   for(int k = 0; k < n; k++)
     {
      double x = (double)k;
      double y = price[i0 + k];
      sx += x; sy += y; sxx += x * x; sxy += x * y;
     }
   double den = (double)n * sxx - sx * sx;
   if(MathAbs(den) < DBL_EPSILON) return(0.0);
   return(((double)n * sxy - sx * sy) / den);
  }

double BoundaryAt(const Setup &s, const int idx, const bool upper)
  {
   double x = (double)(idx - s.flagStartIdx);
   return(upper ? (s.upInter + s.upSlope * x) : (s.dnInter + s.dnSlope * x));
  }

//+------------------------------------------------------------------+
//| Chart-TF swings. Strictly causal: a swing at j needs bars         |
//| j-K .. j+K, so it may only be tested once bar j+K has closed.     |
//+------------------------------------------------------------------+
bool IsSwingLow(const double &low[], const int j, const int k, const int maxIdx)
  {
   if(j - k < 0 || j + k > maxIdx) return(false);
   double v = low[j];
   for(int m = 1; m <= k; m++)
     {
      if(low[j - m] <= v) return(false);
      if(low[j + m] <= v) return(false);
     }
   return(true);
  }

bool IsSwingHigh(const double &high[], const int j, const int k, const int maxIdx)
  {
   if(j - k < 0 || j + k > maxIdx) return(false);
   double v = high[j];
   for(int m = 1; m <= k; m++)
     {
      if(high[j - m] >= v) return(false);
      if(high[j + m] >= v) return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| HTF swings on the series-indexed snapshots                       |
//+------------------------------------------------------------------+
bool HtfIsSwingHigh(const int s, const int k)
  {
   if(s - k < 0 || s + k >= g_htfCopied) return(false);
   double v = g_htfHigh[s];
   for(int m = 1; m <= k; m++)
     {
      if(g_htfHigh[s - m] >= v) return(false);
      if(g_htfHigh[s + m] >= v) return(false);
     }
   return(true);
  }

bool HtfIsSwingLow(const int s, const int k)
  {
   if(s - k < 0 || s + k >= g_htfCopied) return(false);
   double v = g_htfLow[s];
   for(int m = 1; m <= k; m++)
     {
      if(g_htfLow[s - m] <= v) return(false);
      if(g_htfLow[s + m] <= v) return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| HTF bias at a chart-TF bar time.                                 |
//|   hshift = HTF bar containing t   -> still FORMING, never used    |
//|   h      = hshift + 1             -> last CLOSED HTF bar          |
//| Bias requires BOTH the EMA slope test and the structure test to   |
//| agree; disagreement yields NEUTRAL, which suppresses all signals. |
//+------------------------------------------------------------------+
int HtfBiasAt(const datetime t, double &strength)
  {
   strength = 0.0;

   int hshift = iBarShift(_Symbol, g_htf, t, false);
   if(hshift < 0) return(BIAS_NEUTRAL);

   int h = hshift + 1;                     // last HTF bar closed at time t
   if(h == g_biasCacheShift)
     {
      strength = g_biasCacheStr;
      return(g_biasCacheVal);
     }

   int    result = BIAS_NEUTRAL;
   double str    = 0.0;
   int    k      = InpHTF_SwingBars;

   //--- The swing search window is FIXED (InpHTF_SwingLookback bars),
   //--- not "as far back as the snapshot happens to reach". This is what
   //--- makes the bias at a given bar independent of how many HTF bars
   //--- were loaded, and therefore identical in a forward tester run and
   //--- in a history reload. A variable-width search would find a
   //--- different number of swings in a short snapshot than in a long
   //--- one and silently repaint the bias.
   int scanFrom = h + k;
   int scanTo   = h + k + InpHTF_SwingLookback;

   //--- room for: EMA back to h+3, ATR at h, and the whole fixed swing
   //--- window including the forward confirmation bars of its oldest bar
   int need = IMax(h + 4, scanTo + k + 1);

   if(need < g_htfCopied)
     {
      double atrH = g_htfAtr[h];
      if(atrH > 0.0)
        {
         //--- (a) EMA slope over the last 3 closed HTF bars,
         //---     normalised to HTF ATR
         double slopePerBar = (g_htfEma[h] - g_htfEma[h + 3]) / 3.0;
         double norm        = slopePerBar / atrH;
         str = MathAbs(norm);

         int emaBias = BIAS_NEUTRAL;
         if(norm >=  InpHTF_SlopeATR) emaBias = BIAS_BULLISH;
         if(norm <= -InpHTF_SlopeATR) emaBias = BIAS_BEARISH;

         //--- (b) structure: last 2 confirmed swing highs AND lows.
         //--- A swing at shift s is confirmed at shift s-k, so only
         //--- swings with s >= h+k were knowable at h.
         double sh[2];
         double sl[2];
         int    nh = 0, nl = 0;
         for(int s = scanFrom; s <= scanTo; s++)
           {
            if(nh >= 2 && nl >= 2) break;
            if(nh < 2 && HtfIsSwingHigh(s, k)) { sh[nh] = g_htfHigh[s]; nh++; }
            if(nl < 2 && HtfIsSwingLow(s, k))  { sl[nl] = g_htfLow[s];  nl++; }
           }

         int structBias = BIAS_NEUTRAL;
         if(nh == 2 && nl == 2)
           {
            //--- index 0 is the more recent of each pair
            bool hh = (sh[0] > sh[1]);
            bool hl = (sl[0] > sl[1]);
            bool lh = (sh[0] < sh[1]);
            bool ll = (sl[0] < sl[1]);
            if(hh && hl)      structBias = BIAS_BULLISH;
            else if(lh && ll) structBias = BIAS_BEARISH;
           }

         if(emaBias != BIAS_NEUTRAL && emaBias == structBias)
            result = emaBias;
        }
     }

   g_biasCacheShift = h;
   g_biasCacheVal   = result;
   g_biasCacheStr   = str;
   strength = str;
   return(result);
  }

//+------------------------------------------------------------------+
//| Quality score 0..100                                             |
//+------------------------------------------------------------------+
double ComputeQuality(const DirParams &p, const double tightness, const double poleATRmult,
                      const double eff, const double retr, const int flagBars,
                      const double biasStrength, const double breakStrength)
  {
   //--- tightness, lower is better (weight 20)
   double sTight = Clamp01(1.0 - tightness / MathMax(p.maxTightness, DBL_EPSILON)) * 20.0;
   //--- pole size above the minimum, saturating at 3x the minimum (15)
   double sPole  = Clamp01((poleATRmult - p.poleMinATR) / MathMax(2.0 * p.poleMinATR, DBL_EPSILON)) * 15.0;
   //--- directional efficiency above the minimum (15)
   double sEff   = Clamp01((eff - p.poleEff) / MathMax(1.0 - p.poleEff, DBL_EPSILON)) * 15.0;
   //--- retracement depth, ideal near 0.382 (15)
   double sRetr  = Clamp01(1.0 - MathAbs(retr - 0.382) / 0.236) * 15.0;
   //--- flag bar count, ideal mid-range (10)
   double mid    = 0.5 * (double)(p.flagMinBars + p.flagMaxBars);
   double half   = MathMax(0.5 * (double)(p.flagMaxBars - p.flagMinBars), 1.0);
   double sBars  = Clamp01(1.0 - MathAbs((double)flagBars - mid) / half) * 10.0;
   //--- HTF bias strength, saturating at 5x the slope threshold (15)
   double sBias  = Clamp01(biasStrength / MathMax(5.0 * InpHTF_SlopeATR, DBL_EPSILON)) * 15.0;
   //--- breakout close strength, saturating at 1 ATR beyond the boundary (10)
   double sBreak = Clamp01(breakStrength) * 10.0;

   double total = sTight + sPole + sEff + sRetr + sBars + sBias + sBreak;
   if(total < 0.0)   total = 0.0;
   if(total > 100.0) total = 100.0;
   return(total);
  }

//+------------------------------------------------------------------+
//| Drawing - bounded objects only, both rays OFF, never selectable  |
//+------------------------------------------------------------------+
void StyleLine(const string name, const color clr, const int width, const ENUM_LINE_STYLE style)
  {
   ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,      width);
   ObjectSetInteger(0, name, OBJPROP_STYLE,      style);
   ObjectSetInteger(0, name, OBJPROP_RAY_LEFT,   false);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT,  false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTED,   false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER,     0);
  }

void MakeTrend(const string name, const datetime t1, const double p1,
               const datetime t2, const double p2,
               const color clr, const int width, const ENUM_LINE_STYLE style)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_TIME,  0, t1);
   ObjectSetDouble (0, name, OBJPROP_PRICE, 0, p1);
   ObjectSetInteger(0, name, OBJPROP_TIME,  1, t2);
   ObjectSetDouble (0, name, OBJPROP_PRICE, 1, p2);
   StyleLine(name, clr, width, style);
  }

void MakeRect(const string name, const datetime t1, const double p1,
              const datetime t2, const double p2, const color clr)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_TIME,  0, t1);
   ObjectSetDouble (0, name, OBJPROP_PRICE, 0, p1);
   ObjectSetInteger(0, name, OBJPROP_TIME,  1, t2);
   ObjectSetDouble (0, name, OBJPROP_PRICE, 1, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE,      STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,      1);
   ObjectSetInteger(0, name, OBJPROP_FILL,       true);
   ObjectSetInteger(0, name, OBJPROP_BACK,       true);   // candles stay readable
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTED,   false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
  }

string SetupTag(const int id) { return(g_prefix + "s" + IntegerToString(id) + "_"); }

void DeleteSetupObjects(const int id) { ObjectsDeleteAll(0, SetupTag(id)); }

//--- keep at most InpMaxVisibleSetups setups drawn; delete the oldest
void RegisterDrawn(const int id)
  {
   int n = ArraySize(g_drawnIds);
   for(int k = 0; k < n; k++)
      if(g_drawnIds[k] == id) return;

   ArrayResize(g_drawnIds, n + 1);
   g_drawnIds[n] = id;

   int maxVis = IMax(InpMaxVisibleSetups, 1);
   while(ArraySize(g_drawnIds) > maxVis)
     {
      DeleteSetupObjects(g_drawnIds[0]);
      int cnt = ArraySize(g_drawnIds);
      for(int k = 1; k < cnt; k++) g_drawnIds[k - 1] = g_drawnIds[k];
      ArrayResize(g_drawnIds, cnt - 1);
     }
  }

//--- Draw / refresh a setup's objects at their current extent. Once a
//--- setup reaches a terminal state the caller stops calling this, so
//--- the objects freeze exactly where they were.
void DrawSetup(const int si, const datetime &time[], const int rates_total)
  {
   if(!InpDraw || rates_total <= 0) return;

   int    id  = g_setups[si].id;
   string tag = SetupTag(id);
   color  clr = (g_setups[si].isBull ? InpBullColor : InpBearColor);

   //--- pole: anchor bar -> pole extreme bar. No extension.
   MakeTrend(tag + "pole",
             g_setups[si].anchorTime,  g_setups[si].anchorPrice,
             g_setups[si].poleEndTime, g_setups[si].poleEndPrice,
             clr, 1, STYLE_DOT);

   //--- flag channel: flag bars + InpProjectBars forward, then stop.
   int      fs  = g_setups[si].flagStartIdx;
   int      fe  = g_setups[si].flagEndIdx + g_projectBars;
   datetime tFs = BarTime(time, rates_total, fs);
   datetime tFe = BarTime(time, rates_total, fe);
   double   dx  = (double)(fe - fs);

   MakeTrend(tag + "up", tFs, g_setups[si].upInter,
             tFe, g_setups[si].upInter + g_setups[si].upSlope * dx,
             clr, 1, STYLE_SOLID);
   MakeTrend(tag + "dn", tFs, g_setups[si].dnInter,
             tFe, g_setups[si].dnInter + g_setups[si].dnSlope * dx,
             clr, 1, STYLE_SOLID);

   //--- break level: from the break bar forward InpProjectBars only,
   //--- never a horizontal line across the chart.
   if(g_setups[si].breakIdx > 0)
     {
      datetime t1 = g_setups[si].breakTime;
      datetime t2 = BarTime(time, rates_total, g_setups[si].breakIdx + g_projectBars);
      MakeTrend(tag + "brk", t1, g_setups[si].breakLevel,
                t2, g_setups[si].breakLevel, clr, 1, STYLE_SOLID);

      //--- retest zone: bounded to the retest window bars
      int    rw  = (g_setups[si].isBull ? g_bull.retestWindow : g_bear.retestWindow);
      double tol = (g_setups[si].isBull ? g_bull.retestTolATR : g_bear.retestTolATR)
                   * g_setups[si].atrAtBreak;
      if(tol > 0.0)
        {
         datetime r1 = g_setups[si].breakTime;
         datetime r2 = BarTime(time, rates_total, g_setups[si].breakIdx + rw);
         MakeRect(tag + "rt", r1, g_setups[si].breakLevel + tol,
                  r2, g_setups[si].breakLevel - tol, clr);
        }
     }

   g_setups[si].drawn = true;
   RegisterDrawn(id);
  }

//--- redraw only on state change, and only for recent setups
void MaybeDraw(const int si, const int i, const datetime &time[], const int rates_total)
  {
   if(!InpDraw) return;
   if(i < rates_total - IMax(InpHistoryBarsToDraw, 1)) return;
   if(g_setups[si].drawn && g_setups[si].lastDrawnState == g_setups[si].state) return;
   DrawSetup(si, time, rates_total);
   g_setups[si].lastDrawnState = g_setups[si].state;
  }

//+------------------------------------------------------------------+
//| Signal emission - writes the buffer once, for this bar, forever  |
//+------------------------------------------------------------------+
void EmitSignal(const int type, const int i, const datetime t, const double plotPrice,
                const double entry, const double atr, const Setup &s)
  {
   int n = ArraySize(g_sigs);
   ArrayResize(g_sigs, n + 1);

   g_sigs[n].t           = t;
   g_sigs[n].idx         = i;
   g_sigs[n].type        = type;
   g_sigs[n].isBull      = (type == SIG_BULL_CONFIRMED || type == SIG_BULL_BREAKONLY);
   g_sigs[n].confirmed   = (type == SIG_BULL_CONFIRMED || type == SIG_BEAR_CONFIRMED);
   g_sigs[n].plotPrice   = plotPrice;
   g_sigs[n].entryPrice  = entry;
   g_sigs[n].atr         = atr;
   g_sigs[n].quality     = s.quality;
   g_sigs[n].poleATRmult = s.poleATRmult;
   g_sigs[n].tightness   = s.tightness;
   g_sigs[n].retracePct  = s.retracePct;
   g_sigs[n].poleEff     = s.poleEff;
   g_sigs[n].flagBars    = s.flagBars;
   g_sigs[n].bias        = s.biasAtForm;
   g_sigs[n].breakTime   = s.breakTime;
   g_sigs[n].retestTime  = s.retestTime;
   g_sigs[n].flushed     = false;

   switch(type)
     {
      case SIG_BULL_CONFIRMED: BufBullConf[i] = plotPrice; break;
      case SIG_BEAR_CONFIRMED: BufBearConf[i] = plotPrice; break;
      case SIG_BULL_BREAKONLY: BufBullBO[i]   = plotPrice; break;
      case SIG_BEAR_BREAKONLY: BufBearBO[i]   = plotPrice; break;
     }
   BufQuality[i] = s.quality;

   if(InpVerboseLog)
      PrintFormat("FSP %s %s @ %s | quality=%.1f poleATR=%.2f eff=%.2f tight=%.3f retr=%.1f%% flagBars=%d bias=%d",
                  (g_sigs[n].isBull ? "BULL" : "BEAR"),
                  (g_sigs[n].confirmed ? "CONFIRMED" : "BREAKOUT_ONLY"),
                  TimeToString(t, TIME_DATE | TIME_MINUTES),
                  s.quality, s.poleATRmult, s.poleEff, s.tightness,
                  s.retracePct * 100.0, s.flagBars, s.biasAtForm);
  }

//+------------------------------------------------------------------+
//| STAGE 1 (pole) + STAGE 2 (flag): try to detect a pattern whose   |
//| LAST flag bar is i. Reads indices <= i only.                     |
//+------------------------------------------------------------------+
bool TryDetect(const bool isBull, const int i, const int bias, const double biasStrength,
               const double &high[], const double &low[], const double &close[],
               const datetime &time[], const int maxIdx)
  {
   DirParams p;
   if(isBull) p = g_bull; else p = g_bear;

   double atr = g_atr[i];
   if(atr <= 0.0) return(false);

   int K = InpSwingConfirmBars;

   //--- longest flag first: prefer the fuller structure
   for(int fb = p.flagMaxBars; fb >= p.flagMinBars; fb--)
     {
      int poleEnd = i - fb;                       // pole extreme bar
      if(poleEnd - p.poleMaxBars - K - 1 < 0) continue;

      //--- STAGE 1: anchor = most recent CONFIRMED swing before poleEnd
      int anchor = -1;
      for(int a = poleEnd - 1; a >= poleEnd - p.poleMaxBars; a--)
        {
         if(a - K < 0) break;
         if(a + K > i) continue;                  // not yet confirmed at bar i
         if(isBull ? IsSwingLow(low, a, K, maxIdx) : IsSwingHigh(high, a, K, maxIdx))
           { anchor = a; break; }
        }
      if(anchor < 0) continue;

      //--- a flag must not span a session break
      if(RangeHasGap(time, anchor, i)) continue;

      //--- the pole extreme must actually be the extreme of [anchor, poleEnd]
      double anchorPrice = (isBull ? low[anchor] : high[anchor]);
      double extreme     = (isBull ? high[poleEnd] : low[poleEnd]);
      bool   isExtreme   = true;
      for(int k = anchor; k <= poleEnd; k++)
        {
         if(isBull) { if(high[k] > extreme) { isExtreme = false; break; } }
         else       { if(low[k]  < extreme) { isExtreme = false; break; } }
        }
      if(!isExtreme) continue;

      double poleHeight = (isBull ? (extreme - anchorPrice) : (anchorPrice - extreme));
      if(poleHeight <= 0.0) continue;

      //--- pole height in ATR multiples (no absolute price thresholds)
      double poleATRmult = poleHeight / atr;
      if(poleATRmult < p.poleMinATR) continue;

      //--- directional efficiency = |net move| / sum of bar ranges
      double sumRange = 0.0;
      for(int k = anchor; k <= poleEnd; k++) sumRange += (high[k] - low[k]);
      if(sumRange <= 0.0) continue;
      double eff = poleHeight / sumRange;
      if(eff < p.poleEff) continue;

      //--- max counter-retracement inside the pole
      double run    = (isBull ? high[anchor] : low[anchor]);
      double maxCtr = 0.0;
      for(int k = anchor; k <= poleEnd; k++)
        {
         if(isBull)
           {
            if(high[k] > run) run = high[k];
            double ctr = run - low[k];
            if(ctr > maxCtr) maxCtr = ctr;
           }
         else
           {
            if(low[k] < run) run = low[k];
            double ctr = high[k] - run;
            if(ctr > maxCtr) maxCtr = ctr;
           }
        }
      if(maxCtr > p.poleMaxRetrace * poleHeight) continue;

      //--- STAGE 2: flag bars are poleEnd+1 .. i
      int fs = poleEnd + 1;
      int n  = i - poleEnd;                       // == fb

      double fHigh = high[fs], fLow = low[fs];
      for(int k = fs; k <= i; k++)
        {
         if(high[k] > fHigh) fHigh = high[k];
         if(low[k]  < fLow)  fLow  = low[k];
        }

      //--- retracement of the pole
      double retr = (isBull ? (extreme - fLow) / poleHeight
                            : (fHigh - extreme) / poleHeight);
      if(retr < p.minRetrace || retr > p.maxRetrace) continue;

      //--- the flag must not undo the pole
      if(isBull) { if(fLow  <= anchorPrice) continue; }
      else       { if(fHigh >= anchorPrice) continue; }

      //--- TIGHTNESS: flag_range / pole_height
      double flagRange = fHigh - fLow;
      double tight     = flagRange / poleHeight;
      if(tight > p.maxTightness) continue;

      //--- slope must be counter-trend or flat; reject sloping WITH the pole
      double slope = LsSlope(close, fs, n);
      double tol   = p.slopeTolATR * atr;
      if(isBull) { if(slope >  tol) continue; }
      else       { if(slope < -tol) continue; }

      //--- boundaries: LS on the flag bars only, enveloped
      double upS, upI, dnS, dnI;
      FitBoundary(high, fs, n, true,  upS, upI);
      FitBoundary(low,  fs, n, false, dnS, dnI);

      //--- accept
      Setup s;
      s.id             = g_nextSetupId++;
      s.isBull         = isBull;
      s.state          = ST_FLAG_FORMED;
      s.lastDrawnState = ST_IDLE;
      s.anchorIdx      = anchor;
      s.anchorTime     = time[anchor];
      s.anchorPrice    = anchorPrice;
      s.poleEndIdx     = poleEnd;
      s.poleEndTime    = time[poleEnd];
      s.poleEndPrice   = extreme;
      s.poleHeight     = poleHeight;
      s.poleATRmult    = poleATRmult;
      s.poleEff        = eff;
      s.flagStartIdx   = fs;
      s.flagEndIdx     = i;
      s.flagStartTime  = time[fs];
      s.flagEndTime    = time[i];
      s.flagBars       = n;
      s.upSlope        = upS;
      s.upInter        = upI;
      s.dnSlope        = dnS;
      s.dnInter        = dnI;
      s.flagRange      = flagRange;
      s.tightness      = tight;
      s.retracePct     = retr;
      s.atrAtFlag      = atr;
      s.breakIdx       = 0;
      s.breakTime      = 0;
      s.breakLevel     = 0.0;
      s.breakStrength  = 0.0;
      s.atrAtBreak     = atr;
      s.retestIdx      = 0;
      s.retestTime     = 0;
      s.biasAtForm     = bias;
      s.biasStrength   = biasStrength;
      s.quality        = 0.0;
      s.drawn          = false;

      int cnt = ArraySize(g_setups);
      ArrayResize(g_setups, cnt + 1);
      g_setups[cnt] = s;

      if(isBull) g_liveBull = cnt; else g_liveBear = cnt;

      if(InpVerboseLog)
         PrintFormat("FSP setup #%d %s FLAG_FORMED @ %s | poleATR=%.2f eff=%.2f tight=%.3f retr=%.1f%% bars=%d",
                     s.id, (isBull ? "BULL" : "BEAR"),
                     TimeToString(time[i], TIME_DATE | TIME_MINUTES),
                     poleATRmult, eff, tight, retr * 100.0, n);
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Advance one live setup by one closed bar                         |
//+------------------------------------------------------------------+
void AdvanceSetup(const int si, const int i, const int bias,
                  const double &open[], const double &high[], const double &low[],
                  const double &close[], const datetime &time[], const long &tickvol[])
  {
   if(i <= g_setups[si].flagEndIdx) return;

   bool isBull = g_setups[si].isBull;
   DirParams p;
   if(isBull) p = g_bull; else p = g_bear;

   double atr = g_atr[i];
   if(atr <= 0.0) return;

   //--- HTF bias flip (including a flip to NEUTRAL) before confirmation
   if(bias != g_setups[si].biasAtForm)
     {
      g_setups[si].state = ST_INVALIDATED;
      return;
     }

   double up = BoundaryAt(g_setups[si], i, true);
   double dn = BoundaryAt(g_setups[si], i, false);

   //--- close past the pole origin
   if(isBull)
     {
      if(close[i] < g_setups[si].anchorPrice) { g_setups[si].state = ST_INVALIDATED; return; }
     }
   else
     {
      if(close[i] > g_setups[si].anchorPrice) { g_setups[si].state = ST_INVALIDATED; return; }
     }

   //------------------------------------------------------------------
   if(g_setups[si].state == ST_FLAG_FORMED)
     {
      //--- close beyond the opposite flag boundary
      if(isBull) { if(close[i] < dn) { g_setups[si].state = ST_INVALIDATED; return; } }
      else       { if(close[i] > up) { g_setups[si].state = ST_INVALIDATED; return; } }

      //--- no break within the break window
      if(i - g_setups[si].flagEndIdx > p.breakWindow)
        { g_setups[si].state = ST_INVALIDATED; return; }

      //--- BROKEN: a CLOSE beyond the boundary by the ATR buffer.
      //--- Wick-only breaks do not qualify.
      double buf = p.breakBufATR * atr;
      bool   brk = (isBull ? (close[i] >= up + buf) : (close[i] <= dn - buf));
      if(!brk) return;

      //--- optional volume filter. Off by default: MT5 tick volume is
      //--- broker-dependent and meaningless on synthetics.
      if(InpUseVolume)
        {
         double avg = 0.0;
         for(int k = g_setups[si].flagStartIdx; k <= g_setups[si].flagEndIdx; k++)
            avg += (double)tickvol[k];
         avg /= (double)g_setups[si].flagBars;
         if(avg > 0.0 && (double)tickvol[i] <= avg) return;
        }

      double level = (isBull ? up : dn);
      g_setups[si].state         = ST_BROKEN;
      g_setups[si].breakIdx      = i;
      g_setups[si].breakTime     = time[i];
      g_setups[si].breakLevel    = level;
      g_setups[si].breakStrength = MathAbs(close[i] - level) / atr;
      g_setups[si].atrAtBreak    = atr;
      g_setups[si].quality       = ComputeQuality(p, g_setups[si].tightness, g_setups[si].poleATRmult,
                                                  g_setups[si].poleEff, g_setups[si].retracePct,
                                                  g_setups[si].flagBars, g_setups[si].biasStrength,
                                                  g_setups[si].breakStrength);
      return;
     }

   //------------------------------------------------------------------
   if(g_setups[si].state == ST_BROKEN || g_setups[si].state == ST_RETESTING)
     {
      int age = i - g_setups[si].breakIdx;

      //--- close beyond the opposite flag boundary
      if(isBull) { if(close[i] < dn) { g_setups[si].state = ST_INVALIDATED; return; } }
      else       { if(close[i] > up) { g_setups[si].state = ST_INVALIDATED; return; } }

      double level = g_setups[si].breakLevel;
      double tol   = p.retestTolATR * g_setups[si].atrAtBreak;

      //--- RETESTING: price trades back into the tolerance band
      if(g_setups[si].state == ST_BROKEN && age <= p.retestWindow)
        {
         bool touched = (isBull ? (low[i] <= level + tol) : (high[i] >= level - tol));
         if(touched)
           {
            g_setups[si].state      = ST_RETESTING;
            g_setups[si].retestIdx  = i;
            g_setups[si].retestTime = time[i];
           }
        }

      //--- CONFIRMED: a closed bar rejects from the retest zone - it
      //--- closes in the breakout direction AND beyond the broken level.
      //--- The signal is emitted HERE, on this bar. Not earlier.
      if(g_setups[si].state == ST_RETESTING && age <= p.retestWindow)
        {
         bool rejects = (isBull ? (close[i] > open[i] && close[i] > level)
                                : (close[i] < open[i] && close[i] < level));
         if(rejects)
           {
            g_setups[si].state = ST_CONFIRMED;
            double plot = (isBull ? (low[i] - 0.5 * atr) : (high[i] + 0.5 * atr));
            EmitSignal((isBull ? SIG_BULL_CONFIRMED : SIG_BEAR_CONFIRMED),
                       i, time[i], plot, close[i], atr, g_setups[si]);
            return;
           }
        }

      //--- window expiry without confirmation -> BREAKOUT_ONLY, emitted
      //--- on the expiry bar (the break bar could not have known this
      //--- outcome). Kept as a separate population, never discarded.
      if(age >= p.retestWindow)
        {
         g_setups[si].state = ST_INVALIDATED;
         double plot = (isBull ? (low[i] - 0.5 * atr) : (high[i] + 0.5 * atr));
         EmitSignal((isBull ? SIG_BULL_BREAKONLY : SIG_BEAR_BREAKONLY),
                    i, time[i], plot, close[i], atr, g_setups[si]);
        }
     }
  }

//+------------------------------------------------------------------+
//| One closed bar of the causal pipeline                            |
//+------------------------------------------------------------------+
void ProcessBar(const int i, const double &open[], const double &high[], const double &low[],
                const double &close[], const datetime &time[], const long &tickvol[],
                const int lastClosed, const int rates_total)
  {
   double biasStrength = 0.0;
   int    bias = HtfBiasAt(time[i], biasStrength);
   BufBias[i]  = (double)bias;

   //--- advance the (at most two) live setups
   if(g_liveBull >= 0)
     {
      AdvanceSetup(g_liveBull, i, bias, open, high, low, close, time, tickvol);
      MaybeDraw(g_liveBull, i, time, rates_total);
      if(g_setups[g_liveBull].state == ST_CONFIRMED ||
         g_setups[g_liveBull].state == ST_INVALIDATED)
         g_liveBull = -1;                      // objects freeze at their final extent
     }
   if(g_liveBear >= 0)
     {
      AdvanceSetup(g_liveBear, i, bias, open, high, low, close, time, tickvol);
      MaybeDraw(g_liveBear, i, time, rates_total);
      if(g_setups[g_liveBear].state == ST_CONFIRMED ||
         g_setups[g_liveBear].state == ST_INVALIDATED)
         g_liveBear = -1;
     }

   //--- NEUTRAL bias suppresses all signals
   if(bias == BIAS_NEUTRAL) return;

   //--- one live setup per direction at a time
   if(bias == BIAS_BULLISH && g_liveBull < 0)
     {
      if(TryDetect(true, i, bias, biasStrength, high, low, close, time, lastClosed))
         MaybeDraw(g_liveBull, i, time, rates_total);
     }
   if(bias == BIAS_BEARISH && g_liveBear < 0)
     {
      if(TryDetect(false, i, bias, biasStrength, high, low, close, time, lastClosed))
         MaybeDraw(g_liveBear, i, time, rates_total);
     }
  }

//+------------------------------------------------------------------+
//| CSV export                                                       |
//+------------------------------------------------------------------+
void CsvWriteHeader(void)
  {
   if(!InpExportCSV) return;
   int h = FileOpen(g_csvFile, FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(h == INVALID_HANDLE)
     {
      PrintFormat("FSP: cannot open %s for writing (err %d)", g_csvFile, GetLastError());
      return;
     }
   FileWrite(h,
             "datetime", "symbol", "timeframe", "direction",
             "pole_ATR", "tightness", "retracement_pct", "flag_bars",
             "htf_bias", "quality_score", "break_bar_time", "retest_bar_time",
             "confirmed_bool",
             "MFE_10", "MFE_20", "MFE_50",
             "MAE_10", "MAE_20", "MAE_50",
             "pole_efficiency");
   FileClose(h);
   g_csvRowsWritten = 0;
  }

//--- MFE/MAE are forward-looking by definition. They are computed only
//--- once the whole horizon is fully closed history, written to file
//--- only, and never read back into the signal path.
void FlushCsvRows(const double &high[], const double &low[], const int rates_total)
  {
   if(!InpExportCSV) return;

   int lastClosed = rates_total - 2;
   int n = ArraySize(g_sigs);

   bool any = false;
   for(int k = 0; k < n; k++)
      if(!g_sigs[k].flushed && g_sigs[k].idx + FSP_HMAX <= lastClosed) { any = true; break; }
   if(!any) return;

   int fh = FileOpen(g_csvFile, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(fh == INVALID_HANDLE) return;
   FileSeek(fh, 0, SEEK_END);

   int horiz[3];
   horiz[0] = FSP_H1; horiz[1] = FSP_H2; horiz[2] = FSP_H3;

   for(int k = 0; k < n; k++)
     {
      if(g_sigs[k].flushed) continue;
      int si = g_sigs[k].idx;
      if(si + FSP_HMAX > lastClosed) continue;

      double atr = g_sigs[k].atr;
      if(atr <= 0.0) { g_sigs[k].flushed = true; continue; }

      double mfe[3];
      double mae[3];
      for(int q = 0; q < 3; q++)
        {
         double hi = high[si + 1], lo = low[si + 1];
         for(int m = si + 1; m <= si + horiz[q]; m++)
           {
            if(high[m] > hi) hi = high[m];
            if(low[m]  < lo) lo = low[m];
           }
         if(g_sigs[k].isBull)
           {
            mfe[q] = (hi - g_sigs[k].entryPrice) / atr;
            mae[q] = (g_sigs[k].entryPrice - lo) / atr;
           }
         else
           {
            mfe[q] = (g_sigs[k].entryPrice - lo) / atr;
            mae[q] = (hi - g_sigs[k].entryPrice) / atr;
           }
        }

      FileWrite(fh,
                TimeToString(g_sigs[k].t, TIME_DATE | TIME_MINUTES | TIME_SECONDS),
                _Symbol,
                TfToString((ENUM_TIMEFRAMES)_Period),
                (g_sigs[k].isBull ? "BULL" : "BEAR"),
                DoubleToString(g_sigs[k].poleATRmult, 4),
                DoubleToString(g_sigs[k].tightness, 4),
                DoubleToString(g_sigs[k].retracePct * 100.0, 4),
                IntegerToString(g_sigs[k].flagBars),
                IntegerToString(g_sigs[k].bias),
                DoubleToString(g_sigs[k].quality, 2),
                (g_sigs[k].breakTime  > 0 ? TimeToString(g_sigs[k].breakTime,  TIME_DATE | TIME_MINUTES | TIME_SECONDS) : ""),
                (g_sigs[k].retestTime > 0 ? TimeToString(g_sigs[k].retestTime, TIME_DATE | TIME_MINUTES | TIME_SECONDS) : ""),
                (g_sigs[k].confirmed ? "1" : "0"),
                DoubleToString(mfe[0], 4), DoubleToString(mfe[1], 4), DoubleToString(mfe[2], 4),
                DoubleToString(mae[0], 4), DoubleToString(mae[1], 4), DoubleToString(mae[2], 4),
                DoubleToString(g_sigs[k].poleEff, 4));

      g_sigs[k].flushed = true;
      g_csvRowsWritten++;
     }
   FileClose(fh);
  }

//+------------------------------------------------------------------+
//| Repaint self-test                                                |
//+------------------------------------------------------------------+
bool WriteDump(const string fname)
  {
   int h = FileOpen(fname, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("FSP: cannot write dump %s (err %d)", fname, GetLastError());
      return(false);
     }
   int n = ArraySize(g_sigs);
   for(int k = 0; k < n; k++)
     {
      //--- fixed-width formatting so the bytes are deterministic
      string line = TimeToString(g_sigs[k].t, TIME_DATE | TIME_MINUTES | TIME_SECONDS) + ";" +
                    IntegerToString(g_sigs[k].type) + ";" +
                    DoubleToString(g_sigs[k].plotPrice, g_digits) + ";" +
                    DoubleToString(g_sigs[k].quality, 2);
      FileWrite(h, line);
     }
   FileClose(h);
   return(true);
  }

bool FilesIdentical(const string a, const string b, long &firstDiff)
  {
   firstDiff = -1;
   int ha = FileOpen(a, FILE_READ | FILE_BIN);
   int hb = FileOpen(b, FILE_READ | FILE_BIN);
   if(ha == INVALID_HANDLE || hb == INVALID_HANDLE)
     {
      if(ha != INVALID_HANDLE) FileClose(ha);
      if(hb != INVALID_HANDLE) FileClose(hb);
      return(false);
     }

   long sa = (long)FileSize(ha);
   long sb = (long)FileSize(hb);
   long lim = (sa < sb ? sa : sb);

   bool same = (sa == sb);
   if(!same) firstDiff = lim;

   for(long k = 0; k < lim; k++)
     {
      uchar ca = (uchar)FileReadInteger(ha, CHAR_VALUE);
      uchar cb = (uchar)FileReadInteger(hb, CHAR_VALUE);
      if(ca != cb) { same = false; firstDiff = k; break; }
     }

   FileClose(ha);
   FileClose(hb);
   return(same);
  }

//--- Called at OnDeinit only, i.e. once a run is complete. Calling it
//--- mid-run would compare a partial A against a complete B and report
//--- a false FAIL.
void RepaintTestFinalize(void)
  {
   if(!InpRepaintTest) return;
   if(ArraySize(g_sigs) == 0)
     {
      Print("FSP REPAINT TEST: no signals in this run, nothing to compare.");
      return;
     }

   if(!FileIsExist(g_dumpA))
     {
      if(WriteDump(g_dumpA))
         PrintFormat("FSP REPAINT TEST: baseline written -> %s (%d signals). "
                     "Re-run over the same range to produce B and compare.",
                     g_dumpA, ArraySize(g_sigs));
      return;
     }

   if(!WriteDump(g_dumpB)) return;

   long diff = -1;
   if(FilesIdentical(g_dumpA, g_dumpB, diff))
      PrintFormat("FSP REPAINT TEST: PASS - %s and %s are byte-identical (%d signals).",
                  g_dumpA, g_dumpB, ArraySize(g_sigs));
   else
      PrintFormat("FSP REPAINT TEST: FAIL - %s and %s differ at byte offset %s.",
                  g_dumpA, g_dumpB, IntegerToString(diff));
  }

//+------------------------------------------------------------------+
//| State reset (full recalculation)                                 |
//+------------------------------------------------------------------+
void ResetState(void)
  {
   ArrayResize(g_setups,  0);
   ArrayResize(g_sigs,    0);
   ArrayResize(g_drawnIds,0);
   g_nextSetupId       = 1;
   g_liveBull          = -1;
   g_liveBear          = -1;
   g_lastProcessedTime = 0;
   g_biasCacheShift    = -1;
   g_biasCacheVal      = BIAS_NEUTRAL;
   g_biasCacheStr      = 0.0;
   ObjectsDeleteAll(0, g_prefix);
   CsvWriteHeader();
  }

//+------------------------------------------------------------------+
//| HTF bias label. No win rate, no accuracy, no statistics.         |
//+------------------------------------------------------------------+
void UpdateBiasLabel(const int bias)
  {
   if(!InpShowBiasLabel) return;
   string name = g_prefix + "biaslabel";
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  10);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE,  20);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   9);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
     }
   string txt = "HTF " + TfToString(g_htf) + ": " +
                (bias == BIAS_BULLISH ? "BULLISH" : (bias == BIAS_BEARISH ? "BEARISH" : "NEUTRAL"));
   ObjectSetString (0, name, OBJPROP_TEXT,  txt);
   ObjectSetInteger(0, name, OBJPROP_COLOR,
                    (bias == BIAS_BULLISH ? InpBullColor
                     : (bias == BIAS_BEARISH ? InpBearColor : clrGray)));
  }

//+------------------------------------------------------------------+
//| Gap awareness. Sampled from the actual series - no hardcoded     |
//| symbol names. 24/7 synthetics simply report no gaps.             |
//+------------------------------------------------------------------+
void DetectGapAwareness(void)
  {
   datetime t[];
   ArraySetAsSeries(t, false);
   int got = CopyTime(_Symbol, _Period, 0, 5000, t);
   if(got < 100) { g_gapAware = true; return; }    // unknown -> be strict
   int gaps = 0;
   for(int k = 1; k < got; k++)
      if((long)(t[k] - t[k - 1]) > 2 * (long)g_periodSeconds) gaps++;
   g_gapAware = (gaps > 0);
  }

//+------------------------------------------------------------------+
//| Refresh HTF snapshots. Returns false on partial data.            |
//+------------------------------------------------------------------+
bool RefreshHtf(const int want)
  {
   //--- copy in ascending order first. Copy* resizes the destination
   //--- dynamic arrays, so the post-call ArraySize is the true count.
   ArraySetAsSeries(g_htfHigh, false);
   ArraySetAsSeries(g_htfLow,  false);
   ArraySetAsSeries(g_htfEma,  false);
   ArraySetAsSeries(g_htfAtr,  false);

   int c1 = CopyHigh  (_Symbol, g_htf, 0, want, g_htfHigh);
   int c2 = CopyLow   (_Symbol, g_htf, 0, want, g_htfLow);
   int c3 = CopyBuffer(g_hHtfEMA, 0, 0, want, g_htfEma);
   int c4 = CopyBuffer(g_hHtfATR, 0, 0, want, g_htfAtr);
   if(c1 <= 0 || c2 <= 0 || c3 <= 0 || c4 <= 0) return(false);

   //--- all four were requested from start_pos 0, so shift 0 is the same
   //--- (forming) HTF bar in each; a short copy only truncates the old
   //--- end. Taking the minimum keeps the four series aligned.
   int got = IMin(IMin(c1, c2), IMin(c3, c4));

   //--- hard minimum below which the bias cannot be computed at all.
   //--- Partial data must never produce a signal.
   int hardMin = InpHTF_EMA + InpHTF_ATR + InpHTF_SwingLookback +
                 3 * InpHTF_SwingBars + 12;
   if(got < hardMin) return(false);

   //--- then switch to shift indexing: index 0 = current (forming) bar,
   //--- which HtfBiasAt never reads (it starts at shift hshift+1 >= 1)
   ArraySetAsSeries(g_htfHigh, true);
   ArraySetAsSeries(g_htfLow,  true);
   ArraySetAsSeries(g_htfEma,  true);
   ArraySetAsSeries(g_htfAtr,  true);
   g_htfCopied = got;

   //--- the snapshot moved; the per-pass bias cache is stale
   g_biasCacheShift = -1;
   return(true);
  }

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- symbol properties, read once. 3/5-digit brokers and suffixed
   //--- symbols are handled by reading these, never by parsing names.
   g_digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(g_point    <= 0.0) g_point    = MathPow(10.0, -g_digits);
   if(g_tickSize <= 0.0) g_tickSize = g_point;
   g_periodSeconds = PeriodSeconds(_Period);

   //--- HTF resolution and validation
   g_htf = (InpHTF == PERIOD_CURRENT) ? AutoMapHTF((ENUM_TIMEFRAMES)_Period) : InpHTF;
   if(PeriodSeconds(g_htf) <= g_periodSeconds)
     {
      PrintFormat("FSP INIT FAILED: InpHTF (%s) must be strictly HIGHER than the chart timeframe (%s). "
                  "Choose a larger timeframe, or leave InpHTF = PERIOD_CURRENT for auto-mapping.",
                  TfToString(g_htf), TfToString((ENUM_TIMEFRAMES)_Period));
      return(INIT_PARAMETERS_INCORRECT);
     }

   //--- input sanity
   if(InpFlagMinBars < 2 || InpFlagMaxBars < InpFlagMinBars ||
      InpBear_FlagMinBars < 2 || InpBear_FlagMaxBars < InpBear_FlagMinBars)
     {
      Print("FSP INIT FAILED: flag bar range invalid (need 2 <= min <= max).");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpSwingConfirmBars < 1 || InpHTF_SwingBars < 1)
     {
      Print("FSP INIT FAILED: swing confirmation bars must be >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpMinRetrace >= InpMaxRetrace || InpBear_MinRetrace >= InpBear_MaxRetrace)
     {
      Print("FSP INIT FAILED: retracement min must be < max.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpATRPeriod < 1 || InpHTF_ATR < 1 || InpHTF_EMA < 2)
     {
      Print("FSP INIT FAILED: ATR/EMA periods out of range.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_projectBars = InpProjectBars;
   if(g_projectBars < 1)  g_projectBars = 1;
   if(g_projectBars > 15) g_projectBars = 15;

   //--- bull block
   g_bull.poleMaxBars    = InpPoleMaxBars;
   g_bull.poleMinATR     = InpPoleMinATR;
   g_bull.poleEff        = InpPoleEfficiency;
   g_bull.poleMaxRetrace = InpPoleMaxRetrace;
   g_bull.flagMinBars    = InpFlagMinBars;
   g_bull.flagMaxBars    = InpFlagMaxBars;
   g_bull.minRetrace     = InpMinRetrace;
   g_bull.maxRetrace     = InpMaxRetrace;
   g_bull.maxTightness   = InpMaxTightness;
   g_bull.slopeTolATR    = InpFlagSlopeTolATR;
   g_bull.breakBufATR    = InpBreakBufferATR;
   g_bull.retestTolATR   = InpRetestToleranceATR;
   g_bull.retestWindow   = InpRetestWindow;
   g_bull.breakWindow    = InpBreakWindow;

   //--- bear block: independent thresholds, not a mirror of the bull side
   g_bear.poleMaxBars    = InpBear_PoleMaxBars;
   g_bear.poleMinATR     = InpBear_PoleMinATR;
   g_bear.poleEff        = InpBear_PoleEfficiency;
   g_bear.poleMaxRetrace = InpBear_PoleMaxRetrace;
   g_bear.flagMinBars    = InpBear_FlagMinBars;
   g_bear.flagMaxBars    = InpBear_FlagMaxBars;
   g_bear.minRetrace     = InpBear_MinRetrace;
   g_bear.maxRetrace     = InpBear_MaxRetrace;
   g_bear.maxTightness   = InpBear_MinTightness;
   g_bear.slopeTolATR    = InpBear_FlagSlopeTolATR;
   g_bear.breakBufATR    = InpBear_BreakBufferATR;
   g_bear.retestTolATR   = InpBear_RetestToleranceATR;
   g_bear.retestWindow   = InpBear_RetestWindow;
   g_bear.breakWindow    = InpBear_BreakWindow;

   //--- buffers, non-series indexing everywhere
   SetIndexBuffer(0, BufBullConf, INDICATOR_DATA);
   SetIndexBuffer(1, BufBearConf, INDICATOR_DATA);
   SetIndexBuffer(2, BufBullBO,   INDICATOR_DATA);
   SetIndexBuffer(3, BufBearBO,   INDICATOR_DATA);
   SetIndexBuffer(4, BufBias,     INDICATOR_DATA);
   SetIndexBuffer(5, BufQuality,  INDICATOR_DATA);

   ArraySetAsSeries(BufBullConf, false);
   ArraySetAsSeries(BufBearConf, false);
   ArraySetAsSeries(BufBullBO,   false);
   ArraySetAsSeries(BufBearBO,   false);
   ArraySetAsSeries(BufBias,     false);
   ArraySetAsSeries(BufQuality,  false);

   PlotIndexSetInteger(0, PLOT_ARROW, 233);
   PlotIndexSetInteger(1, PLOT_ARROW, 234);
   PlotIndexSetInteger(2, PLOT_ARROW, 241);
   PlotIndexSetInteger(3, PLOT_ARROW, 242);
   for(int k = 0; k < 6; k++)
      PlotIndexSetDouble(k, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   //--- handles
   g_hATR    = iATR(_Symbol, _Period, InpATRPeriod);
   g_hHtfEMA = iMA (_Symbol, g_htf, InpHTF_EMA, 0, MODE_EMA, PRICE_CLOSE);
   g_hHtfATR = iATR(_Symbol, g_htf, InpHTF_ATR);
   if(g_hATR == INVALID_HANDLE || g_hHtfEMA == INVALID_HANDLE || g_hHtfATR == INVALID_HANDLE)
     {
      Print("FSP INIT FAILED: could not create ATR/EMA handles.");
      return(INIT_FAILED);
     }

   //--- warmup: the first bar index that can legitimately be evaluated
   g_warmup = InpATRPeriod + 2 * InpSwingConfirmBars +
              IMax(g_bull.poleMaxBars, g_bear.poleMaxBars) +
              IMax(g_bull.flagMaxBars, g_bear.flagMaxBars) + 10;

   //--- filenames
   string tag = SanitizeName(_Symbol) + "_" + SanitizeName(TfToString((ENUM_TIMEFRAMES)_Period));
   g_csvFile = "FSP_signals_" + tag + ".csv";
   g_dumpA   = "FSP_repaint_" + tag + "_A.csv";
   g_dumpB   = "FSP_repaint_" + tag + "_B.csv";

   DetectGapAwareness();

   IndicatorSetString (INDICATOR_SHORTNAME, "FlagStructurePro (HTF " + TfToString(g_htf) + ")");
   IndicatorSetInteger(INDICATOR_DIGITS, g_digits);

   ResetState();

   PrintFormat("FSP init: %s %s | HTF=%s | digits=%d point=%s ticksize=%s | gapAware=%s | warmup=%d bars",
               _Symbol, TfToString((ENUM_TIMEFRAMES)_Period), TfToString(g_htf),
               g_digits, DoubleToString(g_point, 10), DoubleToString(g_tickSize, 10),
               (g_gapAware ? "yes" : "no"), g_warmup);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit - full object cleanup                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   RepaintTestFinalize();
   ObjectsDeleteAll(0, g_prefix);
   if(g_hATR    != INVALID_HANDLE) IndicatorRelease(g_hATR);
   if(g_hHtfEMA != INVALID_HANDLE) IndicatorRelease(g_hHtfEMA);
   if(g_hHtfATR != INVALID_HANDLE) IndicatorRelease(g_hHtfATR);
   ChartRedraw(0);
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
   //--- non-series indexing throughout: index 0 = oldest bar,
   //--- rates_total-1 = the forming bar
   ArraySetAsSeries(time,        false);
   ArraySetAsSeries(open,        false);
   ArraySetAsSeries(high,        false);
   ArraySetAsSeries(low,         false);
   ArraySetAsSeries(close,       false);
   ArraySetAsSeries(tick_volume, false);

   if(rates_total < g_warmup + 5) return(prev_calculated);

   //--- chart-TF ATR snapshot. Partial data -> compute nothing.
   if(ArraySize(g_atr) != rates_total) ArrayResize(g_atr, rates_total);
   ArraySetAsSeries(g_atr, false);
   if(CopyBuffer(g_hATR, 0, 0, rates_total, g_atr) < rates_total)
      return(prev_calculated);

   //--- HTF snapshot. It must span the ENTIRE chart history being
   //--- evaluated, not a fixed recent window: the oldest chart bar we
   //--- process needs its HTF context present, otherwise that bar would
   //--- resolve to NEUTRAL in a history reload while resolving to a real
   //--- bias in a forward run - a repaint. Size it from the chart range.
   double htfRatio = (double)g_periodSeconds / (double)PeriodSeconds(g_htf);
   int    coverH   = (int)MathCeil((double)rates_total * htfRatio) + 8;
   int    wantH    = IMax(InpHTF_Bars,
                          coverH + InpHTF_EMA + InpHTF_ATR +
                          InpHTF_SwingLookback + 3 * InpHTF_SwingBars + 40);
   if(!RefreshHtf(wantH)) return(prev_calculated);

   //--- If the broker's HTF history is shallower than the chart range,
   //--- the oldest chart bars have no HTF context and resolve to NEUTRAL
   //--- (signals suppressed - the conservative direction). Say so once,
   //--- because it changes what a repaint A/B run covers.
   if(g_htfCopied < wantH && !g_htfShortWarned)
     {
      g_htfShortWarned = true;
      PrintFormat("FSP: HTF history is short - requested %d %s bars, got %d. "
                  "The oldest ~%d chart bars resolve to NEUTRAL bias and emit no signals. "
                  "Download more %s history before running the repaint A/B test.",
                  wantH, TfToString(g_htf), g_htfCopied,
                  (int)MathMax(0.0, (double)(wantH - g_htfCopied) / MathMax(htfRatio, DBL_EPSILON)),
                  TfToString(g_htf));
     }

   //--- full recalculation: replay the entire causal sequence
   bool full = (prev_calculated == 0);
   if(full)
     {
      ResetState();
      for(int k = 0; k < rates_total; k++)
        {
         BufBullConf[k] = EMPTY_VALUE;
         BufBearConf[k] = EMPTY_VALUE;
         BufBullBO[k]   = EMPTY_VALUE;
         BufBearBO[k]   = EMPTY_VALUE;
         BufBias[k]     = EMPTY_VALUE;
         BufQuality[k]  = EMPTY_VALUE;
        }
     }

   int lastClosed = rates_total - 2;      // the forming bar is never evaluated
   int start      = g_warmup;

   //--- incremental: resume strictly after the last bar that already
   //--- has a verdict. Keyed by TIME, so index shifts cannot cause a
   //--- re-evaluation of a bar whose value is already immutable.
   if(!full && g_lastProcessedTime > 0)
     {
      int resume = -1;
      for(int k = lastClosed; k >= 0; k--)
         if(time[k] <= g_lastProcessedTime) { resume = k + 1; break; }
      if(resume < 0) resume = start;
      start = IMax(start, resume);
     }

   for(int i = start; i <= lastClosed; i++)
     {
      ProcessBar(i, open, high, low, close, time, tick_volume, lastClosed, rates_total);
      g_lastProcessedTime = time[i];
     }

   //--- the forming bar carries nothing, ever
   int f = rates_total - 1;
   BufBullConf[f] = EMPTY_VALUE;
   BufBearConf[f] = EMPTY_VALUE;
   BufBullBO[f]   = EMPTY_VALUE;
   BufBearBO[f]   = EMPTY_VALUE;
   BufBias[f]     = EMPTY_VALUE;
   BufQuality[f]  = EMPTY_VALUE;

   //--- validation harness
   FlushCsvRows(high, low, rates_total);

   if(InpShowBiasLabel && lastClosed >= 0 && BufBias[lastClosed] != EMPTY_VALUE)
      UpdateBiasLabel((int)BufBias[lastClosed]);

   return(rates_total);
  }
//+------------------------------------------------------------------+
