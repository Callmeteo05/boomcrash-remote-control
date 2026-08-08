//+------------------------------------------------------------------+
//|                                                   CSymbolSpec.mqh |
//|                                                                   |
//|   Module 1 of the Structure-Driven Adaptive Expert Advisor.       |
//|                                                                   |
//|   Responsibility:                                                 |
//|     Read every broker-side symbol specification ONCE, cache it,   |
//|     and hand it out to the rest of the EA through cheap indexed   |
//|     accessors. Nothing above this module may call SymbolInfo*     |
//|     directly.                                                     |
//|                                                                   |
//|   Provides:                                                       |
//|     - spec cache for an arbitrary number of symbols               |
//|     - broker prefix / suffix detection (statistical, never by     |
//|       symbol name)                                                |
//|     - filling-mode resolution from the SYMBOL_FILLING_MODE        |
//|       BITMASK (tested with &, never ==)                           |
//|     - lot normalization: round DOWN to step, clamp, reject        |
//|     - trade-calculation-mode detection and classification         |
//|                                                                   |
//|   This module contains NO strategy logic, NO timeframes and NO    |
//|   symbol names. It is pure broker arithmetic.                     |
//+------------------------------------------------------------------+
#ifndef SEA_CSYMBOLSPEC_MQH
#define SEA_CSYMBOLSPEC_MQH

//--- SYMBOL_FILLING_BOC was introduced in a later terminal build than
//--- SYMBOL_FILLING_FOK / SYMBOL_FILLING_IOC. The numeric flag value is
//--- part of the terminal protocol and is spelled out here so the module
//--- compiles on builds where the enum member does not yet exist.
#define SEA_FILLING_FLAG_BOC   4

//+------------------------------------------------------------------+
//| Tunable defaults.                                                 |
//|                                                                   |
//| These are DEFAULTS, not magic numbers: every one of them is       |
//| reachable through a public setter so SEA.mq5 can bind an Inp      |
//| parameter to it. Documented ranges are given per constant.        |
//+------------------------------------------------------------------+
const int    SEA_SPEC_AFFIX_MAX_LEN       = 6;        // 1..16   longest prefix/suffix considered
const int    SEA_SPEC_AFFIX_MIN_CORE      = 3;        // 2..8    shortest acceptable core after stripping
const int    SEA_SPEC_AFFIX_SEED_COUNT    = 20;       // 1..200  symbols sampled to seed affix candidates
const double SEA_SPEC_AFFIX_SHARE_SEP     = 0.60;     // 0.30..1.00 share required for a separator-led affix
const double SEA_SPEC_AFFIX_SHARE_ALNUM   = 0.95;     // 0.80..1.00 share required for an alphanumeric affix
const string SEA_SPEC_AFFIX_SEPARATORS    = "._-#+/!~,: ";
const double SEA_SPEC_VOLUME_EPSILON      = 1.0e-6;   // step-relative tolerance for float comparison
const int    SEA_SPEC_MAX_VOLUME_DIGITS   = 8;        // upper bound on decimals derived from VOLUME_STEP

//+------------------------------------------------------------------+
//| Broad instrument family derived from SYMBOL_TRADE_CALC_MODE.      |
//|                                                                   |
//| Derived from the broker's calculation mode ONLY. It is never      |
//| inferred from a symbol name, and it carries no permission or      |
//| direction meaning - it exists so margin and value arithmetic can  |
//| branch correctly.                                                 |
//+------------------------------------------------------------------+
enum ENUM_SEA_CALC_FAMILY
  {
   SEA_CALC_FAMILY_UNKNOWN = 0,  // calculation mode not recognised by this build
   SEA_CALC_FAMILY_FOREX,        // margin scales with contract size and leverage
   SEA_CALC_FAMILY_CFD,          // contract-size based CFD family
   SEA_CALC_FAMILY_FUTURES,      // margin quoted directly per contract
   SEA_CALC_FAMILY_EXCHANGE,     // exchange-traded instruments and bonds
   SEA_CALC_FAMILY_COLLATERAL    // non-tradeable collateral instrument
  };

//+------------------------------------------------------------------+
//| One symbol's complete cached specification.                       |
//|                                                                   |
//| Fields marked (dynamic) are re-read by Refresh(); everything else |
//| is read once when the symbol is added to the cache.               |
//+------------------------------------------------------------------+
struct SSymbolSpec
  {
   //--- identity
   string            name;              // exact broker symbol name
   string            core;              // name with broker prefix and suffix stripped
   bool              valid;             // false when the spec is unusable for trading arithmetic
   string            invalidReason;     // human-readable reason when valid == false
   datetime          lastRefresh;       // server time of the last Refresh()

   //--- quotation
   int               digits;            // price decimals
   double            point;             // one point in price units

   //--- volume
   double            volumeMin;         // SYMBOL_VOLUME_MIN
   double            volumeMax;         // SYMBOL_VOLUME_MAX
   double            volumeStep;        // SYMBOL_VOLUME_STEP
   double            volumeLimit;       // SYMBOL_VOLUME_LIMIT, 0 when unlimited
   int               volumeDigits;      // decimals implied by volumeStep

   //--- valuation
   double            tickSize;          // SYMBOL_TRADE_TICK_SIZE, price units
   double            tickValue;         // SYMBOL_TRADE_TICK_VALUE, account currency per 1.00 lot
   double            tickValueProfit;   // SYMBOL_TRADE_TICK_VALUE_PROFIT
   double            tickValueLoss;     // SYMBOL_TRADE_TICK_VALUE_LOSS
   double            contractSize;      // SYMBOL_TRADE_CONTRACT_SIZE
   double            valuePerPriceUnit; // account currency per 1.00 of price move, per 1.00 lot
   double            valuePerPoint;     // account currency per point, per 1.00 lot

   //--- broker levels (dynamic)
   long              stopsLevelPoints;  // SYMBOL_TRADE_STOPS_LEVEL, 0 means dynamic
   long              freezeLevelPoints; // SYMBOL_TRADE_FREEZE_LEVEL
   double            stopsLevelPrice;   // stopsLevelPoints in price units
   double            freezeLevelPrice;  // freezeLevelPoints in price units

   //--- spread (dynamic)
   long              spreadPoints;      // SYMBOL_SPREAD
   bool              spreadFloat;       // SYMBOL_SPREAD_FLOAT

   //--- execution
   ENUM_SYMBOL_TRADE_EXECUTION execMode;       // SYMBOL_TRADE_EXEMODE
   long                        fillingMask;    // SYMBOL_FILLING_MODE, a BITMASK
   long                        expirationMask; // SYMBOL_EXPIRATION_MODE, a BITMASK
   ENUM_ORDER_TYPE_FILLING     fillingMarket;  // resolved filling for market orders
   ENUM_ORDER_TYPE_FILLING     fillingPending; // resolved filling for pending orders

   //--- permissions (dynamic)
   ENUM_SYMBOL_TRADE_MODE      tradeMode;      // SYMBOL_TRADE_MODE
   bool                        longAllowed;    // broker permits opening longs
   bool                        shortAllowed;   // broker permits opening shorts
   bool                        openAllowed;    // broker permits opening anything

   //--- calculation
   ENUM_SYMBOL_CALC_MODE       calcMode;       // SYMBOL_TRADE_CALC_MODE
   ENUM_SEA_CALC_FAMILY        calcFamily;     // derived family
   double                      marginInitial;  // SYMBOL_MARGIN_INITIAL
   double                      marginMaintenance; // SYMBOL_MARGIN_MAINTENANCE

   //--- currencies
   string            currencyBase;      // SYMBOL_CURRENCY_BASE
   string            currencyProfit;    // SYMBOL_CURRENCY_PROFIT
   string            currencyMargin;    // SYMBOL_CURRENCY_MARGIN
  };

//+------------------------------------------------------------------+
//| CSymbolSpec                                                       |
//|                                                                   |
//| Cache of SSymbolSpec records plus the arithmetic that depends on  |
//| them. Resolve a symbol to an index ONCE (Ensure / IndexOf) and    |
//| use the indexed accessors thereafter - the tick path must never   |
//| pay for a string lookup.                                          |
//+------------------------------------------------------------------+
class CSymbolSpec
  {
private:
   SSymbolSpec       m_specs[];              // the cache
   string            m_prefix;               // detected or configured broker prefix
   string            m_suffix;               // detected or configured broker suffix
   bool              m_affixesResolved;      // true once detection or explicit set has run
   bool              m_verbose;              // print diagnostics
   string            m_lastError;            // last failure description
   bool              m_preferReturnPending;  // use ORDER_FILLING_RETURN for pendings

   //--- affix detection tuning
   int               m_affixMaxLen;
   int               m_affixMinCore;
   int               m_affixSeedCount;
   double            m_affixShareSep;
   double            m_affixShareAlnum;

   //--- internal helpers
   bool              ReadStatic(const string symbol,SSymbolSpec &spec);
   bool              ReadDynamic(SSymbolSpec &spec);
   void              DeriveValues(SSymbolSpec &spec);
   void              ResolveFilling(SSymbolSpec &spec);
   int               DeriveVolumeDigits(const double step) const;
   ENUM_SEA_CALC_FAMILY DeriveCalcFamily(const ENUM_SYMBOL_CALC_MODE mode) const;
   bool              IsSeparator(const ushort ch) const;
   string            DetectOneAffix(const string &names[],const int total,const bool leading) const;
   void              Log(const string message) const;
   bool              InRange(const int index) const;

public:
                     CSymbolSpec(void);
                    ~CSymbolSpec(void);

   //--- configuration -------------------------------------------------
   //! Enable or disable diagnostic printing. Off by default.
   void              SetVerbose(const bool enabled) { m_verbose=enabled; }

   //! Set the broker prefix and suffix explicitly, bypassing detection.
   //! Pass empty strings to declare that the broker uses none.
   void              SetAffixes(const string prefix,const string suffix);

   //! Tune statistical affix detection.
   //! maxLen      1..16    longest affix considered
   //! minCore     2..8     shortest acceptable remainder after stripping
   //! seedCount   1..200   symbols sampled to seed candidate affixes
   //! shareSep    0.30..1.00 universe share required for a separator-led affix
   //! shareAlnum  0.80..1.00 universe share required for an alphanumeric affix
   void              SetAffixDetection(const int maxLen,const int minCore,const int seedCount,
                                       const double shareSep,const double shareAlnum);

   //! Choose ORDER_FILLING_RETURN for pending orders (default true).
   //! When false, pendings reuse the resolved market filling mode.
   //! CTradeExec owns the retcode 10030 fallback; this only sets the
   //! first attempt.
   void              SetPreferReturnForPending(const bool enabled);

   //--- affix handling ------------------------------------------------
   //! Scan the broker's full symbol list and infer the common prefix and
   //! suffix statistically. No symbol name is matched or assumed.
   //! Returns true when the scan completed (an empty affix is a valid
   //! result and still returns true).
   bool              DetectAffixes(void);

   //! Detected or configured broker prefix, empty when none.
   string            Prefix(void) const { return m_prefix; }

   //! Detected or configured broker suffix, empty when none.
   string            Suffix(void) const { return m_suffix; }

   //! Strip the broker prefix and suffix from a raw symbol name.
   //! Returns the input unchanged when stripping would leave a core
   //! shorter than the configured minimum.
   string            CoreOf(const string symbol) const;

   //--- cache management ----------------------------------------------
   //! Add a symbol to the cache if absent, reading its full spec.
   //! Returns the cache index, or -1 when the symbol does not exist at
   //! the broker or its spec is unusable.
   int               Ensure(const string symbol);

   //! Cache index of an already-added symbol, or -1.
   int               IndexOf(const string symbol) const;

   //! Number of symbols currently cached.
   int               Total(void) const { return ArraySize(m_specs); }

   //! Copy a cached record out by index. Returns false on a bad index.
   bool              Get(const int index,SSymbolSpec &out) const;

   //! Copy a cached record out by name. Returns false when not cached.
   bool              GetBySymbol(const string symbol,SSymbolSpec &out) const;

   //! Re-read the dynamic fields (spread, levels, permissions, margin
   //! rates, tick values) for one cached symbol.
   bool              Refresh(const int index);

   //! Refresh every cached symbol. Returns the number refreshed.
   int               RefreshAll(void);

   //! Drop every cached record. Affix settings are retained.
   void              Clear(void);

   //--- indexed accessors (hot path) -----------------------------------
   //! Exact broker symbol name at index, empty on a bad index.
   string            Name(const int index) const;
   //! Prefix/suffix-stripped name at index, empty on a bad index.
   string            Core(const int index) const;
   //! True when the cached spec is usable for trading arithmetic.
   bool              IsValid(const int index) const;
   //! Reason the spec was marked invalid, empty when valid.
   string            InvalidReason(const int index) const;
   //! Price decimals.
   int               Digits(const int index) const;
   //! One point in price units, 0.0 on a bad index.
   double            Point(const int index) const;
   //! SYMBOL_VOLUME_MIN.
   double            VolumeMin(const int index) const;
   //! SYMBOL_VOLUME_MAX.
   double            VolumeMax(const int index) const;
   //! SYMBOL_VOLUME_STEP.
   double            VolumeStep(const int index) const;
   //! SYMBOL_TRADE_TICK_SIZE in price units.
   double            TickSize(const int index) const;
   //! SYMBOL_TRADE_CONTRACT_SIZE.
   double            ContractSize(const int index) const;
   //! Account currency per 1.00 of price movement, per 1.00 lot.
   double            ValuePerPriceUnit(const int index) const;
   //! Account currency per point, per 1.00 lot.
   double            ValuePerPoint(const int index) const;
   //! Minimum stop distance in price units. 0.0 means the broker
   //! publishes no static level and the distance is spread-driven.
   double            StopsLevelPrice(const int index) const;
   //! Freeze distance in price units.
   double            FreezeLevelPrice(const int index) const;
   //! Current spread in points.
   long              SpreadPoints(const int index) const;
   //! Current spread in price units.
   double            SpreadPrice(const int index) const;
   //! Resolved filling mode for market orders.
   ENUM_ORDER_TYPE_FILLING FillingMarket(const int index) const;
   //! Resolved filling mode for pending orders.
   ENUM_ORDER_TYPE_FILLING FillingPending(const int index) const;
   //! Raw SYMBOL_FILLING_MODE bitmask.
   long              FillingMask(const int index) const;
   //! Raw SYMBOL_EXPIRATION_MODE bitmask.
   long              ExpirationMask(const int index) const;
   //! Broker permits opening long positions.
   bool              LongAllowed(const int index) const;
   //! Broker permits opening short positions.
   bool              ShortAllowed(const int index) const;
   //! Broker permits opening positions at all.
   bool              OpenAllowed(const int index) const;
   //! Raw SYMBOL_TRADE_CALC_MODE.
   ENUM_SYMBOL_CALC_MODE CalcMode(const int index) const;
   //! Derived instrument family.
   ENUM_SEA_CALC_FAMILY  CalcFamily(const int index) const;
   //! SYMBOL_CURRENCY_PROFIT.
   string            CurrencyProfit(const int index) const;
   //! SYMBOL_CURRENCY_BASE.
   string            CurrencyBase(const int index) const;
   //! SYMBOL_CURRENCY_MARGIN.
   string            CurrencyMargin(const int index) const;

   //--- arithmetic -----------------------------------------------------
   //! Normalize a lot request: round DOWN to VOLUME_STEP, clamp to
   //! VOLUME_MAX and VOLUME_LIMIT.
   //! Returns 0.0 when the result would fall below VOLUME_MIN - the
   //! caller must treat 0.0 as REJECT. This function never rounds up.
   double            NormalizeVolume(const int index,const double lots) const;

   //! True when lots is exactly tradeable as given.
   bool              IsVolumeValid(const int index,const double lots) const;

   //! Round a price to the symbol's tick size and digits.
   double            NormalizePrice(const int index,const double price) const;

   //! Account currency per 1.00 of price movement at VOLUME_MIN.
   //! This is the pointValue term used by the affordability formula:
   //!   pointValue = (TICK_VALUE_LOSS / TICK_SIZE) * VOLUME_MIN
   double            PointValueAtMinVolume(const int index) const;

   //! Account currency per 1.00 of price movement at the given lots.
   double            MoneyPerPriceUnit(const int index,const double lots) const;

   //! Account currency risked by a stop of stopPrice price units at
   //! the given lots.
   double            MoneyAtRisk(const int index,const double stopPriceDistance,const double lots) const;

   //! True when the filling mode is set in the symbol's BITMASK.
   //! ORDER_FILLING_RETURN is not represented in the mask and is
   //! reported as supported for non-market execution modes.
   bool              IsFillingSupported(const int index,const ENUM_ORDER_TYPE_FILLING filling) const;

   //! True when the expiration type is set in the symbol's BITMASK.
   bool              IsExpirationSupported(const int index,const ENUM_ORDER_TYPE_TIME expiration) const;

   //! Fill out[] with every filling mode worth trying, best first.
   //! CTradeExec walks this list on retcode 10030. Returns the count.
   int               SupportedFillings(const int index,ENUM_ORDER_TYPE_FILLING &out[]) const;

   //--- diagnostics -----------------------------------------------------
   //! Multi-line dump of one cached spec, for the journal and tests.
   string            Describe(const int index) const;

   //! One-line summary of one cached spec.
   string            DescribeShort(const int index) const;

   //! Last failure description, empty when none.
   string            LastError(void) const { return m_lastError; }

   //--- enum formatting ---------------------------------------------------
   //! Readable name of a calculation mode.
   string            CalcModeToString(const ENUM_SYMBOL_CALC_MODE mode) const;
   //! Readable name of a derived family.
   string            CalcFamilyToString(const ENUM_SEA_CALC_FAMILY family) const;
   //! Readable name of a trade mode.
   string            TradeModeToString(const ENUM_SYMBOL_TRADE_MODE mode) const;
   //! Readable name of an execution mode.
   string            ExecModeToString(const ENUM_SYMBOL_TRADE_EXECUTION mode) const;
   //! Readable name of a filling mode.
   string            FillingToString(const ENUM_ORDER_TYPE_FILLING filling) const;
   //! Readable decode of a SYMBOL_FILLING_MODE bitmask.
   string            FillingMaskToString(const long mask) const;
   //! Readable decode of a SYMBOL_EXPIRATION_MODE bitmask.
   string            ExpirationMaskToString(const long mask) const;
  };

//+------------------------------------------------------------------+
//| Constructor.                                                      |
//+------------------------------------------------------------------+
CSymbolSpec::CSymbolSpec(void)
  {
   m_prefix              = "";
   m_suffix              = "";
   m_affixesResolved     = false;
   m_verbose             = false;
   m_lastError           = "";
   m_preferReturnPending = true;
   m_affixMaxLen         = SEA_SPEC_AFFIX_MAX_LEN;
   m_affixMinCore        = SEA_SPEC_AFFIX_MIN_CORE;
   m_affixSeedCount      = SEA_SPEC_AFFIX_SEED_COUNT;
   m_affixShareSep       = SEA_SPEC_AFFIX_SHARE_SEP;
   m_affixShareAlnum     = SEA_SPEC_AFFIX_SHARE_ALNUM;
   ArrayResize(m_specs,0);
  }

//+------------------------------------------------------------------+
//| Destructor.                                                       |
//+------------------------------------------------------------------+
CSymbolSpec::~CSymbolSpec(void)
  {
   ArrayFree(m_specs);
  }

//+------------------------------------------------------------------+
//| Diagnostic print.                                                 |
//+------------------------------------------------------------------+
void CSymbolSpec::Log(const string message) const
  {
   if(m_verbose)
      Print("[CSymbolSpec] ",message);
  }

//+------------------------------------------------------------------+
//| Index bounds test.                                                |
//+------------------------------------------------------------------+
bool CSymbolSpec::InRange(const int index) const
  {
   return(index>=0 && index<ArraySize(m_specs));
  }

//+------------------------------------------------------------------+
//| Explicit affix override.                                          |
//+------------------------------------------------------------------+
void CSymbolSpec::SetAffixes(const string prefix,const string suffix)
  {
   m_prefix          = prefix;
   m_suffix          = suffix;
   m_affixesResolved = true;
   Log(StringFormat("affixes set explicitly: prefix='%s' suffix='%s'",m_prefix,m_suffix));
  }

//+------------------------------------------------------------------+
//| Affix detection tuning.                                           |
//+------------------------------------------------------------------+
void CSymbolSpec::SetAffixDetection(const int maxLen,const int minCore,const int seedCount,
                                    const double shareSep,const double shareAlnum)
  {
   m_affixMaxLen     = (maxLen    <1     ? 1     : (maxLen>16     ? 16     : maxLen));
   m_affixMinCore    = (minCore   <1     ? 1     : (minCore>8     ? 8      : minCore));
   m_affixSeedCount  = (seedCount <1     ? 1     : (seedCount>200 ? 200    : seedCount));
   m_affixShareSep   = (shareSep  <0.30  ? 0.30  : (shareSep>1.0  ? 1.0    : shareSep));
   m_affixShareAlnum = (shareAlnum<0.80  ? 0.80  : (shareAlnum>1.0 ? 1.0   : shareAlnum));
  }

//+------------------------------------------------------------------+
//| Pending-order filling preference.                                 |
//+------------------------------------------------------------------+
void CSymbolSpec::SetPreferReturnForPending(const bool enabled)
  {
   m_preferReturnPending=enabled;
   for(int i=0; i<ArraySize(m_specs); i++)
      ResolveFilling(m_specs[i]);
  }

//+------------------------------------------------------------------+
//| Separator test.                                                   |
//+------------------------------------------------------------------+
bool CSymbolSpec::IsSeparator(const ushort ch) const
  {
   return(StringFind(SEA_SPEC_AFFIX_SEPARATORS,ShortToString(ch))>=0);
  }

//+------------------------------------------------------------------+
//| Detect one affix (leading = prefix, otherwise suffix).            |
//|                                                                   |
//| Candidates are seeded from the first m_affixSeedCount symbols and |
//| then counted across the whole universe. A separator-led candidate |
//| needs a lower share than a purely alphanumeric one, because an    |
//| alphanumeric tail can collide with genuine instrument spelling.   |
//| The LONGEST qualifying candidate wins.                            |
//+------------------------------------------------------------------+
string CSymbolSpec::DetectOneAffix(const string &names[],const int total,const bool leading) const
  {
   if(total<=0)
      return("");

   string candidates[];
   ArrayResize(candidates,0);

   int seeds=(m_affixSeedCount<total ? m_affixSeedCount : total);
   for(int s=0; s<seeds; s++)
     {
      int len=StringLen(names[s]);
      for(int L=1; L<=m_affixMaxLen; L++)
        {
         if(len-L<m_affixMinCore)
            break;
         string piece=(leading ? StringSubstr(names[s],0,L) : StringSubstr(names[s],len-L,L));

         bool seen=false;
         for(int c=0; c<ArraySize(candidates); c++)
            if(candidates[c]==piece)
              {
               seen=true;
               break;
              }
         if(!seen)
           {
            int n=ArraySize(candidates);
            ArrayResize(candidates,n+1);
            candidates[n]=piece;
           }
        }
     }

   string best="";
   double bestShare=0.0;

   for(int c=0; c<ArraySize(candidates); c++)
     {
      string piece=candidates[c];
      int    pieceLen=StringLen(piece);
      int    hits=0;

      for(int i=0; i<total; i++)
        {
         int len=StringLen(names[i]);
         if(len-pieceLen<m_affixMinCore)
            continue;
         if(leading)
           {
            if(StringSubstr(names[i],0,pieceLen)==piece)
               hits++;
           }
         else
           {
            if(StringSubstr(names[i],len-pieceLen,pieceLen)==piece)
               hits++;
           }
        }

      double share=(double)hits/(double)total;

      //--- a separator at the joint makes the affix unambiguous
      ushort joint=(leading ? StringGetCharacter(piece,pieceLen-1) : StringGetCharacter(piece,0));
      bool   sepLed=IsSeparator(joint);
      double required=(sepLed ? m_affixShareSep : m_affixShareAlnum);

      if(share<required)
         continue;
      if(pieceLen>StringLen(best) || (pieceLen==StringLen(best) && share>bestShare))
        {
         best=piece;
         bestShare=share;
        }
     }

   return(best);
  }

//+------------------------------------------------------------------+
//| Scan the broker universe and infer prefix and suffix.             |
//+------------------------------------------------------------------+
bool CSymbolSpec::DetectAffixes(void)
  {
   int total=SymbolsTotal(false);
   if(total<=0)
     {
      m_lastError="DetectAffixes: broker reports no symbols";
      Log(m_lastError);
      return(false);
     }

   string names[];
   ArrayResize(names,total);
   for(int i=0; i<total; i++)
      names[i]=SymbolName(i,false);

   m_suffix          = DetectOneAffix(names,total,false);
   m_prefix          = DetectOneAffix(names,total,true);
   m_affixesResolved = true;

   Log(StringFormat("affix scan over %d symbols: prefix='%s' suffix='%s'",
                    total,m_prefix,m_suffix));
   return(true);
  }

//+------------------------------------------------------------------+
//| Strip prefix and suffix from a raw symbol name.                   |
//+------------------------------------------------------------------+
string CSymbolSpec::CoreOf(const string symbol) const
  {
   string out=symbol;

   int pLen=StringLen(m_prefix);
   if(pLen>0 && StringLen(out)-pLen>=m_affixMinCore && StringSubstr(out,0,pLen)==m_prefix)
      out=StringSubstr(out,pLen);

   int sLen=StringLen(m_suffix);
   int oLen=StringLen(out);
   if(sLen>0 && oLen-sLen>=m_affixMinCore && StringSubstr(out,oLen-sLen,sLen)==m_suffix)
      out=StringSubstr(out,0,oLen-sLen);

   return(out);
  }

//+------------------------------------------------------------------+
//| Decimals implied by a volume step.                                |
//+------------------------------------------------------------------+
int CSymbolSpec::DeriveVolumeDigits(const double step) const
  {
   if(step<=0.0)
      return(2);
   double s=step;
   int    d=0;
   while(d<SEA_SPEC_MAX_VOLUME_DIGITS && MathAbs(s-MathRound(s))>1.0e-9)
     {
      s*=10.0;
      d++;
     }
   return(d);
  }

//+------------------------------------------------------------------+
//| Map a broker calculation mode onto a derived family.              |
//+------------------------------------------------------------------+
ENUM_SEA_CALC_FAMILY CSymbolSpec::DeriveCalcFamily(const ENUM_SYMBOL_CALC_MODE mode) const
  {
   switch(mode)
     {
      case SYMBOL_CALC_MODE_FOREX:
      case SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE:
         return(SEA_CALC_FAMILY_FOREX);

      case SYMBOL_CALC_MODE_CFD:
      case SYMBOL_CALC_MODE_CFDINDEX:
      case SYMBOL_CALC_MODE_CFDLEVERAGE:
         return(SEA_CALC_FAMILY_CFD);

      case SYMBOL_CALC_MODE_FUTURES:
      case SYMBOL_CALC_MODE_EXCH_FUTURES:
      case SYMBOL_CALC_MODE_EXCH_FUTURES_FORTS:
         return(SEA_CALC_FAMILY_FUTURES);

      case SYMBOL_CALC_MODE_EXCH_STOCKS:
      case SYMBOL_CALC_MODE_EXCH_STOCKS_MOEX:
      case SYMBOL_CALC_MODE_EXCH_BONDS:
      case SYMBOL_CALC_MODE_EXCH_BONDS_MOEX:
         return(SEA_CALC_FAMILY_EXCHANGE);

      case SYMBOL_CALC_MODE_SERV_COLLATERAL:
         return(SEA_CALC_FAMILY_COLLATERAL);
     }
   return(SEA_CALC_FAMILY_UNKNOWN);
  }

//+------------------------------------------------------------------+
//| Resolve filling modes from the BITMASK.                           |
//|                                                                   |
//| SYMBOL_FILLING_MODE is a bitmask and is tested with & only.       |
//| ORDER_FILLING_RETURN is not represented in the mask: it is the    |
//| terminal's default for non-market execution and for pendings.     |
//+------------------------------------------------------------------+
void CSymbolSpec::ResolveFilling(SSymbolSpec &spec)
  {
   if((spec.fillingMask & SYMBOL_FILLING_FOK)!=0)
      spec.fillingMarket=ORDER_FILLING_FOK;
   else
      if((spec.fillingMask & SYMBOL_FILLING_IOC)!=0)
         spec.fillingMarket=ORDER_FILLING_IOC;
      else
         if((spec.fillingMask & SEA_FILLING_FLAG_BOC)!=0)
            spec.fillingMarket=ORDER_FILLING_BOC;
         else
            spec.fillingMarket=ORDER_FILLING_RETURN;

   if(m_preferReturnPending)
      spec.fillingPending=ORDER_FILLING_RETURN;
   else
      spec.fillingPending=spec.fillingMarket;
  }

//+------------------------------------------------------------------+
//| Read the fields that do not change during a session.              |
//+------------------------------------------------------------------+
bool CSymbolSpec::ReadStatic(const string symbol,SSymbolSpec &spec)
  {
   long exists=0;
   if(!SymbolInfoInteger(symbol,SYMBOL_EXIST,exists) || exists==0)
     {
      m_lastError=StringFormat("symbol '%s' does not exist at the broker",symbol);
      return(false);
     }

   if(!SymbolSelect(symbol,true))
     {
      m_lastError=StringFormat("SymbolSelect('%s') failed, error %d",symbol,GetLastError());
      return(false);
     }

   spec.name          = symbol;
   spec.core          = CoreOf(symbol);
   spec.valid         = true;
   spec.invalidReason = "";

   spec.digits        = (int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
   spec.point         = SymbolInfoDouble(symbol,SYMBOL_POINT);

   spec.volumeMin     = SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   spec.volumeMax     = SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
   spec.volumeStep    = SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
   spec.volumeLimit   = SymbolInfoDouble(symbol,SYMBOL_VOLUME_LIMIT);
   spec.volumeDigits  = DeriveVolumeDigits(spec.volumeStep);

   spec.tickSize      = SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
   spec.contractSize  = SymbolInfoDouble(symbol,SYMBOL_TRADE_CONTRACT_SIZE);

   spec.execMode      = (ENUM_SYMBOL_TRADE_EXECUTION)SymbolInfoInteger(symbol,SYMBOL_TRADE_EXEMODE);
   spec.fillingMask   = SymbolInfoInteger(symbol,SYMBOL_FILLING_MODE);
   spec.expirationMask= SymbolInfoInteger(symbol,SYMBOL_EXPIRATION_MODE);

   spec.calcMode      = (ENUM_SYMBOL_CALC_MODE)SymbolInfoInteger(symbol,SYMBOL_TRADE_CALC_MODE);
   spec.calcFamily    = DeriveCalcFamily(spec.calcMode);

   spec.currencyBase  = SymbolInfoString(symbol,SYMBOL_CURRENCY_BASE);
   spec.currencyProfit= SymbolInfoString(symbol,SYMBOL_CURRENCY_PROFIT);
   spec.currencyMargin= SymbolInfoString(symbol,SYMBOL_CURRENCY_MARGIN);

   ResolveFilling(spec);
   return(true);
  }

//+------------------------------------------------------------------+
//| Read the fields that move during a session.                       |
//+------------------------------------------------------------------+
bool CSymbolSpec::ReadDynamic(SSymbolSpec &spec)
  {
   const string symbol=spec.name;

   spec.tickValue        = SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE);
   spec.tickValueProfit  = SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE_PROFIT);
   spec.tickValueLoss    = SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);

   spec.stopsLevelPoints = SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL);
   spec.freezeLevelPoints= SymbolInfoInteger(symbol,SYMBOL_TRADE_FREEZE_LEVEL);

   spec.spreadPoints     = SymbolInfoInteger(symbol,SYMBOL_SPREAD);
   spec.spreadFloat      = (SymbolInfoInteger(symbol,SYMBOL_SPREAD_FLOAT)!=0);

   spec.tradeMode        = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(symbol,SYMBOL_TRADE_MODE);
   spec.marginInitial    = SymbolInfoDouble(symbol,SYMBOL_MARGIN_INITIAL);
   spec.marginMaintenance= SymbolInfoDouble(symbol,SYMBOL_MARGIN_MAINTENANCE);

   spec.longAllowed      = (spec.tradeMode==SYMBOL_TRADE_MODE_FULL || spec.tradeMode==SYMBOL_TRADE_MODE_LONGONLY);
   spec.shortAllowed     = (spec.tradeMode==SYMBOL_TRADE_MODE_FULL || spec.tradeMode==SYMBOL_TRADE_MODE_SHORTONLY);
   spec.openAllowed      = (spec.longAllowed || spec.shortAllowed);

   spec.lastRefresh      = TimeCurrent();

   DeriveValues(spec);
   return(spec.valid);
  }

//+------------------------------------------------------------------+
//| Derive value arithmetic and validate the spec.                    |
//+------------------------------------------------------------------+
void CSymbolSpec::DeriveValues(SSymbolSpec &spec)
  {
   spec.stopsLevelPrice = (double)spec.stopsLevelPoints  * spec.point;
   spec.freezeLevelPrice= (double)spec.freezeLevelPoints * spec.point;

   //--- prefer the loss-side tick value: risk arithmetic must be
   //--- conservative when a broker publishes asymmetric values
   double tv=spec.tickValueLoss;
   if(tv<=0.0)
      tv=spec.tickValue;

   double ts=spec.tickSize;
   if(ts<=0.0)
      ts=spec.point;

   if(ts>0.0 && tv>0.0)
     {
      spec.valuePerPriceUnit = tv/ts;
      spec.valuePerPoint     = spec.valuePerPriceUnit*spec.point;
     }
   else
     {
      spec.valuePerPriceUnit = 0.0;
      spec.valuePerPoint     = 0.0;
     }

   //--- validation: any failure here makes the symbol untradeable,
   //--- it is never patched with an assumed value
   spec.valid         = true;
   spec.invalidReason = "";

   if(spec.point<=0.0)
     {
      spec.valid=false;
      spec.invalidReason="SYMBOL_POINT is zero";
     }
   else
      if(spec.tickSize<=0.0)
        {
         spec.valid=false;
         spec.invalidReason="SYMBOL_TRADE_TICK_SIZE is zero";
        }
      else
         if(spec.volumeMin<=0.0)
           {
            spec.valid=false;
            spec.invalidReason="SYMBOL_VOLUME_MIN is zero";
           }
         else
            if(spec.volumeStep<=0.0)
              {
               spec.valid=false;
               spec.invalidReason="SYMBOL_VOLUME_STEP is zero";
              }
            else
               if(spec.volumeMax<spec.volumeMin)
                 {
                  spec.valid=false;
                  spec.invalidReason="SYMBOL_VOLUME_MAX below SYMBOL_VOLUME_MIN";
                 }
               else
                  if(spec.valuePerPriceUnit<=0.0)
                    {
                     spec.valid=false;
                     spec.invalidReason="tick value unavailable, money arithmetic impossible";
                    }
                  else
                     if(spec.calcFamily==SEA_CALC_FAMILY_COLLATERAL)
                       {
                        spec.valid=false;
                        spec.invalidReason="collateral instrument, not tradeable";
                       }
  }

//+------------------------------------------------------------------+
//| Add a symbol to the cache.                                        |
//+------------------------------------------------------------------+
int CSymbolSpec::Ensure(const string symbol)
  {
   int existing=IndexOf(symbol);
   if(existing>=0)
      return(existing);

   if(!m_affixesResolved)
      DetectAffixes();

   SSymbolSpec spec;
   if(!ReadStatic(symbol,spec))
     {
      Log(m_lastError);
      return(-1);
     }
   ReadDynamic(spec);

   int n=ArraySize(m_specs);
   if(ArrayResize(m_specs,n+1)!=n+1)
     {
      m_lastError="cache resize failed";
      Log(m_lastError);
      return(-1);
     }
   m_specs[n]=spec;

   if(!spec.valid)
      Log(StringFormat("'%s' cached but INVALID: %s",symbol,spec.invalidReason));
   else
      Log(StringFormat("'%s' cached at index %d (%s)",symbol,n,DescribeShort(n)));

   return(n);
  }

//+------------------------------------------------------------------+
//| Cache lookup by name.                                             |
//+------------------------------------------------------------------+
int CSymbolSpec::IndexOf(const string symbol) const
  {
   for(int i=0; i<ArraySize(m_specs); i++)
      if(m_specs[i].name==symbol)
         return(i);
   return(-1);
  }

//+------------------------------------------------------------------+
//| Copy a record out by index.                                       |
//+------------------------------------------------------------------+
bool CSymbolSpec::Get(const int index,SSymbolSpec &out) const
  {
   if(!InRange(index))
      return(false);
   out=m_specs[index];
   return(true);
  }

//+------------------------------------------------------------------+
//| Copy a record out by name.                                        |
//+------------------------------------------------------------------+
bool CSymbolSpec::GetBySymbol(const string symbol,SSymbolSpec &out) const
  {
   return(Get(IndexOf(symbol),out));
  }

//+------------------------------------------------------------------+
//| Refresh dynamic fields for one symbol.                            |
//+------------------------------------------------------------------+
bool CSymbolSpec::Refresh(const int index)
  {
   if(!InRange(index))
     {
      m_lastError=StringFormat("Refresh: index %d out of range",index);
      return(false);
     }
   return(ReadDynamic(m_specs[index]));
  }

//+------------------------------------------------------------------+
//| Refresh every cached symbol.                                      |
//+------------------------------------------------------------------+
int CSymbolSpec::RefreshAll(void)
  {
   int done=0;
   for(int i=0; i<ArraySize(m_specs); i++)
      if(ReadDynamic(m_specs[i]))
         done++;
   return(done);
  }

//+------------------------------------------------------------------+
//| Empty the cache.                                                  |
//+------------------------------------------------------------------+
void CSymbolSpec::Clear(void)
  {
   ArrayResize(m_specs,0);
  }

//+------------------------------------------------------------------+
//| Indexed accessors.                                                |
//+------------------------------------------------------------------+
string CSymbolSpec::Name(const int index) const
  { return(InRange(index) ? m_specs[index].name : ""); }

string CSymbolSpec::Core(const int index) const
  { return(InRange(index) ? m_specs[index].core : ""); }

bool CSymbolSpec::IsValid(const int index) const
  { return(InRange(index) ? m_specs[index].valid : false); }

string CSymbolSpec::InvalidReason(const int index) const
  { return(InRange(index) ? m_specs[index].invalidReason : "index out of range"); }

int CSymbolSpec::Digits(const int index) const
  { return(InRange(index) ? m_specs[index].digits : 0); }

double CSymbolSpec::Point(const int index) const
  { return(InRange(index) ? m_specs[index].point : 0.0); }

double CSymbolSpec::VolumeMin(const int index) const
  { return(InRange(index) ? m_specs[index].volumeMin : 0.0); }

double CSymbolSpec::VolumeMax(const int index) const
  { return(InRange(index) ? m_specs[index].volumeMax : 0.0); }

double CSymbolSpec::VolumeStep(const int index) const
  { return(InRange(index) ? m_specs[index].volumeStep : 0.0); }

double CSymbolSpec::TickSize(const int index) const
  { return(InRange(index) ? m_specs[index].tickSize : 0.0); }

double CSymbolSpec::ContractSize(const int index) const
  { return(InRange(index) ? m_specs[index].contractSize : 0.0); }

double CSymbolSpec::ValuePerPriceUnit(const int index) const
  { return(InRange(index) ? m_specs[index].valuePerPriceUnit : 0.0); }

double CSymbolSpec::ValuePerPoint(const int index) const
  { return(InRange(index) ? m_specs[index].valuePerPoint : 0.0); }

double CSymbolSpec::StopsLevelPrice(const int index) const
  { return(InRange(index) ? m_specs[index].stopsLevelPrice : 0.0); }

double CSymbolSpec::FreezeLevelPrice(const int index) const
  { return(InRange(index) ? m_specs[index].freezeLevelPrice : 0.0); }

long CSymbolSpec::SpreadPoints(const int index) const
  { return(InRange(index) ? m_specs[index].spreadPoints : 0); }

double CSymbolSpec::SpreadPrice(const int index) const
  { return(InRange(index) ? (double)m_specs[index].spreadPoints*m_specs[index].point : 0.0); }

ENUM_ORDER_TYPE_FILLING CSymbolSpec::FillingMarket(const int index) const
  { return(InRange(index) ? m_specs[index].fillingMarket : ORDER_FILLING_FOK); }

ENUM_ORDER_TYPE_FILLING CSymbolSpec::FillingPending(const int index) const
  { return(InRange(index) ? m_specs[index].fillingPending : ORDER_FILLING_RETURN); }

long CSymbolSpec::FillingMask(const int index) const
  { return(InRange(index) ? m_specs[index].fillingMask : 0); }

long CSymbolSpec::ExpirationMask(const int index) const
  { return(InRange(index) ? m_specs[index].expirationMask : 0); }

bool CSymbolSpec::LongAllowed(const int index) const
  { return(InRange(index) ? m_specs[index].longAllowed : false); }

bool CSymbolSpec::ShortAllowed(const int index) const
  { return(InRange(index) ? m_specs[index].shortAllowed : false); }

bool CSymbolSpec::OpenAllowed(const int index) const
  { return(InRange(index) ? m_specs[index].openAllowed : false); }

ENUM_SYMBOL_CALC_MODE CSymbolSpec::CalcMode(const int index) const
  { return(InRange(index) ? m_specs[index].calcMode : SYMBOL_CALC_MODE_FOREX); }

ENUM_SEA_CALC_FAMILY CSymbolSpec::CalcFamily(const int index) const
  { return(InRange(index) ? m_specs[index].calcFamily : SEA_CALC_FAMILY_UNKNOWN); }

string CSymbolSpec::CurrencyProfit(const int index) const
  { return(InRange(index) ? m_specs[index].currencyProfit : ""); }

string CSymbolSpec::CurrencyBase(const int index) const
  { return(InRange(index) ? m_specs[index].currencyBase : ""); }

string CSymbolSpec::CurrencyMargin(const int index) const
  { return(InRange(index) ? m_specs[index].currencyMargin : ""); }

//+------------------------------------------------------------------+
//| Normalize a lot request. Rounds DOWN, never up.                   |
//| Returns 0.0 to mean REJECT.                                       |
//+------------------------------------------------------------------+
double CSymbolSpec::NormalizeVolume(const int index,const double lots) const
  {
   if(!InRange(index) || !m_specs[index].valid)
      return(0.0);
   if(lots<=0.0)
      return(0.0);

   const double step=m_specs[index].volumeStep;
   const double vmin=m_specs[index].volumeMin;
   double       vmax=m_specs[index].volumeMax;
   const int    vdig=m_specs[index].volumeDigits;

   if(m_specs[index].volumeLimit>0.0 && m_specs[index].volumeLimit<vmax)
      vmax=m_specs[index].volumeLimit;

   double want=(lots>vmax ? vmax : lots);

   //--- snap to the step grid, downward, tolerating float error that
   //--- would otherwise drop a legitimate request a whole step
   double steps=want/step;
   double snapped=MathRound(steps);
   if(MathAbs(steps-snapped)>SEA_SPEC_VOLUME_EPSILON)
      snapped=MathFloor(steps);

   double result=NormalizeDouble(snapped*step,vdig);

   if(result>vmax+step*SEA_SPEC_VOLUME_EPSILON)
      result=NormalizeDouble(MathFloor(vmax/step)*step,vdig);

   //--- below the broker minimum is a rejection, never a round-up
   if(result<vmin-step*SEA_SPEC_VOLUME_EPSILON)
      return(0.0);

   return(result);
  }

//+------------------------------------------------------------------+
//| Exact-tradeability test for a lot size.                           |
//+------------------------------------------------------------------+
bool CSymbolSpec::IsVolumeValid(const int index,const double lots) const
  {
   if(!InRange(index))
      return(false);
   double norm=NormalizeVolume(index,lots);
   if(norm<=0.0)
      return(false);
   return(MathAbs(norm-lots)<=m_specs[index].volumeStep*SEA_SPEC_VOLUME_EPSILON);
  }

//+------------------------------------------------------------------+
//| Round a price to the symbol's tick grid.                          |
//+------------------------------------------------------------------+
double CSymbolSpec::NormalizePrice(const int index,const double price) const
  {
   if(!InRange(index))
      return(price);
   const double ts=m_specs[index].tickSize;
   if(ts<=0.0)
      return(NormalizeDouble(price,m_specs[index].digits));
   return(NormalizeDouble(MathRound(price/ts)*ts,m_specs[index].digits));
  }

//+------------------------------------------------------------------+
//| pointValue = (TICK_VALUE_LOSS / TICK_SIZE) * VOLUME_MIN           |
//+------------------------------------------------------------------+
double CSymbolSpec::PointValueAtMinVolume(const int index) const
  {
   if(!InRange(index))
      return(0.0);
   return(m_specs[index].valuePerPriceUnit*m_specs[index].volumeMin);
  }

//+------------------------------------------------------------------+
//| Money per 1.00 of price movement at the given lots.               |
//+------------------------------------------------------------------+
double CSymbolSpec::MoneyPerPriceUnit(const int index,const double lots) const
  {
   if(!InRange(index))
      return(0.0);
   return(m_specs[index].valuePerPriceUnit*lots);
  }

//+------------------------------------------------------------------+
//| Money risked by a stop distance expressed in price units.         |
//+------------------------------------------------------------------+
double CSymbolSpec::MoneyAtRisk(const int index,const double stopPriceDistance,const double lots) const
  {
   if(!InRange(index) || stopPriceDistance<=0.0 || lots<=0.0)
      return(0.0);
   return(m_specs[index].valuePerPriceUnit*stopPriceDistance*lots);
  }

//+------------------------------------------------------------------+
//| Bitmask test for a filling mode.                                  |
//+------------------------------------------------------------------+
bool CSymbolSpec::IsFillingSupported(const int index,const ENUM_ORDER_TYPE_FILLING filling) const
  {
   if(!InRange(index))
      return(false);
   const long mask=m_specs[index].fillingMask;

   switch(filling)
     {
      case ORDER_FILLING_FOK:
         return((mask & SYMBOL_FILLING_FOK)!=0);
      case ORDER_FILLING_IOC:
         return((mask & SYMBOL_FILLING_IOC)!=0);
      case ORDER_FILLING_BOC:
         return((mask & SEA_FILLING_FLAG_BOC)!=0);
      case ORDER_FILLING_RETURN:
         //--- not carried in the mask; the terminal rejects it only
         //--- under pure market execution
         return(m_specs[index].execMode!=SYMBOL_TRADE_EXECUTION_MARKET);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Bitmask test for an expiration type.                              |
//+------------------------------------------------------------------+
bool CSymbolSpec::IsExpirationSupported(const int index,const ENUM_ORDER_TYPE_TIME expiration) const
  {
   if(!InRange(index))
      return(false);
   const long mask=m_specs[index].expirationMask;

   switch(expiration)
     {
      case ORDER_TIME_GTC:
         return((mask & SYMBOL_EXPIRATION_GTC)!=0);
      case ORDER_TIME_DAY:
         return((mask & SYMBOL_EXPIRATION_DAY)!=0);
      case ORDER_TIME_SPECIFIED:
         return((mask & SYMBOL_EXPIRATION_SPECIFIED)!=0);
      case ORDER_TIME_SPECIFIED_DAY:
         return((mask & SYMBOL_EXPIRATION_SPECIFIED_DAY)!=0);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Ordered list of filling modes worth attempting.                   |
//+------------------------------------------------------------------+
int CSymbolSpec::SupportedFillings(const int index,ENUM_ORDER_TYPE_FILLING &out[]) const
  {
   ArrayResize(out,0);
   if(!InRange(index))
      return(0);

   ENUM_ORDER_TYPE_FILLING order[4];
   order[0]=m_specs[index].fillingMarket;
   order[1]=ORDER_FILLING_FOK;
   order[2]=ORDER_FILLING_IOC;
   order[3]=ORDER_FILLING_RETURN;

   for(int i=0; i<4; i++)
     {
      if(i>0 && !IsFillingSupported(index,order[i]))
         continue;

      bool dup=false;
      for(int j=0; j<ArraySize(out); j++)
         if(out[j]==order[i])
           {
            dup=true;
            break;
           }
      if(dup)
         continue;

      int n=ArraySize(out);
      ArrayResize(out,n+1);
      out[n]=order[i];
     }
   return(ArraySize(out));
  }

//+------------------------------------------------------------------+
//| Enum formatting.                                                  |
//+------------------------------------------------------------------+
string CSymbolSpec::CalcModeToString(const ENUM_SYMBOL_CALC_MODE mode) const
  {
   switch(mode)
     {
      case SYMBOL_CALC_MODE_FOREX:                return("FOREX");
      case SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE:    return("FOREX_NO_LEVERAGE");
      case SYMBOL_CALC_MODE_FUTURES:              return("FUTURES");
      case SYMBOL_CALC_MODE_CFD:                  return("CFD");
      case SYMBOL_CALC_MODE_CFDINDEX:             return("CFDINDEX");
      case SYMBOL_CALC_MODE_CFDLEVERAGE:          return("CFDLEVERAGE");
      case SYMBOL_CALC_MODE_EXCH_STOCKS:          return("EXCH_STOCKS");
      case SYMBOL_CALC_MODE_EXCH_FUTURES:         return("EXCH_FUTURES");
      case SYMBOL_CALC_MODE_EXCH_FUTURES_FORTS:   return("EXCH_FUTURES_FORTS");
      case SYMBOL_CALC_MODE_EXCH_BONDS:           return("EXCH_BONDS");
      case SYMBOL_CALC_MODE_EXCH_STOCKS_MOEX:     return("EXCH_STOCKS_MOEX");
      case SYMBOL_CALC_MODE_EXCH_BONDS_MOEX:      return("EXCH_BONDS_MOEX");
      case SYMBOL_CALC_MODE_SERV_COLLATERAL:      return("SERV_COLLATERAL");
     }
   return(StringFormat("UNKNOWN(%d)",(int)mode));
  }

string CSymbolSpec::CalcFamilyToString(const ENUM_SEA_CALC_FAMILY family) const
  {
   switch(family)
     {
      case SEA_CALC_FAMILY_FOREX:      return("FOREX");
      case SEA_CALC_FAMILY_CFD:        return("CFD");
      case SEA_CALC_FAMILY_FUTURES:    return("FUTURES");
      case SEA_CALC_FAMILY_EXCHANGE:   return("EXCHANGE");
      case SEA_CALC_FAMILY_COLLATERAL: return("COLLATERAL");
     }
   return("UNKNOWN");
  }

string CSymbolSpec::TradeModeToString(const ENUM_SYMBOL_TRADE_MODE mode) const
  {
   switch(mode)
     {
      case SYMBOL_TRADE_MODE_DISABLED:  return("DISABLED");
      case SYMBOL_TRADE_MODE_LONGONLY:  return("LONGONLY");
      case SYMBOL_TRADE_MODE_SHORTONLY: return("SHORTONLY");
      case SYMBOL_TRADE_MODE_CLOSEONLY: return("CLOSEONLY");
      case SYMBOL_TRADE_MODE_FULL:      return("FULL");
     }
   return(StringFormat("UNKNOWN(%d)",(int)mode));
  }

string CSymbolSpec::ExecModeToString(const ENUM_SYMBOL_TRADE_EXECUTION mode) const
  {
   switch(mode)
     {
      case SYMBOL_TRADE_EXECUTION_REQUEST:  return("REQUEST");
      case SYMBOL_TRADE_EXECUTION_INSTANT:  return("INSTANT");
      case SYMBOL_TRADE_EXECUTION_MARKET:   return("MARKET");
      case SYMBOL_TRADE_EXECUTION_EXCHANGE: return("EXCHANGE");
     }
   return(StringFormat("UNKNOWN(%d)",(int)mode));
  }

string CSymbolSpec::FillingToString(const ENUM_ORDER_TYPE_FILLING filling) const
  {
   switch(filling)
     {
      case ORDER_FILLING_FOK:    return("FOK");
      case ORDER_FILLING_IOC:    return("IOC");
      case ORDER_FILLING_BOC:    return("BOC");
      case ORDER_FILLING_RETURN: return("RETURN");
     }
   return(StringFormat("UNKNOWN(%d)",(int)filling));
  }

string CSymbolSpec::FillingMaskToString(const long mask) const
  {
   string out="";
   if((mask & SYMBOL_FILLING_FOK)!=0)
      out+="FOK ";
   if((mask & SYMBOL_FILLING_IOC)!=0)
      out+="IOC ";
   if((mask & SEA_FILLING_FLAG_BOC)!=0)
      out+="BOC ";
   if(out=="")
      out="<none> ";
   return(StringFormat("%s(0x%X)",out,(int)mask));
  }

string CSymbolSpec::ExpirationMaskToString(const long mask) const
  {
   string out="";
   if((mask & SYMBOL_EXPIRATION_GTC)!=0)
      out+="GTC ";
   if((mask & SYMBOL_EXPIRATION_DAY)!=0)
      out+="DAY ";
   if((mask & SYMBOL_EXPIRATION_SPECIFIED)!=0)
      out+="SPECIFIED ";
   if((mask & SYMBOL_EXPIRATION_SPECIFIED_DAY)!=0)
      out+="SPECIFIED_DAY ";
   if(out=="")
      out="<none> ";
   return(StringFormat("%s(0x%X)",out,(int)mask));
  }

//+------------------------------------------------------------------+
//| One-line summary.                                                 |
//+------------------------------------------------------------------+
string CSymbolSpec::DescribeShort(const int index) const
  {
   if(!InRange(index))
      return("<index out of range>");
   const SSymbolSpec s=m_specs[index];
   return(StringFormat("%s core=%s %s dig=%d vol=%s/%s/%s fill=%s valid=%s",
                       s.name,s.core,CalcFamilyToString(s.calcFamily),s.digits,
                       DoubleToString(s.volumeMin,s.volumeDigits),
                       DoubleToString(s.volumeStep,s.volumeDigits),
                       DoubleToString(s.volumeMax,s.volumeDigits),
                       FillingToString(s.fillingMarket),
                       (s.valid ? "yes" : "no")));
  }

//+------------------------------------------------------------------+
//| Full dump.                                                        |
//+------------------------------------------------------------------+
string CSymbolSpec::Describe(const int index) const
  {
   if(!InRange(index))
      return("<index out of range>");

   const SSymbolSpec s=m_specs[index];
   string out="";

   out+=StringFormat("--- %s (index %d) ---\n",s.name,index);
   out+=StringFormat("  core              : %s   (prefix='%s' suffix='%s')\n",s.core,m_prefix,m_suffix);
   out+=StringFormat("  valid             : %s%s\n",(s.valid ? "yes" : "NO"),
                     (s.valid ? "" : "  reason: "+s.invalidReason));
   out+=StringFormat("  digits / point    : %d / %s\n",
                     s.digits,DoubleToString(s.point,s.digits+2));
   out+=StringFormat("  tick size / value : %s / %.5f  (profit %.5f, loss %.5f)\n",
                     DoubleToString(s.tickSize,s.digits+2),
                     s.tickValue,s.tickValueProfit,s.tickValueLoss);
   out+=StringFormat("  contract size     : %.2f\n",s.contractSize);
   out+=StringFormat("  value / price unit: %.5f per 1.00 lot\n",s.valuePerPriceUnit);
   out+=StringFormat("  value / point     : %.5f per 1.00 lot\n",s.valuePerPoint);
   out+=StringFormat("  pointValue @ min  : %.5f  (formula: tickValueLoss/tickSize*volumeMin)\n",
                     s.valuePerPriceUnit*s.volumeMin);
   out+=StringFormat("  volume min/step/max: %s / %s / %s  (limit %s, digits %d)\n",
                     DoubleToString(s.volumeMin,s.volumeDigits),
                     DoubleToString(s.volumeStep,s.volumeDigits),
                     DoubleToString(s.volumeMax,s.volumeDigits),
                     DoubleToString(s.volumeLimit,s.volumeDigits),
                     s.volumeDigits);
   out+=StringFormat("  stops / freeze    : %d pts (%s) / %d pts (%s)\n",
                     (int)s.stopsLevelPoints,DoubleToString(s.stopsLevelPrice,s.digits),
                     (int)s.freezeLevelPoints,DoubleToString(s.freezeLevelPrice,s.digits));
   out+=StringFormat("  spread            : %d pts (%s) %s\n",
                     (int)s.spreadPoints,
                     DoubleToString((double)s.spreadPoints*s.point,s.digits),
                     (s.spreadFloat ? "floating" : "fixed"));
   out+=StringFormat("  execution         : %s\n",ExecModeToString(s.execMode));
   out+=StringFormat("  filling mask      : %s\n",FillingMaskToString(s.fillingMask));
   out+=StringFormat("  filling resolved  : market=%s pending=%s\n",
                     FillingToString(s.fillingMarket),FillingToString(s.fillingPending));
   out+=StringFormat("  expiration mask   : %s\n",ExpirationMaskToString(s.expirationMask));
   out+=StringFormat("  trade mode        : %s  (long=%s short=%s)\n",
                     TradeModeToString(s.tradeMode),
                     (s.longAllowed ? "yes" : "no"),(s.shortAllowed ? "yes" : "no"));
   out+=StringFormat("  calc mode         : %s -> family %s\n",
                     CalcModeToString(s.calcMode),CalcFamilyToString(s.calcFamily));
   out+=StringFormat("  margin init/maint : %.2f / %.2f\n",s.marginInitial,s.marginMaintenance);
   out+=StringFormat("  currencies        : base=%s profit=%s margin=%s\n",
                     s.currencyBase,s.currencyProfit,s.currencyMargin);
   out+=StringFormat("  last refresh      : %s\n",TimeToString(s.lastRefresh,TIME_DATE|TIME_SECONDS));

   return(out);
  }

#endif // SEA_CSYMBOLSPEC_MQH
//+------------------------------------------------------------------+
