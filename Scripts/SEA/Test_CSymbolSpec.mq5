//+------------------------------------------------------------------+
//|                                            Test_CSymbolSpec.mq5   |
//|                                                                   |
//|   Test harness for module 1, CSymbolSpec.                         |
//|                                                                   |
//|   Attach to any chart and run. It exercises the cache against the |
//|   live broker specification of the chart symbol plus a sample of  |
//|   Market Watch symbols, and asserts the invariants the rest of    |
//|   the EA is entitled to rely on.                                  |
//|                                                                   |
//|   This script places no orders and modifies nothing.              |
//+------------------------------------------------------------------+
#property script_show_inputs
#property description "CSymbolSpec unit tests - read only, places no orders"

#include <SEA/CSymbolSpec.mqh>

//--- inputs
input int    InpSampleSymbols   = 8;      // Market Watch symbols to dump (0..50)
input bool   InpDumpFullSpec    = true;   // print the full spec for the chart symbol
input bool   InpVerboseModule   = true;   // let CSymbolSpec print its own diagnostics
input string InpForcePrefix     = "";     // override detected prefix (empty = auto)
input string InpForceSuffix     = "";     // override detected suffix (empty = auto)
input bool   InpUseForcedAffix  = false;  // true to apply the two fields above

//--- assertion counters
int g_pass = 0;
int g_fail = 0;
int g_warn = 0;

//+------------------------------------------------------------------+
//| Assertion helpers                                                 |
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

void CheckEqualDouble(const double actual,const double expected,const double tolerance,const string label)
  {
   bool ok=(MathAbs(actual-expected)<=tolerance);
   if(ok)
     {
      g_pass++;
      PrintFormat("  PASS  %s  (got %.8f)",label,actual);
     }
   else
     {
      g_fail++;
      PrintFormat("  FAIL  %s  (got %.8f, expected %.8f +/- %.8f)",label,actual,expected,tolerance);
     }
  }

void Warn(const bool condition,const string label)
  {
   if(condition)
     {
      g_pass++;
      PrintFormat("  PASS  %s",label);
     }
   else
     {
      g_warn++;
      PrintFormat("  WARN  %s",label);
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
//| Script entry point                                                |
//+------------------------------------------------------------------+
void OnStart()
  {
   CSymbolSpec spec;
   spec.SetVerbose(InpVerboseModule);

   Section("1. AFFIX RESOLUTION");

   if(InpUseForcedAffix)
     {
      spec.SetAffixes(InpForcePrefix,InpForceSuffix);
      PrintFormat("  affixes forced by input: prefix='%s' suffix='%s'",spec.Prefix(),spec.Suffix());
     }
   else
     {
      bool scanned=spec.DetectAffixes();
      Check(scanned,"DetectAffixes completed");
      PrintFormat("  detected prefix='%s'  suffix='%s'",spec.Prefix(),spec.Suffix());
      PrintFormat("  universe size: %d symbols",SymbolsTotal(false));
     }

   PrintFormat("  chart symbol '%s' -> core '%s'",_Symbol,spec.CoreOf(_Symbol));
   Check(StringLen(spec.CoreOf(_Symbol))>0,"CoreOf returns a non-empty core");
   Check(StringLen(spec.CoreOf(_Symbol))<=StringLen(_Symbol),"core is never longer than the raw name");
   Check(spec.CoreOf(spec.CoreOf(_Symbol))==spec.CoreOf(_Symbol),"CoreOf is idempotent");

   //-----------------------------------------------------------------
   Section("2. CACHE THE CHART SYMBOL");

   int idx=spec.Ensure(_Symbol);
   Check(idx>=0,"Ensure(_Symbol) returned a valid index");
   if(idx<0)
     {
      PrintFormat("  aborting: %s",spec.LastError());
      Summary();
      return;
     }

   Check(spec.Ensure(_Symbol)==idx,"Ensure is idempotent, no duplicate entry");
   Check(spec.Total()==1,"cache holds exactly one record");
   Check(spec.IndexOf(_Symbol)==idx,"IndexOf resolves the cached symbol");
   Check(spec.IndexOf(_Symbol+"__no_such_symbol__")==-1,"IndexOf returns -1 for an unknown symbol");

   if(!spec.IsValid(idx))
      PrintFormat("  NOTE: spec marked invalid: %s",spec.InvalidReason(idx));
   Check(spec.IsValid(idx),"chart symbol spec is valid for trading arithmetic");

   if(InpDumpFullSpec)
     {
      Print("");
      Print(spec.Describe(idx));
     }

   //-----------------------------------------------------------------
   Section("3. QUOTATION AND VALUE ARITHMETIC");

   Check(spec.Point(idx)>0.0,"point > 0");
   Check(spec.Digits(idx)>=0,"digits >= 0");
   Check(spec.TickSize(idx)>0.0,"tick size > 0");
   Check(spec.ValuePerPriceUnit(idx)>0.0,"value per price unit > 0");
   Check(spec.ValuePerPoint(idx)>0.0,"value per point > 0");

   CheckEqualDouble(spec.ValuePerPoint(idx),
                    spec.ValuePerPriceUnit(idx)*spec.Point(idx),
                    1.0e-10,
                    "valuePerPoint == valuePerPriceUnit * point");

   CheckEqualDouble(spec.PointValueAtMinVolume(idx),
                    spec.ValuePerPriceUnit(idx)*spec.VolumeMin(idx),
                    1.0e-10,
                    "PointValueAtMinVolume == valuePerPriceUnit * volumeMin");

   CheckEqualDouble(spec.MoneyPerPriceUnit(idx,spec.VolumeMin(idx)),
                    spec.PointValueAtMinVolume(idx),
                    1.0e-10,
                    "MoneyPerPriceUnit at volumeMin agrees with PointValueAtMinVolume");

   //--- cross-check the value arithmetic against the terminal itself
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   if(ask>0.0)
     {
      double moveUnits = spec.TickSize(idx)*100.0;     // a small, safely quotable move
      double lots      = spec.VolumeMin(idx);
      double expected  = spec.MoneyAtRisk(idx,moveUnits,lots);
      double terminal  = 0.0;

      if(OrderCalcProfit(ORDER_TYPE_BUY,_Symbol,lots,ask,ask-moveUnits,terminal))
        {
         double loss=MathAbs(terminal);
         PrintFormat("  cross-check: CSymbolSpec %.5f vs OrderCalcProfit %.5f (%.1f%% apart)",
                     expected,loss,(loss>0.0 ? 100.0*MathAbs(expected-loss)/loss : 0.0));
         Warn(loss>0.0 && MathAbs(expected-loss)<=loss*0.05,
              "MoneyAtRisk within 5% of OrderCalcProfit (asymmetric tick values can widen this)");
        }
      else
         PrintFormat("  NOTE: OrderCalcProfit unavailable, error %d - cross-check skipped",GetLastError());
     }
   else
      Print("  NOTE: no ask price yet, value cross-check skipped");

   //-----------------------------------------------------------------
   Section("4. LOT NORMALIZATION - MUST ROUND DOWN, NEVER UP");

   double vmin =spec.VolumeMin(idx);
   double vmax =spec.VolumeMax(idx);
   double vstep=spec.VolumeStep(idx);
   PrintFormat("  min=%.8f  step=%.8f  max=%.8f",vmin,vstep,vmax);

   CheckEqualDouble(spec.NormalizeVolume(idx,vmin),vmin,vstep*1.0e-6,
                    "volumeMin normalizes to itself");

   CheckEqualDouble(spec.NormalizeVolume(idx,vmin+vstep),vmin+vstep,vstep*1.0e-6,
                    "min+step normalizes to itself");

   CheckEqualDouble(spec.NormalizeVolume(idx,vmin+vstep*1.5),vmin+vstep,vstep*1.0e-6,
                    "min+1.5*step rounds DOWN to min+step");

   CheckEqualDouble(spec.NormalizeVolume(idx,vmin+vstep*0.9),vmin,vstep*1.0e-6,
                    "min+0.9*step rounds DOWN to min");

   Check(spec.NormalizeVolume(idx,vmin*0.5)==0.0,
         "below minimum is REJECTED with 0.0, never rounded up");

   Check(spec.NormalizeVolume(idx,0.0)==0.0,"zero lots rejected");
   Check(spec.NormalizeVolume(idx,-1.0)==0.0,"negative lots rejected");

   Check(spec.NormalizeVolume(idx,vmax*10.0)<=vmax+vstep*1.0e-6,
         "oversized request clamped to volumeMax");
   Check(spec.NormalizeVolume(idx,vmax*10.0)>=vmin,
         "clamped result still tradeable");

   Check(spec.NormalizeVolume(-1,vmin)==0.0,"bad index rejects rather than guessing");

   //--- sweep the round-down property across the tradeable band
   int    sweepFails=0;
   int    sweepPoints=0;
   double sweepTop=(vmax<vmin+vstep*200.0 ? vmax : vmin+vstep*200.0);
   for(double v=vmin; v<=sweepTop; v+=vstep*0.37)
     {
      double n=spec.NormalizeVolume(idx,v);
      sweepPoints++;
      if(n>0.0 && n>v+vstep*1.0e-6)
         sweepFails++;
     }
   PrintFormat("  swept %d request sizes",sweepPoints);
   Check(sweepFails==0,"no request across the sweep was ever rounded UP");

   Check(spec.IsVolumeValid(idx,vmin),"IsVolumeValid true for volumeMin");
   Check(!spec.IsVolumeValid(idx,vmin*0.5),"IsVolumeValid false below minimum");
   Check(!spec.IsVolumeValid(idx,vmin+vstep*0.5),"IsVolumeValid false off the step grid");

   //-----------------------------------------------------------------
   Section("5. PRICE NORMALIZATION");

   if(ask>0.0)
     {
      double np=spec.NormalizePrice(idx,ask+spec.TickSize(idx)*0.4);
      PrintFormat("  ask=%s  normalized=%s",
                  DoubleToString(ask,spec.Digits(idx)),
                  DoubleToString(np,spec.Digits(idx)));
      double onGrid=MathAbs(np/spec.TickSize(idx)-MathRound(np/spec.TickSize(idx)));
      Check(onGrid<1.0e-6,"normalized price sits on the tick grid");
      CheckEqualDouble(spec.NormalizePrice(idx,ask),ask,spec.TickSize(idx)*0.5,
                       "an already-valid price survives normalization");
     }
   else
      Print("  NOTE: no ask price yet, price normalization checks skipped");

   //-----------------------------------------------------------------
   Section("6. FILLING MODE - BITMASK, TESTED WITH &");

   long mask=spec.FillingMask(idx);
   PrintFormat("  raw mask          : %s",spec.FillingMaskToString(mask));
   PrintFormat("  resolved market   : %s",spec.FillingToString(spec.FillingMarket(idx)));
   PrintFormat("  resolved pending  : %s",spec.FillingToString(spec.FillingPending(idx)));

   Check(mask!=0,"broker publishes a non-empty filling mask");

   ENUM_ORDER_TYPE_FILLING resolved=spec.FillingMarket(idx);
   Check(resolved==ORDER_FILLING_RETURN || spec.IsFillingSupported(idx,resolved),
         "resolved market filling is present in the mask");

   //--- an unsupported flag must not be reported as supported
   bool fokInMask=((mask & SYMBOL_FILLING_FOK)!=0);
   bool iocInMask=((mask & SYMBOL_FILLING_IOC)!=0);
   Check(spec.IsFillingSupported(idx,ORDER_FILLING_FOK)==fokInMask,"FOK support matches the mask bit");
   Check(spec.IsFillingSupported(idx,ORDER_FILLING_IOC)==iocInMask,"IOC support matches the mask bit");

   ENUM_ORDER_TYPE_FILLING fallbacks[];
   int fbCount=spec.SupportedFillings(idx,fallbacks);
   string fbList="";
   for(int i=0; i<fbCount; i++)
      fbList+=spec.FillingToString(fallbacks[i])+" ";
   PrintFormat("  fallback order    : %s",fbList);
   Check(fbCount>0,"at least one filling mode offered for CTradeExec");
   if(fbCount>0)
      Check(fallbacks[0]==spec.FillingMarket(idx),"fallback list leads with the resolved mode");

   //-----------------------------------------------------------------
   Section("7. EXPIRATION MODE - PENDING ORDERS EXPIRE BY STYLE");

   PrintFormat("  expiration mask   : %s",spec.ExpirationMaskToString(spec.ExpirationMask(idx)));
   bool specifiedOk=spec.IsExpirationSupported(idx,ORDER_TIME_SPECIFIED);
   Warn(specifiedOk,"ORDER_TIME_SPECIFIED supported (needed for bar-count pending expiry)");
   if(!specifiedOk)
      Print("  NOTE: this symbol cannot carry a timed expiry - CTradeExec must cancel manually");

   //-----------------------------------------------------------------
   Section("8. PERMISSIONS AND CALCULATION MODE");

   SSymbolSpec chart;
   Check(spec.Get(idx,chart),"Get(idx) copies the cached record out");
   PrintFormat("  trade mode        : %s",spec.TradeModeToString(chart.tradeMode));
   PrintFormat("  execution mode    : %s",spec.ExecModeToString(chart.execMode));
   PrintFormat("  long allowed      : %s",(spec.LongAllowed(idx) ? "yes" : "no"));
   PrintFormat("  short allowed     : %s",(spec.ShortAllowed(idx) ? "yes" : "no"));
   PrintFormat("  calc mode         : %s",spec.CalcModeToString(spec.CalcMode(idx)));
   PrintFormat("  derived family    : %s",spec.CalcFamilyToString(spec.CalcFamily(idx)));

   Check(spec.OpenAllowed(idx)==(spec.LongAllowed(idx) || spec.ShortAllowed(idx)),
         "openAllowed agrees with the direction flags");
   Check(spec.CalcFamily(idx)!=SEA_CALC_FAMILY_UNKNOWN,
         "calculation mode maps to a known family");

   //-----------------------------------------------------------------
   Section("9. BOUNDS SAFETY - BAD INDICES NEVER CRASH OR GUESS");

   Check(spec.Name(-1)=="","Name(-1) returns empty");
   Check(spec.Name(9999)=="","Name(out of range) returns empty");
   Check(spec.Point(-1)==0.0,"Point(-1) returns 0");
   Check(spec.VolumeMin(9999)==0.0,"VolumeMin(out of range) returns 0");
   Check(!spec.IsValid(-1),"IsValid(-1) is false");
   Check(!spec.LongAllowed(-1),"LongAllowed(-1) is false");
   Check(!spec.ShortAllowed(-1),"ShortAllowed(-1) is false");
   Check(spec.PointValueAtMinVolume(-1)==0.0,"PointValueAtMinVolume(-1) returns 0");
   Check(spec.Describe(-1)=="<index out of range>","Describe(-1) is explicit");

   SSymbolSpec dummy;
   Check(!spec.Get(-1,dummy),"Get(-1) fails cleanly");
   Check(!spec.GetBySymbol("__nothing__",dummy),"GetBySymbol on an unknown symbol fails cleanly");

   //-----------------------------------------------------------------
   Section("10. REFRESH AND DETERMINISM");

   string before=spec.DescribeShort(idx);
   Check(spec.Refresh(idx),"Refresh succeeds on a cached symbol");
   string after=spec.DescribeShort(idx);
   Check(before==after,"static fields are byte-identical across a refresh");
   Check(!spec.Refresh(-1),"Refresh(-1) fails cleanly");

   double v1=spec.NormalizeVolume(idx,vmin*3.7);
   double v2=spec.NormalizeVolume(idx,vmin*3.7);
   Check(v1==v2,"NormalizeVolume is deterministic");

   //-----------------------------------------------------------------
   Section("11. MARKET WATCH SAMPLE");

   int watch=SymbolsTotal(true);
   int want=(InpSampleSymbols<0 ? 0 : (InpSampleSymbols>50 ? 50 : InpSampleSymbols));
   int taken=0, valid=0, invalid=0;

   for(int i=0; i<watch && taken<want; i++)
     {
      string name=SymbolName(i,true);
      if(name==_Symbol)
         continue;
      int k=spec.Ensure(name);
      if(k<0)
        {
         PrintFormat("  %-16s SKIPPED: %s",name,spec.LastError());
         continue;
        }
      taken++;
      if(spec.IsValid(k))
        {
         valid++;
         PrintFormat("  %-16s core=%-12s %-10s min=%-8s pv@min=%.5f fill=%s",
                     spec.Name(k),spec.Core(k),
                     spec.CalcFamilyToString(spec.CalcFamily(k)),
                     DoubleToString(spec.VolumeMin(k),3),
                     spec.PointValueAtMinVolume(k),
                     spec.FillingToString(spec.FillingMarket(k)));
        }
      else
        {
         invalid++;
         PrintFormat("  %-16s INVALID: %s",spec.Name(k),spec.InvalidReason(k));
        }
     }

   PrintFormat("  sampled %d symbols: %d valid, %d invalid",taken,valid,invalid);
   Check(spec.Total()==taken+1,"cache size matches the number of symbols added");

   int refreshed=spec.RefreshAll();
   PrintFormat("  RefreshAll refreshed %d of %d",refreshed,spec.Total());

   spec.Clear();
   Check(spec.Total()==0,"Clear empties the cache");
   Check(spec.IndexOf(_Symbol)==-1,"lookup fails after Clear");

   Summary();
  }

//+------------------------------------------------------------------+
//| Result summary                                                    |
//+------------------------------------------------------------------+
void Summary()
  {
   Print("");
   Print("================================================================");
   PrintFormat("  RESULT: %d passed, %d failed, %d warnings",g_pass,g_fail,g_warn);
   if(g_fail==0)
      Print("  CSymbolSpec invariants hold on this broker feed.");
   else
      Print("  CSymbolSpec FAILED - do not proceed to module 2.");
   Print("================================================================");
  }
//+------------------------------------------------------------------+
