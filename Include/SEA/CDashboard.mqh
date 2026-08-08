//+------------------------------------------------------------------+
//|                                                   CDashboard.mqh  |
//|                                                                   |
//|   Module 22. On-chart HUD.                                        |
//|                                                                   |
//|   Display only. The dashboard reads state and draws it. It never  |
//|   computes anything a decision depends on, and it never touches   |
//|   an order.                                                       |
//|                                                                   |
//|   Redrawn on the timer, never in the tick path.                   |
//+------------------------------------------------------------------+
#ifndef SEA_CDASHBOARD_MQH
#define SEA_CDASHBOARD_MQH

#include <SEA/SEA_Common.mqh>

#define SEA_HUD_PREFIX  "SEA_HUD_"
#define SEA_HUD_MAXROWS 28

//+------------------------------------------------------------------+
//| CDashboard                                                        |
//+------------------------------------------------------------------+
class CDashboard
  {
private:
   long              m_chart;
   int               m_x;
   int               m_y;
   int               m_lineHeight;
   int               m_fontSize;
   string            m_font;
   color             m_colorNormal;
   color             m_colorGood;
   color             m_colorWarn;
   color             m_colorBad;
   color             m_colorHeader;
   bool              m_enabled;
   int               m_rows;

   void              Row(const int index,const string text,const color clr);
   void              Clear(void);

public:
                     CDashboard(void);
                    ~CDashboard(void);

   //! Configure position and appearance.
   //! x, y     screen offset in pixels
   //! fontSize 6..14, default 9
   void              Configure(const int x,const int y,const int fontSize,const bool enabled);

   //! Turn the HUD on or off. Off removes every object.
   void              SetEnabled(const bool enabled);

   //! True when the HUD is drawing.
   bool              IsEnabled(void) const { return m_enabled; }

   //! Remove every HUD object. Call from OnDeinit.
   void              Destroy(void);

   //--- drawing -----------------------------------------------------------
   //! Begin a redraw. Resets the row cursor.
   void              Begin(void);

   //! Add a header line.
   void              Header(const string text);

   //! Add a plain line.
   void              Line(const string text);

   //! Add a line coloured by a good/bad flag.
   void              Status(const string label,const string value,const bool good);

   //! Add a line coloured by severity: 0 good, 1 warn, 2 bad.
   void              Severity(const string label,const string value,const int severity);

   //! Finish a redraw, clearing any rows left over from last time.
   void              End(void);
  };

//+------------------------------------------------------------------+
CDashboard::CDashboard(void)
  {
   m_chart       = 0;
   m_x           = 10;
   m_y           = 20;
   m_lineHeight  = 14;
   m_fontSize    = 9;
   m_font        = "Consolas";
   m_colorNormal = clrSilver;
   m_colorGood   = clrLimeGreen;
   m_colorWarn   = clrGold;
   m_colorBad    = clrTomato;
   m_colorHeader = clrWhite;
   m_enabled     = true;
   m_rows        = 0;
  }

//+------------------------------------------------------------------+
CDashboard::~CDashboard(void)
  {
   Destroy();
  }

//+------------------------------------------------------------------+
void CDashboard::Configure(const int x,const int y,const int fontSize,const bool enabled)
  {
   m_x        = (x<0 ? 0 : x);
   m_y        = (y<0 ? 0 : y);
   m_fontSize = (fontSize<6 ? 6 : (fontSize>14 ? 14 : fontSize));
   m_lineHeight=m_fontSize+5;
   SetEnabled(enabled);
  }

//+------------------------------------------------------------------+
void CDashboard::SetEnabled(const bool enabled)
  {
   if(m_enabled && !enabled)
      Destroy();
   m_enabled=enabled;
  }

//+------------------------------------------------------------------+
void CDashboard::Clear(void)
  {
   for(int i=0; i<SEA_HUD_MAXROWS; i++)
     {
      string name=StringFormat("%s%d",SEA_HUD_PREFIX,i);
      if(ObjectFind(m_chart,name)>=0)
         ObjectDelete(m_chart,name);
     }
  }

//+------------------------------------------------------------------+
void CDashboard::Destroy(void)
  {
   Clear();
   ChartRedraw(m_chart);
  }

//+------------------------------------------------------------------+
void CDashboard::Row(const int index,const string text,const color clr)
  {
   if(!m_enabled || index<0 || index>=SEA_HUD_MAXROWS)
      return;

   string name=StringFormat("%s%d",SEA_HUD_PREFIX,index);

   if(ObjectFind(m_chart,name)<0)
     {
      if(!ObjectCreate(m_chart,name,OBJ_LABEL,0,0,0))
         return;
      ObjectSetInteger(m_chart,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(m_chart,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(m_chart,name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(m_chart,name,OBJPROP_BACK,false);
      ObjectSetString(m_chart,name,OBJPROP_FONT,m_font);
     }

   ObjectSetInteger(m_chart,name,OBJPROP_XDISTANCE,m_x);
   ObjectSetInteger(m_chart,name,OBJPROP_YDISTANCE,m_y+index*m_lineHeight);
   ObjectSetInteger(m_chart,name,OBJPROP_FONTSIZE,m_fontSize);
   ObjectSetInteger(m_chart,name,OBJPROP_COLOR,clr);
   ObjectSetString(m_chart,name,OBJPROP_TEXT,text);
  }

//+------------------------------------------------------------------+
void CDashboard::Begin(void)
  {
   m_rows=0;
  }

//+------------------------------------------------------------------+
void CDashboard::Header(const string text)
  {
   Row(m_rows,text,m_colorHeader);
   m_rows++;
  }

//+------------------------------------------------------------------+
void CDashboard::Line(const string text)
  {
   Row(m_rows,text,m_colorNormal);
   m_rows++;
  }

//+------------------------------------------------------------------+
void CDashboard::Status(const string label,const string value,const bool good)
  {
   Row(m_rows,StringFormat("%-18s %s",label,value),
       (good ? m_colorGood : m_colorBad));
   m_rows++;
  }

//+------------------------------------------------------------------+
void CDashboard::Severity(const string label,const string value,const int severity)
  {
   color clr=m_colorGood;
   if(severity==1)
      clr=m_colorWarn;
   if(severity>=2)
      clr=m_colorBad;

   Row(m_rows,StringFormat("%-18s %s",label,value),clr);
   m_rows++;
  }

//+------------------------------------------------------------------+
void CDashboard::End(void)
  {
   //--- clear rows left behind by a longer previous draw
   for(int i=m_rows; i<SEA_HUD_MAXROWS; i++)
     {
      string name=StringFormat("%s%d",SEA_HUD_PREFIX,i);
      if(ObjectFind(m_chart,name)>=0)
         ObjectDelete(m_chart,name);
     }

   ChartRedraw(m_chart);
  }

#endif // SEA_CDASHBOARD_MQH
//+------------------------------------------------------------------+
