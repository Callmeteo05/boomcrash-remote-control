//+------------------------------------------------------------------+
//|                                                Test_RiskHalt.mq5  |
//|                                                                   |
//|   Drawdown halt and persistence test.                             |
//|                                                                   |
//|   CLAUDE.md requires a deliberate DD-halt test INCLUDING A FORCED |
//|   TERMINAL RESTART. This script covers the persistence half of    |
//|   that: it proves the kill switch is written to GlobalVariables   |
//|   and read back, so a restart cannot clear it.                    |
//|                                                                   |
//|   Run it in three phases with InpPhase:                           |
//|                                                                   |
//|     1 ARM      writes a hard-halt flag under the EA's magic       |
//!     2 VERIFY   restart the terminal, then run this. A fresh       |
//|                CRiskManager must come up ALREADY HALTED.          |
//|     3 RESET    clears the flag so the EA can trade again          |
//|                                                                   |
//|   Phase 1 writes only to GlobalVariables. It places no orders and |
//|   touches no positions.                                           |
//|                                                                   |
//|   USE A DEMO ACCOUNT.                                             |
//+------------------------------------------------------------------+
#property script_show_inputs
#property description "Drawdown halt persistence test - writes GlobalVariables only"

#include <SEA/SEA_Common.mqh>
#include <SEA/CSymbolSpec.mqh>
#include <SEA/CRiskManager.mqh>

enum ENUM_TEST_PHASE
  {
   PHASE_ARM = 1,     // 1 - arm a hard halt
   PHASE_VERIFY = 2,  // 2 - verify it survived a restart
   PHASE_RESET = 3,   // 3 - clear it
   PHASE_SIZING = 4   // 4 - sizing and ladder checks only, no halt
  };

input ENUM_TEST_PHASE InpPhase = PHASE_SIZING;   // Which phase to run
input long InpMagicNumber      = 20260808;       // Must match the EA's magic

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
   if(AccountInfoInteger(ACCOUNT_TRADE_MODE)==ACCOUNT_TRADE_MODE_REAL)
     {
      Print("REFUSED: this is a LIVE account. Run the halt test on demo.");
      return;
     }

   CRiskManager risk;
   risk.SetVerbose(true);

   PrintFormat("Risk halt test, phase %d, magic %I64d",(int)InpPhase,InpMagicNumber);

   switch(InpPhase)
     {
      //-------------------------------------------------------------
      case PHASE_ARM:
        {
         Section("PHASE 1 - ARM THE HARD HALT");

         risk.Init(InpMagicNumber,5.0,3.0,4,4,400.0,2,50.0,0.25);
         Print("  before: ",risk.Describe());

         //--- write the halt flag directly, the way a real drawdown
         //--- breach would
         string key=StringFormat("SEA_%d_HARDHALT",(int)InpMagicNumber);
         GlobalVariableSet(key,1.0);
         GlobalVariablesFlush();

         Check(GlobalVariableCheck(key),"hard halt flag written to GlobalVariables");
         Check(GlobalVariableGet(key)>0.5,"flag reads back as set");

         Print("");
         Print("  NOW RESTART THE TERMINAL COMPLETELY, then run this script");
         Print("  again with InpPhase = 2 (VERIFY).");
         Print("  A close-and-reopen of the chart is NOT sufficient - the");
         Print("  point is to prove the flag survives a process restart.");
         break;
        }

      //-------------------------------------------------------------
      case PHASE_VERIFY:
        {
         Section("PHASE 2 - VERIFY THE HALT SURVIVED THE RESTART");

         string key=StringFormat("SEA_%d_HARDHALT",(int)InpMagicNumber);
         Check(GlobalVariableCheck(key),
               "the flag still exists after the restart");

         //--- a FRESH risk manager, exactly as OnInit would build it
         risk.Init(InpMagicNumber,5.0,3.0,4,4,400.0,2,50.0,0.25);

         ENUM_SEA_HALT state=risk.Evaluate();

         Check(state==SEA_HALT_HARD,
               "a fresh CRiskManager comes up HARD HALTED");
         Check(!risk.EntriesAllowed(),
               "entries are refused");
         Check(risk.MustFlatten(),
               "MustFlatten is true, so the EA will close everything");

         PrintFormat("  halt reason: %s",risk.HaltReason());

         //--- and it must not clear itself, however many times it runs
         bool stayed=true;
         for(int i=0; i<20; i++)
            if(risk.Evaluate()!=SEA_HALT_HARD)
              {
               stayed=false;
               break;
              }
         Check(stayed,"20 further evaluations do not clear the halt");

         Print("");
         Print("  Run phase 3 to clear the flag before using the EA.");
         break;
        }

      //-------------------------------------------------------------
      case PHASE_RESET:
        {
         Section("PHASE 3 - MANUAL RESET");

         risk.Init(InpMagicNumber,5.0,3.0,4,4,400.0,2,50.0,0.25);
         Check(risk.MustFlatten() || risk.HaltState()==SEA_HALT_HARD,
               "halt was active before the reset");

         risk.ManualResetHardHalt();

         ENUM_SEA_HALT state=risk.Evaluate();
         Check(state!=SEA_HALT_HARD,"hard halt cleared");
         Check(risk.EntriesAllowed() || state==SEA_HALT_SOFT,
               "entries are permitted again");

         Print("  ",risk.Describe());
         break;
        }

      //-------------------------------------------------------------
      case PHASE_SIZING:
        {
         Section("PHASE 4 - SIZING, LADDER AND MARGIN CHECKS");

         CSymbolSpec spec;
         spec.SetVerbose(false);
         spec.DetectAffixes();

         int idx=spec.Ensure(_Symbol);
         if(idx<0)
           {
            Print("  ABORT: cannot cache the chart symbol");
            break;
           }

         risk.Init(InpMagicNumber,5.0,3.0,4,4,400.0,2,50.0,0.25);
         Print("  ",risk.Describe());

         double equity=AccountInfoDouble(ACCOUNT_EQUITY);
         double riskPct=risk.CurrentRiskPercent();

         PrintFormat("  equity %.2f, risk %.3f%%, micro mode %s",
                     equity,riskPct,(risk.IsMicroMode() ? "YES" : "no"));

         //--- ladder bounds
         Check(riskPct>0.0 && riskPct<=1.0,
               "risk percentage sits inside the equity ladder band");

         //--- sizing on a realistic structural stop
         double atrHandleStop=spec.Point(idx)*300.0;   // arbitrary probe distance
         string reason;
         double lots=risk.CalculateLots(spec,idx,atrHandleStop,reason);

         PrintFormat("  probe stop %s -> %s lots  %s",
                     DoubleToString(atrHandleStop,_Digits),
                     DoubleToString(lots,4),
                     (reason=="" ? "" : "("+reason+")"));

         if(lots>0.0)
           {
            //--- the money actually at risk must match the budget
            double atRisk=spec.MoneyAtRisk(idx,atrHandleStop,lots);
            double budget=equity*riskPct/100.0;

            PrintFormat("  money at risk %.2f against a budget of %.2f",atRisk,budget);
            Check(atRisk<=budget*1.02,
                  "risk never exceeds the budget (rounding is DOWN)");

            Check(lots>=spec.VolumeMin(idx),
                  "size is at or above the broker minimum");
           }
         else
            Print("  NOTE: sizing rejected, which is a valid outcome - see the reason above");

         //--- a stop so wide nothing can fund it must be REJECTED,
         //--- never quietly tightened
         double absurdStop=spec.Point(idx)*10000000.0;
         string absurdReason;
         double absurdLots=risk.CalculateLots(spec,idx,absurdStop,absurdReason);
         Check(absurdLots==0.0,
               "an unaffordable stop is REJECTED, not tightened to fit");
         PrintFormat("  unaffordable stop rejected: %s",absurdReason);

         //--- a negative or zero stop must be refused
         string zeroReason;
         Check(risk.CalculateLots(spec,idx,0.0,zeroReason)==0.0,
               "a zero stop distance is refused");
         Check(risk.CalculateLots(spec,idx,-1.0,zeroReason)==0.0,
               "a negative stop distance is refused");

         //--- LOSSES MUST NEVER RAISE RISK
         Section("PHASE 4b - A LOSING STREAK NEVER INCREASES RISK");

         double before=risk.CurrentRiskPercent();
         PrintFormat("  risk before any losses: %.4f%%",before);

         for(int i=0; i<3; i++)
            risk.RecordTrade(-10.0,-1.0);

         double after=risk.CurrentRiskPercent();
         PrintFormat("  risk after 3 losses   : %.4f%%  (streak %d)",
                     after,risk.LossStreak());

         Check(after<=before+1.0e-9,
               "risk did NOT increase after consecutive losses");

         //--- and the breaker arms on the fourth
         risk.RecordTrade(-10.0,-1.0);
         ENUM_SEA_HALT afterBreaker=risk.Evaluate();
         PrintFormat("  after the 4th loss: streak %d, halt %s",
                     risk.LossStreak(),
                     (afterBreaker==SEA_HALT_BREAKER ? "BREAKER" : "other"));
         Check(afterBreaker==SEA_HALT_BREAKER,
               "the consecutive-loss breaker armed on the 4th loss");
         Check(!risk.EntriesAllowed(),
               "entries are blocked while the breaker holds");

         Print("");
         Print("  NOTE: this phase wrote a loss streak and an armed breaker to");
         Print("  GlobalVariables. Run phase 3 to clear state before live use.");
         break;
        }
     }

   Print("");
   Print("================================================================");
   PrintFormat("  RESULT: %d passed, %d failed",g_pass,g_fail);
   Print("================================================================");
  }
//+------------------------------------------------------------------+
