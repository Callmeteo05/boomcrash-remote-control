//+------------------------------------------------------------------+
//|                                                  CManagement.mqh  |
//|                                                                   |
//|   Module 18. Break-even, partials, structural trailing.           |
//|                                                                   |
//|   Management answers one question per bar: given what structure   |
//|   now says, where does the stop belong?                           |
//|                                                                   |
//|   Two absolutes:                                                  |
//|     NEVER widen an existing stop. CTradeExec refuses it too, so   |
//|     the rule is enforced twice on purpose.                        |
//|     Exit at a structural level where one exists. A fixed R        |
//|     multiple is the fallback, not the plan.                       |
//+------------------------------------------------------------------+
#ifndef SEA_CMANAGEMENT_MQH
#define SEA_CMANAGEMENT_MQH

#include <Trade/PositionInfo.mqh>
#include <SEA/SEA_Common.mqh>
#include <SEA/CSymbolSpec.mqh>
#include <SEA/CTradeExec.mqh>
#include <SEA/CStructure.mqh>
#include <SEA/CRegime.mqh>
#include <SEA/CSpikeHazard.mqh>

#define SEA_MAX_TRACKED 64

//+------------------------------------------------------------------+
//| What the EA remembers about one live position.                    |
//+------------------------------------------------------------------+
struct SManagedPosition
  {
   ulong             ticket;
   string            symbol;
   ENUM_SEA_DIRECTION direction;
   double            entryPrice;
   double            initialStop;
   double            initialRisk;      // price units
   double            lots;
   datetime          openTime;
   bool              breakEvenDone;
   bool              partialTaken;
   double            maxFavourable;    // MFE in price units
   double            maxAdverse;       // MAE in price units
   int               legCount;
   bool              counterSpike;
  };

//+------------------------------------------------------------------+
//| CManagement                                                       |
//+------------------------------------------------------------------+
class CManagement
  {
private:
   CPositionInfo     m_position;
   SManagedPosition  m_tracked[];
   int               m_count;

   double            m_partialAtR;      // take a partial at this R
   double            m_partialFraction; // fraction of the position closed
   bool              m_usePartials;
   bool              m_verbose;

   int               Find(const ulong ticket) const;
   double            CurrentR(const SManagedPosition &p,const double price) const;

public:
                     CManagement(void);
                    ~CManagement(void);

   //! Configure.
   //!
   //! partialAtR       0.5..5.0, default 1.0
   //! partialFraction  0.1..0.9, default 0.5
   //! usePartials      default true
   void              Configure(const double partialAtR,const double partialFraction,
                               const bool usePartials);

   //! Print diagnostics. Off by default.
   void              SetVerbose(const bool enabled) { m_verbose=enabled; }

   //! Begin tracking a filled position.
   bool              Track(const ulong ticket,const string symbol,
                           const ENUM_SEA_DIRECTION dir,
                           const double entry,const double stop,const double lots,
                           const bool counterSpike);

   //! Stop tracking a closed position and return its record.
   bool              Untrack(const ulong ticket,SManagedPosition &out);

   //! Drop records whose positions no longer exist.
   int               Reconcile(CTradeExec &exec);

   //! Number of tracked positions.
   int               Count(void) const { return m_count; }

   //! Copy out a tracked record.
   bool              Get(const ulong ticket,SManagedPosition &out) const;

   //! Copy out by index.
   bool              At(const int index,SManagedPosition &out) const;

   //--- per-bar management -------------------------------------------------
   //! Manage one position for one bar.
   //!
   //! Applies, in order:
   //!   1. hazard-driven forced exits (they outrank everything)
   //!   2. break-even at the regime's R threshold
   //!   3. a partial at the configured R
   //!   4. a structural or ATR trail per the regime profile
   //!
   //! Returns true when something was changed.
   bool              Manage(const ulong ticket,CSymbolSpec &spec,const int specIndex,
                            CTradeExec &exec,CStructure &structure,CRegime &regime,
                            CSpikeHazard &hazard);

   //! Update the MFE/MAE excursion record. Cheap enough for the tick
   //! path: it compares two doubles.
   void              UpdateExcursion(const ulong ticket,const double price);

   //! Realised outcome in R for a closed position.
   double            OutcomeR(const SManagedPosition &p,const double closePrice) const;

   //! One-line summary of a tracked position.
   string            Describe(const ulong ticket) const;
  };

//+------------------------------------------------------------------+
CManagement::CManagement(void)
  {
   m_count           = 0;
   m_partialAtR      = 1.0;
   m_partialFraction = 0.5;
   m_usePartials     = true;
   m_verbose         = false;
   ArrayResize(m_tracked,SEA_MAX_TRACKED);
  }

//+------------------------------------------------------------------+
CManagement::~CManagement(void)
  {
   ArrayFree(m_tracked);
  }

//+------------------------------------------------------------------+
void CManagement::Configure(const double partialAtR,const double partialFraction,
                            const bool usePartials)
  {
   m_partialAtR      = (partialAtR<0.5 ? 0.5 : (partialAtR>5.0 ? 5.0 : partialAtR));
   m_partialFraction = (partialFraction<0.1 ? 0.1 : (partialFraction>0.9 ? 0.9 : partialFraction));
   m_usePartials     = usePartials;
  }

//+------------------------------------------------------------------+
int CManagement::Find(const ulong ticket) const
  {
   for(int i=0; i<m_count; i++)
      if(m_tracked[i].ticket==ticket)
         return(i);
   return(-1);
  }

//+------------------------------------------------------------------+
bool CManagement::Track(const ulong ticket,const string symbol,
                        const ENUM_SEA_DIRECTION dir,
                        const double entry,const double stop,const double lots,
                        const bool counterSpike)
  {
   if(Find(ticket)>=0)
      return(true);
   if(m_count>=SEA_MAX_TRACKED)
      return(false);

   m_tracked[m_count].ticket        = ticket;
   m_tracked[m_count].symbol        = symbol;
   m_tracked[m_count].direction     = dir;
   m_tracked[m_count].entryPrice    = entry;
   m_tracked[m_count].initialStop   = stop;
   m_tracked[m_count].initialRisk   = MathAbs(entry-stop);
   m_tracked[m_count].lots          = lots;
   m_tracked[m_count].openTime      = TimeCurrent();
   m_tracked[m_count].breakEvenDone = false;
   m_tracked[m_count].partialTaken  = false;
   m_tracked[m_count].maxFavourable = 0.0;
   m_tracked[m_count].maxAdverse    = 0.0;
   m_tracked[m_count].legCount      = 1;
   m_tracked[m_count].counterSpike  = counterSpike;
   m_count++;
   return(true);
  }

//+------------------------------------------------------------------+
bool CManagement::Untrack(const ulong ticket,SManagedPosition &out)
  {
   int i=Find(ticket);
   if(i<0)
      return(false);

   out=m_tracked[i];
   int last=m_count-1;
   if(i!=last)
      m_tracked[i]=m_tracked[last];
   m_count--;
   return(true);
  }

//+------------------------------------------------------------------+
int CManagement::Reconcile(CTradeExec &exec)
  {
   int dropped=0;
   for(int i=m_count-1; i>=0; i--)
     {
      if(m_position.SelectByTicket(m_tracked[i].ticket))
         continue;

      //--- the position is gone; the journal captures the outcome from
      //--- the deal history, so here we only release the slot
      int last=m_count-1;
      if(i!=last)
         m_tracked[i]=m_tracked[last];
      m_count--;
      dropped++;
     }
   return(dropped);
  }

//+------------------------------------------------------------------+
bool CManagement::Get(const ulong ticket,SManagedPosition &out) const
  {
   int i=Find(ticket);
   if(i<0)
      return(false);
   out=m_tracked[i];
   return(true);
  }

//+------------------------------------------------------------------+
bool CManagement::At(const int index,SManagedPosition &out) const
  {
   if(index<0 || index>=m_count)
      return(false);
   out=m_tracked[index];
   return(true);
  }

//+------------------------------------------------------------------+
double CManagement::CurrentR(const SManagedPosition &p,const double price) const
  {
   if(p.initialRisk<=0.0)
      return(0.0);

   double move=(p.direction==SEA_DIR_LONG ? price-p.entryPrice : p.entryPrice-price);
   return(move/p.initialRisk);
  }

//+------------------------------------------------------------------+
void CManagement::UpdateExcursion(const ulong ticket,const double price)
  {
   int i=Find(ticket);
   if(i<0)
      return;

   double move=(m_tracked[i].direction==SEA_DIR_LONG
                ? price-m_tracked[i].entryPrice
                : m_tracked[i].entryPrice-price);

   if(move>m_tracked[i].maxFavourable)
      m_tracked[i].maxFavourable=move;
   if(move<m_tracked[i].maxAdverse)
      m_tracked[i].maxAdverse=move;
  }

//+------------------------------------------------------------------+
double CManagement::OutcomeR(const SManagedPosition &p,const double closePrice) const
  {
   return(CurrentR(p,closePrice));
  }

//+------------------------------------------------------------------+
bool CManagement::Manage(const ulong ticket,CSymbolSpec &spec,const int specIndex,
                         CTradeExec &exec,CStructure &structure,CRegime &regime,
                         CSpikeHazard &hazard)
  {
   int slot=Find(ticket);
   if(slot<0)
      return(false);
   if(!m_position.SelectByTicket(ticket))
      return(false);

   const string symbol=m_tracked[slot].symbol;
   const bool   isLong=(m_tracked[slot].direction==SEA_DIR_LONG);

   double price=(isLong ? SymbolInfoDouble(symbol,SYMBOL_BID)
                 : SymbolInfoDouble(symbol,SYMBOL_ASK));
   if(price<=0.0)
      return(false);

   UpdateExcursion(ticket,price);

   double r          = CurrentR(m_tracked[slot],price);
   double currentStop= m_position.StopLoss();
   bool   acted      = false;

   //--- 1. HAZARD OVERRIDES. A counter-spike position in rising hazard
   //--- is closed regardless of how good it looks.
   if(hazard.MustFlattenCounter(symbol,m_tracked[slot].direction))
     {
      exec.ClosePosition(ticket,"hazard EXTREME: counter-spike flattened");
      return(true);
     }

   if(hazard.ShouldCloseProfitableCounter(symbol,m_tracked[slot].direction,r))
     {
      exec.ClosePosition(ticket,
                         StringFormat("hazard HIGH: profitable counter-spike closed at %.2fR",r));
      return(true);
     }

   SRegimeProfile prof=regime.Profile();

   //--- 2. BREAK-EVEN at the regime's R threshold
   if(!m_tracked[slot].breakEvenDone && prof.breakEvenR>0.0 && r>=prof.breakEvenR)
     {
      //--- break-even plus the spread, so the exit is genuinely flat
      double spread=spec.SpreadPrice(specIndex);
      double beStop=(isLong ? m_tracked[slot].entryPrice+spread
                     : m_tracked[slot].entryPrice-spread);

      bool improves=(currentStop<=0.0 ||
                     (isLong ? beStop>currentStop : beStop<currentStop));

      if(improves && exec.ModifyPosition(ticket,spec.NormalizePrice(specIndex,beStop),
                                         m_position.TakeProfit()))
        {
         m_tracked[slot].breakEvenDone=true;
         currentStop=beStop;
         acted=true;
         if(m_verbose)
            PrintFormat("[CManagement] #%I64u break-even at %.2fR",ticket,r);
        }
     }

   //--- 3. PARTIAL at the configured R
   if(m_usePartials && !m_tracked[slot].partialTaken && r>=m_partialAtR)
     {
      double closeVolume=m_position.Volume()*m_partialFraction;
      if(exec.ClosePartial(specIndex,ticket,closeVolume,
                           StringFormat("partial at %.2fR",r)))
        {
         m_tracked[slot].partialTaken=true;
         acted=true;
        }
     }

   //--- 4. TRAIL, per the regime profile.
   //--- A spike instrument is never trailed - with-spike positions close
   //--- on the spike, counter-spike positions are never trailed into
   //--- rising hazard.
   if(hazard.TrailingForbidden(symbol,m_tracked[slot].direction))
      return(acted);

   double newStop=0.0;

   if(prof.trailStructural && structure.IsReady())
     {
      //--- trail to the most recent confirmed swing behind price
      SSwing sw;
      if(isLong && structure.LastSwingLow(sw))
         newStop=sw.price;
      if(!isLong && structure.LastSwingHigh(sw))
         newStop=sw.price;
     }
   else
      if(prof.trailATR && prof.trailATRMult>0.0)
        {
         double atr=regime.ATRFast();
         if(atr>0.0)
            newStop=(isLong ? price-atr*prof.trailATRMult
                     : price+atr*prof.trailATRMult);
        }

   if(newStop<=0.0)
      return(acted);

   //--- NEVER WIDEN. Only a stop that improves is sent.
   bool improves=(currentStop<=0.0 ||
                  (isLong ? newStop>currentStop : newStop<currentStop));
   if(!improves)
      return(acted);

   //--- respect the broker's minimum distance from current price
   double stopsLevel=spec.StopsLevelPrice(specIndex);
   if(stopsLevel>0.0 && MathAbs(price-newStop)<stopsLevel)
      return(acted);

   if(exec.ModifyPosition(ticket,spec.NormalizePrice(specIndex,newStop),
                          m_position.TakeProfit()))
     {
      acted=true;
      if(m_verbose)
         PrintFormat("[CManagement] #%I64u trailed to %s at %.2fR",
                     ticket,DoubleToString(newStop,8),r);
     }

   return(acted);
  }

//+------------------------------------------------------------------+
string CManagement::Describe(const ulong ticket) const
  {
   int i=Find(ticket);
   if(i<0)
      return(StringFormat("#%I64u not tracked",ticket));

   return(StringFormat("#%I64u %s %s entry=%s stop=%s risk=%s legs=%d be=%s partial=%s "
                       "MFE=%s MAE=%s counterSpike=%s",
                       m_tracked[i].ticket,m_tracked[i].symbol,
                       SeaDirectionToString(m_tracked[i].direction),
                       DoubleToString(m_tracked[i].entryPrice,8),
                       DoubleToString(m_tracked[i].initialStop,8),
                       DoubleToString(m_tracked[i].initialRisk,8),
                       m_tracked[i].legCount,
                       (m_tracked[i].breakEvenDone ? "yes" : "no"),
                       (m_tracked[i].partialTaken ? "yes" : "no"),
                       DoubleToString(m_tracked[i].maxFavourable,8),
                       DoubleToString(m_tracked[i].maxAdverse,8),
                       (m_tracked[i].counterSpike ? "yes" : "no")));
  }

#endif // SEA_CMANAGEMENT_MQH
//+------------------------------------------------------------------+
