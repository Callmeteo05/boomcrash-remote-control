//+------------------------------------------------------------------+
//|                                                       CZones.mqh  |
//|                                                                   |
//|   Module 6. Order blocks, fair value gaps, breakers, inverted     |
//|   FVGs, and the state machine that ages them.                     |
//|                                                                   |
//|   A zone is not a signal. It is a LOCATION. CStructure decides    |
//|   whether a location may be traded; this module only says where   |
//|   the locations are and whether they are still untouched.         |
//|                                                                   |
//|   State: FRESH -> TAPPED -> MITIGATED -> INVERTED -> EXPIRED      |
//|   Only FRESH is tradeable.                                        |
//|                                                                   |
//|   RULE 1: formation and state transitions are evaluated on CLOSED |
//|   bars only. shift >= 1 throughout.                               |
//+------------------------------------------------------------------+
#ifndef SEA_CZONES_MQH
#define SEA_CZONES_MQH

#include <SEA/SEA_Common.mqh>

#define SEA_MAX_ZONES        192
#define SEA_IMPULSE_MAX_BARS   5

//+------------------------------------------------------------------+
//| CZones                                                            |
//|                                                                   |
//| One instance per (symbol, timeframe).                             |
//+------------------------------------------------------------------+
class CZones
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   int               m_atrHandle;
   int               m_atrPeriod;
   double            m_impulseATR;      // from the symbol profile
   int               m_maxAgeBars;      // InpZoneMaxAge, default 500
   int               m_lookback;
   bool              m_verbose;
   datetime          m_lastBarTime;
   bool              m_ready;

   SZone             m_zones[];
   int               m_zoneCount;

   bool              AddZone(const ENUM_SEA_ZONE_TYPE type,const ENUM_SEA_DIRECTION bias,
                             const double upper,const double lower,
                             const datetime time,const int shift,const double impulse);
   void              DetectOrderBlocks(const MqlRates &r[],const int total,const double atr);
   void              DetectFVGs(const MqlRates &r[],const int total);
   void              MarkOverlaps(void);
   void              AgeAndTransition(const MqlRates &r[],const int total);
   double            ImpulseStrength(const MqlRates &r[],const int start,
                                     const int bars,const bool bullish,const double atr) const;

public:
                     CZones(void);
                    ~CZones(void);

   //! Bind to a symbol and timeframe and take an ATR handle from the pool.
   //! impulseATR comes from the symbol profile (2.0 uniform .. 4.0 clustered).
   //! Returns false when history is short or the handle cannot be created.
   bool              Init(const string symbol,const ENUM_TIMEFRAMES tf,CIndicatorPool &pool,
                          const double impulseATR,const int maxAgeBars,
                          const int atrPeriod,const int lookback);

   //! Give the ATR handle back to the pool. Call on tier demotion.
   void              Release(CIndicatorPool &pool);

   //! Print diagnostics. Off by default.
   void              SetVerbose(const bool enabled) { m_verbose=enabled; }

   //! Update the impulse threshold after a profile refresh.
   void              SetImpulseATR(const double mult);

   //! Rebuild zones and run the state machine. New bar only unless forced.
   //! Returns false when the series is unsynchronised - skip and retry.
   bool              Update(const bool force=false);

   //! True once a successful Update has run.
   bool              IsReady(void) const { return m_ready; }

   //! Number of zones held, in every state.
   int               Count(void) const { return m_zoneCount; }

   //! Copy out a zone by index.
   bool              Get(const int index,SZone &out) const;

   //! Number of zones currently FRESH.
   int               FreshCount(void) const;

   //! Nearest FRESH zone supporting a direction, within maxDistance
   //! price units of the reference price. Returns false when none.
   //! Pass maxDistance <= 0 for no distance limit.
   bool              NearestFresh(const double price,const ENUM_SEA_DIRECTION bias,
                                  const double maxDistance,SZone &out) const;

   //! Highest-quality FRESH zone containing the price, if any.
   //! Quality ranks by impulse strength, then by freshness.
   bool              ZoneAtPrice(const double price,const ENUM_SEA_DIRECTION bias,SZone &out) const;

   //! True when the price sits inside a FRESH zone of that bias.
   bool              InFreshZone(const double price,const ENUM_SEA_DIRECTION bias) const;

   //! One-line summary.
   string            Describe(void) const;

   //! Deterministic fingerprint for the repaint test.
   string            Fingerprint(void) const;
  };

//+------------------------------------------------------------------+
CZones::CZones(void)
  {
   m_symbol      = "";
   m_tf          = PERIOD_CURRENT;
   m_atrHandle   = INVALID_HANDLE;
   m_atrPeriod   = 14;
   m_impulseATR  = 2.0;
   m_maxAgeBars  = 500;
   m_lookback    = 500;
   m_verbose     = false;
   m_lastBarTime = 0;
   m_ready       = false;
   m_zoneCount   = 0;
   ArrayResize(m_zones,SEA_MAX_ZONES);
  }

//+------------------------------------------------------------------+
CZones::~CZones(void)
  {
   ArrayFree(m_zones);
  }

//+------------------------------------------------------------------+
bool CZones::Init(const string symbol,const ENUM_TIMEFRAMES tf,CIndicatorPool &pool,
                  const double impulseATR,const int maxAgeBars,
                  const int atrPeriod,const int lookback)
  {
   m_symbol     = symbol;
   m_tf         = tf;
   m_atrPeriod  = (atrPeriod<2 ? 2 : (atrPeriod>200 ? 200 : atrPeriod));
   m_impulseATR = (impulseATR<0.5 ? 0.5 : (impulseATR>10.0 ? 10.0 : impulseATR));
   m_maxAgeBars = (maxAgeBars<20 ? 20 : (maxAgeBars>5000 ? 5000 : maxAgeBars));
   m_lookback   = (lookback<60 ? 60 : (lookback>5000 ? 5000 : lookback));
   m_zoneCount  = 0;
   m_ready      = false;
   m_lastBarTime= 0;

   //--- RULE 8: handle created here, never in OnTick
   m_atrHandle=pool.AcquireATR(symbol,tf,m_atrPeriod);
   if(m_atrHandle==INVALID_HANDLE)
     {
      if(m_verbose)
         PrintFormat("[CZones] %s: ATR handle unavailable",symbol);
      return(false);
     }

   int available=SeaAvailableBars(symbol,tf);
   if(available<60)
      return(false);
   if(available<m_lookback)
      m_lookback=available;

   return(Update(true));
  }

//+------------------------------------------------------------------+
void CZones::Release(CIndicatorPool &pool)
  {
   if(m_atrHandle!=INVALID_HANDLE)
     {
      pool.Release(m_atrHandle);
      m_atrHandle=INVALID_HANDLE;
     }
   m_ready=false;
  }

//+------------------------------------------------------------------+
void CZones::SetImpulseATR(const double mult)
  {
   double m=(mult<0.5 ? 0.5 : (mult>10.0 ? 10.0 : mult));
   if(MathAbs(m-m_impulseATR)<1.0e-9)
      return;
   m_impulseATR=m;
   m_lastBarTime=0;   // force rebuild
  }

//+------------------------------------------------------------------+
bool CZones::AddZone(const ENUM_SEA_ZONE_TYPE type,const ENUM_SEA_DIRECTION bias,
                     const double upper,const double lower,
                     const datetime time,const int shift,const double impulse)
  {
   if(m_zoneCount>=SEA_MAX_ZONES)
      return(false);
   if(upper<=lower)
      return(false);

   m_zones[m_zoneCount].type        = type;
   m_zones[m_zoneCount].state       = SEA_ZONE_FRESH;
   m_zones[m_zoneCount].bias        = bias;
   m_zones[m_zoneCount].upper       = upper;
   m_zones[m_zoneCount].lower       = lower;
   m_zones[m_zoneCount].originTime  = time;
   m_zones[m_zoneCount].originShift = shift;
   m_zones[m_zoneCount].ageBars     = shift-1;
   m_zones[m_zoneCount].touchCount  = 0;
   m_zones[m_zoneCount].impulseATR  = impulse;
   m_zones[m_zoneCount].overlapsFVG = false;
   m_zoneCount++;
   return(true);
  }

//+------------------------------------------------------------------+
//| Strength of the move leaving bar `start`, in ATR multiples.       |
//+------------------------------------------------------------------+
double CZones::ImpulseStrength(const MqlRates &r[],const int start,
                               const int bars,const bool bullish,const double atr) const
  {
   if(atr<=0.0)
      return(0.0);

   int last=start-bars;
   if(last<1 || start>=ArraySize(r))
      return(0.0);

   double move;
   if(bullish)
      move=r[last].high-r[start].low;
   else
      move=r[start].high-r[last].low;

   if(move<=0.0)
      return(0.0);
   return(move/atr);
  }

//+------------------------------------------------------------------+
//| Order blocks.                                                     |
//|                                                                   |
//| Demand = body of the last BEARISH candle before a bullish impulse |
//| Supply = body of the last BULLISH candle before a bearish impulse |
//| Impulse = move >= m_impulseATR within SEA_IMPULSE_MAX_BARS bars.  |
//+------------------------------------------------------------------+
void CZones::DetectOrderBlocks(const MqlRates &r[],const int total,const double atr)
  {
   if(atr<=0.0)
      return;

   //--- walk closed bars only; leave room for the impulse window
   for(int i=total-2; i>=1+SEA_IMPULSE_MAX_BARS; i--)
     {
      //--- bullish impulse leaving bar i
      double bullStrength=0.0;
      for(int b=1; b<=SEA_IMPULSE_MAX_BARS; b++)
        {
         double s=ImpulseStrength(r,i,b,true,atr);
         if(s>bullStrength)
            bullStrength=s;
        }

      if(bullStrength>=m_impulseATR && r[i].close<r[i].open)
        {
         //--- bar i is the last bearish candle before the push
         AddZone(SEA_ZONE_OB_DEMAND,SEA_DIR_LONG,
                 MathMax(r[i].open,r[i].close),MathMin(r[i].open,r[i].close),
                 r[i].time,i,bullStrength);
         continue;
        }

      //--- bearish impulse leaving bar i
      double bearStrength=0.0;
      for(int b=1; b<=SEA_IMPULSE_MAX_BARS; b++)
        {
         double s=ImpulseStrength(r,i,b,false,atr);
         if(s>bearStrength)
            bearStrength=s;
        }

      if(bearStrength>=m_impulseATR && r[i].close>r[i].open)
         AddZone(SEA_ZONE_OB_SUPPLY,SEA_DIR_SHORT,
                 MathMax(r[i].open,r[i].close),MathMin(r[i].open,r[i].close),
                 r[i].time,i,bearStrength);
     }
  }

//+------------------------------------------------------------------+
//| Fair value gaps: a 3-bar displacement leaving an untraded band.   |
//|                                                                   |
//| Bullish: Low[i] > High[i+2]   Bearish: High[i] < Low[i+2]         |
//| (series indexing, so i is newer than i+2)                         |
//+------------------------------------------------------------------+
void CZones::DetectFVGs(const MqlRates &r[],const int total)
  {
   for(int i=1; i+2<total; i++)
     {
      if(r[i].low>r[i+2].high)
         AddZone(SEA_ZONE_FVG_BULL,SEA_DIR_LONG,
                 r[i].low,r[i+2].high,r[i+1].time,i+1,0.0);
      else
         if(r[i].high<r[i+2].low)
            AddZone(SEA_ZONE_FVG_BEAR,SEA_DIR_SHORT,
                    r[i+2].low,r[i].high,r[i+1].time,i+1,0.0);
     }
  }

//+------------------------------------------------------------------+
//| Flag order blocks that contain a same-direction FVG.              |
//| The overlap is worth 10 points in CScoring.                       |
//+------------------------------------------------------------------+
void CZones::MarkOverlaps(void)
  {
   for(int a=0; a<m_zoneCount; a++)
     {
      if(m_zones[a].type!=SEA_ZONE_OB_DEMAND && m_zones[a].type!=SEA_ZONE_OB_SUPPLY)
         continue;

      for(int b=0; b<m_zoneCount; b++)
        {
         if(m_zones[b].type!=SEA_ZONE_FVG_BULL && m_zones[b].type!=SEA_ZONE_FVG_BEAR)
            continue;
         if(m_zones[b].bias!=m_zones[a].bias)
            continue;

         bool overlap=(m_zones[b].lower<=m_zones[a].upper &&
                       m_zones[b].upper>=m_zones[a].lower);
         if(overlap)
           {
            m_zones[a].overlapsFVG=true;
            break;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| State machine.                                                    |
//|                                                                   |
//| Every zone is replayed against the CLOSED bars that came after it.|
//|   wick into the zone, no close through   -> TAPPED                |
//|   trade through the body                 -> MITIGATED             |
//|   a bar CLOSES fully beyond the zone     -> INVERTED              |
//|   older than m_maxAgeBars                -> EXPIRED               |
//|                                                                   |
//| An INVERTED order block is a Breaker. An INVERTED FVG is an IFVG. |
//| Both are retyped so downstream modules see what they now are.     |
//+------------------------------------------------------------------+
void CZones::AgeAndTransition(const MqlRates &r[],const int total)
  {
   for(int z=0; z<m_zoneCount; z++)
     {
      int origin=m_zones[z].originShift;
      m_zones[z].ageBars=origin-1;

      if(m_zones[z].ageBars>m_maxAgeBars)
        {
         m_zones[z].state=SEA_ZONE_EXPIRED;
         continue;
        }

      bool bullZone=(m_zones[z].bias==SEA_DIR_LONG);

      //--- replay every closed bar after formation, oldest first
      for(int i=origin-1; i>=1; i--)
        {
         if(m_zones[z].state==SEA_ZONE_INVERTED || m_zones[z].state==SEA_ZONE_EXPIRED)
            break;

         bool wickedIn=(r[i].low<=m_zones[z].upper && r[i].high>=m_zones[z].lower);
         if(!wickedIn)
            continue;

         m_zones[z].touchCount++;

         //--- a CLOSE fully beyond the far edge inverts the zone
         bool closedThrough=(bullZone ? (r[i].close<m_zones[z].lower)
                             : (r[i].close>m_zones[z].upper));
         if(closedThrough)
           {
            m_zones[z].state=SEA_ZONE_INVERTED;

            switch(m_zones[z].type)
              {
               case SEA_ZONE_OB_DEMAND:
                  m_zones[z].type=SEA_ZONE_BREAKER_BEAR;
                  m_zones[z].bias=SEA_DIR_SHORT;
                  break;
               case SEA_ZONE_OB_SUPPLY:
                  m_zones[z].type=SEA_ZONE_BREAKER_BULL;
                  m_zones[z].bias=SEA_DIR_LONG;
                  break;
               case SEA_ZONE_FVG_BULL:
                  m_zones[z].type=SEA_ZONE_IFVG_BEAR;
                  m_zones[z].bias=SEA_DIR_SHORT;
                  break;
               case SEA_ZONE_FVG_BEAR:
                  m_zones[z].type=SEA_ZONE_IFVG_BULL;
                  m_zones[z].bias=SEA_DIR_LONG;
                  break;
              }
            break;
           }

         //--- traded into the body without closing through
         double bodyHigh=MathMax(r[i].open,r[i].close);
         double bodyLow =MathMin(r[i].open,r[i].close);
         bool   bodyIn  =(bodyLow<=m_zones[z].upper && bodyHigh>=m_zones[z].lower);

         if(bodyIn)
           {
            if(m_zones[z].state==SEA_ZONE_FRESH || m_zones[z].state==SEA_ZONE_TAPPED)
               m_zones[z].state=SEA_ZONE_MITIGATED;
           }
         else
            if(m_zones[z].state==SEA_ZONE_FRESH)
               m_zones[z].state=SEA_ZONE_TAPPED;
        }
     }
  }

//+------------------------------------------------------------------+
bool CZones::Update(const bool force)
  {
   if(m_symbol=="" || m_atrHandle==INVALID_HANDLE)
      return(false);

   datetime barTime=(datetime)SeriesInfoInteger(m_symbol,m_tf,SERIES_LASTBAR_DATE);
   if(!force && barTime==m_lastBarTime && m_ready)
      return(true);

   MqlRates r[];
   if(!SeaCopyRates(m_symbol,m_tf,0,m_lookback,r))
      return(false);

   //--- ATR read from the newest CLOSED bar
   double atr[];
   if(!SeaCopyBuffer(m_atrHandle,0,1,1,atr))
      return(false);

   int total=ArraySize(r);
   m_zoneCount=0;

   DetectOrderBlocks(r,total,atr[0]);
   DetectFVGs(r,total);
   AgeAndTransition(r,total);
   MarkOverlaps();

   m_lastBarTime = barTime;
   m_ready       = true;

   if(m_verbose)
      PrintFormat("[CZones] %s",Describe());

   return(true);
  }

//+------------------------------------------------------------------+
bool CZones::Get(const int index,SZone &out) const
  {
   if(index<0 || index>=m_zoneCount)
      return(false);
   out=m_zones[index];
   return(true);
  }

//+------------------------------------------------------------------+
int CZones::FreshCount(void) const
  {
   int n=0;
   for(int i=0; i<m_zoneCount; i++)
      if(m_zones[i].state==SEA_ZONE_FRESH)
         n++;
   return(n);
  }

//+------------------------------------------------------------------+
bool CZones::NearestFresh(const double price,const ENUM_SEA_DIRECTION bias,
                          const double maxDistance,SZone &out) const
  {
   int    best=-1;
   double bestDist=0.0;

   for(int i=0; i<m_zoneCount; i++)
     {
      if(m_zones[i].state!=SEA_ZONE_FRESH)
         continue;
      if(bias!=SEA_DIR_NONE && m_zones[i].bias!=bias)
         continue;

      //--- distance to the near edge, zero when price is inside
      double dist=0.0;
      if(price>m_zones[i].upper)
         dist=price-m_zones[i].upper;
      else
         if(price<m_zones[i].lower)
            dist=m_zones[i].lower-price;

      if(maxDistance>0.0 && dist>maxDistance)
         continue;

      if(best<0 || dist<bestDist)
        {
         best=i;
         bestDist=dist;
        }
     }

   if(best<0)
      return(false);
   out=m_zones[best];
   return(true);
  }

//+------------------------------------------------------------------+
bool CZones::ZoneAtPrice(const double price,const ENUM_SEA_DIRECTION bias,SZone &out) const
  {
   int    best=-1;
   double bestQuality=-1.0;

   for(int i=0; i<m_zoneCount; i++)
     {
      if(m_zones[i].state!=SEA_ZONE_FRESH)
         continue;
      if(bias!=SEA_DIR_NONE && m_zones[i].bias!=bias)
         continue;
      if(price<m_zones[i].lower || price>m_zones[i].upper)
         continue;

      //--- stronger impulse wins; a younger zone breaks the tie
      double quality=m_zones[i].impulseATR*1000.0-(double)m_zones[i].ageBars;
      if(quality>bestQuality)
        {
         bestQuality=quality;
         best=i;
        }
     }

   if(best<0)
      return(false);
   out=m_zones[best];
   return(true);
  }

//+------------------------------------------------------------------+
bool CZones::InFreshZone(const double price,const ENUM_SEA_DIRECTION bias) const
  {
   SZone z;
   return(ZoneAtPrice(price,bias,z));
  }

//+------------------------------------------------------------------+
string CZones::Describe(void) const
  {
   int fresh=0,tapped=0,mitigated=0,inverted=0,expired=0;
   for(int i=0; i<m_zoneCount; i++)
      switch(m_zones[i].state)
        {
         case SEA_ZONE_FRESH:     fresh++;     break;
         case SEA_ZONE_TAPPED:    tapped++;    break;
         case SEA_ZONE_MITIGATED: mitigated++; break;
         case SEA_ZONE_INVERTED:  inverted++;  break;
         case SEA_ZONE_EXPIRED:   expired++;   break;
        }

   return(StringFormat("%s zones=%d fresh=%d tapped=%d mitigated=%d inverted=%d expired=%d impulse=%.1fATR",
                       m_symbol,m_zoneCount,fresh,tapped,mitigated,inverted,expired,m_impulseATR));
  }

//+------------------------------------------------------------------+
string CZones::Fingerprint(void) const
  {
   string out=StringFormat("%s|%d|%d|",m_symbol,(int)m_tf,m_zoneCount);
   for(int i=0; i<m_zoneCount; i++)
      out+=StringFormat("%d:%d:%s:%s;",
                        (int)m_zones[i].type,(int)m_zones[i].state,
                        DoubleToString(m_zones[i].lower,8),
                        DoubleToString(m_zones[i].upper,8));
   return(out);
  }

#endif // SEA_CZONES_MQH
//+------------------------------------------------------------------+
