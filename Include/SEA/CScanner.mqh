//+------------------------------------------------------------------+
//|                                                     CScanner.mqh  |
//|                                                                   |
//|   Module 19. Tiered universe scan and ranking.                    |
//|                                                                   |
//|   TIER 3 COLD  full universe, refreshed on HTF bar close, bias    |
//|   TIER 2 WARM  ~15-30 symbols, LTF bar close, zones and freshness |
//|   TIER 1 HOT   max InpMaxHotSymbols, every tick, triggers only    |
//|                                                                   |
//|   THE SCANNER RETURNS CANDIDATES ONLY. It never executes.         |
//|                                                                   |
//|   Indicator handles are created on Tier 2 promotion and released  |
//|   on demotion, which is what keeps the handle count bounded.      |
//+------------------------------------------------------------------+
#ifndef SEA_CSCANNER_MQH
#define SEA_CSCANNER_MQH

#include <SEA/SEA_Common.mqh>
#include <SEA/CSymbolSpec.mqh>
#include <SEA/CStyle.mqh>
#include <SEA/CMTF.mqh>
#include <SEA/CPhase.mqh>
#include <SEA/CRegime.mqh>
#include <SEA/CSymbolProfiler.mqh>
#include <SEA/CSpikeHazard.mqh>
#include <SEA/CAffordability.mqh>
#include <SEA/CProbabilityMap.mqh>
#include <SEA/CGates.mqh>
#include <SEA/CScoring.mqh>
#include <SEA/CRiskManager.mqh>

#define SEA_TIER_COLD  3
#define SEA_TIER_WARM  2
#define SEA_TIER_HOT   1

#define SEA_MAX_UNIVERSE  512
#define SEA_MAX_WARM      32
#define SEA_MAX_HOT       10
#define SEA_MAX_CANDIDATES 32

//+------------------------------------------------------------------+
//| One symbol's place in the universe.                               |
//+------------------------------------------------------------------+
struct SScanEntry
  {
   string             symbol;
   int                specIndex;
   int                tier;
   bool               profiled;
   bool               tradeable;
   ENUM_SEA_DIRECTION coldBias;
   double             rankScore;
   datetime           promotedAt;
   string             exclusion;      // why it is not tradeable
  };

//+------------------------------------------------------------------+
//| CScanner                                                          |
//+------------------------------------------------------------------+
class CScanner
  {
private:
   SScanEntry        m_universe[];
   int               m_count;

   //--- warm engines, one slot per warm symbol
   CMTF             *m_mtf[SEA_MAX_WARM];
   CPhase           *m_phase[SEA_MAX_WARM];
   CRegime          *m_regime[SEA_MAX_WARM];
   string            m_warmSymbol[SEA_MAX_WARM];
   int               m_warmCount;

   string            m_hotSymbol[SEA_MAX_HOT];
   double            m_hotScore[SEA_MAX_HOT];
   int               m_hotCount;
   int               m_maxHot;
   int               m_maxWarm;

   SSetup            m_candidates[];
   int               m_candidateCount;

   bool              m_verbose;
   int               m_handleWarnThreshold;

   int               FindUniverse(const string symbol) const;
   int               FindWarm(const string symbol) const;
   int               FindHot(const string symbol) const;
   bool              AllocateWarm(const string symbol);
   void              FreeWarm(const int slot,CIndicatorPool &pool);

public:
                     CScanner(void);
                    ~CScanner(void);

   //! Configure tier sizes.
   //!
   //! maxHot   1..10, default 5
   //! maxWarm  4..32, default 24
   void              Configure(const int maxHot,const int maxWarm);

   //! Print diagnostics. Off by default.
   void              SetVerbose(const bool enabled) { m_verbose=enabled; }

   //--- universe ----------------------------------------------------------
   //! Build the cold universe from Market Watch.
   //! Symbols whose spec is unusable are recorded with their exclusion
   //! reason rather than silently dropped.
   int               BuildUniverse(CSymbolSpec &spec,const bool marketWatchOnly);

   //! Universe size.
   int               UniverseSize(void) const { return m_count; }

   //! Copy out a universe entry.
   bool              GetEntry(const int index,SScanEntry &out) const;

   //! Count of symbols at a tier.
   int               TierCount(const int tier) const;

   //--- tier 3: cold ---------------------------------------------------------
   //! Refresh the cold universe: profile, affordability, directional
   //! bias. Runs on HTF bar close.
   //! Returns the number of tradeable symbols found.
   int               RefreshCold(CSymbolSpec &spec,CStyle &style,CIndicatorPool &pool,
                                 CSymbolProfiler &profiler,CAffordability &afford,
                                 CRiskManager &risk,CSpikeHazard &hazard);

   //--- tier 2: warm ----------------------------------------------------------
   //! Promote the best cold symbols to warm, allocating their cascade
   //! engines and indicator handles.
   //! Returns the number of warm symbols after the pass.
   int               PromoteWarm(CSymbolSpec &spec,CStyle &style,CIndicatorPool &pool,
                                 CSymbolProfiler &profiler,const int atrPeriod,
                                 const int staleBars,const int zoneMaxAge,
                                 const double equalTolerance,const int sweepMaxBars,
                                 const int lookback,
                                 const double accumATRRatio,const double accumADXMax,
                                 const double accumRangeATR,const int chochWindow,
                                 const double adxTrending,const double adxRanging,
                                 const double expansionRatio,const double compressionRatio,
                                 const int atrSlowPeriod,const int adxPeriod);

   //! Update every warm symbol's cascade, phase and regime.
   //! Runs on execution-timeframe bar close.
   int               UpdateWarm(void);

   //! Cascade engine for a warm symbol, or NULL.
   CMTF             *MTFOf(const string symbol) const;
   //! Phase engine for a warm symbol, or NULL.
   CPhase           *PhaseOf(const string symbol) const;
   //! Regime engine for a warm symbol, or NULL.
   CRegime          *RegimeOf(const string symbol) const;

   //--- tier 1: hot -------------------------------------------------------------
   //! Promote to hot. A full hot list is only displaced by a
   //! HIGHER-scoring candidate, never by an equal one.
   bool              PromoteHot(const string symbol,const double score);

   //! True when a symbol is hot.
   bool              IsHot(const string symbol) const { return FindHot(symbol)>=0; }

   //! Hot symbol count.
   int               HotCount(void) const { return m_hotCount; }

   //! Hot symbol by index.
   string            HotSymbol(const int index) const;

   //--- candidate generation -------------------------------------------------------
   //! Collect every qualified setup across the warm set.
   //!
   //! Runs the full pipeline per symbol: probability, gates, scoring.
   //! Rejected setups are reported through the callback-free journal
   //! buffer the caller drains afterwards.
   //!
   //! RETURNS CANDIDATES ONLY. Nothing here places an order.
   int               CollectCandidates(CSymbolSpec &spec,CStyle &style,
                                       CProbabilityMap &probability,CGates &gates,
                                       CScoring &scoring,CSpikeHazard &hazard,
                                       CAffordability &afford,CRiskManager &risk,
                                       CSymbolProfiler &profiler);

   //! Number of candidates from the last collection.
   int               CandidateCount(void) const { return m_candidateCount; }

   //! Copy out a candidate. Index 0 is the highest scoring.
   bool              GetCandidate(const int index,SSetup &out) const;

   //! Collapse correlated candidates, keeping the best per currency
   //! group. Returns the surviving count.
   int               ApplyCorrelationCollapse(CSymbolSpec &spec,const int maxPerGroup);

   //! Return the top N candidates for the open slots. The rest are
   //! DISCARDED, never queued - a stale setup is not a setup.
   int               TopCandidates(const int slots,SSetup &out[]) const;

   //! Last gate result for a symbol and direction, for the journal.
   bool              LastGateResult(const string symbol,const ENUM_SEA_DIRECTION dir,
                                    SGateResult &out) const;

   //! The full context behind that gate result: entry, stop, target and
   //! score as they stood when the setup was judged. The journal needs
   //! these to replay a rejection and decide whether it would have won.
   bool              LastGateContext(const string symbol,const ENUM_SEA_DIRECTION dir,
                                     SGateContext &out) const;

   //! Number of gate evaluations recorded on the last collection pass.
   int               GateRecordCount(void) const { return m_lastGateCount; }

   //! Walk the recorded gate evaluations by index.
   bool              GateRecordAt(const int index,SGateContext &ctx,SGateResult &result) const;

   //! One-line summary.
   string            Describe(void) const;

private:
   //--- rejection buffer, drained by the journal
   SGateResult       m_lastGates[SEA_MAX_WARM*2];
   SGateContext      m_lastGateCtx[SEA_MAX_WARM*2];
   string            m_lastGateSymbol[SEA_MAX_WARM*2];
   int               m_lastGateDir[SEA_MAX_WARM*2];
   int               m_lastGateCount;
  };

//+------------------------------------------------------------------+
CScanner::CScanner(void)
  {
   m_count               = 0;
   m_warmCount           = 0;
   m_hotCount            = 0;
   m_maxHot              = 5;
   m_maxWarm             = 24;
   m_candidateCount      = 0;
   m_verbose             = false;
   m_handleWarnThreshold = 400;
   m_lastGateCount       = 0;

   ArrayResize(m_universe,SEA_MAX_UNIVERSE);
   ArrayResize(m_candidates,SEA_MAX_CANDIDATES);

   for(int i=0; i<SEA_MAX_WARM; i++)
     {
      m_mtf[i]        = NULL;
      m_phase[i]      = NULL;
      m_regime[i]     = NULL;
      m_warmSymbol[i] = "";
     }
   for(int i=0; i<SEA_MAX_HOT; i++)
     {
      m_hotSymbol[i]=" ";
      m_hotScore[i] =0.0;
     }
  }

//+------------------------------------------------------------------+
CScanner::~CScanner(void)
  {
   for(int i=0; i<SEA_MAX_WARM; i++)
     {
      if(m_mtf[i]!=NULL)
        {
         delete m_mtf[i];
         m_mtf[i]=NULL;
        }
      if(m_phase[i]!=NULL)
        {
         delete m_phase[i];
         m_phase[i]=NULL;
        }
      if(m_regime[i]!=NULL)
        {
         delete m_regime[i];
         m_regime[i]=NULL;
        }
     }
   ArrayFree(m_universe);
   ArrayFree(m_candidates);
  }

//+------------------------------------------------------------------+
void CScanner::Configure(const int maxHot,const int maxWarm)
  {
   m_maxHot =(maxHot<1 ? 1 : (maxHot>SEA_MAX_HOT ? SEA_MAX_HOT : maxHot));
   m_maxWarm=(maxWarm<4 ? 4 : (maxWarm>SEA_MAX_WARM ? SEA_MAX_WARM : maxWarm));
  }

//+------------------------------------------------------------------+
int CScanner::FindUniverse(const string symbol) const
  {
   for(int i=0; i<m_count; i++)
      if(m_universe[i].symbol==symbol)
         return(i);
   return(-1);
  }

//+------------------------------------------------------------------+
int CScanner::FindWarm(const string symbol) const
  {
   for(int i=0; i<SEA_MAX_WARM; i++)
      if(m_warmSymbol[i]==symbol && m_mtf[i]!=NULL)
         return(i);
   return(-1);
  }

//+------------------------------------------------------------------+
int CScanner::FindHot(const string symbol) const
  {
   for(int i=0; i<m_hotCount; i++)
      if(m_hotSymbol[i]==symbol)
         return(i);
   return(-1);
  }

//+------------------------------------------------------------------+
int CScanner::BuildUniverse(CSymbolSpec &spec,const bool marketWatchOnly)
  {
   m_count=0;
   int total=SymbolsTotal(marketWatchOnly);

   for(int i=0; i<total && m_count<SEA_MAX_UNIVERSE; i++)
     {
      string name=SymbolName(i,marketWatchOnly);
      if(name=="")
         continue;

      int idx=spec.Ensure(name);

      m_universe[m_count].symbol     = name;
      m_universe[m_count].specIndex  = idx;
      m_universe[m_count].tier       = SEA_TIER_COLD;
      m_universe[m_count].profiled   = false;
      m_universe[m_count].tradeable  = false;
      m_universe[m_count].coldBias   = SEA_DIR_NONE;
      m_universe[m_count].rankScore  = 0.0;
      m_universe[m_count].promotedAt = 0;
      m_universe[m_count].exclusion  = "";

      if(idx<0)
         m_universe[m_count].exclusion="spec unavailable";
      else
         if(!spec.IsValid(idx))
            m_universe[m_count].exclusion=spec.InvalidReason(idx);
         else
            if(!spec.OpenAllowed(idx))
               m_universe[m_count].exclusion="broker forbids opening positions";

      m_count++;
     }

   if(m_verbose)
      PrintFormat("[CScanner] universe built: %d symbols",m_count);

   return(m_count);
  }

//+------------------------------------------------------------------+
bool CScanner::GetEntry(const int index,SScanEntry &out) const
  {
   if(index<0 || index>=m_count)
      return(false);
   out=m_universe[index];
   return(true);
  }

//+------------------------------------------------------------------+
int CScanner::TierCount(const int tier) const
  {
   int n=0;
   for(int i=0; i<m_count; i++)
      if(m_universe[i].tier==tier)
         n++;
   return(n);
  }

//+------------------------------------------------------------------+
//| TIER 3: profile, affordability, bias. Cheap per symbol.           |
//+------------------------------------------------------------------+
int CScanner::RefreshCold(CSymbolSpec &spec,CStyle &style,CIndicatorPool &pool,
                          CSymbolProfiler &profiler,CAffordability &afford,
                          CRiskManager &risk,CSpikeHazard &hazard)
  {
   int tradeable=0;
   ENUM_TIMEFRAMES execTF=style.ExecTF();
   int styleId=style.StyleId();

   for(int i=0; i<m_count; i++)
     {
      if(m_universe[i].specIndex<0 || m_universe[i].exclusion!="")
         continue;

      const string symbol=m_universe[i].symbol;

      //--- measure the profile if we have not already
      if(!profiler.IsComplete(symbol,styleId))
        {
         profiler.Profile(symbol,styleId,execTF,pool);
         m_universe[i].profiled=true;
        }

      SProfile profile;
      if(!profiler.Get(symbol,styleId,profile) || !profile.complete)
        {
         m_universe[i].tradeable=false;
         m_universe[i].exclusion="profile incomplete";
         continue;
        }

      //--- a measured NOISY_AVOID is excluded on its own numbers
      if(profile.behaviour==SEA_BEHAVIOUR_NOISY_AVOID)
        {
         m_universe[i].tradeable=false;
         m_universe[i].exclusion="measured NOISY_AVOID";
         continue;
        }

      //--- register spike character with the hazard model
      hazard.Register(symbol,profile);

      //--- current ATR for the affordability arithmetic
      int atrHandle=pool.AcquireATR(symbol,execTF,14);
      if(atrHandle==INVALID_HANDLE)
         continue;

      double atr[];
      bool got=SeaCopyBuffer(atrHandle,0,1,1,atr);
      pool.Release(atrHandle);
      if(!got)
         continue;

      afford.EvaluateFromProfile(symbol,m_universe[i].specIndex,spec,risk,
                                 profile,atr[0],style.SpreadStopCap());

      m_universe[i].tradeable=afford.IsTradeable(symbol);
      m_universe[i].exclusion=afford.Reason(symbol);
      m_universe[i].rankScore=afford.Score(symbol);

      if(m_universe[i].tradeable)
         tradeable++;
     }

   afford.MarkEvaluated();

   if(m_verbose)
      PrintFormat("[CScanner] cold refresh: %d of %d tradeable",tradeable,m_count);

   return(tradeable);
  }

//+------------------------------------------------------------------+
bool CScanner::AllocateWarm(const string symbol)
  {
   int slot=-1;
   for(int i=0; i<m_maxWarm; i++)
      if(m_mtf[i]==NULL)
        {
         slot=i;
         break;
        }
   if(slot<0)
      return(false);

   m_mtf[slot]        = new CMTF();
   m_phase[slot]      = new CPhase();
   m_regime[slot]     = new CRegime();
   m_warmSymbol[slot] = symbol;

   return(m_mtf[slot]!=NULL && m_phase[slot]!=NULL && m_regime[slot]!=NULL);
  }

//+------------------------------------------------------------------+
void CScanner::FreeWarm(const int slot,CIndicatorPool &pool)
  {
   if(slot<0 || slot>=SEA_MAX_WARM)
      return;

   if(m_mtf[slot]!=NULL)
     {
      m_mtf[slot].Release(pool);
      delete m_mtf[slot];
      m_mtf[slot]=NULL;
     }
   if(m_phase[slot]!=NULL)
     {
      m_phase[slot].Release(pool);
      delete m_phase[slot];
      m_phase[slot]=NULL;
     }
   if(m_regime[slot]!=NULL)
     {
      m_regime[slot].Release(pool);
      delete m_regime[slot];
      m_regime[slot]=NULL;
     }

   //--- release anything still held for the symbol
   if(m_warmSymbol[slot]!="")
      pool.ReleaseSymbol(m_warmSymbol[slot]);

   m_warmSymbol[slot]="";
  }

//+------------------------------------------------------------------+
//| TIER 2: allocate cascade engines for the best cold symbols.       |
//+------------------------------------------------------------------+
int CScanner::PromoteWarm(CSymbolSpec &spec,CStyle &style,CIndicatorPool &pool,
                          CSymbolProfiler &profiler,const int atrPeriod,
                          const int staleBars,const int zoneMaxAge,
                          const double equalTolerance,const int sweepMaxBars,
                          const int lookback,
                          const double accumATRRatio,const double accumADXMax,
                          const double accumRangeATR,const int chochWindow,
                          const double adxTrending,const double adxRanging,
                          const double expansionRatio,const double compressionRatio,
                          const int atrSlowPeriod,const int adxPeriod)
  {
   int styleId=style.StyleId();

   //--- rank cold symbols by affordability score
   int    order[SEA_MAX_UNIVERSE];
   double scores[SEA_MAX_UNIVERSE];
   int    n=0;

   for(int i=0; i<m_count; i++)
     {
      if(!m_universe[i].tradeable)
         continue;
      order[n]=i;
      scores[n]=m_universe[i].rankScore;
      n++;
     }

   //--- insertion sort, descending
   for(int i=1; i<n; i++)
     {
      int    oi=order[i];
      double sc=scores[i];
      int j=i-1;
      while(j>=0 && scores[j]<sc)
        {
         order[j+1]=order[j];
         scores[j+1]=scores[j];
         j--;
        }
      order[j+1]=oi;
      scores[j+1]=sc;
     }

   //--- demote warm symbols no longer tradeable, releasing their handles
   for(int s=0; s<m_maxWarm; s++)
     {
      if(m_mtf[s]==NULL)
         continue;
      int u=FindUniverse(m_warmSymbol[s]);
      if(u>=0 && m_universe[u].tradeable)
         continue;

      if(m_verbose)
         PrintFormat("[CScanner] demoting %s from warm",m_warmSymbol[s]);
      if(u>=0)
         m_universe[u].tier=SEA_TIER_COLD;
      FreeWarm(s,pool);
     }

   //--- promote up to the warm ceiling
   int promoted=0;
   for(int k=0; k<n; k++)
     {
      int u=order[k];
      if(m_universe[u].tier==SEA_TIER_WARM && FindWarm(m_universe[u].symbol)>=0)
         continue;

      //--- count current warm occupancy
      int occupied=0;
      for(int s=0; s<m_maxWarm; s++)
         if(m_mtf[s]!=NULL)
            occupied++;
      if(occupied>=m_maxWarm)
         break;

      SProfile profile;
      if(!profiler.Get(m_universe[u].symbol,styleId,profile) || !profile.complete)
         continue;

      if(!AllocateWarm(m_universe[u].symbol))
         continue;

      int slot=FindWarm(m_universe[u].symbol);
      if(slot<0)
         continue;

      //--- RULE 8: handles are created HERE, on promotion
      bool ok=true;
      ok=ok && m_mtf[slot].Init(m_universe[u].symbol,style,pool,
                                profile.fractalBars,staleBars,
                                profile.impulseATR,zoneMaxAge,
                                equalTolerance,sweepMaxBars,atrPeriod,lookback);

      ok=ok && m_phase[slot].Init(m_universe[u].symbol,style.ExecTF(),pool,
                                  atrPeriod,atrSlowPeriod,adxPeriod,
                                  accumATRRatio,accumADXMax,accumRangeATR,
                                  profile.accumMinBars,sweepMaxBars,chochWindow);

      ok=ok && m_regime[slot].Init(m_universe[u].symbol,style.ExecTF(),pool,
                                   atrPeriod,atrSlowPeriod,adxPeriod,
                                   adxTrending,adxRanging,
                                   expansionRatio,compressionRatio);

      if(!ok)
        {
         if(m_verbose)
            PrintFormat("[CScanner] %s failed warm initialisation, releasing",
                        m_universe[u].symbol);
         FreeWarm(slot,pool);
         continue;
        }

      m_universe[u].tier=SEA_TIER_WARM;
      m_universe[u].promotedAt=TimeCurrent();
      promoted++;
     }

   m_warmCount=0;
   for(int s=0; s<m_maxWarm; s++)
      if(m_mtf[s]!=NULL)
         m_warmCount++;

   if(pool.LiveHandles()>m_handleWarnThreshold)
      PrintFormat("[CScanner] WARNING: %d live indicator handles",pool.LiveHandles());

   if(m_verbose)
      PrintFormat("[CScanner] warm tier: %d symbols (%d promoted this pass)",
                  m_warmCount,promoted);

   return(m_warmCount);
  }

//+------------------------------------------------------------------+
int CScanner::UpdateWarm(void)
  {
   int updated=0;

   for(int s=0; s<m_maxWarm; s++)
     {
      if(m_mtf[s]==NULL)
         continue;

      m_mtf[s].Update();

      CStructure *exec=m_mtf[s].Structure(m_mtf[s].Levels()-1);
      if(exec==NULL)
         continue;

      if(m_phase[s]!=NULL)
         m_phase[s].Update(exec);
      if(m_regime[s]!=NULL)
         m_regime[s].Update(exec);

      updated++;
     }

   return(updated);
  }

//+------------------------------------------------------------------+
CMTF *CScanner::MTFOf(const string symbol) const
  {
   int s=FindWarm(symbol);
   return(s<0 ? NULL : m_mtf[s]);
  }

CPhase *CScanner::PhaseOf(const string symbol) const
  {
   int s=FindWarm(symbol);
   return(s<0 ? NULL : m_phase[s]);
  }

CRegime *CScanner::RegimeOf(const string symbol) const
  {
   int s=FindWarm(symbol);
   return(s<0 ? NULL : m_regime[s]);
  }

//+------------------------------------------------------------------+
//| TIER 1. A full hot list yields only to a HIGHER score.            |
//+------------------------------------------------------------------+
bool CScanner::PromoteHot(const string symbol,const double score)
  {
   int existing=FindHot(symbol);
   if(existing>=0)
     {
      m_hotScore[existing]=score;
      return(true);
     }

   if(m_hotCount<m_maxHot)
     {
      m_hotSymbol[m_hotCount]=symbol;
      m_hotScore[m_hotCount] =score;
      m_hotCount++;
      return(true);
     }

   //--- find the weakest incumbent
   int    weakest=0;
   double weakestScore=m_hotScore[0];
   for(int i=1; i<m_hotCount; i++)
      if(m_hotScore[i]<weakestScore)
        {
         weakest=i;
         weakestScore=m_hotScore[i];
      }

   //--- strictly greater. An equal score does not displace an incumbent.
   if(score<=weakestScore)
      return(false);

   if(m_verbose)
      PrintFormat("[CScanner] %s (%.0f) displaces %s (%.0f) from hot",
                  symbol,score,m_hotSymbol[weakest],weakestScore);

   m_hotSymbol[weakest]=symbol;
   m_hotScore[weakest] =score;
   return(true);
  }

//+------------------------------------------------------------------+
string CScanner::HotSymbol(const int index) const
  {
   if(index<0 || index>=m_hotCount)
      return("");
   return(m_hotSymbol[index]);
  }

//+------------------------------------------------------------------+
//| Run the full pipeline over the warm set and collect survivors.    |
//+------------------------------------------------------------------+
int CScanner::CollectCandidates(CSymbolSpec &spec,CStyle &style,
                                CProbabilityMap &probability,CGates &gates,
                                CScoring &scoring,CSpikeHazard &hazard,
                                CAffordability &afford,CRiskManager &risk,
                                CSymbolProfiler &profiler)
  {
   m_candidateCount=0;
   m_lastGateCount =0;

   const int styleId=style.StyleId();

   for(int s=0; s<m_maxWarm; s++)
     {
      if(m_mtf[s]==NULL || !m_mtf[s].IsReady())
         continue;

      const string symbol=m_warmSymbol[s];
      int u=FindUniverse(symbol);
      if(u<0 || !m_universe[u].tradeable)
         continue;

      const int specIndex=m_universe[u].specIndex;
      if(specIndex<0 || !spec.IsValid(specIndex))
         continue;

      SProfile profile;
      if(!profiler.Get(symbol,styleId,profile) || !profile.complete)
         continue;

      //--- COMPRESSION forbids entries outright
      if(m_regime[s]!=NULL && !m_regime[s].EntriesAllowed())
         continue;

      const int execLevel=m_mtf[s].Levels()-1;
      CStructure *exec=m_mtf[s].Structure(execLevel);
      CZones     *zones=m_mtf[s].Zones(execLevel);
      if(exec==NULL || zones==NULL || !exec.IsReady())
         continue;

      SAffordability aff;
      if(!afford.Get(symbol,aff))
         continue;

      //--- both directions are evaluated. Nothing is direction-locked.
      for(int d=0; d<2; d++)
        {
         ENUM_SEA_DIRECTION dir=(d==0 ? SEA_DIR_LONG : SEA_DIR_SHORT);

         //--- the broker may forbid one side
         if(dir==SEA_DIR_LONG && !spec.LongAllowed(specIndex))
            continue;
         if(dir==SEA_DIR_SHORT && !spec.ShortAllowed(specIndex))
            continue;

         double price=(dir==SEA_DIR_LONG ? SymbolInfoDouble(symbol,SYMBOL_ASK)
                       : SymbolInfoDouble(symbol,SYMBOL_BID));
         if(price<=0.0)
            continue;

         //--- the entry level is the near edge of a FRESH zone
         SZone zone;
         bool  zoneFound=zones.NearestFresh(price,dir,aff.requiredStop*3.0,zone);

         double entry=price;
         if(zoneFound)
            entry=(dir==SEA_DIR_LONG ? zone.upper : zone.lower);

         //--- structural invalidation
         double invalidation=0.0;
         bool   invalidationOk=exec.InvalidationLevel(dir,invalidation);

         //--- the stop sits beyond the invalidation by the spread
         double stop=0.0;
         if(invalidationOk)
           {
            double pad=spec.SpreadPrice(specIndex);
            stop=(dir==SEA_DIR_LONG ? invalidation-pad : invalidation+pad);
           }

         //--- the target is the nearest unswept opposing liquidity
         SLiquidity target;
         bool targetFound=m_mtf[s].NearestUnswept(entry,dir,target);
         double targetPrice=(targetFound ? target.price : 0.0);

         double riskDist  =MathAbs(entry-stop);
         double rewardDist=(targetFound ? MathAbs(targetPrice-entry) : 0.0);
         double rr        =(riskDist>0.0 ? rewardDist/riskDist : 0.0);

         //--- price action trigger on a CLOSED bar
         ENUM_SEA_TRIGGER trigger=exec.DetectTrigger(dir,1);

         //--- probability at this location
         SProbability prob=probability.Evaluate(m_mtf[s],entry,dir,execLevel);

         //--- assemble the gate context
         SGateContext ctx;
         ctx.symbol              = symbol;
         ctx.specIndex           = specIndex;
         ctx.direction           = dir;
         ctx.execLevel           = execLevel;
         ctx.entryPrice          = entry;
         ctx.stopPrice           = stop;
         ctx.targetPrice         = targetPrice;
         ctx.requiredStop        = aff.requiredStop;
         ctx.affordableStop      = aff.affordableStop;
         ctx.spread              = spec.SpreadPrice(specIndex);
         ctx.spreadCap           = aff.spreadCap;
         ctx.zoneFound           = zoneFound;
         ctx.zoneState           = (zoneFound ? zone.state : SEA_ZONE_EXPIRED);
         ctx.zoneType            = (zoneFound ? zone.type  : SEA_ZONE_NONE);
         ctx.zoneUpper           = (zoneFound ? zone.upper : 0.0);
         ctx.zoneLower           = (zoneFound ? zone.lower : 0.0);
         ctx.trigger             = trigger;
         ctx.invalidationDefined = invalidationOk;
         ctx.invalidationLevel   = invalidation;
         ctx.probability         = prob.score;
         ctx.reversalHypothesis  = prob.isReversal;
         ctx.hypothesisMargin    = prob.margin;
         ctx.phase               = (m_phase[s]!=NULL ? m_phase[s].Phase() : SEA_PHASE_UNDEFINED);
         ctx.sweepConfirmed      = (m_phase[s]!=NULL ? m_phase[s].SweepConfirmed() : false);
         ctx.regime              = (m_regime[s]!=NULL ? m_regime[s].Regime() : SEA_REGIME_UNDEFINED);
         ctx.htfState            = m_mtf[s].HTFState();
         ctx.rr                  = rr;

         //--- ALL TEN GATES
         SGateResult gateResult=gates.Evaluate(ctx,hazard);

         //--- record for the journal, pass or fail
         if(m_lastGateCount<SEA_MAX_WARM*2)
           {
            m_lastGates[m_lastGateCount]      = gateResult;
            m_lastGateCtx[m_lastGateCount]    = ctx;
            m_lastGateSymbol[m_lastGateCount] = symbol;
            m_lastGateDir[m_lastGateCount]    = (int)dir;
            m_lastGateCount++;
           }

         if(!gateResult.allPassed)
            continue;

         //--- SURVIVOR. Only now is it scored.
         SScoreContext sctx=scoring.BuildContext(m_mtf[s],m_phase[s],symbol,dir,execLevel,
                                                 entry,stop,targetPrice,
                                                 (zoneFound && zone.state==SEA_ZONE_FRESH),
                                                 (zoneFound && zone.touchCount==0),
                                                 (zoneFound && zone.overlapsFVG),
                                                 targetFound);

         SScoreResult score=scoring.Score(sctx,profile.minConfluence);
         if(!score.qualifies)
            continue;

         if(m_candidateCount>=SEA_MAX_CANDIDATES)
            break;

         //--- size it
         string rejectReason;
         double lots=risk.CalculateLots(spec,specIndex,riskDist,rejectReason);
         if(lots<=0.0)
           {
            if(m_verbose)
               PrintFormat("[CScanner] %s %s sized to zero: %s",
                           symbol,SeaDirectionToString(dir),rejectReason);
            continue;
           }

         SSetup c;
         c.valid              = true;
         c.symbol             = symbol;
         c.specIndex          = specIndex;
         c.direction          = dir;
         c.entryPrice         = entry;
         c.stopPrice          = stop;
         c.targetPrice        = targetPrice;
         c.zoneUpper          = ctx.zoneUpper;
         c.zoneLower          = ctx.zoneLower;
         c.zoneType           = ctx.zoneType;
         c.trigger            = trigger;
         c.breakType          = exec.LastBreak();
         c.zoneOriginTime     = (zoneFound ? zone.originTime : 0);
         c.phase              = ctx.phase;
         c.regime             = ctx.regime;
         c.mtfAlignment       = m_mtf[s].Alignment();
         c.probability        = prob.score;
         c.reversalHypothesis = prob.isReversal;
         c.hypothesisMargin   = prob.margin;
         c.score              = score.total;
         c.scoreBreakdown     = score.breakdown;
         c.lots               = lots;
         c.riskMoney          = spec.MoneyAtRisk(specIndex,riskDist,lots);
         c.riskPercent        = (AccountInfoDouble(ACCOUNT_EQUITY)>0.0
                                 ? c.riskMoney/AccountInfoDouble(ACCOUNT_EQUITY)*100.0 : 0.0);
         c.rr                 = rr;
         c.createdAt          = TimeCurrent();
         c.expiryBars         = style.PendingExpiryBars();

         m_candidates[m_candidateCount]=c;
         m_candidateCount++;
        }
     }

   //--- rank
   scoring.SortByScore(m_candidates,m_candidateCount);

   if(m_verbose)
      PrintFormat("[CScanner] %d candidates from %d warm symbols",
                  m_candidateCount,m_warmCount);

   return(m_candidateCount);
  }

//+------------------------------------------------------------------+
bool CScanner::GetCandidate(const int index,SSetup &out) const
  {
   if(index<0 || index>=m_candidateCount)
      return(false);
   out=m_candidates[index];
   return(true);
  }

//+------------------------------------------------------------------+
//| Correlation collapse.                                             |
//|                                                                   |
//| Exposure is counted per INDIVIDUAL CURRENCY, not per pair. Three  |
//| candidates that each contain the same currency are three bets on  |
//| that currency however different their symbols look, so the cap    |
//| applies to the currency itself.                                   |
//|                                                                   |
//| Candidates arrive already sorted best-first, so the highest       |
//| scorer claims the exposure and later ones are DISCARDED, not      |
//| queued.                                                           |
//|                                                                   |
//| Instruments with no currency pair - synthetics, indices quoted    |
//| in the deposit currency - are exempt, as the architecture         |
//| requires.                                                         |
//+------------------------------------------------------------------+
int CScanner::ApplyCorrelationCollapse(CSymbolSpec &spec,const int maxPerGroup)
  {
   if(m_candidateCount<=1)
      return(m_candidateCount);

   int cap=(maxPerGroup<1 ? 1 : maxPerGroup);

   string currency[SEA_MAX_CANDIDATES*2];
   int    used[SEA_MAX_CANDIDATES*2];
   int    currencyCount=0;

   SSetup kept[];
   ArrayResize(kept,SEA_MAX_CANDIDATES);
   int keptCount=0;

   for(int i=0; i<m_candidateCount; i++)
     {
      string base  =spec.CurrencyBase(m_candidates[i].specIndex);
      string profit=spec.CurrencyProfit(m_candidates[i].specIndex);

      //--- a symbol that names no currency pair carries no shared
      //--- currency exposure to cap
      bool exempt=(base=="" || profit=="" || base==profit);

      if(exempt)
        {
         kept[keptCount]=m_candidates[i];
         keptCount++;
         continue;
        }

      //--- locate or create a counter for each side
      int slots[2];
      string names[2];
      names[0]=base;
      names[1]=profit;

      bool blocked=false;
      string blockedBy="";

      for(int k=0; k<2; k++)
        {
         int g=-1;
         for(int c=0; c<currencyCount; c++)
            if(currency[c]==names[k])
              {
               g=c;
               break;
              }

         if(g<0)
           {
            if(currencyCount>=SEA_MAX_CANDIDATES*2)
              {
               blocked=true;
               blockedBy="currency table full";
               break;
              }
            currency[currencyCount]=names[k];
            used[currencyCount]=0;
            g=currencyCount;
            currencyCount++;
           }

         slots[k]=g;

         if(used[g]>=cap)
           {
            blocked=true;
            blockedBy=names[k];
           }
        }

      if(blocked)
        {
         if(m_verbose)
            PrintFormat("[CScanner] %s discarded: %s already at the %d exposure cap",
                        m_candidates[i].symbol,blockedBy,cap);
         continue;
        }

      //--- claim the exposure on both sides
      used[slots[0]]++;
      used[slots[1]]++;

      kept[keptCount]=m_candidates[i];
      keptCount++;
     }

   for(int i=0; i<keptCount; i++)
      m_candidates[i]=kept[i];
   m_candidateCount=keptCount;

   return(m_candidateCount);
  }

//+------------------------------------------------------------------+
int CScanner::TopCandidates(const int slots,SSetup &out[]) const
  {
   int want=(slots<0 ? 0 : slots);
   if(want>m_candidateCount)
      want=m_candidateCount;

   ArrayResize(out,want);
   for(int i=0; i<want; i++)
      out[i]=m_candidates[i];

   return(want);
  }

//+------------------------------------------------------------------+
bool CScanner::LastGateResult(const string symbol,const ENUM_SEA_DIRECTION dir,
                              SGateResult &out) const
  {
   for(int i=0; i<m_lastGateCount; i++)
      if(m_lastGateSymbol[i]==symbol && m_lastGateDir[i]==(int)dir)
        {
         out=m_lastGates[i];
         return(true);
        }
   return(false);
  }

//+------------------------------------------------------------------+
bool CScanner::LastGateContext(const string symbol,const ENUM_SEA_DIRECTION dir,
                               SGateContext &out) const
  {
   for(int i=0; i<m_lastGateCount; i++)
      if(m_lastGateSymbol[i]==symbol && m_lastGateDir[i]==(int)dir)
        {
         out=m_lastGateCtx[i];
         return(true);
        }
   return(false);
  }

//+------------------------------------------------------------------+
bool CScanner::GateRecordAt(const int index,SGateContext &ctx,SGateResult &result) const
  {
   if(index<0 || index>=m_lastGateCount)
      return(false);
   ctx=m_lastGateCtx[index];
   result=m_lastGates[index];
   return(true);
  }

//+------------------------------------------------------------------+
string CScanner::Describe(void) const
  {
   return(StringFormat("universe=%d cold=%d warm=%d hot=%d candidates=%d",
                       m_count,TierCount(SEA_TIER_COLD),m_warmCount,
                       m_hotCount,m_candidateCount));
  }

#endif // SEA_CSCANNER_MQH
//+------------------------------------------------------------------+
