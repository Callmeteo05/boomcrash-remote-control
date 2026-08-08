//+------------------------------------------------------------------+
//|                                                  Test_CZones.mq5  |
//|                                                                   |
//|   Correctness test for module 6, CZones.                          |
//|                                                                   |
//|   CZones reads live bars, so "correctness" here means INDEPENDENT |
//|   RECOMPUTATION: this script re-derives the fair value gaps and   |
//|   order block bodies straight from the raw MqlRates array, using  |
//|   its own arithmetic, and compares the answers.                   |
//|                                                                   |
//|   Two engines that agree by accident is unlikely; two engines     |
//|   that disagree means one of them is wrong, and the raw-bar       |
//|   version is the one with nowhere to hide.                        |
//|                                                                   |
//|   Also checks the invariants the rest of the EA relies on:        |
//|     a FRESH zone has never been touched                           |
//|     upper is always above lower                                   |
//|     an INVERTED zone has flipped its type AND its bias            |
//|     NearestFresh and ZoneAtPrice only ever return FRESH zones     |
//|                                                                   |
//|   Places no orders. Modifies nothing.                             |
//+------------------------------------------------------------------+
#property script_show_inputs
#property description "CZones correctness test - independent recomputation, read only"

#include <SEA/SEA_Common.mqh>
#include <SEA/CZones.mqh>

input int    InpLookback   = 400;  // Bars to scan (100-3000)
input double InpImpulseATR = 2.0;  // Impulse threshold in ATR (0.5-10)
input int    InpZoneMaxAge = 500;  // Zone expiry in bars (20-5000)
input int    InpATRPeriod  = 14;   // ATR period

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
   CZones         zones;

   //--- the chart's own timeframe, without naming a PERIOD_ constant
   //--- (RULE 10 keeps those inside CStyle)
   ENUM_TIMEFRAMES tf=(ENUM_TIMEFRAMES)_Period;

   if(SeaAvailableBars(_Symbol,tf)<InpLookback+50)
     {
      PrintFormat("ABORT: need %d bars on %s. Scroll the chart back to load history.",
                  InpLookback+50,_Symbol);
      return;
     }

   if(!zones.Init(_Symbol,tf,pool,InpImpulseATR,InpZoneMaxAge,InpATRPeriod,InpLookback))
     {
      Print("ABORT: CZones failed to initialise");
      return;
     }

   PrintFormat("%s",zones.Describe());

   //--- the same bars CZones just read
   MqlRates r[];
   if(!SeaCopyRates(_Symbol,tf,0,InpLookback,r))
     {
      Print("ABORT: cannot read rates for the independent check");
      return;
     }
   int total=ArraySize(r);

   //-----------------------------------------------------------------
   Section("1. STRUCTURAL INVARIANTS");

   Check(zones.Count()>0,"at least one zone was found");

   int badBounds=0, badBias=0, negativeAge=0;
   for(int i=0; i<zones.Count(); i++)
     {
      SZone z;
      if(!zones.Get(i,z))
         continue;

      if(z.upper<=z.lower)
         badBounds++;
      if(z.bias==SEA_DIR_NONE)
         badBias++;
      if(z.ageBars<0)
         negativeAge++;
     }

   Check(badBounds==0,StringFormat("every zone has upper > lower (%d violations)",badBounds));
   Check(badBias==0,StringFormat("every zone carries a direction (%d without)",badBias));
   Check(negativeAge==0,StringFormat("no zone has a negative age (%d found)",negativeAge));

   //-----------------------------------------------------------------
   Section("2. THE FRESHNESS CONTRACT - ONLY FRESH IS TRADEABLE");

   //--- A FRESH zone must never have been touched. GATE 5 trusts this.
   int freshTouched=0;
   int freshCount=0;
   for(int i=0; i<zones.Count(); i++)
     {
      SZone z;
      if(!zones.Get(i,z))
         continue;
      if(z.state!=SEA_ZONE_FRESH)
         continue;
      freshCount++;
      if(z.touchCount>0)
        {
         freshTouched++;
         if(freshTouched<=3)
            PrintFormat("        FRESH zone %s has %d touches",
                        SeaZoneTypeToString(z.type),z.touchCount);
        }
     }
   PrintFormat("  %d FRESH zones of %d total",freshCount,zones.Count());
   Check(freshTouched==0,"no FRESH zone carries a recorded touch");

   //--- INDEPENDENT CHECK: replay the bars after each FRESH zone formed
   //--- and confirm price genuinely never entered it
   int falselyFresh=0;
   for(int i=0; i<zones.Count(); i++)
     {
      SZone z;
      if(!zones.Get(i,z) || z.state!=SEA_ZONE_FRESH)
         continue;

      for(int k=z.originShift-1; k>=1; k--)
        {
         if(k>=total)
            continue;
         //--- any overlap of the bar's range with the zone is an entry
         if(r[k].low<=z.upper && r[k].high>=z.lower)
           {
            falselyFresh++;
            if(falselyFresh<=3)
               PrintFormat("        zone %s [%s..%s] marked FRESH but bar at %s entered it",
                           SeaZoneTypeToString(z.type),
                           DoubleToString(z.lower,_Digits),
                           DoubleToString(z.upper,_Digits),
                           TimeToString(r[k].time,TIME_DATE|TIME_MINUTES));
            break;
           }
        }
     }
   Check(falselyFresh==0,
         StringFormat("independent bar replay agrees: no FRESH zone was entered (%d disputed)",
                      falselyFresh));

   //--- expiry must be enforced
   int overAged=0;
   for(int i=0; i<zones.Count(); i++)
     {
      SZone z;
      if(!zones.Get(i,z))
         continue;
      if(z.ageBars>InpZoneMaxAge && z.state!=SEA_ZONE_EXPIRED)
         overAged++;
     }
   Check(overAged==0,
         StringFormat("every zone older than %d bars is EXPIRED (%d stragglers)",
                      InpZoneMaxAge,overAged));

   //-----------------------------------------------------------------
   Section("3. INDEPENDENT RECOMPUTATION OF FAIR VALUE GAPS");

   //--- Re-derive FVGs straight from the bars.
   //---   bullish: Low[i] > High[i+2]
   //---   bearish: High[i] < Low[i+2]
   //--- The zone body spans the gap and is stamped on bar i+1.
   int independentBull=0, independentBear=0;
   int matchedBull=0, matchedBear=0;

   for(int i=1; i+2<total; i++)
     {
      bool bull=(r[i].low>r[i+2].high);
      bool bear=(r[i].high<r[i+2].low);
      if(!bull && !bear)
         continue;

      double expectUpper=(bull ? r[i].low  : r[i+2].low);
      double expectLower=(bull ? r[i+2].high : r[i].high);
      datetime expectTime=r[i+1].time;

      if(bull)
         independentBull++;
      else
         independentBear++;

      //--- find the corresponding zone. An FVG that was later closed
      //--- through will have been retyped to an IFVG, so accept both.
      bool found=false;
      for(int k=0; k<zones.Count(); k++)
        {
         SZone z;
         if(!zones.Get(k,z))
            continue;
         if(z.originTime!=expectTime)
            continue;

         bool isFvgFamily=(z.type==SEA_ZONE_FVG_BULL || z.type==SEA_ZONE_FVG_BEAR ||
                           z.type==SEA_ZONE_IFVG_BULL || z.type==SEA_ZONE_IFVG_BEAR);
         if(!isFvgFamily)
            continue;

         if(MathAbs(z.upper-expectUpper)<_Point*0.5 &&
            MathAbs(z.lower-expectLower)<_Point*0.5)
           {
            found=true;
            break;
           }
        }

      if(found)
        {
         if(bull)
            matchedBull++;
         else
            matchedBear++;
        }
      else
         if(independentBull+independentBear<=200)
           {
            //--- report only the first few, and only when the zone store
            //--- was not full, since a full store legitimately drops some
            if(zones.Count()<SEA_MAX_ZONES && (independentBull+independentBear)<=5)
               PrintFormat("        %s FVG at %s [%s..%s] not reproduced by CZones",
                           (bull ? "bullish" : "bearish"),
                           TimeToString(expectTime,TIME_DATE|TIME_MINUTES),
                           DoubleToString(expectLower,_Digits),
                           DoubleToString(expectUpper,_Digits));
           }
     }

   PrintFormat("  independent scan found %d bullish and %d bearish FVGs",
               independentBull,independentBear);
   PrintFormat("  CZones reproduced %d bullish and %d bearish",matchedBull,matchedBear);

   if(zones.Count()>=SEA_MAX_ZONES)
     {
      PrintFormat("  NOTE: the zone store hit its %d ceiling, so some independently",
                  SEA_MAX_ZONES);
      Print("        found gaps were legitimately dropped. Exactness not asserted.");
      Check(matchedBull+matchedBear>0,"at least some FVGs were reproduced");
     }
   else
     {
      Check(matchedBull==independentBull,
            StringFormat("every bullish FVG reproduced exactly (%d of %d)",
                         matchedBull,independentBull));
      Check(matchedBear==independentBear,
            StringFormat("every bearish FVG reproduced exactly (%d of %d)",
                         matchedBear,independentBear));
     }

   //--- and the converse: no FVG zone that the raw bars do not support
   int phantom=0;
   for(int k=0; k<zones.Count(); k++)
     {
      SZone z;
      if(!zones.Get(k,z))
         continue;
      if(z.type!=SEA_ZONE_FVG_BULL && z.type!=SEA_ZONE_FVG_BEAR)
         continue;

      int i=z.originShift-1;      // the gap is stamped on bar i+1
      if(i<1 || i+2>=total)
         continue;

      bool bull=(r[i].low>r[i+2].high);
      bool bear=(r[i].high<r[i+2].low);
      if(!bull && !bear)
        {
         phantom++;
         if(phantom<=3)
            PrintFormat("        phantom %s at %s - no gap in the raw bars",
                        SeaZoneTypeToString(z.type),
                        TimeToString(z.originTime,TIME_DATE|TIME_MINUTES));
        }
     }
   Check(phantom==0,
         StringFormat("no FVG zone exists without a real gap behind it (%d phantoms)",
                      phantom));

   //-----------------------------------------------------------------
   Section("4. ORDER BLOCK BODIES MATCH THEIR ORIGIN CANDLE");

   //--- A demand OB is the BODY of the last bearish candle before the
   //--- push, so its bounds must equal that candle's open and close.
   int obChecked=0, obMismatch=0, obWrongColour=0;

   for(int k=0; k<zones.Count(); k++)
     {
      SZone z;
      if(!zones.Get(k,z))
         continue;
      if(z.type!=SEA_ZONE_OB_DEMAND && z.type!=SEA_ZONE_OB_SUPPLY)
         continue;

      int i=z.originShift;
      if(i<1 || i>=total)
         continue;
      if(r[i].time!=z.originTime)
         continue;

      obChecked++;

      double bodyHigh=MathMax(r[i].open,r[i].close);
      double bodyLow =MathMin(r[i].open,r[i].close);

      if(MathAbs(z.upper-bodyHigh)>_Point*0.5 || MathAbs(z.lower-bodyLow)>_Point*0.5)
        {
         obMismatch++;
         if(obMismatch<=3)
            PrintFormat("        OB at %s: zone [%s..%s] vs candle body [%s..%s]",
                        TimeToString(z.originTime,TIME_DATE|TIME_MINUTES),
                        DoubleToString(z.lower,_Digits),DoubleToString(z.upper,_Digits),
                        DoubleToString(bodyLow,_Digits),DoubleToString(bodyHigh,_Digits));
        }

      //--- demand comes from a BEARISH candle, supply from a BULLISH one
      bool candleBearish=(r[i].close<r[i].open);
      if(z.type==SEA_ZONE_OB_DEMAND && !candleBearish)
         obWrongColour++;
      if(z.type==SEA_ZONE_OB_SUPPLY && candleBearish)
         obWrongColour++;
     }

   PrintFormat("  checked %d order blocks against their origin candles",obChecked);
   Check(obMismatch==0,
         StringFormat("every OB spans exactly its origin candle body (%d mismatches)",
                      obMismatch));
   Check(obWrongColour==0,
         StringFormat("demand comes from bearish candles, supply from bullish (%d wrong)",
                      obWrongColour));

   //-----------------------------------------------------------------
   Section("5. INVERSION FLIPS TYPE AND BIAS TOGETHER");

   int inverted=0, inversionBad=0;
   for(int k=0; k<zones.Count(); k++)
     {
      SZone z;
      if(!zones.Get(k,z) || z.state!=SEA_ZONE_INVERTED)
         continue;
      inverted++;

      //--- an inverted zone must carry a breaker or IFVG type, never
      //--- still be an OB or plain FVG
      bool retyped=(z.type==SEA_ZONE_BREAKER_BULL || z.type==SEA_ZONE_BREAKER_BEAR ||
                    z.type==SEA_ZONE_IFVG_BULL   || z.type==SEA_ZONE_IFVG_BEAR);
      if(!retyped)
        {
         inversionBad++;
         continue;
        }

      //--- and the bias must agree with the new type
      bool wantsLong=(z.type==SEA_ZONE_BREAKER_BULL || z.type==SEA_ZONE_IFVG_BULL);
      if(wantsLong && z.bias!=SEA_DIR_LONG)
         inversionBad++;
      if(!wantsLong && z.bias!=SEA_DIR_SHORT)
         inversionBad++;
     }

   PrintFormat("  %d inverted zones",inverted);
   Check(inversionBad==0,
         StringFormat("every inverted zone retyped and flipped bias consistently (%d bad)",
                      inversionBad));

   //-----------------------------------------------------------------
   Section("6. QUERY METHODS RETURN ONLY WHAT THEY PROMISE");

   double price=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(price>0.0)
     {
      SZone found;

      //--- NearestFresh must return a FRESH zone of the asked bias
      if(zones.NearestFresh(price,SEA_DIR_LONG,0.0,found))
        {
         Check(found.state==SEA_ZONE_FRESH,"NearestFresh returned a FRESH zone");
         Check(found.bias==SEA_DIR_LONG,"NearestFresh honoured the requested bias");

         //--- and it really is the nearest
         double dist=0.0;
         if(price>found.upper)
            dist=price-found.upper;
         else
            if(price<found.lower)
               dist=found.lower-price;

         bool nearer=false;
         for(int k=0; k<zones.Count(); k++)
           {
            SZone z;
            if(!zones.Get(k,z))
               continue;
            if(z.state!=SEA_ZONE_FRESH || z.bias!=SEA_DIR_LONG)
               continue;
            double d=0.0;
            if(price>z.upper)
               d=price-z.upper;
            else
               if(price<z.lower)
                  d=z.lower-price;
            if(d<dist-_Point*0.5)
               nearer=true;
           }
         Check(!nearer,"no FRESH long zone sits nearer than the one returned");
        }
      else
         Print("  no FRESH long zone near price, NearestFresh checks skipped");

      //--- ZoneAtPrice must return a zone actually containing the price
      if(zones.ZoneAtPrice(price,SEA_DIR_NONE,found))
        {
         Check(price>=found.lower && price<=found.upper,
               "ZoneAtPrice returned a zone that contains the price");
         Check(found.state==SEA_ZONE_FRESH,"ZoneAtPrice returned a FRESH zone");
        }
      else
         Print("  price is not inside any FRESH zone right now");

      //--- a distance limit must be honoured
      SZone tight;
      if(zones.NearestFresh(price,SEA_DIR_LONG,_Point,tight))
        {
         double d=0.0;
         if(price>tight.upper)
            d=price-tight.upper;
         else
            if(price<tight.lower)
               d=tight.lower-price;
         Check(d<=_Point*1.5,"a tight maxDistance was respected");
        }
      else
         Check(true,"a tight maxDistance correctly returned nothing");
     }

   //-----------------------------------------------------------------
   Section("7. IMPULSE THRESHOLD WAS ACTUALLY APPLIED");

   int weakImpulse=0, obWithImpulse=0;
   for(int k=0; k<zones.Count(); k++)
     {
      SZone z;
      if(!zones.Get(k,z))
         continue;
      if(z.type!=SEA_ZONE_OB_DEMAND && z.type!=SEA_ZONE_OB_SUPPLY)
         continue;
      obWithImpulse++;
      if(z.impulseATR<InpImpulseATR-1.0e-9)
         weakImpulse++;
     }

   PrintFormat("  %d order blocks, all required >= %.1f ATR of displacement",
               obWithImpulse,InpImpulseATR);
   Check(weakImpulse==0,
         StringFormat("no OB was created from a move below the threshold (%d weak)",
                      weakImpulse));

   //--- raising the threshold must produce FEWER order blocks
   CZones strict;
   if(strict.Init(_Symbol,tf,pool,InpImpulseATR*2.5,InpZoneMaxAge,
                  InpATRPeriod,InpLookback))
     {
      int loose=0, tightCount=0;
      for(int k=0; k<zones.Count(); k++)
        {
         SZone z;
         if(zones.Get(k,z) &&
            (z.type==SEA_ZONE_OB_DEMAND || z.type==SEA_ZONE_OB_SUPPLY))
            loose++;
        }
      for(int k=0; k<strict.Count(); k++)
        {
         SZone z;
         if(strict.Get(k,z) &&
            (z.type==SEA_ZONE_OB_DEMAND || z.type==SEA_ZONE_OB_SUPPLY))
            tightCount++;
        }

      PrintFormat("  threshold %.1f ATR -> %d OBs, threshold %.1f ATR -> %d OBs",
                  InpImpulseATR,loose,InpImpulseATR*2.5,tightCount);
      Check(tightCount<=loose,
            "a stricter impulse threshold never produces MORE order blocks");
      strict.Release(pool);
     }

   //-----------------------------------------------------------------
   Section("8. CLEANUP");

   zones.Release(pool);
   pool.ReleaseAll();
   Check(pool.LiveHandles()==0,"every indicator handle released");

   Print("");
   Print("================================================================");
   PrintFormat("  RESULT: %d passed, %d failed",g_pass,g_fail);
   if(g_fail==0)
      Print("  CZones agrees with an independent read of the same bars.");
   else
      Print("  CZones DISAGREES with the raw bars. Locations are unreliable.");
   Print("================================================================");
  }
//+------------------------------------------------------------------+
