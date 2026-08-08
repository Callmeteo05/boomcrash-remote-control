//+------------------------------------------------------------------+
//|                                                 CRiskManager.mqh  |
//|                                                                   |
//|   Module 2. Sizing, drawdown tracking, halts, persistence.        |
//|                                                                   |
//|   This module bounds the SIZE of a structural decision. It never  |
//|   overrides its DIRECTION.                                        |
//|                                                                   |
//|   Two hard rules it exists to enforce:                            |
//|     - risk responds to demonstrated edge, NEVER to a losing       |
//|       streak. There is no martingale path through this code.      |
//|     - a terminal restart must NOT reset the kill switch. State    |
//|       is restored in OnInit BEFORE the first OnTick.              |
//|                                                                   |
//|   Drawdown is measured on EQUITY, never balance.                  |
//+------------------------------------------------------------------+
#ifndef SEA_CRISKMANAGER_MQH
#define SEA_CRISKMANAGER_MQH

#include <SEA/SEA_Common.mqh>
#include <SEA/CSymbolSpec.mqh>

//--- GlobalVariable keys. Prefixed with the magic number at runtime so
//--- two instances of the EA never share state.
#define SEA_GV_HWM            "SEA_%d_HWM"
#define SEA_GV_DAYSTART       "SEA_%d_DAYSTART"
#define SEA_GV_DAYSTAMP       "SEA_%d_DAYSTAMP"
#define SEA_GV_INITIALBAL     "SEA_%d_INITBAL"
#define SEA_GV_HARDHALT       "SEA_%d_HARDHALT"
#define SEA_GV_LOSSSTREAK     "SEA_%d_LOSSES"
#define SEA_GV_BREAKERUNTIL   "SEA_%d_BREAKER"

//+------------------------------------------------------------------+
//| Rolling record of one closed trade, for the profit factor window. |
//+------------------------------------------------------------------+
struct STradeRecord
  {
   datetime          closeTime;
   double            profit;      // account currency, net
   double            rMultiple;   // outcome in R
  };

#define SEA_PF_WINDOW 20

//+------------------------------------------------------------------+
//| CRiskManager                                                      |
//+------------------------------------------------------------------+
class CRiskManager
  {
private:
   long              m_magic;
   bool              m_verbose;

   //--- limits
   double            m_maxDDPercent;        // static, from initial balance
   double            m_dailyDDPercent;      // from day-start equity
   double            m_softHaltFraction;    // 0.80 of either limit
   double            m_slippageBuffer;      // 0.5% closed before the limit
   int               m_maxConsecutiveLosses;
   int               m_breakerHours;
   double            m_marginFloor;         // refuse entry below this level %
   int               m_maxCurrencyExposure;
   double            m_microModeCeiling;
   double            m_maxMarginUtil;

   //--- state
   double            m_initialBalance;
   double            m_highWaterMark;
   double            m_dayStartEquity;
   datetime          m_dayStamp;
   bool              m_hardHalted;
   int               m_lossStreak;
   datetime          m_breakerUntil;
   ENUM_SEA_HALT     m_haltState;
   string            m_haltReason;

   //--- rolling performance
   STradeRecord      m_trades[];
   int               m_tradeCount;

   string            Key(const string pattern) const;
   double            LadderRisk(const double equity) const;
   double            ProfitFactor(void) const;
   datetime          BrokerDayStart(void) const;

public:
                     CRiskManager(void);
                    ~CRiskManager(void);

   //--- setup -----------------------------------------------------------
   //! Configure limits and restore persisted state.
   //!
   //! MUST be called from OnInit, BEFORE the first OnTick. A restart
   //! that skips this reopens a kill switch that was deliberately shut.
   //!
   //! maxDDPercent          3..10,  default 5.0
   //! dailyDDPercent        2..5,   default 3.0
   //! maxConsecutiveLosses  2..10,  default 4
   //! breakerHours          1..48,  default 4
   //! marginFloor           200..1000, default 400
   //! maxCurrencyExposure   1..10,  default 2
   //! microModeCeiling      0..1000, default 50
   //! maxMarginUtil         0.05..0.90, default 0.25
   bool              Init(const long magic,
                          const double maxDDPercent,const double dailyDDPercent,
                          const int maxConsecutiveLosses,const int breakerHours,
                          const double marginFloor,const int maxCurrencyExposure,
                          const double microModeCeiling,const double maxMarginUtil);

   //! Print diagnostics. Off by default.
   void              SetVerbose(const bool enabled) { m_verbose=enabled; }

   //! Persist every tracked value. Called after each state change.
   void              Persist(void) const;

   //! Restore persisted state. Called by Init.
   void              Restore(void);

   //! Clear the hard halt. MANUAL operation - never called by the EA
   //! itself. Exposed so a maintenance script can reset it deliberately.
   void              ManualResetHardHalt(void);

   //--- per-tick / per-bar --------------------------------------------
   //! Refresh drawdown state and evaluate halts. Cheap enough for the
   //! tick path: it reads account values and compares, nothing more.
   //! Returns the resulting halt state.
   ENUM_SEA_HALT     Evaluate(void);

   //--- queries ----------------------------------------------------------
   //! Current halt state.
   ENUM_SEA_HALT     HaltState(void) const { return m_haltState; }

   //! Human-readable reason for the current halt.
   string            HaltReason(void) const { return m_haltReason; }

   //! True when new entries are permitted. Open trades are unaffected.
   bool              EntriesAllowed(void) const;

   //! True when everything must be closed immediately.
   bool              MustFlatten(void) const { return m_haltState==SEA_HALT_HARD; }

   //! True when the account is below the micro-mode ceiling, where the
   //! binding constraint is margin rather than risk percentage.
   bool              IsMicroMode(void) const;

   //! Risk percentage currently in force, from the equity ladder and
   //! the rolling profit factor.
   double            CurrentRiskPercent(void) const;

   //! Equity at the last evaluation.
   double            Equity(void) const { return AccountInfoDouble(ACCOUNT_EQUITY); }

   //! Drawdown from the high-water mark, as a percentage.
   double            DrawdownPercent(void) const;

   //! Drawdown from day-start equity, as a percentage.
   double            DailyDrawdownPercent(void) const;

   //! Consecutive losses recorded.
   int               LossStreak(void) const { return m_lossStreak; }

   //--- sizing ------------------------------------------------------------
   //! Position size for a structural stop.
   //!
   //!   lots = (Equity * Risk%) / (stopPriceDistance * valuePerPriceUnit)
   //!
   //! Rounded DOWN to VOLUME_STEP and clamped. Returns 0.0 when the
   //! trade cannot be taken at all - the caller must treat 0.0 as a
   //! rejection and never substitute a minimum lot.
   //!
   //! stopPriceDistance is in PRICE units, not points.
   double            CalculateLots(CSymbolSpec &spec,const int specIndex,
                                   const double stopPriceDistance,string &rejectReason);

   //! Maximum stop, in price units, affordable at the current equity
   //! and risk percentage for one VOLUME_MIN lot.
   double            AffordableStop(CSymbolSpec &spec,const int specIndex) const;

   //! Approve additional exposure for a scale-in.
   //! Returns false when the basket would exceed InpMaxBasketRisk or
   //! any halt is active.
   bool              ApproveExposure(const double existingRiskR,const double addedRiskR,
                                     const double maxBasketRiskR,string &rejectReason) const;

   //! Margin level check. Refuses entry below the configured floor.
   bool              MarginLevelOk(string &detail) const;

   //! Margin utilisation check for one candidate position.
   bool              MarginUtilisationOk(const string symbol,const double lots,
                                         const ENUM_ORDER_TYPE type,const double price,
                                         string &detail) const;

   //--- trade outcomes -----------------------------------------------------
   //! Record a closed trade. Updates the loss streak, the breaker and
   //! the rolling profit factor window.
   void              RecordTrade(const double profit,const double rMultiple);

   //! Rolling profit factor over the last SEA_PF_WINDOW trades.
   //! Returns 0.0 when the window is not yet full enough to mean much.
   double            RollingProfitFactor(void) const { return ProfitFactor(); }

   //--- diagnostics ---------------------------------------------------------
   //! Multi-line state dump.
   string            Describe(void) const;
  };

//+------------------------------------------------------------------+
CRiskManager::CRiskManager(void)
  {
   m_magic                = 0;
   m_verbose              = false;
   m_maxDDPercent         = 5.0;
   m_dailyDDPercent       = 3.0;
   m_softHaltFraction     = 0.80;
   m_slippageBuffer       = 0.5;
   m_maxConsecutiveLosses = 4;
   m_breakerHours         = 4;
   m_marginFloor          = 400.0;
   m_maxCurrencyExposure  = 2;
   m_microModeCeiling     = 50.0;
   m_maxMarginUtil        = 0.25;
   m_initialBalance       = 0.0;
   m_highWaterMark        = 0.0;
   m_dayStartEquity       = 0.0;
   m_dayStamp             = 0;
   m_hardHalted           = false;
   m_lossStreak           = 0;
   m_breakerUntil         = 0;
   m_haltState            = SEA_HALT_NONE;
   m_haltReason           = "";
   m_tradeCount           = 0;
   ArrayResize(m_trades,SEA_PF_WINDOW);
  }

//+------------------------------------------------------------------+
CRiskManager::~CRiskManager(void)
  {
   ArrayFree(m_trades);
  }

//+------------------------------------------------------------------+
string CRiskManager::Key(const string pattern) const
  {
   return(StringFormat(pattern,(int)m_magic));
  }

//+------------------------------------------------------------------+
bool CRiskManager::Init(const long magic,
                        const double maxDDPercent,const double dailyDDPercent,
                        const int maxConsecutiveLosses,const int breakerHours,
                        const double marginFloor,const int maxCurrencyExposure,
                        const double microModeCeiling,const double maxMarginUtil)
  {
   m_magic                = magic;
   m_maxDDPercent         = (maxDDPercent<3.0 ? 3.0 : (maxDDPercent>10.0 ? 10.0 : maxDDPercent));
   m_dailyDDPercent       = (dailyDDPercent<2.0 ? 2.0 : (dailyDDPercent>5.0 ? 5.0 : dailyDDPercent));
   m_maxConsecutiveLosses = (maxConsecutiveLosses<2 ? 2 : (maxConsecutiveLosses>10 ? 10 : maxConsecutiveLosses));
   m_breakerHours         = (breakerHours<1 ? 1 : (breakerHours>48 ? 48 : breakerHours));
   m_marginFloor          = (marginFloor<200.0 ? 200.0 : (marginFloor>1000.0 ? 1000.0 : marginFloor));
   m_maxCurrencyExposure  = (maxCurrencyExposure<1 ? 1 : (maxCurrencyExposure>10 ? 10 : maxCurrencyExposure));
   m_microModeCeiling     = (microModeCeiling<0.0 ? 0.0 : (microModeCeiling>1000.0 ? 1000.0 : microModeCeiling));
   m_maxMarginUtil        = (maxMarginUtil<0.05 ? 0.05 : (maxMarginUtil>0.90 ? 0.90 : maxMarginUtil));

   Restore();

   double equity=AccountInfoDouble(ACCOUNT_EQUITY);

   //--- first ever run on this account and magic
   if(m_initialBalance<=0.0)
     {
      m_initialBalance=AccountInfoDouble(ACCOUNT_BALANCE);
      if(m_initialBalance<=0.0)
         m_initialBalance=equity;
     }
   if(m_highWaterMark<=0.0)
      m_highWaterMark=equity;

   //--- roll the daily anchor if the broker day changed while we were down
   datetime dayStart=BrokerDayStart();
   if(m_dayStamp!=dayStart)
     {
      m_dayStamp       = dayStart;
      m_dayStartEquity = equity;
     }
   if(m_dayStartEquity<=0.0)
      m_dayStartEquity=equity;

   Persist();

   if(m_verbose)
      Print("[CRiskManager] ",Describe());

   //--- a restored hard halt is reported loudly, never silently cleared
   if(m_hardHalted)
      Print("[CRiskManager] HARD HALT restored from persistent state. ",
            "Manual reset required before this EA will trade again.");

   return(true);
  }

//+------------------------------------------------------------------+
datetime CRiskManager::BrokerDayStart(void) const
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(),dt);
   dt.hour=0;
   dt.min=0;
   dt.sec=0;
   return(StructToTime(dt));
  }

//+------------------------------------------------------------------+
void CRiskManager::Persist(void) const
  {
   GlobalVariableSet(Key(SEA_GV_HWM),m_highWaterMark);
   GlobalVariableSet(Key(SEA_GV_DAYSTART),m_dayStartEquity);
   GlobalVariableSet(Key(SEA_GV_DAYSTAMP),(double)m_dayStamp);
   GlobalVariableSet(Key(SEA_GV_INITIALBAL),m_initialBalance);
   GlobalVariableSet(Key(SEA_GV_HARDHALT),(m_hardHalted ? 1.0 : 0.0));
   GlobalVariableSet(Key(SEA_GV_LOSSSTREAK),(double)m_lossStreak);
   GlobalVariableSet(Key(SEA_GV_BREAKERUNTIL),(double)m_breakerUntil);
   GlobalVariablesFlush();
  }

//+------------------------------------------------------------------+
void CRiskManager::Restore(void)
  {
   if(GlobalVariableCheck(Key(SEA_GV_HWM)))
      m_highWaterMark=GlobalVariableGet(Key(SEA_GV_HWM));
   if(GlobalVariableCheck(Key(SEA_GV_DAYSTART)))
      m_dayStartEquity=GlobalVariableGet(Key(SEA_GV_DAYSTART));
   if(GlobalVariableCheck(Key(SEA_GV_DAYSTAMP)))
      m_dayStamp=(datetime)GlobalVariableGet(Key(SEA_GV_DAYSTAMP));
   if(GlobalVariableCheck(Key(SEA_GV_INITIALBAL)))
      m_initialBalance=GlobalVariableGet(Key(SEA_GV_INITIALBAL));
   if(GlobalVariableCheck(Key(SEA_GV_HARDHALT)))
      m_hardHalted=(GlobalVariableGet(Key(SEA_GV_HARDHALT))>0.5);
   if(GlobalVariableCheck(Key(SEA_GV_LOSSSTREAK)))
      m_lossStreak=(int)GlobalVariableGet(Key(SEA_GV_LOSSSTREAK));
   if(GlobalVariableCheck(Key(SEA_GV_BREAKERUNTIL)))
      m_breakerUntil=(datetime)GlobalVariableGet(Key(SEA_GV_BREAKERUNTIL));
  }

//+------------------------------------------------------------------+
void CRiskManager::ManualResetHardHalt(void)
  {
   m_hardHalted=false;
   m_haltState=SEA_HALT_NONE;
   m_haltReason="";
   m_highWaterMark=AccountInfoDouble(ACCOUNT_EQUITY);
   Persist();
   Print("[CRiskManager] Hard halt MANUALLY reset. High-water mark re-anchored.");
  }

//+------------------------------------------------------------------+
double CRiskManager::DrawdownPercent(void) const
  {
   if(m_initialBalance<=0.0)
      return(0.0);
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   //--- max DD is measured from the INITIAL BALANCE, statically, so a
   //--- winning run cannot quietly widen the permitted loss
   double dd=(m_initialBalance-equity)/m_initialBalance*100.0;
   return(dd>0.0 ? dd : 0.0);
  }

//+------------------------------------------------------------------+
double CRiskManager::DailyDrawdownPercent(void) const
  {
   if(m_dayStartEquity<=0.0)
      return(0.0);
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double dd=(m_dayStartEquity-equity)/m_dayStartEquity*100.0;
   return(dd>0.0 ? dd : 0.0);
  }

//+------------------------------------------------------------------+
ENUM_SEA_HALT CRiskManager::Evaluate(void)
  {
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);

   //--- roll the daily anchor at broker midnight
   datetime dayStart=BrokerDayStart();
   if(dayStart!=m_dayStamp)
     {
      m_dayStamp       = dayStart;
      m_dayStartEquity = equity;
      if(m_haltState==SEA_HALT_DAILY)
        {
         m_haltState  = SEA_HALT_NONE;
         m_haltReason = "";
         if(m_verbose)
            Print("[CRiskManager] daily halt auto-resumed at broker midnight");
        }
      Persist();
     }

   //--- high-water mark tracks equity upward only
   if(equity>m_highWaterMark)
     {
      m_highWaterMark=equity;
      Persist();
     }

   //--- a restored hard halt outranks everything
   if(m_hardHalted)
     {
      m_haltState  = SEA_HALT_HARD;
      m_haltReason = "max drawdown hard halt, manual reset required";
      return(m_haltState);
     }

   double dd      = DrawdownPercent();
   double dailyDD = DailyDrawdownPercent();

   //--- hard close fires slightly BEFORE the limit, to leave room for
   //--- slippage on the closing fills
   double hardTrigger=m_maxDDPercent-m_slippageBuffer;
   if(hardTrigger<0.5)
      hardTrigger=m_maxDDPercent*0.5;

   if(dd>=hardTrigger)
     {
      m_hardHalted = true;
      m_haltState  = SEA_HALT_HARD;
      m_haltReason = StringFormat("max drawdown %.2f%% reached the %.2f%% trigger",dd,hardTrigger);
      Persist();
      Print("[CRiskManager] HARD HALT: ",m_haltReason);
      return(m_haltState);
     }

   //--- consecutive-loss breaker
   if(m_breakerUntil>0 && TimeCurrent()<m_breakerUntil)
     {
      m_haltState  = SEA_HALT_BREAKER;
      m_haltReason = StringFormat("consecutive-loss breaker active until %s",
                                  TimeToString(m_breakerUntil,TIME_DATE|TIME_MINUTES));
      return(m_haltState);
     }
   if(m_breakerUntil>0 && TimeCurrent()>=m_breakerUntil)
     {
      m_breakerUntil=0;
      m_lossStreak=0;
      Persist();
     }

   //--- daily limit
   double dailyHardTrigger=m_dailyDDPercent-m_slippageBuffer;
   if(dailyHardTrigger<0.5)
      dailyHardTrigger=m_dailyDDPercent*0.5;

   if(dailyDD>=dailyHardTrigger)
     {
      m_haltState  = SEA_HALT_DAILY;
      m_haltReason = StringFormat("daily drawdown %.2f%% reached the %.2f%% trigger",
                                  dailyDD,dailyHardTrigger);
      return(m_haltState);
     }

   //--- soft halt at 80% of either limit: block entries, let runners run
   if(dd>=m_maxDDPercent*m_softHaltFraction ||
      dailyDD>=m_dailyDDPercent*m_softHaltFraction)
     {
      m_haltState  = SEA_HALT_SOFT;
      m_haltReason = StringFormat("soft halt: dd %.2f%% of %.2f%%, daily %.2f%% of %.2f%%",
                                  dd,m_maxDDPercent,dailyDD,m_dailyDDPercent);
      return(m_haltState);
     }

   m_haltState  = SEA_HALT_NONE;
   m_haltReason = "";
   return(m_haltState);
  }

//+------------------------------------------------------------------+
bool CRiskManager::EntriesAllowed(void) const
  {
   return(m_haltState==SEA_HALT_NONE);
  }

//+------------------------------------------------------------------+
bool CRiskManager::IsMicroMode(void) const
  {
   return(AccountInfoDouble(ACCOUNT_EQUITY)<m_microModeCeiling);
  }

//+------------------------------------------------------------------+
//| Equity ladder.                                                    |
//|   < $500      0.50%                                               |
//|   $500-2k     0.75%                                               |
//|   $2k-10k     1.00%                                               |
//|   > $10k      1.00%                                               |
//+------------------------------------------------------------------+
double CRiskManager::LadderRisk(const double equity) const
  {
   if(equity<500.0)
      return(0.50);
   if(equity<2000.0)
      return(0.75);
   return(1.00);
  }

//+------------------------------------------------------------------+
//| Rolling profit factor over the trade window.                      |
//+------------------------------------------------------------------+
double CRiskManager::ProfitFactor(void) const
  {
   if(m_tradeCount<5)
      return(0.0);   // not enough evidence to move risk either way

   double gross=0.0,loss=0.0;
   for(int i=0; i<m_tradeCount; i++)
     {
      if(m_trades[i].profit>0.0)
         gross+=m_trades[i].profit;
      else
         loss+=MathAbs(m_trades[i].profit);
     }

   if(loss<=0.0)
      return(gross>0.0 ? 99.0 : 0.0);
   return(gross/loss);
  }

//+------------------------------------------------------------------+
//| Risk percentage in force.                                         |
//|                                                                   |
//| The ladder sets the band. The rolling profit factor moves within  |
//| that band and NOWHERE ELSE. A losing streak does not raise risk -  |
//| there is no code path here that can.                              |
//+------------------------------------------------------------------+
double CRiskManager::CurrentRiskPercent(void) const
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double base   = LadderRisk(equity);

   //--- band around the ladder value: floor 60%, top 100%
   double floorRisk = base*0.60;
   double topRisk   = base;

   double pf=ProfitFactor();
   if(pf<=0.0)
      return(base*0.80);      // no evidence yet: sit mid-band

   if(pf>1.4)
      return(topRisk);
   if(pf<1.0)
      return(floorRisk);

   //--- linear between the two, on demonstrated edge only
   double t=(pf-1.0)/0.4;
   return(floorRisk+(topRisk-floorRisk)*t);
  }

//+------------------------------------------------------------------+
double CRiskManager::AffordableStop(CSymbolSpec &spec,const int specIndex) const
  {
   double pointValue=spec.PointValueAtMinVolume(specIndex);
   if(pointValue<=0.0)
      return(0.0);

   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double risk  =equity*CurrentRiskPercent()/100.0;
   return(risk/pointValue);
  }

//+------------------------------------------------------------------+
//| Position sizing.                                                  |
//+------------------------------------------------------------------+
double CRiskManager::CalculateLots(CSymbolSpec &spec,const int specIndex,
                                   const double stopPriceDistance,string &rejectReason)
  {
   rejectReason="";

   if(!spec.IsValid(specIndex))
     {
      rejectReason="symbol spec invalid";
      return(0.0);
     }
   if(stopPriceDistance<=0.0)
     {
      rejectReason="stop distance not positive";
      return(0.0);
     }
   if(!EntriesAllowed())
     {
      rejectReason="risk halt active: "+m_haltReason;
      return(0.0);
     }

   double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskPercent = CurrentRiskPercent();
   double riskMoney   = equity*riskPercent/100.0;

   double valuePerUnit=spec.ValuePerPriceUnit(specIndex);
   if(valuePerUnit<=0.0)
     {
      rejectReason="value per price unit unavailable";
      return(0.0);
     }

   //--- MICRO MODE: the binding constraint is margin, not risk percent.
   //--- Size is not a choice - it is VOLUME_MIN or nothing.
   if(IsMicroMode())
     {
      double minLots   = spec.VolumeMin(specIndex);
      double pointValue= spec.PointValueAtMinVolume(specIndex);
      if(pointValue<=0.0)
        {
         rejectReason="micro mode: point value unavailable";
         return(0.0);
        }

      double maxStop=riskMoney/pointValue;
      if(stopPriceDistance>maxStop)
        {
         rejectReason=StringFormat("stop exceeds micro budget (%s required, %s affordable)",
                                   DoubleToString(stopPriceDistance,8),
                                   DoubleToString(maxStop,8));
         return(0.0);
        }

      string marginDetail;
      if(!MarginUtilisationOk(spec.Name(specIndex),minLots,ORDER_TYPE_BUY,
                              SymbolInfoDouble(spec.Name(specIndex),SYMBOL_ASK),marginDetail))
        {
         rejectReason="micro mode: "+marginDetail;
         return(0.0);
        }

      return(minLots);
     }

   //--- normal sizing
   double raw=riskMoney/(stopPriceDistance*valuePerUnit);
   double lots=spec.NormalizeVolume(specIndex,raw);

   if(lots<=0.0)
     {
      rejectReason=StringFormat("computed %s lots, below broker minimum %s - "
                                "risk budget cannot fund this stop",
                                DoubleToString(raw,8),
                                DoubleToString(spec.VolumeMin(specIndex),8));
      return(0.0);
     }

   //--- margin sanity on the normalized size
   string detail;
   if(!MarginUtilisationOk(spec.Name(specIndex),lots,ORDER_TYPE_BUY,
                           SymbolInfoDouble(spec.Name(specIndex),SYMBOL_ASK),detail))
     {
      rejectReason=detail;
      return(0.0);
     }

   return(lots);
  }

//+------------------------------------------------------------------+
bool CRiskManager::MarginLevelOk(string &detail) const
  {
   detail="";
   double marginUsed=AccountInfoDouble(ACCOUNT_MARGIN);

   //--- no open margin means no margin-level constraint yet
   if(marginUsed<=0.0)
      return(true);

   double level=AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   if(level<=0.0)
      return(true);

   if(level<m_marginFloor)
     {
      detail=StringFormat("margin level %.1f%% below the %.1f%% floor",level,m_marginFloor);
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
bool CRiskManager::MarginUtilisationOk(const string symbol,const double lots,
                                       const ENUM_ORDER_TYPE type,const double price,
                                       string &detail) const
  {
   detail="";
   if(lots<=0.0 || price<=0.0)
     {
      detail="margin check: invalid lots or price";
      return(false);
     }

   double margin=0.0;
   if(!OrderCalcMargin(type,symbol,lots,price,margin))
     {
      detail=StringFormat("OrderCalcMargin failed, error %d",GetLastError());
      return(false);
     }

   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double cap=equity*m_maxMarginUtil;

   if(margin>cap)
     {
      detail=StringFormat("margin %.2f exceeds the %.0f%% utilisation cap (%.2f)",
                          margin,m_maxMarginUtil*100.0,cap);
      return(false);
     }

   string levelDetail;
   if(!MarginLevelOk(levelDetail))
     {
      detail=levelDetail;
      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
bool CRiskManager::ApproveExposure(const double existingRiskR,const double addedRiskR,
                                   const double maxBasketRiskR,string &rejectReason) const
  {
   rejectReason="";

   if(!EntriesAllowed())
     {
      rejectReason="risk halt active: "+m_haltReason;
      return(false);
     }

   double total=existingRiskR+addedRiskR;
   if(total>maxBasketRiskR)
     {
      rejectReason=StringFormat("basket risk %.2fR would exceed the %.2fR cap",
                                total,maxBasketRiskR);
      return(false);
     }

   string detail;
   if(!MarginLevelOk(detail))
     {
      rejectReason=detail;
      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Record a closed trade.                                            |
//|                                                                   |
//| A loss increments the streak and can arm the breaker. It NEVER    |
//| increases risk. That asymmetry is deliberate and load-bearing.    |
//+------------------------------------------------------------------+
void CRiskManager::RecordTrade(const double profit,const double rMultiple)
  {
   //--- rolling window, oldest evicted
   if(m_tradeCount<SEA_PF_WINDOW)
     {
      m_trades[m_tradeCount].closeTime = TimeCurrent();
      m_trades[m_tradeCount].profit    = profit;
      m_trades[m_tradeCount].rMultiple = rMultiple;
      m_tradeCount++;
     }
   else
     {
      for(int i=0; i<SEA_PF_WINDOW-1; i++)
         m_trades[i]=m_trades[i+1];
      m_trades[SEA_PF_WINDOW-1].closeTime = TimeCurrent();
      m_trades[SEA_PF_WINDOW-1].profit    = profit;
      m_trades[SEA_PF_WINDOW-1].rMultiple = rMultiple;
     }

   if(profit<0.0)
     {
      m_lossStreak++;
      if(m_lossStreak>=m_maxConsecutiveLosses)
        {
         m_breakerUntil=TimeCurrent()+(long)m_breakerHours*3600;
         Print(StringFormat("[CRiskManager] consecutive-loss breaker armed after %d losses, "
                            "paused until %s",
                            m_lossStreak,TimeToString(m_breakerUntil,TIME_DATE|TIME_MINUTES)));
        }
     }
   else
      m_lossStreak=0;

   Persist();
  }

//+------------------------------------------------------------------+
string CRiskManager::Describe(void) const
  {
   return(StringFormat("equity=%.2f initBal=%.2f hwm=%.2f dayStart=%.2f "
                       "dd=%.2f%%/%.2f%% daily=%.2f%%/%.2f%% risk=%.2f%% pf=%.2f "
                       "losses=%d halt=%s micro=%s",
                       AccountInfoDouble(ACCOUNT_EQUITY),m_initialBalance,
                       m_highWaterMark,m_dayStartEquity,
                       DrawdownPercent(),m_maxDDPercent,
                       DailyDrawdownPercent(),m_dailyDDPercent,
                       CurrentRiskPercent(),ProfitFactor(),
                       m_lossStreak,
                       (m_haltState==SEA_HALT_NONE ? "none" : m_haltReason),
                       (IsMicroMode() ? "yes" : "no")));
  }

#endif // SEA_CRISKMANAGER_MQH
//+------------------------------------------------------------------+
