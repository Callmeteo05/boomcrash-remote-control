//+------------------------------------------------------------------+
//|                                                 CSpikeHazard.mqh  |
//|                                                                   |
//|   Module 11. Spike interval, hazard bands, stress stops.          |
//|                                                                   |
//|   CSpikeHazard PERMITS, SIZES and TIMES. It NEVER selects          |
//|   direction. There is no code path here that can turn a hazard    |
//|   reading into an entry, and no instrument is direction-locked.   |
//|                                                                   |
//|   Spike character comes from CSymbolProfiler, measured            |
//|   statistically. An instrument with no measured spike character   |
//|   returns hazard LOW and constrains nothing.                      |
//|                                                                   |
//|   Hazard = barsSinceLastSpike / measured mean interval            |
//|     <0.4    LOW      counter-spike fully permitted                |
//|     0.4-0.7 MEDIUM   counter-spike allowed, no scale-ins          |
//|     0.7-0.9 HIGH     close profitable counter-spike, no entries   |
//|     >0.9    EXTREME  flat all counter-spike, arm with-spike       |
//|                                                                   |
//|   On restart with no stored count, hazard is 1.0. Never assume    |
//|   safe.                                                           |
//+------------------------------------------------------------------+
#ifndef SEA_CSPIKEHAZARD_MQH
#define SEA_CSPIKEHAZARD_MQH

#include <SEA/SEA_Common.mqh>
#include <SEA/CSymbolProfiler.mqh>

#define SEA_GV_SPIKE_BARS   "SEA_%d_SPK_%s"
#define SEA_MAX_HAZARD_SYM  64

//+------------------------------------------------------------------+
//| Per-symbol hazard state.                                          |
//+------------------------------------------------------------------+
struct SHazardState
  {
   string            symbol;
   bool              spikeDriven;
   ENUM_SEA_DIRECTION spikeDirection;
   double            meanIntervalBars;
   double            meanMagnitude;
   int               barsSinceSpike;
   double            hazard;
   ENUM_SEA_HAZARD   band;
   datetime          lastSpikeTime;
   datetime          lastBarTime;
  };

//+------------------------------------------------------------------+
//| CSpikeHazard                                                      |
//+------------------------------------------------------------------+
class CSpikeHazard
  {
private:
   SHazardState      m_states[];
   int               m_count;
   long              m_magic;
   double            m_detectATR;
   int               m_atrPeriod;
   bool              m_verbose;

   int               Find(const string symbol) const;
   string            Key(const string symbol) const;
   void              Classify(SHazardState &s) const;

public:
                     CSpikeHazard(void);
                    ~CSpikeHazard(void);

   //! Configure detection. detectATR must match the profiler's value
   //! or the two disagree about what a spike is.
   //! detectATR 2.0..20.0, default 5.0
   void              Init(const long magic,const double detectATR,const int atrPeriod);

   //! Print diagnostics. Off by default.
   void              SetVerbose(const bool enabled) { m_verbose=enabled; }

   //! Register a symbol from its measured profile.
   //!
   //! On first registration the bar counter is restored from a
   //! GlobalVariable. With NO stored count the hazard is set to 1.0,
   //! which is EXTREME - the EA never assumes a fresh restart is safe.
   bool              Register(const string symbol,const SProfile &profile);

   //! Recount bars since the last spike from closed bars.
   //! Call on execution-timeframe bar close, never in the tick path.
   bool              Update(const string symbol,const ENUM_TIMEFRAMES tf,
                            CIndicatorPool &pool);

   //! Persist every bar counter.
   void              Persist(void) const;

   //--- queries -----------------------------------------------------------
   //! Hazard ratio for a symbol. Returns 1.0 for an unregistered
   //! symbol - unknown is treated as dangerous, not as safe.
   double            Hazard(const string symbol) const;

   //! Hazard band for a symbol.
   ENUM_SEA_HAZARD   Band(const string symbol) const;

   //! True when the symbol has measured spike character at all.
   bool              IsSpikeDriven(const string symbol) const;

   //! Measured spike direction. This is REPORTING, not permission -
   //! callers use it to know which side is "with" and which "against".
   ENUM_SEA_DIRECTION SpikeDirection(const string symbol) const;

   //! True when a proposed direction runs AGAINST the measured spike.
   bool              IsCounterSpike(const string symbol,const ENUM_SEA_DIRECTION dir) const;

   //--- permissions --------------------------------------------------------
   //! GATE 10. Does the hazard permit an entry in this direction?
   //!
   //! Never returns "you must trade this way" - only "not this way,
   //! not now". A non-spike instrument always permits both directions.
   bool              PermitsEntry(const string symbol,const ENUM_SEA_DIRECTION dir,
                                  string &reason) const;

   //! True when scale-ins are permitted for this direction right now.
   bool              PermitsScaleIn(const string symbol,const ENUM_SEA_DIRECTION dir) const;

   //! True when an open counter-spike position in profit should be
   //! closed because hazard has risen into the HIGH band.
   bool              ShouldCloseProfitableCounter(const string symbol,
                                                  const ENUM_SEA_DIRECTION dir,
                                                  const double currentR) const;

   //! True when every counter-spike position must be flattened.
   bool              MustFlattenCounter(const string symbol,const ENUM_SEA_DIRECTION dir) const;

   //! True when trailing is forbidden for this position.
   //! A counter-spike trade is never trailed into rising hazard, and a
   //! with-spike trade is closed on the spike rather than trailed.
   bool              TrailingForbidden(const string symbol,const ENUM_SEA_DIRECTION dir) const;

   //--- sizing --------------------------------------------------------------
   //! Sizing distance for a counter-spike trade, in price units.
   //!
   //! A counter-spike position is PLACED at its structural stop but
   //! SIZED against the measured spike magnitude, because that is the
   //! loss actually at risk when a spike arrives. Returns 0.0 when the
   //! symbol has no measured spike character, meaning "size normally".
   double            CounterSpikeSizingDistance(const string symbol) const;

   //! Fixed target distance for a counter-spike trade, in price units.
   //! Returns 0.0 when the symbol has no spike character.
   double            CounterSpikeTarget(const string symbol,const double structuralStop) const;

   //--- diagnostics ----------------------------------------------------------
   //! One-line state for a symbol.
   string            Describe(const string symbol) const;
  };

//+------------------------------------------------------------------+
CSpikeHazard::CSpikeHazard(void)
  {
   m_count     = 0;
   m_magic     = 0;
   m_detectATR = 5.0;
   m_atrPeriod = 14;
   m_verbose   = false;
   ArrayResize(m_states,SEA_MAX_HAZARD_SYM);
  }

//+------------------------------------------------------------------+
CSpikeHazard::~CSpikeHazard(void)
  {
   Persist();
   ArrayFree(m_states);
  }

//+------------------------------------------------------------------+
void CSpikeHazard::Init(const long magic,const double detectATR,const int atrPeriod)
  {
   m_magic     = magic;
   m_detectATR = (detectATR<2.0 ? 2.0 : (detectATR>20.0 ? 20.0 : detectATR));
   m_atrPeriod = (atrPeriod<2 ? 2 : (atrPeriod>200 ? 200 : atrPeriod));
  }

//+------------------------------------------------------------------+
int CSpikeHazard::Find(const string symbol) const
  {
   for(int i=0; i<m_count; i++)
      if(m_states[i].symbol==symbol)
         return(i);
   return(-1);
  }

//+------------------------------------------------------------------+
string CSpikeHazard::Key(const string symbol) const
  {
   return(StringFormat(SEA_GV_SPIKE_BARS,(int)m_magic,symbol));
  }

//+------------------------------------------------------------------+
void CSpikeHazard::Classify(SHazardState &s) const
  {
   if(!s.spikeDriven || s.meanIntervalBars<=0.0)
     {
      //--- no measured spike character: this module constrains nothing
      s.hazard = 0.0;
      s.band   = SEA_HAZARD_LOW;
      return;
     }

   s.hazard=(double)s.barsSinceSpike/s.meanIntervalBars;

   if(s.hazard<0.4)
      s.band=SEA_HAZARD_LOW;
   else
      if(s.hazard<0.7)
         s.band=SEA_HAZARD_MEDIUM;
      else
         if(s.hazard<0.9)
            s.band=SEA_HAZARD_HIGH;
         else
            s.band=SEA_HAZARD_EXTREME;
  }

//+------------------------------------------------------------------+
bool CSpikeHazard::Register(const string symbol,const SProfile &profile)
  {
   int slot=Find(symbol);
   if(slot<0)
     {
      if(m_count>=SEA_MAX_HAZARD_SYM)
         return(false);
      slot=m_count;
      m_count++;
     }

   SHazardState s;
   s.symbol           = symbol;
   s.spikeDriven      = profile.spikeDriven;
   s.spikeDirection   = profile.spikeDirection;
   s.meanIntervalBars = profile.spikeMeanIntervalBars;
   s.meanMagnitude    = profile.spikeMeanMagnitude;
   s.lastSpikeTime    = 0;
   s.lastBarTime      = 0;

   //--- restore the bar counter
   string key=Key(symbol);
   if(GlobalVariableCheck(key))
      s.barsSinceSpike=(int)GlobalVariableGet(key);
   else
     {
      //--- NO STORED COUNT. Assume hazard 1.0, which is EXTREME.
      //--- Never assume safe after a restart.
      s.barsSinceSpike=(int)MathCeil(s.meanIntervalBars>0.0 ? s.meanIntervalBars : 1.0);
      if(m_verbose && s.spikeDriven)
         PrintFormat("[CSpikeHazard] %s: no stored spike counter, assuming hazard 1.0 (EXTREME)",
                     symbol);
     }

   Classify(s);
   m_states[slot]=s;
   return(true);
  }

//+------------------------------------------------------------------+
bool CSpikeHazard::Update(const string symbol,const ENUM_TIMEFRAMES tf,
                          CIndicatorPool &pool)
  {
   int slot=Find(symbol);
   if(slot<0)
      return(false);

   if(!m_states[slot].spikeDriven)
      return(true);   // nothing to count

   datetime barTime=(datetime)SeriesInfoInteger(symbol,tf,SERIES_LASTBAR_DATE);
   if(barTime==m_states[slot].lastBarTime)
      return(true);

   //--- look back far enough to find at least one prior spike
   int need=(int)MathCeil(m_states[slot].meanIntervalBars*4.0);
   if(need<200)
      need=200;
   if(need>5000)
      need=5000;

   MqlRates r[];
   if(!SeaCopyRates(symbol,tf,0,need,r))
      return(false);

   int atrHandle=pool.AcquireATR(symbol,tf,m_atrPeriod);
   if(atrHandle==INVALID_HANDLE)
      return(false);

   double atr[];
   bool got=SeaCopyBuffer(atrHandle,0,1,ArraySize(r)-2>50 ? ArraySize(r)-2 : 50,atr);
   pool.Release(atrHandle);
   if(!got)
      return(false);

   double medianATR=SeaMedian(atr);
   if(medianATR<=0.0)
      return(false);

   double threshold=medianATR*m_detectATR;

   //--- newest CLOSED bar first
   int found=-1;
   for(int i=1; i<ArraySize(r); i++)
     {
      if(r[i].high-r[i].low>=threshold)
        {
         found=i;
         break;
        }
     }

   if(found>=0)
     {
      m_states[slot].barsSinceSpike=found-1;
      m_states[slot].lastSpikeTime =r[found].time;
     }
   else
     {
      //--- no spike anywhere in the window: treat as maximally overdue
      m_states[slot].barsSinceSpike=ArraySize(r);
     }

   m_states[slot].lastBarTime=barTime;
   Classify(m_states[slot]);

   GlobalVariableSet(Key(symbol),(double)m_states[slot].barsSinceSpike);

   if(m_verbose)
      Print("[CSpikeHazard] ",Describe(symbol));

   return(true);
  }

//+------------------------------------------------------------------+
void CSpikeHazard::Persist(void) const
  {
   for(int i=0; i<m_count; i++)
      if(m_states[i].spikeDriven)
         GlobalVariableSet(Key(m_states[i].symbol),(double)m_states[i].barsSinceSpike);
   GlobalVariablesFlush();
  }

//+------------------------------------------------------------------+
double CSpikeHazard::Hazard(const string symbol) const
  {
   int i=Find(symbol);
   if(i<0)
      return(1.0);   // unknown is dangerous, not safe
   return(m_states[i].hazard);
  }

//+------------------------------------------------------------------+
ENUM_SEA_HAZARD CSpikeHazard::Band(const string symbol) const
  {
   int i=Find(symbol);
   if(i<0)
      return(SEA_HAZARD_EXTREME);
   return(m_states[i].band);
  }

//+------------------------------------------------------------------+
bool CSpikeHazard::IsSpikeDriven(const string symbol) const
  {
   int i=Find(symbol);
   return(i>=0 && m_states[i].spikeDriven);
  }

//+------------------------------------------------------------------+
ENUM_SEA_DIRECTION CSpikeHazard::SpikeDirection(const string symbol) const
  {
   int i=Find(symbol);
   if(i<0)
      return(SEA_DIR_NONE);
   return(m_states[i].spikeDirection);
  }

//+------------------------------------------------------------------+
bool CSpikeHazard::IsCounterSpike(const string symbol,const ENUM_SEA_DIRECTION dir) const
  {
   int i=Find(symbol);
   if(i<0 || !m_states[i].spikeDriven)
      return(false);
   if(m_states[i].spikeDirection==SEA_DIR_NONE || dir==SEA_DIR_NONE)
      return(false);
   return(dir!=m_states[i].spikeDirection);
  }

//+------------------------------------------------------------------+
//| GATE 10.                                                          |
//+------------------------------------------------------------------+
bool CSpikeHazard::PermitsEntry(const string symbol,const ENUM_SEA_DIRECTION dir,
                                string &reason) const
  {
   reason="";

   int i=Find(symbol);
   if(i<0)
     {
      reason="symbol not registered with the hazard model";
      return(false);
     }

   //--- no measured spike character: no constraint from this module
   if(!m_states[i].spikeDriven)
      return(true);

   bool counter=IsCounterSpike(symbol,dir);

   if(!counter)
     {
      //--- WITH the spike. Permitted at every hazard band; EXTREME is
      //--- precisely when these setups are armed.
      return(true);
     }

   //--- AGAINST the spike
   switch(m_states[i].band)
     {
      case SEA_HAZARD_LOW:
         return(true);
      case SEA_HAZARD_MEDIUM:
         return(true);
      case SEA_HAZARD_HIGH:
         reason=StringFormat("hazard HIGH (%.2f): no new counter-spike entries",
                             m_states[i].hazard);
         return(false);
      case SEA_HAZARD_EXTREME:
         reason=StringFormat("hazard EXTREME (%.2f): counter-spike flat only",
                             m_states[i].hazard);
         return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
bool CSpikeHazard::PermitsScaleIn(const string symbol,const ENUM_SEA_DIRECTION dir) const
  {
   int i=Find(symbol);
   if(i<0)
      return(false);
   if(!m_states[i].spikeDriven)
      return(true);

   if(!IsCounterSpike(symbol,dir))
      return(true);

   //--- MEDIUM and above: no scale-ins into a counter-spike position
   return(m_states[i].band==SEA_HAZARD_LOW);
  }

//+------------------------------------------------------------------+
bool CSpikeHazard::ShouldCloseProfitableCounter(const string symbol,
                                                const ENUM_SEA_DIRECTION dir,
                                                const double currentR) const
  {
   int i=Find(symbol);
   if(i<0 || !m_states[i].spikeDriven)
      return(false);
   if(!IsCounterSpike(symbol,dir))
      return(false);
   if(currentR<=0.0)
      return(false);

   return(m_states[i].band==SEA_HAZARD_HIGH || m_states[i].band==SEA_HAZARD_EXTREME);
  }

//+------------------------------------------------------------------+
bool CSpikeHazard::MustFlattenCounter(const string symbol,const ENUM_SEA_DIRECTION dir) const
  {
   int i=Find(symbol);
   if(i<0 || !m_states[i].spikeDriven)
      return(false);
   if(!IsCounterSpike(symbol,dir))
      return(false);
   return(m_states[i].band==SEA_HAZARD_EXTREME);
  }

//+------------------------------------------------------------------+
bool CSpikeHazard::TrailingForbidden(const string symbol,const ENUM_SEA_DIRECTION dir) const
  {
   int i=Find(symbol);
   if(i<0 || !m_states[i].spikeDriven)
      return(false);

   //--- with-spike: close on the spike, do not trail
   //--- counter-spike: never trailed into rising hazard
   return(true);
  }

//+------------------------------------------------------------------+
double CSpikeHazard::CounterSpikeSizingDistance(const string symbol) const
  {
   int i=Find(symbol);
   if(i<0 || !m_states[i].spikeDriven)
      return(0.0);
   return(m_states[i].meanMagnitude);
  }

//+------------------------------------------------------------------+
double CSpikeHazard::CounterSpikeTarget(const string symbol,const double structuralStop) const
  {
   int i=Find(symbol);
   if(i<0 || !m_states[i].spikeDriven)
      return(0.0);
   if(structuralStop<=0.0)
      return(0.0);

   //--- a fixed target, never trailed. Two units of the risk actually
   //--- taken, which for a counter-spike trade is the structural stop.
   return(structuralStop*2.0);
  }

//+------------------------------------------------------------------+
string CSpikeHazard::Describe(const string symbol) const
  {
   int i=Find(symbol);
   if(i<0)
      return(StringFormat("%s: not registered, hazard assumed 1.00 EXTREME",symbol));

   if(!m_states[i].spikeDriven)
      return(StringFormat("%s: no measured spike character, hazard model inactive",symbol));

   return(StringFormat("%s spike=%s interval=%.1f bars since=%d hazard=%.2f band=%s magnitude=%s",
                       symbol,SeaDirectionToString(m_states[i].spikeDirection),
                       m_states[i].meanIntervalBars,m_states[i].barsSinceSpike,
                       m_states[i].hazard,SeaHazardToString(m_states[i].band),
                       DoubleToString(m_states[i].meanMagnitude,_Digits)));
  }

#endif // SEA_CSPIKEHAZARD_MQH
//+------------------------------------------------------------------+
