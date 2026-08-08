//+------------------------------------------------------------------+
//|                                                         CMTF.mqh  |
//|                                                                   |
//|   Module 13. Timeframe cascade and alignment score.               |
//|                                                                   |
//|   Owns one CStructure, CZones and CLiquidity per cascade level for|
//|   one symbol. Levels are built TOP DOWN, and a level is rebuilt   |
//|   ONLY on that timeframe's own bar close - an H4 level does not   |
//|   recompute because an M15 bar closed.                            |
//|                                                                   |
//|   Alignment is a signed score, -100..+100, with higher timeframes |
//|   weighted more heavily. It is context, not permission.           |
//+------------------------------------------------------------------+
#ifndef SEA_CMTF_MQH
#define SEA_CMTF_MQH

#include <SEA/SEA_Common.mqh>
#include <SEA/CStyle.mqh>
#include <SEA/CStructure.mqh>
#include <SEA/CZones.mqh>
#include <SEA/CLiquidity.mqh>

//+------------------------------------------------------------------+
//| One cascade level.                                                |
//+------------------------------------------------------------------+
struct SMTFLevel
  {
   ENUM_TIMEFRAMES       timeframe;
   ENUM_SEA_STRUCT_STATE state;
   ENUM_SEA_DIRECTION    bias;
   ENUM_SEA_BREAK_TYPE   lastBreak;
   double                rangeHigh;
   double                rangeLow;
   double                equilibrium;
   bool                  hasRange;
   int                   freshZones;
   int                   unsweptLevels;
   double                weight;         // contribution to alignment
   datetime              lastRebuild;
   bool                  ready;
   int                   testCount;      // touches of this level's boundary
  };

//+------------------------------------------------------------------+
//| CMTF                                                              |
//|                                                                   |
//| One instance per symbol.                                          |
//+------------------------------------------------------------------+
class CMTF
  {
private:
   string            m_symbol;
   int               m_levels;
   bool              m_verbose;
   bool              m_ready;

   CStructure       *m_structure[SEA_CASCADE_LEVELS];
   CZones           *m_zones[SEA_CASCADE_LEVELS];
   CLiquidity       *m_liquidity[SEA_CASCADE_LEVELS];
   SMTFLevel         m_state[SEA_CASCADE_LEVELS];
   datetime          m_lastBar[SEA_CASCADE_LEVELS];

   int               m_alignment;
   double            m_boundaryTolerance;   // ATR fraction for a boundary touch

   void              ComputeAlignment(void);

public:
                     CMTF(void);
                    ~CMTF(void);

   //! Build the cascade for a symbol.
   //!
   //! Allocates one structure, zone and liquidity engine per level and
   //! takes indicator handles from the pool. Call on Tier 2 promotion.
   //!
   //! Returns false when any level fails to initialise - a partial
   //! cascade is never used.
   bool              Init(const string symbol,CStyle &style,CIndicatorPool &pool,
                          const int fractalBars,const int staleBars,
                          const double impulseATR,const int zoneMaxAge,
                          const double equalTolerance,const int sweepMaxBars,
                          const int atrPeriod,const int lookback);

   //! Release every handle and free every level. Call on demotion.
   void              Release(CIndicatorPool &pool);

   //! Print diagnostics. Off by default.
   void              SetVerbose(const bool enabled);

   //! Rebuild any level whose own timeframe has closed a bar.
   //! Returns the number of levels rebuilt.
   int               Update(void);

   //! True once every level has produced usable state.
   bool              IsReady(void) const { return m_ready; }

   //! Bound symbol.
   string            Symbol(void) const { return m_symbol; }

   //--- level access ------------------------------------------------------
   //! Number of cascade levels.
   int               Levels(void) const { return m_levels; }

   //! Copy out a level's summary. Level 0 is the highest timeframe.
   bool              GetLevel(const int level,SMTFLevel &out) const;

   //! Structure engine at a level. Returns NULL for a bad index.
   CStructure       *Structure(const int level) const;

   //! Zone engine at a level.
   CZones           *Zones(const int level) const;

   //! Liquidity engine at a level.
   CLiquidity       *Liquidity(const int level) const;

   //! Index of the level matching a timeframe, or -1.
   int               LevelOf(const ENUM_TIMEFRAMES tf) const;

   //--- aggregate --------------------------------------------------------
   //! Signed alignment, -100..+100. Positive is bullish agreement.
   //! Higher timeframes carry more weight.
   int               Alignment(void) const { return m_alignment; }

   //! Directional bias of the highest timeframe that is not RANGING.
   ENUM_SEA_DIRECTION HTFBias(void) const;

   //! State of the highest timeframe level.
   ENUM_SEA_STRUCT_STATE HTFState(void) const;

   //! Number of levels agreeing with a direction. Feeds the stacking
   //! bonus in CScoring.
   int               LevelsAgreeing(const ENUM_SEA_DIRECTION dir) const;

   //! True when any HTF level holds a FRESH zone containing the price.
   //! An LTF signal with no HTF zone at that price is location-less.
   bool              HTFZoneAtPrice(const double price,const ENUM_SEA_DIRECTION bias,
                                    const int aboveLevel,SZone &out) const;

   //! Nearest unswept liquidity across every level, in a direction.
   bool              NearestUnswept(const double price,const ENUM_SEA_DIRECTION dir,
                                    SLiquidity &out) const;

   //! One-line summary.
   string            Describe(void) const;
  };

//+------------------------------------------------------------------+
CMTF::CMTF(void)
  {
   m_symbol            = "";
   m_levels            = 0;
   m_verbose           = false;
   m_ready             = false;
   m_alignment         = 0;
   m_boundaryTolerance = 0.10;

   for(int i=0; i<SEA_CASCADE_LEVELS; i++)
     {
      m_structure[i] = NULL;
      m_zones[i]     = NULL;
      m_liquidity[i] = NULL;
      m_lastBar[i]   = 0;
     }
  }

//+------------------------------------------------------------------+
CMTF::~CMTF(void)
  {
   for(int i=0; i<SEA_CASCADE_LEVELS; i++)
     {
      if(m_structure[i]!=NULL)
        {
         delete m_structure[i];
         m_structure[i]=NULL;
        }
      if(m_zones[i]!=NULL)
        {
         delete m_zones[i];
         m_zones[i]=NULL;
        }
      if(m_liquidity[i]!=NULL)
        {
         delete m_liquidity[i];
         m_liquidity[i]=NULL;
        }
     }
  }

//+------------------------------------------------------------------+
void CMTF::SetVerbose(const bool enabled)
  {
   m_verbose=enabled;
   for(int i=0; i<m_levels; i++)
     {
      if(m_structure[i]!=NULL)
         m_structure[i].SetVerbose(enabled);
      if(m_zones[i]!=NULL)
         m_zones[i].SetVerbose(enabled);
      if(m_liquidity[i]!=NULL)
         m_liquidity[i].SetVerbose(enabled);
     }
  }

//+------------------------------------------------------------------+
bool CMTF::Init(const string symbol,CStyle &style,CIndicatorPool &pool,
                const int fractalBars,const int staleBars,
                const double impulseATR,const int zoneMaxAge,
                const double equalTolerance,const int sweepMaxBars,
                const int atrPeriod,const int lookback)
  {
   m_symbol = symbol;
   m_levels = style.CascadeLevels();
   m_ready  = false;

   //--- build TOP DOWN: level 0 is the highest timeframe
   for(int i=0; i<m_levels; i++)
     {
      ENUM_TIMEFRAMES tf=style.CascadeTF(i);

      m_structure[i]=new CStructure();
      m_zones[i]    =new CZones();
      m_liquidity[i]=new CLiquidity();

      if(m_structure[i]==NULL || m_zones[i]==NULL || m_liquidity[i]==NULL)
        {
         if(m_verbose)
            PrintFormat("[CMTF] %s: allocation failed at level %d",symbol,i);
         return(false);
        }

      m_structure[i].SetVerbose(m_verbose);
      m_zones[i].SetVerbose(m_verbose);
      m_liquidity[i].SetVerbose(m_verbose);

      bool ok=true;
      ok=ok && m_structure[i].Init(symbol,tf,fractalBars,staleBars,lookback);
      ok=ok && m_zones[i].Init(symbol,tf,pool,impulseATR,zoneMaxAge,atrPeriod,lookback);
      ok=ok && m_liquidity[i].Init(symbol,tf,pool,style.DayTF(),style.WeekTF(),
                                   equalTolerance,sweepMaxBars,atrPeriod,lookback);

      if(!ok)
        {
         //--- a partial cascade is never used: an HTF level missing means
         //--- location cannot be judged, and location gates the signal
         if(m_verbose)
            PrintFormat("[CMTF] %s: level %d (%s) failed to initialise",
                        symbol,i,style.TFName(tf));
         return(false);
        }

      m_state[i].timeframe   = tf;
      m_state[i].ready       = false;
      m_state[i].testCount   = 0;
      m_state[i].lastRebuild = 0;

      //--- higher timeframes weigh more. Level 0 is heaviest.
      m_state[i].weight=(double)(m_levels-i)/(double)m_levels;

      m_lastBar[i]=0;
     }

   Update();
   m_ready=true;
   return(true);
  }

//+------------------------------------------------------------------+
void CMTF::Release(CIndicatorPool &pool)
  {
   for(int i=0; i<m_levels; i++)
     {
      if(m_zones[i]!=NULL)
         m_zones[i].Release(pool);
      if(m_liquidity[i]!=NULL)
         m_liquidity[i].Release(pool);
     }
   m_ready=false;
  }

//+------------------------------------------------------------------+
//| Rebuild only the levels whose own timeframe closed a bar.         |
//+------------------------------------------------------------------+
int CMTF::Update(void)
  {
   int rebuilt=0;

   for(int i=0; i<m_levels; i++)
     {
      if(m_structure[i]==NULL)
         continue;

      ENUM_TIMEFRAMES tf=m_state[i].timeframe;
      datetime barTime=(datetime)SeriesInfoInteger(m_symbol,tf,SERIES_LASTBAR_DATE);

      //--- RULE: a level rebuilds ONLY on its own bar close
      if(barTime==m_lastBar[i] && m_state[i].ready)
         continue;

      bool ok=true;
      ok=ok && m_structure[i].Update();
      ok=ok && m_zones[i].Update();
      ok=ok && m_liquidity[i].Update();

      if(!ok)
         continue;   // unsynchronised: skip and retry on the next pass

      m_state[i].state       = m_structure[i].State();
      m_state[i].bias        = m_structure[i].Bias();
      m_state[i].lastBreak   = m_structure[i].LastBreak();
      m_state[i].hasRange    = m_structure[i].HasRange();
      m_state[i].rangeHigh   = m_structure[i].RangeHigh();
      m_state[i].rangeLow    = m_structure[i].RangeLow();
      m_state[i].equilibrium = m_structure[i].Equilibrium();
      m_state[i].freshZones  = m_zones[i].FreshCount();
      m_state[i].unsweptLevels=m_liquidity[i].UnsweptCount();
      m_state[i].lastRebuild = barTime;
      m_state[i].ready       = true;

      m_lastBar[i]=barTime;
      rebuilt++;
     }

   if(rebuilt>0)
      ComputeAlignment();

   return(rebuilt);
  }

//+------------------------------------------------------------------+
//| Signed alignment, weighted by timeframe.                          |
//+------------------------------------------------------------------+
void CMTF::ComputeAlignment(void)
  {
   double signedSum=0.0;
   double weightSum=0.0;

   for(int i=0; i<m_levels; i++)
     {
      if(!m_state[i].ready)
         continue;

      weightSum+=m_state[i].weight;

      if(m_state[i].bias==SEA_DIR_LONG)
         signedSum+=m_state[i].weight;
      else
         if(m_state[i].bias==SEA_DIR_SHORT)
            signedSum-=m_state[i].weight;
      //--- RANGING contributes zero, and still counts in the denominator
     }

   if(weightSum<=0.0)
     {
      m_alignment=0;
      return;
     }

   m_alignment=(int)MathRound(signedSum/weightSum*100.0);
   if(m_alignment>100)
      m_alignment=100;
   if(m_alignment<-100)
      m_alignment=-100;
  }

//+------------------------------------------------------------------+
bool CMTF::GetLevel(const int level,SMTFLevel &out) const
  {
   if(level<0 || level>=m_levels)
      return(false);
   out=m_state[level];
   return(true);
  }

//+------------------------------------------------------------------+
CStructure *CMTF::Structure(const int level) const
  {
   if(level<0 || level>=m_levels)
      return(NULL);
   return(m_structure[level]);
  }

//+------------------------------------------------------------------+
CZones *CMTF::Zones(const int level) const
  {
   if(level<0 || level>=m_levels)
      return(NULL);
   return(m_zones[level]);
  }

//+------------------------------------------------------------------+
CLiquidity *CMTF::Liquidity(const int level) const
  {
   if(level<0 || level>=m_levels)
      return(NULL);
   return(m_liquidity[level]);
  }

//+------------------------------------------------------------------+
int CMTF::LevelOf(const ENUM_TIMEFRAMES tf) const
  {
   for(int i=0; i<m_levels; i++)
      if(m_state[i].timeframe==tf)
         return(i);
   return(-1);
  }

//+------------------------------------------------------------------+
ENUM_SEA_DIRECTION CMTF::HTFBias(void) const
  {
   for(int i=0; i<m_levels; i++)
     {
      if(!m_state[i].ready)
         continue;
      if(m_state[i].bias!=SEA_DIR_NONE)
         return(m_state[i].bias);
     }
   return(SEA_DIR_NONE);
  }

//+------------------------------------------------------------------+
ENUM_SEA_STRUCT_STATE CMTF::HTFState(void) const
  {
   if(m_levels<=0 || !m_state[0].ready)
      return(SEA_STRUCT_UNKNOWN);
   return(m_state[0].state);
  }

//+------------------------------------------------------------------+
int CMTF::LevelsAgreeing(const ENUM_SEA_DIRECTION dir) const
  {
   if(dir==SEA_DIR_NONE)
      return(0);
   int n=0;
   for(int i=0; i<m_levels; i++)
      if(m_state[i].ready && m_state[i].bias==dir)
         n++;
   return(n);
  }

//+------------------------------------------------------------------+
//| Is there an HTF zone at this price?                               |
//|                                                                   |
//| aboveLevel restricts the search to levels strictly higher than the|
//| execution level, which is what makes the test meaningful: an LTF  |
//| zone at the price is not HTF confirmation of anything.            |
//+------------------------------------------------------------------+
bool CMTF::HTFZoneAtPrice(const double price,const ENUM_SEA_DIRECTION bias,
                          const int aboveLevel,SZone &out) const
  {
   for(int i=0; i<m_levels && i<aboveLevel; i++)
     {
      if(m_zones[i]==NULL || !m_state[i].ready)
         continue;
      if(m_zones[i].ZoneAtPrice(price,bias,out))
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
bool CMTF::NearestUnswept(const double price,const ENUM_SEA_DIRECTION dir,
                          SLiquidity &out) const
  {
   bool       found=false;
   double     bestDist=0.0;

   //--- zero-initialised so the compiler can see it is never read
   //--- before being written, and so a caller that ignores the return
   //--- value gets a defined struct rather than stack garbage
   SLiquidity best;
   best.price      = 0.0;
   best.time       = 0;
   best.isHigh     = false;
   best.swept      = false;
   best.touchCount = 0;
   best.strength   = 0.0;

   for(int i=0; i<m_levels; i++)
     {
      if(m_liquidity[i]==NULL || !m_state[i].ready)
         continue;

      SLiquidity cand;
      if(!m_liquidity[i].TargetFor(price,dir,cand))
         continue;

      double d=MathAbs(cand.price-price);
      if(!found || d<bestDist)
        {
         found=true;
         bestDist=d;
         best=cand;
        }
     }

   if(found)
      out=best;
   return(found);
  }

//+------------------------------------------------------------------+
string CMTF::Describe(void) const
  {
   string out=StringFormat("%s alignment=%+d htf=%s | ",
                           m_symbol,m_alignment,
                           SeaStructStateToString(HTFState()));

   for(int i=0; i<m_levels; i++)
     {
      out+=StringFormat("L%d:%s ",i,
                        (m_state[i].ready ? SeaStructStateToString(m_state[i].state) : "-"));
     }

   return(out);
  }

#endif // SEA_CMTF_MQH
//+------------------------------------------------------------------+
