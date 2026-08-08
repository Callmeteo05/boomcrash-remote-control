//+------------------------------------------------------------------+
//|                                                   CStructure.mqh  |
//|                                                                   |
//|   Module 5. THE SIGNAL AUTHORITY.                                 |
//|                                                                   |
//|   CStructure is the sole source of trade signals. No other module |
//|   may generate an entry. Everything downstream either filters,    |
//|   sizes or times what is decided here.                            |
//|                                                                   |
//|   One instance per (symbol, timeframe).                           |
//|                                                                   |
//|   RULE 1: every read is on a CLOSED bar. shift >= 1 throughout.   |
//|   Index 0 never appears. The full state is recomputed from        |
//|   scratch on each new bar, so two runs over identical history     |
//|   produce identical output.                                       |
//+------------------------------------------------------------------+
#ifndef SEA_CSTRUCTURE_MQH
#define SEA_CSTRUCTURE_MQH

#include <SEA/SEA_Common.mqh>

//--- storage ceilings, sized so a full lookback always fits
#define SEA_MAX_SWINGS       128
#define SEA_STRUCT_MIN_BARS   50

//+------------------------------------------------------------------+
//| CStructure                                                        |
//+------------------------------------------------------------------+
class CStructure
  {
private:
   string                m_symbol;
   ENUM_TIMEFRAMES       m_tf;
   int                   m_fractalBars;    // N, from the symbol profile
   int                   m_staleBars;      // no break within this many = RANGING
   int                   m_lookback;       // bars scanned per rebuild
   bool                  m_verbose;

   datetime              m_lastBarTime;    // guards recompute-on-new-bar-only
   bool                  m_ready;

   //--- confirmed swings, newest first
   SSwing                m_swings[];
   int                   m_swingCount;

   //--- resolved state
   ENUM_SEA_STRUCT_STATE m_state;
   ENUM_SEA_BREAK_TYPE   m_lastBreak;
   ENUM_SEA_DIRECTION    m_lastBreakDir;
   datetime              m_lastBreakTime;
   int                   m_barsSinceBreak;
   double                m_lastBreakLevel;

   //--- dealing range
   double                m_rangeHigh;
   double                m_rangeLow;
   datetime              m_rangeHighTime;
   datetime              m_rangeLowTime;
   bool                  m_rangeValid;

   //--- internals
   bool                  IsFractalHigh(const MqlRates &r[],const int i,const int total) const;
   bool                  IsFractalLow(const MqlRates &r[],const int i,const int total) const;
   void                  AddSwing(const bool isHigh,const double price,
                                  const datetime time,const int shift);
   void                  ResolveState(const MqlRates &r[],const int total);
   void                  ResolveRange(void);
   void                  Reset(void);

public:
                     CStructure(void);
                    ~CStructure(void);

   //--- setup ----------------------------------------------------------
   //! Bind this instance to a symbol and timeframe.
   //! fractalBars comes from the symbol profile (3 clean .. 7 noisy).
   //! staleBars is InpStructureStaleBars, default 50.
   //! Returns false when the series has too little history.
   bool                  Init(const string symbol,const ENUM_TIMEFRAMES tf,
                              const int fractalBars,const int staleBars,
                              const int lookback);

   //! Print diagnostics. Off by default.
   void                  SetVerbose(const bool enabled) { m_verbose=enabled; }

   //! Change the fractal width after a profile update. Forces a rebuild.
   void                  SetFractalBars(const int bars);

   //--- update ---------------------------------------------------------
   //! Recompute swings, state and range. Does nothing unless a new bar
   //! has closed, unless force is true.
   //! Returns false when the series is unsynchronised - that is a SKIP
   //! AND RETRY, not "no signal".
   bool                  Update(const bool force=false);

   //! True once a successful Update has produced usable state.
   bool                  IsReady(void) const { return m_ready; }

   //! Bound symbol.
   string                Symbol(void) const { return m_symbol; }

   //! Bound timeframe.
   ENUM_TIMEFRAMES       Timeframe(void) const { return m_tf; }

   //--- structure ------------------------------------------------------
   //! Current structural state.
   ENUM_SEA_STRUCT_STATE State(void) const { return m_state; }

   //! Directional bias implied by the state. RANGING yields NONE.
   ENUM_SEA_DIRECTION    Bias(void) const;

   //! The last structural break: BOS, CHoCH or NONE.
   ENUM_SEA_BREAK_TYPE   LastBreak(void) const { return m_lastBreak; }

   //! Direction of the last break.
   ENUM_SEA_DIRECTION    LastBreakDirection(void) const { return m_lastBreakDir; }

   //! Bar time of the last break.
   datetime              LastBreakTime(void) const { return m_lastBreakTime; }

   //! Price level that was broken.
   double                LastBreakLevel(void) const { return m_lastBreakLevel; }

   //! Bars elapsed since the last break. Large means stale.
   int                   BarsSinceBreak(void) const { return m_barsSinceBreak; }

   //--- swings ---------------------------------------------------------
   //! Number of confirmed swings held.
   int                   SwingCount(void) const { return m_swingCount; }

   //! Copy out a confirmed swing. Index 0 is the most recent.
   bool                  GetSwing(const int index,SSwing &out) const;

   //! Most recent confirmed swing high. Returns false when none.
   bool                  LastSwingHigh(SSwing &out) const;

   //! Most recent confirmed swing low. Returns false when none.
   bool                  LastSwingLow(SSwing &out) const;

   //! Most recent confirmed swing on the given side, skipping `skip`
   //! matches. Used to find the counter-trend swing a CHoCH breaks.
   bool                  NthSwing(const bool isHigh,const int skip,SSwing &out) const;

   //! Structural invalidation level for a direction: the swing beyond
   //! which the idea is simply wrong. Returns false when undefinable -
   //! GATE 5 then fails and no trade is taken.
   bool                  InvalidationLevel(const ENUM_SEA_DIRECTION dir,double &level) const;

   //--- dealing range ---------------------------------------------------
   //! True when a dealing range is defined.
   bool                  HasRange(void) const { return m_rangeValid; }

   //! High of the current dealing range.
   double                RangeHigh(void) const { return m_rangeHigh; }

   //! Low of the current dealing range.
   double                RangeLow(void) const { return m_rangeLow; }

   //! Midpoint of the dealing range.
   double                Equilibrium(void) const;

   //! Position of a price within the range: 0.0 at the low, 1.0 at the
   //! high. Returns -1.0 when no range is defined.
   double                RangePosition(const double price) const;

   //! True when the price sits below equilibrium.
   bool                  IsDiscount(const double price) const;

   //! True when the price sits above equilibrium.
   bool                  IsPremium(const double price) const;

   //! True when the price sits in the 0.618-0.79 optimal trade entry
   //! band, measured from the side the direction retraces from.
   bool                  IsOTE(const double price,const ENUM_SEA_DIRECTION dir) const;

   //! Price bounds of the OTE band for a direction.
   bool                  OTEBounds(const ENUM_SEA_DIRECTION dir,double &lower,double &upper) const;

   //--- price action triggers -------------------------------------------
   //! Detect a price action trigger on a CLOSED bar.
   //!
   //! shift must be >= 1. Passing 0 returns NONE and logs, because a
   //! forming candle cannot confirm anything.
   //!
   //! Bullish set (mirrored for bearish):
   //!   rejection wick   lower wick >= 60% of range, close in upper third
   //!   engulfing        body engulfs the prior bearish body
   //!   inside break     inside bar, then close above its high
   //!   momentum close   close > 75% of range, body >= 1.2x average body
   ENUM_SEA_TRIGGER      DetectTrigger(const ENUM_SEA_DIRECTION dir,const int shift=1) const;

   //--- diagnostics -------------------------------------------------------
   //! One-line state summary for the journal and dashboard.
   string                Describe(void) const;

   //! Deterministic fingerprint of the resolved state. Two runs over
   //! identical history must produce identical strings - this is what
   //! the repaint test compares.
   string                Fingerprint(void) const;
  };

//+------------------------------------------------------------------+
CStructure::CStructure(void)
  {
   m_symbol      = "";
   m_tf          = PERIOD_CURRENT;
   m_fractalBars = 3;
   m_staleBars   = 50;
   m_lookback    = 500;
   m_verbose     = false;
   m_lastBarTime = 0;
   m_ready       = false;
   m_swingCount  = 0;
   ArrayResize(m_swings,SEA_MAX_SWINGS);
   Reset();
  }

//+------------------------------------------------------------------+
CStructure::~CStructure(void)
  {
   ArrayFree(m_swings);
  }

//+------------------------------------------------------------------+
void CStructure::Reset(void)
  {
   m_swingCount     = 0;
   m_state          = SEA_STRUCT_UNKNOWN;
   m_lastBreak      = SEA_BREAK_NONE;
   m_lastBreakDir   = SEA_DIR_NONE;
   m_lastBreakTime  = 0;
   m_lastBreakLevel = 0.0;
   m_barsSinceBreak = 0;
   m_rangeHigh      = 0.0;
   m_rangeLow       = 0.0;
   m_rangeHighTime  = 0;
   m_rangeLowTime   = 0;
   m_rangeValid     = false;
  }

//+------------------------------------------------------------------+
bool CStructure::Init(const string symbol,const ENUM_TIMEFRAMES tf,
                      const int fractalBars,const int staleBars,
                      const int lookback)
  {
   m_symbol      = symbol;
   m_tf          = tf;
   m_fractalBars = (fractalBars<2 ? 2 : (fractalBars>15 ? 15 : fractalBars));
   m_staleBars   = (staleBars<5 ? 5 : (staleBars>500 ? 500 : staleBars));
   m_lookback    = (lookback<SEA_STRUCT_MIN_BARS ? SEA_STRUCT_MIN_BARS
                    : (lookback>5000 ? 5000 : lookback));
   m_lastBarTime = 0;
   m_ready       = false;
   Reset();

   int available=SeaAvailableBars(symbol,tf);
   if(available<SEA_STRUCT_MIN_BARS)
     {
      if(m_verbose)
         PrintFormat("[CStructure] %s: only %d bars available, need %d",
                     symbol,available,SEA_STRUCT_MIN_BARS);
      return(false);
     }

   if(available<m_lookback)
      m_lookback=available;

   return(Update(true));
  }

//+------------------------------------------------------------------+
void CStructure::SetFractalBars(const int bars)
  {
   int n=(bars<2 ? 2 : (bars>15 ? 15 : bars));
   if(n==m_fractalBars)
      return;
   m_fractalBars=n;
   m_lastBarTime=0;   // force a rebuild on the next Update
  }

//+------------------------------------------------------------------+
//| Fractal tests. r[] is series-indexed: r[0] is the newest bar.     |
//| A fractal at i needs m_fractalBars bars on BOTH sides.            |
//+------------------------------------------------------------------+
bool CStructure::IsFractalHigh(const MqlRates &r[],const int i,const int total) const
  {
   if(i-m_fractalBars<1 || i+m_fractalBars>=total)
      return(false);

   double pivot=r[i].high;
   for(int k=1; k<=m_fractalBars; k++)
     {
      if(r[i-k].high>=pivot)
         return(false);
      if(r[i+k].high>=pivot)
         return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
bool CStructure::IsFractalLow(const MqlRates &r[],const int i,const int total) const
  {
   if(i-m_fractalBars<1 || i+m_fractalBars>=total)
      return(false);

   double pivot=r[i].low;
   for(int k=1; k<=m_fractalBars; k++)
     {
      if(r[i-k].low<=pivot)
         return(false);
      if(r[i+k].low<=pivot)
         return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Append a confirmed swing. Newest ends up at index 0 because the   |
//| scan walks from newest to oldest.                                 |
//+------------------------------------------------------------------+
void CStructure::AddSwing(const bool isHigh,const double price,
                          const datetime time,const int shift)
  {
   if(m_swingCount>=SEA_MAX_SWINGS)
      return;

   m_swings[m_swingCount].isHigh    = isHigh;
   m_swings[m_swingCount].price     = price;
   m_swings[m_swingCount].time      = time;
   m_swings[m_swingCount].shift     = shift;
   m_swings[m_swingCount].confirmed = true;
   m_swings[m_swingCount].swept     = false;
   m_swingCount++;
  }

//+------------------------------------------------------------------+
//| Resolve BOS / CHoCH and the resulting state.                      |
//|                                                                   |
//| Walks forward in time over closed bars. A break requires a bar to |
//| CLOSE beyond the swing - a wick through it is a sweep, not a      |
//| break, and is left for CLiquidity to interpret.                   |
//+------------------------------------------------------------------+
void CStructure::ResolveState(const MqlRates &r[],const int total)
  {
   m_state          = SEA_STRUCT_UNKNOWN;
   m_lastBreak      = SEA_BREAK_NONE;
   m_lastBreakDir   = SEA_DIR_NONE;
   m_lastBreakTime  = 0;
   m_lastBreakLevel = 0.0;
   m_barsSinceBreak = m_staleBars+1;

   if(m_swingCount<2)
      return;

   //--- running reference: the most recent confirmed swing on each side
   //--- that already existed at the bar being examined
   double refHigh=0.0, refLow=0.0;
   bool   haveHigh=false, haveLow=false;
   int    lastBreakShift=-1;

   //--- oldest closed bar first, newest last (shift 1)
   for(int i=total-1; i>=1; i--)
     {
      //--- active references at bar i: the newest confirmed swing of each
      //--- side whose confirmation was already complete by then.
      //--- m_swings is ordered newest-first, so the FIRST match walking
      //--- forward is the newest qualifying swing.
      //--- A swing at shift s is confirmed once m_fractalBars bars have
      //--- closed after it, i.e. only once i <= s - m_fractalBars.
      haveHigh=false;
      haveLow=false;
      for(int s=0; s<m_swingCount; s++)
        {
         if(m_swings[s].shift-m_fractalBars<i)
            continue;                       // confirmation not complete at bar i
         if(m_swings[s].isHigh && !haveHigh)
           {
            refHigh=m_swings[s].price;
            haveHigh=true;
           }
         if(!m_swings[s].isHigh && !haveLow)
           {
            refLow=m_swings[s].price;
            haveLow=true;
           }
         if(haveHigh && haveLow)
            break;
        }

      double close=r[i].close;

      //--- upside break
      if(haveHigh && close>refHigh)
        {
         if(m_state==SEA_STRUCT_BEARISH)
            m_lastBreak=SEA_BREAK_CHOCH;
         else
            m_lastBreak=SEA_BREAK_BOS;

         m_state          = SEA_STRUCT_BULLISH;
         m_lastBreakDir   = SEA_DIR_LONG;
         m_lastBreakTime  = r[i].time;
         m_lastBreakLevel = refHigh;
         lastBreakShift   = i;
         continue;
        }

      //--- downside break
      if(haveLow && close<refLow)
        {
         if(m_state==SEA_STRUCT_BULLISH)
            m_lastBreak=SEA_BREAK_CHOCH;
         else
            m_lastBreak=SEA_BREAK_BOS;

         m_state          = SEA_STRUCT_BEARISH;
         m_lastBreakDir   = SEA_DIR_SHORT;
         m_lastBreakTime  = r[i].time;
         m_lastBreakLevel = refLow;
         lastBreakShift   = i;
        }
     }

   if(lastBreakShift<0)
     {
      m_state          = SEA_STRUCT_RANGING;
      m_barsSinceBreak = m_staleBars+1;
      return;
     }

   //--- shift 1 is the newest closed bar, so elapsed bars = shift - 1
   m_barsSinceBreak=lastBreakShift-1;

   //--- RULE: no break within the stale window means the market is
   //--- ranging, whatever the last break said
   if(m_barsSinceBreak>m_staleBars)
      m_state=SEA_STRUCT_RANGING;
  }

//+------------------------------------------------------------------+
//| Dealing range: the last confirmed swing low to swing high of the  |
//| current leg.                                                      |
//+------------------------------------------------------------------+
void CStructure::ResolveRange(void)
  {
   m_rangeValid=false;

   SSwing hi,lo;
   if(!LastSwingHigh(hi) || !LastSwingLow(lo))
      return;
   if(hi.price<=lo.price)
      return;

   m_rangeHigh     = hi.price;
   m_rangeLow      = lo.price;
   m_rangeHighTime = hi.time;
   m_rangeLowTime  = lo.time;
   m_rangeValid    = true;
  }

//+------------------------------------------------------------------+
//| Rebuild everything from closed bars.                              |
//+------------------------------------------------------------------+
bool CStructure::Update(const bool force)
  {
   if(m_symbol=="")
      return(false);

   //--- bar-close gate: recompute on a new bar only
   datetime barTime=(datetime)SeriesInfoInteger(m_symbol,m_tf,SERIES_LASTBAR_DATE);
   if(!force && barTime==m_lastBarTime && m_ready)
      return(true);

   MqlRates r[];
   if(!SeaCopyRates(m_symbol,m_tf,0,m_lookback,r))
     {
      //--- RULE 9: unsynchronised is skip-and-retry, never "no signal"
      if(m_verbose)
         PrintFormat("[CStructure] %s %d: series not synchronised, skipping",
                     m_symbol,(int)m_tf);
      return(false);
     }

   int total=ArraySize(r);
   if(total<SEA_STRUCT_MIN_BARS)
      return(false);

   Reset();

   //--- collect confirmed fractals, newest first.
   //--- the scan starts at m_fractalBars+1 so the newest possible swing
   //--- already has m_fractalBars CLOSED bars to its right. Index 0 is
   //--- never examined.
   for(int i=m_fractalBars+1; i<total-m_fractalBars && m_swingCount<SEA_MAX_SWINGS; i++)
     {
      if(IsFractalHigh(r,i,total))
         AddSwing(true,r[i].high,r[i].time,i);
      else
         if(IsFractalLow(r,i,total))
            AddSwing(false,r[i].low,r[i].time,i);
     }

   ResolveState(r,total);
   ResolveRange();

   m_lastBarTime = barTime;
   m_ready       = true;

   if(m_verbose)
      PrintFormat("[CStructure] %s",Describe());

   return(true);
  }

//+------------------------------------------------------------------+
ENUM_SEA_DIRECTION CStructure::Bias(void) const
  {
   if(m_state==SEA_STRUCT_BULLISH)
      return(SEA_DIR_LONG);
   if(m_state==SEA_STRUCT_BEARISH)
      return(SEA_DIR_SHORT);
   return(SEA_DIR_NONE);
  }

//+------------------------------------------------------------------+
bool CStructure::GetSwing(const int index,SSwing &out) const
  {
   if(index<0 || index>=m_swingCount)
      return(false);
   out=m_swings[index];
   return(true);
  }

//+------------------------------------------------------------------+
bool CStructure::LastSwingHigh(SSwing &out) const
  {
   return(NthSwing(true,0,out));
  }

//+------------------------------------------------------------------+
bool CStructure::LastSwingLow(SSwing &out) const
  {
   return(NthSwing(false,0,out));
  }

//+------------------------------------------------------------------+
bool CStructure::NthSwing(const bool isHigh,const int skip,SSwing &out) const
  {
   int seen=0;
   for(int i=0; i<m_swingCount; i++)
     {
      if(m_swings[i].isHigh!=isHigh)
         continue;
      if(seen==skip)
        {
         out=m_swings[i];
         return(true);
        }
      seen++;
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Structural invalidation. GATE 5 fails when this returns false.    |
//+------------------------------------------------------------------+
bool CStructure::InvalidationLevel(const ENUM_SEA_DIRECTION dir,double &level) const
  {
   level=0.0;
   SSwing s;

   if(dir==SEA_DIR_LONG)
     {
      //--- a long is wrong below the swing low that launched the leg
      if(!LastSwingLow(s))
         return(false);
      level=s.price;
      return(true);
     }

   if(dir==SEA_DIR_SHORT)
     {
      if(!LastSwingHigh(s))
         return(false);
      level=s.price;
      return(true);
     }

   return(false);
  }

//+------------------------------------------------------------------+
double CStructure::Equilibrium(void) const
  {
   if(!m_rangeValid)
      return(0.0);
   return((m_rangeHigh+m_rangeLow)*0.5);
  }

//+------------------------------------------------------------------+
double CStructure::RangePosition(const double price) const
  {
   if(!m_rangeValid)
      return(-1.0);
   double span=m_rangeHigh-m_rangeLow;
   if(span<=0.0)
      return(-1.0);
   return((price-m_rangeLow)/span);
  }

//+------------------------------------------------------------------+
bool CStructure::IsDiscount(const double price) const
  {
   double p=RangePosition(price);
   return(p>=0.0 && p<0.5);
  }

//+------------------------------------------------------------------+
bool CStructure::IsPremium(const double price) const
  {
   double p=RangePosition(price);
   return(p>=0.0 && p>0.5);
  }

//+------------------------------------------------------------------+
//| OTE band, 0.618-0.79 of the retracement.                          |
//|                                                                   |
//| For a long the retracement is measured down from the range high,  |
//| so the band sits in the lower part of the range. Mirrored short.  |
//+------------------------------------------------------------------+
bool CStructure::OTEBounds(const ENUM_SEA_DIRECTION dir,double &lower,double &upper) const
  {
   lower=0.0;
   upper=0.0;
   if(!m_rangeValid)
      return(false);

   double span=m_rangeHigh-m_rangeLow;
   if(span<=0.0)
      return(false);

   if(dir==SEA_DIR_LONG)
     {
      upper=m_rangeHigh-span*0.618;
      lower=m_rangeHigh-span*0.790;
      return(true);
     }

   if(dir==SEA_DIR_SHORT)
     {
      lower=m_rangeLow+span*0.618;
      upper=m_rangeLow+span*0.790;
      return(true);
     }

   return(false);
  }

//+------------------------------------------------------------------+
bool CStructure::IsOTE(const double price,const ENUM_SEA_DIRECTION dir) const
  {
   double lo,hi;
   if(!OTEBounds(dir,lo,hi))
      return(false);
   return(price>=lo && price<=hi);
  }

//+------------------------------------------------------------------+
//| Price action triggers on a CLOSED bar.                            |
//+------------------------------------------------------------------+
ENUM_SEA_TRIGGER CStructure::DetectTrigger(const ENUM_SEA_DIRECTION dir,const int shift) const
  {
   //--- RULE 1: index 0 is forbidden in any signal path
   if(shift<1)
     {
      if(m_verbose)
         Print("[CStructure] DetectTrigger called with shift 0 - refused");
      return(SEA_TRIGGER_NONE);
     }
   if(dir==SEA_DIR_NONE)
      return(SEA_TRIGGER_NONE);

   //--- the trigger bar, its predecessor, and 20 bars for the body average
   const int need=shift+22;
   MqlRates r[];
   if(!SeaCopyRates(m_symbol,m_tf,0,need,r))
      return(SEA_TRIGGER_NONE);

   const int i=shift;
   const int j=shift+1;

   double range=r[i].high-r[i].low;
   if(range<=0.0)
      return(SEA_TRIGGER_NONE);

   double body      = MathAbs(r[i].close-r[i].open);
   double bodyHigh  = MathMax(r[i].close,r[i].open);
   double bodyLow   = MathMin(r[i].close,r[i].open);
   double upperWick = r[i].high-bodyHigh;
   double lowerWick = bodyLow-r[i].low;
   bool   bullBar   = (r[i].close>r[i].open);

   //--- average body over the 20 closed bars preceding the trigger
   double bodySum=0.0;
   int    bodyN=0;
   for(int k=j; k<j+20 && k<ArraySize(r); k++)
     {
      bodySum+=MathAbs(r[k].close-r[k].open);
      bodyN++;
     }
   double avgBody=(bodyN>0 ? bodySum/(double)bodyN : 0.0);

   if(dir==SEA_DIR_LONG)
     {
      //--- rejection wick: lower wick >= 60% of range, close in upper third
      if(lowerWick>=range*0.60 && r[i].close>=r[i].low+range*(2.0/3.0))
         return(SEA_TRIGGER_REJECTION_WICK);

      //--- bullish engulfing: body engulfs the prior bearish body
      if(bullBar && r[j].close<r[j].open)
        {
         double pBodyHigh=r[j].open;
         double pBodyLow =r[j].close;
         if(bodyLow<=pBodyLow && bodyHigh>=pBodyHigh)
            return(SEA_TRIGGER_ENGULFING);
        }

      //--- inside-bar break: bar j inside bar j+1, bar i closes above j's high
      if(j+1<ArraySize(r))
        {
         bool inside=(r[j].high<=r[j+1].high && r[j].low>=r[j+1].low);
         if(inside && r[i].close>r[j].high)
            return(SEA_TRIGGER_INSIDE_BREAK);
        }

      //--- momentum close: close in the top quarter, body >= 1.2x average
      if(bullBar && r[i].close>=r[i].low+range*0.75 && avgBody>0.0 && body>=avgBody*1.2)
         return(SEA_TRIGGER_MOMENTUM_CLOSE);

      return(SEA_TRIGGER_NONE);
     }

   //--- bearish mirror
   if(upperWick>=range*0.60 && r[i].close<=r[i].high-range*(2.0/3.0))
      return(SEA_TRIGGER_REJECTION_WICK);

   if(!bullBar && r[j].close>r[j].open)
     {
      double pBodyHigh=r[j].close;
      double pBodyLow =r[j].open;
      if(bodyLow<=pBodyLow && bodyHigh>=pBodyHigh)
         return(SEA_TRIGGER_ENGULFING);
     }

   if(j+1<ArraySize(r))
     {
      bool inside=(r[j].high<=r[j+1].high && r[j].low>=r[j+1].low);
      if(inside && r[i].close<r[j].low)
         return(SEA_TRIGGER_INSIDE_BREAK);
     }

   if(!bullBar && r[i].close<=r[i].high-range*0.75 && avgBody>0.0 && body>=avgBody*1.2)
      return(SEA_TRIGGER_MOMENTUM_CLOSE);

   return(SEA_TRIGGER_NONE);
  }

//+------------------------------------------------------------------+
string CStructure::Describe(void) const
  {
   return(StringFormat("%s state=%s lastBreak=%s(%s) barsSince=%d swings=%d range=[%s..%s] eq=%s",
                       m_symbol,
                       SeaStructStateToString(m_state),
                       (m_lastBreak==SEA_BREAK_BOS ? "BOS" :
                        (m_lastBreak==SEA_BREAK_CHOCH ? "CHoCH" : "none")),
                       SeaDirectionToString(m_lastBreakDir),
                       m_barsSinceBreak,m_swingCount,
                       (m_rangeValid ? DoubleToString(m_rangeLow,_Digits)  : "-"),
                       (m_rangeValid ? DoubleToString(m_rangeHigh,_Digits) : "-"),
                       (m_rangeValid ? DoubleToString(Equilibrium(),_Digits) : "-")));
  }

//+------------------------------------------------------------------+
//| Deterministic fingerprint for the repaint test.                   |
//+------------------------------------------------------------------+
string CStructure::Fingerprint(void) const
  {
   string out=StringFormat("%s|%d|%d|%d|%d|%s|%d|",
                           m_symbol,(int)m_tf,m_fractalBars,
                           (int)m_state,(int)m_lastBreak,
                           TimeToString(m_lastBreakTime,TIME_DATE|TIME_MINUTES),
                           m_swingCount);

   for(int i=0; i<m_swingCount; i++)
      out+=StringFormat("%s%s@%s;",
                        (m_swings[i].isHigh ? "H" : "L"),
                        DoubleToString(m_swings[i].price,8),
                        TimeToString(m_swings[i].time,TIME_DATE|TIME_MINUTES));

   return(out);
  }

#endif // SEA_CSTRUCTURE_MQH
//+------------------------------------------------------------------+
