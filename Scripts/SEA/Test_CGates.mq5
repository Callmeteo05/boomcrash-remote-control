//+------------------------------------------------------------------+
//|                                                  Test_CGates.mq5  |
//|                                                                   |
//|   Correctness test for module 15, CGates.                         |
//|                                                                   |
//|   This is a TRUE UNIT TEST. CGates takes a plain SGateContext, so |
//|   every input is built by hand and every expected verdict is      |
//|   known in advance. Nothing here depends on live market data      |
//|   except the spike hazard registration, which is driven through   |
//|   a synthetic profile.                                            |
//|                                                                   |
//|   The property that matters most: NO COMPENSATION. The method is  |
//|   to build a context that passes all ten, then break exactly one  |
//|   field at a time and assert that:                                |
//|     - that gate fails                                             |
//|     - allPassed is false                                          |
//!     - every OTHER gate still passes                               |
//|                                                                   |
//|   That last clause is what catches a gate reading the wrong       |
//|   field, which is the failure mode that would otherwise show up   |
//|   as mysterious over-trading months later.                        |
//|                                                                   |
//|   Places no orders. Reads no chart data.                          |
//+------------------------------------------------------------------+
#property script_show_inputs
#property description "CGates unit test - synthetic inputs, no orders, no market data"

#include <SEA/SEA_Common.mqh>
#include <SEA/CGates.mqh>
#include <SEA/CSpikeHazard.mqh>

input double InpMinLocationScore = 75.0;  // Gate 8 threshold under test
input double InpMinRR            = 2.0;   // Gate 9 threshold under test
input double InpStopSafety       = 1.2;   // Gate 2 safety factor under test

int g_pass = 0;
int g_fail = 0;

//+------------------------------------------------------------------+
void Check(const bool condition,const string label)
  {
   if(condition)
     {
      g_pass++;
      PrintFormat("  PASS  %s",label);
     }
   else
     {
      g_fail++;
      PrintFormat("  FAIL  %s",label);
     }
  }

void Section(const string title)
  {
   Print("");
   Print("================================================================");
   Print("  ",title);
   Print("================================================================");
  }

//+------------------------------------------------------------------+
//| A context engineered to pass all ten gates.                       |
//|                                                                   |
//| Every value sits comfortably clear of its threshold so that a     |
//| deliberate break is unambiguous.                                  |
//+------------------------------------------------------------------+
SGateContext PassingContext(const string symbol)
  {
   SGateContext c;

   c.symbol              = symbol;
   c.specIndex           = 0;
   c.direction           = SEA_DIR_LONG;
   c.execLevel           = 4;

   c.entryPrice          = 100.0;
   c.stopPrice           = 99.0;
   c.targetPrice         = 104.0;

   c.requiredStop        = 1.0;
   c.affordableStop      = 5.0;      // 5x required, well past the 1.2 factor
   c.spread              = 0.05;
   c.spreadCap           = 0.15;

   c.zoneFound           = true;
   c.zoneState           = SEA_ZONE_FRESH;
   c.zoneType            = SEA_ZONE_OB_DEMAND;
   c.zoneUpper           = 100.2;
   c.zoneLower           = 99.8;

   c.trigger             = SEA_TRIGGER_ENGULFING;
   c.invalidationDefined = true;
   c.invalidationLevel   = 99.0;

   c.probability         = 88.0;
   c.reversalHypothesis  = true;
   c.hypothesisMargin    = 20.0;

   c.phase               = SEA_PHASE_DISTRIBUTION;   // gate 10 not applicable
   c.sweepConfirmed      = false;
   c.regime              = SEA_REGIME_TRENDING;
   c.htfState            = SEA_STRUCT_BULLISH;
   c.rr                  = 4.0;

   return(c);
  }

//+------------------------------------------------------------------+
//| Assert that exactly one gate failed, and that it was the expected |
//| one. This is the no-compensation and no-crosstalk check in one.   |
//+------------------------------------------------------------------+
void ExpectOnlyGateFails(CGates &gates,CSpikeHazard &hazard,
                         const SGateContext &ctx,const int expectedGate,
                         const string label)
  {
   SGateResult r=gates.Evaluate(ctx,hazard);

   bool targetFailed=!r.gates[expectedGate].passed;
   bool othersOk=true;
   string collateral="";

   for(int i=0; i<10; i++)
     {
      if(i==expectedGate)
         continue;
      if(!r.gates[i].passed)
        {
         othersOk=false;
         collateral+=StringFormat("%s; ",r.gates[i].name);
        }
     }

   bool rejected=!r.allPassed;

   if(targetFailed && othersOk && rejected && r.failedCount==1)
     {
      g_pass++;
      PrintFormat("  PASS  %s  (only '%s' failed)",label,gates.GateName(expectedGate));
      return;
     }

   g_fail++;
   PrintFormat("  FAIL  %s",label);
   if(!targetFailed)
      PrintFormat("        expected gate '%s' did NOT fail",gates.GateName(expectedGate));
   if(!othersOk)
      PrintFormat("        collateral damage - other gates also failed: %s",collateral);
   if(!rejected)
      PrintFormat("        allPassed was TRUE despite a failure - NO COMPENSATION IS BROKEN");
   if(r.failedCount!=1)
      PrintFormat("        failedCount was %d, expected 1",r.failedCount);
  }

//+------------------------------------------------------------------+
void OnStart()
  {
   CGates       gates;
   CSpikeHazard hazard;

   gates.Configure(InpMinLocationScore,InpMinRR,InpStopSafety);
   hazard.Init(0,5.0,14);

   const string SYM="TESTSYM";
   const string SPIKESYM="SPIKESYM";

   //--- a synthetic NON-spike profile, so gate 10 has no opinion
   SProfile calm;
   calm.symbol                = SYM;
   calm.complete              = true;
   calm.spikeDriven           = false;
   calm.spikeDirection        = SEA_DIR_NONE;
   calm.spikeMeanIntervalBars = 0.0;
   calm.spikeMeanMagnitude    = 0.0;
   calm.spikeConsistency      = 0.0;
   calm.spikeCount            = 0;
   hazard.Register(SYM,calm);

   //-----------------------------------------------------------------
   Section("1. THE BASELINE MUST PASS ALL TEN");

   SGateContext base=PassingContext(SYM);
   SGateResult  r=gates.Evaluate(base,hazard);

   Check(r.allPassed,"engineered context passes all ten gates");
   Check(r.failedCount==0,"failedCount is zero");
   Check(r.firstFailure=="","firstFailure is empty");

   if(!r.allPassed)
     {
      Print("  Baseline does not pass, so the isolation tests below are");
      Print("  meaningless. Full report:");
      Print(gates.Report(r));
      Print("  ABORTING");
      return;
     }

   Check(StringLen(gates.CompactReport(r))==10,"compact report is a 10-character mask");
   Check(gates.CompactReport(r)=="1111111111","all-pass mask is ten ones");

   //-----------------------------------------------------------------
   Section("2. EACH GATE FAILS IN ISOLATION - NO COMPENSATION, NO CROSSTALK");

   //--- GATE 0: spread above the cap
   SGateContext c=base;
   c.spread=0.20;                      // cap is 0.15
   ExpectOnlyGateFails(gates,hazard,c,SEA_GATE_SPREAD,"spread above cap rejects");

   //--- GATE 1: affordable stop below required x safety
   c=base;
   c.affordableStop=1.1;               // required 1.0 x 1.2 = 1.2
   ExpectOnlyGateFails(gates,hazard,c,SEA_GATE_AFFORDABILITY,
                       "unaffordable stop rejects");

   //--- the boundary: exactly at required x safety must PASS
   c=base;
   c.affordableStop=1.2;
   r=gates.Evaluate(c,hazard);
   Check(r.gates[SEA_GATE_AFFORDABILITY].passed,
         "affordable stop exactly at required x1.2 passes (boundary inclusive)");

   //--- and a hair under must FAIL
   c.affordableStop=1.1999;
   r=gates.Evaluate(c,hazard);
   Check(!r.gates[SEA_GATE_AFFORDABILITY].passed,
         "a hair under required x1.2 fails");

   //--- GATE 2: HTF ranging
   c=base;
   c.htfState=SEA_STRUCT_RANGING;
   ExpectOnlyGateFails(gates,hazard,c,SEA_GATE_HTF_NOT_RANGING,
                       "HTF RANGING rejects");

   c=base;
   c.htfState=SEA_STRUCT_UNKNOWN;
   ExpectOnlyGateFails(gates,hazard,c,SEA_GATE_HTF_NOT_RANGING,
                       "HTF UNKNOWN rejects (absence of structure is not permission)");

   //--- GATE 4: zone not fresh
   c=base;
   c.zoneState=SEA_ZONE_TAPPED;
   ExpectOnlyGateFails(gates,hazard,c,SEA_GATE_ZONE_FRESH,"TAPPED zone rejects");

   c=base;
   c.zoneState=SEA_ZONE_MITIGATED;
   ExpectOnlyGateFails(gates,hazard,c,SEA_GATE_ZONE_FRESH,"MITIGATED zone rejects");

   c=base;
   c.zoneFound=false;
   c.zoneState=SEA_ZONE_FRESH;
   ExpectOnlyGateFails(gates,hazard,c,SEA_GATE_ZONE_FRESH,"no zone at all rejects");

   //--- GATE 5: no trigger
   c=base;
   c.trigger=SEA_TRIGGER_NONE;
   ExpectOnlyGateFails(gates,hazard,c,SEA_GATE_TRIGGER,"absent price action trigger rejects");

   //--- GATE 6: no definable invalidation
   c=base;
   c.invalidationDefined=false;
   ExpectOnlyGateFails(gates,hazard,c,SEA_GATE_INVALIDATION,
                       "undefinable invalidation rejects");

   c=base;
   c.stopPrice=0.0;
   ExpectOnlyGateFails(gates,hazard,c,SEA_GATE_INVALIDATION,
                       "zero stop price rejects even when invalidation is flagged");

   //--- GATE 7: probability below the location minimum
   c=base;
   c.probability=InpMinLocationScore-0.1;
   ExpectOnlyGateFails(gates,hazard,c,SEA_GATE_PROBABILITY,
                       "probability below the location minimum rejects");

   c=base;
   c.probability=InpMinLocationScore;
   r=gates.Evaluate(c,hazard);
   Check(r.gates[SEA_GATE_PROBABILITY].passed,
         "probability exactly at the minimum passes (boundary inclusive)");

   //--- GATE 8: reward to risk
   c=base;
   c.rr=InpMinRR-0.01;
   ExpectOnlyGateFails(gates,hazard,c,SEA_GATE_RR,"RR below the minimum rejects");

   c=base;
   c.rr=InpMinRR;
   r=gates.Evaluate(c,hazard);
   Check(r.gates[SEA_GATE_RR].passed,"RR exactly at the minimum passes");

   //-----------------------------------------------------------------
   Section("3. GATE 10 - ACCUMULATION DEMANDS A CONFIRMED SWEEP");

   //--- in ACCUMULATION with no sweep: reject
   c=base;
   c.phase=SEA_PHASE_ACCUMULATION;
   c.sweepConfirmed=false;
   ExpectOnlyGateFails(gates,hazard,c,SEA_GATE_MANIPULATION,
                       "ACCUMULATION without a confirmed sweep rejects");

   //--- in ACCUMULATION with a sweep: pass
   c.sweepConfirmed=true;
   r=gates.Evaluate(c,hazard);
   Check(r.allPassed,"ACCUMULATION with a confirmed sweep passes");

   //--- outside accumulation the gate is not applicable
   c=base;
   c.phase=SEA_PHASE_MANIPULATION;
   c.sweepConfirmed=false;
   r=gates.Evaluate(c,hazard);
   Check(r.gates[SEA_GATE_MANIPULATION].passed,
         "outside ACCUMULATION the sweep gate is not applicable and passes");

   c.phase=SEA_PHASE_UNDEFINED;
   r=gates.Evaluate(c,hazard);
   Check(r.gates[SEA_GATE_MANIPULATION].passed,
         "UNDEFINED phase does not trigger the sweep requirement");

   //-----------------------------------------------------------------
   Section("4. GATE 3 - SPIKE HAZARD");

   //--- an UNREGISTERED symbol must be refused. Unknown is dangerous.
   c=base;
   c.symbol="NEVER_REGISTERED";
   r=gates.Evaluate(c,hazard);
   Check(!r.gates[SEA_GATE_HAZARD].passed,
         "an unregistered symbol is REFUSED, not assumed safe");
   Check(!r.allPassed,"and the setup is rejected overall");

   //--- a spike-driven symbol with no stored counter starts EXTREME
   GlobalVariableDel(StringFormat("SEA_%d_SPK_%s",0,SPIKESYM));

   SProfile spiky;
   spiky.symbol                = SPIKESYM;
   spiky.complete              = true;
   spiky.spikeDriven           = true;
   spiky.spikeDirection        = SEA_DIR_SHORT;   // spikes go DOWN
   spiky.spikeMeanIntervalBars = 100.0;
   spiky.spikeMeanMagnitude    = 5.0;
   spiky.spikeConsistency      = 0.95;
   spiky.spikeCount            = 60;
   hazard.Register(SPIKESYM,spiky);

   PrintFormat("  %s",hazard.Describe(SPIKESYM));
   Check(hazard.Band(SPIKESYM)==SEA_HAZARD_EXTREME,
         "a fresh spike symbol with no stored counter starts at EXTREME");

   //--- LONG is counter-spike here (spikes are SHORT), so it is refused
   c=base;
   c.symbol=SPIKESYM;
   c.direction=SEA_DIR_LONG;
   ExpectOnlyGateFails(gates,hazard,c,SEA_GATE_HAZARD,
                       "counter-spike entry at EXTREME hazard rejects");

   //--- SHORT is WITH the spike, and must be permitted at EXTREME.
   //--- This is the important half: hazard restricts one side without
   //--- ever locking the instrument to a direction.
   c.direction=SEA_DIR_SHORT;
   r=gates.Evaluate(c,hazard);
   Check(r.gates[SEA_GATE_HAZARD].passed,
         "WITH-spike entry is permitted at EXTREME hazard");
   Check(r.allPassed,
         "and the whole setup passes - the instrument is not direction-locked");

   Check(hazard.IsCounterSpike(SPIKESYM,SEA_DIR_LONG),
         "LONG is correctly identified as counter-spike");
   Check(!hazard.IsCounterSpike(SPIKESYM,SEA_DIR_SHORT),
         "SHORT is correctly identified as with-spike");
   Check(!hazard.IsCounterSpike(SYM,SEA_DIR_LONG),
         "a non-spike symbol has no counter-spike direction at all");

   //--- a non-spike symbol constrains neither side
   c=base;
   c.symbol=SYM;
   c.direction=SEA_DIR_LONG;
   r=gates.Evaluate(c,hazard);
   bool longOk=r.gates[SEA_GATE_HAZARD].passed;
   c.direction=SEA_DIR_SHORT;
   r=gates.Evaluate(c,hazard);
   bool shortOk=r.gates[SEA_GATE_HAZARD].passed;
   Check(longOk && shortOk,
         "a symbol with no measured spike character permits both directions");

   GlobalVariableDel(StringFormat("SEA_%d_SPK_%s",0,SPIKESYM));

   //-----------------------------------------------------------------
   Section("5. NO COMPENSATION - A PERFECT SCORE CANNOT BUY A FAILED GATE");

   //--- everything maxed out, but one gate broken
   c=base;
   c.probability      = 100.0;
   c.rr               = 99.0;
   c.affordableStop   = 1000.0;
   c.hypothesisMargin = 100.0;
   c.spread           = 0.0;
   //--- and the single failure
   c.trigger=SEA_TRIGGER_NONE;

   r=gates.Evaluate(c,hazard);
   Check(!r.allPassed,
         "a maximal context with ONE failed gate is still REJECTED");
   Check(r.failedCount==1,"exactly one gate failed");
   Check(StringFind(r.firstFailure,"trigger")>=0,
         "firstFailure names the trigger gate");

   //--- multiple failures are all reported, not just the first
   c=base;
   c.trigger    = SEA_TRIGGER_NONE;
   c.rr         = 0.5;
   c.zoneState  = SEA_ZONE_MITIGATED;
   c.htfState   = SEA_STRUCT_RANGING;

   r=gates.Evaluate(c,hazard);
   Check(r.failedCount==4,
         StringFormat("all four broken gates reported, not just the first (got %d)",
                      r.failedCount));
   Check(!r.gates[SEA_GATE_TRIGGER].passed &&
         !r.gates[SEA_GATE_RR].passed &&
         !r.gates[SEA_GATE_ZONE_FRESH].passed &&
         !r.gates[SEA_GATE_HTF_NOT_RANGING].passed,
         "each of the four is individually marked failed");

   Check(gates.CompactReport(r)!="1111111111","compact mask reflects the failures");
   PrintFormat("  mask: %s",gates.CompactReport(r));

   //-----------------------------------------------------------------
   Section("6. EVERY GATE IS ALWAYS REPORTED");

   //--- even when the cheapest gate fails first, all ten carry a name
   //--- and a detail, because the journal aggregates on them
   c=base;
   c.spread=99.0;
   r=gates.Evaluate(c,hazard);

   bool allNamed=true;
   for(int i=0; i<10; i++)
      if(r.gates[i].name=="")
        {
         allNamed=false;
         PrintFormat("        gate %d has no name",i);
        }
   Check(allNamed,"all ten gates carry a name even after an early failure");

   bool allDetailed=true;
   for(int i=0; i<10; i++)
      if(r.gates[i].detail=="")
        {
         allDetailed=false;
         PrintFormat("        gate %d has no detail",i);
        }
   Check(allDetailed,"all ten gates carry a detail string");

   bool namesUnique=true;
   for(int i=0; i<10; i++)
      for(int j=i+1; j<10; j++)
         if(gates.GateName(i)==gates.GateName(j))
           {
            namesUnique=false;
            PrintFormat("        gates %d and %d share a name",i,j);
           }
   Check(namesUnique,"the ten gate names are distinct");

   //-----------------------------------------------------------------
   Section("7. DETERMINISM");

   c=base;
   SGateResult a1=gates.Evaluate(c,hazard);
   SGateResult a2=gates.Evaluate(c,hazard);
   Check(gates.CompactReport(a1)==gates.CompactReport(a2),
         "identical input yields an identical mask");
   Check(a1.failedCount==a2.failedCount,"identical failedCount");

   //-----------------------------------------------------------------
   Print("");
   Print("================================================================");
   PrintFormat("  RESULT: %d passed, %d failed",g_pass,g_fail);
   if(g_fail==0)
      Print("  CGates holds. No gate compensates for another.");
   else
      Print("  CGates FAILED. A leaking gate means unplanned trades.");
   Print("================================================================");
  }
//+------------------------------------------------------------------+
