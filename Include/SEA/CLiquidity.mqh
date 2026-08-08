//+------------------------------------------------------------------+
//|                                                   CLiquidity.mqh  |
//|                                                                   |
//|   Module 7. Where the stops are.                                  |
//|                                                                   |
//|   Equal highs and lows, previous day and week extremes, and the   |
//|   sweeps that take them. A sweep is a WICK beyond a level with a  |
//|   CLOSE back inside - if the bar closes beyond, that is a break   |
//|   and belongs to CStructure, not here.                            |
//|                                                                   |
//|   This module never generates an entry. It supplies targets and   |
//|   the sweep evidence CPhase needs to confirm manipulation.        |
//|                                                                   |
//|   RULE 10: daily and weekly timeframes arrive as parameters.      |
//+------------------------------------------------------------------+
#ifndef SEA_CLIQUIDITY_MQH
#define SEA_CLIQUIDITY_MQH

#include <SEA/SEA_Common.mqh>

#define SEA_MAX_LIQUIDITY 96

//+------------------------------------------------------------------+
//| CLiquidity                                                        |
//|                                                                   |
//| One instance per (symbol, timeframe).                             |
//+------------------------------------------------------------------+
class CLiquidity
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   ENUM_TIMEFRAMES   m_dayTF;
   ENUM_TIMEFRAMES   m_weekTF;
   int               m_lookback;
   double            m_equalTolerance;   // as a fraction of ATR
   int               m_atrHandle;
   int               m_atrPeriod;
   int               m_sweepMaxBars;     // InpSweepMaxBars, close back inside within
   bool              m_verbose;
   datetime          m_lastBarTime;
   bool              m_ready;

   SLiquidity        m_levels[];
   int               m_levelCount;

   //--- session extremes
   double            m_pdh,m_pdl,m_pwh,m_pwl;
   bool              m_haveDaily,m_haveWeekly;

   bool              AddLevel(const double price,const datetime time,const bool isHigh,
                              const int touches,const double strength);
   void              DetectEqualLevels(const MqlRates &r[],const int total,const double atr);
   void              DetectSessionLevels(void);
   void              DetectSweeps(const MqlRates &r[],const int total);

public:
                     CLiquidity(void);
                    ~CLiquidity(void);

   //! Bind to a symbol and timeframe.
   //! dayTF and weekTF come from CStyle - this module may not name a
   //! PERIOD_ constant.
   //! equalTolerance is the ATR fraction within which two extremes count
   //! as equal. Documented range 0.02..0.50, default 0.10.
   bool              Init(const string symbol,const ENUM_TIMEFRAMES tf,CIndicatorPool &pool,
                          const ENUM_TIMEFRAMES dayTF,const ENUM_TIMEFRAMES weekTF,
                          const double equalTolerance,const int sweepMaxBars,
                          const int atrPeriod,const int lookback);

   //! Return the ATR handle to the pool.
   void              Release(CIndicatorPool &pool);

   //! Print diagnostics. Off by default.
   void              SetVerbose(const bool enabled) { m_verbose=enabled; }

   //! Rebuild levels and sweep flags. New bar only unless forced.
   bool              Update(const bool force=false);

   //! True once a successful Update has run.
   bool              IsReady(void) const { return m_ready; }

   //! Number of liquidity levels held.
   int               Count(void) const { return m_levelCount; }

   //! Copy out a level by index.
   bool              Get(const int index,SLiquidity &out) const;

   //--- session extremes -----------------------------------------------
   //! Previous day high. Returns false when daily history is missing.
   bool              PreviousDayHigh(double &price) const;
   //! Previous day low.
   bool              PreviousDayLow(double &price) const;
   //! Previous week high.
   bool              PreviousWeekHigh(double &price) const;
   //! Previous week low.
   bool              PreviousWeekLow(double &price) const;

   //--- queries ----------------------------------------------------------
   //! Nearest UNSWEPT liquidity above the price. This is the natural
   //! target for a long and the natural stop-hunt zone for a short.
   bool              NearestUnsweptAbove(const double price,SLiquidity &out) const;

   //! Nearest UNSWEPT liquidity below the price.
   bool              NearestUnsweptBelow(const double price,SLiquidity &out) const;

   //! Nearest opposing liquidity for a direction - the target used by
   //! GATE 6 to measure reward.
   bool              TargetFor(const double price,const ENUM_SEA_DIRECTION dir,SLiquidity &out) const;

   //! True when unswept liquidity exists beyond a level in a direction.
   //! Feeds the breakout hypothesis in CProbabilityMap.
   bool              UnsweptBeyond(const double level,const ENUM_SEA_DIRECTION dir) const;

   //! True when a sweep completed within the last `withinBars` closed
   //! bars on the given side. CPhase requires this before it will call
   //! a sequence MANIPULATION.
   bool              RecentSweep(const bool highSide,const int withinBars,
                                 double &sweptLevel,datetime &sweptTime) const;

   //! Count of levels still unswept.
   int               UnsweptCount(void) const;

   //! One-line summary.
   string            Describe(void) const;
  };

//+------------------------------------------------------------------+
CLiquidity::CLiquidity(void)
  {
   m_symbol         = "";
   m_tf             = PERIOD_CURRENT;
   m_dayTF          = PERIOD_CURRENT;
   m_weekTF         = PERIOD_CURRENT;
   m_lookback       = 300;
   m_equalTolerance = 0.10;
   m_atrHandle      = INVALID_HANDLE;
   m_atrPeriod      = 14;
   m_sweepMaxBars   = 3;
   m_verbose        = false;
   m_lastBarTime    = 0;
   m_ready          = false;
   m_levelCount     = 0;
   m_pdh=0.0; m_pdl=0.0; m_pwh=0.0; m_pwl=0.0;
   m_haveDaily=false;
   m_haveWeekly=false;
   ArrayResize(m_levels,SEA_MAX_LIQUIDITY);
  }

//+------------------------------------------------------------------+
CLiquidity::~CLiquidity(void)
  {
   ArrayFree(m_levels);
  }

//+------------------------------------------------------------------+
bool CLiquidity::Init(const string symbol,const ENUM_TIMEFRAMES tf,CIndicatorPool &pool,
                      const ENUM_TIMEFRAMES dayTF,const ENUM_TIMEFRAMES weekTF,
                      const double equalTolerance,const int sweepMaxBars,
                      const int atrPeriod,const int lookback)
  {
   m_symbol         = symbol;
   m_tf             = tf;
   m_dayTF          = dayTF;
   m_weekTF         = weekTF;
   m_equalTolerance = (equalTolerance<0.02 ? 0.02 : (equalTolerance>0.50 ? 0.50 : equalTolerance));
   m_sweepMaxBars   = (sweepMaxBars<1 ? 1 : (sweepMaxBars>20 ? 20 : sweepMaxBars));
   m_atrPeriod      = (atrPeriod<2 ? 2 : (atrPeriod>200 ? 200 : atrPeriod));
   m_lookback       = (lookback<60 ? 60 : (lookback>3000 ? 3000 : lookback));
   m_levelCount     = 0;
   m_ready          = false;
   m_lastBarTime    = 0;

   m_atrHandle=pool.AcquireATR(symbol,tf,m_atrPeriod);
   if(m_atrHandle==INVALID_HANDLE)
      return(false);

   int available=SeaAvailableBars(symbol,tf);
   if(available<60)
      return(false);
   if(available<m_lookback)
      m_lookback=available;

   return(Update(true));
  }

//+------------------------------------------------------------------+
void CLiquidity::Release(CIndicatorPool &pool)
  {
   if(m_atrHandle!=INVALID_HANDLE)
     {
      pool.Release(m_atrHandle);
      m_atrHandle=INVALID_HANDLE;
     }
   m_ready=false;
  }

//+------------------------------------------------------------------+
bool CLiquidity::AddLevel(const double price,const datetime time,const bool isHigh,
                          const int touches,const double strength)
  {
   if(m_levelCount>=SEA_MAX_LIQUIDITY)
      return(false);

   m_levels[m_levelCount].price      = price;
   m_levels[m_levelCount].time       = time;
   m_levels[m_levelCount].isHigh     = isHigh;
   m_levels[m_levelCount].swept      = false;
   m_levels[m_levelCount].touchCount = touches;
   m_levels[m_levelCount].strength   = strength;
   m_levelCount++;
   return(true);
  }

//+------------------------------------------------------------------+
//| Equal highs and equal lows.                                       |
//|                                                                   |
//| Two or more extremes within m_equalTolerance * ATR of each other  |
//| form a pool. More touches means more resting orders, so strength  |
//| scales with the touch count.                                      |
//+------------------------------------------------------------------+
void CLiquidity::DetectEqualLevels(const MqlRates &r[],const int total,const double atr)
  {
   if(atr<=0.0)
      return;

   double tol=atr*m_equalTolerance;
   if(tol<=0.0)
      return;

   //--- highs
   for(int i=1; i<total-1 && m_levelCount<SEA_MAX_LIQUIDITY; i++)
     {
      //--- local high over a 2-bar window on each side
      if(i-1<1 || i+1>=total)
         continue;
      if(r[i].high<r[i-1].high || r[i].high<r[i+1].high)
         continue;

      //--- already covered by a recorded pool?
      bool covered=false;
      for(int k=0; k<m_levelCount; k++)
         if(m_levels[k].isHigh && MathAbs(m_levels[k].price-r[i].high)<=tol)
           {
            covered=true;
            break;
           }
      if(covered)
         continue;

      //--- count matching extremes further back
      int      touches=1;
      datetime newest=r[i].time;
      for(int j=i+1; j<total-1; j++)
        {
         if(j-1<1)
            continue;
         if(r[j].high<r[j-1].high || r[j].high<r[j+1].high)
            continue;
         if(MathAbs(r[j].high-r[i].high)<=tol)
            touches++;
        }

      if(touches>=2)
         AddLevel(r[i].high,newest,true,touches,
                  MathMin(1.0,(double)touches/4.0));
     }

   //--- lows
   for(int i=1; i<total-1 && m_levelCount<SEA_MAX_LIQUIDITY; i++)
     {
      if(i-1<1 || i+1>=total)
         continue;
      if(r[i].low>r[i-1].low || r[i].low>r[i+1].low)
         continue;

      bool covered=false;
      for(int k=0; k<m_levelCount; k++)
         if(!m_levels[k].isHigh && MathAbs(m_levels[k].price-r[i].low)<=tol)
           {
            covered=true;
            break;
           }
      if(covered)
         continue;

      int      touches=1;
      datetime newest=r[i].time;
      for(int j=i+1; j<total-1; j++)
        {
         if(j-1<1)
            continue;
         if(r[j].low>r[j-1].low || r[j].low>r[j+1].low)
            continue;
         if(MathAbs(r[j].low-r[i].low)<=tol)
            touches++;
        }

      if(touches>=2)
         AddLevel(r[i].low,newest,false,touches,
                  MathMin(1.0,(double)touches/4.0));
     }
  }

//+------------------------------------------------------------------+
//| Previous day and week extremes.                                   |
//|                                                                   |
//| Shift 1 is the last CLOSED daily/weekly bar - shift 0 is today,   |
//| still forming, and is never used.                                 |
//+------------------------------------------------------------------+
void CLiquidity::DetectSessionLevels(void)
  {
   m_haveDaily=false;
   m_haveWeekly=false;

   MqlRates d[];
   if(SeaCopyRates(m_symbol,m_dayTF,1,1,d))
     {
      m_pdh=d[0].high;
      m_pdl=d[0].low;
      m_haveDaily=true;
      AddLevel(m_pdh,d[0].time,true,1,0.85);
      AddLevel(m_pdl,d[0].time,false,1,0.85);
     }

   MqlRates w[];
   if(SeaCopyRates(m_symbol,m_weekTF,1,1,w))
     {
      m_pwh=w[0].high;
      m_pwl=w[0].low;
      m_haveWeekly=true;
      AddLevel(m_pwh,w[0].time,true,1,1.00);
      AddLevel(m_pwl,w[0].time,false,1,1.00);
     }
  }

//+------------------------------------------------------------------+
//| Mark levels that have been swept.                                 |
//|                                                                   |
//| A SWEEP is: a wick beyond the level, then a CLOSE back inside     |
//| within m_sweepMaxBars closed bars.                                |
//| A bar that CLOSES beyond and stays there is a break, not a sweep, |
//| and the level is simply consumed - also marked swept, since the   |
//| resting orders are gone either way.                               |
//+------------------------------------------------------------------+
void CLiquidity::DetectSweeps(const MqlRates &r[],const int total)
  {
   for(int k=0; k<m_levelCount; k++)
     {
      m_levels[k].swept=false;

      for(int i=total-1; i>=1; i--)
        {
         if(r[i].time<=m_levels[k].time && m_levels[k].time!=0)
            continue;   // bar predates the level

         if(m_levels[k].isHigh)
           {
            if(r[i].high<=m_levels[k].price)
               continue;

            //--- wicked above: did a close come back under within the window?
            for(int j=i; j>=1 && j>i-m_sweepMaxBars-1; j--)
               if(r[j].close<m_levels[k].price)
                 {
                  m_levels[k].swept=true;
                  break;
                 }

            //--- closed above and never returned: consumed
            if(!m_levels[k].swept && r[i].close>m_levels[k].price)
               m_levels[k].swept=true;
           }
         else
           {
            if(r[i].low>=m_levels[k].price)
               continue;

            for(int j=i; j>=1 && j>i-m_sweepMaxBars-1; j--)
               if(r[j].close>m_levels[k].price)
                 {
                  m_levels[k].swept=true;
                  break;
                 }

            if(!m_levels[k].swept && r[i].close<m_levels[k].price)
               m_levels[k].swept=true;
           }

         if(m_levels[k].swept)
            break;
        }
     }
  }

//+------------------------------------------------------------------+
bool CLiquidity::Update(const bool force)
  {
   if(m_symbol=="" || m_atrHandle==INVALID_HANDLE)
      return(false);

   datetime barTime=(datetime)SeriesInfoInteger(m_symbol,m_tf,SERIES_LASTBAR_DATE);
   if(!force && barTime==m_lastBarTime && m_ready)
      return(true);

   MqlRates r[];
   if(!SeaCopyRates(m_symbol,m_tf,0,m_lookback,r))
      return(false);

   double atr[];
   if(!SeaCopyBuffer(m_atrHandle,0,1,1,atr))
      return(false);

   int total=ArraySize(r);
   m_levelCount=0;

   DetectSessionLevels();
   DetectEqualLevels(r,total,atr[0]);
   DetectSweeps(r,total);

   m_lastBarTime = barTime;
   m_ready       = true;

   if(m_verbose)
      PrintFormat("[CLiquidity] %s",Describe());

   return(true);
  }

//+------------------------------------------------------------------+
bool CLiquidity::Get(const int index,SLiquidity &out) const
  {
   if(index<0 || index>=m_levelCount)
      return(false);
   out=m_levels[index];
   return(true);
  }

//+------------------------------------------------------------------+
bool CLiquidity::PreviousDayHigh(double &price) const
  {
   price=m_pdh;
   return(m_haveDaily);
  }

bool CLiquidity::PreviousDayLow(double &price) const
  {
   price=m_pdl;
   return(m_haveDaily);
  }

bool CLiquidity::PreviousWeekHigh(double &price) const
  {
   price=m_pwh;
   return(m_haveWeekly);
  }

bool CLiquidity::PreviousWeekLow(double &price) const
  {
   price=m_pwl;
   return(m_haveWeekly);
  }

//+------------------------------------------------------------------+
bool CLiquidity::NearestUnsweptAbove(const double price,SLiquidity &out) const
  {
   int    best=-1;
   double bestDist=0.0;

   for(int i=0; i<m_levelCount; i++)
     {
      if(m_levels[i].swept)
         continue;
      if(m_levels[i].price<=price)
         continue;

      double d=m_levels[i].price-price;
      if(best<0 || d<bestDist)
        {
         best=i;
         bestDist=d;
        }
     }

   if(best<0)
      return(false);
   out=m_levels[best];
   return(true);
  }

//+------------------------------------------------------------------+
bool CLiquidity::NearestUnsweptBelow(const double price,SLiquidity &out) const
  {
   int    best=-1;
   double bestDist=0.0;

   for(int i=0; i<m_levelCount; i++)
     {
      if(m_levels[i].swept)
         continue;
      if(m_levels[i].price>=price)
         continue;

      double d=price-m_levels[i].price;
      if(best<0 || d<bestDist)
        {
         best=i;
         bestDist=d;
        }
     }

   if(best<0)
      return(false);
   out=m_levels[best];
   return(true);
  }

//+------------------------------------------------------------------+
bool CLiquidity::TargetFor(const double price,const ENUM_SEA_DIRECTION dir,SLiquidity &out) const
  {
   if(dir==SEA_DIR_LONG)
      return(NearestUnsweptAbove(price,out));
   if(dir==SEA_DIR_SHORT)
      return(NearestUnsweptBelow(price,out));
   return(false);
  }

//+------------------------------------------------------------------+
bool CLiquidity::UnsweptBeyond(const double level,const ENUM_SEA_DIRECTION dir) const
  {
   for(int i=0; i<m_levelCount; i++)
     {
      if(m_levels[i].swept)
         continue;
      if(dir==SEA_DIR_LONG && m_levels[i].price>level)
         return(true);
      if(dir==SEA_DIR_SHORT && m_levels[i].price<level)
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
bool CLiquidity::RecentSweep(const bool highSide,const int withinBars,
                             double &sweptLevel,datetime &sweptTime) const
  {
   sweptLevel=0.0;
   sweptTime=0;

   MqlRates r[];
   int need=(withinBars<1 ? 1 : withinBars)+m_sweepMaxBars+2;
   if(!SeaCopyRates(m_symbol,m_tf,0,need,r))
      return(false);

   int total=ArraySize(r);

   for(int k=0; k<m_levelCount; k++)
     {
      if(m_levels[k].isHigh!=highSide)
         continue;
      if(!m_levels[k].swept)
         continue;

      //--- was the sweep inside the window of closed bars?
      for(int i=1; i<total && i<=withinBars+m_sweepMaxBars; i++)
        {
         bool wicked=(highSide ? (r[i].high>m_levels[k].price)
                      : (r[i].low<m_levels[k].price));
         if(!wicked)
            continue;

         bool reclaimed=false;
         for(int j=i; j>=1 && j>i-m_sweepMaxBars-1; j--)
           {
            if(highSide && r[j].close<m_levels[k].price)
              {
               reclaimed=true;
               break;
              }
            if(!highSide && r[j].close>m_levels[k].price)
              {
               reclaimed=true;
               break;
              }
           }

         if(reclaimed)
           {
            sweptLevel=m_levels[k].price;
            sweptTime=r[i].time;
            return(true);
           }
        }
     }

   return(false);
  }

//+------------------------------------------------------------------+
int CLiquidity::UnsweptCount(void) const
  {
   int n=0;
   for(int i=0; i<m_levelCount; i++)
      if(!m_levels[i].swept)
         n++;
   return(n);
  }

//+------------------------------------------------------------------+
string CLiquidity::Describe(void) const
  {
   return(StringFormat("%s levels=%d unswept=%d PDH/PDL=%s/%s PWH/PWL=%s/%s",
                       m_symbol,m_levelCount,UnsweptCount(),
                       (m_haveDaily  ? DoubleToString(m_pdh,_Digits) : "-"),
                       (m_haveDaily  ? DoubleToString(m_pdl,_Digits) : "-"),
                       (m_haveWeekly ? DoubleToString(m_pwh,_Digits) : "-"),
                       (m_haveWeekly ? DoubleToString(m_pwl,_Digits) : "-")));
  }

#endif // SEA_CLIQUIDITY_MQH
//+------------------------------------------------------------------+
