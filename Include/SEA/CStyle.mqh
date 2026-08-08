//+------------------------------------------------------------------+
//|                                                       CStyle.mqh  |
//|                                                                   |
//|   Module 4. Trading style configuration.                          |
//|                                                                   |
//|   RULE 10: this is the ONLY file in the EA permitted to name a    |
//|   PERIOD_ constant. Every other module receives timeframes as     |
//|   ENUM_TIMEFRAMES parameters read from here.                      |
//|                                                                   |
//|   Style sets the CADENCE of the EA - which timeframes it reads,   |
//|   how wide its stops start, how many scale-ins it tolerates. It   |
//|   never sets direction.                                           |
//+------------------------------------------------------------------+
#ifndef SEA_CSTYLE_MQH
#define SEA_CSTYLE_MQH

#include <SEA/SEA_Common.mqh>

//+------------------------------------------------------------------+
//| Selectable trading styles.                                        |
//+------------------------------------------------------------------+
enum ENUM_SEA_STYLE
  {
   SEA_STYLE_SCALP = 0,
   SEA_STYLE_INTRADAY,
   SEA_STYLE_SWING,
   SEA_STYLE_AUTO
  };

//--- cascade depth is fixed at five levels for every style
#define SEA_CASCADE_LEVELS 5

//+------------------------------------------------------------------+
//| CStyle                                                            |
//|                                                                   |
//| Holds the resolved style and exposes every cadence parameter the  |
//| rest of the EA needs. AUTO resolves per symbol by measuring       |
//| spread/ATR, tick frequency and structural cleanliness at each     |
//| candidate style's execution timeframe.                            |
//+------------------------------------------------------------------+
class CStyle
  {
private:
   ENUM_SEA_STYLE    m_requested;      // what the user asked for
   ENUM_SEA_STYLE    m_resolved;       // what AUTO settled on, or the request
   ENUM_TIMEFRAMES   m_cascade[SEA_CASCADE_LEVELS];
   bool              m_verbose;

   void              BuildCascade(void);

public:
                     CStyle(void);
                    ~CStyle(void) {}

   //! Print diagnostics. Off by default.
   void              SetVerbose(const bool enabled) { m_verbose=enabled; }

   //! Set the requested style and rebuild the cascade.
   //! AUTO stays unresolved until ResolveAuto() runs for a symbol.
   void              SetStyle(const ENUM_SEA_STYLE style);

   //! The style the user requested, AUTO included.
   ENUM_SEA_STYLE    Requested(void) const { return m_requested; }

   //! The style actually in force. Never returns AUTO.
   ENUM_SEA_STYLE    Resolved(void) const { return m_resolved; }

   //! Numeric id used to key per-(symbol, style) profiles.
   int               StyleId(void) const { return (int)m_resolved; }

   //! Readable style name.
   string            Name(void) const;

   //--- cascade -------------------------------------------------------
   //! Number of timeframes in the cascade, highest first.
   int               CascadeLevels(void) const { return SEA_CASCADE_LEVELS; }

   //! Cascade timeframe at a level. Level 0 is the highest timeframe.
   ENUM_TIMEFRAMES   CascadeTF(const int level) const;

   //! Timeframe that sets directional bias.
   ENUM_TIMEFRAMES   BiasTF(void) const;

   //! Timeframe zones and candidate ranking run on.
   ENUM_TIMEFRAMES   ExecTF(void) const;

   //! Timeframe price action triggers are read from.
   ENUM_TIMEFRAMES   TriggerTF(void) const;

   //! Daily timeframe. CLiquidity needs it for PDH/PDL and cannot name
   //! a PERIOD_ constant itself under RULE 10.
   ENUM_TIMEFRAMES   DayTF(void) const { return PERIOD_D1; }

   //! Weekly timeframe, for PWH/PWL. Same reason as DayTF.
   ENUM_TIMEFRAMES   WeekTF(void) const { return PERIOD_W1; }

   //! Readable name of a timeframe, for logs and the dashboard.
   string            TFName(const ENUM_TIMEFRAMES tf) const;

   //! Seconds in one bar of a timeframe.
   int               TFSeconds(const ENUM_TIMEFRAMES tf) const;

   //--- cadence parameters --------------------------------------------
   //! Baseline stop distance in ATR multiples. The symbol profile
   //! overrides this once it has measured enough bars.
   double            StopATRMult(void) const;

   //! Maximum scale-in legs this style tolerates.
   int               MaxScaleIns(void) const;

   //! Spread ceiling as a fraction of the required stop.
   double            SpreadStopCap(void) const;

   //! Bars a pending entry survives before it is cancelled.
   int               PendingExpiryBars(void) const;

   //! Minimum bars of containment before a range counts as accumulation.
   int               AccumMinBars(void) const;

   //! Trades per day above which a gate is assumed to be leaking.
   int               MaxDailyAssert(void) const;

   //--- AUTO resolution ------------------------------------------------
   //! Score one style for a symbol. Higher is better.
   //! Inputs are measured, not assumed:
   //!   spreadOverATR  median spread / median ATR at that style's exec TF
   //!   ticksPerBar    average ticks observed per exec-TF bar
   //!   cleanliness    confirmed swings / fractal candidates, 0..1
   double            ScoreStyle(const ENUM_SEA_STYLE style,
                                const double spreadOverATR,
                                const double ticksPerBar,
                                const double cleanliness) const;

   //! Settle AUTO on the highest-scoring style and rebuild the cascade.
   //! Returns the style chosen. A no-op when the request is not AUTO.
   ENUM_SEA_STYLE    ResolveAuto(const double &spreadOverATR[],
                                 const double &ticksPerBar[],
                                 const double &cleanliness[]);

   //! One-line description of the resolved style.
   string            Describe(void) const;
  };

//+------------------------------------------------------------------+
CStyle::CStyle(void)
  {
   m_requested = SEA_STYLE_INTRADAY;
   m_resolved  = SEA_STYLE_INTRADAY;
   m_verbose   = false;
   BuildCascade();
  }

//+------------------------------------------------------------------+
void CStyle::SetStyle(const ENUM_SEA_STYLE style)
  {
   m_requested=style;
   //--- AUTO trades as INTRADAY until ResolveAuto measures a symbol
   m_resolved=(style==SEA_STYLE_AUTO ? SEA_STYLE_INTRADAY : style);
   BuildCascade();
   if(m_verbose)
      PrintFormat("[CStyle] %s",Describe());
  }

//+------------------------------------------------------------------+
//| Build the timeframe cascade for the resolved style.               |
//| Highest timeframe first.                                          |
//+------------------------------------------------------------------+
void CStyle::BuildCascade(void)
  {
   switch(m_resolved)
     {
      case SEA_STYLE_SCALP:
         m_cascade[0]=PERIOD_H4;
         m_cascade[1]=PERIOD_H1;
         m_cascade[2]=PERIOD_M15;
         m_cascade[3]=PERIOD_M5;
         m_cascade[4]=PERIOD_M1;
         break;

      case SEA_STYLE_SWING:
         m_cascade[0]=PERIOD_MN1;
         m_cascade[1]=PERIOD_W1;
         m_cascade[2]=PERIOD_D1;
         m_cascade[3]=PERIOD_H4;
         m_cascade[4]=PERIOD_H1;
         break;

      default: // INTRADAY
         m_cascade[0]=PERIOD_W1;
         m_cascade[1]=PERIOD_D1;
         m_cascade[2]=PERIOD_H4;
         m_cascade[3]=PERIOD_H1;
         m_cascade[4]=PERIOD_M15;
         break;
     }
  }

//+------------------------------------------------------------------+
string CStyle::Name(void) const
  {
   switch(m_resolved)
     {
      case SEA_STYLE_SCALP:    return("SCALP");
      case SEA_STYLE_INTRADAY: return("INTRADAY");
      case SEA_STYLE_SWING:    return("SWING");
     }
   return("AUTO");
  }

//+------------------------------------------------------------------+
ENUM_TIMEFRAMES CStyle::CascadeTF(const int level) const
  {
   if(level<0)
      return(m_cascade[0]);
   if(level>=SEA_CASCADE_LEVELS)
      return(m_cascade[SEA_CASCADE_LEVELS-1]);
   return(m_cascade[level]);
  }

//+------------------------------------------------------------------+
//| Bias timeframe: SCALP H1, INTRADAY H4, SWING D1.                  |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES CStyle::BiasTF(void) const
  {
   switch(m_resolved)
     {
      case SEA_STYLE_SCALP: return(PERIOD_H1);
      case SEA_STYLE_SWING: return(PERIOD_D1);
     }
   return(PERIOD_H4);
  }

//+------------------------------------------------------------------+
//| Execution timeframe: SCALP M5, INTRADAY M15, SWING H4.            |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES CStyle::ExecTF(void) const
  {
   switch(m_resolved)
     {
      case SEA_STYLE_SCALP: return(PERIOD_M5);
      case SEA_STYLE_SWING: return(PERIOD_H4);
     }
   return(PERIOD_M15);
  }

//+------------------------------------------------------------------+
//| Trigger timeframe: SCALP M1, INTRADAY M5, SWING H1.               |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES CStyle::TriggerTF(void) const
  {
   switch(m_resolved)
     {
      case SEA_STYLE_SCALP: return(PERIOD_M1);
      case SEA_STYLE_SWING: return(PERIOD_H1);
     }
   return(PERIOD_M5);
  }

//+------------------------------------------------------------------+
string CStyle::TFName(const ENUM_TIMEFRAMES tf) const
  {
   switch(tf)
     {
      case PERIOD_M1:  return("M1");
      case PERIOD_M5:  return("M5");
      case PERIOD_M15: return("M15");
      case PERIOD_M30: return("M30");
      case PERIOD_H1:  return("H1");
      case PERIOD_H4:  return("H4");
      case PERIOD_D1:  return("D1");
      case PERIOD_W1:  return("W1");
      case PERIOD_MN1: return("MN1");
     }
   return(EnumToString(tf));
  }

//+------------------------------------------------------------------+
int CStyle::TFSeconds(const ENUM_TIMEFRAMES tf) const
  {
   return(PeriodSeconds(tf));
  }

//+------------------------------------------------------------------+
//| Cadence parameters, per the style table.                          |
//+------------------------------------------------------------------+
double CStyle::StopATRMult(void) const
  {
   switch(m_resolved)
     {
      case SEA_STYLE_SCALP: return(1.5);
      case SEA_STYLE_SWING: return(4.0);
     }
   return(2.5);
  }

int CStyle::MaxScaleIns(void) const
  {
   switch(m_resolved)
     {
      case SEA_STYLE_SCALP: return(1);
      case SEA_STYLE_SWING: return(3);
     }
   return(2);
  }

double CStyle::SpreadStopCap(void) const
  {
   switch(m_resolved)
     {
      case SEA_STYLE_SCALP: return(0.08);
      case SEA_STYLE_SWING: return(0.25);
     }
   return(0.15);
  }

int CStyle::PendingExpiryBars(void) const
  {
   switch(m_resolved)
     {
      case SEA_STYLE_SCALP: return(3);
      case SEA_STYLE_SWING: return(8);
     }
   return(5);
  }

int CStyle::AccumMinBars(void) const
  {
   switch(m_resolved)
     {
      case SEA_STYLE_SCALP: return(12);
      case SEA_STYLE_SWING: return(30);
     }
   return(20);
  }

int CStyle::MaxDailyAssert(void) const
  {
   switch(m_resolved)
     {
      case SEA_STYLE_SCALP: return(20);
      case SEA_STYLE_SWING: return(3);
     }
   return(8);
  }

//+------------------------------------------------------------------+
//| Score a style for one symbol from measured statistics.            |
//|                                                                   |
//| Execution drag dominates: a style whose stops are small relative  |
//| to the spread cannot be afforded no matter how clean the chart.   |
//| Tick frequency matters only for the faster styles - a swing style |
//| does not care that a symbol is quiet between bars.                |
//+------------------------------------------------------------------+
double CStyle::ScoreStyle(const ENUM_SEA_STYLE style,
                          const double spreadOverATR,
                          const double ticksPerBar,
                          const double cleanliness) const
  {
   if(style==SEA_STYLE_AUTO)
      return(0.0);

   //--- required stop as a fraction of ATR for this style
   double stopMult;
   double minTicks;      // ticks per exec bar below which execution is unreliable
   switch(style)
     {
      case SEA_STYLE_SCALP:
         stopMult=1.5;
         minTicks=30.0;
         break;
      case SEA_STYLE_SWING:
         stopMult=4.0;
         minTicks=2.0;
         break;
      default:
         stopMult=2.5;
         minTicks=10.0;
         break;
     }

   //--- drag: spread as a fraction of the stop this style would use.
   //--- 0.0 is free, 1.0 means the spread eats the whole stop.
   double drag=(stopMult>0.0 ? spreadOverATR/stopMult : 1.0);
   if(drag<0.0)
      drag=0.0;
   if(drag>1.0)
      drag=1.0;

   double dragScore=(1.0-drag)*50.0;

   //--- liquidity: enough ticks per bar for a trigger to be real
   double tickScore=0.0;
   if(minTicks>0.0)
     {
      double ratio=ticksPerBar/minTicks;
      if(ratio>1.0)
         ratio=1.0;
      if(ratio<0.0)
         ratio=0.0;
      tickScore=ratio*25.0;
     }

   //--- cleanliness: how often a fractal candidate becomes a real swing
   double clean=cleanliness;
   if(clean<0.0)
      clean=0.0;
   if(clean>1.0)
      clean=1.0;
   double cleanScore=clean*25.0;

   return(dragScore+tickScore+cleanScore);
  }

//+------------------------------------------------------------------+
//| Settle AUTO on the best-scoring style.                            |
//|                                                                   |
//| The three input arrays are indexed by ENUM_SEA_STYLE ordinal:     |
//| [0] SCALP, [1] INTRADAY, [2] SWING.                               |
//+------------------------------------------------------------------+
ENUM_SEA_STYLE CStyle::ResolveAuto(const double &spreadOverATR[],
                                   const double &ticksPerBar[],
                                   const double &cleanliness[])
  {
   if(m_requested!=SEA_STYLE_AUTO)
      return(m_resolved);

   if(ArraySize(spreadOverATR)<3 || ArraySize(ticksPerBar)<3 || ArraySize(cleanliness)<3)
     {
      if(m_verbose)
         Print("[CStyle] ResolveAuto: incomplete measurements, holding INTRADAY");
      return(m_resolved);
     }

   ENUM_SEA_STYLE best=SEA_STYLE_INTRADAY;
   double         bestScore=-1.0;

   for(int s=0; s<3; s++)
     {
      ENUM_SEA_STYLE cand=(ENUM_SEA_STYLE)s;
      double sc=ScoreStyle(cand,spreadOverATR[s],ticksPerBar[s],cleanliness[s]);
      if(m_verbose)
         PrintFormat("[CStyle] AUTO candidate %d scored %.1f (drag=%.4f ticks=%.1f clean=%.2f)",
                     s,sc,spreadOverATR[s],ticksPerBar[s],cleanliness[s]);
      if(sc>bestScore)
        {
         bestScore=sc;
         best=cand;
        }
     }

   m_resolved=best;
   BuildCascade();

   if(m_verbose)
      PrintFormat("[CStyle] AUTO resolved to %s (score %.1f)",Name(),bestScore);

   return(m_resolved);
  }

//+------------------------------------------------------------------+
string CStyle::Describe(void) const
  {
   string cascade="";
   for(int i=0; i<SEA_CASCADE_LEVELS; i++)
     {
      cascade+=TFName(m_cascade[i]);
      if(i<SEA_CASCADE_LEVELS-1)
         cascade+=">";
     }

   return(StringFormat("style=%s cascade=%s bias=%s exec=%s trigger=%s "
                       "stopATR=%.1f maxLegs=%d spreadCap=%.2f expiry=%dbars "
                       "accumMin=%d dailyAssert=%d",
                       Name(),cascade,
                       TFName(BiasTF()),TFName(ExecTF()),TFName(TriggerTF()),
                       StopATRMult(),MaxScaleIns(),SpreadStopCap(),
                       PendingExpiryBars(),AccumMinBars(),MaxDailyAssert()));
  }

#endif // SEA_CSTYLE_MQH
//+------------------------------------------------------------------+
