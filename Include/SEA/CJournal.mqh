//+------------------------------------------------------------------+
//|                                                     CJournal.mqh  |
//|                                                                   |
//|   Module 21. Trade and rejection logging.                         |
//|                                                                   |
//|   IF THE JOURNAL CANNOT EXPLAIN A TRADE STRUCTURALLY, THAT IS A   |
//|   BUG. Every accepted trade records the structural event that      |
//|   triggered it, the zone it came from, and the full confluence     |
//|   breakdown.                                                       |
//|                                                                   |
//|   Rejections matter as much as fills. Every rejected setup is      |
//|   logged with its full gate results and revisited 20 bars later to |
//|   record whether it would have hit target or stop - that is how    |
//|   we learn which gate is earning its keep and which is costing.    |
//+------------------------------------------------------------------+
#ifndef SEA_CJOURNAL_MQH
#define SEA_CJOURNAL_MQH

#include <SEA/SEA_Common.mqh>
#include <SEA/CGates.mqh>

#define SEA_JOURNAL_TRADES     "sea_trades.csv"
#define SEA_JOURNAL_REJECTIONS "sea_rejections.csv"
#define SEA_MAX_PENDING_REVIEW 128

//+------------------------------------------------------------------+
//| A rejection awaiting its 20-bar follow-up.                        |
//+------------------------------------------------------------------+
struct SPendingReview
  {
   string             symbol;
   ENUM_TIMEFRAMES    timeframe;
   ENUM_SEA_DIRECTION direction;
   datetime           rejectedAt;
   double             entryPrice;
   double             stopPrice;
   double             targetPrice;
   double             score;
   double             threshold;
   string             gateMask;
   string             firstFailure;
   int                barsToReview;
   bool               reviewed;
  };

//+------------------------------------------------------------------+
//| Weekly aggregate.                                                 |
//+------------------------------------------------------------------+
struct SJournalSummary
  {
   int               tradesTaken;
   int               tradesWon;
   int               tradesLost;
   double            totalR;
   int               rejections;
   int               rejectionsByGate[10];
   int               rejectedWouldHaveWon;
   int               acceptedButLost;
  };

//+------------------------------------------------------------------+
//| CJournal                                                          |
//+------------------------------------------------------------------+
class CJournal
  {
private:
   SPendingReview    m_pending[];
   int               m_pendingCount;
   SJournalSummary   m_summary;

   int               m_reviewBars;      // bars before a rejection is reviewed
   bool              m_tradeHeaderDone;
   bool              m_rejectHeaderDone;
   bool              m_verbose;

   int               m_tradesToday;
   datetime          m_dayStamp;

   bool              EnsureTradeHeader(void);
   bool              EnsureRejectHeader(void);

public:
                     CJournal(void);
                    ~CJournal(void);

   //! Configure.
   //! reviewBars 5..200, default 20
   void              Configure(const int reviewBars);

   //! Print diagnostics. Off by default.
   void              SetVerbose(const bool enabled) { m_verbose=enabled; }

   //--- trades -------------------------------------------------------------
   //! Log an accepted trade at fill.
   //!
   //! Every argument here is a structural fact. If a caller cannot
   //! supply one, the trade should not have been taken.
   bool              LogTrade(const SSetup &setup,const double requestedPrice,
                              const double filledPrice,const double slippagePoints,
                              const int legNumber,const string structuralEvent);

   //! Log a closed trade's outcome.
   bool              LogOutcome(const string symbol,const ulong ticket,
                                const double profit,const double rMultiple,
                                const double mae,const double mfe,
                                const string exitReason);

   //--- rejections -----------------------------------------------------------
   //! Log a rejected setup with its full gate results, and schedule the
   //! 20-bar follow-up.
   bool              LogRejection(const string symbol,const ENUM_TIMEFRAMES tf,
                                  const ENUM_SEA_DIRECTION dir,
                                  const double entry,const double stop,const double target,
                                  const double score,const double threshold,
                                  const SGateResult &gates,CGates &gateEngine);

   //! Revisit rejections whose review window has elapsed and record
   //! whether they would have hit target or stop.
   //! Call on execution-timeframe bar close.
   int               ProcessReviews(void);

   //! Rejections waiting for review.
   int               PendingReviews(void) const { return m_pendingCount; }

   //--- assertions -------------------------------------------------------------
   //! Note a trade for the daily count. Returns the count for today.
   int               NoteTradeToday(void);

   //! Trades taken today.
   int               TradesToday(void) const { return m_tradesToday; }

   //! ASSERTION: more trades today than the style permits means a gate
   //! is leaking. Returns true when the assertion fires.
   bool              AssertDailyLimit(const int styleMax) const;

   //--- summary -----------------------------------------------------------------
   //! Running summary.
   SJournalSummary   Summary(void) const { return m_summary; }

   //! Write the weekly summary to the terminal log.
   void              WriteWeeklySummary(CGates &gateEngine) const;

   //! Reset the running summary.
   void              ResetSummary(void);
  };

//+------------------------------------------------------------------+
CJournal::CJournal(void)
  {
   m_pendingCount     = 0;
   m_reviewBars       = 20;
   m_tradeHeaderDone  = false;
   m_rejectHeaderDone = false;
   m_verbose          = false;
   m_tradesToday      = 0;
   m_dayStamp         = 0;

   ArrayResize(m_pending,SEA_MAX_PENDING_REVIEW);
   ResetSummary();
  }

//+------------------------------------------------------------------+
CJournal::~CJournal(void)
  {
   ArrayFree(m_pending);
  }

//+------------------------------------------------------------------+
void CJournal::Configure(const int reviewBars)
  {
   m_reviewBars=(reviewBars<5 ? 5 : (reviewBars>200 ? 200 : reviewBars));
  }

//+------------------------------------------------------------------+
void CJournal::ResetSummary(void)
  {
   m_summary.tradesTaken          = 0;
   m_summary.tradesWon            = 0;
   m_summary.tradesLost           = 0;
   m_summary.totalR               = 0.0;
   m_summary.rejections           = 0;
   m_summary.rejectedWouldHaveWon = 0;
   m_summary.acceptedButLost      = 0;
   for(int i=0; i<10; i++)
      m_summary.rejectionsByGate[i]=0;
  }

//+------------------------------------------------------------------+
bool CJournal::EnsureTradeHeader(void)
  {
   if(m_tradeHeaderDone)
      return(true);

   if(FileIsExist(SEA_JOURNAL_TRADES))
     {
      m_tradeHeaderDone=true;
      return(true);
     }

   int h=FileOpen(SEA_JOURNAL_TRADES,FILE_WRITE|FILE_CSV|FILE_ANSI,',');
   if(h==INVALID_HANDLE)
      return(false);

   FileWrite(h,"time","symbol","direction","structural_event","zone_type","zone_origin",
             "trigger","break_type","phase","regime","mtf_alignment","probability",
             "hypothesis","margin","score","breakdown","invalidation",
             "entry_requested","entry_filled","slippage_points","lots",
             "stop","target","rr","risk_money","risk_pct","leg");
   FileClose(h);

   m_tradeHeaderDone=true;
   return(true);
  }

//+------------------------------------------------------------------+
bool CJournal::EnsureRejectHeader(void)
  {
   if(m_rejectHeaderDone)
      return(true);

   if(FileIsExist(SEA_JOURNAL_REJECTIONS))
     {
      m_rejectHeaderDone=true;
      return(true);
     }

   int h=FileOpen(SEA_JOURNAL_REJECTIONS,FILE_WRITE|FILE_CSV|FILE_ANSI,',');
   if(h==INVALID_HANDLE)
      return(false);

   FileWrite(h,"time","symbol","direction","entry","stop","target",
             "score","threshold","gate_mask","first_failure",
             "gate_details","reviewed","would_have_hit");
   FileClose(h);

   m_rejectHeaderDone=true;
   return(true);
  }

//+------------------------------------------------------------------+
bool CJournal::LogTrade(const SSetup &setup,const double requestedPrice,
                        const double filledPrice,const double slippagePoints,
                        const int legNumber,const string structuralEvent)
  {
   if(!EnsureTradeHeader())
      return(false);

   //--- if the caller cannot name the structural event, that is the bug
   //--- this journal exists to catch. Log it loudly rather than hide it.
   string event=structuralEvent;
   if(event=="")
     {
      event="UNEXPLAINED - THIS IS A BUG";
      Print("[CJournal] WARNING: trade logged with no structural explanation. ",
            "A trade the journal cannot explain structurally is a bug.");
     }

   int h=FileOpen(SEA_JOURNAL_TRADES,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI,',');
   if(h==INVALID_HANDLE)
      return(false);
   FileSeek(h,0,SEEK_END);

   FileWrite(h,
             TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),
             setup.symbol,
             SeaDirectionToString(setup.direction),
             event,
             SeaZoneTypeToString(setup.zoneType),
             TimeToString(setup.zoneOriginTime,TIME_DATE|TIME_MINUTES),
             SeaTriggerToString(setup.trigger),
             (setup.breakType==SEA_BREAK_BOS ? "BOS" :
              (setup.breakType==SEA_BREAK_CHOCH ? "CHoCH" : "none")),
             SeaPhaseToString(setup.phase),
             SeaRegimeToString(setup.regime),
             setup.mtfAlignment,
             DoubleToString(setup.probability,1),
             (setup.reversalHypothesis ? "reversal" : "breakout"),
             DoubleToString(setup.hypothesisMargin,1),
             DoubleToString(setup.score,1),
             setup.scoreBreakdown,
             DoubleToString(setup.stopPrice,8),
             DoubleToString(requestedPrice,8),
             DoubleToString(filledPrice,8),
             DoubleToString(slippagePoints,1),
             DoubleToString(setup.lots,4),
             DoubleToString(setup.stopPrice,8),
             DoubleToString(setup.targetPrice,8),
             DoubleToString(setup.rr,2),
             DoubleToString(setup.riskMoney,2),
             DoubleToString(setup.riskPercent,3),
             legNumber);

   FileClose(h);

   m_summary.tradesTaken++;
   return(true);
  }

//+------------------------------------------------------------------+
bool CJournal::LogOutcome(const string symbol,const ulong ticket,
                          const double profit,const double rMultiple,
                          const double mae,const double mfe,
                          const string exitReason)
  {
   int h=FileOpen(SEA_JOURNAL_TRADES,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI,',');
   if(h==INVALID_HANDLE)
      return(false);
   FileSeek(h,0,SEEK_END);

   FileWrite(h,
             TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),
             symbol,"OUTCOME",
             StringFormat("ticket %I64u",ticket),
             "","","","","","",0,"","","",
             DoubleToString(rMultiple,3),
             exitReason,"","","",
             DoubleToString(profit,2),
             DoubleToString(mae,8),
             DoubleToString(mfe,8),
             "","","","",0);

   FileClose(h);

   if(profit>0.0)
      m_summary.tradesWon++;
   else
     {
      m_summary.tradesLost++;
      m_summary.acceptedButLost++;
     }
   m_summary.totalR+=rMultiple;

   return(true);
  }

//+------------------------------------------------------------------+
bool CJournal::LogRejection(const string symbol,const ENUM_TIMEFRAMES tf,
                            const ENUM_SEA_DIRECTION dir,
                            const double entry,const double stop,const double target,
                            const double score,const double threshold,
                            const SGateResult &gates,CGates &gateEngine)
  {
   if(!EnsureRejectHeader())
      return(false);

   string mask=gateEngine.CompactReport(gates);

   string details="";
   for(int i=0; i<10; i++)
      if(!gates.gates[i].passed)
        {
         details+=StringFormat("%s: %s | ",gates.gates[i].name,gates.gates[i].detail);
         m_summary.rejectionsByGate[i]++;
        }

   int h=FileOpen(SEA_JOURNAL_REJECTIONS,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI,',');
   if(h==INVALID_HANDLE)
      return(false);
   FileSeek(h,0,SEEK_END);

   FileWrite(h,
             TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),
             symbol,SeaDirectionToString(dir),
             DoubleToString(entry,8),
             DoubleToString(stop,8),
             DoubleToString(target,8),
             DoubleToString(score,1),
             DoubleToString(threshold,1),
             mask,gates.firstFailure,details,
             "pending","");

   FileClose(h);

   m_summary.rejections++;

   //--- schedule the follow-up
   if(m_pendingCount<SEA_MAX_PENDING_REVIEW)
     {
      m_pending[m_pendingCount].symbol       = symbol;
      m_pending[m_pendingCount].timeframe    = tf;
      m_pending[m_pendingCount].direction    = dir;
      m_pending[m_pendingCount].rejectedAt   = TimeCurrent();
      m_pending[m_pendingCount].entryPrice   = entry;
      m_pending[m_pendingCount].stopPrice    = stop;
      m_pending[m_pendingCount].targetPrice  = target;
      m_pending[m_pendingCount].score        = score;
      m_pending[m_pendingCount].threshold    = threshold;
      m_pending[m_pendingCount].gateMask     = mask;
      m_pending[m_pendingCount].firstFailure = gates.firstFailure;
      m_pending[m_pendingCount].barsToReview = m_reviewBars;
      m_pending[m_pendingCount].reviewed     = false;
      m_pendingCount++;
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| The follow-up that makes rejections informative.                  |
//|                                                                   |
//| For each rejection past its review window, replay the bars since   |
//| and record whether target or stop would have come first.           |
//+------------------------------------------------------------------+
int CJournal::ProcessReviews(void)
  {
   int reviewed=0;

   for(int i=m_pendingCount-1; i>=0; i--)
     {
      if(m_pending[i].reviewed)
         continue;

      //--- how many bars have closed since the rejection?
      int barsSince=iBarShift(m_pending[i].symbol,m_pending[i].timeframe,
                              m_pending[i].rejectedAt,false);
      if(barsSince<m_pending[i].barsToReview)
         continue;

      MqlRates r[];
      if(!SeaCopyRates(m_pending[i].symbol,m_pending[i].timeframe,
                       1,m_pending[i].barsToReview+1,r))
         continue;

      //--- walk forward from the rejection, oldest first
      string verdict="neither";
      for(int k=ArraySize(r)-1; k>=0; k--)
        {
         if(r[k].time<m_pending[i].rejectedAt)
            continue;

         if(m_pending[i].direction==SEA_DIR_LONG)
           {
            if(r[k].low<=m_pending[i].stopPrice)
              {
               verdict="stop";
               break;
              }
            if(m_pending[i].targetPrice>0.0 && r[k].high>=m_pending[i].targetPrice)
              {
               verdict="target";
               break;
              }
           }
         else
           {
            if(r[k].high>=m_pending[i].stopPrice)
              {
               verdict="stop";
               break;
              }
            if(m_pending[i].targetPrice>0.0 && r[k].low<=m_pending[i].targetPrice)
              {
               verdict="target";
               break;
              }
           }
        }

      if(verdict=="target")
         m_summary.rejectedWouldHaveWon++;

      //--- append the verdict as a review row
      int h=FileOpen(SEA_JOURNAL_REJECTIONS,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI,',');
      if(h!=INVALID_HANDLE)
        {
         FileSeek(h,0,SEEK_END);
         FileWrite(h,
                   TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),
                   m_pending[i].symbol,
                   SeaDirectionToString(m_pending[i].direction),
                   DoubleToString(m_pending[i].entryPrice,8),
                   DoubleToString(m_pending[i].stopPrice,8),
                   DoubleToString(m_pending[i].targetPrice,8),
                   DoubleToString(m_pending[i].score,1),
                   DoubleToString(m_pending[i].threshold,1),
                   m_pending[i].gateMask,
                   m_pending[i].firstFailure,
                   "REVIEW","reviewed",verdict);
         FileClose(h);
        }

      if(m_verbose)
         PrintFormat("[CJournal] review %s %s rejected on '%s' -> would have hit %s",
                     m_pending[i].symbol,
                     SeaDirectionToString(m_pending[i].direction),
                     m_pending[i].firstFailure,verdict);

      //--- release the slot
      int last=m_pendingCount-1;
      if(i!=last)
         m_pending[i]=m_pending[last];
      m_pendingCount--;
      reviewed++;
     }

   return(reviewed);
  }

//+------------------------------------------------------------------+
int CJournal::NoteTradeToday(void)
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(),dt);
   dt.hour=0;
   dt.min=0;
   dt.sec=0;
   datetime today=StructToTime(dt);

   if(today!=m_dayStamp)
     {
      m_dayStamp    = today;
      m_tradesToday = 0;
     }

   m_tradesToday++;
   return(m_tradesToday);
  }

//+------------------------------------------------------------------+
bool CJournal::AssertDailyLimit(const int styleMax) const
  {
   if(styleMax<=0)
      return(false);
   return(m_tradesToday>styleMax);
  }

//+------------------------------------------------------------------+
void CJournal::WriteWeeklySummary(CGates &gateEngine) const
  {
   Print("================ SEA WEEKLY SUMMARY ================");
   PrintFormat("trades taken   : %d  (won %d, lost %d)  total %.2fR",
               m_summary.tradesTaken,m_summary.tradesWon,
               m_summary.tradesLost,m_summary.totalR);
   PrintFormat("rejections     : %d",m_summary.rejections);
   PrintFormat("rejected but would have won : %d",m_summary.rejectedWouldHaveWon);
   PrintFormat("accepted but lost           : %d",m_summary.acceptedButLost);
   Print("-- rejections by failing gate --");
   for(int i=0; i<10; i++)
      PrintFormat("  %-26s %d",gateEngine.GateName(i),m_summary.rejectionsByGate[i]);
   Print("====================================================");
  }

#endif // SEA_CJOURNAL_MQH
//+------------------------------------------------------------------+
