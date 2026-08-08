//+------------------------------------------------------------------+
//|                                                       CPhase.mqh  |
//|                                                                   |
//|   Module 8. Accumulation / manipulation / distribution.           |
//|                                                                   |
//|   MANIPULATION is the strictest test in this EA. It requires the  |
//|   FULL ordered sequence:                                          |
//|                                                                   |
//|     valid accumulation range                                      |
//|       -> wick beyond an edge                                      |
//|       -> CLOSE back inside within InpSweepMaxBars                 |
//|       -> CHoCH in the opposite direction within InpChochWindow    |
//|                                                                   |
//|   A partial sequence returns false. A wick alone is never a       |
//|   sweep. This is what stops the EA buying every dip out of a      |
//|   range that has not actually trapped anyone.                     |
//+------------------------------------------------------------------+
#ifndef SEA_CPHASE_MQH
#define SEA_CPHASE_MQH

#include <SEA/SEA_Common.mqh>
#include <SEA/CStructure.mqh>

//+------------------------------------------------------------------+
//| CPhase                                                            |
//|                                                                   |
//| One instance per (symbol, timeframe).                             |
//+------------------------------------------------------------------+
class CPhase
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   int               m_atrFast;          // ATR(14) handle
   int               m_atrSlow;          // ATR(50) handle
   int               m_adxHandle;
   int               m_atrFastPeriod;
   int               m_atrSlowPeriod;
   int               m_adxPeriod;

   //--- thresholds, all injected, none hard-coded in logic
   double            m_accumATRRatio;    // ATR14 < ATR50 * this
   double            m_accumADXMax;      // ADX below this
   double            m_accumRangeATR;    // containment width in ATR
   int               m_accumMinBars;     // from style / profile
   int               m_sweepMaxBars;     // close back inside within
   int               m_chochWindow;      // CHoCH must follow within

   bool              m_verbose;
   datetime          m_lastBarTime;
   bool              m_ready;

   //--- resolved state
   ENUM_SEA_PHASE    m_phase;
   double            m_rangeHigh;
   double            m_rangeLow;
   double            m_equilibrium;
   int               m_rangeBars;
   bool              m_rangeValid;

   //--- manipulation evidence
   bool              m_sweepConfirmed;
   bool              m_sweepWasHigh;     // true = buy-side liquidity taken
   double            m_sweptLevel;
   datetime          m_sweepTime;
   int               m_sweepBarsAgo;
   ENUM_SEA_DIRECTION m_manipulationDir; // direction the trap points to

   bool              DetectRange(const MqlRates &r[],const int total,
                                 const double atrFast,const double atrSlow,const double adx);
   bool              DetectSweep(const MqlRates &r[],const int total);
   bool              DetectDistribution(CStructure *structure,const double adxNow,
                                        const double adxPrev,const double atrFast,
                                        const double atrSlow) const;

public:
                     CPhase(void);
                    ~CPhase(void) {}

   //! Bind to a symbol and timeframe and take ATR/ADX handles.
   //!
   //! accumATRRatio  0.4..0.95, default 0.70   ATR14 < ATR50 * ratio
   //! accumADXMax    10..30,    default 20
   //! accumRangeATR  0.5..5.0,  default 1.50   containment width
   //! accumMinBars   from CStyle / profile
   //! sweepMaxBars   1..10,     default 3
   //! chochWindow    3..50,     default 12
   bool              Init(const string symbol,const ENUM_TIMEFRAMES tf,CIndicatorPool &pool,
                          const int atrFastPeriod,const int atrSlowPeriod,const int adxPeriod,
                          const double accumATRRatio,const double accumADXMax,
                          const double accumRangeATR,const int accumMinBars,
                          const int sweepMaxBars,const int chochWindow);

   //! Return every handle to the pool.
   void              Release(CIndicatorPool &pool);

   //! Print diagnostics. Off by default.
   void              SetVerbose(const bool enabled) { m_verbose=enabled; }

   //! Update the accumulation minimum after a profile refresh.
   void              SetAccumMinBars(const int bars);

   //! Re-evaluate the phase. Needs CStructure for the CHoCH leg of the
   //! manipulation sequence and for distribution confirmation.
   //! New bar only unless forced.
   bool              Update(CStructure *structure,const bool force=false);

   //! True once a successful Update has run.
   bool              IsReady(void) const { return m_ready; }

   //--- results ---------------------------------------------------------
   //! Current phase.
   ENUM_SEA_PHASE    Phase(void) const { return m_phase; }

   //! True when a valid accumulation range is defined.
   bool              HasRange(void) const { return m_rangeValid; }

   //! Accumulation range high.
   double            RangeHigh(void) const { return m_rangeHigh; }
   //! Accumulation range low.
   double            RangeLow(void) const { return m_rangeLow; }
   //! Accumulation range midpoint.
   double            Equilibrium(void) const { return m_equilibrium; }
   //! Bars the range has held.
   int               RangeBars(void) const { return m_rangeBars; }

   //! GATE 8: true when the full manipulation sequence completed.
   //! A partial sequence is always false.
   bool              SweepConfirmed(void) const { return m_sweepConfirmed; }

   //! Direction the confirmed manipulation points to. NONE when no
   //! sequence completed.
   ENUM_SEA_DIRECTION ManipulationDirection(void) const { return m_manipulationDir; }

   //! Level that was swept, valid only when SweepConfirmed.
   double            SweptLevel(void) const { return m_sweptLevel; }

   //! Bars since the sweep completed.
   int               SweepBarsAgo(void) const { return m_sweepBarsAgo; }

   //! True when the sweep took buy-side (high) liquidity.
   bool              SweepWasHighSide(void) const { return m_sweepWasHigh; }

   //! One-line summary.
   string            Describe(void) const;

   //! Deterministic fingerprint for the repaint test.
   string            Fingerprint(void) const;
  };

//+------------------------------------------------------------------+
CPhase::CPhase(void)
  {
   m_symbol          = "";
   m_tf              = PERIOD_CURRENT;
   m_atrFast         = INVALID_HANDLE;
   m_atrSlow         = INVALID_HANDLE;
   m_adxHandle       = INVALID_HANDLE;
   m_atrFastPeriod   = 14;
   m_atrSlowPeriod   = 50;
   m_adxPeriod       = 14;
   m_accumATRRatio   = 0.70;
   m_accumADXMax     = 20.0;
   m_accumRangeATR   = 1.50;
   m_accumMinBars    = 20;
   m_sweepMaxBars    = 3;
   m_chochWindow     = 12;
   m_verbose         = false;
   m_lastBarTime     = 0;
   m_ready           = false;
   m_phase           = SEA_PHASE_UNDEFINED;
   m_rangeHigh       = 0.0;
   m_rangeLow        = 0.0;
   m_equilibrium     = 0.0;
   m_rangeBars       = 0;
   m_rangeValid      = false;
   m_sweepConfirmed  = false;
   m_sweepWasHigh    = false;
   m_sweptLevel      = 0.0;
   m_sweepTime       = 0;
   m_sweepBarsAgo    = 0;
   m_manipulationDir = SEA_DIR_NONE;
  }

//+------------------------------------------------------------------+
bool CPhase::Init(const string symbol,const ENUM_TIMEFRAMES tf,CIndicatorPool &pool,
                  const int atrFastPeriod,const int atrSlowPeriod,const int adxPeriod,
                  const double accumATRRatio,const double accumADXMax,
                  const double accumRangeATR,const int accumMinBars,
                  const int sweepMaxBars,const int chochWindow)
  {
   m_symbol        = symbol;
   m_tf            = tf;
   m_atrFastPeriod = (atrFastPeriod<2 ? 2 : (atrFastPeriod>200 ? 200 : atrFastPeriod));
   m_atrSlowPeriod = (atrSlowPeriod<3 ? 3 : (atrSlowPeriod>500 ? 500 : atrSlowPeriod));
   m_adxPeriod     = (adxPeriod<2 ? 2 : (adxPeriod>200 ? 200 : adxPeriod));
   m_accumATRRatio = (accumATRRatio<0.40 ? 0.40 : (accumATRRatio>0.95 ? 0.95 : accumATRRatio));
   m_accumADXMax   = (accumADXMax<10.0 ? 10.0 : (accumADXMax>30.0 ? 30.0 : accumADXMax));
   m_accumRangeATR = (accumRangeATR<0.5 ? 0.5 : (accumRangeATR>5.0 ? 5.0 : accumRangeATR));
   m_accumMinBars  = (accumMinBars<5 ? 5 : (accumMinBars>200 ? 200 : accumMinBars));
   m_sweepMaxBars  = (sweepMaxBars<1 ? 1 : (sweepMaxBars>10 ? 10 : sweepMaxBars));
   m_chochWindow   = (chochWindow<3 ? 3 : (chochWindow>50 ? 50 : chochWindow));
   m_ready         = false;
   m_lastBarTime   = 0;

   m_atrFast  = pool.AcquireATR(symbol,tf,m_atrFastPeriod);
   m_atrSlow  = pool.AcquireATR(symbol,tf,m_atrSlowPeriod);
   m_adxHandle= pool.AcquireADX(symbol,tf,m_adxPeriod);

   if(m_atrFast==INVALID_HANDLE || m_atrSlow==INVALID_HANDLE || m_adxHandle==INVALID_HANDLE)
     {
      if(m_verbose)
         PrintFormat("[CPhase] %s: indicator handles unavailable",symbol);
      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
void CPhase::Release(CIndicatorPool &pool)
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
void CPhase::SetAccumMinBars(const int bars)
  {
   int n=(bars<5 ? 5 : (bars>200 ? 200 : bars));
   if(n==m_accumMinBars)
      return;
   m_accumMinBars=n;
   m_lastBarTime=0;
  }

//+------------------------------------------------------------------+
//| Accumulation: contraction plus containment.                       |
//|                                                                   |
//| ATR(14) < ATR(50) * ratio, ADX below the ceiling, and price       |
//| contained within accumRangeATR * ATR for at least accumMinBars    |
//| CLOSED bars.                                                      |
//+------------------------------------------------------------------+
bool CPhase::DetectRange(const MqlRates &r[],const int total,
                         const double atrFast,const double atrSlow,const double adx)
  {
   m_rangeValid=false;
   m_rangeBars=0;

   if(atrFast<=0.0 || atrSlow<=0.0)
      return(false);
   if(atrFast>=atrSlow*m_accumATRRatio)
      return(false);
   if(adx>=m_accumADXMax)
      return(false);

   double maxWidth=atrFast*m_accumRangeATR;
   if(maxWidth<=0.0)
      return(false);

   //--- grow the window backwards from the newest closed bar for as
   //--- long as containment holds
   double hi=r[1].high;
   double lo=r[1].low;
   int    bars=1;

   for(int i=2; i<total; i++)
     {
      double nh=MathMax(hi,r[i].high);
      double nl=MathMin(lo,r[i].low);
      if(nh-nl>maxWidth)
         break;
      hi=nh;
      lo=nl;
      bars++;
     }

   if(bars<m_accumMinBars)
      return(false);

   m_rangeHigh   = hi;
   m_rangeLow    = lo;
   m_equilibrium = (hi+lo)*0.5;
   m_rangeBars   = bars;
   m_rangeValid  = true;
   return(true);
  }

//+------------------------------------------------------------------+
//| The sweep leg of the manipulation sequence.                       |
//|                                                                   |
//| Requires, in order: a wick beyond a range edge, then a CLOSE back |
//| inside the range within m_sweepMaxBars closed bars.               |
//| The CHoCH leg is checked separately in Update, against            |
//| CStructure - this module never infers a break itself.             |
//+------------------------------------------------------------------+
bool CPhase::DetectSweep(const MqlRates &r[],const int total)
  {
   m_sweepConfirmed  = false;
   m_sweepWasHigh    = false;
   m_sweptLevel      = 0.0;
   m_sweepTime       = 0;
   m_sweepBarsAgo    = 0;
   m_manipulationDir = SEA_DIR_NONE;

   if(!m_rangeValid)
      return(false);

   //--- search the closed bars inside the CHoCH window
   int limit=(m_chochWindow<total-1 ? m_chochWindow : total-1);

   for(int i=1; i<=limit; i++)
     {
      //--- high-side sweep: wick above the range high
      if(r[i].high>m_rangeHigh)
        {
         for(int j=i; j>=1 && j>i-m_sweepMaxBars-1; j--)
            if(r[j].close<m_rangeHigh && r[j].close>m_rangeLow)
              {
               m_sweepConfirmed  = true;
               m_sweepWasHigh    = true;
               m_sweptLevel      = m_rangeHigh;
               m_sweepTime       = r[i].time;
               m_sweepBarsAgo    = i-1;
               //--- buy-side liquidity taken traps longs, so the trap
               //--- points DOWN
               m_manipulationDir = SEA_DIR_SHORT;
               return(true);
              }
        }

      //--- low-side sweep: wick below the range low
      if(r[i].low<m_rangeLow)
        {
         for(int j=i; j>=1 && j>i-m_sweepMaxBars-1; j--)
            if(r[j].close>m_rangeLow && r[j].close<m_rangeHigh)
              {
               m_sweepConfirmed  = true;
               m_sweepWasHigh    = false;
               m_sweptLevel      = m_rangeLow;
               m_sweepTime       = r[i].time;
               m_sweepBarsAgo    = i-1;
               m_manipulationDir = SEA_DIR_LONG;
               return(true);
              }
        }
     }

   return(false);
  }

//+------------------------------------------------------------------+
//| Distribution: a confirmed BOS out of the range after a sweep,     |
//| with ADX rising and ATR expanding.                                |
//+------------------------------------------------------------------+
bool CPhase::DetectDistribution(CStructure *structure,const double adxNow,
                                const double adxPrev,const double atrFast,
                                const double atrSlow) const
  {
   if(structure==NULL)
      return(false);
   if(structure.LastBreak()!=SEA_BREAK_BOS)
      return(false);
   if(adxNow<=adxPrev)
      return(false);
   if(atrFast<=atrSlow)
      return(false);

   //--- the break must have left the accumulation range
   if(m_rangeValid)
     {
      double level=structure.LastBreakLevel();
      if(level<=m_rangeHigh && level>=m_rangeLow)
         return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
bool CPhase::Update(CStructure *structure,const bool force)
  {
   if(structure==NULL)
      return(false);
   if(m_symbol=="" || m_atrFast==INVALID_HANDLE)
      return(false);

   datetime barTime=(datetime)SeriesInfoInteger(m_symbol,m_tf,SERIES_LASTBAR_DATE);
   if(!force && barTime==m_lastBarTime && m_ready)
      return(true);

   int need=m_accumMinBars+m_chochWindow+m_sweepMaxBars+20;
   MqlRates r[];
   if(!SeaCopyRates(m_symbol,m_tf,0,need,r))
      return(false);

   double atrF[],atrS[],adx[];
   if(!SeaCopyBuffer(m_atrFast,0,1,1,atrF))
      return(false);
   if(!SeaCopyBuffer(m_atrSlow,0,1,1,atrS))
      return(false);
   if(!SeaCopyBuffer(m_adxHandle,0,1,2,adx))
      return(false);

   int total=ArraySize(r);

   bool inRange=DetectRange(r,total,atrF[0],atrS[0],adx[0]);

   //--- default to whatever the structure says when no range exists
   m_phase=SEA_PHASE_UNDEFINED;

   if(inRange)
     {
      m_phase=SEA_PHASE_ACCUMULATION;

      //--- leg 2 and 3: sweep with a close back inside
      if(DetectSweep(r,total))
        {
         //--- leg 4: a CHoCH in the trap direction, inside the window
         bool chochOk=(structure.LastBreak()==SEA_BREAK_CHOCH &&
                       structure.LastBreakDirection()==m_manipulationDir &&
                       structure.BarsSinceBreak()<=m_chochWindow &&
                       structure.LastBreakTime()>=m_sweepTime);

         if(chochOk)
            m_phase=SEA_PHASE_MANIPULATION;
         else
           {
            //--- PARTIAL SEQUENCE. Not manipulation. The sweep evidence
            //--- is discarded so GATE 8 cannot be satisfied by it.
            m_sweepConfirmed  = false;
            m_manipulationDir = SEA_DIR_NONE;
           }
        }
     }

   //--- distribution overrides, since it is what a completed range does
   if(DetectDistribution(structure,adx[0],adx[1],atrF[0],atrS[0]))
     {
      m_phase=SEA_PHASE_DISTRIBUTION;
      //--- phase resets to ACCUMULATION when a new contraction forms,
      //--- which happens naturally on the next DetectRange success
     }

   m_lastBarTime = barTime;
   m_ready       = true;

   if(m_verbose)
      PrintFormat("[CPhase] %s",Describe());

   return(true);
  }

//+------------------------------------------------------------------+
string CPhase::Describe(void) const
  {
   return(StringFormat("%s phase=%s range=%s[%s..%s] bars=%d sweep=%s dir=%s ago=%d",
                       m_symbol,SeaPhaseToString(m_phase),
                       (m_rangeValid ? "yes" : "no"),
                       (m_rangeValid ? DoubleToString(m_rangeLow,_Digits)  : "-"),
                       (m_rangeValid ? DoubleToString(m_rangeHigh,_Digits) : "-"),
                       m_rangeBars,
                       (m_sweepConfirmed ? "CONFIRMED" : "no"),
                       SeaDirectionToString(m_manipulationDir),
                       m_sweepBarsAgo));
  }

//+------------------------------------------------------------------+
string CPhase::Fingerprint(void) const
  {
   return(StringFormat("%s|%d|%d|%s|%s|%d|%d|%d",
                       m_symbol,(int)m_tf,(int)m_phase,
                       DoubleToString(m_rangeLow,8),
                       DoubleToString(m_rangeHigh,8),
                       m_rangeBars,
                       (m_sweepConfirmed ? 1 : 0),
                       (int)m_manipulationDir));
  }

#endif // SEA_CPHASE_MQH
//+------------------------------------------------------------------+
