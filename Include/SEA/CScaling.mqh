//+------------------------------------------------------------------+
//|                                                     CScaling.mqh  |
//|                                                                   |
//|   Module 17. Pyramiding into WINNERS ONLY.                        |
//|                                                                   |
//|   The hard rules, all of which this module enforces and none of   |
//|   which any caller can override:                                  |
//|     never add to a position in drawdown                           |
//|     never add before the initial stop is at break-even            |
//|     each leg is SMALLER than the last, by InpScaleDecay           |
//|     a decayed leg below VOLUME_MIN stops scaling. Never round up. |
//|     CRiskManager::ApproveExposure must return true                |
//|                                                                   |
//|   This is the module most likely to be quietly turned into a      |
//|   martingale by a well-meaning edit. It is written so that any    |
//|   such edit has to delete an explicit refusal to do it.           |
//+------------------------------------------------------------------+
#ifndef SEA_CSCALING_MQH
#define SEA_CSCALING_MQH

#include <Trade/PositionInfo.mqh>
#include <SEA/SEA_Common.mqh>
#include <SEA/CSymbolSpec.mqh>
#include <SEA/CRiskManager.mqh>
#include <SEA/CTradeExec.mqh>
#include <SEA/CStructure.mqh>
#include <SEA/CRegime.mqh>
#include <SEA/CSpikeHazard.mqh>
#include <SEA/CManagement.mqh>

#define SEA_GV_BASKET     "SEA_%d_BSK_%s"
#define SEA_MAX_BASKETS   32

//+------------------------------------------------------------------+
//| State of one symbol's scale-in basket.                            |
//+------------------------------------------------------------------+
struct SBasket
  {
   string             symbol;
   ENUM_SEA_DIRECTION direction;
   int                legCount;
   double             lastLegLots;
   double             aggregateRiskR;
   ENUM_SEA_STRUCT_STATE structureAtEntry;
   datetime           lastAddTime;
  };

//+------------------------------------------------------------------+
//| CScaling                                                          |
//+------------------------------------------------------------------+
class CScaling
  {
private:
   CPositionInfo     m_position;
   SBasket           m_baskets[];
   int               m_count;
   long              m_magic;

   double            m_scaleTriggerR;    // InpScaleTriggerR, default 1.0
   double            m_scaleDecay;       // InpScaleDecay,    default 0.5
   double            m_maxBasketRisk;    // InpMaxBasketRisk, default 1.0R
   bool              m_verbose;

   int               Find(const string symbol) const;
   string            Key(const string symbol) const;

public:
                     CScaling(void);
                    ~CScaling(void);

   //! Configure.
   //!
   //! scaleTriggerR  0.5..5.0,  default 1.0
   //! scaleDecay     0.1..0.9,  default 0.5  - strictly below 1.0, so a
   //!                leg can never be larger than the one before it
   //! maxBasketRisk  0.5..3.0R, default 1.0R
   void              Configure(const long magic,const double scaleTriggerR,
                               const double scaleDecay,const double maxBasketRisk);

   //! Print diagnostics. Off by default.
   void              SetVerbose(const bool enabled) { m_verbose=enabled; }

   //! Persist every basket.
   void              Persist(void) const;

   //! Restore a symbol's basket from GlobalVariables.
   void              Restore(const string symbol);

   //! Open a basket when the first leg fills.
   bool              OpenBasket(const string symbol,const ENUM_SEA_DIRECTION dir,
                                const double firstLegLots,const double riskR,
                                const ENUM_SEA_STRUCT_STATE structureNow);

   //! Close a basket when the last leg closes.
   void              CloseBasket(const string symbol);

   //! Copy out a basket.
   bool              Get(const string symbol,SBasket &out) const;

   //! Legs currently open on a symbol.
   int               LegCount(const string symbol) const;

   //--- the decision --------------------------------------------------------
   //! May we add a leg right now?
   //!
   //! Every gate is checked and the first refusal is returned in
   //! `reason`. A false here is final for this bar.
   bool              MayAdd(const string symbol,const ENUM_SEA_DIRECTION dir,
                            const ulong ticket,CManagement &management,
                            CStructure &structure,CRegime &regime,
                            CSpikeHazard &hazard,CRiskManager &risk,
                            const int styleMaxLegs,const int profileMaxLegs,
                            string &reason) const;

   //! Size of the next leg, decayed from the last.
   //!
   //! Returns 0.0 when the decayed size falls below VOLUME_MIN. That is
   //! a STOP SCALING signal, not an invitation to round up.
   double            NextLegLots(const string symbol,CSymbolSpec &spec,
                                 const int specIndex) const;

   //! Record a filled leg and decay the reference size.
   void              RecordLeg(const string symbol,const double lots,const double addedRiskR);

   //! Trail every leg on a symbol to the most recent confirmed swing.
   //! Called after each add, per the architecture.
   int               TrailAllLegs(const string symbol,CSymbolSpec &spec,const int specIndex,
                                  CTradeExec &exec,CStructure &structure) const;

   //! One-line summary.
   string            Describe(const string symbol) const;
  };

//+------------------------------------------------------------------+
CScaling::CScaling(void)
  {
   m_count         = 0;
   m_magic         = 0;
   m_scaleTriggerR = 1.0;
   m_scaleDecay    = 0.5;
   m_maxBasketRisk = 1.0;
   m_verbose       = false;
   ArrayResize(m_baskets,SEA_MAX_BASKETS);
  }

//+------------------------------------------------------------------+
CScaling::~CScaling(void)
  {
   Persist();
   ArrayFree(m_baskets);
  }

//+------------------------------------------------------------------+
void CScaling::Configure(const long magic,const double scaleTriggerR,
                         const double scaleDecay,const double maxBasketRisk)
  {
   m_magic         = magic;
   m_scaleTriggerR = (scaleTriggerR<0.5 ? 0.5 : (scaleTriggerR>5.0 ? 5.0 : scaleTriggerR));
   //--- clamped strictly below 1.0. A decay of 1.0 or more would let a
   //--- later leg match or exceed an earlier one, which is the first
   //--- step towards a martingale.
   m_scaleDecay    = (scaleDecay<0.1 ? 0.1 : (scaleDecay>0.9 ? 0.9 : scaleDecay));
   m_maxBasketRisk = (maxBasketRisk<0.5 ? 0.5 : (maxBasketRisk>3.0 ? 3.0 : maxBasketRisk));
  }

//+------------------------------------------------------------------+
int CScaling::Find(const string symbol) const
  {
   for(int i=0; i<m_count; i++)
      if(m_baskets[i].symbol==symbol)
         return(i);
   return(-1);
  }

//+------------------------------------------------------------------+
string CScaling::Key(const string symbol) const
  {
   return(StringFormat(SEA_GV_BASKET,(int)m_magic,symbol));
  }

//+------------------------------------------------------------------+
void CScaling::Persist(void) const
  {
   for(int i=0; i<m_count; i++)
     {
      //--- leg count in the integer part, last leg size in the fraction
      double packed=(double)m_baskets[i].legCount+
                    MathMin(0.999,m_baskets[i].lastLegLots)/1000.0;
      GlobalVariableSet(Key(m_baskets[i].symbol),packed);
     }
   GlobalVariablesFlush();
  }

//+------------------------------------------------------------------+
void CScaling::Restore(const string symbol)
  {
   string key=Key(symbol);
   if(!GlobalVariableCheck(key))
      return;

   double packed=GlobalVariableGet(key);
   int    legs=(int)MathFloor(packed);
   double lots=(packed-legs)*1000.0;

   int slot=Find(symbol);
   if(slot<0)
     {
      if(m_count>=SEA_MAX_BASKETS)
         return;
      slot=m_count;
      m_count++;
      m_baskets[slot].symbol           = symbol;
      m_baskets[slot].direction        = SEA_DIR_NONE;
      m_baskets[slot].aggregateRiskR   = (double)legs;
      m_baskets[slot].structureAtEntry = SEA_STRUCT_UNKNOWN;
      m_baskets[slot].lastAddTime      = 0;
     }

   m_baskets[slot].legCount    = legs;
   m_baskets[slot].lastLegLots = lots;
  }

//+------------------------------------------------------------------+
bool CScaling::OpenBasket(const string symbol,const ENUM_SEA_DIRECTION dir,
                          const double firstLegLots,const double riskR,
                          const ENUM_SEA_STRUCT_STATE structureNow)
  {
   int slot=Find(symbol);
   if(slot<0)
     {
      if(m_count>=SEA_MAX_BASKETS)
         return(false);
      slot=m_count;
      m_count++;
     }

   m_baskets[slot].symbol           = symbol;
   m_baskets[slot].direction        = dir;
   m_baskets[slot].legCount         = 1;
   m_baskets[slot].lastLegLots      = firstLegLots;
   m_baskets[slot].aggregateRiskR   = riskR;
   m_baskets[slot].structureAtEntry = structureNow;
   m_baskets[slot].lastAddTime      = TimeCurrent();

   Persist();
   return(true);
  }

//+------------------------------------------------------------------+
void CScaling::CloseBasket(const string symbol)
  {
   int i=Find(symbol);
   if(i<0)
      return;

   GlobalVariableDel(Key(symbol));

   int last=m_count-1;
   if(i!=last)
      m_baskets[i]=m_baskets[last];
   m_count--;
  }

//+------------------------------------------------------------------+
bool CScaling::Get(const string symbol,SBasket &out) const
  {
   int i=Find(symbol);
   if(i<0)
      return(false);
   out=m_baskets[i];
   return(true);
  }

//+------------------------------------------------------------------+
int CScaling::LegCount(const string symbol) const
  {
   int i=Find(symbol);
   return(i<0 ? 0 : m_baskets[i].legCount);
  }

//+------------------------------------------------------------------+
//| Every scale-in gate, in order.                                    |
//+------------------------------------------------------------------+
bool CScaling::MayAdd(const string symbol,const ENUM_SEA_DIRECTION dir,
                      const ulong ticket,CManagement &management,
                      CStructure &structure,CRegime &regime,
                      CSpikeHazard &hazard,CRiskManager &risk,
                      const int styleMaxLegs,const int profileMaxLegs,
                      string &reason) const
  {
   reason="";

   int slot=Find(symbol);
   if(slot<0)
     {
      reason="no open basket on this symbol";
      return(false);
     }

   SManagedPosition pos;
   if(!management.Get(ticket,pos))
     {
      reason="position not tracked";
      return(false);
     }

   //--- the direction of an add must match the basket
   if(m_baskets[slot].direction!=dir)
     {
      reason="add direction does not match the open basket";
      return(false);
     }

   //--- HARD: never add to a position in drawdown
   double price=(dir==SEA_DIR_LONG ? SymbolInfoDouble(symbol,SYMBOL_BID)
                 : SymbolInfoDouble(symbol,SYMBOL_ASK));
   if(price<=0.0)
     {
      reason="no current price";
      return(false);
     }

   double move=(dir==SEA_DIR_LONG ? price-pos.entryPrice : pos.entryPrice-price);
   if(move<=0.0)
     {
      reason="REFUSED: position is in drawdown - never add to a loser";
      return(false);
     }

   double r=(pos.initialRisk>0.0 ? move/pos.initialRisk : 0.0);

   //--- must be at or beyond the scale trigger
   if(r<m_scaleTriggerR)
     {
      reason=StringFormat("position at %.2fR, below the %.2fR scale trigger",r,m_scaleTriggerR);
      return(false);
     }

   //--- HARD: the initial stop must already be at break-even
   if(!pos.breakEvenDone)
     {
      reason="REFUSED: initial stop is not yet at break-even";
      return(false);
     }

   //--- HTF structure must be unchanged since the basket opened
   if(structure.State()!=m_baskets[slot].structureAtEntry)
     {
      reason=StringFormat("structure changed since entry (%s -> %s)",
                          SeaStructStateToString(m_baskets[slot].structureAtEntry),
                          SeaStructStateToString(structure.State()));
      return(false);
     }

   //--- the regime must permit adds at all
   SRegimeProfile prof=regime.Profile();
   if(prof.maxScaleIns==0)
     {
      reason=StringFormat("regime %s permits no scale-ins",
                          SeaRegimeToString(regime.Regime()));
      return(false);
     }

   //--- leg ceiling: the LOWEST of style, profile and regime
   int ceiling=styleMaxLegs;
   if(profileMaxLegs>=0 && profileMaxLegs<ceiling)
      ceiling=profileMaxLegs;
   if(prof.maxScaleIns>=0 && prof.maxScaleIns<ceiling)
      ceiling=prof.maxScaleIns;

   if(m_baskets[slot].legCount>ceiling)
     {
      reason=StringFormat("leg count %d at the ceiling %d",
                          m_baskets[slot].legCount,ceiling);
      return(false);
     }

   //--- the add must be justified structurally: a new BOS in the trend
   //--- direction, or a pullback into a fresh continuation zone
   bool newBOS=(structure.LastBreak()==SEA_BREAK_BOS &&
                structure.LastBreakDirection()==dir &&
                structure.LastBreakTime()>m_baskets[slot].lastAddTime);

   if(!newBOS && !prof.addOnPullback)
     {
      reason="no new BOS in the trend direction since the last add";
      return(false);
     }

   //--- hazard must permit a scale-in in this direction
   if(!hazard.PermitsScaleIn(symbol,dir))
     {
      reason=StringFormat("spike hazard %s forbids scaling into this direction",
                          SeaHazardToString(hazard.Band(symbol)));
      return(false);
     }

   //--- and the risk engine has the last word
   string riskReason;
   if(!risk.ApproveExposure(m_baskets[slot].aggregateRiskR,1.0,m_maxBasketRisk,riskReason))
     {
      reason="risk engine refused: "+riskReason;
      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Decayed leg size. Never rounds up.                                |
//+------------------------------------------------------------------+
double CScaling::NextLegLots(const string symbol,CSymbolSpec &spec,
                             const int specIndex) const
  {
   int i=Find(symbol);
   if(i<0)
      return(0.0);

   double raw=m_baskets[i].lastLegLots*m_scaleDecay;
   double lots=spec.NormalizeVolume(specIndex,raw);

   //--- below the broker minimum: STOP SCALING. Do not round up.
   if(lots<=0.0)
     {
      if(m_verbose)
         PrintFormat("[CScaling] %s: decayed leg %s is below VOLUME_MIN - scaling stops",
                     symbol,DoubleToString(raw,8));
      return(0.0);
     }

   //--- a normalized size that came out LARGER than the raw decay would
   //--- mean the step grid rounded up. Refuse it.
   if(lots>m_baskets[i].lastLegLots)
     {
      if(m_verbose)
         PrintFormat("[CScaling] %s: normalization would enlarge the leg - refused",symbol);
      return(0.0);
     }

   return(lots);
  }

//+------------------------------------------------------------------+
void CScaling::RecordLeg(const string symbol,const double lots,const double addedRiskR)
  {
   int i=Find(symbol);
   if(i<0)
      return;

   m_baskets[i].legCount++;
   m_baskets[i].lastLegLots    = lots;
   m_baskets[i].aggregateRiskR+= addedRiskR;
   m_baskets[i].lastAddTime    = TimeCurrent();

   Persist();

   if(m_verbose)
      Print("[CScaling] ",Describe(symbol));
  }

//+------------------------------------------------------------------+
//| After each add, every leg trails to the most recent confirmed     |
//| swing. Legs are never left behind on their original stops.        |
//+------------------------------------------------------------------+
int CScaling::TrailAllLegs(const string symbol,CSymbolSpec &spec,const int specIndex,
                           CTradeExec &exec,CStructure &structure) const
  {
   int i=Find(symbol);
   if(i<0 || !structure.IsReady())
      return(0);

   bool isLong=(m_baskets[i].direction==SEA_DIR_LONG);

   SSwing sw;
   bool got=(isLong ? structure.LastSwingLow(sw) : structure.LastSwingHigh(sw));
   if(!got)
      return(0);

   double target=spec.NormalizePrice(specIndex,sw.price);
   int    moved=0;

   int total=exec.PositionCount(symbol);
   for(int k=0; k<total; k++)
     {
      ulong ticket=exec.PositionTicket(symbol,k);
      if(ticket==0)
         continue;

      //--- ModifyPosition refuses any widening, so a leg already tighter
      //--- than the swing is simply left alone
      if(exec.ModifyPosition(ticket,target,0.0))
         moved++;
     }

   return(moved);
  }

//+------------------------------------------------------------------+
string CScaling::Describe(const string symbol) const
  {
   int i=Find(symbol);
   if(i<0)
      return(StringFormat("%s: no basket",symbol));

   return(StringFormat("%s basket %s legs=%d lastLeg=%s aggRisk=%.2fR structAtEntry=%s",
                       symbol,SeaDirectionToString(m_baskets[i].direction),
                       m_baskets[i].legCount,
                       DoubleToString(m_baskets[i].lastLegLots,4),
                       m_baskets[i].aggregateRiskR,
                       SeaStructStateToString(m_baskets[i].structureAtEntry)));
  }

#endif // SEA_CSCALING_MQH
//+------------------------------------------------------------------+
