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
#property indicator_buffers 7
#property indicator_plots   4

//--- plot 0 : buy dots
#property indicator_label1  "Apex BUY"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrLime
#property indicator_width1  2

//--- plot 1 : sell dots
#property indicator_label2  "Apex SELL"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrRed
#property indicator_width2  2

//--- plot 2 : the confirmed turn a buy came from
#property indicator_label3  "Apex BUY turn"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrMediumSeaGreen
#property indicator_width3  1

//--- plot 3 : the confirmed turn a sell came from
#property indicator_label4  "Apex SELL turn"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrIndianRed
#property indicator_width4  1

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

enum ENUM_DOT_ANCHOR
  {
   DOT_BOTH,          // Both: turn dot at the extreme + entry dot where it filled
   DOT_SWING_EXTREME, // Turn dot only - at the swing extreme
   DOT_ENTRY_BAR      // Entry dot only - where the trade was takeable
  };

enum ENUM_MARKER
  {
   MARK_DOT,          // Dot  (as in a classic signal system)
   MARK_ARROW         // Arrow
  };

enum ENUM_BUDGET_SCOPE
  {
   BUDGET_CHART,      // Per chart (this symbol + this timeframe)
   BUDGET_SYMBOL,     // Per symbol, shared across its timeframes
   BUDGET_ACCOUNT     // Account-wide, shared across every chart
  };

enum ENUM_CONFIRM
  {
   CONFIRM_TOUCH,     // Fire as soon as price touches the zone (resting limit)
   CONFIRM_CLOSE,     // Wait for a bar to close back out of the zone
   CONFIRM_REJECT     // Wait for a close-out AND a rejection candle
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

//--- the mode rule an adaptive instrument follows
enum ENUM_ADAPTIVE_KIND
  {
   ADK_NONE,          // fall back to the measured direction
   ADK_SWITCH,        // SwitchX - alternates mode after every jump
   ADK_BREAK,         // BreakX  - flips only when a jump breaches the previous jump
   ADK_TREND          // TrendX  - follows the momentum of the last two jumps
  };

//--- which side of a spike instrument to trade
enum ENUM_SYNTH_STYLE
  {
   STYLE_SPIKE,       // Spike catch: trade the jump. Low hit rate, large R
   STYLE_DRIP,        // Drip: trade the grind between jumps. High hit rate, small R
   STYLE_BOTH         // No directional preference
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
input int              InpSweepScanDepth    = 3;               // Scan this many recent resting swings per side
input int              InpSweepReclaimBars  = 2;               // Reclaim may take up to x bars
input int              InpMSSValidBars      = 20;              // Entry must fill within x bars of the MSS
input int              InpMSSGraceBars      = 3;               // Keep trying to arm for x bars after the shift
input int              InpMaxPending        = 4;               // Max setups armed at once
input double           InpMinFVGatr         = 0.15;            // Ignore FVGs smaller than x * ATR
input ENUM_ENTRY_MODE  InpEntryMode         = ENTRY_FVG_CE;    // Where in the FVG to enter

input group "=== EMA trend filter ==="
input bool             InpUseEMA            = true;            // Use the EMA trend filter
input int              InpEmaFast           = 21;              // Fast EMA period
input int              InpEmaSlow           = 50;              // Slow EMA period
input bool             InpEmaHardFilter     = true;            // Block signals against the EMA trend
input int              InpEmaScore          = 15;              // Grade points for EMA alignment

input group "=== Entry confirmation & drawdown control ==="
input ENUM_CONFIRM     InpConfirm           = CONFIRM_CLOSE;   // How an entry must confirm
input double           InpMaxChaseR         = 0.35;            // Reject if confirming close is > x R past the zone
input int              InpMaxTradesPerDay   = 3;               // Max signals per day (0 = unlimited)
input double           InpDailyLossLimitR   = 2.0;             // Stop for the day after losing x R (0 = off)
input ENUM_BUDGET_SCOPE InpBudgetScope      = BUDGET_ACCOUNT;  // What the daily budget counts across
input bool             InpBudgetOnHistory   = true;            // Apply the daily budget to history too

input group "=== Risk engine ==="
input double           InpSLbufferATR       = 0.25;            // SL buffer beyond the swept wick (x * ATR)
input double           InpSpreadMult        = 2.0;             // Extra SL room = spread * x
input double           InpMinRR             = 2.0;             // Reject if opposing liquidity is nearer than x R
input double           InpTP1_R             = 1.0;             // TP1 in R
input double           InpTP3_R             = 3.0;             // TP3 in R
input double           InpRiskPercent       = 1.0;             // Risk % of balance (for the lot suggestion)

input group "=== Quality filter ==="
input ENUM_GRADE_FILTER InpMinGrade         = GRADE_ALL;       // Minimum grade to show and alert
input bool             InpRequireDiscount   = true;            // Buy only in discount / sell only in premium

input group "=== Synthetic indices (Boom / Crash / Step) ==="
input ENUM_SYNTH_MODE  InpSynthMode         = SYNTH_AUTO;      // Synthetic handling
input ENUM_SYNTH_STYLE InpSynthStyle        = STYLE_SPIKE;     // Which side of the spike cycle to trade
input double           InpSpikeATR          = 4.0;             // Spike bar: range >= x * ATR
input bool             InpSynthBiasFilter   = false;           // Hard-block signals on the unfavoured side
input int              InpSynthBiasScore    = 10;              // Grade points for the favoured side

input group "=== Your trading session ==="
input bool             InpUseSession        = true;            // Focus on your trading window
input int              InpSessStartHour     = 8;               // Window start hour (your local time)
input int              InpSessStartMin      = 0;               // Window start minute
input int              InpSessEndHour       = 12;              // Window end hour (your local time)
input int              InpSessEndMin        = 0;               // Window end minute
input int              InpUserGmtOffset     = 2;               // Your UTC offset (UTC+2 = 2)
input int              InpBrokerGmtOffset   = 99;              // Broker UTC offset (99 = auto-detect)
input bool             InpSessionHardFilter = false;           // Show setups ONLY inside the window
input int              InpSessionScore      = 10;              // Grade points for being in the window
input bool             InpSessionBrief      = true;            // Push a briefing when the window opens
input bool             InpShadeSession      = true;            // Shade the window on the chart

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
input bool             InpShowDiagnostics   = true;            // Show which filter is rejecting candidates
input bool             InpShowPending       = true;            // Draw setups that are armed and waiting
input color            InpPendingBuyColor   = clrDeepSkyBlue;  // Armed buy setup colour
input color            InpPendingSellColor  = clrOrange;       // Armed sell setup colour

input group "=== Visuals ==="
input ENUM_MARKER      InpMarker            = MARK_DOT;        // Signal marker style
input ENUM_DOT_ANCHOR  InpDotAnchor         = DOT_BOTH;        // Which dots to draw
input int              InpDotCodeEntry      = 108;             // Entry dot symbol (Wingdings)
input int              InpDotCodeTurn       = 159;             // Turn dot symbol (Wingdings)
input color            InpTurnBuyColor      = clrMediumSeaGreen; // Buy turn dot colour
input color            InpTurnSellColor     = clrIndianRed;    // Sell turn dot colour
input bool             InpLabelShowGrade    = true;            // Put the grade next to BUY / SELL
input bool             InpShowZones         = false;           // Shade the risk and reward zones
input bool             InpShowEntryTag      = true;            // "BUY 0.05 at 1.23456" tag on the entry line
input bool             InpShowStructure     = true;            // Draw BOS / CHoCH / MSS labels
input bool             InpShowFVG           = true;            // Draw fair value gaps
input bool             InpShowRange         = true;            // Draw dealing range + equilibrium
input bool             InpShowLevels        = true;            // Draw entry / SL / TP for each signal
input bool             InpShowPanel         = true;            // On-chart info panel
input int              InpLevelBars         = 30;              // Length of the level lines in bars
input int              InpLevelsRecentBars  = 800;             // Draw SL/TP lines only on the last x bars (0 = all)
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
double BufBuyTurn[];
double BufSellTurn[];
double BufEmaF[];
double BufEmaS[];

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
   int      extremeBar;     // the bar that actually made that extreme
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
   int      dotBar;         // bar the marker is drawn on
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
   bool     inSession;
   double   mae;             // worst adverse excursion, price
   double   mfe;             // best favourable excursion, price
   datetime entryDay;
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

//--- a recorded structure shift, waiting for its arming window
struct MSSEvent
  {
   int  bar;
   int  dir;
   bool done;
  };
MSSEvent     g_mss[];
Setup        g_pending[];

//--- where candidates die, so the panel can show what is starving the output
int          g_rejNoSweep    = 0;
int          g_rejDisp       = 0;
int          g_rejNoFVG      = 0;
int          g_rejRR         = 0;
int          g_rejPD         = 0;
int          g_rejSynth      = 0;
int          g_rejGrade      = 0;
int          g_rejEMA        = 0;
int          g_lastEmaTrend  = 0;
int          g_rejSession    = 0;
int          g_rejChase      = 0;
int          g_rejDaily      = 0;

//--- heat: how far trades go against you before they resolve
double       g_maeSumAll     = 0.0;
double       g_maeSumWin     = 0.0;

//--- daily discipline
datetime     g_dayKey        = 0;
int          g_dayTrades     = 0;
double       g_dayR          = 0.0;
int          g_brokerGmt     = 99;
datetime     g_lastBriefDay  = 0;

//--- does the window actually perform differently? measured, not assumed
int          g_inSessResolved = 0, g_inSessWins = 0;
int          g_outSessResolved = 0, g_outSessWins = 0;
int          g_armed         = 0;
int          g_expired       = 0;
int          g_slBeforeEntry = 0;

int          g_trendMajor    = 0;   // +1 / -1 / 0
int          g_trendInternal = 0;

int          g_swingLB       = 5;
int          g_intLB         = 2;
double       g_dispATR       = 1.5;

int                g_synthDir   = 0;         // +1 spikes up, -1 spikes down, 0 none
ENUM_SYNTH_FAMILY  g_family     = FAM_NONE;
ENUM_ADAPTIVE_KIND g_adaptKind  = ADK_NONE;
string             g_familyName = "";

//--- one recorded jump
struct SpikeRec
  {
   int      bar;
   datetime time;
   int      dir;         // +1 up, -1 down
   double   extreme;     // the far end of the jump
  };
SpikeRec     g_spikes[];
int          g_breakMode     = 0;   // BreakX current mode

//--- the mode model scores itself: predicted next jump vs what actually came
int          g_predTotal     = 0;
int          g_predCorrect   = 0;

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
double TrueRange(const int k, const double &high[], const double &low[], const double &close[])
  {
   if(k < 1) return (high[k] - low[k]);
   return MathMax(high[k] - low[k],
          MathMax(MathAbs(high[k] - close[k-1]),
                  MathAbs(low[k]  - close[k-1])));
  }

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
   g_adaptKind   = ADK_NONE;
   g_familyName  = "";

   if(InpSynthMode == SYNTH_OFF)      return;
   if(InpSynthMode == SYNTH_FORCE_UP)
     { g_synthDir = 1;  g_family = FAM_SPIKE_UP;   g_familyName = "forced spikes-up";   return; }
   if(InpSynthMode == SYNTH_FORCE_DOWN)
     { g_synthDir = -1; g_family = FAM_SPIKE_DOWN; g_familyName = "forced spikes-down"; return; }
   if(InpSynthMode == SYNTH_MEASURED)
     { g_family = FAM_ADAPTIVE; g_adaptKind = ADK_NONE;
       g_familyName = "measured from data"; return; }

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
   else if(StringFind(s, "SWITCHX")>= 0)
     { g_family = FAM_ADAPTIVE; g_adaptKind = ADK_SWITCH; g_familyName = "SwitchX"; }
   else if(StringFind(s, "BREAKX") >= 0)
     { g_family = FAM_ADAPTIVE; g_adaptKind = ADK_BREAK;  g_familyName = "BreakX";  }
   else if(StringFind(s, "TRENDX") >= 0)
     { g_family = FAM_ADAPTIVE; g_adaptKind = ADK_TREND;  g_familyName = "TrendX";  }
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
//| Which way the NEXT jump is expected to go.                        |
//|                                                                   |
//| For the fixed families this is simply the documented direction.    |
//| For the three mode-switching instruments it is a state machine     |
//| built from Weltrade's own descriptions:                            |
//|                                                                    |
//|   SwitchX - alternates mode after every jump                       |
//|   BreakX  - flips only when a jump breaches the previous jump      |
//|   TrendX  - follows the momentum of the last two jumps             |
//|                                                                    |
//| Those descriptions are medium confidence (see BROKER_RESEARCH.md), |
//| so the model scores itself against what actually happens and       |
//| reports its hit rate on the panel. Treat a rate near 50% as the    |
//| model being wrong for that instrument.                             |
//+------------------------------------------------------------------+
int PredictedNextSpikeDir()
  {
   if(g_family == FAM_SPIKE_UP)   return  1;
   if(g_family == FAM_SPIKE_DOWN) return -1;
   if(g_family != FAM_ADAPTIVE)   return  0;

   int n = ArraySize(g_spikes);
   if(n == 0) return 0;

   switch(g_adaptKind)
     {
      case ADK_SWITCH:
         //--- alternates after each jump, so the next one is the opposite
         return -g_spikes[n-1].dir;

      case ADK_BREAK:
         //--- mode persists until a jump breaches the previous jump's level
         return (g_breakMode != 0) ? g_breakMode : g_spikes[n-1].dir;

      case ADK_TREND:
        {
         //--- momentum read from where the last two jumps reached
         if(n < 2) return 0;
         if(g_spikes[n-1].extreme > g_spikes[n-2].extreme) return  1;
         if(g_spikes[n-1].extreme < g_spikes[n-2].extreme) return -1;
         return 0;
        }

      default:
         return MeasuredSpikeDir();
     }
  }

//--- the bias the engine actually trades with
int EffectiveSpikeDir()
  {
   return PredictedNextSpikeDir();
  }

//--- accuracy of the mode model, as a percentage; -1 when untested
double ModelAccuracy()
  {
   if(g_predTotal < 5) return -1.0;
   return 100.0 * g_predCorrect / g_predTotal;
  }

//+------------------------------------------------------------------+
//| Record a jump, after first scoring the prediction that preceded it|
//+------------------------------------------------------------------+
void RecordSpike(const int bar, const datetime t, const int dir, const double extreme)
  {
   //--- score the standing prediction BEFORE the new jump updates the state
   int pred = PredictedNextSpikeDir();
   if(pred != 0)
     {
      g_predTotal++;
      if(pred == dir) g_predCorrect++;
     }

   int n = ArraySize(g_spikes);
   ArrayResize(g_spikes, n + 1);
   g_spikes[n].bar     = bar;
   g_spikes[n].time    = t;
   g_spikes[n].dir     = dir;
   g_spikes[n].extreme = extreme;

   //--- BreakX: the mode flips only when this jump breaches the previous one
   if(n == 0)
      g_breakMode = dir;
   else
     {
      bool breached = (dir > 0) ? (extreme > g_spikes[n-1].extreme)
                                : (extreme < g_spikes[n-1].extreme);
      if(breached) g_breakMode = dir;
     }

   //--- keep the history bounded
   int size = ArraySize(g_spikes);
   if(size > 300) ArrayRemove(g_spikes, 0, size - 300);
  }

//+------------------------------------------------------------------+
//| Print what the engine reads from this broker's symbol spec.       |
//| Everything the risk engine does is derived from these numbers, so |
//| this line is the first thing to check on an unfamiliar broker.    |
//+------------------------------------------------------------------+
int BrokerGmtOffset();

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

   if(InpUseSession)
      PrintFormat("ApexICT session | your window %02d:%02d-%02d:%02d at UTC%+d | "
                  "broker clock detected as UTC%+d | check this line if the window looks shifted",
                  InpSessStartHour, InpSessStartMin, InpSessEndHour, InpSessEndMin,
                  InpUserGmtOffset, BrokerGmtOffset());

   if(stopsLvl > 0)
      PrintFormat("ApexICT: broker requires stops at least %s away from price; "
                  "levels closer than that are pushed out automatically.",
                  DoubleToString(stopsLvl * _Point, _Digits));
  }

//+------------------------------------------------------------------+
//| Session window.                                                  |
//|                                                                   |
//| Bar times are BROKER server time, which is almost never the same  |
//| as yours - most MT5 brokers run EET, some run UTC. Getting this   |
//| wrong silently shifts the whole window by hours, and it is the    |
//| single most common bug in session filters. So the broker offset   |
//| is auto-detected from the terminal rather than assumed, and the   |
//| detected value is printed on attach so you can check it.          |
//+------------------------------------------------------------------+
int BrokerGmtOffset()
  {
   if(InpBrokerGmtOffset != 99) return InpBrokerGmtOffset;
   if(g_brokerGmt != 99)        return g_brokerGmt;

   datetime srv = TimeCurrent();
   datetime gmt = TimeGMT();
   if(srv <= 0 || gmt <= 0) return 0;

   g_brokerGmt = (int)MathRound((double)((long)srv - (long)gmt) / 3600.0);
   return g_brokerGmt;
  }

//--- convert a bar's server time into the user's wall clock
datetime ToUserTime(const datetime serverTime)
  {
   int shift = (InpUserGmtOffset - BrokerGmtOffset()) * 3600;
   return (datetime)((long)serverTime + shift);
  }

bool InSession(const datetime serverTime)
  {
   if(!InpUseSession) return true;

   MqlDateTime dt;
   TimeToStruct(ToUserTime(serverTime), dt);

   int now   = dt.hour * 60 + dt.min;
   int from  = InpSessStartHour * 60 + InpSessStartMin;
   int until = InpSessEndHour   * 60 + InpSessEndMin;

   if(from == until) return true;                 // 24h
   if(from <  until) return (now >= from && now < until);
   return (now >= from || now < until);           // window crosses midnight
  }

//--- the user's calendar day for a bar, used to reset the daily limits
datetime UserDay(const datetime serverTime)
  {
   MqlDateTime dt;
   TimeToStruct(ToUserTime(serverTime), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
  }

//--- roll the daily counters when a new day starts
void RollDay(const datetime barTime)
  {
   datetime d = UserDay(barTime);
   if(d == g_dayKey) return;
   g_dayKey    = d;
   g_dayTrades = 0;
   g_dayR      = 0.0;

   //--- drop counters older than a week so they do not accumulate
   if(g_liveMode && InpBudgetScope != BUDGET_CHART)
      GlobalVariablesDeleteAll("ApexICT_", TimeCurrent() - 7 * 86400);
  }

//+------------------------------------------------------------------+
//| Shared daily budget.                                             |
//|                                                                   |
//| An indicator instance only sees its own chart, so a per-chart     |
//| limit is no limit at all once you run several symbols: three      |
//| trades each across five charts is fifteen trades. The counters are |
//| therefore kept in terminal global variables, which every chart in  |
//| the same terminal can read, so the budget can be genuinely         |
//| account-wide.                                                     |
//|                                                                   |
//| Global variables only exist live, so history always uses the local |
//| counter - a backtest of one chart cannot know what the others did. |
//+------------------------------------------------------------------+
string BudgetKey()
  {
   string scope;
   if(InpBudgetScope == BUDGET_ACCOUNT)     scope = "ACC";
   else if(InpBudgetScope == BUDGET_SYMBOL) scope = _Symbol;
   else                                     scope = _Symbol + "_" + IntegerToString((int)_Period);

   return "ApexICT_" + scope + "_" + IntegerToString((long)g_dayKey);
  }

int SharedDayTrades()
  {
   if(!g_liveMode || InpBudgetScope == BUDGET_CHART) return g_dayTrades;
   string k = BudgetKey() + "_N";
   if(!GlobalVariableCheck(k)) return 0;
   return (int)GlobalVariableGet(k);
  }

double SharedDayR()
  {
   if(!g_liveMode || InpBudgetScope == BUDGET_CHART) return g_dayR;
   string k = BudgetKey() + "_R";
   if(!GlobalVariableCheck(k)) return 0.0;
   return GlobalVariableGet(k);
  }

void SharedAddTrade()
  {
   g_dayTrades++;
   if(!g_liveMode || InpBudgetScope == BUDGET_CHART) return;
   string k = BudgetKey() + "_N";
   GlobalVariableSet(k, SharedDayTrades() + 1);
  }

void SharedAddR(const double r)
  {
   g_dayR += r;
   if(!g_liveMode || InpBudgetScope == BUDGET_CHART) return;
   string k = BudgetKey() + "_R";
   GlobalVariableSet(k, SharedDayR() + r);
  }

//--- has the day already used up its budget
bool DayBudgetSpent()
  {
   if(InpMaxTradesPerDay > 0 && SharedDayTrades() >= InpMaxTradesPerDay) return true;
   if(InpDailyLossLimitR > 0.0 && SharedDayR() <= -InpDailyLossLimitR)   return true;
   return false;
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
   s.level = 0.0;   s.extreme = 0.0; s.extremeBar = -1; s.dir = 0; s.age = 0;
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
   ArrayResize(g_spikes, 0);
   g_breakMode = 0; g_predTotal = 0; g_predCorrect = 0;

   ClearSweep(g_sweepBull);
   ClearSweep(g_sweepBear);
   ArrayResize(g_mss, 0);
   ArrayResize(g_pending, 0);

   g_rejNoSweep = 0; g_rejDisp = 0; g_rejNoFVG = 0; g_rejRR = 0;
   g_rejPD = 0; g_rejSynth = 0; g_rejGrade = 0; g_rejEMA = 0; g_rejSession = 0;
   g_inSessResolved = 0; g_inSessWins = 0;
   g_outSessResolved = 0; g_outSessWins = 0;
   g_lastBriefDay = 0;
   g_rejChase = 0; g_rejDaily = 0;
   g_maeSumAll = 0.0; g_maeSumWin = 0.0;
   g_dayKey = 0; g_dayTrades = 0; g_dayR = 0.0;
   g_armed = 0; g_expired = 0; g_slBeforeEntry = 0;

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

   //--- keep the history bounded; ancient swings are never referenced again
   int size = ArraySize(arr);
   if(size > 400) ArrayRemove(arr, 0, size - 400);
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
   int    scanned = 0;
   for(int i = ArraySize(g_major) - 1; i >= 0 && scanned < 60; i--)
     {
      if(g_major[i].broken) continue;      // a level already traded through is not a pool
      scanned++;
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
//| A sweep = price trades through a resting swing and then reclaims  |
//| it. On synthetics this is failed-breakout geometry rather than a  |
//| real stop raid, but the statistical shape is the same.            |
//|                                                                   |
//| Two deliberate looseners, because the strict version starves the  |
//| engine of candidates:                                             |
//|   * several recent resting swings are scanned, not only the last  |
//|   * the reclaim may take a few bars rather than closing back       |
//|     inside on the sweeping bar itself                             |
//+------------------------------------------------------------------+
void ScanSweepSide(const int i, const bool wantHigh, const datetime &time[],
                   const double &high[], const double &low[], const double &close[])
  {
   int checked = 0;
   for(int k = ArraySize(g_major) - 1; k >= 0 && checked < InpSweepScanDepth; k--)
     {
      if(g_major[k].isHigh != wantHigh) continue;
      if(g_major[k].broken)             continue;
      if(g_major[k].bar >= i)           continue;
      checked++;

      double lvl = g_major[k].price;

      if(!wantHigh)
        {
         //--- sell-side: price must have traded below the level within the
         //--- reclaim window, and this bar must close back above it
         if(close[i] <= lvl) continue;

         double deepest = 0.0;
         int    deepBar = -1;
         bool   pierced = false;
         for(int b = i; b >= i - InpSweepReclaimBars && b > g_major[k].bar; b--)
            if(low[b] < lvl)
              {
               pierced = true;
               if(deepest == 0.0 || low[b] < deepest) { deepest = low[b]; deepBar = b; }
              }
         if(!pierced) continue;

         g_sweepBull.valid   = true;
         g_sweepBull.bar     = i;
         g_sweepBull.time    = time[i];
         g_sweepBull.level   = lvl;
         g_sweepBull.extreme    = deepest;
         g_sweepBull.extremeBar = deepBar;
         g_sweepBull.dir     = 1;
         g_sweepBull.age     = i - g_major[k].bar;
         return;
        }
      else
        {
         if(close[i] >= lvl) continue;

         double highest = 0.0;
         int    highBar = -1;
         bool   pierced = false;
         for(int b = i; b >= i - InpSweepReclaimBars && b > g_major[k].bar; b--)
            if(high[b] > lvl)
              {
               pierced = true;
               if(high[b] > highest) { highest = high[b]; highBar = b; }
              }
         if(!pierced) continue;

         g_sweepBear.valid   = true;
         g_sweepBear.bar     = i;
         g_sweepBear.time    = time[i];
         g_sweepBear.level   = lvl;
         g_sweepBear.extreme    = highest;
         g_sweepBear.extremeBar = highBar;
         g_sweepBear.dir     = -1;
         g_sweepBear.age     = i - g_major[k].bar;
         return;
        }
     }
  }

void DetectSweeps(const int i, const datetime &time[], const double &high[],
                  const double &low[], const double &close[])
  {
   ScanSweepSide(i, false, time, high, low, close);   // sell-side -> longs
   ScanSweepSide(i, true,  time, high, low, close);   // buy-side  -> shorts

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
void DetectSpike(const int i, const datetime &time[], const double &open[],
                 const double &high[], const double &low[])
  {
   double atr = BufATR[i];
   if(atr <= 0.0) return;
   if((high[i] - low[i]) < InpSpikeATR * atr) return;

   g_lastSpikeBar = i;
   g_lastSpikeDir = (high[i] - open[i] >= open[i] - low[i]) ? 1 : -1;

   //--- evidence for the self-check against the name-based assumption
   if(g_lastSpikeDir > 0) g_spikeUp++;
   else                   g_spikeDown++;

   RecordSpike(i, time[i], g_lastSpikeDir,
               (g_lastSpikeDir > 0) ? high[i] : low[i]);
  }

//+------------------------------------------------------------------+
//| Grade a candidate setup                                          |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| EMA trend filter.                                                |
//|                                                                   |
//| Computed inline from the chart's own bars rather than through an  |
//| indicator handle, so there is nothing to fall out of sync with    |
//| the array being iterated, and it costs one multiply per bar. That |
//| keeps the whole pass fast on any timeframe.                       |
//|                                                                   |
//| Returns +1 bullish, -1 bearish, 0 undecided.                      |
//+------------------------------------------------------------------+
int EMATrend(const int i, const double &close[])
  {
   if(!InpUseEMA) return 0;
   if(BufEmaF[i] <= 0.0 || BufEmaS[i] <= 0.0) return 0;

   //--- stack: fast above slow AND price on the same side of the fast line.
   //--- Requiring both removes the chop that a bare crossover produces.
   if(BufEmaF[i] > BufEmaS[i] && close[i] > BufEmaF[i]) return  1;
   if(BufEmaF[i] < BufEmaS[i] && close[i] < BufEmaF[i]) return -1;
   return 0;
  }

//--- how far the fast EMA is separated from the slow one, in ATR.
//--- A wide, cleanly separated stack is a stronger trend than a tangle.
double EMASeparation(const int i)
  {
   if(BufATR[i] <= 0.0 || BufEmaF[i] <= 0.0 || BufEmaS[i] <= 0.0) return 0.0;
   return MathAbs(BufEmaF[i] - BufEmaS[i]) / BufATR[i];
  }

int GradeSetup(const int dir, const double entry, const double sl, const double dol,
               const double disp, const int fvgIdx, const SweepEvent &sw,
               const int i, const double &close[], const datetime barTime, string &reason)
  {
//--- Continuous scoring, and no free base score.
//--- The earlier version handed out 25 points simply for the pattern existing,
//--- which let a mediocre setup coast to a passing grade. Here every point has
//--- to be earned by a measurable property, and each component scales with how
//--- good it actually is instead of stepping over a threshold.
   double score = 0.0;
   string parts = "";

   double atr = (fvgIdx >= 0 && BufATR[g_fvg[fvgIdx].bar] > 0.0)
                ? BufATR[g_fvg[fvgIdx].bar] : 0.0;
   double risk = MathAbs(entry - sl);

//--- 1. structure alignment, up to 25
   if(g_trendMajor == dir)
     {
      score += 18.0;
      parts += "HTF trend aligned; ";
      if(g_trendInternal == dir) { score += 7.0; parts += "both tiers agree; "; }
     }
   else
      parts += "counter-trend; ";

//--- 1b. EMA trend filter, up to InpEmaScore, scaled by how clean the stack is
   if(InpUseEMA)
     {
      int et = EMATrend(i, close);
      if(et == dir)
        {
         double sep = MathMin(1.0, EMASeparation(i) / 1.5);
         score += InpEmaScore * (0.6 + 0.4 * sep);
         parts += StringFormat("EMA %d/%d aligned; ", InpEmaFast, InpEmaSlow);
        }
      else if(et == 0)
         parts += "EMA flat; ";
      else
         parts += "EMA opposes; ";
     }

//--- 1c. inside your trading window
   if(InpUseSession)
     {
      if(InSession(barTime)) { score += InpSessionScore; parts += "in your session; "; }
      else                    parts += "outside your session; ";
     }

//--- 2. premium / discount, up to 15, scaled by depth into the correct half
   double lo, hi;
   if(DealingRange(lo, hi) && hi > lo)
     {
      double pos  = (entry - lo) / (hi - lo);          // 0 = low, 1 = high
      double edge = (dir > 0) ? (0.5 - pos) : (pos - 0.5);
      if(edge > 0.0)
        {
         score += MathMin(15.0, edge * 30.0);
         parts += StringFormat("%s %.0f%%; ", (dir > 0 ? "discount" : "premium"),
                               edge * 200.0);
        }
      else
         parts += (dir > 0 ? "entry in premium; " : "entry in discount; ");
     }

//--- 3. displacement, up to 20, saturating at twice the required strength
   if(g_dispATR > 0.0)
     {
      double q = MathMin(1.0, disp / (g_dispATR * 2.0));
      score += 20.0 * q;
      parts += StringFormat("displacement %.1fATR; ", disp);
     }

//--- 4. gap quality, up to 12
   if(fvgIdx >= 0 && atr > 0.0)
     {
      double size = (g_fvg[fvgIdx].top - g_fvg[fvgIdx].bottom) / atr;
      score += MathMin(12.0, size * 16.0);
      parts += StringFormat("FVG %.2fATR; ", size);
     }

//--- 5. room to the draw, up to 15
   if(risk > 0.0 && dol > 0.0)
     {
      double rr = MathAbs(dol - entry) / risk;
      score += MathMin(15.0, (rr / 4.0) * 15.0);
      parts += StringFormat("%.1fR to draw; ", rr);
     }
   else
      parts += "no resting draw above; ";

//--- 6. sweep decisiveness, up to 8: how far past the level the wick reached
   if(atr > 0.0 && sw.level != 0.0)
     {
      double depth = MathAbs(sw.level - sw.extreme) / atr;
      score += MathMin(8.0, depth * 16.0);
      parts += StringFormat("swept %.2fATR deep; ", depth);
     }

//--- 7. how long the taken level had been resting, up to 5
   score += MathMin(5.0, (double)sw.age / (double)MathMax(1, InpSweepValidBars) * 5.0);

//--- 8. synthetic spike asymmetry.
//--- Spike style trades the jump; drip style trades the grind between jumps.
//--- They are opposite trades, so the bias follows whichever the trader chose.
   int spikeDir = EffectiveSpikeDir();
   if(spikeDir != 0 && InpSynthStyle != STYLE_BOTH)
     {
      bool drip    = (InpSynthStyle == STYLE_DRIP);
      int  favored = drip ? -spikeDir : spikeDir;
      if(dir == favored)
        { score += InpSynthBiasScore; parts += (drip ? "with the grind; " : "with spike direction; "); }
      else
        { score -= InpSynthBiasScore; parts += (drip ? "against the grind; " : "against spike direction; "); }
     }

//--- post-spike continuation: after a jump the instrument returns to its grind
   if(spikeDir != 0 && g_lastSpikeBar >= 0 &&
      (fvgIdx < 0 || (g_fvg[fvgIdx].bar - g_lastSpikeBar) <= InpSweepValidBars) &&
      dir == -g_lastSpikeDir)
     { score += 5.0; parts += "post-spike continuation; "; }

//--- a driftless random walk (Step Index, FlipX) offers no directional edge
   if(g_family == FAM_RANDOM)
     { score -= 15.0; parts += g_familyName + " - random walk, no directional edge; "; }

   int final = (int)MathRound(MathMax(0.0, MathMin(100.0, score)));
   reason = parts;
   return final;
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
                      const string gradeTxt, const double arrowPrice, const double lots,
                      const datetime tDot, const bool drawLevels)
  {
   color dirColor = (dir > 0) ? InpBuyColor : InpSellColor;

   //--- the BUY / SELL word sits with the dot, as in a classic signal chart
   string word = (dir > 0) ? "BUY" : "SELL";
   if(InpLabelShowGrade) word += " " + gradeTxt;
   DrawText(ObjName("SIG", idx), tDot, arrowPrice, word, dirColor, 10);

   if(!InpShowLevels || !drawLevels) return;

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

      //--- heat: how far this trade goes against the entry before it resolves.
      //--- This is the number that says whether entries are actually refined,
      //--- rather than whether they eventually won.
      double adverse = (d > 0) ? (g_trades[k].entry - low[i])
                               : (high[i] - g_trades[k].entry);
      if(adverse > g_trades[k].mae) g_trades[k].mae = adverse;

      double favour = (d > 0) ? (high[i] - g_trades[k].entry)
                              : (g_trades[k].entry - low[i]);
      if(favour > g_trades[k].mfe) g_trades[k].mfe = favour;

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
         if(g_trades[k].inSession) g_inSessResolved++;
         else                      g_outSessResolved++;
         g_maeSumAll += MathMin(1.0, g_trades[k].mae / risk);
         if(g_trades[k].entryDay == g_dayKey) SharedAddR(-1.0);

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
         if(g_trades[k].inSession) { g_inSessResolved++;  g_inSessWins++;  }
         else                      { g_outSessResolved++; g_outSessWins++; }
         double heat = g_trades[k].mae / risk;
         g_maeSumAll += heat;
         g_maeSumWin += heat;
         if(g_trades[k].entryDay == g_dayKey) SharedAddR(g_trades[k].rMultiple);

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

//+------------------------------------------------------------------+
//| Session briefing.                                                |
//|                                                                   |
//| Fires once, on the first closed bar inside your window each day,  |
//| so that when you sit down the state of the market is already      |
//| summarised rather than something you have to reconstruct.         |
//+------------------------------------------------------------------+
void MaybeSessionBrief(const int i, const int rates_total, const datetime &time[],
                       const double &close[])
  {
   if(!InpSessionBrief || !InpUseSession) return;
   if(!g_liveMode)          return;
   if(i != rates_total - 2) return;
   if(!InSession(time[i]))  return;

   //--- once per day, keyed on the user's calendar day
   MqlDateTime dt;
   TimeToStruct(ToUserTime(time[i]), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime day = StructToTime(dt);
   if(day == g_lastBriefDay) return;
   g_lastBriefDay = day;

   string trend = (g_trendMajor > 0) ? "bullish" : (g_trendMajor < 0 ? "bearish" : "ranging");
   int    et    = EMATrend(i, close);
   string emaTx = (et > 0) ? "EMA up" : (et < 0 ? "EMA down" : "EMA flat");

   string zone = "range unknown";
   double lo, hi;
   if(DealingRange(lo, hi) && hi > lo)
     {
      double pos = (close[i] - lo) / (hi - lo) * 100.0;
      zone = StringFormat("%.0f%% of range (%s)", pos,
                          (pos < 50.0 ? "discount - longs favoured"
                                      : "premium - shorts favoured"));
     }

   int armed = 0;
   for(int k = 0; k < ArraySize(g_pending); k++)
      if(g_pending[k].active) armed++;

   string near = "none armed yet";
   if(armed > 0)
     {
      int    best = -1;
      double bestAway = 0.0;
      for(int k = 0; k < ArraySize(g_pending); k++)
        {
         if(!g_pending[k].active) continue;
         double a = MathAbs(close[i] - g_pending[k].entry);
         if(best < 0 || a < bestAway) { best = k; bestAway = a; }
        }
      near = StringFormat("%s %s @ %s",
                          (g_pending[best].dir > 0 ? "BUY" : "SELL"),
                          g_pending[best].gradeText,
                          DoubleToString(g_pending[best].entry, g_digits));
     }

   RollDay(time[i]);

   string budget = "";
   if(InpMaxTradesPerDay > 0)
      budget = StringFormat(" | budget %d trades", InpMaxTradesPerDay);
   if(InpDailyLossLimitR > 0.0)
      budget += StringFormat(", stop at -%.1fR", InpDailyLossLimitR);

   FireAlert("SESSION",
             StringFormat("window open | structure %s | %s | %s | %d armed | nearest: %s%s",
                          trend, emaTx, zone, armed, near, budget));
  }

//+------------------------------------------------------------------+
//| Armed setups, drawn live.                                        |
//|                                                                   |
//| These are the ONLY objects on the chart that move. They have to:  |
//| they show a setup that is waiting for price, and it either fills, |
//| expires or is invalidated. They are drawn dashed and in their own |
//| colours so they can never be confused with a confirmed signal.    |
//| Nothing here is a signal yet - the dot and the alert come when    |
//| a bar actually closes into the entry.                             |
//+------------------------------------------------------------------+
void DrawPendingSetups(const int rates_total, const datetime &time[], const double &close[])
  {
   ObjectsDeleteAll(0, PREFIX + "LIVE");
   if(!InpShowPending) return;
   if(rates_total < 2) return;

   datetime tNow  = time[rates_total-1];
   double   price = close[rates_total-1];
   double   atr   = BufATR[rates_total-2];
   int      lastBar = rates_total - 2;

   int shown = 0;
   for(int k = 0; k < ArraySize(g_pending); k++)
     {
      if(!g_pending[k].active) continue;

      int    dir  = g_pending[k].dir;
      color  clr  = (dir > 0) ? InpPendingBuyColor : InpPendingSellColor;
      string tag  = "LIVE" + IntegerToString(k);
      datetime t1 = time[MathMax(0, MathMin(rates_total-1, g_pending[k].mssBar))];

      //--- the zone price has to reach
      string nEnt = PREFIX + tag + "_E";
      if(ObjectCreate(0, nEnt, OBJ_TREND, 0, t1, g_pending[k].entry, tNow, g_pending[k].entry))
        {
         ObjectSetInteger(0, nEnt, OBJPROP_COLOR, clr);
         ObjectSetInteger(0, nEnt, OBJPROP_STYLE, STYLE_DASH);
         ObjectSetInteger(0, nEnt, OBJPROP_WIDTH, 2);
         ObjectSetInteger(0, nEnt, OBJPROP_RAY_RIGHT, true);
         ObjectSetInteger(0, nEnt, OBJPROP_BACK, true);
         ObjectSetInteger(0, nEnt, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, nEnt, OBJPROP_HIDDEN, true);
        }

      string nSL = PREFIX + tag + "_S";
      if(ObjectCreate(0, nSL, OBJ_TREND, 0, t1, g_pending[k].sl, tNow, g_pending[k].sl))
        {
         ObjectSetInteger(0, nSL, OBJPROP_COLOR, InpSLColor);
         ObjectSetInteger(0, nSL, OBJPROP_STYLE, STYLE_DOT);
         ObjectSetInteger(0, nSL, OBJPROP_WIDTH, 1);
         ObjectSetInteger(0, nSL, OBJPROP_RAY_RIGHT, true);
         ObjectSetInteger(0, nSL, OBJPROP_BACK, true);
         ObjectSetInteger(0, nSL, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, nSL, OBJPROP_HIDDEN, true);
        }

      //--- how close, and how long it has left
      double away  = (atr > 0.0) ? MathAbs(price - g_pending[k].entry) / atr : 0.0;
      int    left  = g_pending[k].expiryBar - lastBar;
      double risk  = MathAbs(g_pending[k].entry - g_pending[k].sl);
      double rr2   = (risk > 0.0) ? MathAbs(g_pending[k].tp2 - g_pending[k].entry) / risk : 0.0;

      string nTx = PREFIX + tag + "_T";
      if(ObjectCreate(0, nTx, OBJ_TEXT, 0, tNow, g_pending[k].entry))
        {
         ObjectSetString(0, nTx, OBJPROP_TEXT,
                         StringFormat("  %s %s ARMED - %.1f ATR away, %d bars left, %.1fR",
                                      (dir > 0 ? "BUY" : "SELL"),
                                      g_pending[k].gradeText, away, MathMax(0, left), rr2));
         ObjectSetInteger(0, nTx, OBJPROP_COLOR, clr);
         ObjectSetInteger(0, nTx, OBJPROP_FONTSIZE, 8);
         ObjectSetInteger(0, nTx, OBJPROP_ANCHOR, ANCHOR_LEFT);
         ObjectSetInteger(0, nTx, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, nTx, OBJPROP_HIDDEN, true);
        }
      shown++;
     }

   //--- one-line summary, always in the same place so it can be read at a glance
   string nHud = PREFIX + "HUD";
   if(ObjectFind(0, nHud) < 0)
     {
      ObjectCreate(0, nHud, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, nHud, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, nHud, OBJPROP_XDISTANCE, 12);
      ObjectSetInteger(0, nHud, OBJPROP_YDISTANCE, 20);
      ObjectSetInteger(0, nHud, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(0, nHud, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nHud, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, nHud, OBJPROP_FONTSIZE, 10);
      ObjectSetString (0, nHud, OBJPROP_FONT, "Arial Bold");
     }

   if(shown == 0)
     {
      ObjectSetString(0, nHud, OBJPROP_TEXT, "no setup armed");
      ObjectSetInteger(0, nHud, OBJPROP_COLOR, clrGray);
     }
   else
     {
      //--- report the one closest to filling
      int    best = -1;
      double bestAway = 0.0;
      for(int k = 0; k < ArraySize(g_pending); k++)
        {
         if(!g_pending[k].active) continue;
         double a = MathAbs(price - g_pending[k].entry);
         if(best < 0 || a < bestAway) { best = k; bestAway = a; }
        }
      double aAtr = (atr > 0.0) ? bestAway / atr : 0.0;
      ObjectSetString(0, nHud, OBJPROP_TEXT,
                      StringFormat("%d ARMED | nearest %s %s @ %s  (%.1f ATR away)",
                                   shown,
                                   (g_pending[best].dir > 0 ? "BUY" : "SELL"),
                                   g_pending[best].gradeText,
                                   DoubleToString(g_pending[best].entry, g_digits),
                                   aAtr));
      ObjectSetInteger(0, nHud, OBJPROP_COLOR,
                       (g_pending[best].dir > 0) ? InpPendingBuyColor : InpPendingSellColor);
     }
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
//| Setup pipeline.                                                  |
//|                                                                   |
//| A structure shift is recorded as an MSS event, and arming is then |
//| attempted on that bar AND for a few bars afterwards, because the  |
//| fair value gap of an impulse frequently completes one or two bars |
//| after the break itself. Several setups may be armed at once - the |
//| earlier single-slot version silently discarded every opportunity  |
//| that appeared while one setup was waiting to fill, which is the   |
//| main reason a strict chain like this produces almost no signals.  |
//|                                                                   |
//| Every rejection is counted so the panel can show exactly which    |
//| filter is starving the output.                                    |
//+------------------------------------------------------------------+
void PushMSS(const int bar, const int dir)
  {
   int n = ArraySize(g_mss);
   ArrayResize(g_mss, n + 1);
   g_mss[n].bar  = bar;
   g_mss[n].dir  = dir;
   g_mss[n].done = false;

   if(ArraySize(g_mss) > 64) ArrayRemove(g_mss, 0, ArraySize(g_mss) - 64);
  }

int CountActivePending()
  {
   int c = 0;
   for(int k = 0; k < ArraySize(g_pending); k++)
      if(g_pending[k].active) c++;
   return c;
  }

//--- attempt to build a setup from one MSS event, evaluated at bar i
bool TryArmFromMSS(const int dir, const int i, const double &close[], const datetime barTime)
  {
   if(CountActivePending() >= InpMaxPending) return false;

   SweepEvent sw;
   if(dir > 0) sw = g_sweepBull;
   else        sw = g_sweepBear;

   if(!sw.valid)   { g_rejNoSweep++; return false; }
   if(i <= sw.bar) { g_rejNoSweep++; return false; }

   //--- the impulse away from the swept wick
   double disp = DisplacementStrength(i, sw.extreme, close);
   if(disp < g_dispATR) { g_rejDisp++; return false; }

   //--- the gap the displacement left behind
   int f = FindFVGInLeg(dir, sw.bar, i);
   if(f < 0) { g_rejNoFVG++; return false; }

   //--- entry inside that gap
   double top   = g_fvg[f].top, bot = g_fvg[f].bottom;
   double entry = (top + bot) * 0.5;                 // consequent encroachment
   if(InpEntryMode == ENTRY_FVG_EDGE) entry = (dir > 0) ? top : bot;
   if(InpEntryMode == ENTRY_FVG_FAR)  entry = (dir > 0) ? bot : top;

   //--- stop beyond the wick that did the sweeping
   double atr = BufATR[i];
   if(atr <= 0.0) return false;
   double buffer = InpSLbufferATR * atr + InpSpreadMult * SpreadPrice();
   double sl     = (dir > 0) ? (sw.extreme - buffer) : (sw.extreme + buffer);

   //--- respect the broker's minimum stop distance for this symbol
   double minDist = MinStopDistance();
   if(minDist > 0.0 && MathAbs(entry - sl) < minDist)
      sl = (dir > 0) ? (entry - minDist) : (entry + minDist);

   entry = NormalizePrice(entry);
   sl    = NormalizePrice(sl);

   double risk = MathAbs(entry - sl);
   if(risk <= 0.0) return false;

   //--- the draw: nearest opposing resting liquidity
   double dol = NearestOpposingLiquidity(dir, entry);
   if(dol > 0.0 && (MathAbs(dol - entry) / risk) < InpMinRR)
     { g_rejRR++; return false; }

   double tp1 = (dir > 0) ? entry + InpTP1_R * risk : entry - InpTP1_R * risk;
   double tp2 = (dol > 0.0) ? dol
                            : ((dir > 0) ? entry + 2.0 * risk : entry - 2.0 * risk);
   double tp3 = (dir > 0) ? entry + InpTP3_R * risk : entry - InpTP3_R * risk;

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

   //--- only inside your trading window, when asked
   if(InpUseSession && InpSessionHardFilter && !InSession(barTime))
     { g_rejSession++; return false; }

   //--- EMA trend hard filter: never take a signal into the trend's teeth
   if(InpUseEMA && InpEmaHardFilter)
     {
      int et = EMATrend(i, close);
      if(et != 0 && et != dir) { g_rejEMA++; return false; }
     }

   //--- premium / discount hard filter
   if(InpRequireDiscount)
     {
      double lo, hi;
      if(DealingRange(lo, hi))
        {
         double eq = (lo + hi) * 0.5;
         if((dir > 0 && entry >= eq) || (dir < 0 && entry <= eq))
           { g_rejPD++; return false; }
        }
     }

   //--- synthetic direction hard filter, on whichever side the style favours
   int sdir = EffectiveSpikeDir();
   if(InpSynthBiasFilter && sdir != 0 && InpSynthStyle != STYLE_BOTH)
     {
      int favored = (InpSynthStyle == STYLE_DRIP) ? -sdir : sdir;
      if(dir != favored) { g_rejSynth++; return false; }
     }

   string reason;
   int score = GradeSetup(dir, entry, sl, dol, disp, f, sw, i, close, barTime, reason);
   if(!GradePasses(score)) { g_rejGrade++; return false; }

   //--- take a free slot
   int slot = -1;
   for(int k = 0; k < ArraySize(g_pending); k++)
      if(!g_pending[k].active) { slot = k; break; }
   if(slot < 0)
     {
      slot = ArraySize(g_pending);
      ArrayResize(g_pending, slot + 1);
     }

   g_pending[slot].active       = true;
   g_pending[slot].dir          = dir;
   g_pending[slot].entry        = entry;
   g_pending[slot].sl           = sl;
   g_pending[slot].tp1          = tp1;
   g_pending[slot].tp2          = tp2;
   g_pending[slot].tp3          = tp3;
   g_pending[slot].mssBar       = i;
   g_pending[slot].expiryBar    = i + InpMSSValidBars;
   g_pending[slot].dotBar       = (sw.extremeBar >= 0) ? sw.extremeBar : i;
   g_pending[slot].sweepExtreme = sw.extreme;
   g_pending[slot].grade        = score;
   g_pending[slot].gradeText    = GradeText(score);
   g_pending[slot].reason       = reason;
   g_pending[slot].watchAlerted = false;

   g_armed++;
   return true;
  }

//--- work the MSS queue: each event gets its arming window, not just one bar
void ProcessMSS(const int i, const double &close[], const datetime barTime)
  {
   for(int k = ArraySize(g_mss) - 1; k >= 0; k--)
     {
      if(g_mss[k].done) continue;
      if(i < g_mss[k].bar) continue;
      if(i > g_mss[k].bar + InpMSSGraceBars) { g_mss[k].done = true; continue; }

      if(TryArmFromMSS(g_mss[k].dir, i, close, barTime))
         g_mss[k].done = true;
     }
  }

//+------------------------------------------------------------------+
//| Emit signals when price fills an armed entry                     |
//+------------------------------------------------------------------+
void TryTriggerSetups(const int i, const int rates_total, const datetime &time[],
                      const double &open[], const double &high[], const double &low[],
                      const double &close[])
  {
   for(int k = 0; k < ArraySize(g_pending); k++)
     {
      if(!g_pending[k].active) continue;
      if(i <= g_pending[k].mssBar) continue;

      //--- invalidated: stop taken out before the entry ever filled
      if((g_pending[k].dir > 0 && low[i]  <= g_pending[k].sl) ||
         (g_pending[k].dir < 0 && high[i] >= g_pending[k].sl))
        { g_pending[k].active = false; g_slBeforeEntry++; continue; }

      if(i > g_pending[k].expiryBar)
        { g_pending[k].active = false; g_expired++; continue; }

      //--- Entry confirmation.
      //---
      //--- CONFIRM_TOUCH assumes a resting limit order: you are filled at the
      //--- zone, at the best possible price, but with no evidence the zone is
      //--- holding. That is where most of the heat on a trade comes from.
      //---
      //--- CONFIRM_CLOSE and CONFIRM_REJECT wait for the bar to close back out
      //--- of the zone, so you enter after the reaction has begun rather than
      //--- into it. The price is worse and the fill is the close, not the zone -
      //--- so the fill price is re-priced below and the trade is re-checked.
      int dirp = g_pending[k].dir;
      bool touched = (dirp > 0) ? (low[i]  <= g_pending[k].entry)
                                : (high[i] >= g_pending[k].entry);
      if(!touched) continue;

      if(InpConfirm != CONFIRM_TOUCH)
        {
         //--- the bar must reclaim the zone in the trade's direction
         bool reclaimed = (dirp > 0) ? (close[i] > g_pending[k].entry)
                                     : (close[i] < g_pending[k].entry);
         if(!reclaimed) continue;

         if(InpConfirm == CONFIRM_REJECT)
           {
            //--- and it must look like rejection: right-way body, and the close
            //--- in the far third of the bar's range
            double rng = high[i] - low[i];
            if(rng <= 0.0) continue;
            bool body = (dirp > 0) ? (close[i] > open[i]) : (close[i] < open[i]);
            double posInBar = (close[i] - low[i]) / rng;
            bool tail = (dirp > 0) ? (posInBar >= 0.66) : (posInBar <= 0.34);
            if(!body || !tail) continue;
           }
        }

      //--- daily budget. Applied to history as well by default, so the dots on
      //--- the chart are the trades you would actually have been allowed to
      //--- take, not every setup the strategy ever found.
      RollDay(time[i]);
      if(InpBudgetOnHistory && DayBudgetSpent()) { g_rejDaily++; continue; }

      //--- Re-price to the fill that actually happens.
      //--- With confirmation on you are filled at the close, not at the zone,
      //--- and pretending otherwise would flatter every statistic below.
      double fill = (InpConfirm == CONFIRM_TOUCH) ? g_pending[k].entry
                                                  : NormalizePrice(close[i]);
      double fillRisk = MathAbs(fill - g_pending[k].sl);
      if(fillRisk <= 0.0) { g_pending[k].active = false; continue; }

      //--- anti-chase: if the confirming close has already run past the zone,
      //--- the good price is gone and what is left is a worse trade wearing the
      //--- same setup's clothes
      double planRisk = MathAbs(g_pending[k].entry - g_pending[k].sl);
      if(planRisk > 0.0)
        {
         double chased = MathAbs(fill - g_pending[k].entry) / planRisk;
         if(chased > InpMaxChaseR) { g_rejChase++; g_pending[k].active = false; continue; }
        }

      //--- and the draw must still be worth reaching from the real fill
      if((MathAbs(g_pending[k].tp2 - fill) / fillRisk) < InpMinRR)
        { g_rejRR++; g_pending[k].active = false; continue; }

      //--- R-based targets move with the fill; TP2 is structural and does not
      g_pending[k].entry = fill;
      g_pending[k].tp1   = NormalizePrice((dirp > 0) ? fill + InpTP1_R * fillRisk
                                                     : fill - InpTP1_R * fillRisk);
      g_pending[k].tp3   = NormalizePrice((dirp > 0) ? fill + InpTP3_R * fillRisk
                                                     : fill - InpTP3_R * fillRisk);

      //--- fired on the close of this bar and never revised
      g_signalCount++;
      int idx = g_signalCount;

      double atr = BufATR[i];
      int    dir = g_pending[k].dir;

      //--- Two markers, and they mean different things.
      //---
      //--- TURN dot (small, dim) sits on the bar that actually made the high or
      //--- low. That is the picture a classic signal chart shows. It is written
      //--- once, after that bar closed, and never moved - so nothing repaints -
      //--- but it appears only now, several bars later, because a swing low is
      //--- not knowable at the swing low.
      //---
      //--- ENTRY dot (large, bright) sits on the bar whose close filled the
      //--- entry. That is the price that was genuinely takeable, and it is what
      //--- the alert, the journal and every statistic are driven by.
      int turnBar = (g_pending[k].dotBar >= 0 && g_pending[k].dotBar <= i)
                    ? g_pending[k].dotBar : i;

      double turnAtr = (BufATR[turnBar] > 0.0) ? BufATR[turnBar] : atr;
      double turnPrice = (dir > 0) ? (low[turnBar]  - 0.5 * turnAtr)
                                   : (high[turnBar] + 0.5 * turnAtr);
      double entryPrice = (dir > 0) ? (low[i]  - 0.9 * atr)
                                    : (high[i] + 0.9 * atr);

      if(InpDotAnchor == DOT_BOTH || InpDotAnchor == DOT_SWING_EXTREME)
        {
         if(dir > 0) BufBuyTurn[turnBar]  = turnPrice;
         else        BufSellTurn[turnBar] = turnPrice;
        }
      if(InpDotAnchor == DOT_BOTH || InpDotAnchor == DOT_ENTRY_BAR)
        {
         if(dir > 0) BufBuy[i]  = entryPrice;
         else        BufSell[i] = entryPrice;
        }

      //--- the BUY / SELL word rides with the turn dot, as in a signal chart
      int    labelBar   = (InpDotAnchor == DOT_ENTRY_BAR) ? i : turnBar;
      double labelPrice = (InpDotAnchor == DOT_ENTRY_BAR) ? entryPrice : turnPrice;
      double arrowPrice = labelPrice;

      double lots = SuggestLots(g_pending[k].entry, g_pending[k].sl);
      double risk = MathAbs(g_pending[k].entry - g_pending[k].sl);

      //--- Every signal in history gets its dots and its BUY / SELL word, which
      //--- are buffer plots and cost nothing. The full entry/SL/TP line set is
      //--- drawn only on recent bars - one signal is ten chart objects, and a
      //--- few hundred of them will bog the chart down for no benefit.
      bool drawLevels = (InpLevelsRecentBars <= 0) || (i >= rates_total - InpLevelsRecentBars);

      int lastIdx = MathMin(rates_total - 1, i + InpLevelBars);
      DrawSignalLevels(idx, g_pending[k].dir, time[i], time[lastIdx],
                       g_pending[k].entry, g_pending[k].sl, g_pending[k].tp1,
                       g_pending[k].tp2, g_pending[k].tp3,
                       g_pending[k].gradeText, arrowPrice, lots, time[labelBar], drawLevels);

      if(InpTrackOutcomes)
        {
         int n = ArraySize(g_trades);
         ArrayResize(g_trades, n + 1);
         g_trades[n].idx       = idx;
         g_trades[n].dir       = g_pending[k].dir;
         g_trades[n].entryBar  = i;
         g_trades[n].entryTime = time[i];
         g_trades[n].entry     = g_pending[k].entry;
         g_trades[n].sl        = g_pending[k].sl;
         g_trades[n].tp1       = g_pending[k].tp1;
         g_trades[n].tp2       = g_pending[k].tp2;
         g_trades[n].tp3       = g_pending[k].tp3;
         g_trades[n].risk      = risk;
         g_trades[n].grade     = g_pending[k].grade;
         g_trades[n].gradeText = g_pending[k].gradeText;
         g_trades[n].open      = true;
         g_trades[n].hitTP1    = false;
         g_trades[n].hitTP2    = false;
         g_trades[n].hitTP3    = false;
         g_trades[n].result    = 0;
         g_trades[n].rMultiple = 0.0;
         g_trades[n].inSession = InSession(time[i]);
         g_trades[n].mae       = 0.0;
         g_trades[n].mfe       = 0.0;
         g_trades[n].entryDay  = UserDay(time[i]);
        }

      double rr2 = (risk > 0.0) ? MathAbs(g_pending[k].tp2 - g_pending[k].entry) / risk : 0.0;
      g_lastSignalTxt = StringFormat("%s %s @ %s  SL %s  TP2 %s  (%.1fR)",
                                     (g_pending[k].dir > 0 ? "BUY" : "SELL"),
                                     g_pending[k].gradeText,
                                     DoubleToString(g_pending[k].entry, g_digits),
                                     DoubleToString(g_pending[k].sl,    g_digits),
                                     DoubleToString(g_pending[k].tp2,   g_digits),
                                     rr2);

      bool isLive = (g_liveMode && i == rates_total - 2);
      if(isLive)
         JournalSignal(time[i], g_pending[k].dir, g_pending[k].gradeText, g_pending[k].grade,
                       g_pending[k].entry, g_pending[k].sl, g_pending[k].tp1,
                       g_pending[k].tp2, g_pending[k].tp3, g_pending[k].reason);

      if(InpAlertTrigger && isLive && time[i] != g_lastAlertBar)
        {
         g_lastAlertBar = time[i];
         FireAlert("TRIGGER",
                   StringFormat("%s | entry %s | SL %s | TP1 %s | TP2 %s | TP3 %s | lots %s | %s",
                                g_lastSignalTxt,
                                DoubleToString(g_pending[k].entry, g_digits),
                                DoubleToString(g_pending[k].sl,    g_digits),
                                DoubleToString(g_pending[k].tp1,   g_digits),
                                DoubleToString(g_pending[k].tp2,   g_digits),
                                DoubleToString(g_pending[k].tp3,   g_digits),
                                DoubleToString(lots, 2),
                                g_pending[k].reason));
        }

      SharedAddTrade();
      g_pending[k].active = false;
     }
  }

//+------------------------------------------------------------------+
//| WATCH alerts: a setup is armed and price is approaching it       |
//+------------------------------------------------------------------+
void MaybeWatchAlerts(const int i, const int rates_total, const datetime &time[],
                      const double &close[])
  {
   if(!InpAlertWatch)       return;
   if(!g_liveMode)          return;
   if(i != rates_total - 2) return;

   double atr = BufATR[i];
   if(atr <= 0.0) return;

   for(int k = 0; k < ArraySize(g_pending); k++)
     {
      if(!g_pending[k].active)      continue;
      if(g_pending[k].watchAlerted) continue;
      if(MathAbs(close[i] - g_pending[k].entry) > 1.5 * atr) continue;

      g_pending[k].watchAlerted = true;
      g_lastWatchBar = time[i];

      FireAlert("WATCH",
                StringFormat("%s %s setup armed - entry %s | SL %s | TP2 %s | %s",
                             (g_pending[k].dir > 0 ? "BUY" : "SELL"),
                             g_pending[k].gradeText,
                             DoubleToString(g_pending[k].entry, g_digits),
                             DoubleToString(g_pending[k].sl,    g_digits),
                             DoubleToString(g_pending[k].tp2,   g_digits),
                             g_pending[k].reason));
     }
  }


//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
void UpdateDiagnostics();

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

   string ema = "";
   if(InpUseEMA && g_lastEmaTrend != 0)
      ema = StringFormat(" | EMA %d/%d %s", InpEmaFast, InpEmaSlow,
                         (g_lastEmaTrend > 0 ? "up" : "down"));
   else if(InpUseEMA)
      ema = " | EMA flat";

   //--- synthetic classification, plus what the bars actually show
   string synth = "";
   if(g_family != FAM_NONE)
     {
      int measured = MeasuredSpikeDir();
      string obs = StringFormat(" [spikes up %d / down %d]", g_spikeUp, g_spikeDown);

      if(g_family == FAM_RANDOM)
         synth = " | " + g_familyName + ": random walk, no directional edge" + obs;
      else if(g_family == FAM_ADAPTIVE)
        {
         int    pred = PredictedNextSpikeDir();
         double acc  = ModelAccuracy();
         synth = " | " + g_familyName + ": next jump "
               + (pred > 0 ? "UP" : pred < 0 ? "DOWN" : "undecided");
         if(acc >= 0.0)
           {
            synth += StringFormat("  model %.0f%% (%d/%d)", acc, g_predCorrect, g_predTotal);
            if(acc < 55.0) synth += " << NO BETTER THAN A COIN, IGNORE THE BIAS";
           }
         synth += obs;
        }
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

      //--- average heat: how much of the stop a trade typically eats before
      //--- resolving. Winners' heat is the number to tune the stop against.
      double heatAll = g_maeSumAll / g_resolved;
      if(g_wins > 0)
         stats += StringFormat("  heat %.2fR (winners %.2fR)", heatAll, g_maeSumWin / g_wins);
      else
         stats += StringFormat("  heat %.2fR", heatAll);

      //--- is your window actually better, or does it only feel better?
      if(InpUseSession && g_inSessResolved >= 5 && g_outSessResolved >= 5)
        {
         double inW  = 100.0 * g_inSessWins  / g_inSessResolved;
         double outW = 100.0 * g_outSessWins / g_outSessResolved;
         stats += StringFormat("  ||  in-session %.0f%% (%d)  vs  outside %.0f%% (%d)",
                               inW, g_inSessResolved, outW, g_outSessResolved);
        }
     }

   string today = "";
   if(InpMaxTradesPerDay > 0 || InpDailyLossLimitR > 0.0)
     {
      string scope = (InpBudgetScope == BUDGET_ACCOUNT) ? "all charts"
                   : (InpBudgetScope == BUDGET_SYMBOL)  ? "this symbol" : "this chart";
      today = StringFormat(" | today %d", SharedDayTrades());
      if(InpMaxTradesPerDay > 0) today += StringFormat("/%d", InpMaxTradesPerDay);
      today += StringFormat(" trades %+.1fR (%s)", SharedDayR(), scope);
      if(DayBudgetSpent()) today += " - DONE FOR TODAY";
     }

   ObjectSetString(0, name, OBJPROP_TEXT,
                   StringFormat("Apex ICT | %s %s | structure %s | signals %d%s%s | %s%s",
                                _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period),
                                trend, g_signalCount, stats, today, g_lastSignalTxt, synth + ema));
   ObjectSetInteger(0, name, OBJPROP_COLOR,
                    (g_trendMajor > 0) ? InpBuyColor : (g_trendMajor < 0 ? InpSellColor : clrGray));

   UpdateDiagnostics();
  }

//+------------------------------------------------------------------+
//| Diagnostics line.                                                |
//|                                                                   |
//| When the engine prints nothing, the useful question is not "why   |
//| is it broken" but "which filter ate the candidates". This counts  |
//| every rejection by stage, so the answer is on the chart.          |
//+------------------------------------------------------------------+
void UpdateDiagnostics()
  {
   if(!InpShowDiagnostics) return;

   string name = PREFIX + "DIAG";
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 12);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE,
                       (InpShowHeader ? (26 + 4 * (InpHdrFontSize + 6)) : 20) + 16);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrGray);
     }

   int rejected = g_rejNoSweep + g_rejDisp + g_rejNoFVG + g_rejRR
                + g_rejPD + g_rejSynth + g_rejGrade + g_rejEMA + g_rejSession
                + g_rejChase + g_rejDaily;

   //--- name the stage that is doing the most damage
   string worst = "none";
   int    worstN = 0;
   if(g_rejNoSweep > worstN) { worstN = g_rejNoSweep; worst = "no sweep"; }
   if(g_rejDisp    > worstN) { worstN = g_rejDisp;    worst = "displacement too weak"; }
   if(g_rejNoFVG   > worstN) { worstN = g_rejNoFVG;   worst = "no FVG in the impulse"; }
   if(g_rejRR      > worstN) { worstN = g_rejRR;      worst = "draw too close (Min RR)"; }
   if(g_rejPD      > worstN) { worstN = g_rejPD;      worst = "premium/discount filter"; }
   if(g_rejSynth   > worstN) { worstN = g_rejSynth;   worst = "spike-direction filter"; }
   if(g_rejGrade   > worstN) { worstN = g_rejGrade;   worst = "below minimum grade"; }
   if(g_rejEMA     > worstN) { worstN = g_rejEMA;     worst = "against the EMA trend"; }
   if(g_rejSession > worstN) { worstN = g_rejSession; worst = "outside your session window"; }
   if(g_rejChase   > worstN) { worstN = g_rejChase;   worst = "confirmation ran too far (chase)"; }
   if(g_rejDaily   > worstN) { worstN = g_rejDaily;   worst = "daily trade / loss budget spent"; }

   ObjectSetString(0, name, OBJPROP_TEXT,
                   StringFormat("candidates rejected %d  [sweep %d | disp %d | fvg %d | RR %d | PD %d | spike %d | grade %d | ema %d | sess %d | chase %d | daily %d]"
                                "   armed %d  expired %d  stopped-pre-entry %d   biggest blocker: %s",
                                rejected, g_rejNoSweep, g_rejDisp, g_rejNoFVG, g_rejRR,
                                g_rejPD, g_rejSynth, g_rejGrade, g_rejEMA, g_rejSession,
                                g_rejChase, g_rejDaily,
                                g_armed, g_expired, g_slBeforeEntry, worst));
  }

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   SetIndexBuffer(0, BufBuy,      INDICATOR_DATA);
   SetIndexBuffer(1, BufSell,     INDICATOR_DATA);
   SetIndexBuffer(2, BufBuyTurn,  INDICATOR_DATA);
   SetIndexBuffer(3, BufSellTurn, INDICATOR_DATA);
   SetIndexBuffer(4, BufATR,      INDICATOR_CALCULATIONS);
   SetIndexBuffer(5, BufEmaF,     INDICATOR_CALCULATIONS);
   SetIndexBuffer(6, BufEmaS,     INDICATOR_CALCULATIONS);

   ArraySetAsSeries(BufBuy,      false);
   ArraySetAsSeries(BufSell,     false);
   ArraySetAsSeries(BufBuyTurn,  false);
   ArraySetAsSeries(BufSellTurn, false);
   ArraySetAsSeries(BufATR,      false);
   ArraySetAsSeries(BufEmaF,     false);
   ArraySetAsSeries(BufEmaS,     false);

   //--- entry dots: the price that was actually takeable
   if(InpMarker == MARK_DOT)
     {
      PlotIndexSetInteger(0, PLOT_ARROW, InpDotCodeEntry);
      PlotIndexSetInteger(1, PLOT_ARROW, InpDotCodeEntry);
     }
   else
     {
      PlotIndexSetInteger(0, PLOT_ARROW, 233);     // up arrow
      PlotIndexSetInteger(1, PLOT_ARROW, 234);     // down arrow
     }

   //--- turn dots: smaller and dimmer, so the takeable dot stays the loud one
   PlotIndexSetInteger(2, PLOT_ARROW, InpDotCodeTurn);
   PlotIndexSetInteger(3, PLOT_ARROW, InpDotCodeTurn);
   PlotIndexSetInteger(2, PLOT_LINE_COLOR, 0, InpTurnBuyColor);
   PlotIndexSetInteger(3, PLOT_LINE_COLOR, 0, InpTurnSellColor);
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, 0, InpBuyColor);
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, 0, InpSellColor);

   for(int pl = 0; pl < 4; pl++)
     {
      PlotIndexSetInteger(pl, PLOT_ARROW_SHIFT, 0);
      PlotIndexSetDouble(pl, PLOT_EMPTY_VALUE, EMPTY_VALUE);
     }
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
      PrintFormat("ApexICT: %s changes mode by design. Its next-jump direction comes from "
                  "a state machine, and the model reports its own hit rate on the panel. "
                  "If that rate sits near 50%%, the model is wrong for this instrument - "
                  "set 'Synthetic handling' to Off and trade the structure alone.",
                  g_familyName);

   if(g_family == FAM_SYMMETRIC)
      PrintFormat("ApexICT: %s has no spike mechanic, so no directional bias is applied. "
                  "The structure engine runs normally.", g_familyName);

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
   if(InpUseEMA) warmup = MathMax(warmup, InpEmaSlow + 10);
   if(rates_total < warmup + 10) return 0;

   g_liveMode = (prev_calculated > 0);

   int start;

   if(prev_calculated == 0)
     {
      ArrayInitialize(BufBuy,      EMPTY_VALUE);
      ArrayInitialize(BufSell,     EMPTY_VALUE);
      ArrayInitialize(BufBuyTurn,  EMPTY_VALUE);
      ArrayInitialize(BufSellTurn, EMPTY_VALUE);
      ArrayInitialize(BufATR,  0.0);
      ArrayInitialize(BufEmaF, 0.0);
      ArrayInitialize(BufEmaS, 0.0);
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
   //--- rolling true-range sum: one add and one subtract per bar instead of
   //--- re-summing the whole window, which is where the old pass burned its time
   const int atrPeriod = 14;
   if(start >= atrPeriod + 1)
     {
      double trSum = 0.0;
      for(int k = start - atrPeriod + 1; k <= start; k++)
         trSum += TrueRange(k, high, low, close);
      BufATR[start] = trSum / atrPeriod;

      for(int i = start + 1; i < rates_total; i++)
        {
         trSum += TrueRange(i, high, low, close)
                - TrueRange(i - atrPeriod, high, low, close);
         BufATR[i] = trSum / atrPeriod;
        }
     }

   //--- EMAs, recursive so each bar costs one multiply. Seeded from the first
   //--- bar we touch; the seed washes out long before any signal is graded.
   if(InpUseEMA)
     {
      double kF = 2.0 / (MathMax(1, InpEmaFast) + 1.0);
      double kS = 2.0 / (MathMax(1, InpEmaSlow) + 1.0);
      for(int i = start; i < rates_total; i++)
        {
         if(i == 0 || BufEmaF[i-1] <= 0.0)
           { BufEmaF[i] = close[i]; BufEmaS[i] = close[i]; continue; }
         BufEmaF[i] = close[i] * kF + BufEmaF[i-1] * (1.0 - kF);
         BufEmaS[i] = close[i] * kS + BufEmaS[i-1] * (1.0 - kS);
        }
     }

   //--- main pass: closed bars only, so the live bar never influences anything
   int last = rates_total - 2;

   for(int i = start; i <= last; i++)
     {
      //--- a bar is analysed exactly once. Without this guard the overlap bar
      //--- that MT5 re-sends on every tick would duplicate swings and gaps.
      if(time[i] <= g_lastProcessed) continue;
      g_lastProcessed = time[i];

      BufBuy[i]      = EMPTY_VALUE;
      BufSell[i]     = EMPTY_VALUE;
      BufBuyTurn[i]  = EMPTY_VALUE;
      BufSellTurn[i] = EMPTY_VALUE;

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
      DetectSpike(i, time, open, high, low);

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

      //--- the model: an internal shift in the direction opposite the sweep.
      //--- The shift is queued, then arming is retried across a grace window,
      //--- because the impulse FVG often completes a bar or two after the break.
      if(intBreak != 0) PushMSS(i, intBreak);
      ProcessMSS(i, close, time[i]);

      //--- follow already-emitted signals to their outcome before a new one fires,
      //--- so a signal never resolves itself on its own entry bar
      UpdateTrades(i, time, high, low);

      g_lastEmaTrend = EMATrend(i, close);

      //--- entry fill
      MaybeSessionBrief(i, rates_total, time, close);
      MaybeWatchAlerts(i, rates_total, time, close);
      TryTriggerSetups(i, rates_total, time, open, high, low, close);
     }

   //--- keep the live bar clean
   if(rates_total >= 1)
     {
      BufBuy[rates_total-1]      = EMPTY_VALUE;
      BufSell[rates_total-1]     = EMPTY_VALUE;
      BufBuyTurn[rates_total-1]  = EMPTY_VALUE;
      BufSellTurn[rates_total-1] = EMPTY_VALUE;
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

   //--- shade your window so it is obvious which bars it covers
   if(InpUseSession && InpShadeSession)
     {
      ObjectsDeleteAll(0, PREFIX + "SESS");
      int from = MathMax(1, rates_total - 400);
      int band = 0;
      int runStart = -1;
      for(int i = from; i <= rates_total - 2 && band < 40; i++)
        {
         bool in = InSession(time[i]);
         if(in && runStart < 0) runStart = i;
         if((!in || i == rates_total - 2) && runStart >= 0)
           {
            int runEnd = (in ? i : i - 1);
            string nm = StringFormat("%sSESS%d", PREFIX, band++);
            double top = high[runStart], bot = low[runStart];
            for(int b = runStart; b <= runEnd; b++)
              { if(high[b] > top) top = high[b]; if(low[b] < bot) bot = low[b]; }
            if(ObjectCreate(0, nm, OBJ_RECTANGLE, 0, time[runStart], top, time[runEnd], bot))
              {
               ObjectSetInteger(0, nm, OBJPROP_COLOR, clrGainsboro);
               ObjectSetInteger(0, nm, OBJPROP_FILL, true);
               ObjectSetInteger(0, nm, OBJPROP_BACK, true);
               ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
               ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
              }
            runStart = -1;
           }
        }
     }

   DrawPendingSetups(rates_total, time, close);
   UpdateHeader();
   UpdatePanel();
   return rates_total;
  }
//+------------------------------------------------------------------+
