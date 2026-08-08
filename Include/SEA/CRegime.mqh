//+------------------------------------------------------------------+
//|                                                      CRegime.mqh  |
//|                                                                   |
//|   Module 9. Trending / ranging / expansion / compression.         |
//|                                                                   |
//|   Regime does not decide WHETHER to trade or in WHICH direction.  |
//|   It decides how a position is MANAGED once structure has already |
//|   justified it: how far to let it run, when to move to break-even,|
//|   whether to trail, whether to add.                               |
//|                                                                   |
//|   The one veto it holds: COMPRESSION blocks new entries, because  |
//|   there is no displacement to trade into.                         |
//+------------------------------------------------------------------+
#ifndef SEA_CREGIME_MQH
#define SEA_CREGIME_MQH

#include <SEA/SEA_Common.mqh>
#include <SEA/CStructure.mqh>

//+------------------------------------------------------------------+
//| Management profile implied by a regime.                           |
//+------------------------------------------------------------------+
struct SRegimeProfile
  {
   int               maxScaleIns;      // -1 means "use the style maximum"
   bool              addOnNewBOS;
   bool              addOnPullback;
   double            breakEvenR;       // 0 means never
   bool              trailStructural;
   bool              trailATR;
   double            trailATRMult;
   double            stopATRMult;      // 0 means use the structural stop
   bool              entriesAllowed;
  };

//+------------------------------------------------------------------+
//| CRegime                                                           |
//|                                                                   |
//| One instance per (symbol, timeframe).                             |
//+------------------------------------------------------------------+
class CRegime
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   int               m_atrFast;
   int               m_atrSlow;
   int               m_adxHandle;
   int               m_atrFastPeriod;
   int               m_atrSlowPeriod;
   int               m_adxPeriod;

   //--- thresholds
   double            m_adxTrending;     // above this = trending
   double            m_adxRanging;      // below this = ranging
   double            m_expansionRatio;  // ATR14 > ATR50 * this
   double            m_compressionRatio;// ATR14 < ATR50 * this

   bool              m_verbose;
   datetime          m_lastBarTime;
   bool              m_ready;

   ENUM_SEA_REGIME   m_regime;
   ENUM_SEA_REGIME   m_previous;
   bool              m_changedThisBar;
   double            m_adx;
   double            m_atrFastValue;
   double            m_atrSlowValue;
   int               m_insideBarRun;

   int               CountInsideBars(const MqlRates &r[],const int total) const;

public:
                     CRegime(void);
                    ~CRegime(void) {}

   //! Bind to a symbol and timeframe and take ATR/ADX handles.
   //!
   //! adxTrending      20..40, default 25
   //! adxRanging       10..25, default 20
   //! expansionRatio   1.1..3.0, default 1.50
   //! compressionRatio 0.3..0.9, default 0.70
   bool              Init(const string symbol,const ENUM_TIMEFRAMES tf,CIndicatorPool &pool,
                          const int atrFastPeriod,const int atrSlowPeriod,const int adxPeriod,
                          const double adxTrending,const double adxRanging,
                          const double expansionRatio,const double compressionRatio);

   //! Return every handle to the pool.
   void              Release(CIndicatorPool &pool);

   //! Print diagnostics. Off by default.
   void              SetVerbose(const bool enabled) { m_verbose=enabled; }

   //! Re-classify. Call per bar for any symbol holding an open position.
   //! New bar only unless forced.
   bool              Update(const CStructure &structure,const bool force=false);

   //! True once a successful Update has run.
   bool              IsReady(void) const { return m_ready; }

   //--- results ----------------------------------------------------------
   //! Current regime.
   ENUM_SEA_REGIME   Regime(void) const { return m_regime; }

   //! Regime before the most recent change.
   ENUM_SEA_REGIME   Previous(void) const { return m_previous; }

   //! True when the regime changed on the most recent update.
   //! On a change the caller must apply the new management profile and
   //! block further scale-ins.
   bool              Changed(void) const { return m_changedThisBar; }

   //! Latest ADX reading from the newest CLOSED bar.
   double            ADX(void) const { return m_adx; }

   //! Latest fast ATR.
   double            ATRFast(void) const { return m_atrFastValue; }

   //! Latest slow ATR.
   double            ATRSlow(void) const { return m_atrSlowValue; }

   //! Consecutive inside bars ending at the newest closed bar.
   int               InsideBarRun(void) const { return m_insideBarRun; }

   //! GATE-adjacent: COMPRESSION forbids new entries outright.
   bool              EntriesAllowed(void) const { return m_regime!=SEA_REGIME_COMPRESSION; }

   //! Management profile for the current regime.
   SRegimeProfile    Profile(void) const;

   //! Management profile for an arbitrary regime.
   SRegimeProfile    ProfileFor(const ENUM_SEA_REGIME regime) const;

   //! One-line summary.
   string            Describe(void) const;
  };

//+------------------------------------------------------------------+
CRegime::CRegime(void)
  {
   m_symbol           = "";
   m_tf               = PERIOD_CURRENT;
   m_atrFast          = INVALID_HANDLE;
   m_atrSlow          = INVALID_HANDLE;
   m_adxHandle        = INVALID_HANDLE;
   m_atrFastPeriod    = 14;
   m_atrSlowPeriod    = 50;
   m_adxPeriod        = 14;
   m_adxTrending      = 25.0;
   m_adxRanging       = 20.0;
   m_expansionRatio   = 1.50;
   m_compressionRatio = 0.70;
   m_verbose          = false;
   m_lastBarTime      = 0;
   m_ready            = false;
   m_regime           = SEA_REGIME_UNDEFINED;
   m_previous         = SEA_REGIME_UNDEFINED;
   m_changedThisBar   = false;
   m_adx              = 0.0;
   m_atrFastValue     = 0.0;
   m_atrSlowValue     = 0.0;
   m_insideBarRun     = 0;
  }

//+------------------------------------------------------------------+
bool CRegime::Init(const string symbol,const ENUM_TIMEFRAMES tf,CIndicatorPool &pool,
                   const int atrFastPeriod,const int atrSlowPeriod,const int adxPeriod,
                   const double adxTrending,const double adxRanging,
                   const double expansionRatio,const double compressionRatio)
  {
   m_symbol           = symbol;
   m_tf               = tf;
   m_atrFastPeriod    = (atrFastPeriod<2 ? 2 : (atrFastPeriod>200 ? 200 : atrFastPeriod));
   m_atrSlowPeriod    = (atrSlowPeriod<3 ? 3 : (atrSlowPeriod>500 ? 500 : atrSlowPeriod));
   m_adxPeriod        = (adxPeriod<2 ? 2 : (adxPeriod>200 ? 200 : adxPeriod));
   m_adxTrending      = (adxTrending<20.0 ? 20.0 : (adxTrending>40.0 ? 40.0 : adxTrending));
   m_adxRanging       = (adxRanging<10.0 ? 10.0 : (adxRanging>25.0 ? 25.0 : adxRanging));
   m_expansionRatio   = (expansionRatio<1.1 ? 1.1 : (expansionRatio>3.0 ? 3.0 : expansionRatio));
   m_compressionRatio = (compressionRatio<0.3 ? 0.3 : (compressionRatio>0.9 ? 0.9 : compressionRatio));
   m_ready            = false;
   m_lastBarTime      = 0;

   m_atrFast  = pool.AcquireATR(symbol,tf,m_atrFastPeriod);
   m_atrSlow  = pool.AcquireATR(symbol,tf,m_atrSlowPeriod);
   m_adxHandle= pool.AcquireADX(symbol,tf,m_adxPeriod);

   return(m_atrFast!=INVALID_HANDLE && m_atrSlow!=INVALID_HANDLE && m_adxHandle!=INVALID_HANDLE);
  }

//+------------------------------------------------------------------+
void CRegime::Release(CIndicatorPool &pool)
  {
   if(m_atrFast!=INVALID_HANDLE)
     {
      pool.Release(m_atrFast);
      m_atrFast=INVALID_HANDLE;
     }
   if(m_atrSlow!=INVALID_HANDLE)
     {
      pool.Release(m_atrSlow);
      m_atrSlow=INVALID_HANDLE;
     }
   if(m_adxHandle!=INVALID_HANDLE)
     {
      pool.Release(m_adxHandle);
      m_adxHandle=INVALID_HANDLE;
     }
   m_ready=false;
  }

//+------------------------------------------------------------------+
//| Consecutive inside bars ending at the newest CLOSED bar.          |
//+------------------------------------------------------------------+
int CRegime::CountInsideBars(const MqlRates &r[],const int total) const
  {
   int run=0;
   for(int i=1; i+1<total; i++)
     {
      if(r[i].high<=r[i+1].high && r[i].low>=r[i+1].low)
         run++;
      else
         break;
     }
   return(run);
  }

//+------------------------------------------------------------------+
//| Classify.                                                         |
//|                                                                   |
//| Volatility is checked first because expansion and compression are |
//| statements about displacement, and displacement overrides an ADX  |
//| reading that lags it.                                             |
//+------------------------------------------------------------------+
bool CRegime::Update(const CStructure &structure,const bool force)
  {
   if(m_symbol=="" || m_atrFast==INVALID_HANDLE)
      return(false);

   datetime barTime=(datetime)SeriesInfoInteger(m_symbol,m_tf,SERIES_LASTBAR_DATE);
   if(!force && barTime==m_lastBarTime && m_ready)
     {
      m_changedThisBar=false;
      return(true);
     }

   MqlRates r[];
   if(!SeaCopyRates(m_symbol,m_tf,0,60,r))
      return(false);

   double atrF[],atrS[],adx[];
   if(!SeaCopyBuffer(m_atrFast,0,1,1,atrF))
      return(false);
   if(!SeaCopyBuffer(m_atrSlow,0,1,1,atrS))
      return(false);
   if(!SeaCopyBuffer(m_adxHandle,0,1,1,adx))
      return(false);

   m_atrFastValue = atrF[0];
   m_atrSlowValue = atrS[0];
   m_adx          = adx[0];
   m_insideBarRun = CountInsideBars(r,ArraySize(r));

   ENUM_SEA_REGIME resolved=SEA_REGIME_UNDEFINED;

   if(m_atrSlowValue>0.0)
     {
      double ratio=m_atrFastValue/m_atrSlowValue;

      if(ratio>m_expansionRatio)
         resolved=SEA_REGIME_EXPANSION;
      else
         if(ratio<m_compressionRatio && m_insideBarRun>=2)
            resolved=SEA_REGIME_COMPRESSION;
     }

   if(resolved==SEA_REGIME_UNDEFINED)
     {
      bool directional=(structure.State()==SEA_STRUCT_BULLISH ||
                        structure.State()==SEA_STRUCT_BEARISH);

      if(m_adx>m_adxTrending && directional)
         resolved=SEA_REGIME_TRENDING;
      else
         if(m_adx<m_adxRanging)
            resolved=SEA_REGIME_RANGING;
         else
            resolved=(directional ? SEA_REGIME_TRENDING : SEA_REGIME_RANGING);
     }

   m_changedThisBar=(m_ready && resolved!=m_regime);
   if(m_changedThisBar)
      m_previous=m_regime;

   m_regime      = resolved;
   m_lastBarTime = barTime;
   m_ready       = true;

   if(m_verbose && m_changedThisBar)
      PrintFormat("[CRegime] %s changed %s -> %s",
                  m_symbol,SeaRegimeToString(m_previous),SeaRegimeToString(m_regime));

   return(true);
  }

//+------------------------------------------------------------------+
SRegimeProfile CRegime::Profile(void) const
  {
   return(ProfileFor(m_regime));
  }

//+------------------------------------------------------------------+
//| The regime table, verbatim.                                       |
//|                                                                   |
//|                 Trending   Ranging   Expansion   Compression      |
//| Scale-ins       max        0         1           0                |
//| Add trigger     new BOS    -         pullback    -                |
//| Break-even at   1.0R       0.5R      1.5R        -                |
//| Trail           structural none      ATR x3.0    -                |
//| Stop            zone wick  range ext ATR x2.5    -                |
//| Entries         yes        yes       yes         NO               |
//+------------------------------------------------------------------+
SRegimeProfile CRegime::ProfileFor(const ENUM_SEA_REGIME regime) const
  {
   SRegimeProfile p;
   p.maxScaleIns     = 0;
   p.addOnNewBOS     = false;
   p.addOnPullback   = false;
   p.breakEvenR      = 0.0;
   p.trailStructural = false;
   p.trailATR        = false;
   p.trailATRMult    = 0.0;
   p.stopATRMult     = 0.0;
   p.entriesAllowed  = true;

   switch(regime)
     {
      case SEA_REGIME_TRENDING:
         p.maxScaleIns     = -1;      // style maximum
         p.addOnNewBOS     = true;
         p.breakEvenR      = 1.0;
         p.trailStructural = true;
         break;

      case SEA_REGIME_RANGING:
         p.maxScaleIns = 0;
         p.breakEvenR  = 0.5;
         break;

      case SEA_REGIME_EXPANSION:
         p.maxScaleIns   = 1;
         p.addOnPullback = true;
         p.breakEvenR    = 1.5;
         p.trailATR      = true;
         p.trailATRMult  = 3.0;
         p.stopATRMult   = 2.5;
         break;

      case SEA_REGIME_COMPRESSION:
         p.maxScaleIns    = 0;
         p.entriesAllowed = false;
         break;
     }

   return(p);
  }

//+------------------------------------------------------------------+
string CRegime::Describe(void) const
  {
   return(StringFormat("%s regime=%s adx=%.1f atrFast=%s atrSlow=%s ratio=%.2f inside=%d entries=%s",
                       m_symbol,SeaRegimeToString(m_regime),m_adx,
                       DoubleToString(m_atrFastValue,_Digits),
                       DoubleToString(m_atrSlowValue,_Digits),
                       (m_atrSlowValue>0.0 ? m_atrFastValue/m_atrSlowValue : 0.0),
                       m_insideBarRun,
                       (EntriesAllowed() ? "yes" : "NO")));
  }

#endif // SEA_CREGIME_MQH
//+------------------------------------------------------------------+
