//+------------------------------------------------------------------+
//|                                              CRT_Sniper_Pro.mq5  |
//|      Candle Range Theory + HTF bias + spike engine + scoring     |
//+------------------------------------------------------------------+
#property copyright   "CRT Sniper Pro"
#property version     "2.00"
#property description "Graded BUY / SELL dots backed by Candle Range Theory, higher-timeframe bias,"
#property description "premium-discount location, market structure shifts and candlestick confirmation."
#property description "Includes a spike engine for Boom / Crash / GainX / PainX that trades both"
#property description "with the spike and against it, plus a live self-scoring performance tracker."
#property description "Signals are evaluated on closed bars only - the indicator does not repaint."
#property indicator_chart_window
#property indicator_buffers 10
#property indicator_plots   4

//--- plot 1 : premium grade BUY
#property indicator_label1  "CRT Buy A+"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrDodgerBlue
#property indicator_width1  4
//--- plot 2 : standard BUY
#property indicator_label2  "CRT Buy"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrSteelBlue
#property indicator_width2  2
//--- plot 3 : premium grade SELL
#property indicator_label3  "CRT Sell A+"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrOrangeRed
#property indicator_width3  4
//--- plot 4 : standard SELL
#property indicator_label4  "CRT Sell"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrIndianRed
#property indicator_width4  2

#define PREFIX   "CRTP_"
#define MAXSIG   256
#define MAXOPEN  64
#define MAXROWS  64

//--- market regime
#define REG_RANGE 0
#define REG_BULL  1
#define REG_BEAR  2

//--- entry models
#define NMODELS   9
#define MODE_CRT   0   // Candle Range Theory : anchor raid -> MSS -> retest
#define MODE_HUNT  1   // spike hunt   (with the spike)
#define MODE_FADE  2   // spike fade   (against the spike)
#define MODE_SWEEP 3   // liquidity sweep + reclaim
#define MODE_BRT   4   // break and retest
#define MODE_TPB   5   // trend pullback to EMA 50
#define MODE_ASIA  6   // Asian range sweep (Judas swing)
#define MODE_NBO   7   // news breakout continuation
#define MODE_NFD   8   // news spike reversal

//--- sessions
#define SESS_OFF    0
#define SESS_ASIA   1
#define SESS_LONDON 2
#define SESS_NY     3

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

enum ENUM_SYMCLASS
  {
   SC_AUTO       = 0,  // Auto detect
   SC_FX         = 1,  // Forex
   SC_METAL      = 2,  // Metals
   SC_INDEX      = 3,  // Stock index
   SC_CRYPTO     = 4,  // Crypto
   SC_VOL        = 5,  // Volatility / synthetic (no spikes)
   SC_SPIKE_UP   = 6,  // Spikes UP  - Boom, GainX
   SC_SPIKE_DOWN = 7   // Spikes DOWN - Crash, PainX
  };

enum ENUM_SPIKEDIR
  {
   SPD_AUTO = 0,  // Auto detect
   SPD_UP   = 1,  // Spikes up (Boom / GainX)
   SPD_DOWN = 2   // Spikes down (Crash / PainX)
  };

enum ENUM_STYLE
  {
   STY_AUTO  = 0, // Auto (from chart timeframe)
   STY_SCALP = 1, // Scalp
   STY_INTRA = 2, // Intraday / day trade
   STY_SWING = 3  // Swing
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Trading style ==="
input ENUM_STYLE      InpTradeStyle       = STY_AUTO;       // Trading style
input bool            InpStyleTune        = true;           // Let the style set targets, expiry, cooldown, stops
input double          InpMinTpSpreadX     = 0.0;            // Override: TP1 must be >= this x spread (0 = use style)

input group "=== Symbol adaptation (any broker, any symbol) ==="
input bool            InpAutoTune         = true;           // Auto-tune thresholds to the detected symbol class
input ENUM_SYMCLASS   InpForceClass       = SC_AUTO;        // Force symbol class
input ENUM_SPIKEDIR   InpForceSpikeDir    = SPD_AUTO;       // Force spike direction
input bool            InpStatDetect       = true;           // Detect spikes statistically when the name is unknown

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
input bool            InpBlockInRange     = true;           // Block CRT signals while HTF is SIDEWAYS

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
input int             InpCooldownBars     = 3;              // Min bars between signals of the same engine

input group "=== SPIKE ENGINE (Boom / Crash / GainX / PainX) ==="
input bool            InpTradeSpikes      = true;           // HUNT: trade WITH the spike (against the drift)
input bool            InpTradeFades       = true;           // FADE: trade AGAINST the spike (with the drift)
input double          InpSpikeMult        = 5.0;            // Spike bar = range >= this x median drift range
input int             InpDriftWin         = 50;             // Median drift-range window (bars)
input int             InpDriftChanLook    = 50;             // Drift channel lookback (bars)
input double          InpHuntMinDueness   = 0.70;           // HUNT: min spike due-ness (1.0 = average interval)
input double          InpHuntMaxDueness   = 2.50;           // HUNT: max due-ness (beyond this the model is stale)
input double          InpHuntMaxPos       = 0.35;           // HUNT: max position in the drift channel
input bool            InpHuntNeedCrt      = true;           // HUNT: require a CRT raid in the spike direction
input double          InpHuntSlDrift      = 3.0;            // HUNT: stop distance beyond structure (x drift range)
input double          InpSpikeTP1Frac     = 0.50;           // HUNT: TP1 as a fraction of the median spike
input double          InpSpikeTP2Frac     = 1.00;           // HUNT: TP2 as a fraction of the median spike
input int             InpFadeWindow       = 3;              // FADE: enter within N bars of the spike
input double          InpFadeMinExhaust   = 0.35;           // FADE: min give-back of the spike range
input double          InpFadeBlockDueness = 0.85;           // FADE: block when the next spike is this due
input double          InpFadeSlBuf        = 0.50;           // FADE: stop beyond the spike extreme (x drift range)
input double          InpFadeTp2Drift     = 3.0;            // FADE: TP2 beyond the pre-spike level (x drift range)
input int             InpMinSpikesToTrade = 3;              // Min spikes observed before the engine arms

input group "=== Entry models ==="
input bool            InpUseCRT           = true;           // CRT : anchor raid -> MSS -> retest
input bool            InpUseSweep         = true;           // Liquidity sweep + reclaim
input bool            InpUseBRT           = true;           // Break and retest
input bool            InpUseTPB           = true;           // Trend pullback to EMA 50
input bool            InpUseAsia          = true;           // Asian range sweep (Judas swing)
input int             InpSweepLook        = 20;             // Sweep : prior-low/high lookback (bars)
input double          InpSweepMinATR      = 0.15;           // Sweep : min penetration beyond the level (x ATR)
input double          InpBrtTolATR        = 0.35;           // Break+retest : retest tolerance (x ATR)
input int             InpBrtExpiry        = 30;             // Break+retest : level stays armed N bars
input double          InpTpbMaxDepth      = 0.62;           // Pullback : max retracement of the leg (0..1)
input int             InpAsiaSweepStart   = 7;              // Asian sweep : hunt window start (GMT hour)
input int             InpAsiaSweepEnd     = 12;             // Asian sweep : hunt window end (GMT hour)

input group "=== News filter (MT5 economic calendar) ==="
input bool            InpUseNews          = true;           // Block signals around high-impact news
input bool            InpNewsHighOnly     = true;           // High impact only (off = high + medium)
input int             InpNewsBefore       = 30;             // Blackout before the release (minutes)
input int             InpNewsAfter        = 30;             // Blackout after the release (minutes)

input group "=== News TRADING (MT5 calendar) ==="
input bool            InpTradeNews        = true;           // Trade the release instead of only avoiding it
input bool            InpNewsBO           = true;           // News breakout continuation
input bool            InpNewsFade         = true;           // News spike reversal
input int             InpNewsPreRange     = 30;             // Pre-news range built over N minutes
input int             InpNewsDelay        = 2;              // Wait N minutes after the release before entering
input int             InpNewsWindow       = 60;             // Models stay live for N minutes after release
input bool            InpNewsBoNeedBias   = false;          // Breakout must agree with the HTF bias
input double          InpNewsDispATR      = 1.00;           // Breakout displacement beyond the range (x ATR)
input double          InpNewsSpikeATR     = 1.50;           // Reversal : spike beyond the range (x ATR)
input string          InpExtraNewsCcy     = "";             // Extra currencies to watch, comma separated

input group "=== Freshness (turns a dot into an entry) ==="
input bool            InpUseFreshness     = true;           // Expire signals that price has run away from
input double          InpMaxChaseR        = 0.30;           // Max adverse chase from the signal price (in R)
input int             InpSignalTTL        = 3;              // Signal stops being actionable after N bars

input group "=== Signal quality & grading ==="
input int             InpMinScore         = 62;             // Minimum confluence score to print a dot (0-100)
input int             InpPremiumScore     = 85;             // Score at or above this prints the large A+ dot
input bool            InpShowScore        = true;           // Print the score next to each dot
input int             InpShowLastGrades   = 30;             // Score labels for the last N signals

input group "=== Sessions / killzones (GMT) ==="
input bool            InpUseSessions      = false;          // Only signal inside the selected killzones
input int             InpGmtOffset        = 0;              // Broker server offset from GMT (hours)
input bool            InpAsia             = true;           // Asian killzone
input int             InpAsiaStart        = 0;              // Asia start (GMT hour)
input int             InpAsiaEnd          = 4;              // Asia end (GMT hour)
input bool            InpLondon           = true;           // London killzone
input int             InpLonStart         = 7;              // London start (GMT hour)
input int             InpLonEnd           = 10;             // London end (GMT hour)
input bool            InpNewYork          = true;           // New York killzone
input int             InpNYStart          = 12;             // New York start (GMT hour)
input int             InpNYEnd            = 15;             // New York end (GMT hour)

input group "=== Risk : stop loss & targets ==="
input int             InpAtrPeriod        = 14;             // ATR period
input int             InpSlLookback       = 6;              // Structural SL lookback (bars)
input double          InpSlBufATR         = 0.30;           // SL buffer beyond structure (x ATR)
input double          InpMaxRiskATR       = 4.0;            // Skip signal if risk > this (x ATR, 0 = off)
input double          InpRR1              = 2.0;            // Take profit 1 (R multiple)
input double          InpRR2              = 3.5;            // Take profit 2 (R multiple)
input bool            InpUseLiquidityTP   = true;           // Push TP2 to the opposing liquidity if further
input int             InpLiqLookback      = 30;             // Opposing liquidity lookback (bars)
input double          InpAccountRiskPct   = 1.0;            // Account risk per trade (%) for the lot calculator

input group "=== Performance tracker ==="
input bool            InpTrackStats       = true;           // Forward-test every printed signal on history

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
input bool            InpPanelCompact     = false;          // Compact dashboard (hide performance block)
input ENUM_BASE_CORNER InpCorner          = CORNER_LEFT_UPPER; // Panel corner
input int             InpPanelX           = 12;             // Panel X offset
input int             InpPanelY           = 22;             // Panel Y offset
input int             InpFontSize         = 8;              // Panel font size
input string          InpFontName         = "Consolas";     // Panel font
input color           InpPanelBG          = C'16,18,26';    // Panel background
input color           InpPanelText        = clrGainsboro;   // Panel text

input group "=== Alerts ==="
input bool            InpAlertPopup       = true;           // Popup alert
input bool            InpAlertPush        = false;          // Push notification
input bool            InpAlertSound       = true;           // Sound alert
input string          InpSoundFile        = "alert.wav";    // Sound file

//+------------------------------------------------------------------+
//| Buffers                                                          |
//+------------------------------------------------------------------+
double BufBuyHi[];    // 0 premium buy dot
double BufBuyLo[];    // 1 standard buy dot
double BufSellHi[];   // 2 premium sell dot
double BufSellLo[];   // 3 standard sell dot
double BufSL[];       // 4
double BufTP1[];      // 5
double BufTP2[];      // 6
double BufDir[];      // 7  +1 buy, -1 sell
double BufScore[];    // 8  0..100
double BufMode[];     // 9  0 CRT, 1 HUNT, 2 FADE

//+------------------------------------------------------------------+
//| Handles                                                          |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES g_htf = PERIOD_D1;
ENUM_TIMEFRAMES g_mtf = PERIOD_H1;

int g_hEmaF = INVALID_HANDLE, g_hEmaS = INVALID_HANDLE, g_hAtr = INVALID_HANDLE, g_hAdx = INVALID_HANDLE;
int g_hEmaFH = INVALID_HANDLE, g_hEmaSH = INVALID_HANDLE, g_hAtrH = INVALID_HANDLE, g_hAdxH = INVALID_HANDLE;
int g_hEmaFM = INVALID_HANDLE, g_hEmaSM = INVALID_HANDLE, g_hAtrM = INVALID_HANDLE, g_hAdxM = INVALID_HANDLE;

ENUM_TIMEFRAMES g_ribTf[4] = {PERIOD_M15, PERIOD_H1, PERIOD_H4, PERIOD_D1};
int g_ribEmaF[4], g_ribEmaS[4], g_ribAtr[4], g_ribAdx[4];
int g_ribBias[4];

//--- series (all series-indexed: 0 = newest)
MqlRates g_hr[];
double   g_hEmaFv[], g_hEmaSv[], g_hAtrv[], g_hAdxv[];
double   g_emaFv[], g_emaSv[], g_atrv[], g_adxv[];
double   g_mEmaFv[], g_mEmaSv[], g_mAtrv[], g_mAdxv[];

//+------------------------------------------------------------------+
//| Tuned working parameters (auto-tune may override the inputs)     |
//+------------------------------------------------------------------+
double g_dispATR, g_maxRiskATR, g_adxTrend, g_spikeMult, g_minSepATR;
bool   g_useSessions;

//--- style-driven working parameters
int    g_style      = STY_INTRA;
double g_rr1        = 2.0;
double g_rr2        = 3.5;
double g_slBuf      = 0.30;
double g_minTpSprdX = 4.0;
int    g_expiry     = 24;
int    g_cooldown   = 3;
int    g_minScore   = 62;
bool   g_liqTP      = true;

//--- break-and-retest armed level
int    g_brtDir   = 0;
double g_brtLevel = 0.0;
int    g_brtBar   = -1;

//--- health / diagnostics
int    g_newsReject   = 0;
int    g_htfAvail     = 0;
bool   g_htfOk        = true;
int    g_spreadReject = 0;

//+------------------------------------------------------------------+
//| Symbol profile                                                   |
//+------------------------------------------------------------------+
int    g_symClass   = SC_AUTO;
int    g_spikeDir   = 0;          // +1 spikes up, -1 spikes down, 0 not a spike index
int    g_nominal    = 0;          // number parsed out of the symbol name
string g_classHow   = "";         // how the class was decided

//+------------------------------------------------------------------+
//| Spike engine state                                               |
//+------------------------------------------------------------------+
int    g_lastSpikeBar  = -1;
int    g_lastSpikeDir  = 0;
double g_lastSpikeHigh = 0.0, g_lastSpikeLow = 0.0, g_lastSpikeRange = 0.0;
double g_preSpikeClose = 0.0;

double g_spikeSizes[32];
int    g_spikeSizeN = 0;
int    g_spikeGaps[32];
int    g_spikeGapN = 0;
int    g_spikeSeen = 0;
double g_avgGap = 0.0;
double g_medSpike = 0.0;
double g_gapConsistency = 0.0;

//+------------------------------------------------------------------+
//| CRT / setup state machine                                        |
//+------------------------------------------------------------------+
struct CRTInfo
  {
   bool     found;
   int      dir;
   double   hi, lo;
   datetime raidTime;
   int      raidShift;
   double   qual;       // 0..1 sweep depth + reclaim strength
  };

datetime g_stRaid    = 0;
int      g_stDir     = 0;
double   g_stCrtHi   = 0.0, g_stCrtLo = 0.0, g_stCrtQual = 0.0;
bool     g_stMss     = false;
double   g_stMssLvl  = 0.0;
int      g_stMssBar  = -1;
double   g_stDisp    = 0.0;
bool     g_stZone    = false;
double   g_stZoneHi  = 0.0, g_stZoneLo = 0.0;
string   g_stZoneKind = "";
int      g_lastSigBarMode[NMODELS];
int      g_lastProc  = -1;

double   g_swHigh = 0.0, g_swLow = 0.0;
int      g_swHighBar = -1, g_swLowBar = -1;

//+------------------------------------------------------------------+
//| Signal history + forward performance tracking                    |
//+------------------------------------------------------------------+
struct SigRec
  {
   datetime t;
   int      bar;
   int      dir;
   int      mode;
   int      score;
   double   entry, sl, tp1, tp2;
   string   pattern;
   string   grade;
   string   reason;
  };
SigRec   g_sig[MAXSIG];
int      g_sigCount = 0;
datetime g_lastAlert = 0;

struct OpenTrade
  {
   bool   active;
   int    dir, mode, bar;
   double entry, sl, tp1;
  };
OpenTrade g_open[MAXOPEN];

int    g_nWin = 0, g_nLoss = 0;
double g_sumWinR = 0.0, g_sumLossR = 0.0;
int    g_streak = 0, g_worstStreak = 0;
int    g_modeWin[NMODELS], g_modeLoss[NMODELS];

//+------------------------------------------------------------------+
//| Dashboard snapshot                                               |
//+------------------------------------------------------------------+
int      g_dHtfReg = REG_RANGE, g_dMidReg = REG_RANGE, g_dLtfReg = REG_RANGE;
double   g_dHtfAdx = 0.0, g_dLtfAdx = 0.0;
bool     g_dCrt = false;
int      g_dCrtDir = 0;
double   g_dCrtHi = 0.0, g_dCrtLo = 0.0;
double   g_dPD = 0.5, g_dHtfPD = 0.5;
double   g_dAtr = 0.0, g_dDrift = 0.0;
double   g_dDueness = 0.0;
int      g_dBarsSinceSpike = 0;
bool     g_dHuntOpen = false, g_dFadeOpen = false;
string   g_dPhase = "SEARCHING";

string   g_rowTxt[MAXROWS];
color    g_rowCol[MAXROWS];
int      g_rowN = 0;

//+------------------------------------------------------------------+
//| Generic helpers                                                  |
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
   if(from < 0) from = 0;
   if(to > n - 1) to = n - 1;
   double v = -DBL_MAX;
   for(int k = from; k <= to; k++)
      if(a[k] > v) v = a[k];
   return (v == -DBL_MAX ? 0.0 : v);
  }

double LowestOf(const double &a[], int from, int to, const int n)
  {
   if(from < 0) from = 0;
   if(to > n - 1) to = n - 1;
   double v = DBL_MAX;
   for(int k = from; k <= to; k++)
      if(a[k] < v) v = a[k];
   return (v == DBL_MAX ? 0.0 : v);
  }

double Clamp(const double v, const double lo, const double hi)
  {
   return (v < lo ? lo : (v > hi ? hi : v));
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

string RegShort(const int r)
  {
   if(r == REG_BULL) return "UP";
   if(r == REG_BEAR) return "DN";
   return "--";
  }

color RegColor(const int r)
  {
   if(r == REG_BULL) return clrDodgerBlue;
   if(r == REG_BEAR) return clrOrangeRed;
   return clrGoldenrod;
  }

string ModeName(const int m)
  {
   switch(m)
     {
      case MODE_HUNT:  return "Spike Hunt";
      case MODE_FADE:  return "Spike Fade";
      case MODE_SWEEP: return "Liq Sweep";
      case MODE_BRT:   return "Break+Retest";
      case MODE_TPB:   return "Trend Pullback";
      case MODE_ASIA:  return "Asian Sweep";
      case MODE_NBO:   return "News Breakout";
      case MODE_NFD:   return "News Reversal";
     }
   return "CRT";
  }

string ModeShort(const int m)
  {
   switch(m)
     {
      case MODE_HUNT:  return "HUNT";
      case MODE_FADE:  return "FADE";
      case MODE_SWEEP: return "SWEEP";
      case MODE_BRT:   return "BRT";
      case MODE_TPB:   return "TPB";
      case MODE_ASIA:  return "ASIA";
      case MODE_NBO:   return "NEWS-BO";
      case MODE_NFD:   return "NEWS-REV";
     }
   return "CRT";
  }

string SessName(const int s)
  {
   if(s == SESS_ASIA)   return "ASIA";
   if(s == SESS_LONDON) return "LONDON";
   if(s == SESS_NY)     return "NEW YORK";
   return "OFF-SESSION";
  }

ENUM_TIMEFRAMES ResolveHTF(const ENUM_TIMEFRAMES chart)
  {
   switch(chart)
     {
      case PERIOD_M1: case PERIOD_M2: case PERIOD_M3:
      case PERIOD_M4: case PERIOD_M5:   return PERIOD_H1;
      case PERIOD_M6: case PERIOD_M10: case PERIOD_M12:
      case PERIOD_M15: case PERIOD_M20: case PERIOD_M30: return PERIOD_H4;
      case PERIOD_H1: case PERIOD_H2: case PERIOD_H3:
      case PERIOD_H4:   return PERIOD_D1;
      case PERIOD_H6: case PERIOD_H8: case PERIOD_H12:
      case PERIOD_D1:   return PERIOD_W1;
      case PERIOD_W1: case PERIOD_MN1: return PERIOD_MN1;
     }
   return PERIOD_D1;
  }

//--- anchor ladder used to shift the CRT anchor by trading style
int LadderIndex(const ENUM_TIMEFRAMES tf)
  {
   ENUM_TIMEFRAMES lad[7] = {PERIOD_M15, PERIOD_M30, PERIOD_H1, PERIOD_H4,
                             PERIOD_D1, PERIOD_W1, PERIOD_MN1};
   for(int i = 0; i < 7; i++)
      if(lad[i] == tf) return i;
   return 4;
  }

ENUM_TIMEFRAMES LadderAt(int i)
  {
   ENUM_TIMEFRAMES lad[7] = {PERIOD_M15, PERIOD_M30, PERIOD_H1, PERIOD_H4,
                             PERIOD_D1, PERIOD_W1, PERIOD_MN1};
   if(i < 0) i = 0;
   if(i > 6) i = 6;
   return lad[i];
  }

int AutoStyle(const ENUM_TIMEFRAMES chart)
  {
   int s = PeriodSeconds(chart);
   if(s <= 300)  return STY_SCALP;   // M1 .. M5
   if(s <= 3600) return STY_INTRA;   // M6 .. H1
   return STY_SWING;                 // H2 and above
  }

string StyleName(const int st)
  {
   if(st == STY_SCALP) return "SCALP";
   if(st == STY_SWING) return "SWING";
   return "INTRADAY";
  }

//--- scalping pulls the anchor one rung down, swing pushes it one rung up
ENUM_TIMEFRAMES ResolveHTFStyled(const ENUM_TIMEFRAMES chart, const int st)
  {
   ENUM_TIMEFRAMES base = ResolveHTF(chart);
   int idx = LadderIndex(base);
   if(st == STY_SCALP) idx--;
   if(st == STY_SWING) idx++;
   ENUM_TIMEFRAMES tf = LadderAt(idx);
   if(PeriodSeconds(tf) <= PeriodSeconds(chart))
      tf = base;
   return tf;
  }

ENUM_TIMEFRAMES PickLadder(const double secs)
  {
   ENUM_TIMEFRAMES lad[8] = {PERIOD_M1, PERIOD_M5, PERIOD_M15, PERIOD_M30,
                             PERIOD_H1, PERIOD_H4, PERIOD_D1, PERIOD_W1};
   ENUM_TIMEFRAMES best = PERIOD_H1;
   double bd = DBL_MAX;
   for(int i = 0; i < 8; i++)
     {
      double d = MathAbs(MathLog((double)PeriodSeconds(lad[i])) - MathLog(secs));
      if(d < bd) { bd = d; best = lad[i]; }
     }
   return best;
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

//+------------------------------------------------------------------+
//| Broker-agnostic symbol classification                            |
//+------------------------------------------------------------------+
string NormSymbol(const string raw)
  {
   string s = raw;
   StringToUpper(s);
   string out = "";
   int n = StringLen(s);
   for(int i = 0; i < n; i++)
     {
      ushort ch = StringGetCharacter(s, i);
      if((ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9'))
         out += ShortToString(ch);
     }
   return out;
  }

bool Has(const string hay, const string needle)
  {
   return (StringFind(hay, needle) >= 0);
  }

int FirstNumber(const string s)
  {
   int n = StringLen(s), val = 0;
   bool in = false;
   for(int i = 0; i < n; i++)
     {
      ushort ch = StringGetCharacter(s, i);
      if(ch >= '0' && ch <= '9')
        {
         in = true;
         val = val * 10 + (int)(ch - '0');
         if(val > 100000) break;
        }
      else
         if(in) break;
     }
   return val;
  }

int CountCcy(const string s)
  {
   string c[8] = {"USD", "EUR", "GBP", "JPY", "CHF", "AUD", "NZD", "CAD"};
   int hits = 0;
   for(int i = 0; i < 8; i++)
      if(Has(s, c[i])) hits++;
   return hits;
  }

//--- name-based classification; returns SC_AUTO when the name says nothing
int ClassifyByName(const string norm, int &spikeDir, int &nominal)
  {
   spikeDir = 0;
   nominal  = 0;

   if(Has(norm, "BOOM") || Has(norm, "GAINX"))
     {
      spikeDir = 1;
      nominal  = FirstNumber(norm);
      return SC_SPIKE_UP;
     }
   if(Has(norm, "CRASH") || Has(norm, "PAINX"))
     {
      spikeDir = -1;
      nominal  = FirstNumber(norm);
      return SC_SPIKE_DOWN;
     }
   if(Has(norm, "VOLATILITY") || Has(norm, "JUMP") || Has(norm, "STEPINDEX") ||
      Has(norm, "RANGEBREAK") || Has(norm, "DRIFTSWITCH"))
      return SC_VOL;
   if(Has(norm, "XAU") || Has(norm, "XAG") || Has(norm, "XPT") || Has(norm, "XPD") ||
      Has(norm, "GOLD") || Has(norm, "SILVER"))
      return SC_METAL;
   if(Has(norm, "BTC") || Has(norm, "ETH") || Has(norm, "XRP") || Has(norm, "LTC") ||
      Has(norm, "SOL") || Has(norm, "DOGE") || Has(norm, "ADA") || Has(norm, "BNB"))
      return SC_CRYPTO;
   if(Has(norm, "US30") || Has(norm, "DJ30") || Has(norm, "NAS") || Has(norm, "USTEC") ||
      Has(norm, "NDX")  || Has(norm, "SPX")  || Has(norm, "US500") || Has(norm, "GER") ||
      Has(norm, "DAX")  || Has(norm, "UK100") || Has(norm, "JP225") || Has(norm, "HK50") ||
      Has(norm, "AUS200") || Has(norm, "FRA40") || Has(norm, "EU50"))
      return SC_INDEX;
   if(CountCcy(norm) >= 2)
      return SC_FX;
   return SC_AUTO;
  }

//+------------------------------------------------------------------+
//| Robust drift baseline : median bar range over a window           |
//+------------------------------------------------------------------+
double MedianRange(const double &h[], const double &l[], const int i, const int win)
  {
   static double tmp[];
   int cnt = MathMin(win, i + 1);
   if(cnt < 5)
      return 0.0;
   if(ArraySize(tmp) != cnt)
      ArrayResize(tmp, cnt);
   for(int k = 0; k < cnt; k++)
      tmp[k] = h[i-k] - l[i-k];
   ArraySort(tmp);
   return tmp[cnt / 2];
  }

//+------------------------------------------------------------------+
//| Spike bar test                                                   |
//+------------------------------------------------------------------+
bool IsSpikeBar(const double &o[], const double &h[], const double &l[], const double &c[],
                const int i, const double driftRange, int &dir)
  {
   dir = 0;
   if(driftRange <= 0.0)
      return false;
   double rng = h[i] - l[i];
   if(rng < g_spikeMult * driftRange)
      return false;
   double upMove = h[i] - o[i];
   double dnMove = o[i] - l[i];
   dir = (upMove >= dnMove ? 1 : -1);
   return true;
  }

//+------------------------------------------------------------------+
//| Statistical spike profiling over history                         |
//+------------------------------------------------------------------+
void ProfileSymbol(const int rates_total, const double &o[], const double &h[],
                   const double &l[], const double &c[])
  {
   string norm = NormSymbol(_Symbol);
   int nameDir = 0, nominal = 0;
   int byName = ClassifyByName(norm, nameDir, nominal);

   g_nominal = nominal;

   if(InpForceClass != SC_AUTO)
     {
      g_symClass = InpForceClass;
      g_spikeDir = (g_symClass == SC_SPIKE_UP ? 1 : (g_symClass == SC_SPIKE_DOWN ? -1 : 0));
      g_classHow = "forced";
     }
   else
      if(byName != SC_AUTO)
        {
         g_symClass = byName;
         g_spikeDir = nameDir;
         g_classHow = "name";
        }
      else
        {
         g_symClass = SC_AUTO;
         g_spikeDir = 0;
         g_classHow = "unknown";
        }

   if(InpForceSpikeDir == SPD_UP)        { g_spikeDir = 1;  g_classHow = "forced"; }
   else if(InpForceSpikeDir == SPD_DOWN) { g_spikeDir = -1; g_classHow = "forced"; }

   //--- statistical fallback / verification
   if(InpStatDetect && InpForceSpikeDir == SPD_AUTO && g_spikeDir == 0)
     {
      int scan = MathMin(rates_total - 2, 3000);
      int from = rates_total - 1 - scan;
      if(from < InpDriftWin + 2) from = InpDriftWin + 2;

      int upS = 0, dnS = 0;
      for(int i = from; i <= rates_total - 2; i++)
        {
         double dr = MedianRange(h, l, i - 1, InpDriftWin);
         int sd = 0;
         if(IsSpikeBar(o, h, l, c, i, dr, sd))
           {
            if(sd > 0) upS++;
            else       dnS++;
           }
        }
      if(upS >= 5 && upS >= 3 * MathMax(1, dnS))
        {
         g_spikeDir = 1;
         g_symClass = SC_SPIKE_UP;
         g_classHow = StringFormat("stats %d up / %d dn", upS, dnS);
        }
      else
         if(dnS >= 5 && dnS >= 3 * MathMax(1, upS))
           {
            g_spikeDir = -1;
            g_symClass = SC_SPIKE_DOWN;
            g_classHow = StringFormat("stats %d dn / %d up", dnS, upS);
           }
     }

   if(g_symClass == SC_AUTO)
      g_symClass = SC_FX;
  }

string ClassName(const int c)
  {
   switch(c)
     {
      case SC_FX:         return "FOREX";
      case SC_METAL:      return "METAL";
      case SC_INDEX:      return "INDEX";
      case SC_CRYPTO:     return "CRYPTO";
      case SC_VOL:        return "SYNTHETIC";
      case SC_SPIKE_UP:   return "SPIKE-UP (Boom/GainX)";
      case SC_SPIKE_DOWN: return "SPIKE-DOWN (Crash/PainX)";
     }
   return "AUTO";
  }

//+------------------------------------------------------------------+
//| Auto-tune the working thresholds to the detected class           |
//+------------------------------------------------------------------+
void AutoTune()
  {
   g_dispATR    = InpDispATR;
   g_maxRiskATR = InpMaxRiskATR;
   g_adxTrend   = InpAdxTrend;
   g_spikeMult  = InpSpikeMult;
   g_minSepATR  = InpMinSepATR;
   g_useSessions = InpUseSessions;

   if(!InpAutoTune)
      return;

   switch(g_symClass)
     {
      case SC_INDEX:
         g_dispATR = 1.40; g_maxRiskATR = 4.5; g_adxTrend = 22.0;
         break;
      case SC_CRYPTO:
         g_dispATR = 1.50; g_maxRiskATR = 5.0; g_adxTrend = 18.0; g_useSessions = false;
         break;
      case SC_METAL:
         g_dispATR = 1.30; g_maxRiskATR = 4.5; g_adxTrend = 20.0;
         break;
      case SC_VOL:
         g_dispATR = 1.40; g_maxRiskATR = 5.0; g_adxTrend = 18.0; g_useSessions = false;
         break;
      case SC_SPIKE_UP:
      case SC_SPIKE_DOWN:
         g_dispATR = 1.60; g_maxRiskATR = 6.0; g_adxTrend = 18.0;
         g_minSepATR = 0.18; g_useSessions = false;
         break;
     }
  }

//+------------------------------------------------------------------+
//| Trading style : targets, patience and cost tolerance             |
//| Runs after AutoTune - it may tighten what AutoTune set.          |
//+------------------------------------------------------------------+
void ApplyStyle()
  {
   g_rr1       = InpRR1;
   g_rr2       = InpRR2;
   g_slBuf     = InpSlBufATR;
   g_expiry    = InpSetupExpiry;
   g_cooldown  = InpCooldownBars;
   g_minScore  = InpMinScore;
   g_liqTP     = InpUseLiquidityTP;
   g_minTpSprdX = 4.0;

   if(InpStyleTune)
     {
      switch(g_style)
        {
         case STY_SCALP:
            // fast in, fast out - costs dominate, so demand a wide TP/spread ratio
            g_rr1 = 1.2; g_rr2 = 2.0;
            g_slBuf = 0.20; g_expiry = 8; g_cooldown = 2;
            g_liqTP = false;
            g_minTpSprdX = 6.0;
            g_minScore = MathMax(InpMinScore, 68);
            g_dispATR = MathMin(g_dispATR, 1.00);
            break;

         case STY_INTRA:
            g_rr1 = 2.0; g_rr2 = 3.5;
            g_slBuf = 0.30; g_expiry = 24; g_cooldown = 3;
            g_liqTP = true;
            g_minTpSprdX = 4.0;
            break;

         case STY_SWING:
            // wide stops, long patience, targets that justify holding
            g_rr1 = 2.5; g_rr2 = 5.0;
            g_slBuf = 0.50; g_expiry = 60; g_cooldown = 6;
            g_liqTP = true;
            g_minTpSprdX = 3.0;
            g_maxRiskATR = MathMax(g_maxRiskATR, 5.0);
            g_dispATR = MathMax(g_dispATR, 1.30);
            break;
        }
     }

   if(InpMinTpSpreadX > 0.0)
      g_minTpSprdX = InpMinTpSpreadX;
  }

//--- current spread in price terms (historical spread is not available,
//--- so the viability gate is evaluated with the live spread)
double SpreadPrice()
  {
   double sp = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) *
               SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(sp <= 0.0)
      sp = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return MathMax(sp, 0.0);
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
   bool trending = (adx >= g_adxTrend) && (sep >= g_minSepATR * atr);
   if(!trending)
      return REG_RANGE;
   if(emaF > emaS && price > emaS) return REG_BULL;
   if(emaF < emaS && price < emaS) return REG_BEAR;
   return REG_RANGE;
  }

//+------------------------------------------------------------------+
//| Candlestick patterns                                             |
//+------------------------------------------------------------------+
string BullishPattern(const double &o[], const double &h[], const double &l[],
                      const double &c[], const int i, const double atr)
  {
   if(i < 3 || atr <= 0.0) return "";
   double body = MathAbs(c[i] - o[i]);
   double rng  = h[i] - l[i];
   if(rng <= 0.0) return "";
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
   if(i < 3 || atr <= 0.0) return "";
   double body = MathAbs(c[i] - o[i]);
   double rng  = h[i] - l[i];
   if(rng <= 0.0) return "";
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

int PatternStrength(const string p)
  {
   if(p == "Bull Engulf"  || p == "Bear Engulf")   return 10;
   if(p == "Morning Star" || p == "Evening Star")  return 10;
   if(p == "Hammer"       || p == "Shooting Star") return 8;
   if(p == "Piercing"     || p == "Dark Cloud")    return 8;
   if(p == "Tweezer Btm"  || p == "Tweezer Top")   return 6;
   if(p == "IB Break Up"  || p == "IB Break Dn")   return 6;
   if(p == "Rejection")                            return 5;
   return 2;
  }

//+------------------------------------------------------------------+
//| Sessions                                                         |
//+------------------------------------------------------------------+
int GmtHour(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return (dt.hour - InpGmtOffset + 48) % 24;
  }

int GmtDay(const datetime t)
  {
   return (int)((t - (datetime)(InpGmtOffset * 3600)) / 86400);
  }

bool InKillzone(const datetime t)
  {
   if(!g_useSessions)
      return true;
   int g = GmtHour(t);
   if(InpAsia    && g >= InpAsiaStart && g < InpAsiaEnd) return true;
   if(InpLondon  && g >= InpLonStart  && g < InpLonEnd)  return true;
   if(InpNewYork && g >= InpNYStart   && g < InpNYEnd)   return true;
   return false;
  }

int SessionOf(const datetime t)
  {
   int g = GmtHour(t);
   if(g >= InpAsiaStart && g < InpAsiaEnd) return SESS_ASIA;
   if(g >= InpLonStart  && g < InpLonEnd)  return SESS_LONDON;
   if(g >= InpNYStart   && g < InpNYEnd)   return SESS_NY;
   return SESS_OFF;
  }

//--- Asian range, rebuilt each GMT day as the loop walks forward
int    g_asiaDay = -1;
double g_asiaHi  = 0.0, g_asiaLo = 0.0;
bool   g_asiaSet = false;
bool   g_asiaSweptHi = false, g_asiaSweptLo = false;

void UpdateAsianRange(const datetime t, const double hi, const double lo)
  {
   int day = GmtDay(t);
   if(day != g_asiaDay)
     {
      g_asiaDay = day;
      g_asiaHi = 0.0; g_asiaLo = 0.0; g_asiaSet = false;
      g_asiaSweptHi = false; g_asiaSweptLo = false;
     }
   int g = GmtHour(t);
   if(g >= InpAsiaStart && g < InpAsiaEnd)
     {
      if(!g_asiaSet) { g_asiaHi = hi; g_asiaLo = lo; g_asiaSet = true; }
      else           { g_asiaHi = MathMax(g_asiaHi, hi); g_asiaLo = MathMin(g_asiaLo, lo); }
     }
  }

//+------------------------------------------------------------------+
//| News filter - MT5 economic calendar                              |
//| Events are fetched once per recalculation, not once per bar.     |
//+------------------------------------------------------------------+
datetime g_newsTimes[];
int      g_newsCount   = 0;
bool     g_newsOk      = false;   // calendar reachable and relevant to this symbol
string   g_newsCcy     = "";

void CollectNewsFor(const string ccy, datetime from, datetime to)
  {
   if(ccy == "")
      return;

   MqlCalendarEvent events[];
   int ne = CalendarEventByCurrency(ccy, events);
   if(ne <= 0)
      return;

   MqlCalendarValue values[];
   int nv = CalendarValueHistory(values, from, to, NULL, ccy);
   if(nv <= 0)
      return;

   for(int v = 0; v < nv; v++)
     {
      for(int e = 0; e < ne; e++)
        {
         if(events[e].id != values[v].event_id)
            continue;
         bool keep = (events[e].importance == CALENDAR_IMPORTANCE_HIGH) ||
                     (!InpNewsHighOnly && events[e].importance == CALENDAR_IMPORTANCE_MODERATE);
         if(keep)
           {
            int n = ArraySize(g_newsTimes);
            ArrayResize(g_newsTimes, n + 1);
            g_newsTimes[n] = values[v].time;
           }
         break;
        }
     }
  }

//--- every currency this symbol is exposed to, however the broker names it.
//--- Symbol properties first, then the name, then the index home currency,
//--- then anything the user added. Covers majors, crosses, exotics and CFDs.
void AddCcy(string &list[], int &n, const string c)
  {
   if(c == "" || StringLen(c) != 3)
      return;
   for(int k = 0; k < n; k++)
      if(list[k] == c) return;
   ArrayResize(list, n + 1);
   list[n] = c;
   n++;
  }

int ResolveCurrencies(string &list[])
  {
   int n = 0;
   ArrayResize(list, 0);

   AddCcy(list, n, SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE));
   AddCcy(list, n, SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT));
   AddCcy(list, n, SymbolInfoString(_Symbol, SYMBOL_CURRENCY_MARGIN));

   //--- some brokers leave those blank or wrong on CFDs, so read the name too
   string norm = NormSymbol(_Symbol);
   string known[22] = {"USD","EUR","GBP","JPY","CHF","AUD","NZD","CAD",
                       "SEK","NOK","DKK","PLN","CZK","HUF","TRY","ZAR",
                       "MXN","SGD","HKD","CNH","ILS","THB"};
   for(int k = 0; k < 22; k++)
      if(Has(norm, known[k]))
         AddCcy(list, n, known[k]);

   //--- an index trades on its home economy's calendar
   if(Has(norm, "US30") || Has(norm, "DJ30") || Has(norm, "NAS") || Has(norm, "USTEC") ||
      Has(norm, "NDX")  || Has(norm, "SPX")  || Has(norm, "US500"))
      AddCcy(list, n, "USD");
   if(Has(norm, "GER") || Has(norm, "DAX") || Has(norm, "EU50") || Has(norm, "FRA40"))
      AddCcy(list, n, "EUR");
   if(Has(norm, "UK100") || Has(norm, "FTSE")) AddCcy(list, n, "GBP");
   if(Has(norm, "JP225") || Has(norm, "NIKKEI")) AddCcy(list, n, "JPY");
   if(Has(norm, "HK50"))   AddCcy(list, n, "HKD");
   if(Has(norm, "AUS200")) AddCcy(list, n, "AUD");
   //--- metals and crypto are priced in, and react to, the dollar calendar
   if(g_symClass == SC_METAL || g_symClass == SC_CRYPTO)
      AddCcy(list, n, "USD");

   //--- user additions
   if(InpExtraNewsCcy != "")
     {
      string parts[];
      int np = StringSplit(InpExtraNewsCcy, ',', parts);
      for(int k = 0; k < np; k++)
        {
         string c = parts[k];
         StringTrimLeft(c);
         StringTrimRight(c);
         StringToUpper(c);
         AddCcy(list, n, c);
        }
     }
   return n;
  }

void LoadNews(const datetime from, const datetime to)
  {
   ArrayResize(g_newsTimes, 0);
   g_newsCount = 0;
   g_newsOk = false;
   g_newsCcy = "";

   if(!InpUseNews)
      return;
   //--- synthetics have no macro calendar; their base currency would be misleading
   if(g_symClass == SC_SPIKE_UP || g_symClass == SC_SPIKE_DOWN || g_symClass == SC_VOL)
      return;

   string ccy[];
   int n = ResolveCurrencies(ccy);
   for(int k = 0; k < n; k++)
     {
      CollectNewsFor(ccy[k], from, to);
      g_newsCcy += (g_newsCcy == "" ? "" : "/") + ccy[k];
     }

   g_newsCount = ArraySize(g_newsTimes);
   if(g_newsCount > 0)
     {
      ArraySort(g_newsTimes);
      g_newsOk = true;
     }
  }

//+------------------------------------------------------------------+
//| News phase tracking - pre-range, release, trade window           |
//+------------------------------------------------------------------+
int    g_nEvt      = -1;      // index of the event currently being tracked
double g_preHi     = 0.0, g_preLo = 0.0;
bool   g_preSet    = false;
double g_postHi    = 0.0, g_postLo = 0.0;
bool   g_postSet   = false;
bool   g_nboDone   = false, g_nfdDone = false;

//--- index of the event whose pre-range / trade window contains t
int NewsIndexFor(const datetime t)
  {
   if(g_newsCount <= 0)
      return -1;
   long pre  = (long)InpNewsPreRange * 60;
   long post = (long)InpNewsWindow * 60;
   for(int k = 0; k < g_newsCount; k++)
     {
      long d = (long)t - (long)g_newsTimes[k];
      if(d >= -pre && d <= post)
         return k;
     }
   return -1;
  }

void UpdateNewsPhase(const datetime t, const double hi, const double lo)
  {
   int idx = NewsIndexFor(t);
   if(idx != g_nEvt)
     {
      g_nEvt = idx;
      g_preSet = false; g_postSet = false;
      g_preHi = 0.0; g_preLo = 0.0; g_postHi = 0.0; g_postLo = 0.0;
      g_nboDone = false; g_nfdDone = false;
     }
   if(idx < 0)
      return;

   datetime T = g_newsTimes[idx];
   if(t < T)
     {
      if(!g_preSet) { g_preHi = hi; g_preLo = lo; g_preSet = true; }
      else          { g_preHi = MathMax(g_preHi, hi); g_preLo = MathMin(g_preLo, lo); }
     }
   else
     {
      if(!g_postSet) { g_postHi = hi; g_postLo = lo; g_postSet = true; }
      else           { g_postHi = MathMax(g_postHi, hi); g_postLo = MathMin(g_postLo, lo); }
     }
  }

//--- true while the news models are allowed to fire
bool InNewsTradeWindow(const datetime t)
  {
   if(g_nEvt < 0)
      return false;
   long d = (long)t - (long)g_newsTimes[g_nEvt];
   return (d >= (long)InpNewsDelay * 60 && d <= (long)InpNewsWindow * 60);
  }

bool NewsBlackout(const datetime t)
  {
   if(!InpUseNews || g_newsCount <= 0)
      return false;
   long before = (long)InpNewsBefore * 60;
   long after  = (long)InpNewsAfter  * 60;
   for(int k = 0; k < g_newsCount; k++)
     {
      long d = (long)g_newsTimes[k] - (long)t;
      if(d >= 0 && d <= before) return true;   // release is imminent
      if(d < 0 && -d <= after)  return true;   // release just happened
     }
   return false;
  }

//--- minutes to the next scheduled release (-1 when none / unavailable)
int MinutesToNews(const datetime t)
  {
   if(g_newsCount <= 0)
      return -1;
   for(int k = 0; k < g_newsCount; k++)
     {
      if(g_newsTimes[k] >= t)
         return (int)(((long)g_newsTimes[k] - (long)t) / 60);
     }
   return -1;
  }

//+------------------------------------------------------------------+
//| Reason stack - why this trade is worth taking                    |
//+------------------------------------------------------------------+
string BuildReason(const int model, const int bias, const int mtfAgree, const double pd,
                   const string zone, const string pat, const int sess,
                   const double rr, const string extra)
  {
   string r = ModeShort(model);
   r += " | " + TfName(g_htf) + " " + RegName(bias);
   if(mtfAgree >= 0)
      r += StringFormat(" | %d/3 MTF", mtfAgree);
   if(pd >= 0.0)
      r += StringFormat(" | %s %.0f%%", (pd < 0.5 ? "discount" : "premium"), pd * 100.0);
   if(sess != SESS_OFF)
      r += " | " + SessName(sess);
   if(extra != "")
      r += " | " + extra;
   if(zone != "")
      r += " | " + zone;
   if(pat != "")
      r += " | " + pat;
   r += StringFormat(" | %.1fR", rr);
   return r;
  }

//+------------------------------------------------------------------+
//| CRT detection on the anchor timeframe                            |
//+------------------------------------------------------------------+
bool FindCRT(const int hs, const int htfBias, CRTInfo &out)
  {
   out.found = false; out.dir = 0; out.hi = 0.0; out.lo = 0.0;
   out.raidTime = 0; out.raidShift = -1; out.qual = 0.0;

   int nH = ArraySize(g_hr);
   if(nH <= 0 || hs < 0)
      return false;

   int maxJ = hs + MathMax(1, InpCrtValidBars);

   for(int j = hs + 1; j <= maxJ; j++)
     {
      int a = j + 1;
      if(a + InpSRLookback >= nH) break;
      if(a >= ArraySize(g_hAtrv)) break;

      double aHi = g_hr[a].high, aLo = g_hr[a].low;
      double aRng = aHi - aLo;
      if(aRng <= 0.0) continue;

      double atrH = g_hAtrv[a];
      if(atrH <= 0.0) continue;
      double tol  = InpKeyLevelTolATR * atrH;
      double back = Clamp(InpMinCloseBackPct, 0.0, 0.5) * aRng;

      double rHi = g_hr[j].high, rLo = g_hr[j].low, rCl = g_hr[j].close;

      bool bull = (rLo < aLo) && (rCl > aLo + back) && (rCl < aHi);
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
         if(htfBias == REG_BULL)      bear = false;
         else if(htfBias == REG_BEAR) bull = false;
         else                         { bull = false; bear = false; }
        }

      if(!bull && !bear) continue;

      double sweep  = (bull ? (aLo - rLo) : (rHi - aHi)) / atrH;
      double reclaim = (bull ? (rCl - aLo) : (aHi - rCl)) / aRng;

      out.found     = true;
      out.dir       = (bull ? 1 : -1);
      out.hi        = aHi;
      out.lo        = aLo;
      out.raidTime  = g_hr[j].time;
      out.raidShift = j;
      out.qual      = Clamp(0.5 * Clamp(sweep / 0.8, 0, 1) + 0.5 * Clamp(reclaim / 0.5, 0, 1), 0, 1);
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Setup state                                                      |
//+------------------------------------------------------------------+
void ResetSetup()
  {
   g_stRaid = 0; g_stDir = 0; g_stCrtHi = 0.0; g_stCrtLo = 0.0; g_stCrtQual = 0.0;
   g_stMss = false; g_stMssLvl = 0.0; g_stMssBar = -1; g_stDisp = 0.0;
   g_stZone = false; g_stZoneHi = 0.0; g_stZoneLo = 0.0; g_stZoneKind = "";
  }

void ResetAll()
  {
   ResetSetup();
   for(int m = 0; m < NMODELS; m++)
     {
      g_lastSigBarMode[m] = -1000000;
      g_modeWin[m] = 0;
      g_modeLoss[m] = 0;
     }
   g_swHigh = 0.0; g_swLow = 0.0; g_swHighBar = -1; g_swLowBar = -1;
   g_sigCount = 0;

   g_brtDir = 0; g_brtLevel = 0.0; g_brtBar = -1;
   g_nEvt = -1; g_preSet = false; g_postSet = false;
   g_preHi = 0.0; g_preLo = 0.0; g_postHi = 0.0; g_postLo = 0.0;
   g_nboDone = false; g_nfdDone = false;
   g_asiaDay = -1; g_asiaHi = 0.0; g_asiaLo = 0.0; g_asiaSet = false;
   g_asiaSweptHi = false; g_asiaSweptLo = false;
   g_lastSpikeBar = -1; g_lastSpikeDir = 0;
   g_lastSpikeHigh = 0.0; g_lastSpikeLow = 0.0; g_lastSpikeRange = 0.0;
   g_preSpikeClose = 0.0;
   g_spikeSizeN = 0; g_spikeGapN = 0; g_spikeSeen = 0;
   g_avgGap = 0.0; g_medSpike = 0.0; g_gapConsistency = 0.0;

   for(int k = 0; k < MAXOPEN; k++)
      g_open[k].active = false;
   g_nWin = 0; g_nLoss = 0; g_sumWinR = 0.0; g_sumLossR = 0.0;
   g_streak = 0; g_worstStreak = 0;
  }

//+------------------------------------------------------------------+
//| Retest zones                                                     |
//+------------------------------------------------------------------+
bool BuildBullZone(const double &o[], const double &h[], const double &l[],
                   const double &c[], const int i, const double atr,
                   double &zHi, double &zLo, string &kind)
  {
   int lo = MathMax(2, i - InpLegLookback);
   if(InpZoneMode != ZM_OB_ONLY)
     {
      for(int k = i; k >= lo; k--)
        {
         if(k - 2 < 0) break;
         if(l[k] > h[k-2])
           {
            zHi = l[k]; zLo = h[k-2];
            if(zHi < c[i] && zHi > zLo) { kind = "FVG"; return true; }
           }
        }
      if(InpZoneMode == ZM_FVG_ONLY) return false;
     }
   for(int k = i - 1; k >= lo; k--)
     {
      if(c[k] < o[k])
        {
         zLo = l[k]; zHi = MathMax(o[k], c[k]);
         if(zHi < c[i] && zHi > zLo) { kind = "Order Block"; return true; }
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
                   const double &c[], const int i, const double atr,
                   double &zHi, double &zLo, string &kind)
  {
   int lo = MathMax(2, i - InpLegLookback);
   if(InpZoneMode != ZM_OB_ONLY)
     {
      for(int k = i; k >= lo; k--)
        {
         if(k - 2 < 0) break;
         if(h[k] < l[k-2])
           {
            zLo = h[k]; zHi = l[k-2];
            if(zLo > c[i] && zHi > zLo) { kind = "FVG"; return true; }
           }
        }
      if(InpZoneMode == ZM_FVG_ONLY) return false;
     }
   for(int k = i - 1; k >= lo; k--)
     {
      if(c[k] > o[k])
        {
         zHi = h[k]; zLo = MathMin(o[k], c[k]);
         if(zLo > c[i] && zHi > zLo) { kind = "Order Block"; return true; }
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
//| Confluence scoring                                               |
//+------------------------------------------------------------------+
string GradeOf(const int score)
  {
   if(score >= InpPremiumScore) return "A+";
   if(score >= 73) return "A";
   if(score >= 62) return "B";
   return "C";
  }

int ScoreCRT(const bool biasAligned, const int mtfAgree, const double crtQual,
             const double pdDepth, const double dispMult, const string zoneKind,
             const string pattern, const bool emaAligned, const double adx,
             const bool inSession)
  {
   double s = 0.0;
   s += (biasAligned ? 14.0 : 0.0);
   s += 12.0 * Clamp((double)mtfAgree / 3.0, 0, 1);
   s += 14.0 * Clamp(crtQual, 0, 1);
   s += 12.0 * Clamp(pdDepth, 0, 1);
   s += 12.0 * Clamp((dispMult - g_dispATR) / 1.2, 0, 1);
   s += (zoneKind == "FVG" ? 10.0 : (zoneKind == "Order Block" ? 7.0 : 4.0));
   s += (double)PatternStrength(pattern);
   s += (emaAligned ? 5.0 : 0.0) + 5.0 * Clamp((adx - g_adxTrend) / 15.0, 0, 1);
   s += (inSession ? 6.0 : 0.0);
   return (int)MathRound(Clamp(s, 0, 100));
  }

int ScoreHunt(const double dueness, const double chanPos, const bool crtOk,
              const string pattern, const double rrToTp1, const double spikeVsDrift)
  {
   double s = 0.0;
   s += 24.0 * Clamp(dueness / 1.5, 0, 1);
   s += 18.0 * Clamp(1.0 - chanPos / MathMax(0.05, InpHuntMaxPos), 0, 1);
   s += (crtOk ? 16.0 : 0.0);
   s += 12.0 * Clamp(g_gapConsistency, 0, 1);
   s += (double)PatternStrength(pattern);
   s += 10.0 * Clamp(rrToTp1 / 3.0, 0, 1);
   s += 10.0 * Clamp(spikeVsDrift / 8.0, 0, 1);
   return (int)MathRound(Clamp(s, 0, 100));
  }

int ScoreFade(const double spikeVsMedian, const double exhaust, const int htfReg,
              const int driftReg, const double dueness, const string pattern,
              const double pdPos, const double rrToTp1)
  {
   double s = 0.0;
   s += 18.0 * Clamp(spikeVsMedian, 0, 1);
   s += 20.0 * Clamp(exhaust / 0.60, 0, 1);
   s += (htfReg == driftReg ? 18.0 : (htfReg == REG_RANGE ? 8.0 : 0.0));
   s += 16.0 * Clamp(1.0 - dueness / MathMax(0.05, InpFadeBlockDueness), 0, 1);
   s += (double)PatternStrength(pattern) * 1.2;
   s += 8.0 * Clamp(pdPos, 0, 1);
   s += 8.0 * Clamp(rrToTp1 / 2.0, 0, 1);
   return (int)MathRound(Clamp(s, 0, 100));
  }

//--- shared scorer for the pure price-action models
int ScorePA(const bool biasAligned, const int mtfAgree, const double pdDepth,
            const double structQual, const string pattern, const bool emaAligned,
            const double adx, const bool inSess, const double rr, const bool edgeBonus)
  {
   double s = 0.0;
   s += (biasAligned ? 16.0 : 0.0);
   s += 12.0 * Clamp((double)mtfAgree / 3.0, 0, 1);
   s += 12.0 * Clamp(pdDepth, 0, 1);
   s += 14.0 * Clamp(structQual, 0, 1);
   s += (double)PatternStrength(pattern);
   s += (emaAligned ? 5.0 : 0.0) + 5.0 * Clamp((adx - g_adxTrend) / 15.0, 0, 1);
   s += (inSess ? 8.0 : 0.0);
   s += 10.0 * Clamp(rr / 3.0, 0, 1);
   s += (edgeBonus ? 8.0 : 0.0);
   return (int)MathRound(Clamp(s, 0, 100));
  }

//+------------------------------------------------------------------+
//| Signal storage + forward performance tracking                    |
//+------------------------------------------------------------------+
void PushSignal(const datetime t, const int bar, const int dir, const int mode,
                const int score, const double entry, const double sl,
                const double tp1, const double tp2, const string pat, const string reason)
  {
   int idx = g_sigCount;
   if(g_sigCount >= MAXSIG)
     {
      for(int k = 1; k < MAXSIG; k++)
         g_sig[k-1] = g_sig[k];
      idx = MAXSIG - 1;
     }
   else
      g_sigCount++;

   g_sig[idx].t = t;
   g_sig[idx].bar = bar;
   g_sig[idx].dir = dir;
   g_sig[idx].mode = mode;
   g_sig[idx].score = score;
   g_sig[idx].entry = entry;
   g_sig[idx].sl = sl;
   g_sig[idx].tp1 = tp1;
   g_sig[idx].tp2 = tp2;
   g_sig[idx].pattern = pat;
   g_sig[idx].grade = GradeOf(score);
   g_sig[idx].reason = reason;

   if(!InpTrackStats)
      return;

   for(int k = 0; k < MAXOPEN; k++)
     {
      if(g_open[k].active) continue;
      g_open[k].active = true;
      g_open[k].dir = dir;
      g_open[k].mode = mode;
      g_open[k].bar = bar;
      g_open[k].entry = entry;
      g_open[k].sl = sl;
      g_open[k].tp1 = tp1;
      return;
     }
  }

void SettleTrade(const int mode, const bool win, const double r)
  {
   if(win)
     {
      g_nWin++;
      g_sumWinR += r;
      g_modeWin[mode]++;
      g_streak = (g_streak > 0 ? g_streak + 1 : 1);
     }
   else
     {
      g_nLoss++;
      g_sumLossR += 1.0;
      g_modeLoss[mode]++;
      g_streak = (g_streak < 0 ? g_streak - 1 : -1);
      if(g_streak < g_worstStreak) g_worstStreak = g_streak;
     }
  }

//--- resolve every open forward-test on the current bar
void UpdateOpenTrades(const double &h[], const double &l[], const int i)
  {
   if(!InpTrackStats)
      return;
   for(int k = 0; k < MAXOPEN; k++)
     {
      if(!g_open[k].active || g_open[k].bar >= i)
         continue;
      double risk = MathAbs(g_open[k].entry - g_open[k].sl);
      if(risk <= 0.0) { g_open[k].active = false; continue; }

      bool hitSL = false, hitTP = false;
      if(g_open[k].dir > 0)
        {
         hitSL = (l[i] <= g_open[k].sl);
         hitTP = (h[i] >= g_open[k].tp1);
        }
      else
        {
         hitSL = (h[i] >= g_open[k].sl);
         hitTP = (l[i] <= g_open[k].tp1);
        }

      // conservative: when a single bar covers both levels, count it as a loss
      if(hitSL)
        {
         SettleTrade(g_open[k].mode, false, -1.0);
         g_open[k].active = false;
        }
      else
         if(hitTP)
           {
            SettleTrade(g_open[k].mode, true, MathAbs(g_open[k].tp1 - g_open[k].entry) / risk);
            g_open[k].active = false;
           }
     }
  }

//+------------------------------------------------------------------+
//| Lot size for the configured account risk                         |
//+------------------------------------------------------------------+
double LotForRisk(const double slDist)
  {
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal <= 0.0 || slDist <= 0.0) return 0.0;
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tv <= 0.0 || ts <= 0.0) return 0.0;
   double lossPerLot = slDist / ts * tv;
   if(lossPerLot <= 0.0) return 0.0;
   double lots = (bal * InpAccountRiskPct / 100.0) / lossPerLot;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step > 0.0) lots = MathFloor(lots / step) * step;
   if(mn > 0.0) lots = MathMax(mn, lots);
   if(mx > 0.0) lots = MathMin(mx, lots);
   return lots;
  }

//+------------------------------------------------------------------+
//| Object helpers                                                   |
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
              const string txt, const color col, const int size, const ENUM_ANCHOR_POINT anch)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
   ObjectSetInteger(0, name, OBJPROP_TIME, 0, t);
   ObjectSetDouble(0, name, OBJPROP_PRICE, 0, price);
   ObjectSetString(0, name, OBJPROP_TEXT, txt);
   ObjectSetString(0, name, OBJPROP_FONT, InpFontName);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anch);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void DrawSignalLevels(const bool force)
  {
   static int drawn = -1;
   if(!force && drawn == g_sigCount)
      return;
   drawn = g_sigCount;

   ObjectsDeleteAll(0, PREFIX + "lvl_");
   ObjectsDeleteAll(0, PREFIX + "grd_");
   if(g_sigCount == 0)
      return;

   int span = MathMax(4, InpProjectBars) * PeriodSeconds(_Period);

   if(InpShowSLTP)
     {
      int show = (InpShowLastSignals < g_sigCount ? InpShowLastSignals : g_sigCount);
      for(int s = g_sigCount - show; s < g_sigCount; s++)
        {
         datetime t1 = g_sig[s].t, t2 = t1 + span;
         string id = PREFIX + "lvl_" + IntegerToString(s) + "_";
         MakeSeg(id + "sl",  t1, t2, g_sig[s].sl,  InpSLColor,  STYLE_DOT,  1);
         MakeSeg(id + "tp1", t1, t2, g_sig[s].tp1, InpTP1Color, STYLE_DOT,  1);
         MakeSeg(id + "tp2", t1, t2, g_sig[s].tp2, InpTP2Color, STYLE_DASH, 1);
         MakeText(id + "tsl",  t2, g_sig[s].sl,  " SL "  + DoubleToString(g_sig[s].sl,  _Digits), InpSLColor,  InpFontSize, ANCHOR_LEFT);
         MakeText(id + "ttp1", t2, g_sig[s].tp1, " TP1 " + DoubleToString(g_sig[s].tp1, _Digits), InpTP1Color, InpFontSize, ANCHOR_LEFT);
         MakeText(id + "ttp2", t2, g_sig[s].tp2, " TP2 " + DoubleToString(g_sig[s].tp2, _Digits), InpTP2Color, InpFontSize, ANCHOR_LEFT);
        }
     }

   if(InpShowScore)
     {
      int showG = (InpShowLastGrades < g_sigCount ? InpShowLastGrades : g_sigCount);
      for(int s = g_sigCount - showG; s < g_sigCount; s++)
        {
         string id = PREFIX + "grd_" + IntegerToString(s);
         double at = (g_sig[s].dir > 0 ? g_sig[s].sl : g_sig[s].tp2);
         color  cc = (g_sig[s].dir > 0 ? clrDodgerBlue : clrOrangeRed);
         string tx = g_sig[s].grade + " " + IntegerToString(g_sig[s].score) + " " + ModeShort(g_sig[s].mode);
         MakeText(id, g_sig[s].t, at, tx, cc, MathMax(6, InpFontSize - 1),
                  (g_sig[s].dir > 0 ? ANCHOR_UPPER : ANCHOR_LOWER));
        }
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
void AddRow(const string txt, const color col)
  {
   if(g_rowN >= MAXROWS) return;
   g_rowTxt[g_rowN] = txt;
   g_rowCol[g_rowN] = col;
   g_rowN++;
  }

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

//--- how far price has run from the last signal, and whether it is still takeable
bool FreshnessVerdict(string &verdict, color &col, double &chasedR, int &ageBars)
  {
   verdict = "no signal yet";
   col = clrSilver;
   chasedR = 0.0;
   ageBars = -1;
   if(g_sigCount <= 0)
      return false;

   SigRec s = g_sig[g_sigCount-1];
   double risk = MathAbs(s.entry - s.sl);
   if(risk <= 0.0)
      return false;

   double px = (s.dir > 0 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                : SymbolInfoDouble(_Symbol, SYMBOL_BID));
   if(px <= 0.0) px = s.entry;

   //--- positive = price has moved away in the trade direction (chasing costs you)
   chasedR = (s.dir > 0 ? (px - s.entry) : (s.entry - px)) / risk;
   ageBars = (int)((TimeCurrent() - s.t) / MathMax(1, PeriodSeconds(_Period)));

   if(!InpUseFreshness)
     {
      verdict = "freshness off";
      col = clrSilver;
      return true;
     }
   if(ageBars > InpSignalTTL)
     {
      verdict = StringFormat("EXPIRED  (%d bars old)", ageBars);
      col = clrOrangeRed;
     }
   else if(chasedR > InpMaxChaseR)
     {
      verdict = StringFormat("TOO LATE  (chased %.2fR)", chasedR);
      col = clrOrangeRed;
     }
   else if(chasedR < -1.0)
     {
      verdict = "INVALIDATED  (past the stop)";
      col = clrOrangeRed;
     }
   else
     {
      verdict = StringFormat("TAKEABLE  (chased %.2fR, %d bars)", chasedR, ageBars);
      col = clrLimeGreen;
     }
   return true;
  }

void BuildRows()
  {
   g_rowN = 0;
   const string SEP = "-------------------------------------------";
   color dimc = C'110,116,138';

   AddRow("  C R T   S N I P E R   P R O", clrWhite);
   AddRow(StringFormat("Market      : %s  %s", _Symbol, TfName((ENUM_TIMEFRAMES)_Period)), InpPanelText);
   AddRow(StringFormat("Class       : %s  [%s]", ClassName(g_symClass), g_classHow),
          (g_spikeDir != 0 ? clrOrange : InpPanelText));
   AddRow(StringFormat("Style       : %s   TP %.1fR / %.1fR", StyleName(g_style), g_rr1, g_rr2), clrGold);

   int sessNow = SessionOf(TimeCurrent());
   AddRow(StringFormat("Session     : %s%s", SessName(sessNow),
                       (g_asiaSet ? StringFormat("   Asia %s-%s",
                        DoubleToString(g_asiaLo, _Digits), DoubleToString(g_asiaHi, _Digits)) : "")),
          (sessNow == SESS_OFF ? clrSilver : clrAqua));

   string newsTxt = "off";
   color  newsCol = dimc;
   if(InpUseNews)
     {
      if(g_symClass == SC_SPIKE_UP || g_symClass == SC_SPIKE_DOWN || g_symClass == SC_VOL)
        { newsTxt = "n/a for synthetics"; }
      else if(!g_newsOk)
        { newsTxt = "calendar unavailable"; newsCol = clrGoldenrod; }
      else
        {
         int mins = MinutesToNews(TimeCurrent());
         bool blocked = NewsBlackout(TimeCurrent());
         bool tradable = InpTradeNews && InNewsTradeWindow(TimeCurrent()) && g_preSet;
         string state = tradable ? "TRADING THE RELEASE"
                        : (blocked ? "BLACKOUT"
                           : (mins >= 0 ? StringFormat("next in %dm", mins) : "clear"));
         newsTxt = StringFormat("%s  %s  (%d events, %d blocked)", g_newsCcy, state,
                                g_newsCount, g_newsReject);
         newsCol = (tradable ? clrAqua
                    : (blocked ? clrOrangeRed
                       : (mins >= 0 && mins <= 60 ? clrGoldenrod : clrLimeGreen)));
        }
      if(g_newsOk && g_preSet && g_nEvt >= 0)
        {
         AddRow(StringFormat("Pre-news    : %s - %s   (%d-min range)",
                             DoubleToString(g_preLo, _Digits), DoubleToString(g_preHi, _Digits),
                             InpNewsPreRange), clrAqua);
        }
     }
   AddRow(StringFormat("News        : %s", newsTxt), newsCol);
   AddRow(SEP, dimc);

   AddRow(StringFormat("HTF anchor  : %s", TfName(g_htf)), InpPanelText);
   if(!g_htfOk)
      AddRow(StringFormat("HTF history : %d / %d bars  INSUFFICIENT", g_htfAvail, InpEmaSlow + 10), clrRed);
   AddRow(StringFormat("HTF bias    : %s  (ADX %.1f)", RegName(g_dHtfReg), g_dHtfAdx), RegColor(g_dHtfReg));
   AddRow(StringFormat("Mid %-7s : %s", TfName(g_mtf), RegName(g_dMidReg)), RegColor(g_dMidReg));
   AddRow(StringFormat("Chart trend : %s  (ADX %.1f)", RegName(g_dLtfReg), g_dLtfAdx), RegColor(g_dLtfReg));
   AddRow(StringFormat("MTF ribbon  : M15 %s | H1 %s | H4 %s | D1 %s",
                       RegShort(g_ribBias[0]), RegShort(g_ribBias[1]),
                       RegShort(g_ribBias[2]), RegShort(g_ribBias[3])), InpPanelText);
   AddRow(SEP, dimc);

   string pdTxt = (g_dPD < 0.45 ? "DISCOUNT" : (g_dPD > 0.55 ? "PREMIUM" : "EQUILIBRIUM"));
   color  pdCol = (g_dPD < 0.45 ? clrDodgerBlue : (g_dPD > 0.55 ? clrOrangeRed : clrGoldenrod));
   string crtTxt = "SEARCHING";
   color  crtCol = clrSilver;
   if(g_dCrt)
     {
      crtTxt = (g_dCrtDir > 0 ? "BULLISH CRT ARMED" : "BEARISH CRT ARMED");
      crtCol = (g_dCrtDir > 0 ? clrDodgerBlue : clrOrangeRed);
     }
   AddRow(StringFormat("CRT state   : %s", crtTxt), crtCol);
   AddRow(StringFormat("CRT range   : %s / %s",
                       (g_dCrt ? DoubleToString(g_dCrtHi, _Digits) : "-"),
                       (g_dCrt ? DoubleToString(g_dCrtLo, _Digits) : "-")), InpPanelText);
   AddRow(StringFormat("Location    : %s %.0f%%", pdTxt, g_dPD * 100.0), pdCol);
   AddRow(StringFormat("Setup       : %s", g_dPhase), clrSilver);

   if(g_spikeDir != 0)
     {
      AddRow(SEP, dimc);
      AddRow("  S P I K E   E N G I N E", clrOrange);
      AddRow(StringFormat("Spike dir   : %s   drift %s",
                          (g_spikeDir > 0 ? "UP" : "DOWN"),
                          (g_spikeDir > 0 ? "DOWN" : "UP")), clrOrange);
      AddRow(StringFormat("Observed    : %d spikes, every ~%.0f bars", g_spikeSeen, g_avgGap), InpPanelText);
      AddRow(StringFormat("Interval CV : %.2f  %s", g_gapConsistency,
                          (g_gapConsistency < 0.25 ? "[RANDOM - turn HUNT off]"
                           : (g_gapConsistency < 0.50 ? "[weak timing edge]" : "[timing edge real]"))),
             (g_gapConsistency < 0.25 ? clrOrangeRed : (g_gapConsistency < 0.50 ? clrGoldenrod : clrLimeGreen)));
      if(g_avgGap > 0.0 && g_avgGap < 5.0)
         AddRow("Resolution  : too few bars between spikes - drop a TF", clrOrangeRed);
      AddRow(StringFormat("Median size : %s   (drift %s)",
                          DoubleToString(g_medSpike, _Digits), DoubleToString(g_dDrift, _Digits)), InpPanelText);
      AddRow(StringFormat("Last spike  : %d bars ago", g_dBarsSinceSpike), InpPanelText);
      AddRow(StringFormat("Due-ness    : %.0f%%  %s", g_dDueness * 100.0,
                          (g_dDueness >= InpFadeBlockDueness ? "[SPIKE DUE]" : "[SAFE TO FADE]")),
             (g_dDueness >= InpFadeBlockDueness ? clrOrangeRed : clrLimeGreen));
      AddRow(StringFormat("Hunt window : %s   Fade window : %s",
                          (g_dHuntOpen ? "OPEN" : "closed"),
                          (g_dFadeOpen ? "OPEN" : "closed")),
             (g_dHuntOpen || g_dFadeOpen ? clrLimeGreen : clrSilver));
     }

   AddRow(SEP, dimc);
   if(g_sigCount > 0)
     {
      SigRec s = g_sig[g_sigCount-1];
      double risk = MathAbs(s.entry - s.sl);
      double rr   = (risk > 0.0 ? MathAbs(s.tp2 - s.entry) / risk : 0.0);
      color  sc   = (s.dir > 0 ? clrDodgerBlue : clrOrangeRed);
      AddRow(StringFormat("Last signal : %s %s   %s %d  (%s)",
                          (s.dir > 0 ? "BUY " : "SELL"), DoubleToString(s.entry, _Digits),
                          s.grade, s.score, ModeName(s.mode)), sc);

      string verdict; color vcol; double chased; int age;
      FreshnessVerdict(verdict, vcol, chased, age);
      AddRow(StringFormat("Status      : %s", verdict), vcol);

      //--- the reason stack, wrapped so it stays inside the panel
      string why = s.reason;
      int guard = 0;
      bool first = true;
      while(StringLen(why) > 0 && guard < 4)
        {
         string chunk = why;
         if(StringLen(why) > 52)
           {
            int cut = StringLen(why) > 52 ? 52 : StringLen(why);
            int bar = -1;
            for(int q = cut; q > 20; q--)
               if(StringGetCharacter(why, q) == '|') { bar = q; break; }
            if(bar < 0) bar = cut;
            chunk = StringSubstr(why, 0, bar);
            why = StringSubstr(why, bar);
           }
         else
            why = "";
         AddRow(StringFormat("%-12s: %s", (first ? "Why" : ""), chunk), C'170,190,220');
         first = false;
         guard++;
        }
      AddRow(StringFormat("SL / TP1    : %s / %s",
                          DoubleToString(s.sl, _Digits), DoubleToString(s.tp1, _Digits)), InpPanelText);
      AddRow(StringFormat("TP2 / R:R   : %s   1:%.1f", DoubleToString(s.tp2, _Digits), rr), InpPanelText);
      AddRow(StringFormat("Lot @ %.1f%%  : %.2f", InpAccountRiskPct, LotForRisk(risk)), clrGold);
     }
   else
     {
      AddRow("Last signal : -", clrSilver);
     }

   string scale = "-";
   color scaleCol = clrSilver;
   if(g_dCrt && ((g_dCrtDir > 0 && g_dHtfReg == REG_BULL) || (g_dCrtDir < 0 && g_dHtfReg == REG_BEAR)))
     {
      scale = StringFormat("%s on %s", (g_dCrtDir > 0 ? "LONGS" : "SHORTS"), ScaleInHint(g_htf));
      scaleCol = (g_dCrtDir > 0 ? clrDodgerBlue : clrOrangeRed);
     }
   AddRow(StringFormat("Scale in    : %s", scale), scaleCol);

   if(InpTrackStats && !InpPanelCompact)
     {
      AddRow(SEP, dimc);
      int tot = g_nWin + g_nLoss;
      AddRow(StringFormat("  P E R F O R M A N C E   (%d closed)", tot), clrWhite);
      if(tot > 0)
        {
         double wr = 100.0 * g_nWin / tot;
         double avgR = (g_sumWinR - g_sumLossR) / tot;
         double pf = (g_sumLossR > 0.0 ? g_sumWinR / g_sumLossR : (g_sumWinR > 0.0 ? 99.0 : 0.0));
         AddRow(StringFormat("Win rate    : %.0f%%   (%dW / %dL)", wr, g_nWin, g_nLoss),
                (wr >= 55.0 ? clrLimeGreen : (wr >= 45.0 ? clrGoldenrod : clrOrangeRed)));
         AddRow(StringFormat("Avg R       : %+.2f     PF %.2f", avgR, pf),
                (avgR > 0.0 ? clrLimeGreen : clrOrangeRed));
         AddRow(StringFormat("Streak      : %+d      worst %d", g_streak, g_worstStreak), InpPanelText);
         AddRow(StringFormat("By engine   : CRT %d/%d | Hunt %d/%d | Fade %d/%d",
                             g_modeWin[0], g_modeWin[0] + g_modeLoss[0],
                             g_modeWin[1], g_modeWin[1] + g_modeLoss[1],
                             g_modeWin[2], g_modeWin[2] + g_modeLoss[2]), InpPanelText);
        }
      else
         AddRow("Win rate    : collecting...", clrSilver);
     }

   AddRow(SEP, dimc);
   double sprdNow = SpreadPrice();
   AddRow(StringFormat("ATR/Spread  : %s / %s   min score %d",
                       DoubleToString(g_dAtr, _Digits),
                       DoubleToString(sprdNow, _Digits), g_minScore), dimc);
   AddRow(StringFormat("Cost gate   : TP1 >= %.1f x spread   %d rejected",
                       g_minTpSprdX, g_spreadReject),
          (g_spreadReject > 0 ? clrGoldenrod : dimc));
  }

void DrawPanel()
  {
   if(!InpShowPanel)
     {
      ObjectsDeleteAll(0, PREFIX + "row");
      ObjectDelete(0, PREFIX + "bg");
      return;
     }

   BuildRows();

   int rowH = InpFontSize + 7;
   int w = InpFontSize * 44 + 30;
   int h = g_rowN * rowH + 20;

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
   ObjectSetInteger(0, bg, OBJPROP_COLOR, C'58,64,84');
   ObjectSetInteger(0, bg, OBJPROP_BACK, false);
   ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);

   for(int i = 0; i < g_rowN; i++)
      PanelRow(i, g_rowTxt[i], g_rowCol[i]);

   static int lastRows = 0;
   for(int i = g_rowN; i < lastRows; i++)
      ObjectDelete(0, PREFIX + "row" + IntegerToString(i));
   lastRows = g_rowN;
  }

//+------------------------------------------------------------------+
//| Alerts                                                           |
//+------------------------------------------------------------------+
void FireAlert(const datetime t, const int dir, const int mode, const int score,
               const string grade, const double entry, const double sl,
               const double tp1, const double tp2, const string pat, const string reason)
  {
   if(t <= g_lastAlert)
      return;
   g_lastAlert = t;

   string msg = StringFormat("%s %s %s | %s %d | %s\nEntry %s  SL %s  TP1 %s  TP2 %s\nWHY: %s\nValid while price stays within %.2fR of entry, %d bars.",
                             (dir > 0 ? "BUY" : "SELL"), _Symbol, TfName((ENUM_TIMEFRAMES)_Period),
                             grade, score, ModeName(mode),
                             DoubleToString(entry, _Digits), DoubleToString(sl, _Digits),
                             DoubleToString(tp1, _Digits), DoubleToString(tp2, _Digits),
                             reason, InpMaxChaseR, InpSignalTTL);

   if(InpAlertPopup) Alert(msg);
   if(InpAlertPush)  SendNotification(msg);
   if(InpAlertSound) PlaySound(InpSoundFile);
  }

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_style = (InpTradeStyle == STY_AUTO ? AutoStyle((ENUM_TIMEFRAMES)_Period) : InpTradeStyle);

   g_htf = (InpHTF == PERIOD_CURRENT ? ResolveHTFStyled((ENUM_TIMEFRAMES)_Period, g_style) : InpHTF);
   if(PeriodSeconds(g_htf) <= PeriodSeconds(_Period))
      g_htf = ResolveHTFStyled((ENUM_TIMEFRAMES)_Period, g_style);
   g_mtf = PickLadder(MathSqrt((double)PeriodSeconds(_Period) * (double)PeriodSeconds(g_htf)));
   if(PeriodSeconds(g_mtf) <= PeriodSeconds(_Period)) g_mtf = (ENUM_TIMEFRAMES)_Period;
   if(PeriodSeconds(g_mtf) >= PeriodSeconds(g_htf))   g_mtf = g_htf;

   SetIndexBuffer(0, BufBuyHi,  INDICATOR_DATA);
   SetIndexBuffer(1, BufBuyLo,  INDICATOR_DATA);
   SetIndexBuffer(2, BufSellHi, INDICATOR_DATA);
   SetIndexBuffer(3, BufSellLo, INDICATOR_DATA);
   SetIndexBuffer(4, BufSL,     INDICATOR_CALCULATIONS);
   SetIndexBuffer(5, BufTP1,    INDICATOR_CALCULATIONS);
   SetIndexBuffer(6, BufTP2,    INDICATOR_CALCULATIONS);
   SetIndexBuffer(7, BufDir,    INDICATOR_CALCULATIONS);
   SetIndexBuffer(8, BufScore,  INDICATOR_CALCULATIONS);
   SetIndexBuffer(9, BufMode,   INDICATOR_CALCULATIONS);

   ArraySetAsSeries(BufBuyHi,  false);
   ArraySetAsSeries(BufBuyLo,  false);
   ArraySetAsSeries(BufSellHi, false);
   ArraySetAsSeries(BufSellLo, false);
   ArraySetAsSeries(BufSL,     false);
   ArraySetAsSeries(BufTP1,    false);
   ArraySetAsSeries(BufTP2,    false);
   ArraySetAsSeries(BufDir,    false);
   ArraySetAsSeries(BufScore,  false);
   ArraySetAsSeries(BufMode,   false);

   for(int p = 0; p < 4; p++)
     {
      PlotIndexSetInteger(p, PLOT_ARROW, 159);
      PlotIndexSetInteger(p, PLOT_ARROW_SHIFT, 0);
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);
     }

   IndicatorSetString(INDICATOR_SHORTNAME, StringFormat("CRT Sniper Pro (HTF %s)", TfName(g_htf)));
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

   g_hEmaF  = iMA(_Symbol, _Period, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaS  = iMA(_Symbol, _Period, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hAtr   = iATR(_Symbol, _Period, InpAtrPeriod);
   g_hAdx   = iADX(_Symbol, _Period, InpAdxPeriod);
   g_hEmaFH = iMA(_Symbol, g_htf, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaSH = iMA(_Symbol, g_htf, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hAtrH  = iATR(_Symbol, g_htf, InpAtrPeriod);
   g_hAdxH  = iADX(_Symbol, g_htf, InpAdxPeriod);
   g_hEmaFM = iMA(_Symbol, g_mtf, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaSM = iMA(_Symbol, g_mtf, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hAtrM  = iATR(_Symbol, g_mtf, InpAtrPeriod);
   g_hAdxM  = iADX(_Symbol, g_mtf, InpAdxPeriod);

   for(int r = 0; r < 4; r++)
     {
      g_ribEmaF[r] = iMA(_Symbol, g_ribTf[r], InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
      g_ribEmaS[r] = iMA(_Symbol, g_ribTf[r], InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
      g_ribAtr[r]  = iATR(_Symbol, g_ribTf[r], InpAtrPeriod);
      g_ribAdx[r]  = iADX(_Symbol, g_ribTf[r], InpAdxPeriod);
      g_ribBias[r] = REG_RANGE;
     }

   if(g_hEmaF == INVALID_HANDLE || g_hEmaS == INVALID_HANDLE || g_hAtr == INVALID_HANDLE ||
      g_hAdx == INVALID_HANDLE || g_hEmaFH == INVALID_HANDLE || g_hEmaSH == INVALID_HANDLE ||
      g_hAtrH == INVALID_HANDLE || g_hAdxH == INVALID_HANDLE || g_hEmaFM == INVALID_HANDLE ||
      g_hEmaSM == INVALID_HANDLE || g_hAtrM == INVALID_HANDLE || g_hAdxM == INVALID_HANDLE)
     {
      Print("CRT Sniper Pro: failed to create indicator handles");
      return INIT_FAILED;
     }

   ArraySetAsSeries(g_hr, true);
   ResetAll();
   g_lastProc = -1;

   //--- provisional profile from the name; refined statistically on first calculation
   int nd = 0, nn = 0;
   int byName = ClassifyByName(NormSymbol(_Symbol), nd, nn);
   g_symClass = (InpForceClass != SC_AUTO ? InpForceClass : (byName != SC_AUTO ? byName : SC_FX));
   g_spikeDir = (InpForceSpikeDir == SPD_UP ? 1 : (InpForceSpikeDir == SPD_DOWN ? -1 : nd));
   g_nominal  = nn;
   g_classHow = "name";
   AutoTune();
   ApplyStyle();

   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, PREFIX);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Series loading                                                   |
//+------------------------------------------------------------------+
bool LoadSeries(const int rates_total, const int calcFrom)
  {
   int ltfNeed = rates_total - calcFrom + 5;
   if(ltfNeed < 60) ltfNeed = 60;

   ArraySetAsSeries(g_hr,     true);
   ArraySetAsSeries(g_hEmaFv, true);
   ArraySetAsSeries(g_hEmaSv, true);
   ArraySetAsSeries(g_hAtrv,  true);
   ArraySetAsSeries(g_hAdxv,  true);
   ArraySetAsSeries(g_emaFv,  true);
   ArraySetAsSeries(g_emaSv,  true);
   ArraySetAsSeries(g_atrv,   true);
   ArraySetAsSeries(g_adxv,   true);
   ArraySetAsSeries(g_mEmaFv, true);
   ArraySetAsSeries(g_mEmaSv, true);
   ArraySetAsSeries(g_mAtrv,  true);
   ArraySetAsSeries(g_mAdxv,  true);

   if(CopyBuffer(g_hEmaF, 0, 0, ltfNeed, g_emaFv) <= 0) return false;
   if(CopyBuffer(g_hEmaS, 0, 0, ltfNeed, g_emaSv) <= 0) return false;
   if(CopyBuffer(g_hAtr,  0, 0, ltfNeed, g_atrv)  <= 0) return false;
   if(CopyBuffer(g_hAdx,  0, 0, ltfNeed, g_adxv)  <= 0) return false;

   double rHtf = (double)PeriodSeconds(_Period) / (double)PeriodSeconds(g_htf);
   int htfNeed = (int)MathCeil((rates_total - calcFrom) * rHtf)
                 + InpEmaSlow + InpSRLookback + InpCrtValidBars + 20;
   htfNeed = MathMax(htfNeed, InpEmaSlow + 60);
   htfNeed = MathMin(htfNeed, 6000);

   if(CopyRates(_Symbol, g_htf, 0, htfNeed, g_hr) <= 0)   return false;
   g_htfAvail = ArraySize(g_hr);
   g_htfOk    = (g_htfAvail >= InpEmaSlow + 10);
   if(CopyBuffer(g_hEmaFH, 0, 0, htfNeed, g_hEmaFv) <= 0) return false;
   if(CopyBuffer(g_hEmaSH, 0, 0, htfNeed, g_hEmaSv) <= 0) return false;
   if(CopyBuffer(g_hAtrH,  0, 0, htfNeed, g_hAtrv)  <= 0) return false;
   if(CopyBuffer(g_hAdxH,  0, 0, htfNeed, g_hAdxv)  <= 0) return false;

   double rMid = (double)PeriodSeconds(_Period) / (double)PeriodSeconds(g_mtf);
   int midNeed = (int)MathCeil((rates_total - calcFrom) * rMid) + InpEmaSlow + 20;
   midNeed = MathMax(midNeed, InpEmaSlow + 60);
   midNeed = MathMin(midNeed, 6000);

   if(CopyBuffer(g_hEmaFM, 0, 0, midNeed, g_mEmaFv) <= 0) return false;
   if(CopyBuffer(g_hEmaSM, 0, 0, midNeed, g_mEmaSv) <= 0) return false;
   if(CopyBuffer(g_hAtrM,  0, 0, midNeed, g_mAtrv)  <= 0) return false;
   if(CopyBuffer(g_hAdxM,  0, 0, midNeed, g_mAdxv)  <= 0) return false;

   return true;
  }

//--- live multi-timeframe ribbon (dashboard only)
void UpdateRibbon()
  {
   for(int r = 0; r < 4; r++)
     {
      double ef[1], es[1], at[1], ax[1], cl[1];
      if(CopyBuffer(g_ribEmaF[r], 0, 1, 1, ef) <= 0) continue;
      if(CopyBuffer(g_ribEmaS[r], 0, 1, 1, es) <= 0) continue;
      if(CopyBuffer(g_ribAtr[r],  0, 1, 1, at) <= 0) continue;
      if(CopyBuffer(g_ribAdx[r],  0, 1, 1, ax) <= 0) continue;
      if(CopyClose(_Symbol, g_ribTf[r], 1, 1, cl) <= 0) continue;
      g_ribBias[r] = Regime(ef[0], es[0], cl[0], ax[0], at[0]);
     }
  }

//+------------------------------------------------------------------+
//| HTF / mid TF context for a chart bar                             |
//+------------------------------------------------------------------+
bool HtfContext(const datetime barTime, int &hs, int &bias, double &htfPD, double &htfAdx)
  {
   hs = iBarShift(_Symbol, g_htf, barTime, false);
   if(hs < 0) return false;

   int nH = ArraySize(g_hr);
   int need = hs + 1 + InpSRLookback + InpCrtValidBars + 2;
   if(need >= nH) return false;
   if(hs + 1 >= ArraySize(g_hEmaFv) || hs + 1 >= ArraySize(g_hEmaSv) ||
      hs + 1 >= ArraySize(g_hAtrv)  || hs + 1 >= ArraySize(g_hAdxv)) return false;

   htfAdx = g_hAdxv[hs+1];
   bias   = Regime(g_hEmaFv[hs+1], g_hEmaSv[hs+1], g_hr[hs+1].close, htfAdx, g_hAtrv[hs+1]);

   double hi = -DBL_MAX, lo = DBL_MAX;
   for(int k = hs + 1; k <= hs + InpSRLookback; k++)
     {
      if(g_hr[k].high > hi) hi = g_hr[k].high;
      if(g_hr[k].low  < lo) lo = g_hr[k].low;
     }
   htfPD = (hi > lo ? Clamp((g_hr[hs].close - lo) / (hi - lo), 0, 1) : 0.5);
   return true;
  }

int MidBias(const datetime barTime)
  {
   int ms = iBarShift(_Symbol, g_mtf, barTime, false);
   if(ms < 0) return REG_RANGE;
   if(ms + 1 >= ArraySize(g_mEmaFv) || ms + 1 >= ArraySize(g_mEmaSv) ||
      ms + 1 >= ArraySize(g_mAtrv)  || ms + 1 >= ArraySize(g_mAdxv)) return REG_RANGE;
   double cl[1];
   if(CopyClose(_Symbol, g_mtf, ms + 1, 1, cl) <= 0) return REG_RANGE;
   return Regime(g_mEmaFv[ms+1], g_mEmaSv[ms+1], cl[0], g_mAdxv[ms+1], g_mAtrv[ms+1]);
  }

//+------------------------------------------------------------------+
//| Spike bookkeeping                                                |
//+------------------------------------------------------------------+
void RegisterSpike(const int i, const int dir, const double hi, const double lo,
                   const double prevClose)
  {
   if(g_lastSpikeBar >= 0)
     {
      int gap = i - g_lastSpikeBar;
      if(gap > 0)
        {
         if(g_spikeGapN < 32) g_spikeGaps[g_spikeGapN++] = gap;
         else
           {
            for(int k = 1; k < 32; k++) g_spikeGaps[k-1] = g_spikeGaps[k];
            g_spikeGaps[31] = gap;
           }
        }
     }

   double size = hi - lo;
   if(g_spikeSizeN < 32) g_spikeSizes[g_spikeSizeN++] = size;
   else
     {
      for(int k = 1; k < 32; k++) g_spikeSizes[k-1] = g_spikeSizes[k];
      g_spikeSizes[31] = size;
     }

   g_lastSpikeBar   = i;
   g_lastSpikeDir   = dir;
   g_lastSpikeHigh  = hi;
   g_lastSpikeLow   = lo;
   g_lastSpikeRange = size;
   g_preSpikeClose  = prevClose;
   g_spikeSeen++;

   //--- refresh running statistics
   if(g_spikeGapN > 0)
     {
      double sum = 0.0;
      for(int k = 0; k < g_spikeGapN; k++) sum += (double)g_spikeGaps[k];
      g_avgGap = sum / g_spikeGapN;
      double var = 0.0;
      for(int k = 0; k < g_spikeGapN; k++)
         var += MathPow((double)g_spikeGaps[k] - g_avgGap, 2.0);
      var /= g_spikeGapN;
      double sd = MathSqrt(var);
      g_gapConsistency = (g_avgGap > 0.0 ? Clamp(1.0 - sd / g_avgGap, 0, 1) : 0.0);
     }
   if(g_spikeSizeN > 0)
     {
      double tmp[];
      ArrayResize(tmp, g_spikeSizeN);
      for(int k = 0; k < g_spikeSizeN; k++) tmp[k] = g_spikeSizes[k];
      ArraySort(tmp);
      g_medSpike = tmp[g_spikeSizeN / 2];
     }
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
   int minBars = InpEmaSlow + InpLegLookback + InpSwingLen * 2 + InpDriftWin + 30;
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
      ArrayInitialize(BufBuyHi,  EMPTY_VALUE);
      ArrayInitialize(BufBuyLo,  EMPTY_VALUE);
      ArrayInitialize(BufSellHi, EMPTY_VALUE);
      ArrayInitialize(BufSellLo, EMPTY_VALUE);
      ArrayInitialize(BufSL,   0.0);
      ArrayInitialize(BufTP1,  0.0);
      ArrayInitialize(BufTP2,  0.0);
      ArrayInitialize(BufDir,  0.0);
      ArrayInitialize(BufScore, 0.0);
      ArrayInitialize(BufMode,  0.0);
      ResetAll();
      ProfileSymbol(rates_total, open, high, low, close);
      AutoTune();
      ApplyStyle();
      g_spreadReject = 0;
      g_newsReject = 0;
      g_lastProc = calcFrom - 1;
     }

   if(!LoadSeries(rates_total, calcFrom))
      return prev_calculated;

   //--- economic calendar, fetched once for the whole calculated range
   static datetime s_newsLoaded = 0;
   if(InpUseNews && (prev_calculated == 0 || time[rates_total-1] - s_newsLoaded > 3600))
     {
      s_newsLoaded = time[rates_total-1];
      LoadNews(time[calcFrom] - 86400, time[rates_total-1] + 7 * 86400);
     }

   int start = MathMax(calcFrom, g_lastProc + 1);
   int last  = rates_total - 2;

   for(int i = start; i < rates_total; i++)
     {
      BufBuyHi[i]  = EMPTY_VALUE;
      BufBuyLo[i]  = EMPTY_VALUE;
      BufSellHi[i] = EMPTY_VALUE;
      BufSellLo[i] = EMPTY_VALUE;
      BufSL[i] = 0.0; BufTP1[i] = 0.0; BufTP2[i] = 0.0;
      BufDir[i] = 0.0; BufScore[i] = 0.0; BufMode[i] = 0.0;
     }

   for(int i = start; i <= last; i++)
     {
      g_lastProc = i;

      double atr = SV(g_atrv, rates_total, i);
      if(atr <= 0.0)
         continue;

      //--- resolve forward tests opened on earlier bars ------------
      UpdateOpenTrades(high, low, i);

      //--- drift baseline and spike detection ----------------------
      double drift = MedianRange(high, low, i - 1, InpDriftWin);
      int sdir = 0;
      if(g_spikeDir != 0 && IsSpikeBar(open, high, low, close, i, drift, sdir))
         RegisterSpike(i, sdir, high[i], low[i], close[i-1]);

      int barsSince = (g_lastSpikeBar >= 0 ? i - g_lastSpikeBar : 1000000);
      double dueness = (g_avgGap > 0.0 && barsSince < 1000000 ? barsSince / g_avgGap : 0.0);

      UpdateAsianRange(time[i], high[i], low[i]);
      UpdateNewsPhase(time[i], high[i], low[i]);

      //--- swing structure ------------------------------------------
      int L = MathMax(1, InpSwingLen);
      int s = i - L;
      if(s - L >= 0)
        {
         bool isHigh = true, isLow = true;
         for(int k = s - L; k <= s + L; k++)
           {
            if(k == s) continue;
            if(high[k] >= high[s]) isHigh = false;
            if(low[k]  <= low[s])  isLow  = false;
           }
         if(isHigh) { g_swHigh = high[s]; g_swHighBar = s; }
         if(isLow)  { g_swLow  = low[s];  g_swLowBar  = s; }
        }

      //--- higher timeframe context ---------------------------------
      int hs = 0, bias = REG_RANGE;
      double htfPD = 0.5, htfAdx = 0.0;
      if(!HtfContext(time[i], hs, bias, htfPD, htfAdx))
         continue;
      int midReg = MidBias(time[i]);

      double emaF = SV(g_emaFv, rates_total, i);
      double emaS = SV(g_emaSv, rates_total, i);
      double adx  = SV(g_adxv,  rates_total, i);
      int ltfReg  = Regime(emaF, emaS, close[i], adx, atr);
      bool inSess = InKillzone(time[i]);

      //--- CRT state -------------------------------------------------
      CRTInfo crt;
      bool haveCrt = FindCRT(hs, bias, crt);

      if(!haveCrt)
         ResetSetup();
      else
        {
         if(crt.raidTime != g_stRaid || crt.dir != g_stDir)
           {
            ResetSetup();
            g_stRaid = crt.raidTime;
            g_stDir  = crt.dir;
            g_stCrtHi = crt.hi;
            g_stCrtLo = crt.lo;
            g_stCrtQual = crt.qual;
           }
        }

      //================= ENGINE OUTPUT ==============================
      int    sigDir = 0, sigMode = -1, sigScore = 0;
      double sigEntry = 0.0, sigSL = 0.0, sigTP1 = 0.0, sigTP2 = 0.0;
      string sigPat = "", sigReason = "";

      //--------------------------------------------------------------
      // ENGINE A : spike FADE  (against the spike, with the drift)
      //--------------------------------------------------------------
      bool fadeWindow = false;
      if(g_spikeDir != 0 && InpTradeFades && g_spikeSeen >= InpMinSpikesToTrade &&
         g_avgGap >= 5.0 &&
         g_lastSpikeBar >= 0 && barsSince >= 1 && barsSince <= InpFadeWindow &&
         g_lastSpikeDir == g_spikeDir && dueness < InpFadeBlockDueness && drift > 0.0)
        {
         fadeWindow = true;
         int fdir = -g_spikeDir;                       // trade the drift
         double spikeRng = g_lastSpikeRange;
         double exhaust = 0.0;
         if(spikeRng > 0.0)
            exhaust = (g_spikeDir > 0 ? (g_lastSpikeHigh - close[i]) / spikeRng
                       : (close[i] - g_lastSpikeLow) / spikeRng);

         string pat = (fdir > 0 ? BullishPattern(open, high, low, close, i, atr)
                       : BearishPattern(open, high, low, close, i, atr));
         if(pat == "") pat = "Zone Tap";
         bool patOk = (!InpRequirePattern || PatternStrength(pat) > 2);

         if(exhaust >= InpFadeMinExhaust && patOk && inSess &&
            i - g_lastSigBarMode[MODE_FADE] >= g_cooldown)
           {
            double entry = close[i];
            double sl = (fdir > 0 ? g_lastSpikeLow - InpFadeSlBuf * drift
                         : g_lastSpikeHigh + InpFadeSlBuf * drift);
            double risk = MathAbs(entry - sl);
            if(risk > 0.0)
              {
               double tp1, tp2;
               if(fdir > 0)
                 {
                  tp1 = (g_preSpikeClose > entry + 0.3 * drift ? g_preSpikeClose : entry + 2.0 * drift);
                  tp2 = tp1 + InpFadeTp2Drift * drift;
                 }
               else
                 {
                  tp1 = (g_preSpikeClose < entry - 0.3 * drift ? g_preSpikeClose : entry - 2.0 * drift);
                  tp2 = tp1 - InpFadeTp2Drift * drift;
                 }
               double rr = MathAbs(tp1 - entry) / risk;
               int driftReg = (g_spikeDir > 0 ? REG_BEAR : REG_BULL);
               double pdPos = (g_spikeDir > 0 ? Clamp(htfPD, 0, 1) : Clamp(1.0 - htfPD, 0, 1));
               int sc = ScoreFade(Clamp(spikeRng / MathMax(g_medSpike, 1e-12), 0, 1),
                                  exhaust, bias, driftReg, dueness, pat, pdPos, rr);
               if(sc >= g_minScore)
                 {
                  sigDir = fdir; sigMode = MODE_FADE; sigScore = sc;
                  sigEntry = entry; sigSL = sl; sigTP1 = tp1; sigTP2 = tp2; sigPat = pat;
                  sigReason = BuildReason(MODE_FADE, bias, -1, htfPD, "", pat, SessionOf(time[i]), rr,
                                          StringFormat("spike %d bars ago, %.0f%% given back, due %.0f%%",
                                                       barsSince, exhaust * 100.0, dueness * 100.0));
                 }
              }
           }
        }

      //--------------------------------------------------------------
      // ENGINE B : spike HUNT  (with the spike, against the drift)
      //--------------------------------------------------------------
      bool huntWindow = false;
      if(sigMode < 0 && g_spikeDir != 0 && InpTradeSpikes &&
         g_spikeSeen >= InpMinSpikesToTrade && g_medSpike > 0.0 && drift > 0.0 &&
         g_avgGap >= 5.0 &&
         dueness >= InpHuntMinDueness && dueness <= InpHuntMaxDueness)
        {
         double chHi = HighestOf(high, i - InpDriftChanLook + 1, i, rates_total);
         double chLo = LowestOf(low,  i - InpDriftChanLook + 1, i, rates_total);
         double chanPos = (chHi > chLo ? (close[i] - chLo) / (chHi - chLo) : 0.5);
         if(g_spikeDir < 0)
            chanPos = 1.0 - chanPos;                   // Crash hunts from the top

         bool crtOk = (!InpHuntNeedCrt || (g_stDir == g_spikeDir && g_stCrtQual > 0.0));

         if(chanPos <= InpHuntMaxPos && crtOk && inSess &&
            i - g_lastSigBarMode[MODE_HUNT] >= g_cooldown)
           {
            huntWindow = true;
            string pat = (g_spikeDir > 0 ? BullishPattern(open, high, low, close, i, atr)
                          : BearishPattern(open, high, low, close, i, atr));
            if(pat == "") pat = "Zone Tap";
            bool patOk = (!InpRequirePattern || PatternStrength(pat) > 2);

            if(patOk)
              {
               double entry = close[i];
               double sl;
               if(g_spikeDir > 0)
                  sl = MathMin(LowestOf(low, i - 10 + 1, i, rates_total), entry) - InpHuntSlDrift * drift;
               else
                  sl = MathMax(HighestOf(high, i - 10 + 1, i, rates_total), entry) + InpHuntSlDrift * drift;

               double risk = MathAbs(entry - sl);
               if(risk > 0.0)
                 {
                  double tp1 = entry + g_spikeDir * InpSpikeTP1Frac * g_medSpike;
                  double tp2 = entry + g_spikeDir * InpSpikeTP2Frac * g_medSpike;
                  double rr  = MathAbs(tp1 - entry) / risk;
                  int sc = ScoreHunt(dueness, chanPos, (g_stDir == g_spikeDir), pat, rr,
                                     g_medSpike / MathMax(drift, 1e-12));
                  if(sc >= g_minScore && rr >= 1.0)
                    {
                     sigDir = g_spikeDir; sigMode = MODE_HUNT; sigScore = sc;
                     sigEntry = entry; sigSL = sl; sigTP1 = tp1; sigTP2 = tp2; sigPat = pat;
                     sigReason = BuildReason(MODE_HUNT, bias, -1, chanPos, "", pat, SessionOf(time[i]), rr,
                                             StringFormat("spike due %.0f%%, channel %.0f%%, CV %.2f",
                                                          dueness * 100.0, chanPos * 100.0, g_gapConsistency));
                    }
                 }
              }
           }
        }

      //--------------------------------------------------------------
      // ENGINE C : the core CRT / MSS / retest engine
      //--------------------------------------------------------------
      if(sigMode < 0 && haveCrt && InpUseCRT)
        {
         double crtRng = g_stCrtHi - g_stCrtLo;
         if(crtRng > 0.0)
           {
            if(!g_stMss)
              {
               if(g_stDir > 0 && g_swHighBar > 0 && g_swHighBar < i && g_swHigh > 0.0)
                 {
                  double legLow = LowestOf(low, i - InpLegLookback + 1, i, rates_total);
                  double dispMult = (atr > 0.0 ? (close[i] - legLow) / atr : 0.0);
                  if(close[i] > g_swHigh && dispMult >= g_dispATR)
                    {
                     g_stMss = true; g_stMssLvl = g_swHigh; g_stMssBar = i; g_stDisp = dispMult;
                     g_stZone = BuildBullZone(open, high, low, close, i, atr,
                                              g_stZoneHi, g_stZoneLo, g_stZoneKind);
                    }
                 }
               else
                  if(g_stDir < 0 && g_swLowBar > 0 && g_swLowBar < i && g_swLow > 0.0)
                    {
                     double legHigh = HighestOf(high, i - InpLegLookback + 1, i, rates_total);
                     double dispMult = (atr > 0.0 ? (legHigh - close[i]) / atr : 0.0);
                     if(close[i] < g_swLow && dispMult >= g_dispATR)
                       {
                        g_stMss = true; g_stMssLvl = g_swLow; g_stMssBar = i; g_stDisp = dispMult;
                        g_stZone = BuildBearZone(open, high, low, close, i, atr,
                                                 g_stZoneHi, g_stZoneLo, g_stZoneKind);
                       }
                    }
              }
            else
              {
               bool dead = (!g_stZone) || (i - g_stMssBar > g_expiry) ||
                           (g_stDir > 0 && close[i] < g_stZoneLo - InpInvalidATR * atr) ||
                           (g_stDir < 0 && close[i] > g_stZoneHi + InpInvalidATR * atr);
               if(dead)
                 {
                  g_stMss = false; g_stZone = false; g_stMssLvl = 0.0; g_stZoneKind = "";
                 }
               else
                 {
                  bool wantBuy  = (g_stDir > 0);
                  bool wantSell = (g_stDir < 0);
                  double pd = Clamp((close[i] - g_stCrtLo) / crtRng, -0.5, 1.5);

                  bool ok = true;
                  if(InpBlockInRange && bias == REG_RANGE)      ok = false;
                  if(wantBuy  && bias != REG_BULL)              ok = false;
                  if(wantSell && bias != REG_BEAR)              ok = false;
                  if(wantBuy  && pd > InpMaxBuyPD)              ok = false;
                  if(wantSell && pd < InpMinSellPD)             ok = false;
                  if(InpUseHtfPD && wantBuy  && htfPD > InpHtfMaxBuyPD)  ok = false;
                  if(InpUseHtfPD && wantSell && htfPD < InpHtfMinSellPD) ok = false;
                  if(!inSess) ok = false;
                  if(i - g_lastSigBarMode[MODE_CRT] < g_cooldown) ok = false;

                  bool emaAligned = (wantBuy ? (emaF > emaS && close[i] > emaF)
                                     : (emaF < emaS && close[i] < emaF));
                  if(InpEmaFilter == EMAF_SOFT)
                    {
                     if(wantBuy  && close[i] < emaF) ok = false;
                     if(wantSell && close[i] > emaF) ok = false;
                    }
                  else
                     if(InpEmaFilter == EMAF_STRICT && !emaAligned)
                        ok = false;

                  bool tapped = (wantBuy ? (low[i] <= g_stZoneHi && close[i] > g_stZoneLo)
                                 : (high[i] >= g_stZoneLo && close[i] < g_stZoneHi));
                  if(!tapped) ok = false;

                  string pat = "";
                  if(ok)
                    {
                     pat = (wantBuy ? BullishPattern(open, high, low, close, i, atr)
                            : BearishPattern(open, high, low, close, i, atr));
                     if(InpRequirePattern && pat == "") ok = false;
                     if(pat == "") pat = "Zone Tap";
                    }

                  if(ok)
                    {
                     double entry = close[i], sl;
                     if(wantBuy)
                        sl = MathMin(LowestOf(low, i - InpSlLookback + 1, i, rates_total), g_stZoneLo) - g_slBuf * atr;
                     else
                        sl = MathMax(HighestOf(high, i - InpSlLookback + 1, i, rates_total), g_stZoneHi) + g_slBuf * atr;

                     double risk = MathAbs(entry - sl);
                     if(risk > 0.0 && (g_maxRiskATR <= 0.0 || risk <= g_maxRiskATR * atr))
                       {
                        double tp1, tp2;
                        if(wantBuy)
                          {
                           tp1 = entry + risk * g_rr1;
                           tp2 = entry + risk * g_rr2;
                           if(g_liqTP)
                             {
                              double liq = MathMax(g_stCrtHi, HighestOf(high, i - InpLiqLookback + 1, i, rates_total));
                              if(liq > tp1) tp2 = liq;
                             }
                          }
                        else
                          {
                           tp1 = entry - risk * g_rr1;
                           tp2 = entry - risk * g_rr2;
                           if(g_liqTP)
                             {
                              double liq = MathMin(g_stCrtLo, LowestOf(low, i - InpLiqLookback + 1, i, rates_total));
                              if(liq < tp1) tp2 = liq;
                             }
                          }

                        int mtfAgree = 0;
                        int want = (wantBuy ? REG_BULL : REG_BEAR);
                        if(bias == want)   mtfAgree++;
                        if(midReg == want) mtfAgree++;
                        if(ltfReg == want) mtfAgree++;

                        double pdDepth = (wantBuy ? Clamp((InpMaxBuyPD - pd) / MathMax(InpMaxBuyPD, 0.01), 0, 1)
                                          : Clamp((pd - InpMinSellPD) / MathMax(1.0 - InpMinSellPD, 0.01), 0, 1));

                        int sc = ScoreCRT(bias == want, mtfAgree, g_stCrtQual, pdDepth, g_stDisp,
                                          g_stZoneKind, pat, emaAligned, adx, inSess);
                        if(sc >= g_minScore)
                          {
                           sigDir = (wantBuy ? 1 : -1); sigMode = MODE_CRT; sigScore = sc;
                           sigEntry = entry; sigSL = sl; sigTP1 = tp1; sigTP2 = tp2; sigPat = pat;
                           sigReason = BuildReason(MODE_CRT, bias, mtfAgree, pd, g_stZoneKind, pat,
                                                   SessionOf(time[i]), g_rr1,
                                                   StringFormat("CRT raid q%.2f, MSS %.1fxATR", g_stCrtQual, g_stDisp));
                          }

                        if(!InpMultiEntry && sc >= g_minScore)
                          {
                           g_stMss = false; g_stZone = false; g_stMssLvl = 0.0; g_stZoneKind = "";
                          }
                       }
                    }
                 }
              }
           }
        }

      //--------------------------------------------------------------
      // Shared context for the pure price-action models
      //--------------------------------------------------------------
      int    wantReg  = REG_RANGE;
      int    mtf3     = 0;
      bool   newsOut  = NewsBlackout(time[i]);
      int    sessNow  = SessionOf(time[i]);
      double chHi50   = HighestOf(high, i - InpDriftChanLook + 1, i, rates_total);
      double chLo50   = LowestOf(low,  i - InpDriftChanLook + 1, i, rates_total);
      double chPos    = (chHi50 > chLo50 ? (close[i] - chLo50) / (chHi50 - chLo50) : 0.5);

      bool paAllowed = (sigMode < 0) && !newsOut && inSess && bias != REG_RANGE;

      //--------------------------------------------------------------
      // ENGINE D : liquidity sweep + reclaim
      //--------------------------------------------------------------
      if(paAllowed && InpUseSweep && i - g_lastSigBarMode[MODE_SWEEP] >= g_cooldown)
        {
         bool wantBuy = (bias == REG_BULL);
         double lvl = (wantBuy ? LowestOf(low,  i - InpSweepLook, i - 1, rates_total)
                       : HighestOf(high, i - InpSweepLook, i - 1, rates_total));
         double pen = (wantBuy ? (lvl - low[i]) : (high[i] - lvl));

         bool swept = (wantBuy ? (low[i] < lvl && close[i] > lvl)
                       : (high[i] > lvl && close[i] < lvl));

         if(swept && pen >= InpSweepMinATR * atr)
           {
            string pat = (wantBuy ? BullishPattern(open, high, low, close, i, atr)
                          : BearishPattern(open, high, low, close, i, atr));
            if(!(InpRequirePattern && pat == ""))
              {
               if(pat == "") pat = "Reclaim";
               double entry = close[i];
               double sl = (wantBuy ? low[i] - g_slBuf * atr : high[i] + g_slBuf * atr);
               double risk = MathAbs(entry - sl);
               if(risk > 0.0 && (g_maxRiskATR <= 0.0 || risk <= g_maxRiskATR * atr))
                 {
                  double tp1 = entry + (wantBuy ? 1.0 : -1.0) * risk * g_rr1;
                  double tp2 = entry + (wantBuy ? 1.0 : -1.0) * risk * g_rr2;
                  double pdD = (wantBuy ? Clamp(1.0 - chPos, 0, 1) : Clamp(chPos, 0, 1));
                  wantReg = (wantBuy ? REG_BULL : REG_BEAR);
                  mtf3 = (bias == wantReg) + (midReg == wantReg) + (ltfReg == wantReg);
                  bool emaAl = (wantBuy ? (emaF > emaS && close[i] > emaF) : (emaF < emaS && close[i] < emaF));
                  int sc = ScorePA(true, mtf3, pdD, Clamp(pen / (0.8 * atr), 0, 1), pat,
                                   emaAl, adx, inSess, g_rr1, sessNow != SESS_OFF);
                  if(sc >= g_minScore)
                    {
                     sigDir = (wantBuy ? 1 : -1); sigMode = MODE_SWEEP; sigScore = sc;
                     sigEntry = entry; sigSL = sl; sigTP1 = tp1; sigTP2 = tp2; sigPat = pat;
                     sigReason = BuildReason(MODE_SWEEP, bias, mtf3, chPos, "", pat, sessNow, g_rr1,
                                             StringFormat("swept %s %s", (wantBuy ? "low" : "high"),
                                                          DoubleToString(lvl, _Digits)));
                    }
                 }
              }
           }
        }

      //--------------------------------------------------------------
      // ENGINE E : break and retest
      //--------------------------------------------------------------
      if(g_swHighBar > 0 && close[i] > g_swHigh && (close[i] - g_swHigh) >= 0.2 * atr &&
         g_brtDir != 1)
        {
         g_brtDir = 1; g_brtLevel = g_swHigh; g_brtBar = i;
        }
      if(g_swLowBar > 0 && close[i] < g_swLow && (g_swLow - close[i]) >= 0.2 * atr &&
         g_brtDir != -1)
        {
         g_brtDir = -1; g_brtLevel = g_swLow; g_brtBar = i;
        }
      if(g_brtDir != 0 && i - g_brtBar > InpBrtExpiry)
         g_brtDir = 0;

      if(paAllowed && sigMode < 0 && InpUseBRT && g_brtDir != 0 && i > g_brtBar &&
         i - g_lastSigBarMode[MODE_BRT] >= g_cooldown)
        {
         bool wantBuy = (g_brtDir > 0);
         if((wantBuy && bias == REG_BULL) || (!wantBuy && bias == REG_BEAR))
           {
            double tol = InpBrtTolATR * atr;
            bool touched = (wantBuy ? (low[i] <= g_brtLevel + tol && close[i] > g_brtLevel)
                            : (high[i] >= g_brtLevel - tol && close[i] < g_brtLevel));
            if(touched)
              {
               string pat = (wantBuy ? BullishPattern(open, high, low, close, i, atr)
                             : BearishPattern(open, high, low, close, i, atr));
               if(!(InpRequirePattern && pat == ""))
                 {
                  if(pat == "") pat = "Retest Hold";
                  double entry = close[i];
                  double sl = (wantBuy ? MathMin(low[i], g_brtLevel) - g_slBuf * atr
                               : MathMax(high[i], g_brtLevel) + g_slBuf * atr);
                  double risk = MathAbs(entry - sl);
                  if(risk > 0.0 && (g_maxRiskATR <= 0.0 || risk <= g_maxRiskATR * atr))
                    {
                     double tp1 = entry + (wantBuy ? 1.0 : -1.0) * risk * g_rr1;
                     double tp2 = entry + (wantBuy ? 1.0 : -1.0) * risk * g_rr2;
                     double precision = Clamp(1.0 - MathAbs(close[i] - g_brtLevel) / MathMax(tol, 1e-12), 0, 1);
                     wantReg = (wantBuy ? REG_BULL : REG_BEAR);
                     mtf3 = (bias == wantReg) + (midReg == wantReg) + (ltfReg == wantReg);
                     bool emaAl = (wantBuy ? (emaF > emaS && close[i] > emaF) : (emaF < emaS && close[i] < emaF));
                     double pdD = (wantBuy ? Clamp(1.0 - chPos, 0, 1) : Clamp(chPos, 0, 1));
                     int sc = ScorePA(true, mtf3, pdD, precision, pat, emaAl, adx, inSess,
                                      g_rr1, sessNow != SESS_OFF);
                     if(sc >= g_minScore)
                       {
                        sigDir = (wantBuy ? 1 : -1); sigMode = MODE_BRT; sigScore = sc;
                        sigEntry = entry; sigSL = sl; sigTP1 = tp1; sigTP2 = tp2; sigPat = pat;
                        sigReason = BuildReason(MODE_BRT, bias, mtf3, chPos, "", pat, sessNow, g_rr1,
                                                "retest " + DoubleToString(g_brtLevel, _Digits));
                        g_brtDir = 0;
                       }
                    }
                 }
              }
           }
        }

      //--------------------------------------------------------------
      // ENGINE F : trend pullback to EMA 50
      //--------------------------------------------------------------
      if(paAllowed && sigMode < 0 && InpUseTPB && ltfReg != REG_RANGE && ltfReg == bias &&
         i - g_lastSigBarMode[MODE_TPB] >= g_cooldown && emaF > 0.0)
        {
         bool wantBuy = (bias == REG_BULL);
         bool touchedEma = (wantBuy ? (low[i] <= emaF && close[i] > emaF)
                            : (high[i] >= emaF && close[i] < emaF));
         if(touchedEma)
           {
            double legHi = HighestOf(high, i - InpLegLookback * 2 + 1, i, rates_total);
            double legLo = LowestOf(low,  i - InpLegLookback * 2 + 1, i, rates_total);
            double legRng = legHi - legLo;
            double depth = (legRng > 0.0 ? (wantBuy ? (legHi - close[i]) / legRng
                                            : (close[i] - legLo) / legRng) : 1.0);
            if(depth <= InpTpbMaxDepth)
              {
               string pat = (wantBuy ? BullishPattern(open, high, low, close, i, atr)
                             : BearishPattern(open, high, low, close, i, atr));
               if(!(InpRequirePattern && pat == ""))
                 {
                  if(pat == "") pat = "EMA Hold";
                  double entry = close[i];
                  double sl = (wantBuy ? LowestOf(low, i - InpSlLookback + 1, i, rates_total) - g_slBuf * atr
                               : HighestOf(high, i - InpSlLookback + 1, i, rates_total) + g_slBuf * atr);
                  double risk = MathAbs(entry - sl);
                  if(risk > 0.0 && (g_maxRiskATR <= 0.0 || risk <= g_maxRiskATR * atr))
                    {
                     double tp1 = entry + (wantBuy ? 1.0 : -1.0) * risk * g_rr1;
                     double tp2 = entry + (wantBuy ? 1.0 : -1.0) * risk * g_rr2;
                     wantReg = (wantBuy ? REG_BULL : REG_BEAR);
                     mtf3 = (bias == wantReg) + (midReg == wantReg) + (ltfReg == wantReg);
                     int sc = ScorePA(true, mtf3, Clamp(depth / InpTpbMaxDepth, 0, 1),
                                      Clamp((adx - g_adxTrend) / 15.0, 0, 1), pat, true, adx,
                                      inSess, g_rr1, sessNow != SESS_OFF);
                     if(sc >= g_minScore)
                       {
                        sigDir = (wantBuy ? 1 : -1); sigMode = MODE_TPB; sigScore = sc;
                        sigEntry = entry; sigSL = sl; sigTP1 = tp1; sigTP2 = tp2; sigPat = pat;
                        sigReason = BuildReason(MODE_TPB, bias, mtf3, (wantBuy ? depth : 1.0 - depth),
                                                "", pat, sessNow, g_rr1,
                                                StringFormat("EMA%d pullback %.0f%%", InpEmaFast, depth * 100.0));
                       }
                    }
                 }
              }
           }
        }

      //--------------------------------------------------------------
      // ENGINE G : Asian range sweep (Judas swing)
      //--------------------------------------------------------------
      if(paAllowed && sigMode < 0 && InpUseAsia && g_asiaSet && g_spikeDir == 0 &&
         g_asiaHi > g_asiaLo && i - g_lastSigBarMode[MODE_ASIA] >= g_cooldown)
        {
         int gh = GmtHour(time[i]);
         if(gh >= InpAsiaSweepStart && gh < InpAsiaSweepEnd)
           {
            bool wantBuy = (bias == REG_BULL);
            bool swept = false;
            if(wantBuy && !g_asiaSweptLo && low[i] < g_asiaLo && close[i] > g_asiaLo)
              { swept = true; g_asiaSweptLo = true; }
            if(!wantBuy && !g_asiaSweptHi && high[i] > g_asiaHi && close[i] < g_asiaHi)
              { swept = true; g_asiaSweptHi = true; }

            if(swept)
              {
               string pat = (wantBuy ? BullishPattern(open, high, low, close, i, atr)
                             : BearishPattern(open, high, low, close, i, atr));
               if(!(InpRequirePattern && pat == ""))
                 {
                  if(pat == "") pat = "Judas Reclaim";
                  double entry = close[i];
                  double sl = (wantBuy ? low[i] - g_slBuf * atr : high[i] + g_slBuf * atr);
                  double risk = MathAbs(entry - sl);
                  if(risk > 0.0 && (g_maxRiskATR <= 0.0 || risk <= g_maxRiskATR * atr))
                    {
                     // the opposite side of the Asian range is the natural target
                     double liq = (wantBuy ? g_asiaHi : g_asiaLo);
                     double tp1 = entry + (wantBuy ? 1.0 : -1.0) * risk * g_rr1;
                     if(wantBuy && liq > tp1) tp1 = liq;
                     if(!wantBuy && liq < tp1) tp1 = liq;
                     double tp2 = entry + (wantBuy ? 1.0 : -1.0) * risk * g_rr2;
                     double rrEff = MathAbs(tp1 - entry) / risk;
                     wantReg = (wantBuy ? REG_BULL : REG_BEAR);
                     mtf3 = (bias == wantReg) + (midReg == wantReg) + (ltfReg == wantReg);
                     bool emaAl = (wantBuy ? (emaF > emaS) : (emaF < emaS));
                     int sc = ScorePA(true, mtf3, 0.8, 0.85, pat, emaAl, adx, true, rrEff, true);
                     if(sc >= g_minScore)
                       {
                        sigDir = (wantBuy ? 1 : -1); sigMode = MODE_ASIA; sigScore = sc;
                        sigEntry = entry; sigSL = sl; sigTP1 = tp1; sigTP2 = tp2; sigPat = pat;
                        sigReason = BuildReason(MODE_ASIA, bias, mtf3, -1.0, "", pat, sessNow, rrEff,
                                                StringFormat("swept Asian %s", (wantBuy ? "low" : "high")));
                       }
                    }
                 }
              }
           }
        }

      //--------------------------------------------------------------
      // ENGINE H / I : trading the release itself
      // These are the only engines allowed to fire inside a blackout.
      //--------------------------------------------------------------
      if(InpTradeNews && sigMode < 0 && g_nEvt >= 0 && g_preSet && InNewsTradeWindow(time[i]) &&
         g_preHi > g_preLo && g_symClass != SC_SPIKE_UP && g_symClass != SC_SPIKE_DOWN)
        {
         double preRng = g_preHi - g_preLo;

         //--- H : the release breaks the pre-news range and keeps going
         if(InpNewsBO && !g_nboDone && i - g_lastSigBarMode[MODE_NBO] >= g_cooldown)
           {
            bool up   = (close[i] > g_preHi + InpNewsDispATR * atr);
            bool down = (close[i] < g_preLo - InpNewsDispATR * atr);
            if(up || down)
              {
               int want = (up ? REG_BULL : REG_BEAR);
               bool biasOk = (!InpNewsBoNeedBias || bias == want);
               if(biasOk)
                 {
                  double entry = close[i];
                  double sl = (up ? g_preLo - g_slBuf * atr : g_preHi + g_slBuf * atr);
                  double risk = MathAbs(entry - sl);
                  if(risk > 0.0 && (g_maxRiskATR <= 0.0 || risk <= g_maxRiskATR * atr))
                    {
                     double dirM = (up ? 1.0 : -1.0);
                     double tp1 = entry + dirM * risk * g_rr1;
                     double tp2 = entry + dirM * risk * g_rr2;
                     double push = MathAbs(up ? close[i] - g_preHi : g_preLo - close[i]) / MathMax(atr, 1e-12);
                     mtf3 = (bias == want) + (midReg == want) + (ltfReg == want);
                     string pat = (up ? BullishPattern(open, high, low, close, i, atr)
                                   : BearishPattern(open, high, low, close, i, atr));
                     if(pat == "") pat = "Release Break";
                     int sc = ScorePA(bias == want, mtf3, 0.6, Clamp(push / 2.0, 0, 1), pat,
                                      true, adx, true, g_rr1, true);
                     if(sc >= g_minScore)
                       {
                        sigDir = (up ? 1 : -1); sigMode = MODE_NBO; sigScore = sc;
                        sigEntry = entry; sigSL = sl; sigTP1 = tp1; sigTP2 = tp2; sigPat = pat;
                        sigReason = BuildReason(MODE_NBO, bias, mtf3, -1.0, "", pat, sessNow, g_rr1,
                                                StringFormat("broke %d-min pre-news range by %.1fxATR", InpNewsPreRange, push));
                        g_nboDone = true;
                       }
                    }
                 }
              }
           }

         //--- I : the release spikes out of the range and gets rejected back in
         if(sigMode < 0 && InpNewsFade && !g_nfdDone && g_postSet &&
            i - g_lastSigBarMode[MODE_NFD] >= g_cooldown)
           {
            double spikeUp = (g_postHi - g_preHi) / MathMax(atr, 1e-12);
            double spikeDn = (g_preLo - g_postLo) / MathMax(atr, 1e-12);

            bool fadeShort = (spikeUp >= InpNewsSpikeATR && close[i] < g_preHi);
            bool fadeLong  = (spikeDn >= InpNewsSpikeATR && close[i] > g_preLo);
            if(fadeShort || fadeLong)
              {
               bool up = fadeLong;
               double entry = close[i];
               double sl = (up ? g_postLo - g_slBuf * atr : g_postHi + g_slBuf * atr);
               double risk = MathAbs(entry - sl);
               if(risk > 0.0 && (g_maxRiskATR <= 0.0 || risk <= g_maxRiskATR * atr))
                 {
                  //--- the far side of the pre-news range is the natural target
                  double dirM = (up ? 1.0 : -1.0);
                  double liq = (up ? g_preHi : g_preLo);
                  double tp1 = entry + dirM * risk * g_rr1;
                  if(up && liq > entry && liq < tp1)  tp1 = liq;
                  if(!up && liq < entry && liq > tp1) tp1 = liq;
                  double tp2 = entry + dirM * risk * g_rr2;
                  double rrEff = MathAbs(tp1 - entry) / risk;
                  int want = (up ? REG_BULL : REG_BEAR);
                  mtf3 = (bias == want) + (midReg == want) + (ltfReg == want);
                  string pat = (up ? BullishPattern(open, high, low, close, i, atr)
                                : BearishPattern(open, high, low, close, i, atr));
                  if(pat == "") pat = "Release Rejection";
                  double mag = (up ? spikeDn : spikeUp);
                  int sc = ScorePA(bias == want, mtf3, 0.7, Clamp(mag / 3.0, 0, 1), pat,
                                   true, adx, true, rrEff, true);
                  if(sc >= g_minScore && rrEff >= 1.0)
                    {
                     sigDir = (up ? 1 : -1); sigMode = MODE_NFD; sigScore = sc;
                     sigEntry = entry; sigSL = sl; sigTP1 = tp1; sigTP2 = tp2; sigPat = pat;
                     sigReason = BuildReason(MODE_NFD, bias, mtf3, -1.0, "", pat, sessNow, rrEff,
                                             StringFormat("release spiked %.1fxATR out of the range and reclaimed it", mag));
                     g_nfdDone = true;
                    }
                 }
              }
           }
        }

      //--- news blackout vetoes everything except the news engines ----
      if(sigMode == MODE_NBO || sigMode == MODE_NFD)
         newsOut = false;
      if(sigMode >= 0 && newsOut)
        {
         g_newsReject++;
         sigMode = -1;
         sigDir = 0;
        }

      //--- spread viability : a target the spread eats is not a signal ---
      if(sigMode >= 0 && sigDir != 0 && g_minTpSprdX > 0.0)
        {
         double sprd = SpreadPrice();
         if(sprd > 0.0 && MathAbs(sigTP1 - sigEntry) < g_minTpSprdX * sprd)
           {
            g_spreadReject++;
            sigMode = -1;
            sigDir  = 0;
           }
        }

      //--- publish -----------------------------------------------------
      if(sigMode >= 0 && sigDir != 0)
        {
         double off = InpDotOffsetATR * atr;
         // large dot = premium score AND every hard gate clear (news, session,
         // spread, and enough anchor history for the bias to mean anything)
         bool premium = (sigScore >= InpPremiumScore) && g_htfOk;
         if(sigDir > 0)
           {
            if(premium) BufBuyHi[i] = low[i] - off;
            else        BufBuyLo[i] = low[i] - off;
           }
         else
           {
            if(premium) BufSellHi[i] = high[i] + off;
            else        BufSellLo[i] = high[i] + off;
           }

         BufSL[i] = sigSL; BufTP1[i] = sigTP1; BufTP2[i] = sigTP2;
         BufDir[i] = (double)sigDir;
         BufScore[i] = (double)sigScore;
         BufMode[i] = (double)sigMode;

         PushSignal(time[i], i, sigDir, sigMode, sigScore, sigEntry, sigSL, sigTP1, sigTP2, sigPat, sigReason);
         g_lastSigBarMode[sigMode] = i;

         if(i == rates_total - 2)
            FireAlert(time[i], sigDir, sigMode, sigScore, GradeOf(sigScore),
                      sigEntry, sigSL, sigTP1, sigTP2, sigPat, sigReason);
        }

      //--- carry window state to the dashboard on the newest bar ------
      if(i == last)
        {
         g_dDrift = drift;
         g_dDueness = Clamp(dueness, 0, 5);
         g_dBarsSinceSpike = (barsSince < 1000000 ? barsSince : -1);
         g_dHuntOpen = huntWindow;
         g_dFadeOpen = fadeWindow;
        }
     }

   //--- dashboard snapshot -------------------------------------------
   int snap = rates_total - 2;
   if(snap >= calcFrom)
     {
      double atrS = SV(g_atrv, rates_total, snap);
      g_dAtr    = atrS;
      g_dLtfAdx = SV(g_adxv, rates_total, snap);
      g_dLtfReg = Regime(SV(g_emaFv, rates_total, snap), SV(g_emaSv, rates_total, snap),
                         close[snap], g_dLtfAdx, atrS);

      int hs = 0, bias = REG_RANGE;
      double htfPD = 0.5, htfAdx = 0.0;
      g_dCrt = false;
      if(HtfContext(time[snap], hs, bias, htfPD, htfAdx))
        {
         g_dHtfReg = bias;
         g_dHtfAdx = htfAdx;
         g_dHtfPD  = htfPD;
         g_dMidReg = MidBias(time[snap]);

         CRTInfo crt;
         g_dCrt = FindCRT(hs, bias, crt);
         if(g_dCrt)
           {
            g_dCrtDir = crt.dir;
            g_dCrtHi = crt.hi;
            g_dCrtLo = crt.lo;
            double rr = crt.hi - crt.lo;
            g_dPD = (rr > 0.0 ? Clamp((close[snap] - crt.lo) / rr, 0, 1) : 0.5);
           }
        }

      if(!g_dCrt)       g_dPhase = "waiting for a CRT raid";
      else if(!g_stMss) g_dPhase = "raid confirmed - waiting MSS";
      else if(g_stZone) g_dPhase = "MSS ok - waiting retest (" + g_stZoneKind + ")";
      else              g_dPhase = "MSS ok - no valid zone";
     }

   UpdateRibbon();
   DrawSignalLevels(prev_calculated == 0);
   DrawCrtBox();
   DrawPanel();
   ChartRedraw();

   return rates_total;
  }
//+------------------------------------------------------------------+
