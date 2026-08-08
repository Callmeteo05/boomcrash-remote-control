//+------------------------------------------------------------------+
//|                                                       CGates.mqh  |
//|                                                                   |
//|   Module 15. Ten hard gates. NO COMPENSATION.                     |
//|                                                                   |
//|   Fail any one gate and there is no trade. A brilliant score does |
//|   not buy a failed gate, and the score is never consulted here -   |
//|   CScoring runs only on survivors.                                |
//|                                                                   |
//|   Cheap gates are evaluated first so the common rejections cost    |
//|   almost nothing, but ALL TEN are always evaluated and reported,   |
//|   because the journal needs the full picture to learn from a       |
//|   rejection.                                                       |
//+------------------------------------------------------------------+
#ifndef SEA_CGATES_MQH
#define SEA_CGATES_MQH

#include <SEA/SEA_Common.mqh>
#include <SEA/CMTF.mqh>
#include <SEA/CPhase.mqh>
#include <SEA/CRegime.mqh>
#include <SEA/CSpikeHazard.mqh>
#include <SEA/CAffordability.mqh>
#include <SEA/CProbabilityMap.mqh>

//--- gate indices, fixed so the journal can aggregate across sessions
#define SEA_GATE_SPREAD          0
#define SEA_GATE_AFFORDABILITY   1
#define SEA_GATE_HTF_NOT_RANGING 2
#define SEA_GATE_HAZARD          3
#define SEA_GATE_ZONE_FRESH      4
#define SEA_GATE_TRIGGER         5
#define SEA_GATE_INVALIDATION    6
#define SEA_GATE_PROBABILITY     7
#define SEA_GATE_RR              8
#define SEA_GATE_MANIPULATION    9

//+------------------------------------------------------------------+
//| Everything a gate evaluation needs, gathered by the scanner.      |
//+------------------------------------------------------------------+
struct SGateContext
  {
   string                symbol;
   int                   specIndex;
   ENUM_SEA_DIRECTION    direction;
   int                   execLevel;

   double                entryPrice;
   double                stopPrice;
   double                targetPrice;
   double                requiredStop;    // price units
   double                affordableStop;  // price units
   double                spread;          // price units
   double                spreadCap;       // price units

   bool                  zoneFound;
   ENUM_SEA_ZONE_STATE   zoneState;
   ENUM_SEA_ZONE_TYPE    zoneType;
   double                zoneUpper;
   double                zoneLower;

   ENUM_SEA_TRIGGER      trigger;
   bool                  invalidationDefined;
   double                invalidationLevel;

   double                probability;
   bool                  reversalHypothesis;
   double                hypothesisMargin;

   ENUM_SEA_PHASE        phase;
   bool                  sweepConfirmed;
   ENUM_SEA_REGIME       regime;
   ENUM_SEA_STRUCT_STATE htfState;
   double                rr;
  };

//+------------------------------------------------------------------+
//| CGates                                                            |
//+------------------------------------------------------------------+
class CGates
  {
private:
   double            m_minLocationScore;   // InpMinLocationScore, default 75
   double            m_minRR;              // InpMinRR, default 2.0
   double            m_stopSafetyFactor;   // 1.2
   bool              m_verbose;

   void              Set(SGateResult &r,const int index,const bool passed,
                         const string name,const string detail) const;

public:
                     CGates(void);
                    ~CGates(void) {}

   //! Configure.
   //!
   //! minLocationScore 50..95, default 75
   //! minRR            1.0..5.0, default 2.0
   //! stopSafetyFactor 1.0..3.0, default 1.2
   void              Configure(const double minLocationScore,const double minRR,
                               const double stopSafetyFactor);

   //! Print diagnostics. Off by default.
   void              SetVerbose(const bool enabled) { m_verbose=enabled; }

   //! Evaluate all ten gates.
   //!
   //! Returns the FULL result, never just the first failure - the
   //! journal needs every verdict to learn which gate is costing money
   //! and which is saving it.
   SGateResult       Evaluate(const SGateContext &ctx,CSpikeHazard &hazard) const;

   //! Convenience: did everything pass?
   bool              Passes(const SGateContext &ctx,CSpikeHazard &hazard) const;

   //! Readable multi-line report of a gate result.
   string            Report(const SGateResult &r) const;

   //! Compact single-line report for the journal CSV.
   string            CompactReport(const SGateResult &r) const;

   //! Name of a gate by index.
   string            GateName(const int index) const;
  };

//+------------------------------------------------------------------+
CGates::CGates(void)
  {
   m_minLocationScore = 75.0;
   m_minRR            = 2.0;
   m_stopSafetyFactor = 1.2;
   m_verbose          = false;
  }

//+------------------------------------------------------------------+
void CGates::Configure(const double minLocationScore,const double minRR,
                       const double stopSafetyFactor)
  {
   m_minLocationScore = (minLocationScore<50.0 ? 50.0
                         : (minLocationScore>95.0 ? 95.0 : minLocationScore));
   m_minRR            = (minRR<1.0 ? 1.0 : (minRR>5.0 ? 5.0 : minRR));
   m_stopSafetyFactor = (stopSafetyFactor<1.0 ? 1.0
                         : (stopSafetyFactor>3.0 ? 3.0 : stopSafetyFactor));
  }

//+------------------------------------------------------------------+
void CGates::Set(SGateResult &r,const int index,const bool passed,
                 const string name,const string detail) const
  {
   if(index<0 || index>=10)
      return;
   r.gates[index].passed = passed;
   r.gates[index].name   = name;
   r.gates[index].detail = detail;
  }

//+------------------------------------------------------------------+
string CGates::GateName(const int index) const
  {
   switch(index)
     {
      case SEA_GATE_SPREAD:          return("spread within cap");
      case SEA_GATE_AFFORDABILITY:   return("stop affordable");
      case SEA_GATE_HTF_NOT_RANGING: return("HTF not ranging");
      case SEA_GATE_HAZARD:          return("spike hazard permits");
      case SEA_GATE_ZONE_FRESH:      return("zone FRESH");
      case SEA_GATE_TRIGGER:         return("closed-bar trigger");
      case SEA_GATE_INVALIDATION:    return("invalidation definable");
      case SEA_GATE_PROBABILITY:     return("probability score");
      case SEA_GATE_RR:              return("reward to risk");
      case SEA_GATE_MANIPULATION:    return("manipulation confirmed");
     }
   return("unknown gate");
  }

//+------------------------------------------------------------------+
//| All ten. Cheap ones first, but every one evaluated.               |
//+------------------------------------------------------------------+
SGateResult CGates::Evaluate(const SGateContext &ctx,CSpikeHazard &hazard) const
  {
   SGateResult r;
   r.allPassed    = true;
   r.failedCount  = 0;
   r.firstFailure = "";

   //--- GATE 1 (cheapest): spread <= requiredStop * styleSpreadCap
   bool spreadOk=(ctx.spreadCap>0.0 && ctx.spread<=ctx.spreadCap);
   Set(r,SEA_GATE_SPREAD,spreadOk,GateName(SEA_GATE_SPREAD),
       StringFormat("spread %s vs cap %s",
                    DoubleToString(ctx.spread,8),DoubleToString(ctx.spreadCap,8)));

   //--- GATE 2 (cheap): affordableStop >= requiredStop * 1.2
   bool affordOk=(ctx.requiredStop>0.0 &&
                  ctx.affordableStop>=ctx.requiredStop*m_stopSafetyFactor);
   Set(r,SEA_GATE_AFFORDABILITY,affordOk,GateName(SEA_GATE_AFFORDABILITY),
       StringFormat("affordable %s vs required %s x%.2f",
                    DoubleToString(ctx.affordableStop,8),
                    DoubleToString(ctx.requiredStop,8),m_stopSafetyFactor));

   //--- GATE 3: HTF structure must not be RANGING
   bool htfOk=(ctx.htfState!=SEA_STRUCT_RANGING && ctx.htfState!=SEA_STRUCT_UNKNOWN);
   Set(r,SEA_GATE_HTF_NOT_RANGING,htfOk,GateName(SEA_GATE_HTF_NOT_RANGING),
       StringFormat("HTF %s",SeaStructStateToString(ctx.htfState)));

   //--- GATE 4: spike hazard permits this direction
   string hazardReason;
   bool hazardOk=hazard.PermitsEntry(ctx.symbol,ctx.direction,hazardReason);
   Set(r,SEA_GATE_HAZARD,hazardOk,GateName(SEA_GATE_HAZARD),
       (hazardOk ? StringFormat("hazard %.2f %s",
                                hazard.Hazard(ctx.symbol),
                                SeaHazardToString(hazard.Band(ctx.symbol)))
        : hazardReason));

   //--- GATE 5: the zone must be FRESH
   bool zoneOk=(ctx.zoneFound && ctx.zoneState==SEA_ZONE_FRESH);
   Set(r,SEA_GATE_ZONE_FRESH,zoneOk,GateName(SEA_GATE_ZONE_FRESH),
       (ctx.zoneFound ? StringFormat("%s %s",
                                     SeaZoneTypeToString(ctx.zoneType),
                                     SeaZoneStateToString(ctx.zoneState))
        : "no zone at entry"));

   //--- GATE 6: a price action trigger on a CLOSED bar
   bool triggerOk=(ctx.trigger!=SEA_TRIGGER_NONE);
   Set(r,SEA_GATE_TRIGGER,triggerOk,GateName(SEA_GATE_TRIGGER),
       SeaTriggerToString(ctx.trigger));

   //--- GATE 7: a structural invalidation point must exist
   bool invalidOk=(ctx.invalidationDefined && ctx.stopPrice>0.0);
   Set(r,SEA_GATE_INVALIDATION,invalidOk,GateName(SEA_GATE_INVALIDATION),
       (invalidOk ? StringFormat("invalidation at %s",DoubleToString(ctx.invalidationLevel,8))
        : "no structural invalidation - idea cannot be proven wrong"));

   //--- GATE 8: probability score at or above the location minimum
   bool probOk=(ctx.probability>=m_minLocationScore);
   Set(r,SEA_GATE_PROBABILITY,probOk,GateName(SEA_GATE_PROBABILITY),
       StringFormat("%.1f vs %.1f minimum (%s, margin %.1f)",
                    ctx.probability,m_minLocationScore,
                    (ctx.reversalHypothesis ? "reversal" : "breakout"),
                    ctx.hypothesisMargin));

   //--- GATE 9: reward to the nearest opposing liquidity
   bool rrOk=(ctx.rr>=m_minRR);
   Set(r,SEA_GATE_RR,rrOk,GateName(SEA_GATE_RR),
       StringFormat("%.2f vs %.2f minimum",ctx.rr,m_minRR));

   //--- GATE 10: in ACCUMULATION, the manipulation sweep must be confirmed.
   //--- Outside accumulation this gate is not applicable and passes.
   bool manipOk=true;
   string manipDetail="not in accumulation, not applicable";
   if(ctx.phase==SEA_PHASE_ACCUMULATION)
     {
      manipOk=ctx.sweepConfirmed;
      manipDetail=(manipOk ? "sweep confirmed"
                   : "ACCUMULATION with no confirmed manipulation sweep");
     }
   else
      if(ctx.phase==SEA_PHASE_MANIPULATION)
         manipDetail="manipulation phase, sequence complete";
   Set(r,SEA_GATE_MANIPULATION,manipOk,GateName(SEA_GATE_MANIPULATION),manipDetail);

   //--- tally. NO COMPENSATION: one failure is a rejection.
   for(int i=0; i<10; i++)
     {
      if(r.gates[i].passed)
         continue;
      r.failedCount++;
      r.allPassed=false;
      if(r.firstFailure=="")
         r.firstFailure=StringFormat("%s (%s)",r.gates[i].name,r.gates[i].detail);
     }

   if(m_verbose && !r.allPassed)
      PrintFormat("[CGates] %s %s REJECTED: %d gate(s) failed, first: %s",
                  ctx.symbol,SeaDirectionToString(ctx.direction),
                  r.failedCount,r.firstFailure);

   return(r);
  }

//+------------------------------------------------------------------+
bool CGates::Passes(const SGateContext &ctx,CSpikeHazard &hazard) const
  {
   SGateResult r=Evaluate(ctx,hazard);
   return(r.allPassed);
  }

//+------------------------------------------------------------------+
string CGates::Report(const SGateResult &r) const
  {
   string out=StringFormat("gates: %s (%d failed)\n",
                           (r.allPassed ? "ALL PASSED" : "REJECTED"),r.failedCount);
   for(int i=0; i<10; i++)
      out+=StringFormat("  [%s] %-24s %s\n",
                        (r.gates[i].passed ? "PASS" : "FAIL"),
                        r.gates[i].name,r.gates[i].detail);
   return(out);
  }

//+------------------------------------------------------------------+
string CGates::CompactReport(const SGateResult &r) const
  {
   string out="";
   for(int i=0; i<10; i++)
      out+=(r.gates[i].passed ? "1" : "0");
   return(out);
  }

#endif // SEA_CGATES_MQH
//+------------------------------------------------------------------+
