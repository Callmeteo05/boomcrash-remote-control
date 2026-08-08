//+------------------------------------------------------------------+
//|                                                       CAlert.mqh  |
//|                                                                   |
//|   Module 20. Push and terminal notifications.                     |
//|                                                                   |
//|   NEVER call SendNotification in the tick hot path. Alerts are    |
//|   queued and flushed on the timer, because a push notification    |
//|   blocks and the tick budget is under one millisecond.            |
//|                                                                   |
//|   Halts bypass the throttle. Everything else respects it.         |
//+------------------------------------------------------------------+
#ifndef SEA_CALERT_MQH
#define SEA_CALERT_MQH

#include <SEA/SEA_Common.mqh>

#define SEA_ALERT_QUEUE 32

//+------------------------------------------------------------------+
//| Alert priority. Critical alerts bypass the throttle.              |
//+------------------------------------------------------------------+
enum ENUM_SEA_ALERT_PRIORITY
  {
   SEA_ALERT_INFO = 0,
   SEA_ALERT_TRADE,
   SEA_ALERT_CRITICAL
  };

//+------------------------------------------------------------------+
//| A queued message.                                                 |
//+------------------------------------------------------------------+
struct SAlertMessage
  {
   string                  text;
   ENUM_SEA_ALERT_PRIORITY priority;
   datetime                queuedAt;
   bool                    push;
   bool                    terminal;
  };

//+------------------------------------------------------------------+
//| CAlert                                                            |
//+------------------------------------------------------------------+
class CAlert
  {
private:
   SAlertMessage     m_queue[];
   int               m_count;

   int               m_minInterval;     // seconds between non-critical alerts
   datetime          m_lastSent;
   bool              m_pushEnabled;
   bool              m_terminalEnabled;
   bool              m_verbose;
   int               m_suppressed;

public:
                     CAlert(void);
                    ~CAlert(void);

   //! Configure.
   //!
   //! minInterval 0..600 seconds, default 30
   void              Configure(const int minInterval,const bool pushEnabled,
                               const bool terminalEnabled);

   //! Print diagnostics. Off by default.
   void              SetVerbose(const bool enabled) { m_verbose=enabled; }

   //! Queue a message. Safe to call from the tick path - it copies a
   //! string and returns. Nothing is sent here.
   bool              Queue(const string text,const ENUM_SEA_ALERT_PRIORITY priority);

   //! Send everything queued. Call from OnTimer, never from OnTick.
   //! Returns the number sent.
   int               Flush(void);

   //! Number of messages waiting.
   int               Pending(void) const { return m_count; }

   //! Messages dropped to the throttle since the last flush.
   int               Suppressed(void) const { return m_suppressed; }

   //--- composed alerts ---------------------------------------------------
   //! Full entry alert: everything the architecture asks for.
   void              EntryAlert(const SSetup &setup,const string topFactors,
                                const double drawdownPct,const double ddLimit,
                                const int legNumber);

   //! Risk halt alert. Always critical, always bypasses the throttle.
   void              HaltAlert(const ENUM_SEA_HALT halt,const string reason);

   //! Spike hazard reached EXTREME.
   void              HazardAlert(const string symbol,const double hazard);

   //! Consecutive-loss breaker armed.
   void              BreakerAlert(const int losses,const datetime until);

   //! Daily target or limit reached.
   void              DailyAlert(const string text);

   //! Gate-leak assertion: more trades today than the style permits.
   void              LeakAlert(const int tradesToday,const int styleMax);
  };

//+------------------------------------------------------------------+
CAlert::CAlert(void)
  {
   m_count           = 0;
   m_minInterval     = 30;
   m_lastSent        = 0;
   m_pushEnabled     = true;
   m_terminalEnabled = true;
   m_verbose         = false;
   m_suppressed      = 0;
   ArrayResize(m_queue,SEA_ALERT_QUEUE);
  }

//+------------------------------------------------------------------+
CAlert::~CAlert(void)
  {
   ArrayFree(m_queue);
  }

//+------------------------------------------------------------------+
void CAlert::Configure(const int minInterval,const bool pushEnabled,
                       const bool terminalEnabled)
  {
   m_minInterval     = (minInterval<0 ? 0 : (minInterval>600 ? 600 : minInterval));
   m_pushEnabled     = pushEnabled;
   m_terminalEnabled = terminalEnabled;
  }

//+------------------------------------------------------------------+
bool CAlert::Queue(const string text,const ENUM_SEA_ALERT_PRIORITY priority)
  {
   //--- Print ALWAYS, whatever the throttle says. The terminal log is
   //--- the record of record and must never be gapped.
   Print("[SEA] ",text);

   if(m_count>=SEA_ALERT_QUEUE)
     {
      //--- a critical message evicts the oldest non-critical one rather
      //--- than being dropped
      if(priority!=SEA_ALERT_CRITICAL)
        {
         m_suppressed++;
         return(false);
        }

      int victim=-1;
      for(int i=0; i<m_count; i++)
         if(m_queue[i].priority!=SEA_ALERT_CRITICAL)
           {
            victim=i;
            break;
           }
      if(victim<0)
         return(false);

      for(int i=victim; i<m_count-1; i++)
         m_queue[i]=m_queue[i+1];
      m_count--;
      m_suppressed++;
     }

   m_queue[m_count].text     = text;
   m_queue[m_count].priority = priority;
   m_queue[m_count].queuedAt = TimeCurrent();
   m_queue[m_count].push     = m_pushEnabled;
   m_queue[m_count].terminal = m_terminalEnabled;
   m_count++;
   return(true);
  }

//+------------------------------------------------------------------+
int CAlert::Flush(void)
  {
   if(m_count<=0)
      return(0);

   int sent=0;
   int kept=0;

   for(int i=0; i<m_count; i++)
     {
      bool critical=(m_queue[i].priority==SEA_ALERT_CRITICAL);

      //--- throttle, bypassed by critical messages
      if(!critical && m_minInterval>0 &&
         m_lastSent>0 && (TimeCurrent()-m_lastSent)<m_minInterval)
        {
         //--- keep it queued for the next flush rather than dropping it
         m_queue[kept]=m_queue[i];
         kept++;
         continue;
        }

      if(m_queue[i].terminal)
         Alert(m_queue[i].text);

      if(m_queue[i].push)
         SendNotification(m_queue[i].text);

      m_lastSent=TimeCurrent();
      sent++;
     }

   m_count=kept;

   if(m_verbose && sent>0)
      PrintFormat("[CAlert] flushed %d, %d still queued, %d suppressed",
                  sent,m_count,m_suppressed);

   m_suppressed=0;
   return(sent);
  }

//+------------------------------------------------------------------+
void CAlert::EntryAlert(const SSetup &setup,const string topFactors,
                        const double drawdownPct,const double ddLimit,
                        const int legNumber)
  {
   string text=StringFormat(
                  "ENTRY %s %s\n"
                  "entry %s  lots %s\n"
                  "SL %s  TP %s  RR %.2f\n"
                  "risk %.2f (%.2f%%)\n"
                  "probability %.0f (%s)\n"
                  "top: %s\n"
                  "phase %s  regime %s  MTF %+d\n"
                  "invalidation %s\n"
                  "DD %.2f%% of %.2f%%  leg %d",
                  setup.symbol,SeaDirectionToString(setup.direction),
                  DoubleToString(setup.entryPrice,8),
                  DoubleToString(setup.lots,4),
                  DoubleToString(setup.stopPrice,8),
                  DoubleToString(setup.targetPrice,8),
                  setup.rr,
                  setup.riskMoney,setup.riskPercent,
                  setup.probability,
                  (setup.reversalHypothesis ? "reversal" : "breakout"),
                  topFactors,
                  SeaPhaseToString(setup.phase),
                  SeaRegimeToString(setup.regime),
                  setup.mtfAlignment,
                  DoubleToString(setup.stopPrice,8),
                  drawdownPct,ddLimit,legNumber);

   Queue(text,SEA_ALERT_TRADE);
  }

//+------------------------------------------------------------------+
void CAlert::HaltAlert(const ENUM_SEA_HALT halt,const string reason)
  {
   string name;
   switch(halt)
     {
      case SEA_HALT_SOFT:    name="SOFT HALT";               break;
      case SEA_HALT_DAILY:   name="DAILY LIMIT";             break;
      case SEA_HALT_HARD:    name="HARD HALT - MANUAL RESET REQUIRED"; break;
      case SEA_HALT_BREAKER: name="CONSECUTIVE-LOSS BREAKER"; break;
      default:               name="HALT CLEARED";            break;
     }

   Queue(StringFormat("%s\n%s",name,reason),SEA_ALERT_CRITICAL);
  }

//+------------------------------------------------------------------+
void CAlert::HazardAlert(const string symbol,const double hazard)
  {
   Queue(StringFormat("SPIKE HAZARD EXTREME\n%s hazard %.2f\n"
                      "counter-spike positions flat, with-spike setups armed",
                      symbol,hazard),
         SEA_ALERT_CRITICAL);
  }

//+------------------------------------------------------------------+
void CAlert::BreakerAlert(const int losses,const datetime until)
  {
   Queue(StringFormat("CONSECUTIVE-LOSS BREAKER\n%d losses in a row\n"
                      "new entries paused until %s",
                      losses,TimeToString(until,TIME_DATE|TIME_MINUTES)),
         SEA_ALERT_CRITICAL);
  }

//+------------------------------------------------------------------+
void CAlert::DailyAlert(const string text)
  {
   Queue(text,SEA_ALERT_CRITICAL);
  }

//+------------------------------------------------------------------+
void CAlert::LeakAlert(const int tradesToday,const int styleMax)
  {
   Queue(StringFormat("GATE LEAK SUSPECTED\n%d trades today against a style maximum of %d\n"
                      "a gate is not holding - inspect the journal",
                      tradesToday,styleMax),
         SEA_ALERT_CRITICAL);
  }

#endif // SEA_CALERT_MQH
//+------------------------------------------------------------------+
