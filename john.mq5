//+------------------------------------------------------------------+
//|                                              PD_JohnWick.mq5     |
//|   Previous Daily Premium/Discount "John Wick" Rejection Signal   |
//|   Indicator for MetaTrader 5 (optimized for XAUUSD)              |
//|                                                                    |
//|   Non-repainting: all signals are evaluated on closed bars only. |
//|   The previous day's High/Low/Mid/Premium/Discount levels are    |
//|   fixed for the entire current trading day.                      |
//+------------------------------------------------------------------+
#property copyright "Custom"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 2
#property indicator_plots   2

#property indicator_type1   DRAW_ARROW
#property indicator_width1  2
#property indicator_label1  "Buy Signal"

#property indicator_type2   DRAW_ARROW
#property indicator_width2  2
#property indicator_label2  "Sell Signal"

//====================================================================
// INPUTS
//====================================================================
input group "=== Previous Day Box ==="
input bool   InpShowBox            = true;
input color  InpBoxColor           = clrDodgerBlue;
input color  InpBorderColor        = clrDodgerBlue;
input int    InpBorderWidth        = 1;
input int    InpBoxTransparency    = 92;    // 0 = opaque .. 100 = invisible (blended toward chart bg)

input group "=== Midline ==="
input bool   InpShowMidline        = true;
input color  InpMidlineColor       = clrSilver;
input ENUM_LINE_STYLE InpMidlineStyle = STYLE_DASH;
input int    InpMidlineWidth       = 1;

input group "=== Premium / Discount Zones ==="
input bool   InpShowZones          = true;
input color  InpPremiumColor       = clrTomato;
input color  InpDiscountColor      = clrLimeGreen;
input int    InpZoneTransparency   = 88;    // 0 = opaque .. 100 = invisible
input double InpZonePercent        = 0.25;  // 25% zone size (future-proof: adjustable)

input group "=== John Wick Detection ==="
input double InpWickMultiplier     = 2.5;   // rejection wick must be >= body * multiplier
input double InpMaxBodyPercent     = 0.35;  // body must be <= range * this

input group "=== Signals ==="
input bool   InpFirstTouchOnly     = true;  // only first valid signal per zone per day
input color  InpBuyArrowColor      = clrLime;
input color  InpSellArrowColor     = clrRed;
input int    InpArrowSize          = 2;
input double InpArrowOffsetPips    = 2.0;   // offset in points (symbol points, not pips)

input group "=== Alerts ==="
input bool   InpEnableAlerts       = true;
input bool   InpEnablePush         = false;
input bool   InpEnableEmail        = false;
input bool   InpEnableSound        = true;
input string InpSoundFile          = "alert.wav";

//====================================================================
// INDICATOR BUFFERS
//====================================================================
double BuyBuffer[];
double SellBuffer[];

//====================================================================
// OBJECT NAME PREFIXES
//====================================================================
#define PREFIX_BOX      "PD_BOX_"
#define PREFIX_MID      "PD_MID_"
#define PREFIX_PREMIUM  "PD_PREMIUM_"
#define PREFIX_DISCOUNT "PD_DISCOUNT_"

//====================================================================
// GLOBAL STATE
//====================================================================
// Cached previous-day levels, keyed by the trading day (midnight) they apply to
datetime g_cachedDayStart   = 0;
double   g_cachedPrevHigh   = 0.0;
double   g_cachedPrevLow    = 0.0;
double   g_cachedMid        = 0.0;
double   g_cachedUpper25    = 0.0;
double   g_cachedLower25    = 0.0;
bool     g_cacheValid       = false;

// First-touch-only state, reset every new trading day
datetime g_stateDayStart        = 0;
bool     g_buySignalFiredToday  = false;
bool     g_sellSignalFiredToday = false;

// Track which day currently has visual objects drawn, so we only
// recreate the box/zones/midline when the trading day changes.
datetime g_drawnDayStart = 0;

// Prevents duplicate alerts on the same closed bar
datetime g_lastAlertBarTime_Buy  = 0;
datetime g_lastAlertBarTime_Sell = 0;

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   SetIndexBuffer(0, BuyBuffer,  INDICATOR_DATA);
   SetIndexBuffer(1, SellBuffer, INDICATOR_DATA);

   ArraySetAsSeries(BuyBuffer,  false);
   ArraySetAsSeries(SellBuffer, false);

   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   PlotIndexSetInteger(0, PLOT_ARROW, 233); // Wingdings up arrow
   PlotIndexSetInteger(1, PLOT_ARROW, 234); // Wingdings down arrow

   PlotIndexSetInteger(0, PLOT_LINE_COLOR, InpBuyArrowColor);
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, InpSellArrowColor);

   PlotIndexSetInteger(0, PLOT_LINE_WIDTH, InpArrowSize);
   PlotIndexSetInteger(1, PLOT_LINE_WIDTH, InpArrowSize);

   IndicatorSetString(INDICATOR_SHORTNAME, "PD Premium/Discount John Wick");

   // Reset all cached/state variables on (re)initialization
   g_cachedDayStart         = 0;
   g_cacheValid             = false;
   g_stateDayStart          = 0;
   g_buySignalFiredToday    = false;
   g_sellSignalFiredToday   = false;
   g_drawnDayStart          = 0;
   g_lastAlertBarTime_Buy   = 0;
   g_lastAlertBarTime_Sell  = 0;

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| OnDeinit - clean up all chart objects created by this indicator  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, PREFIX_BOX);
   ObjectsDeleteAll(0, PREFIX_MID);
   ObjectsDeleteAll(0, PREFIX_PREMIUM);
   ObjectsDeleteAll(0, PREFIX_DISCOUNT);
  }

//+------------------------------------------------------------------+
//| Utility: midnight (day start) for a given time                   |
//+------------------------------------------------------------------+
datetime GetDayStart(datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   s.hour = 0; s.min = 0; s.sec = 0;
   return(StructToTime(s));
  }

//+------------------------------------------------------------------+
//| Utility: format a datetime as YYYYMMDD for object name suffixes  |
//+------------------------------------------------------------------+
string DateSuffix(datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return(StringFormat("%04d%02d%02d", s.year, s.mon, s.day));
  }

//+------------------------------------------------------------------+
//| Extract R/G/B from an MQL5 color (stored as 0x00BBGGRR)          |
//+------------------------------------------------------------------+
uchar GetRValue(color clr) { return (uchar)(clr & 0xFF); }
uchar GetGValue(color clr) { return (uchar)((clr >> 8) & 0xFF); }
uchar GetBValue(color clr) { return (uchar)((clr >> 16) & 0xFF); }

//+------------------------------------------------------------------+
//| Blend a color toward the chart background to fake transparency   |
//| percent: 0 = fully opaque original color, 100 = fully background |
//+------------------------------------------------------------------+
color ApplyTransparency(color clr, int percent)
  {
   percent = MathMax(0, MathMin(100, percent));
   color bg = (color)ChartGetInteger(0, CHART_COLOR_BACKGROUND);

   int r1 = GetRValue(clr),  g1 = GetGValue(clr),  b1 = GetBValue(clr);
   int r2 = GetRValue(bg),   g2 = GetGValue(bg),   b2 = GetBValue(bg);

   int r = r1 + (r2 - r1) * percent / 100;
   int g = g1 + (g2 - g1) * percent / 100;
   int b = b1 + (b2 - b1) * percent / 100;

   return (color)(r | (g << 8) | (b << 16));
  }

//+------------------------------------------------------------------+
//| Retrieve previous-day High/Low/Mid/Upper25/Lower25 for the       |
//| trading day that "barTime" belongs to. Uses a one-entry cache so |
//| consecutive bars on the same day avoid repeated D1 lookups.      |
//+------------------------------------------------------------------+
bool GetDailyLevelsForBar(datetime barTime,
                           double &prevHigh, double &prevLow,
                           double &mid, double &upper25, double &lower25,
                           datetime &dayStartOut)
  {
   datetime dayStart = GetDayStart(barTime);
   dayStartOut = dayStart;

   if(g_cacheValid && g_cachedDayStart == dayStart)
     {
      prevHigh = g_cachedPrevHigh;
      prevLow  = g_cachedPrevLow;
      mid      = g_cachedMid;
      upper25  = g_cachedUpper25;
      lower25  = g_cachedLower25;
      return(true);
     }

   // Find which D1 bar this trading day corresponds to, then step back one
   int dayShift = iBarShift(_Symbol, PERIOD_D1, barTime, false);
   if(dayShift < 0)
      return(false);

   int prevShift = dayShift + 1;

   double ph = iHigh(_Symbol, PERIOD_D1, prevShift);
   double pl = iLow(_Symbol,  PERIOD_D1, prevShift);

   if(ph <= 0.0 || pl <= 0.0 || ph <= pl)
      return(false); // missing/invalid daily bar (e.g. not enough history)

   double range = ph - pl;

   prevHigh = ph;
   prevLow  = pl;
   mid      = (ph + pl) / 2.0;
   upper25  = ph - range * InpZonePercent;
   lower25  = pl + range * InpZonePercent;

   // Update cache
   g_cachedDayStart = dayStart;
   g_cachedPrevHigh = prevHigh;
   g_cachedPrevLow  = prevLow;
   g_cachedMid      = mid;
   g_cachedUpper25  = upper25;
   g_cachedLower25  = lower25;
   g_cacheValid     = true;

   return(true);
  }

//+------------------------------------------------------------------+
//| Candle metrics: body, upper wick, lower wick, range               |
//+------------------------------------------------------------------+
void GetCandleMetrics(const int i,
                      const double &open[], const double &high[],
                      const double &low[],  const double &close[],
                      double &body, double &upperWick, double &lowerWick, double &range)
  {
   double maxOC = MathMax(open[i], close[i]);
   double minOC = MathMin(open[i], close[i]);

   body      = MathAbs(close[i] - open[i]);
   upperWick = high[i] - maxOC;
   lowerWick = minOC - low[i];
   range     = high[i] - low[i];
  }

//+------------------------------------------------------------------+
//| Bullish John Wick pattern test                                    |
//+------------------------------------------------------------------+
bool IsBullishJohnWick(const int i,
                        const double &open[], const double &high[],
                        const double &low[],  const double &close[])
  {
   double body, upperWick, lowerWick, range;
   GetCandleMetrics(i, open, high, low, close, body, upperWick, lowerWick, range);

   if(range <= 0.0)
      return(false);
   if(close[i] <= open[i])
      return(false);
   if(body > range * InpMaxBodyPercent)
      return(false);
   if(lowerWick < body * InpWickMultiplier)
      return(false);
   if(upperWick > body)
      return(false);

   return(true);
  }

//+------------------------------------------------------------------+
//| Bearish John Wick pattern test                                    |
//+------------------------------------------------------------------+
bool IsBearishJohnWick(const int i,
                        const double &open[], const double &high[],
                        const double &low[],  const double &close[])
  {
   double body, upperWick, lowerWick, range;
   GetCandleMetrics(i, open, high, low, close, body, upperWick, lowerWick, range);

   if(range <= 0.0)
      return(false);
   if(close[i] >= open[i])
      return(false);
   if(body > range * InpMaxBodyPercent)
      return(false);
   if(upperWick < body * InpWickMultiplier)
      return(false);
   if(lowerWick > body)
      return(false);

   return(true);
  }

//+------------------------------------------------------------------+
//| Draw/update the previous-day rectangle box (current day only)     |
//+------------------------------------------------------------------+
void DrawOrUpdateBox(datetime dayStart, datetime leftTime, datetime rightTime,
                     double prevHigh, double prevLow)
  {
   if(!InpShowBox)
      return;

   string name = PREFIX_BOX + DateSuffix(dayStart);

   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_RECTANGLE, 0, leftTime, prevHigh, rightTime, prevLow);
      ObjectSetInteger(0, name, OBJPROP_COLOR, InpBorderColor);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, InpBorderWidth);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }

   ObjectSetInteger(0, name, OBJPROP_TIME,  0, leftTime);
   ObjectSetDouble (0, name, OBJPROP_PRICE, 0, prevHigh);
   ObjectSetInteger(0, name, OBJPROP_TIME,  1, rightTime);
   ObjectSetDouble (0, name, OBJPROP_PRICE, 1, prevLow);
   ObjectSetInteger(0, name, OBJPROP_COLOR, ApplyTransparency(InpBoxColor, InpBoxTransparency));
  }

//+------------------------------------------------------------------+
//| Draw/update the midline (current day only)                        |
//+------------------------------------------------------------------+
void DrawOrUpdateMidline(datetime dayStart, datetime leftTime, datetime rightTime, double mid)
  {
   if(!InpShowMidline)
      return;

   string name = PREFIX_MID + DateSuffix(dayStart);

   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_TREND, 0, leftTime, mid, rightTime, mid);
      ObjectSetInteger(0, name, OBJPROP_COLOR, InpMidlineColor);
      ObjectSetInteger(0, name, OBJPROP_STYLE, InpMidlineStyle);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, InpMidlineWidth);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }

   ObjectSetInteger(0, name, OBJPROP_TIME,  0, leftTime);
   ObjectSetDouble (0, name, OBJPROP_PRICE, 0, mid);
   ObjectSetInteger(0, name, OBJPROP_TIME,  1, rightTime);
   ObjectSetDouble (0, name, OBJPROP_PRICE, 1, mid);
  }

//+------------------------------------------------------------------+
//| Draw/update premium & discount zone rectangles (current day only) |
//+------------------------------------------------------------------+
void DrawOrUpdateZones(datetime dayStart, datetime leftTime, datetime rightTime,
                       double prevHigh, double prevLow, double upper25, double lower25)
  {
   if(!InpShowZones)
      return;

   string premName = PREFIX_PREMIUM  + DateSuffix(dayStart);
   string discName = PREFIX_DISCOUNT + DateSuffix(dayStart);

   // Premium zone: Upper25 -> PreviousHigh
   if(ObjectFind(0, premName) < 0)
     {
      ObjectCreate(0, premName, OBJ_RECTANGLE, 0, leftTime, prevHigh, rightTime, upper25);
      ObjectSetInteger(0, premName, OBJPROP_BACK, true);
      ObjectSetInteger(0, premName, OBJPROP_FILL, true);
      ObjectSetInteger(0, premName, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, premName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, premName, OBJPROP_HIDDEN, true);
     }
   ObjectSetInteger(0, premName, OBJPROP_TIME,  0, leftTime);
   ObjectSetDouble (0, premName, OBJPROP_PRICE, 0, prevHigh);
   ObjectSetInteger(0, premName, OBJPROP_TIME,  1, rightTime);
   ObjectSetDouble (0, premName, OBJPROP_PRICE, 1, upper25);
   ObjectSetInteger(0, premName, OBJPROP_COLOR, ApplyTransparency(InpPremiumColor, InpZoneTransparency));

   // Discount zone: PreviousLow -> Lower25
   if(ObjectFind(0, discName) < 0)
     {
      ObjectCreate(0, discName, OBJ_RECTANGLE, 0, leftTime, lower25, rightTime, prevLow);
      ObjectSetInteger(0, discName, OBJPROP_BACK, true);
      ObjectSetInteger(0, discName, OBJPROP_FILL, true);
      ObjectSetInteger(0, discName, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, discName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, discName, OBJPROP_HIDDEN, true);
     }
   ObjectSetInteger(0, discName, OBJPROP_TIME,  0, leftTime);
   ObjectSetDouble (0, discName, OBJPROP_PRICE, 0, lower25);
   ObjectSetInteger(0, discName, OBJPROP_TIME,  1, rightTime);
   ObjectSetDouble (0, discName, OBJPROP_PRICE, 1, prevLow);
   ObjectSetInteger(0, discName, OBJPROP_COLOR, ApplyTransparency(InpDiscountColor, InpZoneTransparency));
  }

//+------------------------------------------------------------------+
//| Remove previous day's visual objects when the trading day rolls  |
//+------------------------------------------------------------------+
void DeletePriorDayObjects(datetime priorDayStart)
  {
   if(priorDayStart == 0)
      return;

   string suffix = DateSuffix(priorDayStart);
   ObjectDelete(0, PREFIX_BOX      + suffix);
   ObjectDelete(0, PREFIX_MID      + suffix);
   ObjectDelete(0, PREFIX_PREMIUM  + suffix);
   ObjectDelete(0, PREFIX_DISCOUNT + suffix);
  }

//+------------------------------------------------------------------+
//| Fire an alert (popup / push / email / sound), once per bar/type   |
//+------------------------------------------------------------------+
void SendSignalAlert(const string type, const string zoneDesc, const double price, const datetime barTime)
  {
   if(!InpEnableAlerts)
      return;

   string msg = StringFormat("%s: John Wick detected in %s (%s) @ %s | price %.5f",
                              _Symbol, zoneDesc, type, TimeToString(barTime, TIME_DATE|TIME_MINUTES), price);

   Alert(msg);

   if(InpEnablePush)
      SendNotification(msg);

   if(InpEnableEmail)
      SendMail(StringFormat("%s Signal - %s", type, _Symbol), msg);

   if(InpEnableSound)
      PlaySound(InpSoundFile);
  }

//+------------------------------------------------------------------+
//| Reset the first-touch-only state for a new trading day            |
//+------------------------------------------------------------------+
void ResetDailyState(datetime dayStart)
  {
   g_stateDayStart          = dayStart;
   g_buySignalFiredToday    = false;
   g_sellSignalFiredToday   = false;
  }

//+------------------------------------------------------------------+
//| Main calculation function                                         |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   if(rates_total < 2)
      return(0);

   int start = (prev_calculated > 1) ? prev_calculated - 1 : 0;

   // A full recalculation (history reload) means our incremental daily
   // state is stale - reset it so first-touch logic replays correctly.
   if(start == 0)
     {
      g_cacheValid            = false;
      g_stateDayStart         = 0;
      g_buySignalFiredToday   = false;
      g_sellSignalFiredToday  = false;
     }

   for(int i = start; i < rates_total; i++)
     {
      BuyBuffer[i]  = EMPTY_VALUE;
      SellBuffer[i] = EMPTY_VALUE;

      double prevHigh, prevLow, mid, upper25, lower25;
      datetime dayStart;

      if(!GetDailyLevelsForBar(time[i], prevHigh, prevLow, mid, upper25, lower25, dayStart))
         continue; // not enough daily history yet for this bar (e.g. very start of chart)

      // New trading day -> reset first-touch-only flags
      if(dayStart != g_stateDayStart)
         ResetDailyState(dayStart);

      bool isClosedBar = (i < rates_total - 1);

      // --- Update chart visuals for the CURRENT (most recent) trading day only ---
      bool isLatestBar = (i == rates_total - 1);
      if(isLatestBar || dayStart == GetDayStart(time[rates_total - 1]))
        {
         if(dayStart != g_drawnDayStart)
           {
            DeletePriorDayObjects(g_drawnDayStart);
            g_drawnDayStart = dayStart;
           }

         datetime leftTime  = dayStart;
         datetime rightTime = time[rates_total - 1];

         DrawOrUpdateBox(dayStart, leftTime, rightTime, prevHigh, prevLow);
         DrawOrUpdateMidline(dayStart, leftTime, rightTime, mid);
         DrawOrUpdateZones(dayStart, leftTime, rightTime, prevHigh, prevLow, upper25, lower25);
        }

      // --- Signal generation: closed bars only, non-repainting ---
      if(!isClosedBar)
         continue;

      bool bullishWick = IsBullishJohnWick(i, open, high, low, close);
      bool bearishWick = IsBearishJohnWick(i, open, high, low, close);

      bool buyCondition  = bullishWick && (low[i]  <= lower25);
      bool sellCondition = bearishWick && (high[i] >= upper25);

      if(InpFirstTouchOnly)
        {
         if(buyCondition && g_buySignalFiredToday)
            buyCondition = false;
         if(sellCondition && g_sellSignalFiredToday)
            sellCondition = false;
        }

      double offset = InpArrowOffsetPips * _Point;

      if(buyCondition)
        {
         BuyBuffer[i] = low[i] - offset;
         g_buySignalFiredToday = true;

         if(time[i] != g_lastAlertBarTime_Buy)
           {
            SendSignalAlert("BUY", "Discount Zone", close[i], time[i]);
            g_lastAlertBarTime_Buy = time[i];
           }
        }

      if(sellCondition)
        {
         SellBuffer[i] = high[i] + offset;
         g_sellSignalFiredToday = true;

         if(time[i] != g_lastAlertBarTime_Sell)
           {
            SendSignalAlert("SELL", "Premium Zone", close[i], time[i]);
            g_lastAlertBarTime_Sell = time[i];
           }
        }
     }

   return(rates_total);
  }
//+------------------------------------------------------------------+
