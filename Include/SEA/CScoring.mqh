//+------------------------------------------------------------------+
//|                                                     CScoring.mqh  |
//|                                                                   |
//|   Module 16. Confluence scoring among gate survivors ONLY.        |
//|                                                                   |
//|   Scoring decides WHICH qualified setup to take. It NEVER decides |
//|   WHETHER to trade - that was settled by CGates, and nothing here |
//|   can reopen it. A setup that failed a gate is never scored.      |
//|                                                                   |
//|   The scale, verbatim:                                            |
//|     HTF bias aligned                 20                           |
//|     Sweep preceded CHoCH             20                           |
//|     Entry in OTE 0.618-0.79          15                           |
//|     Zone FRESH and untested          15                           |
//|     OB + FVG overlap                 10                           |
//|     Target = unswept liquidity       10                           |
//|     RR >= 1:3                        10                           |
//|     MTF stacking bonus              +12 per extra TF              |
//|     Follows confirmed manipulation  +25                           |
//|     Distribution phase, with move   +20                           |
//|     Entry in unresolved accumulation -40                          |
//|     Range break with no prior sweep  -30                          |
//+------------------------------------------------------------------+
#ifndef SEA_CSCORING_MQH
#define SEA_CSCORING_MQH

#include <SEA/SEA_Common.mqh>
#include <SEA/CMTF.mqh>
#include <SEA/CPhase.mqh>

//+------------------------------------------------------------------+
//| Inputs to a scoring pass.                                         |
//+------------------------------------------------------------------+
struct SScoreContext
  {
   string                symbol;
   ENUM_SEA_DIRECTION    direction;
   int                   execLevel;

   double                entryPrice;
   double                stopPrice;
   double                targetPrice;
   double                rr;

   bool                  htfAligned;
   bool                  sweepPrecededChoch;
   bool                  entryInOTE;
   bool                  zoneFresh;
   bool                  zoneUntested;
   bool                  obFvgOverlap;
   bool                  targetIsUnsweptLiquidity;

   int                   levelsAgreeing;
   ENUM_SEA_PHASE        phase;
   bool                  manipulationConfirmed;
   bool                  distributionWithMove;
   bool                  accumulationUnresolved;
   bool                  rangeBreakWithoutSweep;
  };

//+------------------------------------------------------------------+
//| One scored setup.                                                 |
//+------------------------------------------------------------------+
struct SScoreResult
  {
   double            total;
   double            threshold;
   bool              qualifies;
   string            breakdown;
   string            topFactors;   // the three biggest positive contributors
  };

//+------------------------------------------------------------------+
//| CScoring                                                          |
//+------------------------------------------------------------------+
class CScoring
  {
private:
   double            m_minConfluence;   // InpMinConfluenceScore, default 80
   double            m_stackWeight;     // InpMTFStackWeight, default 12
   bool              m_verbose;

public:
                     CScoring(void);
                    ~CScoring(void) {}

   //! Configure.
   //!
   //! minConfluence 50..150, default 80. The symbol profile may raise
   //!               this per instrument (70 clean .. 90 noisy).
   //! stackWeight   4..25,  default 12
   void              Configure(const double minConfluence,const double stackWeight);

   //! Print diagnostics. Off by default.
   void              SetVerbose(const bool enabled) { m_verbose=enabled; }

   //! Current base threshold.
   double            Threshold(void) const { return m_minConfluence; }

   //! Score one gate survivor.
   //!
   //! profileMinConfluence overrides the base threshold when it is
   //! higher - a noisy instrument demands more confluence, never less.
   //! Pass 0.0 to use the base threshold.
   SScoreResult      Score(const SScoreContext &ctx,const double profileMinConfluence) const;

   //! Build a scoring context from the live cascade. Convenience used
   //! by the scanner so the field mapping lives in one place.
   SScoreContext     BuildContext(CMTF &mtf,CPhase &phase,
                                  const string symbol,const ENUM_SEA_DIRECTION dir,
                                  const int execLevel,
                                  const double entry,const double stop,const double target,
                                  const bool zoneFresh,const bool zoneUntested,
                                  const bool obFvgOverlap,
                                  const bool targetIsLiquidity) const;

   //! Sort an array of setups by score, descending. Simple insertion
   //! sort - the candidate list is short by construction.
   void              SortByScore(SSetup &setups[],const int count) const;
  };

//+------------------------------------------------------------------+
CScoring::CScoring(void)
  {
   m_minConfluence = 80.0;
   m_stackWeight   = 12.0;
   m_verbose       = false;
  }

//+------------------------------------------------------------------+
void CScoring::Configure(const double minConfluence,const double stackWeight)
  {
   m_minConfluence = (minConfluence<50.0 ? 50.0 : (minConfluence>150.0 ? 150.0 : minConfluence));
   m_stackWeight   = (stackWeight<4.0 ? 4.0 : (stackWeight>25.0 ? 25.0 : stackWeight));
  }

//+------------------------------------------------------------------+
SScoreResult CScoring::Score(const SScoreContext &ctx,const double profileMinConfluence) const
  {
   SScoreResult out;
   out.total      = 0.0;
   out.breakdown  = "";
   out.topFactors = "";

   //--- a noisy instrument raises the bar; it never lowers it
   out.threshold=m_minConfluence;
   if(profileMinConfluence>out.threshold)
      out.threshold=profileMinConfluence;

   //--- track contributors so the alert can name the top three
   double  values[12];
   string  names[12];
   int     n=0;

   //--- positives
   if(ctx.htfAligned)
     {
      out.total+=20.0;
      values[n]=20.0;
      names[n]="HTF bias aligned";
      n++;
      out.breakdown+="HTF aligned +20; ";
     }

   if(ctx.sweepPrecededChoch)
     {
      out.total+=20.0;
      values[n]=20.0;
      names[n]="sweep preceded CHoCH";
      n++;
      out.breakdown+="sweep->CHoCH +20; ";
     }

   if(ctx.entryInOTE)
     {
      out.total+=15.0;
      values[n]=15.0;
      names[n]="entry in OTE";
      n++;
      out.breakdown+="OTE +15; ";
     }

   if(ctx.zoneFresh && ctx.zoneUntested)
     {
      out.total+=15.0;
      values[n]=15.0;
      names[n]="zone fresh and untested";
      n++;
      out.breakdown+="fresh untested zone +15; ";
     }

   if(ctx.obFvgOverlap)
     {
      out.total+=10.0;
      values[n]=10.0;
      names[n]="OB and FVG overlap";
      n++;
      out.breakdown+="OB+FVG +10; ";
     }

   if(ctx.targetIsUnsweptLiquidity)
     {
      out.total+=10.0;
      values[n]=10.0;
      names[n]="target is unswept liquidity";
      n++;
      out.breakdown+="target=liquidity +10; ";
     }

   if(ctx.rr>=3.0)
     {
      out.total+=10.0;
      values[n]=10.0;
      names[n]="RR at or above 1:3";
      n++;
      out.breakdown+=StringFormat("RR %.2f +10; ",ctx.rr);
     }

   //--- MTF stacking
   if(ctx.levelsAgreeing>1)
     {
      double bonus=(ctx.levelsAgreeing-1)*m_stackWeight;
      out.total+=bonus;
      values[n]=bonus;
      names[n]=StringFormat("%d timeframes stacked",ctx.levelsAgreeing);
      n++;
      out.breakdown+=StringFormat("MTF stack x%d +%.0f; ",ctx.levelsAgreeing-1,bonus);
     }

   if(ctx.manipulationConfirmed)
     {
      out.total+=25.0;
      values[n]=25.0;
      names[n]="follows confirmed manipulation";
      n++;
      out.breakdown+="post-manipulation +25; ";
     }

   if(ctx.distributionWithMove)
     {
      out.total+=20.0;
      values[n]=20.0;
      names[n]="distribution, with the move";
      n++;
      out.breakdown+="distribution +20; ";
     }

   //--- negatives. These are the expensive mistakes, priced accordingly.
   if(ctx.accumulationUnresolved)
     {
      out.total-=40.0;
      out.breakdown+="unresolved accumulation -40; ";
     }

   if(ctx.rangeBreakWithoutSweep)
     {
      out.total-=30.0;
      out.breakdown+="range break with no prior sweep -30; ";
     }

   //--- top three positive contributors, for the entry alert
   for(int pass=0; pass<3 && pass<n; pass++)
     {
      int    best=-1;
      double bestVal=0.0;
      for(int i=0; i<n; i++)
        {
         if(values[i]<=0.0)
            continue;
         if(best<0 || values[i]>bestVal)
           {
            best=i;
            bestVal=values[i];
           }
        }
      if(best<0)
         break;
      if(out.topFactors!="")
         out.topFactors+=", ";
      out.topFactors+=StringFormat("%s (%.0f)",names[best],values[best]);
      values[best]=0.0;   // consumed
     }

   out.qualifies=(out.total>=out.threshold);

   if(m_verbose)
      PrintFormat("[CScoring] %s %s scored %.0f vs %.0f: %s",
                  ctx.symbol,SeaDirectionToString(ctx.direction),
                  out.total,out.threshold,out.breakdown);

   return(out);
  }

//+------------------------------------------------------------------+
SScoreContext CScoring::BuildContext(CMTF &mtf,CPhase &phase,
                                     const string symbol,const ENUM_SEA_DIRECTION dir,
                                     const int execLevel,
                                     const double entry,const double stop,const double target,
                                     const bool zoneFresh,const bool zoneUntested,
                                     const bool obFvgOverlap,
                                     const bool targetIsLiquidity) const
  {
   SScoreContext c;
   c.symbol      = symbol;
   c.direction   = dir;
   c.execLevel   = execLevel;
   c.entryPrice  = entry;
   c.stopPrice   = stop;
   c.targetPrice = target;

   double risk=MathAbs(entry-stop);
   c.rr=(risk>0.0 ? MathAbs(target-entry)/risk : 0.0);

   c.htfAligned    = (mtf.HTFBias()==dir);
   c.levelsAgreeing= mtf.LevelsAgreeing(dir);

   //--- sweep preceding a CHoCH is exactly what CPhase confirms
   c.sweepPrecededChoch = (phase.SweepConfirmed() &&
                           phase.ManipulationDirection()==dir);

   //--- OTE measured at the execution level's dealing range
   c.entryInOTE=false;
   CStructure *ltf=mtf.Structure(execLevel);
   if(ltf!=NULL && ltf.IsReady())
      c.entryInOTE=ltf.IsOTE(entry,dir);

   c.zoneFresh                = zoneFresh;
   c.zoneUntested             = zoneUntested;
   c.obFvgOverlap             = obFvgOverlap;
   c.targetIsUnsweptLiquidity = targetIsLiquidity;

   c.phase                 = phase.Phase();
   c.manipulationConfirmed = (phase.Phase()==SEA_PHASE_MANIPULATION);

   c.distributionWithMove  = (phase.Phase()==SEA_PHASE_DISTRIBUTION &&
                              mtf.HTFBias()==dir);

   //--- entering an accumulation range that has NOT yet been resolved by
   //--- a confirmed sweep is the classic way to be the liquidity
   c.accumulationUnresolved= (phase.Phase()==SEA_PHASE_ACCUMULATION &&
                              !phase.SweepConfirmed());

   //--- a break out of a range where nothing was swept first tends to be
   //--- the fake, not the move
   c.rangeBreakWithoutSweep=false;
   if(ltf!=NULL && ltf.IsReady() && ltf.LastBreak()==SEA_BREAK_BOS)
      c.rangeBreakWithoutSweep=!phase.SweepConfirmed();

   return(c);
  }

//+------------------------------------------------------------------+
void CScoring::SortByScore(SSetup &setups[],const int count) const
  {
   for(int i=1; i<count; i++)
     {
      SSetup key=setups[i];
      int j=i-1;
      while(j>=0 && setups[j].score<key.score)
        {
         setups[j+1]=setups[j];
         j--;
        }
      setups[j+1]=key;
     }
  }

#endif // SEA_CSCORING_MQH
//+------------------------------------------------------------------+
