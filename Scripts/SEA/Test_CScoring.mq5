//+------------------------------------------------------------------+
//|                                                Test_CScoring.mq5  |
//|                                                                   |
//|   Correctness test for module 16, CScoring.                       |
//|                                                                   |
//|   A TRUE UNIT TEST. Every factor is isolated and its point value  |
//|   checked against the scale in CLAUDE.md, verbatim:               |
//|                                                                   |
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
//|                                                                   |
//|   A drifting point value is the kind of bug that never announces  |
//|   itself - the EA just quietly starts preferring the wrong        |
//|   setups. This test pins every one of them.                       |
//|                                                                   |
//|   Places no orders. Reads no chart data.                          |
//+------------------------------------------------------------------+
#property script_show_inputs
#property description "CScoring unit test - synthetic inputs, no orders, no market data"

#include <SEA/SEA_Common.mqh>
#include <SEA/CScoring.mqh>

input double InpMinConfluence = 80.0;  // Base threshold under test
input double InpStackWeight   = 12.0;  // Stacking bonus per extra timeframe

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

void CheckScore(const double actual,const double expected,const string label)
  {
   if(MathAbs(actual-expected)<1.0e-9)
     {
      g_pass++;
      PrintFormat("  PASS  %-52s = %.1f",label,actual);
     }
   else
     {
      g_fail++;
      PrintFormat("  FAIL  %-52s = %.1f, expected %.1f",label,actual,expected);
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
//| A context scoring exactly zero: every factor off, RR below 3.     |
//+------------------------------------------------------------------+
SScoreContext EmptyContext()
  {
   SScoreContext c;

   c.symbol                   = "TESTSYM";
   c.direction                = SEA_DIR_LONG;
   c.execLevel                = 4;
   c.entryPrice               = 100.0;
   c.stopPrice                = 99.0;
   c.targetPrice              = 101.0;
   c.rr                       = 1.0;      // below the 3.0 bonus threshold

   c.htfAligned               = false;
   c.sweepPrecededChoch       = false;
   c.entryInOTE               = false;
   c.zoneFresh                = false;
   c.zoneUntested             = false;
   c.obFvgOverlap             = false;
   c.targetIsUnsweptLiquidity = false;

   c.levelsAgreeing           = 0;
   c.phase                    = SEA_PHASE_UNDEFINED;
   c.manipulationConfirmed    = false;
   c.distributionWithMove     = false;
   c.accumulationUnresolved   = false;
   c.rangeBreakWithoutSweep   = false;

   return(c);
  }

//+------------------------------------------------------------------+
void OnStart()
  {
   CScoring scoring;
   scoring.Configure(InpMinConfluence,InpStackWeight);

   //-----------------------------------------------------------------
   Section("1. THE EMPTY CONTEXT SCORES ZERO");

   SScoreContext c=EmptyContext();
   SScoreResult  r=scoring.Score(c,0.0);

   CheckScore(r.total,0.0,"no factors set");
   Check(!r.qualifies,"a zero score does not qualify");
   CheckScore(r.threshold,InpMinConfluence,"threshold defaults to the configured base");

   //-----------------------------------------------------------------
   Section("2. EACH FACTOR IN ISOLATION - EXACT POINT VALUES");

   c=EmptyContext();
   c.htfAligned=true;
   CheckScore(scoring.Score(c,0.0).total,20.0,"HTF bias aligned");

   c=EmptyContext();
   c.sweepPrecededChoch=true;
   CheckScore(scoring.Score(c,0.0).total,20.0,"sweep preceded CHoCH");

   c=EmptyContext();
   c.entryInOTE=true;
   CheckScore(scoring.Score(c,0.0).total,15.0,"entry in OTE 0.618-0.79");

   //--- this one needs BOTH flags, which is the documented condition
   c=EmptyContext();
   c.zoneFresh=true;
   c.zoneUntested=true;
   CheckScore(scoring.Score(c,0.0).total,15.0,"zone FRESH and untested");

   c=EmptyContext();
   c.zoneFresh=true;
   c.zoneUntested=false;
   CheckScore(scoring.Score(c,0.0).total,0.0,"FRESH but touched scores nothing");

   c=EmptyContext();
   c.zoneFresh=false;
   c.zoneUntested=true;
   CheckScore(scoring.Score(c,0.0).total,0.0,"untested but not FRESH scores nothing");

   c=EmptyContext();
   c.obFvgOverlap=true;
   CheckScore(scoring.Score(c,0.0).total,10.0,"OB and FVG overlap");

   c=EmptyContext();
   c.targetIsUnsweptLiquidity=true;
   CheckScore(scoring.Score(c,0.0).total,10.0,"target is unswept liquidity");

   c=EmptyContext();
   c.manipulationConfirmed=true;
   CheckScore(scoring.Score(c,0.0).total,25.0,"follows confirmed manipulation");

   c=EmptyContext();
   c.distributionWithMove=true;
   CheckScore(scoring.Score(c,0.0).total,20.0,"distribution phase, with the move");

   //-----------------------------------------------------------------
   Section("3. THE RR BONUS AND ITS BOUNDARY");

   c=EmptyContext();
   c.rr=2.99;
   CheckScore(scoring.Score(c,0.0).total,0.0,"RR just under 1:3 earns nothing");

   c.rr=3.0;
   CheckScore(scoring.Score(c,0.0).total,10.0,"RR exactly 1:3 earns the bonus");

   c.rr=10.0;
   CheckScore(scoring.Score(c,0.0).total,10.0,"RR far above 1:3 earns the same 10, not more");

   //-----------------------------------------------------------------
   Section("4. MTF STACKING - (levels - 1) x weight");

   c=EmptyContext();
   c.levelsAgreeing=0;
   CheckScore(scoring.Score(c,0.0).total,0.0,"no agreeing levels");

   c.levelsAgreeing=1;
   CheckScore(scoring.Score(c,0.0).total,0.0,"one agreeing level is not a stack");

   c.levelsAgreeing=2;
   CheckScore(scoring.Score(c,0.0).total,InpStackWeight,"two levels = 1 x weight");

   c.levelsAgreeing=3;
   CheckScore(scoring.Score(c,0.0).total,InpStackWeight*2.0,"three levels = 2 x weight");

   c.levelsAgreeing=5;
   CheckScore(scoring.Score(c,0.0).total,InpStackWeight*4.0,"five levels = 4 x weight");

   //-----------------------------------------------------------------
   Section("5. THE PENALTIES");

   c=EmptyContext();
   c.accumulationUnresolved=true;
   CheckScore(scoring.Score(c,0.0).total,-40.0,"entry in unresolved accumulation");

   c=EmptyContext();
   c.rangeBreakWithoutSweep=true;
   CheckScore(scoring.Score(c,0.0).total,-30.0,"range break with no prior sweep");

   //--- a penalty must be able to sink an otherwise strong setup
   c=EmptyContext();
   c.htfAligned=true;              // +20
   c.entryInOTE=true;              // +15
   c.accumulationUnresolved=true;  // -40
   CheckScore(scoring.Score(c,0.0).total,-5.0,"penalties can drive the total negative");
   Check(!scoring.Score(c,0.0).qualifies,"a negative total never qualifies");

   //--- both penalties together
   c=EmptyContext();
   c.accumulationUnresolved=true;
   c.rangeBreakWithoutSweep=true;
   CheckScore(scoring.Score(c,0.0).total,-70.0,"both penalties are additive");

   //-----------------------------------------------------------------
   Section("6. FULL HOUSE - EVERY POSITIVE FACTOR");

   c=EmptyContext();
   c.htfAligned               = true;   // 20
   c.sweepPrecededChoch       = true;   // 20
   c.entryInOTE               = true;   // 15
   c.zoneFresh                = true;   // 15
   c.zoneUntested             = true;
   c.obFvgOverlap             = true;   // 10
   c.targetIsUnsweptLiquidity = true;   // 10
   c.rr                       = 4.0;    // 10
   c.manipulationConfirmed    = true;   // 25
   c.distributionWithMove     = true;   // 20
   //--- 145 before stacking

   CheckScore(scoring.Score(c,0.0).total,145.0,"all positives, no stacking");

   c.levelsAgreeing=4;                  // +36 at weight 12
   CheckScore(scoring.Score(c,0.0).total,145.0+InpStackWeight*3.0,
              "all positives plus a four-level stack");

   Check(scoring.Score(c,0.0).qualifies,"a full house qualifies");

   //-----------------------------------------------------------------
   Section("7. THRESHOLD - A NOISY PROFILE RAISES IT, NEVER LOWERS IT");

   c=EmptyContext();
   c.htfAligned=true;
   c.sweepPrecededChoch=true;
   c.entryInOTE=true;
   c.zoneFresh=true;
   c.zoneUntested=true;
   c.obFvgOverlap=true;      // 80 exactly

   r=scoring.Score(c,0.0);
   CheckScore(r.total,80.0,"context scores exactly the base threshold");
   Check(r.qualifies,"a score exactly at the threshold qualifies (inclusive)");

   //--- a noisy instrument demanding 90 must reject the same setup
   r=scoring.Score(c,90.0);
   CheckScore(r.threshold,90.0,"a higher profile threshold is adopted");
   Check(!r.qualifies,"the same setup fails against the raised bar");

   //--- a clean instrument asking for 70 must NOT lower the bar
   r=scoring.Score(c,70.0);
   CheckScore(r.threshold,InpMinConfluence,
              "a lower profile threshold is IGNORED - the bar never drops");
   Check(r.qualifies,"and the setup still qualifies at the base threshold");

   //-----------------------------------------------------------------
   Section("8. TOP FACTORS - THE THREE LARGEST, IN ORDER");

   c=EmptyContext();
   c.manipulationConfirmed    = true;   // 25 - largest
   c.htfAligned               = true;   // 20
   c.distributionWithMove     = true;   // 20
   c.obFvgOverlap             = true;   // 10 - should NOT appear
   c.targetIsUnsweptLiquidity = true;   // 10 - should NOT appear

   r=scoring.Score(c,0.0);
   PrintFormat("  topFactors: %s",r.topFactors);

   Check(StringFind(r.topFactors,"manipulation")>=0,
         "the 25-point factor appears in the top three");
   Check(StringFind(r.topFactors,"OB and FVG")<0,
         "a 10-point factor does not displace a 20-point one");

   //--- exactly three entries, so two commas
   int commas=0;
   for(int i=0; i<StringLen(r.topFactors); i++)
      if(StringGetCharacter(r.topFactors,i)==',')
         commas++;
   Check(commas==2,StringFormat("exactly three factors listed (found %d separators)",commas));

   //--- with fewer than three factors it must not invent any
   c=EmptyContext();
   c.htfAligned=true;
   r=scoring.Score(c,0.0);
   Check(StringFind(r.topFactors,",")<0,
         "a single factor produces a single entry, not padding");

   c=EmptyContext();
   r=scoring.Score(c,0.0);
   Check(r.topFactors=="","no factors produces an empty list");

   //-----------------------------------------------------------------
   Section("9. BREAKDOWN STRING IS POPULATED");

   c=EmptyContext();
   c.htfAligned=true;
   c.accumulationUnresolved=true;
   r=scoring.Score(c,0.0);
   PrintFormat("  breakdown: %s",r.breakdown);

   Check(StringLen(r.breakdown)>0,"breakdown is not empty");
   Check(StringFind(r.breakdown,"+20")>=0,"breakdown records the positive");
   Check(StringFind(r.breakdown,"-40")>=0,"breakdown records the penalty");

   //-----------------------------------------------------------------
   Section("10. SORT BY SCORE - DESCENDING, STABLE ENOUGH TO RANK");

   SSetup setups[];
   ArrayResize(setups,5);

   double scores[5]={45.0,120.0,80.0,-10.0,95.0};
   for(int i=0; i<5; i++)
     {
      setups[i].valid  = true;
      setups[i].symbol = StringFormat("SYM%d",i);
      setups[i].score  = scores[i];
     }

   scoring.SortByScore(setups,5);

   string order="";
   for(int i=0; i<5; i++)
      order+=StringFormat("%.0f ",setups[i].score);
   PrintFormat("  sorted: %s",order);

   bool descending=true;
   for(int i=1; i<5; i++)
      if(setups[i].score>setups[i-1].score)
         descending=false;
   Check(descending,"candidates are ordered highest score first");

   CheckScore(setups[0].score,120.0,"the best candidate is first");
   CheckScore(setups[4].score,-10.0,"the worst candidate is last");

   //--- sorting must move the whole record, not just the number
   Check(setups[0].symbol=="SYM1","the symbol travelled with its score");
   Check(setups[4].symbol=="SYM3","the last record is intact too");

   //--- degenerate sizes must not crash
   scoring.SortByScore(setups,0);
   scoring.SortByScore(setups,1);
   Check(true,"sorting zero and one elements is safe");

   //-----------------------------------------------------------------
   Section("11. DETERMINISM");

   c=EmptyContext();
   c.htfAligned=true;
   c.levelsAgreeing=3;
   c.rr=5.0;

   SScoreResult s1=scoring.Score(c,0.0);
   SScoreResult s2=scoring.Score(c,0.0);
   Check(s1.total==s2.total,"identical input yields an identical total");
   Check(s1.breakdown==s2.breakdown,"and an identical breakdown");
   Check(s1.topFactors==s2.topFactors,"and identical top factors");

   //-----------------------------------------------------------------
   Print("");
   Print("================================================================");
   PrintFormat("  RESULT: %d passed, %d failed",g_pass,g_fail);
   if(g_fail==0)
      Print("  CScoring matches the documented scale exactly.");
   else
      Print("  CScoring DIVERGED from the scale. Ranking is untrustworthy.");
   Print("================================================================");
  }
//+------------------------------------------------------------------+
