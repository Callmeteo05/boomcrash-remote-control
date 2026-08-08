//+------------------------------------------------------------------+
//|                                              CSymbolProfiler.mqh  |
//|                                                                   |
//|   Module 10. Eight-metric statistical characterisation.           |
//|                                                                   |
//|   MEASURED, NEVER ASSUMED.                                        |
//|                                                                   |
//|   Nothing in this module matches a symbol name, a family or a     |
//|   broker. An instrument is whatever its own price history says it |
//|   is. A profile with fewer than InpProfileMinBars of history is   |
//|   marked INCOMPLETE and excluded from trading - a guessed profile |
//|   is worse than no profile.                                       |
//|                                                                   |
//|   Metrics are stored per (symbol, style) pair, because the same   |
//|   instrument behaves differently at M5 and H4.                    |
//+------------------------------------------------------------------+
#ifndef SEA_CSYMBOLPROFILER_MQH
#define SEA_CSYMBOLPROFILER_MQH

#include <SEA/SEA_Common.mqh>

#define SEA_PROFILE_FILE   "symbol_profiles.csv"
#define SEA_MAX_PROFILES   512

//+------------------------------------------------------------------+
//| CSymbolProfiler                                                   |
//+------------------------------------------------------------------+
class CSymbolProfiler
  {
private:
   SProfile          m_profiles[];
   int               m_count;

   int               m_lookback;        // InpProfileLookback, default 2000
   int               m_minBars;         // InpProfileMinBars,  default 1000
   double            m_spikeDetectATR;  // InpSpikeDetectATR,  default 5.0
   int               m_spikeMinCount;   // occurrences required, default 30
   double            m_spikeConsistency;// directional consistency, default 0.90
   int               m_atrPeriod;
   bool              m_verbose;

   int               Find(const string symbol,const int styleId) const;
   void              ComputeMetrics(SProfile &p,const MqlRates &r[],const int total,
                                    const double &atr[],const int atrCount) const;
   void              DeriveParameters(SProfile &p) const;
   void              DetectSpikeCharacter(SProfile &p,const MqlRates &r[],const int total,
                                          const double medianATR) const;
   double            VarianceRatio(const MqlRates &r[],const int total,const int q) const;
   double            StructuralCleanliness(const MqlRates &r[],const int total,
                                           const int fractalBars) const;
   double            RangeCycleBars(const double &atr[],const int atrCount) const;
   double            SessionSensitivity(const MqlRates &r[],const int total) const;

public:
                     CSymbolProfiler(void);
                    ~CSymbolProfiler(void);

   //! Configure measurement.
   //!
   //! lookback         200..10000, default 2000  bars measured
   //! minBars          100..10000, default 1000  below this = INCOMPLETE
   //! spikeDetectATR   2.0..20.0,  default 5.0   single-bar range multiple
   //! spikeMinCount    5..500,     default 30    occurrences before believing it
   //! spikeConsistency 0.5..1.0,   default 0.90  directional agreement
   void              Configure(const int lookback,const int minBars,
                               const double spikeDetectATR,const int spikeMinCount,
                               const double spikeConsistency,const int atrPeriod);

   //! Print diagnostics. Off by default.
   void              SetVerbose(const bool enabled) { m_verbose=enabled; }

   //! Measure one (symbol, style) pair at the given timeframe.
   //! Returns false when the series is unsynchronised or too short.
   //! A short series still stores an INCOMPLETE profile so the scanner
   //! can report why the symbol is excluded.
   bool              Profile(const string symbol,const int styleId,
                             const ENUM_TIMEFRAMES execTF,CIndicatorPool &pool);

   //! Copy out a stored profile. Returns false when not measured.
   bool              Get(const string symbol,const int styleId,SProfile &out) const;

   //! True when a complete profile exists. Trading requires this.
   bool              IsComplete(const string symbol,const int styleId) const;

   //! Number of profiles held.
   int               Count(void) const { return m_count; }

   //! Copy out a profile by index.
   bool              At(const int index,SProfile &out) const;

   //--- persistence ------------------------------------------------------
   //! Write every profile to MQL5/Files/symbol_profiles.csv.
   //! Returns the number written, or -1 on failure.
   int               Save(void) const;

   //! Read profiles back. Returns the number loaded, or -1 on failure.
   int               Load(void);

   //--- diagnostics --------------------------------------------------------
   //! Multi-line dump of one profile.
   string            Describe(const string symbol,const int styleId) const;
  };

//+------------------------------------------------------------------+
CSymbolProfiler::CSymbolProfiler(void)
  {
   m_count            = 0;
   m_lookback         = 2000;
   m_minBars          = 1000;
   m_spikeDetectATR   = 5.0;
   m_spikeMinCount    = 30;
   m_spikeConsistency = 0.90;
   m_atrPeriod        = 14;
   m_verbose          = false;
   ArrayResize(m_profiles,SEA_MAX_PROFILES);
  }

//+------------------------------------------------------------------+
CSymbolProfiler::~CSymbolProfiler(void)
  {
   ArrayFree(m_profiles);
  }

//+------------------------------------------------------------------+
void CSymbolProfiler::Configure(const int lookback,const int minBars,
                                const double spikeDetectATR,const int spikeMinCount,
                                const double spikeConsistency,const int atrPeriod)
  {
   m_lookback         = (lookback<200 ? 200 : (lookback>10000 ? 10000 : lookback));
   m_minBars          = (minBars<100 ? 100 : (minBars>10000 ? 10000 : minBars));
   m_spikeDetectATR   = (spikeDetectATR<2.0 ? 2.0 : (spikeDetectATR>20.0 ? 20.0 : spikeDetectATR));
   m_spikeMinCount    = (spikeMinCount<5 ? 5 : (spikeMinCount>500 ? 500 : spikeMinCount));
   m_spikeConsistency = (spikeConsistency<0.5 ? 0.5 : (spikeConsistency>1.0 ? 1.0 : spikeConsistency));
   m_atrPeriod        = (atrPeriod<2 ? 2 : (atrPeriod>200 ? 200 : atrPeriod));

   if(m_minBars>m_lookback)
      m_minBars=m_lookback;
  }

//+------------------------------------------------------------------+
int CSymbolProfiler::Find(const string symbol,const int styleId) const
  {
   for(int i=0; i<m_count; i++)
      if(m_profiles[i].styleId==styleId && m_profiles[i].symbol==symbol)
         return(i);
   return(-1);
  }

//+------------------------------------------------------------------+
//| METRIC 1: trend persistence via the variance ratio.               |
//|                                                                   |
//| Var(q-period return) / (q * Var(1-period return)).                |
//| > 1.15 trending, < 0.85 mean-reverting, between = neither.        |
//+------------------------------------------------------------------+
double CSymbolProfiler::VarianceRatio(const MqlRates &r[],const int total,const int q) const
  {
   if(total<q*4 || q<2)
      return(1.0);

   //--- one-bar log returns
   double single[];
   ArrayResize(single,total-1);
   int n1=0;
   for(int i=1; i<total; i++)
     {
      if(r[i].close<=0.0 || r[i-1].close<=0.0)
         continue;
      single[n1++]=MathLog(r[i-1].close/r[i].close);
     }
   if(n1<q*3)
      return(1.0);
   ArrayResize(single,n1);

   //--- q-bar log returns, non-overlapping
   int qn=n1/q;
   if(qn<3)
      return(1.0);
   double multi[];
   ArrayResize(multi,qn);
   for(int k=0; k<qn; k++)
     {
      double acc=0.0;
      for(int j=0; j<q; j++)
         acc+=single[k*q+j];
      multi[k]=acc;
     }

   double v1=SeaStdDev(single);
   double vq=SeaStdDev(multi);
   v1*=v1;
   vq*=vq;

   if(v1<=0.0)
      return(1.0);
   return(vq/((double)q*v1));
  }

//+------------------------------------------------------------------+
//| METRIC 4: structural cleanliness.                                 |
//|                                                                   |
//| Confirmed swings divided by fractal candidates. A clean market    |
//| turns most candidates into real swings; a noisy one does not.     |
//+------------------------------------------------------------------+
double CSymbolProfiler::StructuralCleanliness(const MqlRates &r[],const int total,
                                              const int fractalBars) const
  {
   if(total<fractalBars*4)
      return(0.5);

   int candidates=0;
   int confirmed=0;

   for(int i=fractalBars+1; i<total-fractalBars; i++)
     {
      //--- a candidate is a simple local extreme over one bar each side
      bool candHigh=(r[i].high>r[i-1].high && r[i].high>r[i+1].high);
      bool candLow =(r[i].low <r[i-1].low  && r[i].low <r[i+1].low);
      if(!candHigh && !candLow)
         continue;

      candidates++;

      //--- confirmed means it survives the full fractal width
      bool ok=true;
      for(int k=1; k<=fractalBars && ok; k++)
        {
         if(candHigh && (r[i-k].high>=r[i].high || r[i+k].high>=r[i].high))
            ok=false;
         if(candLow && (r[i-k].low<=r[i].low || r[i+k].low<=r[i].low))
            ok=false;
        }
      if(ok)
         confirmed++;
     }

   if(candidates<=0)
      return(0.5);
   return((double)confirmed/(double)candidates);
  }

//+------------------------------------------------------------------+
//| METRIC 5: range cycle - median bars spent in compression before   |
//| volatility expands again.                                         |
//+------------------------------------------------------------------+
double CSymbolProfiler::RangeCycleBars(const double &atr[],const int atrCount) const
  {
   if(atrCount<50)
      return(20.0);

   double med=SeaMedian(atr);
   if(med<=0.0)
      return(20.0);

   double threshold=med*0.70;

   double runs[];
   ArrayResize(runs,0);
   int run=0;

   for(int i=atrCount-1; i>=0; i--)
     {
      if(atr[i]<threshold)
         run++;
      else
        {
         if(run>0)
           {
            int n=ArraySize(runs);
            ArrayResize(runs,n+1);
            runs[n]=(double)run;
           }
         run=0;
        }
     }
   if(run>0)
     {
      int n=ArraySize(runs);
      ArrayResize(runs,n+1);
      runs[n]=(double)run;
     }

   if(ArraySize(runs)<3)
      return(20.0);
   return(SeaMedian(runs));
  }

//+------------------------------------------------------------------+
//| METRIC 8: session sensitivity - variance of ATR across the hours  |
//| of the day, normalised by the mean.                               |
//+------------------------------------------------------------------+
double CSymbolProfiler::SessionSensitivity(const MqlRates &r[],const int total) const
  {
   double sum[24],cnt[24];
   for(int h=0; h<24; h++)
     {
      sum[h]=0.0;
      cnt[h]=0.0;
     }

   for(int i=1; i<total; i++)
     {
      MqlDateTime dt;
      TimeToStruct(r[i].time,dt);
      int h=dt.hour;
      if(h<0 || h>23)
         continue;
      sum[h]+=(r[i].high-r[i].low);
      cnt[h]+=1.0;
     }

   double hourly[];
   ArrayResize(hourly,0);
   for(int h=0; h<24; h++)
     {
      if(cnt[h]<5.0)
         continue;
      int n=ArraySize(hourly);
      ArrayResize(hourly,n+1);
      hourly[n]=sum[h]/cnt[h];
     }

   if(ArraySize(hourly)<4)
      return(0.0);

   double mean=SeaMean(hourly);
   if(mean<=0.0)
      return(0.0);
   return(SeaStdDev(hourly)/mean);
  }

//+------------------------------------------------------------------+
//| Spike character, detected statistically.                          |
//|                                                                   |
//| A spike is a single-bar range above m_spikeDetectATR * median ATR.|
//| The instrument is only called SPIKE_DRIVEN when there are enough  |
//| occurrences AND they overwhelmingly point the same way. That test |
//| works on any instrument, named or not.                            |
//+------------------------------------------------------------------+
void CSymbolProfiler::DetectSpikeCharacter(SProfile &p,const MqlRates &r[],const int total,
                                           const double medianATR) const
  {
   p.spikeDriven           = false;
   p.spikeCount            = 0;
   p.spikeMeanIntervalBars = 0.0;
   p.spikeMeanMagnitude    = 0.0;
   p.spikeDirection        = SEA_DIR_NONE;
   p.spikeConsistency      = 0.0;

   if(medianATR<=0.0 || total<50)
      return;

   double threshold=medianATR*m_spikeDetectATR;

   int    up=0,down=0,count=0;
   double magnitudeSum=0.0;
   int    lastShift=-1;
   double intervalSum=0.0;
   int    intervals=0;

   for(int i=total-1; i>=1; i--)
     {
      double range=r[i].high-r[i].low;
      if(range<threshold)
         continue;

      count++;
      magnitudeSum+=range;

      if(r[i].close>r[i].open)
         up++;
      else
         down++;

      if(lastShift>=0)
        {
         intervalSum+=(double)(lastShift-i);
         intervals++;
        }
      lastShift=i;
     }

   p.spikeCount=count;
   if(count<=0)
      return;

   p.spikeMeanMagnitude=magnitudeSum/(double)count;
   if(intervals>0)
      p.spikeMeanIntervalBars=intervalSum/(double)intervals;

   int dominant=(up>down ? up : down);
   p.spikeConsistency=(double)dominant/(double)count;
   p.spikeDirection=(up>down ? SEA_DIR_LONG : SEA_DIR_SHORT);

   //--- all three conditions, or it is not a spike instrument
   if(count>=m_spikeMinCount && p.spikeConsistency>m_spikeConsistency)
      p.spikeDriven=true;
  }

//+------------------------------------------------------------------+
//| The eight metrics.                                                |
//+------------------------------------------------------------------+
void CSymbolProfiler::ComputeMetrics(SProfile &p,const MqlRates &r[],const int total,
                                     const double &atr[],const int atrCount) const
  {
   //--- 1. trend persistence
   p.trendPersistence=VarianceRatio(r,total,5);

   //--- 2. volatility character
   double atrMean=SeaMean(atr);
   double atrStd =SeaStdDev(atr);
   p.volatilityCharacter=(atrMean>0.0 ? atrStd/atrMean : 0.0);

   //--- 3. tail risk
   double medianATR=SeaMedian(atr);
   double maxRange=0.0;
   int    bigBars=0;
   for(int i=1; i<total; i++)
     {
      double range=r[i].high-r[i].low;
      if(range>maxRange)
         maxRange=range;
      if(medianATR>0.0 && range>medianATR*5.0)
         bigBars++;
     }
   p.tailRisk=(medianATR>0.0 ? maxRange/medianATR : 0.0);
   p.tailEventsPer1000=(total>1 ? (double)bigBars*1000.0/(double)(total-1) : 0.0);

   //--- 4. structural cleanliness, measured at the default fractal width
   p.structuralCleanliness=StructuralCleanliness(r,total,3);

   //--- 5. range cycle
   p.rangeCycleBars=RangeCycleBars(atr,atrCount);

   //--- 6. drift
   double driftSum=0.0;
   int    driftN=0;
   for(int i=1; i<total; i++)
     {
      if(r[i].close<=0.0 || r[i-1].close<=0.0)
         continue;
      driftSum+=MathLog(r[i-1].close/r[i].close);
      driftN++;
     }
   p.drift=(driftN>0 ? driftSum/(double)driftN : 0.0);

   //--- 7. execution drag: median spread over the median structural stop
   double spreads[];
   ArrayResize(spreads,total-1>0 ? total-1 : 1);
   int sn=0;
   for(int i=1; i<total; i++)
      if(r[i].spread>0)
         spreads[sn++]=(double)r[i].spread;

   double medianSpreadPoints=0.0;
   if(sn>0)
     {
      ArrayResize(spreads,sn);
      medianSpreadPoints=SeaMedian(spreads);
     }

   double point=SymbolInfoDouble(p.symbol,SYMBOL_POINT);
   double medianSpreadPrice=medianSpreadPoints*point;
   //--- the structural stop this style would use, in price units
   double typicalStop=medianATR*2.5;
   p.executionDrag=(typicalStop>0.0 ? medianSpreadPrice/typicalStop : 1.0);

   //--- 8. session sensitivity
   p.sessionSensitivity=SessionSensitivity(r,total);

   //--- spike character
   DetectSpikeCharacter(p,r,total,medianATR);
  }

//+------------------------------------------------------------------+
//| Behaviour and derived parameters.                                 |
//|                                                                   |
//| Every branch reads a MEASURED number. No symbol name appears.     |
//+------------------------------------------------------------------+
void CSymbolProfiler::DeriveParameters(SProfile &p) const
  {
   //--- behaviour classification, most specific first
   if(p.spikeDriven)
      p.behaviour=SEA_BEHAVIOUR_SPIKE_DRIVEN;
   else
      if(p.structuralCleanliness<0.25 || p.executionDrag>0.40)
         p.behaviour=SEA_BEHAVIOUR_NOISY_AVOID;
      else
         if(p.trendPersistence>1.15)
            p.behaviour=SEA_BEHAVIOUR_TREND_FOLLOWER;
         else
            if(p.trendPersistence<0.85)
               p.behaviour=SEA_BEHAVIOUR_MEAN_REVERTER;
            else
               if(p.volatilityCharacter>0.60)
                  p.behaviour=SEA_BEHAVIOUR_BREAKOUT;
               else
                  p.behaviour=SEA_BEHAVIOUR_UNCLASSIFIED;

   //--- FractalBars: 3 clean -> 7 noisy
   double clean=p.structuralCleanliness;
   if(clean>=0.60)
      p.fractalBars=3;
   else
      if(clean>=0.45)
         p.fractalBars=4;
      else
         if(clean>=0.32)
            p.fractalBars=5;
         else
            if(clean>=0.22)
               p.fractalBars=6;
            else
               p.fractalBars=7;

   //--- ImpulseATR: 2.0 uniform -> 4.0 clustered
   double vc=p.volatilityCharacter;
   p.impulseATR=2.0+(vc>0.0 ? MathMin(2.0,vc*2.5) : 0.0);

   //--- StopATRMult: 1.5 low tail -> 4.0 high tail
   double tail=p.tailRisk;
   if(tail<=3.0)
      p.stopATRMult=1.5;
   else
      if(tail>=15.0)
         p.stopATRMult=4.0;
      else
         p.stopATRMult=1.5+(tail-3.0)/12.0*2.5;

   //--- MinConfluence: 70 clean -> 90 noisy
   p.minConfluence=90.0-MathMin(20.0,clean*20.0/0.60);
   if(p.minConfluence<70.0)
      p.minConfluence=70.0;
   if(p.minConfluence>90.0)
      p.minConfluence=90.0;

   //--- MaxScaleIns: 0 reverter -> 3 trender
   if(p.behaviour==SEA_BEHAVIOUR_MEAN_REVERTER || p.behaviour==SEA_BEHAVIOUR_NOISY_AVOID)
      p.maxScaleIns=0;
   else
      if(p.trendPersistence>1.30)
         p.maxScaleIns=3;
      else
         if(p.trendPersistence>1.15)
            p.maxScaleIns=2;
         else
            p.maxScaleIns=1;

   //--- AccumMinBars from the measured compression length
   p.accumMinBars=(int)MathRound(p.rangeCycleBars);
   if(p.accumMinBars<5)
      p.accumMinBars=5;
   if(p.accumMinBars>200)
      p.accumMinBars=200;
  }

//+------------------------------------------------------------------+
bool CSymbolProfiler::Profile(const string symbol,const int styleId,
                              const ENUM_TIMEFRAMES execTF,CIndicatorPool &pool)
  {
   int slot=Find(symbol,styleId);
   if(slot<0)
     {
      if(m_count>=SEA_MAX_PROFILES)
        {
         if(m_verbose)
            Print("[CSymbolProfiler] profile store full");
         return(false);
        }
      slot=m_count;
      m_count++;
     }

   SProfile p;
   p.symbol       = symbol;
   p.styleId      = styleId;
   p.complete     = false;
   p.lastUpdated  = TimeCurrent();
   p.barsMeasured = 0;
   p.behaviour    = SEA_BEHAVIOUR_UNCLASSIFIED;
   //--- conservative defaults, used only while INCOMPLETE and never traded
   p.fractalBars   = 3;
   p.impulseATR    = 2.0;
   p.stopATRMult   = 2.5;
   p.minConfluence = 90.0;
   p.maxScaleIns   = 0;
   p.accumMinBars  = 20;

   int available=SeaAvailableBars(symbol,execTF);
   if(available<=0)
     {
      m_profiles[slot]=p;
      return(false);   // unsynchronised: skip and retry, do not mark measured
     }

   int want=(available<m_lookback ? available : m_lookback);

   MqlRates r[];
   if(!SeaCopyRates(symbol,execTF,0,want,r))
     {
      m_profiles[slot]=p;
      return(false);
     }

   int total=ArraySize(r);
   p.barsMeasured=total;

   if(total<m_minBars)
     {
      //--- INCOMPLETE. Stored so the scanner can explain the exclusion,
      //--- but never tradeable.
      m_profiles[slot]=p;
      if(m_verbose)
         PrintFormat("[CSymbolProfiler] %s style %d INCOMPLETE: %d bars, need %d",
                     symbol,styleId,total,m_minBars);
      return(true);
     }

   int atrHandle=pool.AcquireATR(symbol,execTF,m_atrPeriod);
   if(atrHandle==INVALID_HANDLE)
     {
      m_profiles[slot]=p;
      return(false);
     }

   double atr[];
   int atrWant=total-m_atrPeriod-1;
   if(atrWant<50)
      atrWant=50;
   bool gotATR=SeaCopyBuffer(atrHandle,0,1,atrWant,atr);
   pool.Release(atrHandle);

   if(!gotATR)
     {
      m_profiles[slot]=p;
      return(false);
     }

   ComputeMetrics(p,r,total,atr,ArraySize(atr));
   DeriveParameters(p);

   p.complete=true;
   m_profiles[slot]=p;

   if(m_verbose)
      Print("[CSymbolProfiler] ",Describe(symbol,styleId));

   return(true);
  }

//+------------------------------------------------------------------+
bool CSymbolProfiler::Get(const string symbol,const int styleId,SProfile &out) const
  {
   int i=Find(symbol,styleId);
   if(i<0)
      return(false);
   out=m_profiles[i];
   return(true);
  }

//+------------------------------------------------------------------+
bool CSymbolProfiler::IsComplete(const string symbol,const int styleId) const
  {
   int i=Find(symbol,styleId);
   return(i>=0 && m_profiles[i].complete);
  }

//+------------------------------------------------------------------+
bool CSymbolProfiler::At(const int index,SProfile &out) const
  {
   if(index<0 || index>=m_count)
      return(false);
   out=m_profiles[index];
   return(true);
  }

//+------------------------------------------------------------------+
int CSymbolProfiler::Save(void) const
  {
   int h=FileOpen(SEA_PROFILE_FILE,FILE_WRITE|FILE_CSV|FILE_ANSI,',');
   if(h==INVALID_HANDLE)
     {
      PrintFormat("[CSymbolProfiler] cannot open %s for writing, error %d",
                  SEA_PROFILE_FILE,GetLastError());
      return(-1);
     }

   FileWrite(h,"symbol","style","complete","bars","last_updated",
             "trend_persistence","volatility_character","tail_risk","tail_per_1000",
             "cleanliness","range_cycle","drift","exec_drag","session_sensitivity",
             "behaviour","fractal_bars","impulse_atr","stop_atr_mult","min_confluence",
             "max_scale_ins","accum_min_bars",
             "spike_driven","spike_count","spike_interval","spike_magnitude",
             "spike_direction","spike_consistency");

   for(int i=0; i<m_count; i++)
     {
      SProfile p=m_profiles[i];
      FileWrite(h,p.symbol,p.styleId,(p.complete ? 1 : 0),p.barsMeasured,
                TimeToString(p.lastUpdated,TIME_DATE|TIME_SECONDS),
                DoubleToString(p.trendPersistence,6),
                DoubleToString(p.volatilityCharacter,6),
                DoubleToString(p.tailRisk,6),
                DoubleToString(p.tailEventsPer1000,6),
                DoubleToString(p.structuralCleanliness,6),
                DoubleToString(p.rangeCycleBars,3),
                DoubleToString(p.drift,10),
                DoubleToString(p.executionDrag,6),
                DoubleToString(p.sessionSensitivity,6),
                SeaBehaviourToString(p.behaviour),
                p.fractalBars,
                DoubleToString(p.impulseATR,3),
                DoubleToString(p.stopATRMult,3),
                DoubleToString(p.minConfluence,2),
                p.maxScaleIns,p.accumMinBars,
                (p.spikeDriven ? 1 : 0),p.spikeCount,
                DoubleToString(p.spikeMeanIntervalBars,3),
                DoubleToString(p.spikeMeanMagnitude,8),
                (int)p.spikeDirection,
                DoubleToString(p.spikeConsistency,4));
     }

   FileClose(h);
   return(m_count);
  }

//+------------------------------------------------------------------+
int CSymbolProfiler::Load(void)
  {
   if(!FileIsExist(SEA_PROFILE_FILE))
      return(0);

   int h=FileOpen(SEA_PROFILE_FILE,FILE_READ|FILE_CSV|FILE_ANSI,',');
   if(h==INVALID_HANDLE)
      return(-1);

   m_count=0;
   bool header=true;

   while(!FileIsEnding(h) && m_count<SEA_MAX_PROFILES)
     {
      string symbol=FileReadString(h);
      if(header)
        {
         //--- consume the rest of the header row
         for(int k=0; k<27 && !FileIsLineEnding(h); k++)
            FileReadString(h);
         header=false;
         continue;
        }
      if(symbol=="")
         break;

      SProfile p;
      p.symbol                = symbol;
      p.styleId               = (int)StringToInteger(FileReadString(h));
      p.complete              = (StringToInteger(FileReadString(h))!=0);
      p.barsMeasured          = (int)StringToInteger(FileReadString(h));
      p.lastUpdated           = StringToTime(FileReadString(h));
      p.trendPersistence      = StringToDouble(FileReadString(h));
      p.volatilityCharacter   = StringToDouble(FileReadString(h));
      p.tailRisk              = StringToDouble(FileReadString(h));
      p.tailEventsPer1000     = StringToDouble(FileReadString(h));
      p.structuralCleanliness = StringToDouble(FileReadString(h));
      p.rangeCycleBars        = StringToDouble(FileReadString(h));
      p.drift                 = StringToDouble(FileReadString(h));
      p.executionDrag         = StringToDouble(FileReadString(h));
      p.sessionSensitivity    = StringToDouble(FileReadString(h));
      FileReadString(h);   // behaviour text, re-derived below
      p.fractalBars           = (int)StringToInteger(FileReadString(h));
      p.impulseATR            = StringToDouble(FileReadString(h));
      p.stopATRMult           = StringToDouble(FileReadString(h));
      p.minConfluence         = StringToDouble(FileReadString(h));
      p.maxScaleIns           = (int)StringToInteger(FileReadString(h));
      p.accumMinBars          = (int)StringToInteger(FileReadString(h));
      p.spikeDriven           = (StringToInteger(FileReadString(h))!=0);
      p.spikeCount            = (int)StringToInteger(FileReadString(h));
      p.spikeMeanIntervalBars = StringToDouble(FileReadString(h));
      p.spikeMeanMagnitude    = StringToDouble(FileReadString(h));
      p.spikeDirection        = (ENUM_SEA_DIRECTION)StringToInteger(FileReadString(h));
      p.spikeConsistency      = StringToDouble(FileReadString(h));

      //--- behaviour is re-derived from the metrics rather than trusted
      //--- from the file, so an edited CSV cannot inject a classification
      DeriveParameters(p);

      m_profiles[m_count]=p;
      m_count++;
     }

   FileClose(h);

   if(m_verbose)
      PrintFormat("[CSymbolProfiler] loaded %d profiles",m_count);

   return(m_count);
  }

//+------------------------------------------------------------------+
string CSymbolProfiler::Describe(const string symbol,const int styleId) const
  {
   int i=Find(symbol,styleId);
   if(i<0)
      return(StringFormat("%s style %d: not profiled",symbol,styleId));

   SProfile p=m_profiles[i];

   if(!p.complete)
      return(StringFormat("%s style %d: INCOMPLETE (%d bars, need %d) - excluded from trading",
                          symbol,styleId,p.barsMeasured,m_minBars));

   return(StringFormat("%s style %d %s bars=%d | persist=%.3f volChar=%.3f tail=%.1f(%.1f/1000) "
                       "clean=%.3f cycle=%.1f drift=%.2e drag=%.3f session=%.3f | "
                       "fractal=%d impulse=%.1f stopATR=%.2f minConf=%.0f legs=%d accum=%d | "
                       "spike=%s n=%d interval=%.1f consistency=%.2f",
                       p.symbol,p.styleId,SeaBehaviourToString(p.behaviour),p.barsMeasured,
                       p.trendPersistence,p.volatilityCharacter,p.tailRisk,p.tailEventsPer1000,
                       p.structuralCleanliness,p.rangeCycleBars,p.drift,p.executionDrag,
                       p.sessionSensitivity,
                       p.fractalBars,p.impulseATR,p.stopATRMult,p.minConfluence,
                       p.maxScaleIns,p.accumMinBars,
                       (p.spikeDriven ? "YES" : "no"),p.spikeCount,
                       p.spikeMeanIntervalBars,p.spikeConsistency));
  }

#endif // SEA_CSYMBOLPROFILER_MQH
//+------------------------------------------------------------------+
