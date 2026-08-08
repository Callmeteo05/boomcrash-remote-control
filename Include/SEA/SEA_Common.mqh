//+------------------------------------------------------------------+
//|                                                    SEA_Common.mqh |
//|                                                                   |
//|   Shared vocabulary for the Structure-Driven Adaptive EA.         |
//|                                                                   |
//|   DEVIATION NOTE: the architecture calls for one class per .mqh.  |
//|   This file holds the enums and structs every module speaks in,   |
//|   plus CIndicatorPool - the single place indicator handles are    |
//|   created and released, which is how NON-NEGOTIABLE RULE 8 is     |
//|   enforced in one auditable location instead of eight.            |
//|   It contains no strategy logic and generates no signals.         |
//|                                                                   |
//|   Contains NO PERIOD_ constants. Timeframes arrive as parameters. |
//+------------------------------------------------------------------+
#ifndef SEA_COMMON_MQH
#define SEA_COMMON_MQH

//+------------------------------------------------------------------+
//| "Not bound to a timeframe yet" sentinel.                          |
//|                                                                   |
//| RULE 10 reserves PERIOD_ constants for CStyle. A constructor still |
//| needs a neutral initial value for an unbound timeframe member, so  |
//| this names one without selecting a timeframe. Numerically it is    |
//| the terminal's "current period" value, which is exactly the        |
//| "unspecified" slot.                                                |
//+------------------------------------------------------------------+
#define SEA_TF_UNSET ((ENUM_TIMEFRAMES)0)

//+------------------------------------------------------------------+
//| Direction of a structural decision.                               |
//+------------------------------------------------------------------+
enum ENUM_SEA_DIRECTION
  {
   SEA_DIR_NONE = 0,
   SEA_DIR_LONG,
   SEA_DIR_SHORT
  };

//+------------------------------------------------------------------+
//| Market structure state at one timeframe.                          |
//+------------------------------------------------------------------+
enum ENUM_SEA_STRUCT_STATE
  {
   SEA_STRUCT_UNKNOWN = 0,   // not enough confirmed swings yet
   SEA_STRUCT_BULLISH,       // higher highs and higher lows
   SEA_STRUCT_BEARISH,       // lower highs and lower lows
   SEA_STRUCT_RANGING        // no BOS or CHoCH within the stale window
  };

//+------------------------------------------------------------------+
//| The structural event that last moved the state.                   |
//+------------------------------------------------------------------+
enum ENUM_SEA_BREAK_TYPE
  {
   SEA_BREAK_NONE = 0,
   SEA_BREAK_BOS,            // continuation: break of the trend-side swing
   SEA_BREAK_CHOCH           // reversal: break of the counter-trend swing
  };

//+------------------------------------------------------------------+
//| Zone taxonomy.                                                    |
//+------------------------------------------------------------------+
enum ENUM_SEA_ZONE_TYPE
  {
   SEA_ZONE_NONE = 0,
   SEA_ZONE_OB_DEMAND,       // last bearish body before a bullish impulse
   SEA_ZONE_OB_SUPPLY,       // last bullish body before a bearish impulse
   SEA_ZONE_FVG_BULL,        // 3-bar gap, Low[i] > High[i+2]
   SEA_ZONE_FVG_BEAR,        // 3-bar gap, High[i] < Low[i+2]
   SEA_ZONE_BREAKER_BULL,    // failed supply revisited from below
   SEA_ZONE_BREAKER_BEAR,    // failed demand revisited from above
   SEA_ZONE_IFVG_BULL,       // bearish FVG closed through, now support
   SEA_ZONE_IFVG_BEAR        // bullish FVG closed through, now resistance
  };

//+------------------------------------------------------------------+
//| Zone lifecycle. Only FRESH is tradeable.                          |
//+------------------------------------------------------------------+
enum ENUM_SEA_ZONE_STATE
  {
   SEA_ZONE_FRESH = 0,       // never touched since formation
   SEA_ZONE_TAPPED,          // wicked into, not closed through
   SEA_ZONE_MITIGATED,       // traded through the body
   SEA_ZONE_INVERTED,        // closed through, now opposing
   SEA_ZONE_EXPIRED          // aged out
  };

//+------------------------------------------------------------------+
//| Wyckoff-style phase.                                              |
//+------------------------------------------------------------------+
enum ENUM_SEA_PHASE
  {
   SEA_PHASE_UNDEFINED = 0,
   SEA_PHASE_ACCUMULATION,
   SEA_PHASE_MANIPULATION,
   SEA_PHASE_DISTRIBUTION
  };

//+------------------------------------------------------------------+
//| Volatility and directional regime.                                |
//+------------------------------------------------------------------+
enum ENUM_SEA_REGIME
  {
   SEA_REGIME_UNDEFINED = 0,
   SEA_REGIME_TRENDING,
   SEA_REGIME_RANGING,
   SEA_REGIME_EXPANSION,
   SEA_REGIME_COMPRESSION
  };

//+------------------------------------------------------------------+
//| Measured instrument behaviour. Derived from metrics only.         |
//+------------------------------------------------------------------+
enum ENUM_SEA_BEHAVIOUR
  {
   SEA_BEHAVIOUR_UNCLASSIFIED = 0,
   SEA_BEHAVIOUR_TREND_FOLLOWER,
   SEA_BEHAVIOUR_MEAN_REVERTER,
   SEA_BEHAVIOUR_BREAKOUT,
   SEA_BEHAVIOUR_SPIKE_DRIVEN,
   SEA_BEHAVIOUR_NOISY_AVOID
  };

//+------------------------------------------------------------------+
//| Spike hazard band.                                                |
//+------------------------------------------------------------------+
enum ENUM_SEA_HAZARD
  {
   SEA_HAZARD_LOW = 0,
   SEA_HAZARD_MEDIUM,
   SEA_HAZARD_HIGH,
   SEA_HAZARD_EXTREME
  };

//+------------------------------------------------------------------+
//| Price action trigger taxonomy.                                    |
//+------------------------------------------------------------------+
enum ENUM_SEA_TRIGGER
  {
   SEA_TRIGGER_NONE = 0,
   SEA_TRIGGER_REJECTION_WICK,
   SEA_TRIGGER_ENGULFING,
   SEA_TRIGGER_INSIDE_BREAK,
   SEA_TRIGGER_MOMENTUM_CLOSE
  };

//+------------------------------------------------------------------+
//| Halt state of the risk engine.                                    |
//+------------------------------------------------------------------+
enum ENUM_SEA_HALT
  {
   SEA_HALT_NONE = 0,
   SEA_HALT_SOFT,            // block new entries, let open trades run
   SEA_HALT_DAILY,           // daily limit, auto-resumes at broker midnight
   SEA_HALT_HARD,            // max drawdown, manual reset required
   SEA_HALT_BREAKER          // consecutive-loss pause
  };

//+------------------------------------------------------------------+
//| A confirmed fractal swing point.                                  |
//+------------------------------------------------------------------+
struct SSwing
  {
   bool              isHigh;        // true = swing high, false = swing low
   double            price;         // the extreme price
   datetime          time;          // bar time of the extreme
   int               shift;         // bar shift at the time of confirmation
   bool              confirmed;     // N candles have closed beyond it
   bool              swept;         // liquidity beyond it has been taken
  };

//+------------------------------------------------------------------+
//| A supply / demand / gap zone.                                     |
//+------------------------------------------------------------------+
struct SZone
  {
   ENUM_SEA_ZONE_TYPE  type;
   ENUM_SEA_ZONE_STATE state;
   ENUM_SEA_DIRECTION  bias;        // direction the zone supports
   double              upper;       // zone top in price
   double              lower;       // zone bottom in price
   datetime            originTime;  // bar time the zone formed on
   int                 originShift; // shift at formation
   int                 ageBars;     // bars since formation
   int                 touchCount;  // times price entered the zone
   double              impulseATR;  // strength of the impulse that made it
   bool                overlapsFVG; // an OB with an FVG inside it
  };

//+------------------------------------------------------------------+
//| A liquidity pool: equal highs/lows or a session extreme.          |
//+------------------------------------------------------------------+
struct SLiquidity
  {
   double            price;
   datetime          time;
   bool              isHigh;        // buy-side liquidity when true
   bool              swept;         // wicked beyond and reclaimed
   int               touchCount;    // how many times it was tested
   double            strength;      // 0..1, from touch count and cleanliness
  };

//+------------------------------------------------------------------+
//| One hard gate's verdict.                                          |
//+------------------------------------------------------------------+
struct SGate
  {
   bool              passed;
   string            name;
   string            detail;        // why it failed, or the measured value
  };

//+------------------------------------------------------------------+
//| Full result of the gate battery. All ten are always reported.     |
//+------------------------------------------------------------------+
struct SGateResult
  {
   SGate             gates[10];
   bool              allPassed;
   int               failedCount;
   string            firstFailure;
  };

//+------------------------------------------------------------------+
//| A trade candidate produced by the scanner.                        |
//|                                                                   |
//| Every field traces to a structural fact. If a candidate cannot    |
//| name its zone origin and its invalidation level, it is a bug.     |
//+------------------------------------------------------------------+
struct SSetup
  {
   bool                  valid;
   string                symbol;
   int                   specIndex;      // CSymbolSpec cache index
   ENUM_SEA_DIRECTION    direction;

   //--- structural justification
   double                entryPrice;     // pending order level
   double                stopPrice;      // structural invalidation
   double                targetPrice;    // nearest opposing liquidity
   double                zoneUpper;
   double                zoneLower;
   ENUM_SEA_ZONE_TYPE    zoneType;
   ENUM_SEA_TRIGGER      trigger;
   ENUM_SEA_BREAK_TYPE   breakType;
   datetime              zoneOriginTime;

   //--- context
   ENUM_SEA_PHASE        phase;
   ENUM_SEA_REGIME       regime;
   int                   mtfAlignment;   // -100..+100
   double                probability;    // 0..100 from CProbabilityMap
   bool                  reversalHypothesis; // false = breakout hypothesis
   double                hypothesisMargin;

   //--- scoring
   double                score;
   string                scoreBreakdown;

   //--- sizing
   double                lots;
   double                riskMoney;
   double                riskPercent;
   double                rr;

   //--- bookkeeping
   datetime              createdAt;
   int                   expiryBars;
  };

//+------------------------------------------------------------------+
//| Measured statistical profile of one (symbol, style) pair.         |
//+------------------------------------------------------------------+
struct SProfile
  {
   bool                  complete;        // enough bars measured
   string                symbol;
   int                   styleId;
   datetime              lastUpdated;
   int                   barsMeasured;

   //--- the eight metrics
   double                trendPersistence;   // variance ratio
   double                volatilityCharacter;// StdDev(ATR)/Mean(ATR)
   double                tailRisk;           // max range / median ATR
   double                tailEventsPer1000;
   double                structuralCleanliness; // confirmed / candidates
   double                rangeCycleBars;
   double                drift;              // mean return per bar
   double                executionDrag;      // spread / structural stop
   double                sessionSensitivity; // variance of hourly ATR

   //--- derived
   ENUM_SEA_BEHAVIOUR    behaviour;
   int                   fractalBars;
   double                impulseATR;
   double                stopATRMult;
   double                minConfluence;
   int                   maxScaleIns;
   int                   accumMinBars;

   //--- spike character
   bool                  spikeDriven;
   int                   spikeCount;
   double                spikeMeanIntervalBars;
   double                spikeMeanMagnitude;
   ENUM_SEA_DIRECTION    spikeDirection;
   double                spikeConsistency;
  };

//+------------------------------------------------------------------+
//| Copy rates safely.                                                |
//|                                                                   |
//| RULE 9: an unsynchronised series is NOT "no signal". This returns |
//| false so the caller skips and retries rather than deciding on     |
//| absent data.                                                      |
//+------------------------------------------------------------------+
bool SeaCopyRates(const string symbol,const ENUM_TIMEFRAMES tf,
                  const int start,const int count,MqlRates &rates[])
  {
   long synced=0;
   if(!SeriesInfoInteger(symbol,tf,SERIES_SYNCHRONIZED,synced) || synced==0)
      return(false);

   ArraySetAsSeries(rates,true);
   int got=CopyRates(symbol,tf,start,count,rates);
   return(got==count);
  }

//+------------------------------------------------------------------+
//| Copy an indicator buffer safely. Same rule as SeaCopyRates.       |
//+------------------------------------------------------------------+
bool SeaCopyBuffer(const int handle,const int buffer,
                   const int start,const int count,double &values[])
  {
   if(handle==INVALID_HANDLE)
      return(false);
   if(BarsCalculated(handle)<start+count)
      return(false);

   ArraySetAsSeries(values,true);
   int got=CopyBuffer(handle,buffer,start,count,values);
   return(got==count);
  }

//+------------------------------------------------------------------+
//| Number of bars available, or 0 when unsynchronised.               |
//+------------------------------------------------------------------+
int SeaAvailableBars(const string symbol,const ENUM_TIMEFRAMES tf)
  {
   long synced=0;
   if(!SeriesInfoInteger(symbol,tf,SERIES_SYNCHRONIZED,synced) || synced==0)
      return(0);
   return((int)SeriesInfoInteger(symbol,tf,SERIES_BARS_COUNT));
  }

//+------------------------------------------------------------------+
//| Direction helpers.                                                |
//+------------------------------------------------------------------+
string SeaDirectionToString(const ENUM_SEA_DIRECTION dir)
  {
   if(dir==SEA_DIR_LONG)
      return("LONG");
   if(dir==SEA_DIR_SHORT)
      return("SHORT");
   return("NONE");
  }

ENUM_SEA_DIRECTION SeaOpposite(const ENUM_SEA_DIRECTION dir)
  {
   if(dir==SEA_DIR_LONG)
      return(SEA_DIR_SHORT);
   if(dir==SEA_DIR_SHORT)
      return(SEA_DIR_LONG);
   return(SEA_DIR_NONE);
  }

string SeaStructStateToString(const ENUM_SEA_STRUCT_STATE s)
  {
   switch(s)
     {
      case SEA_STRUCT_BULLISH: return("BULLISH");
      case SEA_STRUCT_BEARISH: return("BEARISH");
      case SEA_STRUCT_RANGING: return("RANGING");
     }
   return("UNKNOWN");
  }

string SeaPhaseToString(const ENUM_SEA_PHASE p)
  {
   switch(p)
     {
      case SEA_PHASE_ACCUMULATION: return("ACCUMULATION");
      case SEA_PHASE_MANIPULATION: return("MANIPULATION");
      case SEA_PHASE_DISTRIBUTION: return("DISTRIBUTION");
     }
   return("UNDEFINED");
  }

string SeaRegimeToString(const ENUM_SEA_REGIME r)
  {
   switch(r)
     {
      case SEA_REGIME_TRENDING:    return("TRENDING");
      case SEA_REGIME_RANGING:     return("RANGING");
      case SEA_REGIME_EXPANSION:   return("EXPANSION");
      case SEA_REGIME_COMPRESSION: return("COMPRESSION");
     }
   return("UNDEFINED");
  }

string SeaZoneTypeToString(const ENUM_SEA_ZONE_TYPE z)
  {
   switch(z)
     {
      case SEA_ZONE_OB_DEMAND:    return("OB_DEMAND");
      case SEA_ZONE_OB_SUPPLY:    return("OB_SUPPLY");
      case SEA_ZONE_FVG_BULL:     return("FVG_BULL");
      case SEA_ZONE_FVG_BEAR:     return("FVG_BEAR");
      case SEA_ZONE_BREAKER_BULL: return("BREAKER_BULL");
      case SEA_ZONE_BREAKER_BEAR: return("BREAKER_BEAR");
      case SEA_ZONE_IFVG_BULL:    return("IFVG_BULL");
      case SEA_ZONE_IFVG_BEAR:    return("IFVG_BEAR");
     }
   return("NONE");
  }

string SeaZoneStateToString(const ENUM_SEA_ZONE_STATE s)
  {
   switch(s)
     {
      case SEA_ZONE_FRESH:     return("FRESH");
      case SEA_ZONE_TAPPED:    return("TAPPED");
      case SEA_ZONE_MITIGATED: return("MITIGATED");
      case SEA_ZONE_INVERTED:  return("INVERTED");
      case SEA_ZONE_EXPIRED:   return("EXPIRED");
     }
   return("?");
  }

string SeaTriggerToString(const ENUM_SEA_TRIGGER t)
  {
   switch(t)
     {
      case SEA_TRIGGER_REJECTION_WICK: return("REJECTION_WICK");
      case SEA_TRIGGER_ENGULFING:      return("ENGULFING");
      case SEA_TRIGGER_INSIDE_BREAK:   return("INSIDE_BREAK");
      case SEA_TRIGGER_MOMENTUM_CLOSE: return("MOMENTUM_CLOSE");
     }
   return("NONE");
  }

string SeaBehaviourToString(const ENUM_SEA_BEHAVIOUR b)
  {
   switch(b)
     {
      case SEA_BEHAVIOUR_TREND_FOLLOWER: return("TREND_FOLLOWER");
      case SEA_BEHAVIOUR_MEAN_REVERTER:  return("MEAN_REVERTER");
      case SEA_BEHAVIOUR_BREAKOUT:       return("BREAKOUT");
      case SEA_BEHAVIOUR_SPIKE_DRIVEN:   return("SPIKE_DRIVEN");
      case SEA_BEHAVIOUR_NOISY_AVOID:    return("NOISY_AVOID");
     }
   return("UNCLASSIFIED");
  }

string SeaHazardToString(const ENUM_SEA_HAZARD h)
  {
   switch(h)
     {
      case SEA_HAZARD_LOW:     return("LOW");
      case SEA_HAZARD_MEDIUM:  return("MEDIUM");
      case SEA_HAZARD_HIGH:    return("HIGH");
      case SEA_HAZARD_EXTREME: return("EXTREME");
     }
   return("?");
  }

//+------------------------------------------------------------------+
//| Median of a double array. Sorts a copy, leaves the input alone.   |
//+------------------------------------------------------------------+
double SeaMedian(const double &values[])
  {
   int n=ArraySize(values);
   if(n<=0)
      return(0.0);

   double work[];
   ArrayResize(work,n);
   ArrayCopy(work,values);
   ArraySort(work);

   if((n%2)==1)
      return(work[n/2]);
   return((work[n/2-1]+work[n/2])*0.5);
  }

//+------------------------------------------------------------------+
//| Mean of a double array.                                           |
//+------------------------------------------------------------------+
double SeaMean(const double &values[])
  {
   int n=ArraySize(values);
   if(n<=0)
      return(0.0);
   double sum=0.0;
   for(int i=0; i<n; i++)
      sum+=values[i];
   return(sum/(double)n);
  }

//+------------------------------------------------------------------+
//| Population standard deviation of a double array.                  |
//+------------------------------------------------------------------+
double SeaStdDev(const double &values[])
  {
   int n=ArraySize(values);
   if(n<=1)
      return(0.0);
   double m=SeaMean(values);
   double acc=0.0;
   for(int i=0; i<n; i++)
     {
      double d=values[i]-m;
      acc+=d*d;
     }
   return(MathSqrt(acc/(double)n));
  }

//+------------------------------------------------------------------+
//| CIndicatorPool                                                    |
//|                                                                   |
//| The one place indicator handles are born and die.                 |
//|                                                                   |
//| RULE 8: handles are created here on tier promotion or in OnInit,  |
//| cached by (symbol, timeframe, kind, period), and released through |
//| IndicatorRelease. Nothing calls iATR or iADX in OnTick.           |
//+------------------------------------------------------------------+
#define SEA_IND_ATR   1
#define SEA_IND_ADX   2

struct SIndicatorEntry
  {
   string            symbol;
   ENUM_TIMEFRAMES   timeframe;
   int               kind;
   int               period;
   int               handle;
   int               refCount;
  };

class CIndicatorPool
  {
private:
   SIndicatorEntry   m_entries[];
   int               m_warnThreshold;   // warn above this many live handles
   bool              m_warned;
   bool              m_verbose;

   int               Find(const string symbol,const ENUM_TIMEFRAMES tf,
                          const int kind,const int period) const;
   int               Create(const string symbol,const ENUM_TIMEFRAMES tf,
                            const int kind,const int period) const;

public:
                     CIndicatorPool(void);
                    ~CIndicatorPool(void);

   //! Print pool diagnostics. Off by default.
   void              SetVerbose(const bool enabled) { m_verbose=enabled; }

   //! Warn once when the live handle count passes this threshold.
   //! Documented range 50..2000, default 400 per the architecture.
   void              SetWarnThreshold(const int threshold);

   //! Acquire a cached ATR handle, creating it on first request.
   //! Returns INVALID_HANDLE on failure. Never call from OnTick.
   int               AcquireATR(const string symbol,const ENUM_TIMEFRAMES tf,const int period);

   //! Acquire a cached ADX handle. Never call from OnTick.
   int               AcquireADX(const string symbol,const ENUM_TIMEFRAMES tf,const int period);

   //! Drop one reference. The handle is released when the count hits zero.
   void              Release(const int handle);

   //! Release every handle held for a symbol. Call on tier demotion.
   int               ReleaseSymbol(const string symbol);

   //! Release everything. Call from OnDeinit.
   void              ReleaseAll(void);

   //! Number of live handles.
   int               LiveHandles(void) const { return ArraySize(m_entries); }

   //! Latest value of an indicator buffer at a closed-bar shift.
   //! shift must be >= 1 in any signal path.
   bool              Value(const int handle,const int buffer,const int shift,double &value) const;
  };

//+------------------------------------------------------------------+
CIndicatorPool::CIndicatorPool(void)
  {
   m_warnThreshold=400;
   m_warned=false;
   m_verbose=false;
   ArrayResize(m_entries,0);
  }

//+------------------------------------------------------------------+
CIndicatorPool::~CIndicatorPool(void)
  {
   ReleaseAll();
  }

//+------------------------------------------------------------------+
void CIndicatorPool::SetWarnThreshold(const int threshold)
  {
   m_warnThreshold=(threshold<50 ? 50 : (threshold>2000 ? 2000 : threshold));
  }

//+------------------------------------------------------------------+
int CIndicatorPool::Find(const string symbol,const ENUM_TIMEFRAMES tf,
                         const int kind,const int period) const
  {
   for(int i=0; i<ArraySize(m_entries); i++)
      if(m_entries[i].kind==kind && m_entries[i].period==period &&
         m_entries[i].timeframe==tf && m_entries[i].symbol==symbol)
         return(i);
   return(-1);
  }

//+------------------------------------------------------------------+
int CIndicatorPool::Create(const string symbol,const ENUM_TIMEFRAMES tf,
                           const int kind,const int period) const
  {
   if(kind==SEA_IND_ATR)
      return(iATR(symbol,tf,period));
   if(kind==SEA_IND_ADX)
      return(iADX(symbol,tf,period));
   return(INVALID_HANDLE);
  }

//+------------------------------------------------------------------+
int CIndicatorPool::AcquireATR(const string symbol,const ENUM_TIMEFRAMES tf,const int period)
  {
   int at=Find(symbol,tf,SEA_IND_ATR,period);
   if(at>=0)
     {
      m_entries[at].refCount++;
      return(m_entries[at].handle);
     }

   int handle=Create(symbol,tf,SEA_IND_ATR,period);
   if(handle==INVALID_HANDLE)
     {
      if(m_verbose)
         PrintFormat("[CIndicatorPool] iATR(%s,%d) failed, error %d",symbol,(int)tf,GetLastError());
      return(INVALID_HANDLE);
     }

   int n=ArraySize(m_entries);
   ArrayResize(m_entries,n+1);
   m_entries[n].symbol    = symbol;
   m_entries[n].timeframe = tf;
   m_entries[n].kind      = SEA_IND_ATR;
   m_entries[n].period    = period;
   m_entries[n].handle    = handle;
   m_entries[n].refCount  = 1;

   if(!m_warned && ArraySize(m_entries)>m_warnThreshold)
     {
      m_warned=true;
      PrintFormat("[CIndicatorPool] WARNING: %d live indicator handles, above the %d threshold",
                  ArraySize(m_entries),m_warnThreshold);
     }
   return(handle);
  }

//+------------------------------------------------------------------+
int CIndicatorPool::AcquireADX(const string symbol,const ENUM_TIMEFRAMES tf,const int period)
  {
   int at=Find(symbol,tf,SEA_IND_ADX,period);
   if(at>=0)
     {
      m_entries[at].refCount++;
      return(m_entries[at].handle);
     }

   int handle=Create(symbol,tf,SEA_IND_ADX,period);
   if(handle==INVALID_HANDLE)
     {
      if(m_verbose)
         PrintFormat("[CIndicatorPool] iADX(%s,%d) failed, error %d",symbol,(int)tf,GetLastError());
      return(INVALID_HANDLE);
     }

   int n=ArraySize(m_entries);
   ArrayResize(m_entries,n+1);
   m_entries[n].symbol    = symbol;
   m_entries[n].timeframe = tf;
   m_entries[n].kind      = SEA_IND_ADX;
   m_entries[n].period    = period;
   m_entries[n].handle    = handle;
   m_entries[n].refCount  = 1;

   if(!m_warned && ArraySize(m_entries)>m_warnThreshold)
     {
      m_warned=true;
      PrintFormat("[CIndicatorPool] WARNING: %d live indicator handles, above the %d threshold",
                  ArraySize(m_entries),m_warnThreshold);
     }
   return(handle);
  }

//+------------------------------------------------------------------+
void CIndicatorPool::Release(const int handle)
  {
   for(int i=0; i<ArraySize(m_entries); i++)
     {
      if(m_entries[i].handle!=handle)
         continue;

      m_entries[i].refCount--;
      if(m_entries[i].refCount>0)
         return;

      IndicatorRelease(m_entries[i].handle);
      int last=ArraySize(m_entries)-1;
      if(i!=last)
         m_entries[i]=m_entries[last];
      ArrayResize(m_entries,last);
      return;
     }
  }

//+------------------------------------------------------------------+
int CIndicatorPool::ReleaseSymbol(const string symbol)
  {
   int freed=0;
   for(int i=ArraySize(m_entries)-1; i>=0; i--)
     {
      if(m_entries[i].symbol!=symbol)
         continue;
      IndicatorRelease(m_entries[i].handle);
      int last=ArraySize(m_entries)-1;
      if(i!=last)
         m_entries[i]=m_entries[last];
      ArrayResize(m_entries,last);
      freed++;
     }
   return(freed);
  }

//+------------------------------------------------------------------+
void CIndicatorPool::ReleaseAll(void)
  {
   for(int i=0; i<ArraySize(m_entries); i++)
      IndicatorRelease(m_entries[i].handle);
   ArrayResize(m_entries,0);
   m_warned=false;
  }

//+------------------------------------------------------------------+
bool CIndicatorPool::Value(const int handle,const int buffer,const int shift,double &value) const
  {
   value=0.0;
   double buf[];
   if(!SeaCopyBuffer(handle,buffer,shift,1,buf))
      return(false);
   value=buf[0];
   return(value!=EMPTY_VALUE);
  }

#endif // SEA_COMMON_MQH
//+------------------------------------------------------------------+
