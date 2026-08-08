//+------------------------------------------------------------------+
//|                                              CProbabilityMap.mqh  |
//|                                                                   |
//|   Module 14. Graded reversal and breakout levels.                 |
//|                                                                   |
//|   Reversal and breakout are COMPETING HYPOTHESES at the same      |
//|   price. Both are computed, and the higher is returned with its   |
//|   margin over the loser. A narrow margin means the level is       |
//|   genuinely ambiguous, and the caller should treat it that way.   |
//|                                                                   |
//|   HARD RULE: an LTF CHoCH with no HTF zone at that price scores   |
//|   below threshold. LOCATION GATES THE SIGNAL. A change of         |
//|   character in the middle of nowhere is noise with a name.        |
//+------------------------------------------------------------------+
#ifndef SEA_CPROBABILITYMAP_MQH
#define SEA_CPROBABILITYMAP_MQH

#include <SEA/SEA_Common.mqh>
#include <SEA/CMTF.mqh>

//+------------------------------------------------------------------+
//| The verdict at one price.                                         |
//+------------------------------------------------------------------+
struct SProbability
  {
   bool                valid;
   double              score;            // 0..100, the winning hypothesis
   bool                isReversal;       // false = breakout
   double              margin;           // winner minus loser
   double              reversalScore;
   double              breakoutScore;
   ENUM_SEA_DIRECTION  direction;
   int                 levelsAgreeing;
   bool                htfZonePresent;
   string              breakdown;
  };

//+------------------------------------------------------------------+
//| CProbabilityMap                                                   |
//+------------------------------------------------------------------+
class CProbabilityMap
  {
private:
   double            m_stackWeight;       // InpMTFStackWeight, default 12
   double            m_noLocationCeiling; // score cap with no HTF zone
   bool              m_verbose;

   double            ScoreReversal(CMTF &mtf,const double price,
                                   const ENUM_SEA_DIRECTION dir,const int execLevel,
                                   string &detail,bool &htfZone) const;
   double            ScoreBreakout(CMTF &mtf,const double price,
                                   const ENUM_SEA_DIRECTION dir,const int execLevel,
                                   string &detail) const;

public:
                     CProbabilityMap(void);
                    ~CProbabilityMap(void) {}

   //! Configure.
   //!
   //! stackWeight        4..25, default 12  bonus per extra agreeing TF
   //! noLocationCeiling  0..74, default 40  hard cap when no HTF zone
   //!                                       sits at the price. Must stay
   //!                                       BELOW InpMinLocationScore or
   //!                                       the location rule leaks.
   void              Configure(const double stackWeight,const double noLocationCeiling);

   //! Print diagnostics. Off by default.
   void              SetVerbose(const bool enabled) { m_verbose=enabled; }

   //! Evaluate both hypotheses at a price and return the stronger.
   //!
   //! execLevel is the cascade index of the execution timeframe. Levels
   //! above it count as HTF for the location test.
   SProbability      Evaluate(CMTF &mtf,const double price,
                              const ENUM_SEA_DIRECTION dir,const int execLevel) const;

   //! Convenience: score only, 0.0 when the evaluation is invalid.
   double            ScoreAt(CMTF &mtf,const double price,
                             const ENUM_SEA_DIRECTION dir,const int execLevel) const;
  };

//+------------------------------------------------------------------+
CProbabilityMap::CProbabilityMap(void)
  {
   m_stackWeight       = 12.0;
   m_noLocationCeiling = 40.0;
   m_verbose           = false;
  }

//+------------------------------------------------------------------+
void CProbabilityMap::Configure(const double stackWeight,const double noLocationCeiling)
  {
   m_stackWeight       = (stackWeight<4.0 ? 4.0 : (stackWeight>25.0 ? 25.0 : stackWeight));
   m_noLocationCeiling = (noLocationCeiling<0.0 ? 0.0
                          : (noLocationCeiling>74.0 ? 74.0 : noLocationCeiling));
  }

//+------------------------------------------------------------------+
//| Reversal hypothesis.                                              |
//|                                                                   |
//| HIGH (80+) wants all of:                                          |
//|   at an HTF swing extreme                                         |
//|   inside an untested HTF zone                                     |
//|   premium/discount against the HTF bias                           |
//|   liquidity swept and rejected                                    |
//|   an LTF CHoCH                                                    |
//|   impulse legs decreasing (exhaustion)                            |
//+------------------------------------------------------------------+
double CProbabilityMap::ScoreReversal(CMTF &mtf,const double price,
                                      const ENUM_SEA_DIRECTION dir,const int execLevel,
                                      string &detail,bool &htfZone) const
  {
   detail="";
   htfZone=false;

   double score=0.0;

   //--- 1. inside an untested HTF zone. This is the location test.
   SZone zone;
   if(mtf.HTFZoneAtPrice(price,dir,execLevel,zone))
     {
      htfZone=true;
      score+=25.0;
      detail+=StringFormat("HTF %s FRESH +25; ",SeaZoneTypeToString(zone.type));
     }
   else
      detail+="no HTF zone at price +0; ";

   //--- 2. at an HTF swing extreme
   bool atExtreme=false;
   for(int i=0; i<execLevel && i<mtf.Levels(); i++)
     {
      CStructure *s=mtf.Structure(i);
      if(s==NULL || !s.IsReady())
         continue;

      SSwing sw;
      double tolerance=0.0;
      if(s.HasRange())
         tolerance=(s.RangeHigh()-s.RangeLow())*0.05;
      if(tolerance<=0.0)
         continue;

      if(dir==SEA_DIR_LONG && s.LastSwingLow(sw) && MathAbs(price-sw.price)<=tolerance)
         atExtreme=true;
      if(dir==SEA_DIR_SHORT && s.LastSwingHigh(sw) && MathAbs(price-sw.price)<=tolerance)
         atExtreme=true;
      if(atExtreme)
         break;
     }
   if(atExtreme)
     {
      score+=20.0;
      detail+="at HTF swing extreme +20; ";
     }

   //--- 3. premium/discount against the HTF bias
   CStructure *htf=mtf.Structure(0);
   if(htf!=NULL && htf.IsReady() && htf.HasRange())
     {
      bool discounted=htf.IsDiscount(price);
      bool premium   =htf.IsPremium(price);

      if((dir==SEA_DIR_LONG && discounted) || (dir==SEA_DIR_SHORT && premium))
        {
         score+=15.0;
         detail+=(dir==SEA_DIR_LONG ? "in discount +15; " : "in premium +15; ");
        }
     }

   //--- 4. liquidity swept and rejected on the side being reversed from
   for(int i=0; i<mtf.Levels(); i++)
     {
      CLiquidity *liq=mtf.Liquidity(i);
      if(liq==NULL)
         continue;

      double lvl;
      datetime t;
      bool highSide=(dir==SEA_DIR_SHORT);
      if(liq.RecentSweep(highSide,12,lvl,t))
        {
         score+=20.0;
         detail+="liquidity swept and reclaimed +20; ";
         break;
        }
     }

   //--- 5. an LTF CHoCH in the proposed direction
   CStructure *ltf=mtf.Structure(execLevel);
   if(ltf!=NULL && ltf.IsReady())
     {
      if(ltf.LastBreak()==SEA_BREAK_CHOCH && ltf.LastBreakDirection()==dir)
        {
         score+=15.0;
         detail+="LTF CHoCH +15; ";
        }
     }

   //--- 6. exhaustion: impulse legs decreasing
   if(ltf!=NULL && ltf.IsReady() && ltf.SwingCount()>=4)
     {
      SSwing a,b,c;
      if(ltf.GetSwing(0,a) && ltf.GetSwing(1,b) && ltf.GetSwing(2,c))
        {
         double leg1=MathAbs(a.price-b.price);
         double leg2=MathAbs(b.price-c.price);
         if(leg2>0.0 && leg1<leg2*0.75)
           {
            score+=5.0;
            detail+="impulse legs contracting +5; ";
           }
        }
     }

   return(score);
  }

//+------------------------------------------------------------------+
//| Breakout hypothesis.                                              |
//|                                                                   |
//| HIGH (80+) wants all of:                                          |
//|   compression against the HTF trend                               |
//|   3rd or later boundary test                                      |
//|   unswept liquidity beyond                                        |
//|   the range contracting                                           |
//|   a prior sweep already taken                                     |
//+------------------------------------------------------------------+
double CProbabilityMap::ScoreBreakout(CMTF &mtf,const double price,
                                      const ENUM_SEA_DIRECTION dir,const int execLevel,
                                      string &detail) const
  {
   detail="";
   double score=0.0;

   //--- 1. the HTF trend agrees with the breakout direction
   ENUM_SEA_DIRECTION htfBias=mtf.HTFBias();
   if(htfBias==dir)
     {
      score+=25.0;
      detail+="HTF trend agrees +25; ";
     }
   else
      if(htfBias!=SEA_DIR_NONE)
         detail+="breaking against HTF trend +0; ";

   //--- 2. boundary test count at the execution level
   CStructure *ltf=mtf.Structure(execLevel);
   if(ltf!=NULL && ltf.IsReady() && ltf.HasRange())
     {
      double boundary=(dir==SEA_DIR_LONG ? ltf.RangeHigh() : ltf.RangeLow());
      double span    =ltf.RangeHigh()-ltf.RangeLow();
      double tol     =span*0.05;

      //--- count swings that reached the boundary
      int tests=0;
      for(int k=0; k<ltf.SwingCount(); k++)
        {
         SSwing sw;
         if(!ltf.GetSwing(k,sw))
            continue;
         if(dir==SEA_DIR_LONG && sw.isHigh && MathAbs(sw.price-boundary)<=tol)
            tests++;
         if(dir==SEA_DIR_SHORT && !sw.isHigh && MathAbs(sw.price-boundary)<=tol)
            tests++;
        }

      if(tests>=3)
        {
         score+=20.0;
         detail+=StringFormat("%d boundary tests +20; ",tests);
        }
      else
         if(tests==2)
           {
            score+=10.0;
            detail+="2 boundary tests +10; ";
           }
     }

   //--- 3. unswept liquidity beyond the boundary to run into
   SLiquidity target;
   if(mtf.NearestUnswept(price,dir,target))
     {
      score+=20.0;
      detail+="unswept liquidity beyond +20; ";
     }
   else
      detail+="nothing beyond to run into +0; ";

   //--- 4. the range is contracting
   for(int i=0; i<mtf.Levels(); i++)
     {
      CZones *z=mtf.Zones(i);
      if(z==NULL)
         continue;
      //--- a compression signature: few FRESH zones because price has
      //--- been chopping through everything it made
      if(z.FreshCount()<=2 && z.Count()>6)
        {
         score+=15.0;
         detail+="range contracting +15; ";
         break;
        }
     }

   //--- 5. a prior sweep has already cleared the opposing side
   for(int i=0; i<mtf.Levels(); i++)
     {
      CLiquidity *liq=mtf.Liquidity(i);
      if(liq==NULL)
         continue;

      double lvl;
      datetime t;
      //--- an upward break is stronger once the LOW side has been swept,
      //--- and a downward break once the HIGH side has
      bool priorSweepHighSide=(dir==SEA_DIR_SHORT);
      if(liq.RecentSweep(priorSweepHighSide,20,lvl,t))
        {
         score+=20.0;
         detail+="prior opposing sweep taken +20; ";
         break;
        }
     }

   return(score);
  }

//+------------------------------------------------------------------+
SProbability CProbabilityMap::Evaluate(CMTF &mtf,const double price,
                                       const ENUM_SEA_DIRECTION dir,const int execLevel) const
  {
   SProbability out;
   out.valid          = false;
   out.score          = 0.0;
   out.isReversal     = true;
   out.margin         = 0.0;
   out.reversalScore  = 0.0;
   out.breakoutScore  = 0.0;
   out.direction      = dir;
   out.levelsAgreeing = 0;
   out.htfZonePresent = false;
   out.breakdown      = "";

   if(dir==SEA_DIR_NONE || !mtf.IsReady())
      return(out);

   string revDetail,brkDetail;
   bool   htfZone=false;

   out.reversalScore = ScoreReversal(mtf,price,dir,execLevel,revDetail,htfZone);
   out.breakoutScore = ScoreBreakout(mtf,price,dir,execLevel,brkDetail);
   out.htfZonePresent= htfZone;

   //--- MTF stacking bonus applies to whichever hypothesis wins
   out.levelsAgreeing=mtf.LevelsAgreeing(dir);
   double stacking=(out.levelsAgreeing>1 ? (out.levelsAgreeing-1)*m_stackWeight : 0.0);

   //--- competing hypotheses: the higher wins, the gap is the margin
   if(out.reversalScore>=out.breakoutScore)
     {
      out.isReversal = true;
      out.score      = out.reversalScore+stacking;
      out.margin     = out.reversalScore-out.breakoutScore;
      out.breakdown  = "REVERSAL: "+revDetail;
     }
   else
     {
      out.isReversal = false;
      out.score      = out.breakoutScore+stacking;
      out.margin     = out.breakoutScore-out.reversalScore;
      out.breakdown  = "BREAKOUT: "+brkDetail;
     }

   if(stacking>0.0)
      out.breakdown+=StringFormat("MTF stack %d levels +%.0f; ",out.levelsAgreeing,stacking);

   //--- HARD RULE: LOCATION GATES THE SIGNAL.
   //--- With no HTF zone at this price the score is capped below the
   //--- minimum location score, so GATE 2 cannot pass however good the
   //--- rest of the picture looks.
   if(!htfZone && out.score>m_noLocationCeiling)
     {
      out.breakdown+=StringFormat("CAPPED at %.0f: no HTF zone at this price; ",
                                  m_noLocationCeiling);
      out.score=m_noLocationCeiling;
     }

   if(out.score>100.0)
      out.score=100.0;
   if(out.score<0.0)
      out.score=0.0;

   out.valid=true;

   if(m_verbose)
      PrintFormat("[CProbabilityMap] %s %s score=%.1f (rev %.1f / brk %.1f, margin %.1f) %s",
                  mtf.Symbol(),SeaDirectionToString(dir),out.score,
                  out.reversalScore,out.breakoutScore,out.margin,out.breakdown);

   return(out);
  }

//+------------------------------------------------------------------+
double CProbabilityMap::ScoreAt(CMTF &mtf,const double price,
                                const ENUM_SEA_DIRECTION dir,const int execLevel) const
  {
   SProbability p=Evaluate(mtf,price,dir,execLevel);
   return(p.valid ? p.score : 0.0);
  }

#endif // SEA_CPROBABILITYMAP_MQH
//+------------------------------------------------------------------+
