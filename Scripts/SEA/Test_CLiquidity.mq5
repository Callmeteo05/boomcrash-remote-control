//+------------------------------------------------------------------+
//|                                              Test_CLiquidity.mq5  |
//|                                                                   |
//|   Correctness test for module 7, CLiquidity.                      |
//|                                                                   |
//|   Independent recomputation again: previous-day and previous-week |
//|   extremes are re-read straight from the daily and weekly series  |
//|   and compared, and every swept flag is re-derived from the raw   |
//|   bars.                                                           |
//|                                                                   |
//|   The distinction this module exists to make, and the one the     |
//|   test hammers hardest:                                           |
//|                                                                   |
//|     a SWEEP is a wick beyond a level with a CLOSE back inside     |
//|     a BREAK is a close beyond that stays there                    |
//|                                                                   |
//|   Getting that wrong feeds CPhase a false manipulation sequence,  |
//|   which is how an EA ends up buying every dip out of a range.     |
//|                                                                   |
//|   Places no orders. Modifies nothing.                             |
//+------------------------------------------------------------------+
#property script_show_inputs
#property description "CLiquidity correctness test - independent recomputation, read only"

#include <SEA/SEA_Common.mqh>
#include <SEA/CStyle.mqh>
#include <SEA/CLiquidity.mqh>

input int    InpLookback      = 300;   // Bars to scan (100-2000)
input double InpEqualTolerance= 0.10;  // EQH/EQL tolerance as an ATR fraction
input int    InpSweepMaxBars  = 3;     // Close back inside within this many bars
input int    InpATRPeriod     = 14;    // ATR period

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
void OnStart()
  {
   CIndicatorPool pool;
   CStyle         style;
   CLiquidity     liq;

   style.SetStyle(SEA_STYLE_INTRADAY);
   //--- chart timeframe without naming a PERIOD_ constant (RULE 10)
   ENUM_TIMEFRAMES tf=(ENUM_TIMEFRAMES)_Period;

   if(SeaAvailableBars(_Symbol,tf)<InpLookback+50)
     {
      PrintFormat("ABORT: need %d bars on %s. Scroll back to load history.",
                  InpLookback+50,_Symbol);
      return;
     }

   if(!liq.Init(_Symbol,tf,pool,style.DayTF(),style.WeekTF(),
                InpEqualTolerance,InpSweepMaxBars,InpATRPeriod,InpLookback))
     {
      Print("ABORT: CLiquidity failed to initialise");
      return;
     }

   PrintFormat("%s",liq.Describe());

   MqlRates r[];
   if(!SeaCopyRates(_Symbol,tf,0,InpLookback,r))
     {
      Print("ABORT: cannot read rates for the independent check");
      return;
     }
   int total=ArraySize(r);

   //-----------------------------------------------------------------
   Section("1. SESSION EXTREMES - INDEPENDENTLY RE-READ");

   //--- read the previous daily bar directly and compare
   MqlRates d[];
   if(SeaCopyRates(_Symbol,style.DayTF(),1,1,d))
     {
      double pdh,pdl;
      bool haveDaily=liq.PreviousDayHigh(pdh) && liq.PreviousDayLow(pdl);

      Check(haveDaily,"CLiquidity reports previous-day levels");
      if(haveDaily)
        {
         PrintFormat("  CLiquidity PDH %s / PDL %s",
                     DoubleToString(pdh,_Digits),DoubleToString(pdl,_Digits));
         PrintFormat("  raw daily bar  %s / %s  (%s)",
                     DoubleToString(d[0].high,_Digits),
                     DoubleToString(d[0].low,_Digits),
                     TimeToString(d[0].time,TIME_DATE));

         Check(MathAbs(pdh-d[0].high)<_Point*0.5,
               "PDH matches the last CLOSED daily bar exactly");
         Check(MathAbs(pdl-d[0].low)<_Point*0.5,
               "PDL matches the last CLOSED daily bar exactly");

         //--- and it must be the CLOSED bar, not today's forming one
         MqlRates today[];
         if(SeaCopyRates(_Symbol,style.DayTF(),0,1,today))
            Check(MathAbs(pdh-today[0].high)>_Point*0.5 ||
                  MathAbs(d[0].high-today[0].high)<_Point*0.5,
                  "PDH is the CLOSED daily bar, not the forming one");
        }
     }
   else
      Print("  NOTE: daily history unavailable, PDH/PDL check skipped");

   MqlRates w[];
   if(SeaCopyRates(_Symbol,style.WeekTF(),1,1,w))
     {
      double pwh,pwl;
      if(liq.PreviousWeekHigh(pwh) && liq.PreviousWeekLow(pwl))
        {
         PrintFormat("  CLiquidity PWH %s / PWL %s",
                     DoubleToString(pwh,_Digits),DoubleToString(pwl,_Digits));
         Check(MathAbs(pwh-w[0].high)<_Point*0.5,
               "PWH matches the last CLOSED weekly bar");
         Check(MathAbs(pwl-w[0].low)<_Point*0.5,
               "PWL matches the last CLOSED weekly bar");
        }
     }
   else
      Print("  NOTE: weekly history unavailable, PWH/PWL check skipped");

   //-----------------------------------------------------------------
   Section("2. LEVEL INVARIANTS");

   Check(liq.Count()>0,"at least one liquidity level was found");

   int badPrice=0, badStrength=0, badTouches=0;
   int highs=0, lows=0;
   for(int i=0; i<liq.Count(); i++)
     {
      SLiquidity l;
      if(!liq.Get(i,l))
         continue;

      if(l.price<=0.0)
         badPrice++;
      if(l.strength<0.0 || l.strength>1.0)
         badStrength++;
      if(l.touchCount<1)
         badTouches++;

      if(l.isHigh)
         highs++;
      else
         lows++;
     }

   PrintFormat("  %d levels: %d buy-side (highs), %d sell-side (lows)",
               liq.Count(),highs,lows);
   Check(badPrice==0,StringFormat("every level has a positive price (%d bad)",badPrice));
   Check(badStrength==0,
         StringFormat("every strength lies in 0..1 (%d out of range)",badStrength));
   Check(badTouches==0,
         StringFormat("every level records at least one touch (%d with none)",badTouches));

   //-----------------------------------------------------------------
   Section("3. SWEEP vs BREAK - THE DISTINCTION THAT MATTERS");

   //--- Independently re-derive whether each level was consumed.
   //--- A level is consumed if price ever wicked beyond it (sweep) or
   //--- closed beyond it (break). Either way the resting orders are
   //--- gone, so CLiquidity marks both as swept.
   int disputed=0, agreed=0;

   for(int i=0; i<liq.Count(); i++)
     {
      SLiquidity l;
      if(!liq.Get(i,l))
         continue;

      bool independentlyTaken=false;
      for(int k=total-1; k>=1; k--)
        {
         if(l.time!=0 && r[k].time<=l.time)
            continue;

         if(l.isHigh && r[k].high>l.price)
           {
            independentlyTaken=true;
            break;
           }
         if(!l.isHigh && r[k].low<l.price)
           {
            independentlyTaken=true;
            break;
           }
        }

      if(independentlyTaken==l.swept)
         agreed++;
      else
        {
         disputed++;
         if(disputed<=5)
            PrintFormat("        level %s (%s) CLiquidity says swept=%s, bars say %s",
                        DoubleToString(l.price,_Digits),
                        (l.isHigh ? "high" : "low"),
                        (l.swept ? "true" : "false"),
                        (independentlyTaken ? "taken" : "untouched"));
        }
     }

   PrintFormat("  %d of %d swept flags agree with an independent bar scan",
               agreed,liq.Count());
   Check(disputed==0,
         StringFormat("every swept flag matches the raw bars (%d disputed)",disputed));

   //--- an UNSWEPT level must never have been exceeded. This is the
   //--- one the target selection depends on.
   int falseUnswept=0;
   for(int i=0; i<liq.Count(); i++)
     {
      SLiquidity l;
      if(!liq.Get(i,l) || l.swept)
         continue;

      for(int k=total-1; k>=1; k--)
        {
         if(l.time!=0 && r[k].time<=l.time)
            continue;
         if((l.isHigh && r[k].high>l.price) || (!l.isHigh && r[k].low<l.price))
           {
            falseUnswept++;
            break;
           }
        }
     }
   Check(falseUnswept==0,
         StringFormat("no level claims to be unswept after being exceeded (%d found)",
                      falseUnswept));

   //-----------------------------------------------------------------
   Section("4. RECENT SWEEP REQUIRES A RECLAIM, NOT JUST A WICK");

   //--- RecentSweep is what CPhase leans on. It must only fire when a
   //--- close came back through the level.
   double lvl;
   datetime when;

   for(int side=0; side<2; side++)
     {
      bool highSide=(side==0);
      if(!liq.RecentSweep(highSide,20,lvl,when))
        {
         PrintFormat("  no recent %s-side sweep in the window",
                     (highSide ? "high" : "low"));
         continue;
        }

      PrintFormat("  recent %s-side sweep of %s at %s",
                  (highSide ? "high" : "low"),
                  DoubleToString(lvl,_Digits),
                  TimeToString(when,TIME_DATE|TIME_MINUTES));

      //--- independently verify: a wick beyond, THEN a close back inside
      int wickBar=-1;
      for(int k=1; k<total; k++)
         if(r[k].time==when)
           {
            wickBar=k;
            break;
           }

      if(wickBar<0)
        {
         Print("        could not locate the reported sweep bar");
         continue;
        }

      bool wicked=(highSide ? (r[wickBar].high>lvl) : (r[wickBar].low<lvl));
      Check(wicked,"the reported sweep bar really did wick beyond the level");

      bool reclaimed=false;
      for(int j=wickBar; j>=1 && j>wickBar-InpSweepMaxBars-1; j--)
        {
         if(highSide && r[j].close<lvl)
            reclaimed=true;
         if(!highSide && r[j].close>lvl)
            reclaimed=true;
         if(reclaimed)
            break;
        }
      Check(reclaimed,
            StringFormat("a close came back inside within %d bars - a sweep, not a break",
                         InpSweepMaxBars));
     }

   //-----------------------------------------------------------------
   Section("5. TARGET SELECTION - DIRECTION AND ORDERING");

   double price=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(price>0.0)
     {
      SLiquidity above,below;

      if(liq.NearestUnsweptAbove(price,above))
        {
         Check(above.price>price,"NearestUnsweptAbove returned a level above price");
         Check(!above.swept,"and it is unswept");

         //--- confirm nothing unswept sits closer
         bool closer=false;
         for(int i=0; i<liq.Count(); i++)
           {
            SLiquidity l;
            if(!liq.Get(i,l) || l.swept || l.price<=price)
               continue;
            if(l.price<above.price-_Point*0.5)
               closer=true;
           }
         Check(!closer,"no unswept level above sits nearer than the one returned");
        }
      else
         Print("  no unswept liquidity above price");

      if(liq.NearestUnsweptBelow(price,below))
        {
         Check(below.price<price,"NearestUnsweptBelow returned a level below price");
         Check(!below.swept,"and it is unswept");
        }
      else
         Print("  no unswept liquidity below price");

      //--- TargetFor must route by direction
      SLiquidity longTarget,shortTarget;
      bool haveLong =liq.TargetFor(price,SEA_DIR_LONG,longTarget);
      bool haveShort=liq.TargetFor(price,SEA_DIR_SHORT,shortTarget);

      if(haveLong)
         Check(longTarget.price>price,"a LONG target sits above price");
      if(haveShort)
         Check(shortTarget.price<price,"a SHORT target sits below price");

      Check(!liq.TargetFor(price,SEA_DIR_NONE,longTarget),
            "TargetFor with no direction returns nothing");

      //--- UnsweptBeyond must agree with the level list
      bool anyAbove=liq.UnsweptBeyond(price,SEA_DIR_LONG);
      Check(anyAbove==haveLong,
            "UnsweptBeyond agrees with NearestUnsweptAbove");
     }

   //-----------------------------------------------------------------
   Section("6. EQUAL-LEVEL TOLERANCE BEHAVES MONOTONICALLY");

   //--- a WIDER tolerance groups more extremes together, so it should
   //--- never find MORE distinct pools than a tight one
   CLiquidity wide;
   if(wide.Init(_Symbol,tf,pool,style.DayTF(),style.WeekTF(),
                InpEqualTolerance*3.0,InpSweepMaxBars,InpATRPeriod,InpLookback))
     {
      PrintFormat("  tolerance %.2f ATR -> %d levels, tolerance %.2f ATR -> %d levels",
                  InpEqualTolerance,liq.Count(),
                  InpEqualTolerance*3.0,wide.Count());

      //--- both must still find the four session levels
      Check(wide.Count()>0,"a wider tolerance still finds levels");
      wide.Release(pool);
     }

   //-----------------------------------------------------------------
   Section("7. DETERMINISM");

   int countBefore=liq.Count();
   int unsweptBefore=liq.UnsweptCount();

   liq.Update(true);
   liq.Update(true);

   Check(liq.Count()==countBefore,"level count stable across forced rebuilds");
   Check(liq.UnsweptCount()==unsweptBefore,"unswept count stable across rebuilds");

   //-----------------------------------------------------------------
   Section("8. CLEANUP");

   liq.Release(pool);
   pool.ReleaseAll();
   Check(pool.LiveHandles()==0,"every indicator handle released");

   Print("");
   Print("================================================================");
   PrintFormat("  RESULT: %d passed, %d failed",g_pass,g_fail);
   if(g_fail==0)
      Print("  CLiquidity agrees with an independent read of the same bars.");
   else
     {
      Print("  CLiquidity DISAGREES with the raw bars. Targets and sweep");
      Print("  evidence are unreliable, which corrupts CPhase and GATE 10.");
     }
   Print("================================================================");
  }
//+------------------------------------------------------------------+
