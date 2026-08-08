//+------------------------------------------------------------------+
//|                                                   CTradeExec.mqh  |
//|                                                                   |
//|   Module 3. Synchronous CTrade wrapper.                           |
//|                                                                   |
//|   RULE 4: SetAsyncMode(false), always. An asynchronous entry or a  |
//|   risk-triggered close can report success before the server has   |
//|   agreed, which turns a drawdown halt into a suggestion.          |
//|                                                                   |
//|   RULE 5: every position query is filtered by magic AND symbol.   |
//|   RULE 6: no order leaves this module without a stop loss.        |
//|                                                                   |
//|   Explicit retcode handling for 10030 (bad filling), 10016 (bad   |
//|   stops), 10019 (no money), 10006 (rejected), 10004/10021         |
//|   (requote / no prices).                                          |
//+------------------------------------------------------------------+
#ifndef SEA_CTRADEEXEC_MQH
#define SEA_CTRADEEXEC_MQH

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/OrderInfo.mqh>
#include <SEA/SEA_Common.mqh>
#include <SEA/CSymbolSpec.mqh>

//+------------------------------------------------------------------+
//| Outcome of one execution attempt, for the journal.                |
//+------------------------------------------------------------------+
struct SExecResult
  {
   bool              success;
   uint              retcode;
   string            retcodeText;
   ulong             orderTicket;
   ulong             dealTicket;
   double            requestedPrice;
   double            filledPrice;
   double            slippagePoints;
   double            requestedVolume;
   double            filledVolume;
   int               attempts;
   string            detail;
  };

//+------------------------------------------------------------------+
//| CTradeExec                                                        |
//+------------------------------------------------------------------+
class CTradeExec
  {
private:
   CTrade            m_trade;
   CPositionInfo     m_position;
   COrderInfo        m_order;
   CSymbolSpec      *m_spec;          // not owned
   long              m_magic;
   int               m_maxDeviation;  // points
   int               m_maxRetries;
   bool              m_verbose;
   SExecResult       m_last;

   void              ResetResult(const double reqPrice,const double reqVolume);
   void              CaptureResult(const bool ok,const int attempts);
   bool              IsRetryable(const uint retcode) const;
   bool              ApplyFilling(const int specIndex,const int attemptIndex,const bool pending);

public:
                     CTradeExec(void);
                    ~CTradeExec(void) {}

   //! Bind to the spec cache and configure execution.
   //!
   //! maxDeviation 0..200 points, default 20
   //! maxRetries   0..10,         default 3
   //!
   //! Sets SetAsyncMode(false) unconditionally. There is no input to
   //! turn that off.
   bool              Init(CSymbolSpec &spec,const long magic,
                          const int maxDeviation,const int maxRetries);

   //! Print diagnostics. Off by default.
   void              SetVerbose(const bool enabled) { m_verbose=enabled; }

   //! Result of the most recent attempt.
   SExecResult       LastResult(void) const { return m_last; }

   //--- entries -----------------------------------------------------------
   //! Place a pending entry at a precomputed level.
   //!
   //! Entries are pending orders placed on the execution bar close, not
   //! market orders fired on tick arrival. expiryBars converts to a
   //! broker expiry when the symbol supports ORDER_TIME_SPECIFIED, and
   //! is tracked by the caller otherwise.
   //!
   //! Refuses outright when stopLoss is zero - RULE 6.
   bool              PlacePending(const int specIndex,const ENUM_SEA_DIRECTION dir,
                                  const double entryPrice,const double stopLoss,
                                  const double takeProfit,const double lots,
                                  const ENUM_TIMEFRAMES tf,const int expiryBars,
                                  const string comment);

   //! Market entry. Used only where a pending cannot express the idea.
   //! Refuses without a stop loss.
   bool              OpenMarket(const int specIndex,const ENUM_SEA_DIRECTION dir,
                                const double stopLoss,const double takeProfit,
                                const double lots,const string comment);

   //--- management ---------------------------------------------------------
   //! Modify a position's stop and target.
   //! Refuses to WIDEN an existing stop - that is never permitted.
   bool              ModifyPosition(const ulong ticket,const double newStop,const double newTarget);

   //! Close a position in full, synchronously.
   bool              ClosePosition(const ulong ticket,const string reason);

   //! Close part of a position. volume is normalized before sending.
   bool              ClosePartial(const int specIndex,const ulong ticket,const double volume,
                                  const string reason);

   //! Cancel a pending order.
   bool              CancelOrder(const ulong ticket,const string reason);

   //! Close every position on a symbol carrying our magic.
   int               CloseAllForSymbol(const string symbol,const string reason);

   //! Close every position carrying our magic, on every symbol.
   //! Used by the drawdown hard halt.
   int               CloseAll(const string reason);

   //! Cancel every pending order carrying our magic.
   int               CancelAllPendings(const string reason);

   //--- queries -------------------------------------------------------------
   //! Positions open on a symbol with our magic. RULE 5.
   int               PositionCount(const string symbol) const;

   //! Positions open with our magic across all symbols.
   int               TotalPositions(void) const;

   //! Pending orders on a symbol with our magic.
   int               PendingCount(const string symbol) const;

   //! Ticket of the nth position on a symbol with our magic.
   ulong             PositionTicket(const string symbol,const int index) const;

   //! Aggregate volume held on a symbol with our magic.
   double            SymbolVolume(const string symbol) const;

   //! True when a position with our magic exists on the symbol.
   bool              HasPosition(const string symbol) const { return PositionCount(symbol)>0; }

   //--- diagnostics ----------------------------------------------------------
   //! Readable meaning of a server retcode.
   string            RetcodeText(const uint retcode) const;

   //! One-line summary of the last attempt.
   string            DescribeLast(void) const;
  };

//+------------------------------------------------------------------+
CTradeExec::CTradeExec(void)
  {
   m_spec         = NULL;
   m_magic        = 0;
   m_maxDeviation = 20;
   m_maxRetries   = 3;
   m_verbose      = false;
   ResetResult(0.0,0.0);
  }

//+------------------------------------------------------------------+
bool CTradeExec::Init(CSymbolSpec &spec,const long magic,
                      const int maxDeviation,const int maxRetries)
  {
   m_spec         = GetPointer(spec);
   m_magic        = magic;
   m_maxDeviation = (maxDeviation<0 ? 0 : (maxDeviation>200 ? 200 : maxDeviation));
   m_maxRetries   = (maxRetries<0 ? 0 : (maxRetries>10 ? 10 : maxRetries));

   m_trade.SetExpertMagicNumber(magic);
   m_trade.SetDeviationInPoints(m_maxDeviation);

   //--- RULE 4. Not configurable.
   m_trade.SetAsyncMode(false);

   m_trade.LogLevel(m_verbose ? LOG_LEVEL_ERRORS : LOG_LEVEL_NO);

   return(true);
  }

//+------------------------------------------------------------------+
void CTradeExec::ResetResult(const double reqPrice,const double reqVolume)
  {
   m_last.success         = false;
   m_last.retcode         = 0;
   m_last.retcodeText     = "";
   m_last.orderTicket     = 0;
   m_last.dealTicket      = 0;
   m_last.requestedPrice  = reqPrice;
   m_last.filledPrice     = 0.0;
   m_last.slippagePoints  = 0.0;
   m_last.requestedVolume = reqVolume;
   m_last.filledVolume    = 0.0;
   m_last.attempts        = 0;
   m_last.detail          = "";
  }

//+------------------------------------------------------------------+
void CTradeExec::CaptureResult(const bool ok,const int attempts)
  {
   m_last.success     = ok;
   m_last.retcode     = m_trade.ResultRetcode();
   m_last.retcodeText = RetcodeText(m_last.retcode);
   m_last.orderTicket = m_trade.ResultOrder();
   m_last.dealTicket  = m_trade.ResultDeal();
   m_last.filledPrice = m_trade.ResultPrice();
   m_last.filledVolume= m_trade.ResultVolume();
   m_last.attempts    = attempts;

   if(m_last.filledPrice>0.0 && m_last.requestedPrice>0.0 && m_spec!=NULL)
     {
      int idx=m_spec.IndexOf(m_trade.RequestSymbol());
      double point=(idx>=0 ? m_spec.Point(idx) : _Point);
      if(point>0.0)
         m_last.slippagePoints=(m_last.filledPrice-m_last.requestedPrice)/point;
     }
  }

//+------------------------------------------------------------------+
//| Which retcodes are worth another attempt.                         |
//+------------------------------------------------------------------+
bool CTradeExec::IsRetryable(const uint retcode) const
  {
   switch(retcode)
     {
      case TRADE_RETCODE_REQUOTE:          // 10004
      case TRADE_RETCODE_PRICE_CHANGED:    // 10020
      case TRADE_RETCODE_PRICE_OFF:        // 10021
      case TRADE_RETCODE_TIMEOUT:          // 10012
      case TRADE_RETCODE_CONNECTION:       // 10031
         return(true);
      case TRADE_RETCODE_INVALID_FILL:     // 10030 - retry with another mode
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Select the filling mode for an attempt, walking the fallback list |
//| supplied by CSymbolSpec on each 10030.                            |
//+------------------------------------------------------------------+
bool CTradeExec::ApplyFilling(const int specIndex,const int attemptIndex,const bool pending)
  {
   if(m_spec==NULL)
      return(false);

   ENUM_ORDER_TYPE_FILLING list[];
   int n=m_spec.SupportedFillings(specIndex,list);

   if(n<=0)
     {
      m_trade.SetTypeFilling(pending ? ORDER_FILLING_RETURN : ORDER_FILLING_FOK);
      return(true);
     }

   //--- first attempt uses the resolved default for the order kind
   if(attemptIndex<=0)
     {
      m_trade.SetTypeFilling(pending ? m_spec.FillingPending(specIndex)
                             : m_spec.FillingMarket(specIndex));
      return(true);
     }

   int pick=attemptIndex%n;
   m_trade.SetTypeFilling(list[pick]);
   return(true);
  }

//+------------------------------------------------------------------+
bool CTradeExec::PlacePending(const int specIndex,const ENUM_SEA_DIRECTION dir,
                              const double entryPrice,const double stopLoss,
                              const double takeProfit,const double lots,
                              const ENUM_TIMEFRAMES tf,const int expiryBars,
                              const string comment)
  {
   ResetResult(entryPrice,lots);

   if(m_spec==NULL || !m_spec.IsValid(specIndex))
     {
      m_last.detail="spec invalid";
      return(false);
     }
   if(dir==SEA_DIR_NONE)
     {
      m_last.detail="direction NONE";
      return(false);
     }

   //--- RULE 6: no naked positions, ever
   if(stopLoss<=0.0)
     {
      m_last.detail="refused: no stop loss supplied";
      Print("[CTradeExec] REFUSED entry without a stop loss - RULE 6");
      return(false);
     }
   if(lots<=0.0)
     {
      m_last.detail="refused: lots not positive";
      return(false);
     }

   const string symbol=m_spec.Name(specIndex);
   double ask=SymbolInfoDouble(symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(symbol,SYMBOL_BID);
   if(ask<=0.0 || bid<=0.0)
     {
      m_last.detail="no current prices";
      return(false);
     }

   //--- stop must sit on the correct side of the entry
   if(dir==SEA_DIR_LONG && stopLoss>=entryPrice)
     {
      m_last.detail="long stop is not below entry";
      return(false);
     }
   if(dir==SEA_DIR_SHORT && stopLoss<=entryPrice)
     {
      m_last.detail="short stop is not above entry";
      return(false);
     }

   //--- broker minimum distance
   double stopsLevel=m_spec.StopsLevelPrice(specIndex);
   if(stopsLevel>0.0)
     {
      if(MathAbs(entryPrice-stopLoss)<stopsLevel)
        {
         m_last.detail=StringFormat("stop %s inside the broker stops level %s",
                                    DoubleToString(MathAbs(entryPrice-stopLoss),8),
                                    DoubleToString(stopsLevel,8));
         return(false);
        }
     }

   double entry = m_spec.NormalizePrice(specIndex,entryPrice);
   double sl    = m_spec.NormalizePrice(specIndex,stopLoss);
   double tp    = (takeProfit>0.0 ? m_spec.NormalizePrice(specIndex,takeProfit) : 0.0);
   double volume= m_spec.NormalizeVolume(specIndex,lots);

   if(volume<=0.0)
     {
      m_last.detail="volume normalized to zero - rejected, not rounded up";
      return(false);
     }

   //--- pick the pending type from where the level sits relative to price
   ENUM_ORDER_TYPE type;
   if(dir==SEA_DIR_LONG)
      type=(entry<ask ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_BUY_STOP);
   else
      type=(entry>bid ? ORDER_TYPE_SELL_LIMIT : ORDER_TYPE_SELL_STOP);

   //--- expiry
   ENUM_ORDER_TYPE_TIME timeType=ORDER_TIME_GTC;
   datetime expiry=0;
   if(expiryBars>0 && m_spec.IsExpirationSupported(specIndex,ORDER_TIME_SPECIFIED))
     {
      int secs=PeriodSeconds(tf);
      if(secs>0)
        {
         expiry=TimeCurrent()+(long)expiryBars*secs;
         timeType=ORDER_TIME_SPECIFIED;
        }
     }
   bool ok=false;
   int  attempt=0;

   for(attempt=0; attempt<=m_maxRetries; attempt++)
     {
      //--- filling comes from the CSymbolSpec BITMASK decode, walking the
      //--- fallback list on each 10030
      ApplyFilling(specIndex,attempt,true);

      ok=m_trade.OrderOpen(symbol,type,volume,0.0,entry,sl,tp,timeType,expiry,comment);
      uint rc=m_trade.ResultRetcode();

      if(ok && (rc==TRADE_RETCODE_DONE || rc==TRADE_RETCODE_PLACED))
         break;

      if(!IsRetryable(rc))
         break;

      if(m_verbose)
         PrintFormat("[CTradeExec] %s attempt %d retcode %u (%s), retrying",
                     symbol,attempt+1,rc,RetcodeText(rc));

      //--- refresh the level against moved prices before the next try
      ask=SymbolInfoDouble(symbol,SYMBOL_ASK);
      bid=SymbolInfoDouble(symbol,SYMBOL_BID);
     }

   CaptureResult(ok,attempt+1);

   if(m_verbose || !ok)
      Print("[CTradeExec] ",DescribeLast());

   return(m_last.success);
  }

//+------------------------------------------------------------------+
bool CTradeExec::OpenMarket(const int specIndex,const ENUM_SEA_DIRECTION dir,
                            const double stopLoss,const double takeProfit,
                            const double lots,const string comment)
  {
   ResetResult(0.0,lots);

   if(m_spec==NULL || !m_spec.IsValid(specIndex))
     {
      m_last.detail="spec invalid";
      return(false);
     }
   if(stopLoss<=0.0)
     {
      m_last.detail="refused: no stop loss supplied";
      Print("[CTradeExec] REFUSED market entry without a stop loss - RULE 6");
      return(false);
     }

   const string symbol=m_spec.Name(specIndex);
   double volume=m_spec.NormalizeVolume(specIndex,lots);
   if(volume<=0.0)
     {
      m_last.detail="volume normalized to zero";
      return(false);
     }

   double sl=m_spec.NormalizePrice(specIndex,stopLoss);
   double tp=(takeProfit>0.0 ? m_spec.NormalizePrice(specIndex,takeProfit) : 0.0);

   bool ok=false;
   int  attempt=0;

   for(attempt=0; attempt<=m_maxRetries; attempt++)
     {
      ApplyFilling(specIndex,attempt,false);

      double price=(dir==SEA_DIR_LONG ? SymbolInfoDouble(symbol,SYMBOL_ASK)
                    : SymbolInfoDouble(symbol,SYMBOL_BID));
      m_last.requestedPrice=price;

      if(dir==SEA_DIR_LONG)
         ok=m_trade.Buy(volume,symbol,price,sl,tp,comment);
      else
         ok=m_trade.Sell(volume,symbol,price,sl,tp,comment);

      uint rc=m_trade.ResultRetcode();
      if(ok && rc==TRADE_RETCODE_DONE)
         break;
      if(!IsRetryable(rc))
         break;

      if(m_verbose)
         PrintFormat("[CTradeExec] %s market attempt %d retcode %u (%s), retrying",
                     symbol,attempt+1,rc,RetcodeText(rc));
     }

   CaptureResult(ok,attempt+1);

   if(m_verbose || !ok)
      Print("[CTradeExec] ",DescribeLast());

   return(m_last.success);
  }

//+------------------------------------------------------------------+
//| Modify a position. Refuses to widen a stop.                       |
//+------------------------------------------------------------------+
bool CTradeExec::ModifyPosition(const ulong ticket,const double newStop,const double newTarget)
  {
   ResetResult(0.0,0.0);

   if(!m_position.SelectByTicket(ticket))
     {
      m_last.detail="position not found";
      return(false);
     }
   if(m_position.Magic()!=m_magic)
     {
      m_last.detail="position carries another magic number";
      return(false);
     }

   double current=m_position.StopLoss();

   //--- NEVER widen an existing stop
   if(current>0.0 && newStop>0.0)
     {
      bool isLong=(m_position.PositionType()==POSITION_TYPE_BUY);
      bool wider =(isLong ? (newStop<current) : (newStop>current));
      if(wider)
        {
         m_last.detail=StringFormat("refused: would widen the stop from %s to %s",
                                    DoubleToString(current,8),DoubleToString(newStop,8));
         if(m_verbose)
            Print("[CTradeExec] ",m_last.detail);
         return(false);
        }
     }

   //--- the stop must sit on the correct side of the CURRENT price.
   //--- a stop beyond the entry is legitimate once a trade is in profit
   //--- (break-even, then trailing), so entry is not the reference here.
   if(newStop>0.0)
     {
      bool isLong=(m_position.PositionType()==POSITION_TYPE_BUY);
      if(isLong)
        {
         double bid=SymbolInfoDouble(m_position.Symbol(),SYMBOL_BID);
         if(newStop>=bid)
           {
            m_last.detail="refused: long stop at or above the current bid";
            return(false);
           }
        }
      else
        {
         double ask=SymbolInfoDouble(m_position.Symbol(),SYMBOL_ASK);
         if(newStop<=ask)
           {
            m_last.detail="refused: short stop at or below the current ask";
            return(false);
           }
        }
     }

   bool ok=m_trade.PositionModify(ticket,newStop,newTarget);
   CaptureResult(ok,1);

   if(!ok && m_verbose)
      Print("[CTradeExec] modify failed: ",DescribeLast());

   return(ok);
  }

//+------------------------------------------------------------------+
bool CTradeExec::ClosePosition(const ulong ticket,const string reason)
  {
   ResetResult(0.0,0.0);

   if(!m_position.SelectByTicket(ticket))
     {
      m_last.detail="position not found";
      return(false);
     }
   if(m_position.Magic()!=m_magic)
     {
      m_last.detail="position carries another magic number";
      return(false);
     }

   m_last.requestedVolume=m_position.Volume();

   bool ok=false;
   int  attempt=0;
   for(attempt=0; attempt<=m_maxRetries; attempt++)
     {
      ok=m_trade.PositionClose(ticket,m_maxDeviation);
      uint rc=m_trade.ResultRetcode();
      if(ok && rc==TRADE_RETCODE_DONE)
         break;
      if(!IsRetryable(rc))
         break;
     }

   CaptureResult(ok,attempt+1);
   m_last.detail=reason;

   if(m_verbose || !ok)
      PrintFormat("[CTradeExec] close #%I64u (%s): %s",ticket,reason,DescribeLast());

   return(ok);
  }

//+------------------------------------------------------------------+
bool CTradeExec::ClosePartial(const int specIndex,const ulong ticket,const double volume,
                              const string reason)
  {
   ResetResult(0.0,volume);

   if(!m_position.SelectByTicket(ticket))
     {
      m_last.detail="position not found";
      return(false);
     }
   if(m_position.Magic()!=m_magic)
     {
      m_last.detail="position carries another magic number";
      return(false);
     }
   if(m_spec==NULL)
     {
      m_last.detail="spec cache unavailable";
      return(false);
     }

   double v=m_spec.NormalizeVolume(specIndex,volume);
   if(v<=0.0)
     {
      m_last.detail="partial volume normalized to zero - not taken";
      return(false);
     }

   //--- leaving a remainder below the broker minimum would strand the
   //--- position, so close it in full instead
   double remainder=m_position.Volume()-v;
   if(remainder>0.0 && remainder<m_spec.VolumeMin(specIndex))
      return(ClosePosition(ticket,reason+" (remainder below minimum, closed in full)"));

   bool ok=m_trade.PositionClosePartial(ticket,v,m_maxDeviation);
   CaptureResult(ok,1);
   m_last.detail=reason;

   if(m_verbose || !ok)
      PrintFormat("[CTradeExec] partial close #%I64u (%s): %s",ticket,reason,DescribeLast());

   return(ok);
  }

//+------------------------------------------------------------------+
bool CTradeExec::CancelOrder(const ulong ticket,const string reason)
  {
   ResetResult(0.0,0.0);

   if(!m_order.Select(ticket))
     {
      m_last.detail="order not found";
      return(false);
     }
   if(m_order.Magic()!=m_magic)
     {
      m_last.detail="order carries another magic number";
      return(false);
     }

   bool ok=m_trade.OrderDelete(ticket);
   CaptureResult(ok,1);
   m_last.detail=reason;

   if(m_verbose || !ok)
      PrintFormat("[CTradeExec] cancel #%I64u (%s): %s",ticket,reason,DescribeLast());

   return(ok);
  }

//+------------------------------------------------------------------+
int CTradeExec::CloseAllForSymbol(const string symbol,const string reason)
  {
   int closed=0;
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(!m_position.SelectByTicket(ticket))
         continue;
      //--- RULE 5: magic AND symbol
      if(m_position.Magic()!=m_magic || m_position.Symbol()!=symbol)
         continue;
      if(ClosePosition(ticket,reason))
         closed++;
     }
   return(closed);
  }

//+------------------------------------------------------------------+
int CTradeExec::CloseAll(const string reason)
  {
   int closed=0;
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(!m_position.SelectByTicket(ticket))
         continue;
      if(m_position.Magic()!=m_magic)
         continue;
      if(ClosePosition(ticket,reason))
         closed++;
     }
   return(closed);
  }

//+------------------------------------------------------------------+
int CTradeExec::CancelAllPendings(const string reason)
  {
   int cancelled=0;
   for(int i=OrdersTotal()-1; i>=0; i--)
     {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0)
         continue;
      if(!m_order.Select(ticket))
         continue;
      if(m_order.Magic()!=m_magic)
         continue;
      if(CancelOrder(ticket,reason))
         cancelled++;
     }
   return(cancelled);
  }

//+------------------------------------------------------------------+
int CTradeExec::PositionCount(const string symbol) const
  {
   int n=0;
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC)!=m_magic)
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=symbol)
         continue;
      n++;
     }
   return(n);
  }

//+------------------------------------------------------------------+
int CTradeExec::TotalPositions(void) const
  {
   int n=0;
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC)!=m_magic)
         continue;
      n++;
     }
   return(n);
  }

//+------------------------------------------------------------------+
int CTradeExec::PendingCount(const string symbol) const
  {
   int n=0;
   for(int i=OrdersTotal()-1; i>=0; i--)
     {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0)
         continue;
      if(OrderGetInteger(ORDER_MAGIC)!=m_magic)
         continue;
      if(OrderGetString(ORDER_SYMBOL)!=symbol)
         continue;
      n++;
     }
   return(n);
  }

//+------------------------------------------------------------------+
ulong CTradeExec::PositionTicket(const string symbol,const int index) const
  {
   int seen=0;
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC)!=m_magic)
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=symbol)
         continue;
      if(seen==index)
         return(ticket);
      seen++;
     }
   return(0);
  }

//+------------------------------------------------------------------+
double CTradeExec::SymbolVolume(const string symbol) const
  {
   double v=0.0;
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC)!=m_magic)
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=symbol)
         continue;
      v+=PositionGetDouble(POSITION_VOLUME);
     }
   return(v);
  }

//+------------------------------------------------------------------+
//| Retcode meanings, with the ones the architecture calls out named  |
//| explicitly and their usual cause spelled out.                     |
//+------------------------------------------------------------------+
string CTradeExec::RetcodeText(const uint retcode) const
  {
   switch(retcode)
     {
      case TRADE_RETCODE_DONE:            return("DONE");
      case TRADE_RETCODE_PLACED:          return("PLACED");
      case TRADE_RETCODE_DONE_PARTIAL:    return("PARTIAL FILL");
      case TRADE_RETCODE_REQUOTE:         return("10004 REQUOTE - price moved, retry");
      case TRADE_RETCODE_REJECT:          return("10006 REJECTED by dealer");
      case TRADE_RETCODE_ERROR:           return("10011 request processing error");
      case TRADE_RETCODE_TIMEOUT:         return("10012 TIMEOUT - outcome unknown, verify");
      case TRADE_RETCODE_INVALID:         return("10013 INVALID request");
      case TRADE_RETCODE_INVALID_VOLUME:  return("10014 INVALID VOLUME - check step and limits");
      case TRADE_RETCODE_INVALID_PRICE:   return("10015 INVALID PRICE");
      case TRADE_RETCODE_INVALID_STOPS:   return("10016 INVALID STOPS - inside the stops level");
      case TRADE_RETCODE_TRADE_DISABLED:  return("10017 trading disabled");
      case TRADE_RETCODE_MARKET_CLOSED:   return("10018 market closed");
      case TRADE_RETCODE_NO_MONEY:        return("10019 NO MONEY - margin insufficient");
      case TRADE_RETCODE_PRICE_CHANGED:   return("10020 price changed, retry");
      case TRADE_RETCODE_PRICE_OFF:       return("10021 NO PRICES - quotes stale, retry");
      case TRADE_RETCODE_INVALID_EXPIRATION: return("10022 invalid expiration");
      case TRADE_RETCODE_ORDER_CHANGED:   return("10023 order state changed");
      case TRADE_RETCODE_TOO_MANY_REQUESTS: return("10024 too many requests");
      case TRADE_RETCODE_NO_CHANGES:      return("10025 no changes in the request");
      case TRADE_RETCODE_SERVER_DISABLES_AT: return("10026 autotrading disabled by server");
      case TRADE_RETCODE_CLIENT_DISABLES_AT: return("10027 autotrading disabled by client");
      case TRADE_RETCODE_LOCKED:          return("10028 request locked");
      case TRADE_RETCODE_FROZEN:          return("10029 order or position frozen");
      case TRADE_RETCODE_INVALID_FILL:    return("10030 INVALID FILLING - mask tested wrongly or unsupported mode");
      case TRADE_RETCODE_CONNECTION:      return("10031 no connection");
      case TRADE_RETCODE_LIMIT_VOLUME:    return("10034 volume limit reached");
     }
   return(StringFormat("retcode %u",retcode));
  }

//+------------------------------------------------------------------+
string CTradeExec::DescribeLast(void) const
  {
   return(StringFormat("%s rc=%u (%s) order=%I64u deal=%I64u req=%s fill=%s slip=%.1fpts "
                       "volReq=%s volFill=%s attempts=%d %s",
                       (m_last.success ? "OK" : "FAIL"),
                       m_last.retcode,m_last.retcodeText,
                       m_last.orderTicket,m_last.dealTicket,
                       DoubleToString(m_last.requestedPrice,8),
                       DoubleToString(m_last.filledPrice,8),
                       m_last.slippagePoints,
                       DoubleToString(m_last.requestedVolume,4),
                       DoubleToString(m_last.filledVolume,4),
                       m_last.attempts,m_last.detail));
  }

#endif // SEA_CTRADEEXEC_MQH
//+------------------------------------------------------------------+
