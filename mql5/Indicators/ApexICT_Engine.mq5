//+------------------------------------------------------------------+
//|                                              ApexICT_Engine.mq5  |
//|                     Non-repainting ICT signal engine for MT5     |
//|                                                                  |
//|  Model v1 : Liquidity Sweep -> Market Structure Shift -> FVG     |
//|                                                                  |
//|  Non-repaint contract:                                           |
//|    * every calculation reads only closed bars (index >= 1)       |
//|    * a swing is published only after its confirmation bar closes |
//|    * a signal is emitted on the close of its entry bar and the   |
//|      arrow, SL and TP levels never move afterwards               |
//|    * every emitted signal is appended to a CSV journal at the    |
//|      moment it fires, so live output can be diffed against a     |
//|      recalculated history                                        |
//+------------------------------------------------------------------+
#property copyright "Apex ICT Engine"
#property link      ""
#property version   "1.00"
#property description "Sweep -> MSS -> FVG. Structure-derived SL/TP, graded setups, WATCH/TRIGGER alerts."

#property indicator_chart_window
#property indicator_buffers 3
#property indicator_plots   2

//--- plot 0 : buy arrows
#property indicator_label1  "Apex BUY"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrLime
#property indicator_width1  2

//--- plot 1 : sell arrows
#property indicator_label2  "Apex SELL"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrRed
#property indicator_width2  2

//+------------------------------------------------------------------+
//| Enums                                                            |
//+------------------------------------------------------------------+
enum ENUM_PRESET
  {
   PRESET_SCALP,      // Scalp  (fast structure, many signals)
   PRESET_INTRADAY,   // Intraday (balanced)  <- default
   PRESET_SWING,      // Swing  (slow structure, few signals)
   PRESET_CUSTOM      // Custom (use the manual inputs below)
  };

enum ENUM_ENTRY_MODE
  {
   ENTRY_FVG_EDGE,    // Near edge of the FVG (fills more often)
   ENTRY_FVG_CE,      // Consequent encroachment - 50% of the FVG
   ENTRY_FVG_FAR      // Far edge of the FVG (best price, fills least)
  };

enum ENUM_GRADE_FILTER
  {
   GRADE_ALL,         // B and better
   GRADE_A,           // A and better
   GRADE_APLUS        // A+ only
  };

enum ENUM_SYNTH_MODE
  {
   SYNTH_AUTO,        // Auto-detect from the symbol name (Deriv + Weltrade SyntX)
   SYNTH_OFF,         // Treat as an ordinary symbol
   SYNTH_FORCE_UP,    // Force spikes-up behaviour (Boom / GainX)
   SYNTH_FORCE_DOWN,  // Force spikes-down behaviour (Crash / PainX)
   SYNTH_MEASURED     // Ignore the name, take the bias from observed spikes
  };

//--- how an instrument's spike behaviour is decided
enum ENUM_SYNTH_FAMILY
  {
   FAM_NONE,          // ordinary instrument
   FAM_SPIKE_UP,      // Boom, GainX
   FAM_SPIKE_DOWN,    // Crash, PainX
   FAM_RANDOM,        // Step Index, FlipX - driftless random walk
   FAM_ADAPTIVE,      // SwitchX, BreakX, TrendX - direction changes by design
   FAM_SYMMETRIC      // FX Vol, SFX Vol - no spike mechanic
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Preset ==="
input ENUM_PRESET      InpPreset            = PRESET_INTRADAY; // Trading style preset
input int              InpMaxBars           = 5000;            // Bars of history to analyse (0 = all)

input group "=== Structure (used when preset = Custom) ==="
input int              InpSwingLookback     = 5;               // Major swing fractal lookback
input int              InpInternalLookback  = 2;               // Internal swing fractal lookback
input bool             InpBreakOnClose      = true;            // Break of structure needs a body close
input double           InpDisplacementATR   = 1.5;             // Displacement: leg range >= x * ATR

input group "=== Model: Sweep -> MSS -> FVG ==="
input int              InpSweepValidBars    = 25;              // Sweep stays valid for x bars
input int              InpMSSValidBars      = 20;              // Entry must fill within x bars of the MSS
input double           InpMinFVGatr         = 0.15;            // Ignore FVGs smaller than x * ATR
input ENUM_ENTRY_MODE  InpEntryMode         = ENTRY_FVG_CE;    // Where in the FVG to enter

input group "=== Risk engine ==="
input double           InpSLbufferATR       = 0.25;            // SL buffer beyond the swept wick (x * ATR)
input double           InpSpreadMult        = 2.0;             // Extra SL room = spread * x
input double           InpMinRR             = 2.0;             // Reject if opposing liquidity is nearer than x R
input double           InpTP1_R             = 1.0;             // TP1 in R
input double           InpTP3_R             = 3.0;             // TP3 in R
input double           InpRiskPercent       = 1.0;             // Risk % of balance (for the lot suggestion)

input group "=== Quality filter ==="
input ENUM_GRADE_FILTER InpMinGrade         = GRADE_ALL;       // Minimum grade to show and alert
input bool             InpRequireDiscount   = false;           // Longs only in discount / shorts only in premium

input group "=== Synthetic indices (Boom / Crash / Step) ==="
input ENUM_SYNTH_MODE  InpSynthMode         = SYNTH_AUTO;      // Synthetic handling
input double           InpSpikeATR          = 4.0;             // Spike bar: range >= x * ATR
input bool             InpSynthBiasFilter   = false;           // Hard-block signals against the spike direction
input int              InpSynthBiasScore    = 10;              // Grade points for trading with the spike direction

input group "=== Alerts ==="
input bool             InpAlertWatch        = true;            // WATCH alert when a setup arms
input bool             InpAlertTrigger      = true;            // TRIGGER alert when entry fills
input bool             InpAlertPopup        = true;            // Terminal popup
input bool             InpAlertPush         = true;            // Push notification to phone
input bool             InpAlertEmail        = false;           // Email
input bool             InpAlertTelegram     = false;           // Telegram (needs URL in Tools > Options > Expert Advisors)
input string           InpTgToken           = "";              // Telegram bot token
input string           InpTgChatID          = "";              // Telegram chat id

input group "=== Journal ==="
input bool             InpJournalEnabled    = true;            // Append every signal to a CSV journal
input string           InpJournalFile       = "ApexICT_Journal.csv"; // File name (MQL5/Files)

input group "=== Header block (top-left chart text) ==="
input bool             InpShowHeader        = true;            // Show the header block
input string           InpHdr1              = "Apex ICT Engine";                      // Header line 1
input string           InpHdr2              = "Follow Green & Red Arrows";            // Header line 2
input string           InpHdr3              = "Stop Loss: structure-based, per symbol"; // Header line 3
input string           InpHdr4              = "Take Profit: TP1 / TP2 / TP3 at liquidity"; // Header line 4
input color            InpHdr1Color         = clrBlack;        // Header line 1 colour
input color            InpHdr2Color         = clrBlue;         // Header line 2 colour
input color            InpHdr3Color         = clrRed;          // Header line 3 colour
input color            InpHdr4Color         = clrBlack;        // Header line 4 colour
input int              InpHdrFontSize       = 10;              // Header font size

input group "=== Outcome tracking ==="
input bool             InpTrackOutcomes     = true;            // Follow each signal to TP or SL
input bool             InpShowOutcomeMarks  = true;            // Print TP / SL marks where they were hit
input bool             InpShowStats         = true;            // Live win rate / expectancy panel

input group "=== Visuals ==="
input bool             InpShowZones         = false;           // Shade the risk and reward zones
input bool             InpShowEntryTag      = true;            // "BUY 0.05 at 1.23456" tag on the entry line
input bool             InpShowStructure     = true;            // Draw BOS / CHoCH / MSS labels
input bool             InpShowFVG           = true;            // Draw fair value gaps
input bool             InpShowRange         = true;            // Draw dealing range + equilibrium
input bool             InpShowLevels        = true;            // Draw entry / SL / TP for each signal
input bool             InpShowPanel         = true;            // On-chart info panel
input int              InpLevelBars         = 30;              // Length of the level lines in bars
input color            InpBuyColor          = clrLime;         // Buy colour
input color            InpSellColor         = clrRed;          // Sell colour
input color            InpSLColor           = clrCrimson;      // Stop loss colour
input color            InpTPColor           = clrBlack;        // Take profit colour
input color            InpFVGBullColor      = clrSeaGreen;     // Bullish FVG
input color            InpFVGBearColor      = clrIndianRed;    // Bearish FVG

//+------------------------------------------------------------------+
//| Buffers                                                          |
//+------------------------------------------------------------------+
double BufBuy[];
double BufSell[];
double BufATR[];

//+------------------------------------------------------------------+
//| Types                                                            |
//+------------------------------------------------------------------+
struct SwingPoint
  {
   int      bar;            // bar the swing actually sits on
   datetime time;
   double   price;
   bool     isHigh;
   bool     broken;         // has structure already traded through it
   int      confirmBar;     // bar on which it became known (never earlier than bar+lookback)
  };

struct FairValueGap
  {
   int      bar;            // third bar of the pattern - the bar that completes it
   datetime time;
   double   top;
   double   bottom;
   int      dir;            // +1 bullish (BISI), -1 bearish (SIBI)
   bool     mitigated;
  };

struct SweepEvent
  {
   bool     valid;
   int      bar;
   datetime time;
   double   level;          // the level that was taken
   double   extreme;        // the wick extreme of the sweep - the stop reference
   int      dir;            // +1 sell-side swept (bullish bias), -1 buy-side swept
   int      age;            // how long the swept level had been resting, in bars
  };

struct Setup
  {
   bool     active;
   int      dir;            // +1 long, -1 short
   double   entry;
   double   sl;
   double   tp1;
   double   tp2;            // nearest opposing liquidity - the draw
   double   tp3;
   int      mssBar;
   int      expiryBar;
   double   sweepExtreme;
   int      grade;
   string   gradeText;
   string   reason;
   bool     watchAlerted;
  };

//--- an emitted signal, followed forward to its outcome
struct TradeRec
  {
   int      idx;
   int      dir;
   int      entryBar;
   datetime entryTime;
   double   entry, sl, tp1, tp2, tp3;
   double   risk;
   int      grade;
   string   gradeText;
   bool     open;
   bool     hitTP1, hitTP2, hitTP3;
   int      result;          // 0 running, +1 target reached, -1 stopped
   double   rMultiple;
  };

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
#define PREFIX "AICT_"

SwingPoint   g_major[];
SwingPoint   g_internal[];
FairValueGap g_fvg[];
TradeRec     g_trades[];

//--- realised statistics, filled in by the outcome tracker
int          g_resolved      = 0;
int          g_wins          = 0;
int          g_losses        = 0;
double       g_sumR          = 0.0;
double       g_grossWinR     = 0.0;
double       g_grossLossR    = 0.0;
int          g_tp1Hits       = 0;

SweepEvent   g_sweepBull;      // sell-side liquidity taken -> looking for longs
SweepEvent   g_sweepBear;      // buy-side liquidity taken  -> looking for shorts

Setup        g_setup;

int          g_trendMajor    = 0;   // +1 / -1 / 0
int          g_trendInternal = 0;

int          g_swingLB       = 5;
int          g_intLB         = 2;
double       g_dispATR       = 1.5;

int               g_synthDir    = 0;         // +1 spikes up, -1 spikes down, 0 none
ENUM_SYNTH_FAMILY g_family      = FAM_NONE;
string            g_familyName  = "";

//--- observed spike behaviour, used to verify the name-based assumption
int          g_spikeUp       = 0;
int          g_spikeDown     = 0;
bool         g_dirWarned     = false;

datetime     g_lastAlertBar  = 0;
datetime     g_lastWatchBar  = 0;
datetime     g_lastProcessed = 0;   // guards against re-processing a bar
bool         g_liveMode      = false; // false while rebuilding history
int          g_signalCount   = 0;
int          g_lastSpikeBar  = -1;
int          g_lastSpikeDir  = 0;
string       g_lastSignalTxt = "no signals yet";

double       g_point         = 0.0;
int          g_digits        = 5;

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
string ObjName(const string tag, const int idx)
  {
   return StringFormat("%s%s_%d", PREFIX, tag, idx);
  }

double SpreadPrice()
  {
   double sp = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return sp * _Point;
  }

//--- snap a level to the instrument's tick grid. Synthetic indices and
//--- metals do not always have tick size == point, and a level off the
//--- grid is a level the server will not accept.
double NormalizePrice(const double p)
  {
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double v  = p;
   if(ts > 0.0) v = MathRound(p / ts) * ts;
   return NormalizeDouble(v, g_digits);
  }

//--- the broker's minimum distance between price and any SL or TP.
//--- A structurally perfect stop inside this distance is simply rejected,
//--- so every level is pushed out to at least this far.
double MinStopDistance()
  {
   long lvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double d = (double)lvl * _Point;
   double frz = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * _Point;
   return MathMax(d, frz);
  }

//+------------------------------------------------------------------+
//| Detect Boom / Crash / Step from the symbol name                  |
//+------------------------------------------------------------------+
//| Instrument classification.                                        |
//|                                                                   |
//| Deriv and Weltrade use opposite naming conventions for the number |
//| in the symbol: Crash 1000 means one spike per ~1000 ticks, while  |
//| PainX 400 means 400% leverage. Nothing is ever inferred from the  |
//| number for that reason - only from the family name.               |
//|                                                                   |
//| See docs/BROKER_RESEARCH.md for sources and confidence levels.    |
//+------------------------------------------------------------------+
void DetectSynthetic()
  {
   g_synthDir    = 0;
   g_family      = FAM_NONE;
   g_familyName  = "";

   if(InpSynthMode == SYNTH_OFF)      return;
   if(InpSynthMode == SYNTH_FORCE_UP)
     { g_synthDir = 1;  g_family = FAM_SPIKE_UP;   g_familyName = "forced spikes-up";   return; }
   if(InpSynthMode == SYNTH_FORCE_DOWN)
     { g_synthDir = -1; g_family = FAM_SPIKE_DOWN; g_familyName = "forced spikes-down"; return; }
   if(InpSynthMode == SYNTH_MEASURED)
     { g_family = FAM_ADAPTIVE; g_familyName = "measured from data"; return; }

   //--- normalise: upper case and strip spaces, so "Pain X 400" matches "PAINX"
   string s = _Symbol;
   StringToUpper(s);
   StringReplace(s, " ", "");

   //--- Deriv
   if(StringFind(s, "BOOM")  >= 0) { g_family = FAM_SPIKE_UP;   g_familyName = "Boom";  }
   else if(StringFind(s, "CRASH") >= 0) { g_family = FAM_SPIKE_DOWN; g_familyName = "Crash"; }
   else if(StringFind(s, "STEP")  >= 0) { g_family = FAM_RANDOM;     g_familyName = "Step Index"; }

   //--- Weltrade SyntX
   else if(StringFind(s, "GAINX")  >= 0) { g_family = FAM_SPIKE_UP;   g_familyName = "GainX";  }
   else if(StringFind(s, "PAINX")  >= 0) { g_family = FAM_SPIKE_DOWN; g_familyName = "PainX";  }
   else if(StringFind(s, "FLIPX")  >= 0) { g_family = FAM_RANDOM;     g_familyName = "FlipX";  }
   else if(StringFind(s, "SWITCHX")>= 0) { g_family = FAM_ADAPTIVE;   g_familyName = "SwitchX";}
   else if(StringFind(s, "BREAKX") >= 0) { g_family = FAM_ADAPTIVE;   g_familyName = "BreakX"; }
   else if(StringFind(s, "TRENDX") >= 0) { g_family = FAM_ADAPTIVE;   g_familyName = "TrendX"; }
   else if(StringFind(s, "SFXVOL") >= 0) { g_family = FAM_SYMMETRIC;  g_familyName = "SFX Vol";}
   else if(StringFind(s, "FXVOL")  >= 0) { g_family = FAM_SYMMETRIC;  g_familyName = "FX Vol"; }

   if(g_family == FAM_SPIKE_UP)   g_synthDir =  1;
   if(g_family == FAM_SPIKE_DOWN) g_synthDir = -1;
  }

//+------------------------------------------------------------------+
//| The spike direction actually observed in this symbol's bars.      |
//| Returns 0 until there is enough evidence to call it.              |
//+------------------------------------------------------------------+
int MeasuredSpikeDir()
  {
   int total = g_spikeUp + g_spikeDown;
   if(total < 10) return 0;                       // not enough spikes yet
   if(g_spikeUp   >= (int)MathCeil(total * 0.6))  return  1;
   if(g_spikeDown >= (int)MathCeil(total * 0.6))  return -1;
   return 0;                                      // genuinely two-sided
  }

//+------------------------------------------------------------------+
//| The bias the engine should actually trade with.                   |
//| Adaptive instruments change direction by design, so their bias    |
//| comes from observation, never from the name.                      |
//+------------------------------------------------------------------+
int EffectiveSpikeDir()
  {
   if(g_family == FAM_ADAPTIVE) return MeasuredSpikeDir();
   return g_synthDir;
  }

//+------------------------------------------------------------------+
//| Print what the engine reads from this broker's symbol spec.       |
//| Everything the risk engine does is derived from these numbers, so |
//| this line is the first thing to check on an unfamiliar broker.    |
//+------------------------------------------------------------------+
void ReportSymbolSpec()
  {
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickVal <= 0.0) tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   long stopsLvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLvl= SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   long tradeMode= SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);

   PrintFormat("ApexICT spec | %s | digits %d | point %s | tick size %s | "
               "tick value(loss) %s | stops level %d | freeze %d | spread %d",
               _Symbol, _Digits,
               DoubleToString(_Point, 8),
               DoubleToString(tickSize, 8),
               DoubleToString(tickVal, 5),
               (int)stopsLvl, (int)freezeLvl,
               (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));

   if(tickSize <= 0.0 || tickVal <= 0.0)
      Print("ApexICT WARNING: this symbol reports no tick size or tick value. "
            "Levels will still be correct but the lot suggestion will read 0.");

   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED)
      Print("ApexICT WARNING: trading is disabled for this symbol on this account. "
            "Signals will still print - they just cannot be executed here.");

   if(stopsLvl > 0)
      PrintFormat("ApexICT: broker requires stops at least %s away from price; "
                  "levels closer than that are pushed out automatically.",
                  DoubleToString(stopsLvl * _Point, _Digits));
  }

//+------------------------------------------------------------------+
//| Apply the style preset                                           |
//+------------------------------------------------------------------+
void ApplyPreset()
  {
   switch(InpPreset)
     {
      case PRESET_SCALP:
         g_swingLB = 3;  g_intLB = 2;  g_dispATR = 1.2;
         break;
      case PRESET_INTRADAY:
         g_swingLB = 5;  g_intLB = 2;  g_dispATR = 1.5;
         break;
      case PRESET_SWING:
         g_swingLB = 9;  g_intLB = 4;  g_dispATR = 2.0;
         break;
      default: // PRESET_CUSTOM
         g_swingLB = MathMax(1, InpSwingLookback);
         g_intLB   = MathMax(1, InpInternalLookback);
         g_dispATR = InpDisplacementATR;
         break;
     }
  }

//+------------------------------------------------------------------+
//| Reset all engine state                                           |
//+------------------------------------------------------------------+
void ClearSweep(SweepEvent &s)
  {
   s.valid = false; s.bar = -1; s.time = 0;
   s.level = 0.0;   s.extreme = 0.0; s.dir = 0; s.age = 0;
  }

//--- explicit field reset: ZeroMemory must not be used on a struct that
//--- contains strings, it corrupts the string references
void ClearSetup(Setup &s)
  {
   s.active = false; s.dir = 0;
   s.entry = 0.0; s.sl = 0.0; s.tp1 = 0.0; s.tp2 = 0.0; s.tp3 = 0.0;
   s.mssBar = -1; s.expiryBar = -1; s.sweepExtreme = 0.0;
   s.grade = 0; s.gradeText = ""; s.reason = ""; s.watchAlerted = false;
  }

void ResetState()
  {
   ArrayResize(g_major, 0);
   ArrayResize(g_internal, 0);
   ArrayResize(g_fvg, 0);
   ArrayResize(g_trades, 0);

   g_resolved = 0; g_wins = 0; g_losses = 0;
   g_sumR = 0.0;   g_grossWinR = 0.0; g_grossLossR = 0.0; g_tp1Hits = 0;
   g_spikeUp = 0;  g_spikeDown = 0;   g_dirWarned = false;

   ClearSweep(g_sweepBull);
   ClearSweep(g_sweepBear);
   ClearSetup(g_setup);

   g_trendMajor    = 0;
   g_trendInternal = 0;
   g_signalCount   = 0;
   g_lastProcessed = 0;
   g_lastSpikeBar  = -1;
   g_lastSpikeDir  = 0;
   g_lastSignalTxt = "no signals yet";
  }

//+------------------------------------------------------------------+
//| Swing detection - a fractal confirmed by `lb` bars on each side.  |
//| Called for candidate bar p only once bar p+lb has closed, so a    |
//| published swing can never be revised.                             |
//+------------------------------------------------------------------+
bool IsSwingHigh(const double &high[], const int p, const int lb, const int rates_total)
  {
   if(p - lb < 0 || p + lb >= rates_total) return false;
   double v = high[p];
   for(int k = 1; k <= lb; k++)
     {
      if(high[p-k] >  v) return false;
      if(high[p+k] >= v) return false;   // strict on the right removes duplicate plateaus
     }
   return true;
  }

bool IsSwingLow(const double &low[], const int p, const int lb, const int rates_total)
  {
   if(p - lb < 0 || p + lb >= rates_total) return false;
   double v = low[p];
   for(int k = 1; k <= lb; k++)
     {
      if(low[p-k] <  v) return false;
      if(low[p+k] <= v) return false;
     }
   return true;
  }

void PushSwing(SwingPoint &arr[], const int bar, const datetime t, const double price,
               const bool isHigh, const int confirmBar)
  {
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   arr[n].bar        = bar;
   arr[n].time       = t;
   arr[n].price      = price;
   arr[n].isHigh     = isHigh;
   arr[n].broken     = false;
   arr[n].confirmBar = confirmBar;
  }

//--- most recent unbroken swing of the requested side, -1 if none
int LastUnbroken(const SwingPoint &arr[], const bool wantHigh)
  {
   for(int i = ArraySize(arr) - 1; i >= 0; i--)
      if(arr[i].isHigh == wantHigh && !arr[i].broken)
         return i;
   return -1;
  }

int LastAny(const SwingPoint &arr[], const bool wantHigh)
  {
   for(int i = ArraySize(arr) - 1; i >= 0; i--)
      if(arr[i].isHigh == wantHigh)
         return i;
   return -1;
  }

//+------------------------------------------------------------------+
//| Nearest opposing liquidity above / below a price.                |
//| This is the realistic draw: the closest resting swing the market |
//| is likely to reach for. If none exists we return 0.              |
//+------------------------------------------------------------------+
double NearestOpposingLiquidity(const int dir, const double from)
  {
   double best = 0.0;
   for(int i = ArraySize(g_major) - 1; i >= 0; i--)
     {
      if(g_major[i].broken) continue;      // a level already traded through is not a pool
      if(dir > 0 && g_major[i].isHigh && g_major[i].price > from)
        {
         if(best == 0.0 || g_major[i].price < best) best = g_major[i].price;
        }
      if(dir < 0 && !g_major[i].isHigh && g_major[i].price < from)
        {
         if(best == 0.0 || g_major[i].price > best) best = g_major[i].price;
        }
     }
   return best;
  }

//+------------------------------------------------------------------+
//| Dealing range from the two most recent major swings              |
//+------------------------------------------------------------------+
bool DealingRange(double &lo, double &hi)
  {
   int ih = LastAny(g_major, true);
   int il = LastAny(g_major, false);
   if(ih < 0 || il < 0) return false;
   hi = g_major[ih].price;
   lo = g_major[il].price;
   return (hi > lo);
  }

//+------------------------------------------------------------------+
//| FVG detection on the three bars ending at index i                |
//+------------------------------------------------------------------+
void DetectFVG(const int i, const datetime &time[], const double &high[], const double &low[])
  {
   if(i < 2) return;
   double atr = BufATR[i];
   if(atr <= 0.0) return;

   double minSize = InpMinFVGatr * atr;

   //--- bullish: gap between the high of bar i-2 and the low of bar i
   if(low[i] > high[i-2] && (low[i] - high[i-2]) >= minSize)
     {
      int n = ArraySize(g_fvg);
      ArrayResize(g_fvg, n + 1);
      g_fvg[n].bar       = i;
      g_fvg[n].time      = time[i];
      g_fvg[n].top       = low[i];
      g_fvg[n].bottom    = high[i-2];
      g_fvg[n].dir       = 1;
      g_fvg[n].mitigated = false;
     }

   //--- bearish
   if(high[i] < low[i-2] && (low[i-2] - high[i]) >= minSize)
     {
      int n = ArraySize(g_fvg);
      ArrayResize(g_fvg, n + 1);
      g_fvg[n].bar       = i;
      g_fvg[n].time      = time[i];
      g_fvg[n].top       = low[i-2];
      g_fvg[n].bottom    = high[i];
      g_fvg[n].dir       = -1;
      g_fvg[n].mitigated = false;
     }
  }

//--- mark gaps that price has traded back into
void UpdateFVGMitigation(const int i, const double &high[], const double &low[])
  {
   for(int k = ArraySize(g_fvg) - 1; k >= 0; k--)
     {
      if(g_fvg[k].mitigated) continue;
      if(g_fvg[k].bar >= i)  continue;
      if(low[i] <= g_fvg[k].top && high[i] >= g_fvg[k].bottom)
         g_fvg[k].mitigated = true;
     }
  }

//--- the most recent unmitigated FVG of `dir` created between barFrom and barTo
int FindFVGInLeg(const int dir, const int barFrom, const int barTo)
  {
   for(int k = ArraySize(g_fvg) - 1; k >= 0; k--)
     {
      if(g_fvg[k].dir != dir)    continue;
      if(g_fvg[k].mitigated)     continue;
      if(g_fvg[k].bar < barFrom) break;
      if(g_fvg[k].bar > barTo)   continue;
      return k;
     }
   return -1;
  }

//+------------------------------------------------------------------+
//| Sweep detection.                                                 |
//| A sweep = price trades through a resting swing and closes back    |
//| on the original side within the same bar. On synthetics this is   |
//| a failed-breakout geometry rather than a real stop raid, but the  |
//| statistical shape is the same.                                    |
//+------------------------------------------------------------------+
void DetectSweeps(const int i, const datetime &time[], const double &high[],
                  const double &low[], const double &close[])
  {
   //--- sell-side taken: wick below a swing low, close back above it
   int il = LastUnbroken(g_major, false);
   if(il >= 0 && g_major[il].bar < i)
     {
      double lvl = g_major[il].price;
      if(low[i] < lvl && close[i] > lvl)
        {
         g_sweepBull.valid   = true;
         g_sweepBull.bar     = i;
         g_sweepBull.time    = time[i];
         g_sweepBull.level   = lvl;
         g_sweepBull.extreme = low[i];
         g_sweepBull.dir     = 1;
         g_sweepBull.age     = i - g_major[il].bar;
        }
     }

   //--- buy-side taken: wick above a swing high, close back below it
   int ih = LastUnbroken(g_major, true);
   if(ih >= 0 && g_major[ih].bar < i)
     {
      double lvl = g_major[ih].price;
      if(high[i] > lvl && close[i] < lvl)
        {
         g_sweepBear.valid   = true;
         g_sweepBear.bar     = i;
         g_sweepBear.time    = time[i];
         g_sweepBear.level   = lvl;
         g_sweepBear.extreme = high[i];
         g_sweepBear.dir     = -1;
         g_sweepBear.age     = i - g_major[ih].bar;
        }
     }

   //--- expire stale sweeps
   if(g_sweepBull.valid && (i - g_sweepBull.bar) > InpSweepValidBars) g_sweepBull.valid = false;
   if(g_sweepBear.valid && (i - g_sweepBear.bar) > InpSweepValidBars) g_sweepBear.valid = false;
  }

//+------------------------------------------------------------------+
//| Structure break at bar i.                                        |
//| Returns +1 bullish break, -1 bearish break, 0 none, and reports   |
//| whether it was a CHoCH (against the prevailing leg).              |
//+------------------------------------------------------------------+
int DetectBreak(SwingPoint &arr[], int &trend, const int i,
                const double &high[], const double &low[], const double &close[],
                bool &isChoch)
  {
   isChoch = false;
   int result = 0;

   int ih = LastUnbroken(arr, true);
   if(ih >= 0 && arr[ih].bar < i)
     {
      double ref = arr[ih].price;
      double px  = InpBreakOnClose ? close[i] : high[i];
      if(px > ref)
        {
         arr[ih].broken = true;
         isChoch = (trend == -1);
         trend   = 1;
         result  = 1;
        }
     }

   int il = LastUnbroken(arr, false);
   if(result == 0 && il >= 0 && arr[il].bar < i)
     {
      double ref = arr[il].price;
      double px  = InpBreakOnClose ? close[i] : low[i];
      if(px < ref)
        {
         arr[il].broken = true;
         isChoch = (trend == 1);
         trend   = -1;
         result  = -1;
        }
     }

   return result;
  }

//+------------------------------------------------------------------+
//| Displacement: the energy of the breaking move                    |
//+------------------------------------------------------------------+
//--- how far price has travelled away from the swept wick, in ATR.
//--- Measuring from the sweep extreme rather than over a bar window keeps
//--- this a measure of the impulse itself and not of ambient range.
double DisplacementStrength(const int i, const double fromPrice, const double &close[])
  {
   double atr = BufATR[i];
   if(atr <= 0.0) return 0.0;
   return MathAbs(close[i] - fromPrice) / atr;
  }

//+------------------------------------------------------------------+
//| Spike detection for synthetic indices.                            |
//| Boom / Crash produce one outsized bar in a known direction; the    |
//| grind between spikes is the opposite direction.                    |
//+------------------------------------------------------------------+
void DetectSpike(const int i, const double &open[], const double &high[], const double &low[])
  {
   double atr = BufATR[i];
   if(atr <= 0.0) return;
   if((high[i] - low[i]) < InpSpikeATR * atr) return;

   g_lastSpikeBar = i;
   g_lastSpikeDir = (high[i] - open[i] >= open[i] - low[i]) ? 1 : -1;

   //--- evidence for the self-check against the name-based assumption
   if(g_lastSpikeDir > 0) g_spikeUp++;
   else                   g_spikeDown++;
  }

//+------------------------------------------------------------------+
//| Grade a candidate setup                                          |
//+------------------------------------------------------------------+
int GradeSetup(const int dir, const double entry, const double sl, const double dol,
               const double disp, const int fvgIdx, const SweepEvent &sw,
               string &reason)
  {
   int score = 25;                       // base: sweep + MSS + FVG all present
   string parts = "";

   //--- major trend alignment
   if(g_trendMajor == dir) { score += 20; parts += "HTF trend aligned; "; }
   else                    { parts += "counter-trend; "; }

   //--- premium / discount
   double lo, hi;
   if(DealingRange(lo, hi))
     {
      double eq = (lo + hi) * 0.5;
      bool good = (dir > 0) ? (entry < eq) : (entry > eq);
      if(good) { score += 15; parts += (dir > 0 ? "entry in discount; " : "entry in premium; "); }
      else     { parts += (dir > 0 ? "entry in premium; " : "entry in discount; "); }
     }

   //--- displacement quality
   if(disp >= g_dispATR * 1.5)      { score += 15; parts += "strong displacement; "; }
   else if(disp >= g_dispATR)       { score += 8;  parts += "displacement ok; "; }

   //--- gap quality
   if(fvgIdx >= 0)
     {
      double atr  = (BufATR[g_fvg[fvgIdx].bar] > 0.0) ? BufATR[g_fvg[fvgIdx].bar] : 0.0;
      double size = g_fvg[fvgIdx].top - g_fvg[fvgIdx].bottom;
      if(atr > 0.0 && size >= atr * 0.5) { score += 10; parts += "clean FVG; "; }
      else                               { score += 5; }
     }

   //--- room to the draw
   double risk = MathAbs(entry - sl);
   if(risk > 0.0 && dol > 0.0)
     {
      double rr = MathAbs(dol - entry) / risk;
      if(rr >= InpMinRR * 1.5) { score += 10; parts += StringFormat("%.1fR to draw; ", rr); }
      else if(rr >= InpMinRR)  { score += 5;  parts += StringFormat("%.1fR to draw; ", rr); }
     }

   //--- how long the swept level had been resting
   if(sw.age >= InpSweepValidBars) { score += 5; parts += "old level swept; "; }

   //--- synthetic spike asymmetry
   int spikeDir = EffectiveSpikeDir();
   if(spikeDir != 0)
     {
      if(dir == spikeDir) { score += InpSynthBiasScore; parts += "with spike direction; "; }
      else                { score -= InpSynthBiasScore; parts += "against spike direction; "; }
     }

   //--- post-spike continuation: after the spike, the instrument returns to its grind
   if(spikeDir != 0 && g_lastSpikeBar >= 0 &&
      (fvgIdx < 0 || (g_fvg[fvgIdx].bar - g_lastSpikeBar) <= InpSweepValidBars) &&
      dir == -g_lastSpikeDir)
     { score += 5; parts += "post-spike continuation; "; }

   //--- a driftless random walk (Step Index, FlipX) offers no directional edge
   if(g_family == FAM_RANDOM)
     { score -= 15; parts += g_familyName + " - random walk, no directional edge; "; }

   score = (int)MathMax(0, MathMin(100, score));
   reason = parts;
   return score;
  }

string GradeText(const int score)
  {
   if(score >= 85) return "A+";
   if(score >= 70) return "A";
   if(score >= 55) return "B";
   return "C";
  }

bool GradePasses(const int score)
  {
   if(InpMinGrade == GRADE_APLUS) return (score >= 85);
   if(InpMinGrade == GRADE_A)     return (score >= 70);
   return (score >= 55);
  }

//+------------------------------------------------------------------+
//| Suggested lot size for the configured risk                       |
//+------------------------------------------------------------------+
double SuggestLots(const double entry, const double sl)
  {
   double risk = MathAbs(entry - sl);
   if(risk <= 0.0) return 0.0;

   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   //--- TICK_VALUE_LOSS is the value of one tick moving against the position,
   //--- which is exactly what a stop loss costs. Plain TICK_VALUE can differ on
   //--- crosses and on accounts denominated in a third currency.
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0.0)
      tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(tickSize <= 0.0 || tickValue <= 0.0) return 0.0;

   double lossPerLot = (risk / tickSize) * tickValue;
   if(lossPerLot <= 0.0) return 0.0;

   double money = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   double lots  = money / lossPerLot;

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep > 0.0) lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return lots;
  }

//+------------------------------------------------------------------+
//| Drawing                                                          |
//+------------------------------------------------------------------+
void DrawSegment(const string name, const datetime t1, const double p1,
                 const datetime t2, const double p2,
                 const color clr, const int style, const int width)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void DrawText(const string name, const datetime t, const double p,
              const string txt, const color clr, const int fontSize = 8)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TEXT, 0, t, p);
   ObjectSetString(0, name, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void DrawBox(const string name, const datetime t1, const double p1,
             const datetime t2, const double p2, const color clr)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
//| Draw the entry / SL / TP picture for one emitted signal          |
//+------------------------------------------------------------------+
void DrawSignalLevels(const int idx, const int dir, const datetime t1, const datetime t2,
                      const double entry, const double sl,
                      const double tp1, const double tp2, const double tp3,
                      const string gradeTxt, const double arrowPrice, const double lots)
  {
   color dirColor = (dir > 0) ? InpBuyColor : InpSellColor;

   //--- the BUY / SELL word at the arrow, as in a classic arrow system
   DrawText(ObjName("SIG", idx), t1, arrowPrice,
            StringFormat("%s %s", (dir > 0 ? "BUY" : "SELL"), gradeTxt), dirColor, 10);

   if(!InpShowLevels) return;

   //--- shaded risk / reward zones
   if(InpShowZones)
     {
      DrawBox(ObjName("ZR", idx), t1, entry, t2, sl,  InpSLColor);
      DrawBox(ObjName("ZT", idx), t1, entry, t2, tp2, dirColor);
     }

   //--- entry
   DrawSegment(ObjName("ENT", idx), t1, entry, t2, entry, dirColor, STYLE_SOLID, 1);
   if(InpShowEntryTag)
      DrawText(ObjName("TAG", idx), t1, entry,
               StringFormat("%s %s at %s", (dir > 0 ? "BUY" : "SELL"),
                            DoubleToString(lots, 2), DoubleToString(entry, g_digits)),
               dirColor, 8);

   //--- stop, drawn as the red dotted band
   DrawSegment(ObjName("SL",  idx), t1, sl, t2, sl, InpSLColor, STYLE_DOT, 2);
   DrawText   (ObjName("SLt", idx), t2, sl, "SL", InpSLColor);

   //--- targets
   DrawSegment(ObjName("TP1", idx), t1, tp1, t2, tp1, InpTPColor, STYLE_DOT, 1);
   DrawText   (ObjName("TP1t",idx), t2, tp1, "TP1", InpTPColor);

   if(tp2 > 0.0)
     {
      DrawSegment(ObjName("TP2", idx), t1, tp2, t2, tp2, InpTPColor, STYLE_DOT, 1);
      DrawText   (ObjName("TP2t",idx), t2, tp2, "TP2", InpTPColor);
     }
   if(tp3 > 0.0)
     {
      DrawSegment(ObjName("TP3", idx), t1, tp3, t2, tp3, InpTPColor, STYLE_DOT, 1);
      DrawText   (ObjName("TP3t",idx), t2, tp3, "TP3", InpTPColor);
     }
  }

//+------------------------------------------------------------------+
//| Outcome tracker.                                                 |
//| Every emitted signal is followed forward bar by bar until it      |
//| reaches a target or its stop. The TP / SL marks this prints are   |
//| results, not predictions - they appear only after the bar that    |
//| produced them has closed, and they never move.                    |
//|                                                                   |
//| Accounting policy: the trade is scored as held to TP2 or the stop.|
//| If one bar spans both, it is recorded as the loss. That is the    |
//| pessimistic reading and it keeps the statistics honest.           |
//+------------------------------------------------------------------+
void UpdateTrades(const int i, const datetime &time[],
                  const double &high[], const double &low[])
  {
   if(!InpTrackOutcomes) return;

   for(int k = ArraySize(g_trades) - 1; k >= 0; k--)
     {
      if(!g_trades[k].open)        continue;
      if(i <= g_trades[k].entryBar) continue;

      int    d    = g_trades[k].dir;
      double risk = g_trades[k].risk;
      if(risk <= 0.0) { g_trades[k].open = false; continue; }

      bool slHit  = (d > 0) ? (low[i]  <= g_trades[k].sl) : (high[i] >= g_trades[k].sl);
      bool tp1Hit = (d > 0) ? (high[i] >= g_trades[k].tp1) : (low[i] <= g_trades[k].tp1);
      bool tp2Hit = (d > 0) ? (high[i] >= g_trades[k].tp2) : (low[i] <= g_trades[k].tp2);
      bool tp3Hit = (d > 0) ? (high[i] >= g_trades[k].tp3) : (low[i] <= g_trades[k].tp3);

      //--- stop first: the pessimistic reading of an ambiguous bar
      if(slHit)
        {
         g_trades[k].open      = false;
         g_trades[k].result    = -1;
         g_trades[k].rMultiple = -1.0;

         g_resolved++; g_losses++;
         g_sumR       -= 1.0;
         g_grossLossR += 1.0;

         if(InpShowOutcomeMarks)
            DrawText(ObjName("XSL", g_trades[k].idx), time[i], g_trades[k].sl,
                     "SL", InpSLColor, 8);
         continue;
        }

      if(tp1Hit && !g_trades[k].hitTP1)
        {
         g_trades[k].hitTP1 = true;
         g_tp1Hits++;
         if(InpShowOutcomeMarks)
            DrawText(ObjName("XT1", g_trades[k].idx), time[i], g_trades[k].tp1,
                     "TP", InpTPColor, 8);
        }

      if(tp3Hit && !g_trades[k].hitTP3)
        {
         g_trades[k].hitTP3 = true;
         if(InpShowOutcomeMarks)
            DrawText(ObjName("XT3", g_trades[k].idx), time[i], g_trades[k].tp3,
                     "TP", InpTPColor, 8);
        }

      if(tp2Hit && !g_trades[k].hitTP2)
        {
         g_trades[k].hitTP2    = true;
         g_trades[k].open      = false;
         g_trades[k].result    = 1;
         g_trades[k].rMultiple = MathAbs(g_trades[k].tp2 - g_trades[k].entry) / risk;

         g_resolved++; g_wins++;
         g_sumR      += g_trades[k].rMultiple;
         g_grossWinR += g_trades[k].rMultiple;

         if(InpShowOutcomeMarks)
            DrawText(ObjName("XT2", g_trades[k].idx), time[i], g_trades[k].tp2,
                     "TP", InpTPColor, 8);
        }
     }
  }

//+------------------------------------------------------------------+
//| Header block, top-left, mirroring a classic arrow system layout  |
//+------------------------------------------------------------------+
void DrawHeaderLine(const int line, const string txt, const color clr)
  {
   string name = StringFormat("%sHDR%d", PREFIX, line);
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 12);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 18 + line * (InpHdrFontSize + 6));
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetString (0, name, OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpHdrFontSize);
     }
   ObjectSetString (0, name, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  }

void UpdateHeader()
  {
   if(!InpShowHeader) return;
   DrawHeaderLine(0, InpHdr1, InpHdr1Color);
   DrawHeaderLine(1, InpHdr2, InpHdr2Color);
   DrawHeaderLine(2, InpHdr3, InpHdr3Color);
   DrawHeaderLine(3, InpHdr4, InpHdr4Color);
  }

//+------------------------------------------------------------------+
//| Journal                                                          |
//+------------------------------------------------------------------+
void JournalSignal(const datetime t, const int dir, const string gradeTxt, const int score,
                   const double entry, const double sl, const double tp1,
                   const double tp2, const double tp3, const string reason)
  {
   if(!InpJournalEnabled) return;

   int h = FileOpen(InpJournalFile, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(h == INVALID_HANDLE)
     {
      Print("ApexICT: cannot open journal ", InpJournalFile, " err=", GetLastError());
      return;
     }

   bool isNew = (FileSize(h) == 0);
   FileSeek(h, 0, SEEK_END);
   if(isNew)
      FileWrite(h, "emitted_at", "signal_time", "symbol", "timeframe", "model",
                "direction", "grade", "score", "entry", "sl", "tp1", "tp2", "tp3", "reason");

   FileWrite(h,
             TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
             TimeToString(t, TIME_DATE | TIME_SECONDS),
             _Symbol,
             EnumToString((ENUM_TIMEFRAMES)_Period),
             "SWEEP_MSS_FVG",
             (dir > 0 ? "BUY" : "SELL"),
             gradeTxt,
             (string)score,
             DoubleToString(entry, g_digits),
             DoubleToString(sl,    g_digits),
             DoubleToString(tp1,   g_digits),
             DoubleToString(tp2,   g_digits),
             DoubleToString(tp3,   g_digits),
             reason);
   FileClose(h);
  }

//+------------------------------------------------------------------+
//| Alerts                                                           |
//+------------------------------------------------------------------+
void SendTelegram(const string text)
  {
   if(!InpAlertTelegram) return;
   if(InpTgToken == "" || InpTgChatID == "") return;

   string url  = "https://api.telegram.org/bot" + InpTgToken + "/sendMessage";
   string body = "chat_id=" + InpTgChatID + "&text=" + text;

   char post[], result[];
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   string resHeaders;
   StringToCharArray(body, post, 0, StringLen(body), CP_UTF8);

   int code = WebRequest("POST", url, headers, 5000, post, result, resHeaders);
   if(code == -1)
      Print("ApexICT: Telegram failed err=", GetLastError(),
            " - allow https://api.telegram.org in Tools > Options > Expert Advisors");
  }

void FireAlert(const string kind, const string text)
  {
   string msg = StringFormat("[%s] %s %s %s", kind, _Symbol,
                             EnumToString((ENUM_TIMEFRAMES)_Period), text);

   if(InpAlertPopup) Alert(msg);
   if(InpAlertPush)  SendNotification(msg);
   if(InpAlertEmail) SendMail("Apex ICT " + kind, msg);
   SendTelegram(msg);
   Print("ApexICT ", msg);
  }

//+------------------------------------------------------------------+
//| Arm a setup once the MSS is confirmed                            |
//+------------------------------------------------------------------+
void TryArmSetup(const int i, const int dir, const double &close[])
  {
   //--- one armed setup at a time; a live one is not discarded for a newer idea
   if(g_setup.active && i <= g_setup.expiryBar) return;

   SweepEvent sw;
   if(dir > 0) sw = g_sweepBull;
   else        sw = g_sweepBear;

   if(!sw.valid) return;
   if(i <= sw.bar) return;

   //--- the impulse away from the swept wick
   double disp = DisplacementStrength(i, sw.extreme, close);
   if(disp < g_dispATR) return;

   //--- the gap the displacement left behind
   int f = FindFVGInLeg(dir, sw.bar, i);
   if(f < 0) return;

   //--- entry inside that gap
   double top   = g_fvg[f].top, bot = g_fvg[f].bottom;
   double entry = (top + bot) * 0.5;                 // consequent encroachment
   if(InpEntryMode == ENTRY_FVG_EDGE) entry = (dir > 0) ? top : bot;
   if(InpEntryMode == ENTRY_FVG_FAR)  entry = (dir > 0) ? bot : top;

   //--- stop beyond the wick that did the sweeping
   double atr = BufATR[i];
   if(atr <= 0.0) return;
   double buffer = InpSLbufferATR * atr + InpSpreadMult * SpreadPrice();
   double sl     = (dir > 0) ? (sw.extreme - buffer) : (sw.extreme + buffer);

   //--- respect the broker's minimum stop distance for this symbol.
   //--- Without this the level is structurally correct and untradeable.
   double minDist = MinStopDistance();
   if(minDist > 0.0 && MathAbs(entry - sl) < minDist)
      sl = (dir > 0) ? (entry - minDist) : (entry + minDist);

   entry = NormalizePrice(entry);
   sl    = NormalizePrice(sl);

   double risk = MathAbs(entry - sl);
   if(risk <= 0.0) return;

   //--- the draw: nearest opposing resting liquidity
   double dol = NearestOpposingLiquidity(dir, entry);
   if(dol > 0.0)
     {
      double rr = MathAbs(dol - entry) / risk;
      if(rr < InpMinRR) return;         // no room to run before the next pool
     }

   double tp1 = (dir > 0) ? entry + InpTP1_R * risk : entry - InpTP1_R * risk;
   double tp2 = (dol > 0.0) ? dol
                            : ((dir > 0) ? entry + 2.0 * risk : entry - 2.0 * risk);
   double tp3 = (dir > 0) ? entry + InpTP3_R * risk : entry - InpTP3_R * risk;

   //--- targets must clear the same minimum distance, and sit on the tick grid
   if(minDist > 0.0)
     {
      if(dir > 0)
        {
         tp1 = MathMax(tp1, entry + minDist);
         tp2 = MathMax(tp2, tp1 + minDist);
         tp3 = MathMax(tp3, tp2 + minDist);
        }
      else
        {
         tp1 = MathMin(tp1, entry - minDist);
         tp2 = MathMin(tp2, tp1 - minDist);
         tp3 = MathMin(tp3, tp2 - minDist);
        }
     }
   tp1 = NormalizePrice(tp1);
   tp2 = NormalizePrice(tp2);
   tp3 = NormalizePrice(tp3);

   //--- premium / discount hard filter
   if(InpRequireDiscount)
     {
      double lo, hi;
      if(DealingRange(lo, hi))
        {
         double eq = (lo + hi) * 0.5;
         if(dir > 0 && entry >= eq) return;
         if(dir < 0 && entry <= eq) return;
        }
     }

   //--- synthetic direction hard filter
   int sdir = EffectiveSpikeDir();
   if(InpSynthBiasFilter && sdir != 0 && dir != sdir) return;

   string reason;
   int score = GradeSetup(dir, entry, sl, dol, disp, f, sw, reason);
   if(!GradePasses(score)) return;

   g_setup.active       = true;
   g_setup.dir          = dir;
   g_setup.entry        = entry;
   g_setup.sl           = sl;
   g_setup.tp1          = tp1;
   g_setup.tp2          = tp2;
   g_setup.tp3          = tp3;
   g_setup.mssBar       = i;
   g_setup.expiryBar    = i + InpMSSValidBars;
   g_setup.sweepExtreme = sw.extreme;
   g_setup.grade        = score;
   g_setup.gradeText    = GradeText(score);
   g_setup.reason       = reason;
   g_setup.watchAlerted = false;
  }

//+------------------------------------------------------------------+
//| Emit a signal when price fills the armed entry                   |
//+------------------------------------------------------------------+
void TryTriggerSetup(const int i, const int rates_total, const datetime &time[],
                     const double &high[], const double &low[])
  {
   if(!g_setup.active) return;
   if(i <= g_setup.mssBar) return;

   //--- invalidated: stop taken out before the entry ever filled
   if((g_setup.dir > 0 && low[i]  <= g_setup.sl) ||
      (g_setup.dir < 0 && high[i] >= g_setup.sl))
     { g_setup.active = false; return; }

   //--- expired
   if(i > g_setup.expiryBar) { g_setup.active = false; return; }

   bool filled = (g_setup.dir > 0) ? (low[i] <= g_setup.entry)
                                   : (high[i] >= g_setup.entry);
   if(!filled) return;

   //--- fired on the close of this bar and never revised
   g_signalCount++;
   int idx = g_signalCount;

   double atr = BufATR[i];
   double arrowPrice = (g_setup.dir > 0) ? (low[i] - 0.6 * atr) : (high[i] + 0.6 * atr);
   if(g_setup.dir > 0) BufBuy[i]  = arrowPrice;
   else                BufSell[i] = arrowPrice;

   double lots = SuggestLots(g_setup.entry, g_setup.sl);
   double risk = MathAbs(g_setup.entry - g_setup.sl);

   int lastIdx = MathMin(rates_total - 1, i + InpLevelBars);
   DrawSignalLevels(idx, g_setup.dir, time[i], time[lastIdx],
                    g_setup.entry, g_setup.sl, g_setup.tp1, g_setup.tp2, g_setup.tp3,
                    g_setup.gradeText, arrowPrice, lots);

   //--- register the signal so the outcome tracker can follow it forward
   if(InpTrackOutcomes)
     {
      int n = ArraySize(g_trades);
      ArrayResize(g_trades, n + 1);
      g_trades[n].idx       = idx;
      g_trades[n].dir       = g_setup.dir;
      g_trades[n].entryBar  = i;
      g_trades[n].entryTime = time[i];
      g_trades[n].entry     = g_setup.entry;
      g_trades[n].sl        = g_setup.sl;
      g_trades[n].tp1       = g_setup.tp1;
      g_trades[n].tp2       = g_setup.tp2;
      g_trades[n].tp3       = g_setup.tp3;
      g_trades[n].risk      = risk;
      g_trades[n].grade     = g_setup.grade;
      g_trades[n].gradeText = g_setup.gradeText;
      g_trades[n].open      = true;
      g_trades[n].hitTP1    = false;
      g_trades[n].hitTP2    = false;
      g_trades[n].hitTP3    = false;
      g_trades[n].result    = 0;
      g_trades[n].rMultiple = 0.0;
     }

   double rr2  = (risk > 0.0) ? MathAbs(g_setup.tp2 - g_setup.entry) / risk : 0.0;

   g_lastSignalTxt = StringFormat("%s %s @ %s  SL %s  TP2 %s  (%.1fR)",
                                  (g_setup.dir > 0 ? "BUY" : "SELL"),
                                  g_setup.gradeText,
                                  DoubleToString(g_setup.entry, g_digits),
                                  DoubleToString(g_setup.sl,    g_digits),
                                  DoubleToString(g_setup.tp2,   g_digits),
                                  rr2);

   //--- the journal records live signals only. Writing history rows too would
   //--- re-append the whole file on every reload and destroy its value as proof.
   bool isLive = (g_liveMode && i == rates_total - 2);
   if(isLive)
      JournalSignal(time[i], g_setup.dir, g_setup.gradeText, g_setup.grade,
                    g_setup.entry, g_setup.sl, g_setup.tp1, g_setup.tp2, g_setup.tp3,
                    g_setup.reason);

   //--- alert only for the bar that just closed in real time, never for history
   if(InpAlertTrigger && isLive && time[i] != g_lastAlertBar)
     {
      g_lastAlertBar = time[i];
      FireAlert("TRIGGER",
                StringFormat("%s | entry %s | SL %s | TP1 %s | TP2 %s | TP3 %s | lots %s | %s",
                             g_lastSignalTxt,
                             DoubleToString(g_setup.entry, g_digits),
                             DoubleToString(g_setup.sl,    g_digits),
                             DoubleToString(g_setup.tp1,   g_digits),
                             DoubleToString(g_setup.tp2,   g_digits),
                             DoubleToString(g_setup.tp3,   g_digits),
                             DoubleToString(lots, 2),
                             g_setup.reason));
     }

   g_setup.active = false;
  }

//+------------------------------------------------------------------+
//| WATCH alert: setup armed and price approaching the entry         |
//+------------------------------------------------------------------+
void MaybeWatchAlert(const int i, const int rates_total, const datetime &time[],
                     const double &close[])
  {
   if(!InpAlertWatch)        return;
   if(!g_liveMode)           return;          // never alert while rebuilding history
   if(!g_setup.active)       return;
   if(g_setup.watchAlerted)  return;
   if(i != rates_total - 2)  return;          // only the freshly closed bar
   if(time[i] == g_lastWatchBar) return;

   double atr = BufATR[i];
   if(atr <= 0.0) return;
   if(MathAbs(close[i] - g_setup.entry) > 1.5 * atr) return;

   g_setup.watchAlerted = true;
   g_lastWatchBar = time[i];

   FireAlert("WATCH",
             StringFormat("%s %s setup armed - entry %s | SL %s | TP2 %s | %s",
                          (g_setup.dir > 0 ? "BUY" : "SELL"),
                          g_setup.gradeText,
                          DoubleToString(g_setup.entry, g_digits),
                          DoubleToString(g_setup.sl,    g_digits),
                          DoubleToString(g_setup.tp2,   g_digits),
                          g_setup.reason));
  }

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
void UpdatePanel()
  {
   if(!InpShowPanel) return;

   string name = PREFIX + "PANEL";
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 12);
      //--- sit below the header block rather than on top of it
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE,
                       InpShowHeader ? (26 + 4 * (InpHdrFontSize + 6)) : 20);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
     }

   string trend = (g_trendMajor > 0) ? "BULLISH" : (g_trendMajor < 0 ? "BEARISH" : "RANGING");

   //--- synthetic classification, plus what the bars actually show
   string synth = "";
   if(g_family != FAM_NONE)
     {
      int measured = MeasuredSpikeDir();
      string obs = StringFormat(" [spikes up %d / down %d]", g_spikeUp, g_spikeDown);

      if(g_family == FAM_RANDOM)
         synth = " | " + g_familyName + ": random walk, no directional edge" + obs;
      else if(g_family == FAM_ADAPTIVE)
         synth = " | " + g_familyName + ": adaptive, bias "
               + (measured > 0 ? "UP" : measured < 0 ? "DOWN" : "undecided") + obs;
      else if(g_family == FAM_SYMMETRIC)
         synth = " | " + g_familyName + ": no spike mechanic" + obs;
      else
        {
         synth = " | " + g_familyName + ": spikes "
               + (g_synthDir > 0 ? "up" : "down") + obs;

         //--- the assumed direction is documented as medium confidence, so it is
         //--- checked against reality rather than trusted
         if(measured != 0 && measured != g_synthDir)
           {
            synth += "  << OBSERVED DIRECTION DISAGREES";
            if(!g_dirWarned)
              {
               g_dirWarned = true;
               PrintFormat("ApexICT WARNING: %s is assumed to spike %s, but the bars show "
                           "%d up-spikes and %d down-spikes. Set 'Synthetic handling' to "
                           "Measured, or force the correct direction. See "
                           "docs/BROKER_RESEARCH.md.",
                           g_familyName, (g_synthDir > 0 ? "up" : "down"),
                           g_spikeUp, g_spikeDown);
              }
           }
        }
     }

   string stats = "";
   if(InpShowStats && g_resolved > 0)
     {
      double winRate = 100.0 * g_wins / g_resolved;
      double expect  = g_sumR / g_resolved;
      double pf      = (g_grossLossR > 0.0) ? g_grossWinR / g_grossLossR : 0.0;
      stats = StringFormat(" | resolved %d  win %.1f%%  exp %.2fR  PF %.2f  TP1 hit %d",
                           g_resolved, winRate, expect, pf, g_tp1Hits);
     }

   ObjectSetString(0, name, OBJPROP_TEXT,
                   StringFormat("Apex ICT | %s %s | structure %s | signals %d%s | %s%s",
                                _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period),
                                trend, g_signalCount, stats, g_lastSignalTxt, synth));
   ObjectSetInteger(0, name, OBJPROP_COLOR,
                    (g_trendMajor > 0) ? InpBuyColor : (g_trendMajor < 0 ? InpSellColor : clrGray));
  }

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   SetIndexBuffer(0, BufBuy,  INDICATOR_DATA);
   SetIndexBuffer(1, BufSell, INDICATOR_DATA);
   SetIndexBuffer(2, BufATR,  INDICATOR_CALCULATIONS);

   ArraySetAsSeries(BufBuy,  false);
   ArraySetAsSeries(BufSell, false);
   ArraySetAsSeries(BufATR,  false);

   PlotIndexSetInteger(0, PLOT_ARROW, 233);        // up arrow
   PlotIndexSetInteger(1, PLOT_ARROW, 234);        // down arrow
   //--- arrows are already offset in price by the plotting code, so no pixel shift
   PlotIndexSetInteger(0, PLOT_ARROW_SHIFT, 0);
   PlotIndexSetInteger(1, PLOT_ARROW_SHIFT, 0);
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   IndicatorSetString(INDICATOR_SHORTNAME, "Apex ICT Engine");
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

   g_point  = _Point;
   g_digits = _Digits;

   ApplyPreset();
   DetectSynthetic();
   ResetState();

   if(g_family != FAM_NONE)
      PrintFormat("ApexICT: %s detected.", g_familyName);

   if(g_family == FAM_RANDOM)
      PrintFormat("ApexICT: %s is a driftless random walk (equal probability each tick). "
                  "Directional setups are scored down by 15 and should be treated as low "
                  "confidence - there is no trend edge in this series to find.",
                  g_familyName);

   if(g_family == FAM_ADAPTIVE)
      PrintFormat("ApexICT: %s changes spike direction by design, so its bias is taken "
                  "from observed spikes rather than from the symbol name. The bias reads "
                  "'undecided' until at least 10 spikes have been seen.", g_familyName);

   ReportSymbolSpec();

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
   ArraySetAsSeries(time,   false);
   ArraySetAsSeries(open,   false);
   ArraySetAsSeries(high,   false);
   ArraySetAsSeries(low,    false);
   ArraySetAsSeries(close,  false);

   int warmup = MathMax(g_swingLB, g_intLB) * 2 + 20;
   if(rates_total < warmup + 10) return 0;

   g_liveMode = (prev_calculated > 0);

   int start;

   if(prev_calculated == 0)
     {
      ArrayInitialize(BufBuy,  EMPTY_VALUE);
      ArrayInitialize(BufSell, EMPTY_VALUE);
      ArrayInitialize(BufATR,  0.0);
      ObjectsDeleteAll(0, PREFIX);
      ResetState();

      start = warmup;
      if(InpMaxBars > 0 && rates_total - InpMaxBars > start)
         start = rates_total - InpMaxBars;
     }
   else
     {
      start = prev_calculated - 1;
      if(start < warmup) start = warmup;
     }

   //--- ATR (simple rolling true range average, computed inline so there is
   //--- no handle to fall out of sync with the bars we are iterating)
   const int atrPeriod = 14;
   for(int i = start; i < rates_total; i++)
     {
      double sum = 0.0;
      int n = 0;
      for(int k = i - atrPeriod + 1; k <= i; k++)
        {
         if(k < 1) continue;
         double tr = MathMax(high[k] - low[k],
                     MathMax(MathAbs(high[k] - close[k-1]),
                             MathAbs(low[k]  - close[k-1])));
         sum += tr;
         n++;
        }
      BufATR[i] = (n > 0) ? sum / n : 0.0;
     }

   //--- main pass: closed bars only, so the live bar never influences anything
   int last = rates_total - 2;

   for(int i = start; i <= last; i++)
     {
      //--- a bar is analysed exactly once. Without this guard the overlap bar
      //--- that MT5 re-sends on every tick would duplicate swings and gaps.
      if(time[i] <= g_lastProcessed) continue;
      g_lastProcessed = time[i];

      BufBuy[i]  = EMPTY_VALUE;
      BufSell[i] = EMPTY_VALUE;

      //--- publish swings whose confirmation window has now closed
      int pMaj = i - g_swingLB;
      if(pMaj >= g_swingLB)
        {
         if(IsSwingHigh(high, pMaj, g_swingLB, rates_total))
            PushSwing(g_major, pMaj, time[pMaj], high[pMaj], true,  i);
         if(IsSwingLow(low,  pMaj, g_swingLB, rates_total))
            PushSwing(g_major, pMaj, time[pMaj], low[pMaj],  false, i);
        }

      int pInt = i - g_intLB;
      if(pInt >= g_intLB)
        {
         if(IsSwingHigh(high, pInt, g_intLB, rates_total))
            PushSwing(g_internal, pInt, time[pInt], high[pInt], true,  i);
         if(IsSwingLow(low,  pInt, g_intLB, rates_total))
            PushSwing(g_internal, pInt, time[pInt], low[pInt],  false, i);
        }

      //--- arrays
      DetectFVG(i, time, high, low);
      UpdateFVGMitigation(i, high, low);
      DetectSpike(i, open, high, low);

      //--- liquidity
      DetectSweeps(i, time, high, low, close);

      //--- structure
      bool majChoch = false, intChoch = false;
      int majBreak = DetectBreak(g_major,    g_trendMajor,    i, high, low, close, majChoch);
      int intBreak = DetectBreak(g_internal, g_trendInternal, i, high, low, close, intChoch);

      //--- structure labels only on the recent window, to keep the object count sane
      if(InpShowStructure && majBreak != 0 && i > rates_total - 500)
        {
         string tag = majChoch ? "CHoCH" : "BOS";
         DrawText(ObjName("ST", i), time[i],
                  (majBreak > 0 ? high[i] + BufATR[i] * 0.4 : low[i] - BufATR[i] * 0.4),
                  tag, (majBreak > 0 ? InpBuyColor : InpSellColor), 7);
        }

      //--- the model: an internal shift in the direction opposite the sweep
      if(intBreak > 0) TryArmSetup(i,  1, close);
      if(intBreak < 0) TryArmSetup(i, -1, close);

      //--- follow already-emitted signals to their outcome before a new one fires,
      //--- so a signal never resolves itself on its own entry bar
      UpdateTrades(i, time, high, low);

      //--- entry fill
      MaybeWatchAlert(i, rates_total, time, close);
      TryTriggerSetup(i, rates_total, time, high, low);
     }

   //--- keep the live bar clean
   if(rates_total >= 1)
     {
      BufBuy[rates_total-1]  = EMPTY_VALUE;
      BufSell[rates_total-1] = EMPTY_VALUE;
     }

   //--- current dealing range
   if(InpShowRange)
     {
      double lo, hi;
      if(DealingRange(lo, hi))
        {
         datetime t1 = time[MathMax(0, rates_total - 120)];
         datetime t2 = time[rates_total - 1];
         double eq = (lo + hi) * 0.5;
         DrawSegment(PREFIX + "RNG_HI", t1, hi, t2, hi, clrDimGray,  STYLE_DOT,  1);
         DrawSegment(PREFIX + "RNG_LO", t1, lo, t2, lo, clrDimGray,  STYLE_DOT,  1);
         DrawSegment(PREFIX + "RNG_EQ", t1, eq, t2, eq, clrDarkGray, STYLE_DASH, 1);
         DrawText   (PREFIX + "RNG_EQt", t2, eq, "EQ", clrDarkGray, 7);
        }
     }

   //--- recent gaps
   if(InpShowFVG)
     {
      int drawn = 0;
      for(int k = ArraySize(g_fvg) - 1; k >= 0 && drawn < 25; k--)
        {
         if(g_fvg[k].mitigated) continue;
         int endBar = MathMin(rates_total - 1, g_fvg[k].bar + 40);
         DrawBox(ObjName("FVG", k), g_fvg[k].time, g_fvg[k].top,
                 time[endBar], g_fvg[k].bottom,
                 (g_fvg[k].dir > 0 ? InpFVGBullColor : InpFVGBearColor));
         drawn++;
        }
     }

   UpdateHeader();
   UpdatePanel();
   return rates_total;
  }
//+------------------------------------------------------------------+
