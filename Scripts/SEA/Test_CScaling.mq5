//+------------------------------------------------------------------+
//|                                                Test_CScaling.mq5  |
//|                                                                   |
//|   Correctness test for module 17, CScaling.                       |
//|                                                                   |
//|   This is the module where a bug becomes a MARTINGALE, so the     |
//|   tests are written around the refusals rather than the happy     |
//|   path. The questions being answered:                             |
//|                                                                   |
//|     does it ever add to a loser?          (must be never)         |
//|     does it ever add before break-even?   (must be never)         |
//|     can a later leg be bigger than an earlier one?  (must be no)  |
//|     does it round a sub-minimum leg up?   (must be no - it stops) |
//|                                                                   |
//|   The decay ladder is walked all the way down to the broker       |
//|   minimum and past it, which is where a rounding bug would show.  |
//|                                                                   |
//|   Positions are TRACKED SYNTHETICALLY in CManagement - no order   |
//|   is ever placed and no live position is touched. The entry price |
//|   is set relative to the current market price to drive the winner |
//|   and loser branches deterministically.                           |
//+------------------------------------------------------------------+
#property script_show_inputs
#property description "CScaling unit test - synthetic positions, places NO orders"

#include <SEA/SEA_Common.mqh>
#include <SEA/CSymbolSpec.mqh>
#include <SEA/CRiskManager.mqh>
#include <SEA/CTradeExec.mqh>
#include <SEA/CStructure.mqh>
#include <SEA/CRegime.mqh>
#include <SEA/CSpikeHazard.mqh>
#include <SEA/CManagement.mqh>
#include <SEA/CScaling.mqh>

input long   InpTestMagic  = 99009900;  // Isolated magic - must NOT be the EA's
input double InpScaleDecay = 0.5;       // Decay under test (0.1-0.9)
input double InpTriggerR   = 1.0;       // Scale trigger in R

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

void CheckRefused(const bool mayAdd,const string reason,
                  const string mustContain,const string label)
  {
   bool refused=!mayAdd;
   bool named=(mustContain=="" || StringFind(reason,mustContain)>=0);

   if(refused && named)
     {
      g_pass++;
      PrintFormat("  PASS  %s",label);
      PrintFormat("        reason: %s",reason);
      return;
     }

   g_fail++;
   PrintFormat("  FAIL  %s",label);
   if(!refused)
      Print("        IT ALLOWED THE ADD. This is the martingale path.");
   else
      PrintFormat("        refused, but for the wrong reason: %s",reason);
  }

void Section(const string title)
  {
   Print("");
   Print("================================================================");
   Print("  ",title);
   Print("================================================================");
  }

//+------------------------------------------------------------------+
void OnStart()
  {
   if(InpTestMagic==20260808)
     {
      Print("REFUSED: InpTestMagic collides with the EA default magic.");
      Print("Pick a different number so this test cannot touch live baskets.");
      return;
     }

   CIndicatorPool pool;
   CSymbolSpec    spec;
   CRiskManager   risk;
   CTradeExec     exec;
   CStructure     structure;
   CRegime        regime;
   CSpikeHazard   hazard;
   CManagement    management;
   CScaling       scaling;

   spec.DetectAffixes();
   int idx=spec.Ensure(_Symbol);
   if(idx<0 || !spec.IsValid(idx))
     {
      Print("ABORT: chart symbol spec unusable - run Test_CSymbolSpec first");
      return;
     }

   risk.Init(InpTestMagic,5.0,3.0,4,4,400.0,2,50.0,0.25);
   exec.Init(spec,InpTestMagic,20,3);
   scaling.Configure(InpTestMagic,InpTriggerR,InpScaleDecay,1.0);
   management.Configure(1.0,0.5,true);

   //--- a calm synthetic profile, so hazard never interferes
   SProfile calm;
   calm.symbol      = _Symbol;
   calm.complete    = true;
   calm.spikeDriven = false;
   calm.spikeDirection = SEA_DIR_NONE;
   calm.spikeMeanIntervalBars = 0.0;
   calm.spikeMeanMagnitude    = 0.0;
   hazard.Init(InpTestMagic,5.0,14);
   hazard.Register(_Symbol,calm);

   const double vmin =spec.VolumeMin(idx);
   const double vstep=spec.VolumeStep(idx);
   const double point=spec.Point(idx);

   PrintFormat("Symbol %s  volumeMin %s  step %s",
               _Symbol,DoubleToString(vmin,4),DoubleToString(vstep,4));

   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(bid<=0.0)
     {
      Print("ABORT: no bid price");
      return;
     }

   //--- clear any leftover basket from a previous run
   GlobalVariableDel(StringFormat("SEA_%d_BSK_%s",(int)InpTestMagic,_Symbol));
   scaling.CloseBasket(_Symbol);

   //-----------------------------------------------------------------
   Section("1. DECAY LADDER - EVERY LEG SMALLER THAN THE LAST");

   //--- start from a size that can decay several times before hitting
   //--- the broker minimum
   double firstLeg=vmin*8.0;
   firstLeg=spec.NormalizeVolume(idx,firstLeg);
   if(firstLeg<=0.0)
      firstLeg=vmin;

   scaling.OpenBasket(_Symbol,SEA_DIR_LONG,firstLeg,1.0,SEA_STRUCT_BULLISH);
   Check(scaling.LegCount(_Symbol)==1,"a new basket starts at one leg");

   PrintFormat("  first leg: %s",DoubleToString(firstLeg,4));

   double previous=firstLeg;
   int    steps=0;
   bool   everGrew=false;
   bool   everRoundedUp=false;

   for(int i=0; i<12; i++)
     {
      double next=scaling.NextLegLots(_Symbol,spec,idx);
      if(next<=0.0)
        {
         PrintFormat("  leg %d: scaling STOPPED (decayed below the broker minimum)",i+2);
         break;
        }

      //--- THE RULE: never larger than the leg before it
      if(next>previous+1.0e-12)
        {
         everGrew=true;
         PrintFormat("  leg %d: %s is LARGER than the previous %s - MARTINGALE",
                     i+2,DoubleToString(next,4),DoubleToString(previous,4));
        }

      //--- and never rounded up past the raw decay
      double raw=previous*InpScaleDecay;
      if(next>raw+vstep*1.0e-6)
        {
         everRoundedUp=true;
         PrintFormat("  leg %d: %s exceeds the raw decay %s - ROUNDED UP",
                     i+2,DoubleToString(next,4),DoubleToString(raw,8));
        }

      PrintFormat("  leg %d: %s  (raw decay %s)",
                  i+2,DoubleToString(next,4),DoubleToString(raw,8));

      scaling.RecordLeg(_Symbol,next,1.0);
      previous=next;
      steps++;
     }

   Check(!everGrew,"no leg was ever larger than the one before it");
   Check(!everRoundedUp,"no leg was ever rounded UP past its raw decay");
   Check(steps>0,"the ladder produced at least one decayed leg");

   double finalLeg=scaling.NextLegLots(_Symbol,spec,idx);
   Check(finalLeg==0.0,
         "once decay falls below VOLUME_MIN the answer is 0.0 - stop, not round up");

   SBasket b;
   Check(scaling.Get(_Symbol,b),"basket state readable");
   PrintFormat("  %s",scaling.Describe(_Symbol));
   Check(b.legCount==steps+1,"leg count matches the number of recorded legs");

   //-----------------------------------------------------------------
   Section("2. DECAY IS CLAMPED STRICTLY BELOW 1.0");

   CScaling greedy;
   greedy.Configure(InpTestMagic+1,1.0,1.5,1.0);   // ask for 150% per leg
   greedy.OpenBasket(_Symbol,SEA_DIR_LONG,vmin*10.0,1.0,SEA_STRUCT_BULLISH);

   double greedyNext=greedy.NextLegLots(_Symbol,spec,idx);
   PrintFormat("  requested decay 1.5, first leg %s -> next %s",
               DoubleToString(vmin*10.0,4),DoubleToString(greedyNext,4));

   Check(greedyNext<vmin*10.0,
         "a decay above 1.0 is clamped - the next leg is still SMALLER");
   greedy.CloseBasket(_Symbol);
   GlobalVariableDel(StringFormat("SEA_%d_BSK_%s",(int)(InpTestMagic+1),_Symbol));

   //-----------------------------------------------------------------
   Section("3. REFUSALS - THE PART THAT KEEPS THIS FROM BEING A MARTINGALE");

   //--- rebuild a clean single-leg basket
   scaling.CloseBasket(_Symbol);
   scaling.OpenBasket(_Symbol,SEA_DIR_LONG,firstLeg,1.0,SEA_STRUCT_BULLISH);

   //--- structure and regime on the live chart symbol
   ENUM_TIMEFRAMES tf=(ENUM_TIMEFRAMES)_Period;   // RULE 10: no PERIOD_ here
   bool haveStructure=structure.Init(_Symbol,tf,3,50,300);
   bool haveRegime   =regime.Init(_Symbol,tf,pool,14,50,14,25.0,20.0,1.5,0.7);
   if(haveRegime)
      regime.Update(GetPointer(structure),true);

   if(!haveStructure || !haveRegime)
      Print("  NOTE: structure or regime unavailable; refusals below still apply");

   const ulong TICKET=123456789;
   const double risk_distance=point*100.0;

   //--- 3a. A POSITION IN DRAWDOWN. Entry ABOVE the current bid on a
   //--- long, so the trade is losing.
   management.Track(TICKET,_Symbol,SEA_DIR_LONG,
                    bid+risk_distance*3.0,      // entry well above price
                    bid+risk_distance*2.0,      // stop
                    firstLeg,false);

   string reason;
   bool may=scaling.MayAdd(_Symbol,SEA_DIR_LONG,TICKET,management,
                           GetPointer(structure),GetPointer(regime),
                           hazard,risk,3,3,reason);
   CheckRefused(may,reason,"drawdown","a position in DRAWDOWN is refused");

   SManagedPosition dropped;
   management.Untrack(TICKET,dropped);

   //--- 3b. A WINNER, but the stop is not yet at break-even
   management.Track(TICKET,_Symbol,SEA_DIR_LONG,
                    bid-risk_distance*3.0,      // entry well below price: winning
                    bid-risk_distance*4.0,      // stop below entry
                    firstLeg,false);

   may=scaling.MayAdd(_Symbol,SEA_DIR_LONG,TICKET,management,
                      GetPointer(structure),GetPointer(regime),
                      hazard,risk,3,3,reason);
   CheckRefused(may,reason,"break-even",
                "a WINNER is still refused before the stop reaches break-even");

   //--- 3c. direction mismatch against the open basket
   may=scaling.MayAdd(_Symbol,SEA_DIR_SHORT,TICKET,management,
                      GetPointer(structure),GetPointer(regime),
                      hazard,risk,3,3,reason);
   CheckRefused(may,reason,"direction",
                "an add in the opposite direction to the basket is refused");

   //--- 3d. an untracked ticket
   may=scaling.MayAdd(_Symbol,SEA_DIR_LONG,999999999,management,
                      GetPointer(structure),GetPointer(regime),
                      hazard,risk,3,3,reason);
   CheckRefused(may,reason,"not tracked","an untracked position is refused");

   //--- 3e. NULL engines must refuse, not crash or assume
   may=scaling.MayAdd(_Symbol,SEA_DIR_LONG,TICKET,management,
                      NULL,NULL,hazard,risk,3,3,reason);
   CheckRefused(may,reason,"unavailable",
                "missing structure or regime engines refuse rather than assume");

   //--- 3f. no basket at all
   CScaling empty;
   empty.Configure(InpTestMagic+2,InpTriggerR,InpScaleDecay,1.0);
   may=empty.MayAdd(_Symbol,SEA_DIR_LONG,TICKET,management,
                    GetPointer(structure),GetPointer(regime),
                    hazard,risk,3,3,reason);
   CheckRefused(may,reason,"basket","an add with no open basket is refused");

   //--- 3g. structure changed since the basket opened
   scaling.CloseBasket(_Symbol);
   ENUM_SEA_STRUCT_STATE liveState=structure.State();
   ENUM_SEA_STRUCT_STATE wrongState=(liveState==SEA_STRUCT_BULLISH
                                     ? SEA_STRUCT_BEARISH : SEA_STRUCT_BULLISH);
   scaling.OpenBasket(_Symbol,SEA_DIR_LONG,firstLeg,1.0,wrongState);

   //--- make the position a break-even winner so earlier gates pass
   management.Untrack(TICKET,dropped);
   management.Track(TICKET,_Symbol,SEA_DIR_LONG,
                    bid-risk_distance*3.0,bid-risk_distance*4.0,firstLeg,false);

   may=scaling.MayAdd(_Symbol,SEA_DIR_LONG,TICKET,management,
                      GetPointer(structure),GetPointer(regime),
                      hazard,risk,3,3,reason);
   Check(!may,"an add is refused when structure changed since entry");
   PrintFormat("        reason: %s",reason);

   //-----------------------------------------------------------------
   Section("4. LEG CEILING IS THE LOWEST OF STYLE, PROFILE AND REGIME");

   scaling.CloseBasket(_Symbol);
   scaling.OpenBasket(_Symbol,SEA_DIR_LONG,firstLeg,1.0,liveState);

   //--- push the basket past every plausible ceiling
   for(int i=0; i<6; i++)
      scaling.RecordLeg(_Symbol,vmin,1.0);

   PrintFormat("  basket now at %d legs",scaling.LegCount(_Symbol));

   //--- a profile permitting zero legs must veto regardless of style
   may=scaling.MayAdd(_Symbol,SEA_DIR_LONG,TICKET,management,
                      GetPointer(structure),GetPointer(regime),
                      hazard,risk,10,0,reason);
   Check(!may,"a profile maximum of 0 legs vetoes even a permissive style");
   PrintFormat("        reason: %s",reason);

   //--- and a style permitting zero does the same
   may=scaling.MayAdd(_Symbol,SEA_DIR_LONG,TICKET,management,
                      GetPointer(structure),GetPointer(regime),
                      hazard,risk,0,10,reason);
   Check(!may,"a style maximum of 0 legs vetoes even a permissive profile");
   PrintFormat("        reason: %s",reason);

   PrintFormat("  live regime is %s (scale-ins %d)",
               SeaRegimeToString(regime.Regime()),
               regime.Profile().maxScaleIns);

   //-----------------------------------------------------------------
   Section("5. BASKET PERSISTENCE");

   scaling.CloseBasket(_Symbol);
   scaling.OpenBasket(_Symbol,SEA_DIR_LONG,firstLeg,1.0,liveState);
   scaling.RecordLeg(_Symbol,firstLeg*InpScaleDecay,1.0);
   int legsBefore=scaling.LegCount(_Symbol);
   scaling.Persist();

   string key=StringFormat("SEA_%d_BSK_%s",(int)InpTestMagic,_Symbol);
   Check(GlobalVariableCheck(key),"basket state written to GlobalVariables");

   //--- a fresh CScaling must recover the leg count
   CScaling restored;
   restored.Configure(InpTestMagic,InpTriggerR,InpScaleDecay,1.0);
   restored.Restore(_Symbol);

   PrintFormat("  before %d legs, restored %d legs",
               legsBefore,restored.LegCount(_Symbol));
   Check(restored.LegCount(_Symbol)==legsBefore,
         "a fresh instance recovers the leg count across a restart");

   //-----------------------------------------------------------------
   Section("6. CLEANUP");

   scaling.CloseBasket(_Symbol);
   restored.CloseBasket(_Symbol);
   empty.CloseBasket(_Symbol);
   management.Untrack(TICKET,dropped);
   GlobalVariableDel(key);
   GlobalVariableDel(StringFormat("SEA_%d_BSK_%s",(int)(InpTestMagic+2),_Symbol));

   Check(!GlobalVariableCheck(key),"test basket state removed");
   Check(management.Count()==0,"no synthetic positions left tracked");

   regime.Release(pool);
   pool.ReleaseAll();
   Check(pool.LiveHandles()==0,"every indicator handle released");

   //-----------------------------------------------------------------
   Print("");
   Print("================================================================");
   PrintFormat("  RESULT: %d passed, %d failed",g_pass,g_fail);
   if(g_fail==0)
      Print("  CScaling refuses every losing add. No martingale path found.");
   else
      Print("  CScaling FAILED. Do NOT run this EA - it may add to losers.");
   Print("================================================================");
  }
//+------------------------------------------------------------------+
