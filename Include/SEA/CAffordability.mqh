//+------------------------------------------------------------------+
//|                                                CAffordability.mqh |
//|                                                                   |
//|   Module 12. Computed tradeability per symbol.                    |
//|                                                                   |
//|   NO WHITELISTS. NO BLACKLISTS. NO SYMBOL NAMES.                  |
//|                                                                   |
//|   A symbol is tradeable when the arithmetic says the account can  |
//|   afford the stop the structure requires. That is the whole test. |
//|                                                                   |
//|   The rule this module exists to enforce:                         |
//|     NEVER tighten a stop to fit a budget.                         |
//|   If the required stop exceeds the affordable stop, the symbol is |
//|   untradeable at this equity. It is not made tradeable by moving  |
//|   the stop closer.                                                |
//+------------------------------------------------------------------+
#ifndef SEA_CAFFORDABILITY_MQH
#define SEA_CAFFORDABILITY_MQH

#include <SEA/SEA_Common.mqh>
#include <SEA/CSymbolSpec.mqh>
#include <SEA/CRiskManager.mqh>
#include <SEA/CSymbolProfiler.mqh>

#define SEA_MAX_AFFORD 512

//+------------------------------------------------------------------+
//| Affordability verdict for one symbol.                             |
//+------------------------------------------------------------------+
struct SAffordability
  {
   string            symbol;
   int               specIndex;
   bool              evaluated;
   bool              tradeable;
   string            reason;          // why not, when not

   double            pointValue;      // per price unit at VOLUME_MIN
   double            marginAtMin;
   double            affordableStop;  // price units
   double            requiredStop;    // price units
   double            stopsLevel;      // broker minimum, price units
   double            spread;          // price units
   double            spreadCap;       // requiredStop * styleSpreadCap
   double            score;           // affordableStop / requiredStop
   datetime          evaluatedAt;
   double            equityAtEval;
  };

//+------------------------------------------------------------------+
//| CAffordability                                                    |
//+------------------------------------------------------------------+
class CAffordability
  {
private:
   SAffordability    m_items[];
   int               m_count;

   double            m_maxMarginUtil;      // InpMaxMarginUtil, default 0.25
   double            m_stopSafetyFactor;   // affordable >= required * this
   double            m_lastEquity;         // for the 5% re-evaluation trigger
   double            m_equityTriggerPct;
   bool              m_verbose;

   int               Find(const string symbol) const;

public:
                     CAffordability(void);
                    ~CAffordability(void);

   //! Configure.
   //!
   //! maxMarginUtil     0.05..0.90, default 0.25
   //! stopSafetyFactor  1.0..3.0,   default 1.2  (the "* 1.2" in GATE 7)
   //! equityTriggerPct  1..50,      default 5    re-evaluate on this much
   //!                                            equity change
   void              Configure(const double maxMarginUtil,const double stopSafetyFactor,
                               const double equityTriggerPct);

   //! Print diagnostics. Off by default.
   void              SetVerbose(const bool enabled) { m_verbose=enabled; }

   //! True when equity has moved enough to warrant a full re-evaluation.
   bool              NeedsReevaluation(void) const;

   //! Note the current equity as the new reference point.
   void              MarkEvaluated(void);

   //--- evaluation --------------------------------------------------------
   //! Evaluate one symbol.
   //!
   //! requiredStop is the structural stop in PRICE units - normally
   //! ATR(14) * the profile's StopATRMult. It is an INPUT here, never
   //! something this module adjusts.
   bool              Evaluate(const string symbol,const int specIndex,
                              CSymbolSpec &spec,CRiskManager &risk,
                              const double requiredStop,const double styleSpreadCap);

   //! Evaluate from a measured profile plus a current ATR reading.
   //! Refuses to evaluate an INCOMPLETE profile - a guessed profile is
   //! never traded.
   bool              EvaluateFromProfile(const string symbol,const int specIndex,
                                         CSymbolSpec &spec,CRiskManager &risk,
                                         const SProfile &profile,const double atr,
                                         const double styleSpreadCap);

   //--- queries -------------------------------------------------------------
   //! True when the symbol passed every affordability test.
   bool              IsTradeable(const string symbol) const;

   //! Affordability score, affordableStop / requiredStop. Feeds ranking.
   //! Returns 0.0 for an unevaluated symbol.
   double            Score(const string symbol) const;

   //! Copy out the full verdict.
   bool              Get(const string symbol,SAffordability &out) const;

   //! Why a symbol is not tradeable.
   string            Reason(const string symbol) const;

   //! Number of symbols evaluated.
   int               Count(void) const { return m_count; }

   //! Copy out by index.
   bool              At(const int index,SAffordability &out) const;

   //! Count of tradeable symbols.
   int               TradeableCount(void) const;

   //! Fraction of evaluated symbols that are tradeable, 0..1.
   //! The init warning fires when this drops below 0.30.
   double            TradeableFraction(void) const;

   //! The single constraint that disqualified the most symbols. Named
   //! in the init warning so the user knows what to change.
   string            DominantConstraint(void) const;

   //--- diagnostics ----------------------------------------------------------
   //! One-line verdict for a symbol.
   string            Describe(const string symbol) const;
  };

//+------------------------------------------------------------------+
CAffordability::CAffordability(void)
  {
   m_count            = 0;
   m_maxMarginUtil    = 0.25;
   m_stopSafetyFactor = 1.2;
   m_lastEquity       = 0.0;
   m_equityTriggerPct = 5.0;
   m_verbose          = false;
   ArrayResize(m_items,SEA_MAX_AFFORD);
  }

//+------------------------------------------------------------------+
CAffordability::~CAffordability(void)
  {
   ArrayFree(m_items);
  }

//+------------------------------------------------------------------+
void CAffordability::Configure(const double maxMarginUtil,const double stopSafetyFactor,
                               const double equityTriggerPct)
  {
   m_maxMarginUtil    = (maxMarginUtil<0.05 ? 0.05 : (maxMarginUtil>0.90 ? 0.90 : maxMarginUtil));
   m_stopSafetyFactor = (stopSafetyFactor<1.0 ? 1.0 : (stopSafetyFactor>3.0 ? 3.0 : stopSafetyFactor));
   m_equityTriggerPct = (equityTriggerPct<1.0 ? 1.0 : (equityTriggerPct>50.0 ? 50.0 : equityTriggerPct));
  }

//+------------------------------------------------------------------+
int CAffordability::Find(const string symbol) const
  {
   for(int i=0; i<m_count; i++)
      if(m_items[i].symbol==symbol)
         return(i);
   return(-1);
  }

//+------------------------------------------------------------------+
bool CAffordability::NeedsReevaluation(void) const
  {
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(m_lastEquity<=0.0)
      return(true);
   double change=MathAbs(equity-m_lastEquity)/m_lastEquity*100.0;
   return(change>=m_equityTriggerPct);
  }

//+------------------------------------------------------------------+
void CAffordability::MarkEvaluated(void)
  {
   m_lastEquity=AccountInfoDouble(ACCOUNT_EQUITY);
  }

//+------------------------------------------------------------------+
//| The affordability arithmetic, verbatim from the architecture:     |
//|                                                                   |
//|   pointValue     = (TICK_VALUE_LOSS / TICK_SIZE) * VOLUME_MIN     |
//|   marginAtMin    = OrderCalcMargin(symbol, VOLUME_MIN)            |
//|   affordableStop = (Equity * CurrentRiskPct) / pointValue         |
//|   requiredStop   = ATR(14) * StopATRMult                          |
//|                                                                   |
//| TRADEABLE requires ALL of:                                        |
//|   marginAtMin    <= Equity * maxMarginUtil                        |
//|   affordableStop >= requiredStop * stopSafetyFactor               |
//|   affordableStop >= SYMBOL_TRADE_STOPS_LEVEL                      |
//|   spread         <= requiredStop * styleSpreadCap                 |
//+------------------------------------------------------------------+
bool CAffordability::Evaluate(const string symbol,const int specIndex,
                              CSymbolSpec &spec,CRiskManager &risk,
                              const double requiredStop,const double styleSpreadCap)
  {
   int slot=Find(symbol);
   if(slot<0)
     {
      if(m_count>=SEA_MAX_AFFORD)
         return(false);
      slot=m_count;
      m_count++;
     }

   SAffordability a;
   a.symbol       = symbol;
   a.specIndex    = specIndex;
   a.evaluated    = true;
   a.tradeable    = false;
   a.reason       = "";
   a.evaluatedAt  = TimeCurrent();
   a.equityAtEval = AccountInfoDouble(ACCOUNT_EQUITY);
   a.requiredStop = requiredStop;
   a.stopsLevel   = spec.StopsLevelPrice(specIndex);
   a.spread       = spec.SpreadPrice(specIndex);
   a.spreadCap    = requiredStop*styleSpreadCap;
   a.score        = 0.0;

   if(!spec.IsValid(specIndex))
     {
      a.reason="symbol spec invalid: "+spec.InvalidReason(specIndex);
      m_items[slot]=a;
      return(true);
     }

   if(requiredStop<=0.0)
     {
      a.reason="required stop not positive - structure has not defined one";
      m_items[slot]=a;
      return(true);
     }

   //--- pointValue at VOLUME_MIN
   a.pointValue=spec.PointValueAtMinVolume(specIndex);
   if(a.pointValue<=0.0)
     {
      a.reason="point value unavailable, money arithmetic impossible";
      m_items[slot]=a;
      return(true);
     }

   //--- margin at the minimum lot
   double price=SymbolInfoDouble(symbol,SYMBOL_ASK);
   if(price<=0.0)
     {
      a.reason="no ask price";
      m_items[slot]=a;
      return(true);
     }

   a.marginAtMin=0.0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY,symbol,spec.VolumeMin(specIndex),price,a.marginAtMin))
     {
      a.reason=StringFormat("OrderCalcMargin failed, error %d",GetLastError());
      m_items[slot]=a;
      return(true);
     }

   //--- affordable stop at the current risk percentage
   a.affordableStop=a.equityAtEval*risk.CurrentRiskPercent()/100.0/a.pointValue;
   a.score=(requiredStop>0.0 ? a.affordableStop/requiredStop : 0.0);

   //--- test 1: margin utilisation
   double marginCap=a.equityAtEval*m_maxMarginUtil;
   if(a.marginAtMin>marginCap)
     {
      a.reason=StringFormat("margin at minimum lot %.2f exceeds the %.0f%% cap (%.2f)",
                            a.marginAtMin,m_maxMarginUtil*100.0,marginCap);
      m_items[slot]=a;
      return(true);
     }

   //--- test 2: the stop the structure needs must be affordable.
   //--- FAILING THIS DOES NOT TIGHTEN THE STOP. It disqualifies the symbol.
   if(a.affordableStop<requiredStop*m_stopSafetyFactor)
     {
      a.reason=StringFormat("required stop %s exceeds the affordable stop %s "
                            "(x%.2f safety) - untradeable at this equity, stop NOT tightened",
                            DoubleToString(requiredStop,8),
                            DoubleToString(a.affordableStop,8),
                            m_stopSafetyFactor);
      m_items[slot]=a;
      return(true);
     }

   //--- test 3: broker minimum stop distance
   if(a.stopsLevel>0.0 && a.affordableStop<a.stopsLevel)
     {
      a.reason=StringFormat("affordable stop %s is inside the broker stops level %s",
                            DoubleToString(a.affordableStop,8),
                            DoubleToString(a.stopsLevel,8));
      m_items[slot]=a;
      return(true);
     }

   //--- test 4: execution drag
   if(a.spread>a.spreadCap)
     {
      a.reason=StringFormat("spread %s exceeds the cap %s (%.0f%% of the required stop)",
                            DoubleToString(a.spread,8),
                            DoubleToString(a.spreadCap,8),
                            styleSpreadCap*100.0);
      m_items[slot]=a;
      return(true);
     }

   a.tradeable=true;
   m_items[slot]=a;

   if(m_verbose)
      Print("[CAffordability] ",Describe(symbol));

   return(true);
  }

//+------------------------------------------------------------------+
bool CAffordability::EvaluateFromProfile(const string symbol,const int specIndex,
                                         CSymbolSpec &spec,CRiskManager &risk,
                                         const SProfile &profile,const double atr,
                                         const double styleSpreadCap)
  {
   //--- a guessed profile is never traded
   if(!profile.complete)
     {
      int slot=Find(symbol);
      if(slot<0)
        {
         if(m_count>=SEA_MAX_AFFORD)
            return(false);
         slot=m_count;
         m_count++;
        }

      SAffordability a;
      a.symbol       = symbol;
      a.specIndex    = specIndex;
      a.evaluated    = true;
      a.tradeable    = false;
      a.reason       = "profile INCOMPLETE - never trade a guessed profile";
      a.evaluatedAt  = TimeCurrent();
      a.equityAtEval = AccountInfoDouble(ACCOUNT_EQUITY);
      a.requiredStop = 0.0;
      a.score        = 0.0;
      m_items[slot]=a;
      return(true);
     }

   if(atr<=0.0)
      return(false);

   double requiredStop=atr*profile.stopATRMult;
   return(Evaluate(symbol,specIndex,spec,risk,requiredStop,styleSpreadCap));
  }

//+------------------------------------------------------------------+
bool CAffordability::IsTradeable(const string symbol) const
  {
   int i=Find(symbol);
   return(i>=0 && m_items[i].tradeable);
  }

//+------------------------------------------------------------------+
double CAffordability::Score(const string symbol) const
  {
   int i=Find(symbol);
   if(i<0)
      return(0.0);
   return(m_items[i].score);
  }

//+------------------------------------------------------------------+
bool CAffordability::Get(const string symbol,SAffordability &out) const
  {
   int i=Find(symbol);
   if(i<0)
      return(false);
   out=m_items[i];
   return(true);
  }

//+------------------------------------------------------------------+
string CAffordability::Reason(const string symbol) const
  {
   int i=Find(symbol);
   if(i<0)
      return("not evaluated");
   return(m_items[i].tradeable ? "" : m_items[i].reason);
  }

//+------------------------------------------------------------------+
bool CAffordability::At(const int index,SAffordability &out) const
  {
   if(index<0 || index>=m_count)
      return(false);
   out=m_items[index];
   return(true);
  }

//+------------------------------------------------------------------+
int CAffordability::TradeableCount(void) const
  {
   int n=0;
   for(int i=0; i<m_count; i++)
      if(m_items[i].tradeable)
         n++;
   return(n);
  }

//+------------------------------------------------------------------+
double CAffordability::TradeableFraction(void) const
  {
   if(m_count<=0)
      return(0.0);
   return((double)TradeableCount()/(double)m_count);
  }

//+------------------------------------------------------------------+
//| Which constraint is doing the most damage.                        |
//+------------------------------------------------------------------+
string CAffordability::DominantConstraint(void) const
  {
   int margin=0,stop=0,stopsLevel=0,spread=0,other=0;

   for(int i=0; i<m_count; i++)
     {
      if(m_items[i].tradeable)
         continue;

      if(StringFind(m_items[i].reason,"margin at minimum lot")>=0)
         margin++;
      else
         if(StringFind(m_items[i].reason,"exceeds the affordable stop")>=0)
            stop++;
         else
            if(StringFind(m_items[i].reason,"broker stops level")>=0)
               stopsLevel++;
            else
               if(StringFind(m_items[i].reason,"spread")>=0)
                  spread++;
               else
                  other++;
     }

   int best=margin;
   string name="margin at the minimum lot exceeds the utilisation cap";

   if(stop>best)
     {
      best=stop;
      name="the structural stop costs more than the risk budget allows";
     }
   if(stopsLevel>best)
     {
      best=stopsLevel;
      name="the affordable stop is inside the broker minimum stop distance";
     }
   if(spread>best)
     {
      best=spread;
      name="spread is too wide relative to the structural stop";
     }
   if(other>best)
     {
      best=other;
      name="assorted specification failures";
     }

   if(best<=0)
      return("no dominant constraint");

   return(StringFormat("%s (%d of %d symbols)",name,best,m_count));
  }

//+------------------------------------------------------------------+
string CAffordability::Describe(const string symbol) const
  {
   int i=Find(symbol);
   if(i<0)
      return(StringFormat("%s: not evaluated",symbol));

   SAffordability a=m_items[i];

   if(!a.tradeable)
      return(StringFormat("%s UNTRADEABLE: %s",symbol,a.reason));

   return(StringFormat("%s TRADEABLE score=%.2f afford=%s required=%s "
                       "margin=%.2f spread=%s/%s pv=%.5f",
                       symbol,a.score,
                       DoubleToString(a.affordableStop,8),
                       DoubleToString(a.requiredStop,8),
                       a.marginAtMin,
                       DoubleToString(a.spread,8),
                       DoubleToString(a.spreadCap,8),
                       a.pointValue));
  }

#endif // SEA_CAFFORDABILITY_MQH
//+------------------------------------------------------------------+
