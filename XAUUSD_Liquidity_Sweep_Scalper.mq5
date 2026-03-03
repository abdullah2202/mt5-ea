//+------------------------------------------------------------------+
//|                                XAUUSD_Liquidity_Sweep_Scalper.mq5 |
//|                                  Copyright 2026, Antigravity AI |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Antigravity AI"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict
#property tester_indicator "Indicators/Examples/VWAP.ex5"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//--- Input Parameters
input group "=== Risk Management ==="
input double   InpRiskPercent     = 0.5;      // Risk per trade (%)
input double   InpDailyLossLimit  = 1.5;      // Daily max loss (%)
input int      InpMaxTradesSession = 5;       // Max trades per session
input double   InpMaxSpread       = 30;       // Max spread in points (XAUUSD)

input group "=== Indicator Settings ==="
input int      InpEMA_Fast        = 20;       // Fast EMA Period
input int      InpEMA_Slow        = 50;       // Slow EMA Period
input int      InpRSI_Period      = 14;       // RSI Period
input double   InpVWAP_Buffer     = 50;       // VWAP Buffer Zone (points)

input group "=== Strategy Settings ==="
input int      InpLookback        = 20;       // Liquidity Lookback (candles)
input int      InpSweepBuffer     = 10;       // Sweep offset beyond high/low (points)
input int      InpSL_Buffer       = 20;       // SL buffer beyond sweep wick (points)
input bool     InpEnablePartialTP = true;      // Enable 50% partial TP at 1R
input int      InpTimeoutCandles  = 20;       // Time-based exit (M1 candles)

input group "=== Session Times (Broker Time) ==="
input string   InpLondonStart     = "08:00";   // London Start
input string   InpLondonEnd       = "12:00";   // London End
input string   InpNYStart         = "13:00";   // NY Start
input string   InpNYEnd           = "17:00";   // NY End

//--- Global Objects
CTrade         ExtTrade;
CPositionInfo  ExtPosition;
CSymbolInfo    ExtSymbol;

//--- Global Variables
int      hEMA20, hEMA50, hRSI;
double   vEMA20[], vEMA50[], vRSI[];
datetime last_trade_time = 0;
int      trades_today = 0;
double   daily_start_equity = 0;
bool     daily_limit_hit = false;

//--- Structures for sweep detection
struct SSweepLevel
{
   double high;
   double low;
   datetime time;
};

//+------------------------------------------------------------------+
//| Session Manager Class                                            |
//+------------------------------------------------------------------+
class CSessionManager
{
public:
   static bool IsInSession()
   {
      datetime now = TimeCurrent();
      string time_str = TimeToString(now, TIME_MINUTES);
      
      bool london = (time_str >= InpLondonStart && time_str <= InpLondonEnd);
      bool ny = (time_str >= InpNYStart && time_str <= InpNYEnd);
      
      return (london || ny);
   }
   
   static bool IsNewSession()
   {
      static datetime last_reset = 0;
      datetime now = TimeCurrent();
      string time_str = TimeToString(now, TIME_MINUTES);
      
      if (time_str == InpLondonStart || time_str == InpNYStart)
      {
         if (now - last_reset > 60) 
         {
            last_reset = now;
            return true;
         }
      }
      return false;
   }
};

//+------------------------------------------------------------------+
//| VWAP Calculator                                                  |
//+------------------------------------------------------------------+
class CVWAP
{
private:
   double sum_pv;
   double sum_v;
   datetime last_reset;

public:
   CVWAP() : sum_pv(0), sum_v(0), last_reset(0) {}

   void Update()
   {
      if (CSessionManager::IsNewSession()) Reset();
      
      MqlRates rates[];
      if (CopyRates(_Symbol, PERIOD_M1, 0, 1, rates) > 0)
      {
         sum_pv += (double)rates[0].tick_volume * ((rates[0].high + rates[0].low + rates[0].close) / 3.0);
         sum_v += (double)rates[0].tick_volume;
      }
   }

   double GetValue() { return (sum_v > 0) ? (sum_pv / sum_v) : 0; }
   void Reset() { sum_pv = 0; sum_v = 0; }
};

CVWAP ExtVWAP;

//+------------------------------------------------------------------+
//| Signal Generator                                                 |
//+------------------------------------------------------------------+
class CSignalGenerator
{
public:
   static bool GetLiquidityLevels(ENUM_TIMEFRAMES tf, int lookback, SSweepLevel &level)
   {
      int hi_idx = iHighest(_Symbol, tf, MODE_HIGH, lookback, 1);
      int lo_idx = iLowest(_Symbol, tf, MODE_LOW, lookback, 1);
      
      if(hi_idx < 0 || lo_idx < 0) return false;
      
      level.high = iHigh(_Symbol, tf, hi_idx);
      level.low = iLow(_Symbol, tf, lo_idx);
      return true;
   }

   static bool CheckSweep(bool long_bias, SSweepLevel &m1, SSweepLevel &m5, double &sweep_price)
   {
      MqlRates rates[];
      if(CopyRates(_Symbol, PERIOD_M1, 0, 2, rates) < 2) return false;
      
      MqlRates curr = rates[1];
      MqlRates prev = rates[0];
      
      double buffer = InpSweepBuffer * _Point;
      
      if(long_bias)
      {
         // Sweep below low
         double target_low = MathMin(m1.low, m5.low);
         if(prev.low < target_low - buffer && curr.close > target_low)
         {
            // Rejection candle: Long lower wick
            double body = MathAbs(curr.open - curr.close);
            double lower_wick = MathMin(curr.open, curr.close) - curr.low;
            if(lower_wick > body) 
            {
               sweep_price = curr.low;
               return true;
            }
         }
      }
      else
      {
         // Sweep above high
         double target_high = MathMax(m1.high, m5.high);
         if(prev.high > target_high + buffer && curr.close < target_high)
         {
            // Rejection candle: Long upper wick
            double body = MathAbs(curr.open - curr.close);
            double upper_wick = curr.high - MathMax(curr.open, curr.close);
            if(upper_wick > body)
            {
               sweep_price = curr.high;
               return true;
            }
         }
      }
      return false;
   }
};

//+------------------------------------------------------------------+
//| Risk Manager Class                                               |
//+------------------------------------------------------------------+
class CRiskManager
{
public:
   static bool SkipTrade()
   {
      if(daily_limit_hit) return true;
      
      double current_equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double loss = (daily_start_equity - current_equity) / daily_start_equity * 100.0;
      
      if(loss >= InpDailyLossLimit)
      {
         Print("Daily loss limit hit: ", loss, "%");
         daily_limit_hit = true;
         return true;
      }
      
      if(trades_today >= InpMaxTradesSession)
      {
         Print("Max trades for session reached");
         return true;
      }
      
      if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpread)
      {
         Print("Spread too high: ", SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
         return true;
      }
      
      return false;
   }

   static double CalculateLotSize(double sl_distance)
   {
      double risk_amount = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPercent / 100.0);
      double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      
      if(sl_distance <= 0 || tick_value <= 0) return 0;
      
      double lots = risk_amount / (sl_distance / tick_size * tick_value);
      lots = MathFloor(lots / lot_step) * lot_step;
      
      double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      
      return MathMin(max_lot, MathMax(min_lot, lots));
   }
};

//+------------------------------------------------------------------+
//| Trade Executor Class                                             |
//+------------------------------------------------------------------+
class CTradeExecutor
{
public:
   static void ManagePositions(double vwap)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(ExtPosition.SelectByIndex(i) && ExtPosition.Symbol() == _Symbol && ExtPosition.Magic() == 0)
         {
            double price = ExtPosition.PriceCurrent();
            double open = ExtPosition.PriceOpen();
            double sl = ExtPosition.StopLoss();
            double tp = ExtPosition.TakeProfit();
            long type = ExtPosition.PositionType();
            
            // 1. Partial TP (1R)
            double r_dist = MathAbs(open - sl);
            if(InpEnablePartialTP && ExtPosition.Volume() > SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN) * 1.5)
            {
               bool tp1_hit = (type == POSITION_TYPE_BUY) ? (price >= open + r_dist) : (price <= open - r_dist);
               if(tp1_hit)
               {
                  Print("TP1 Hit. Partial Close 50%");
                  ExtTrade.PositionClosePartial(ExtPosition.Ticket(), ExtPosition.Volume() * 0.5);
                  continue;
               }
            }
            
            // 2. VWAP Touch for TP2
            bool vwap_touch = (type == POSITION_TYPE_BUY) ? (price >= vwap) : (price <= vwap);
            if(vwap_touch)
            {
               Print("VWAP Touched. Closing position.");
               ExtTrade.PositionClose(ExtPosition.Ticket());
               continue;
            }
            
            // 3. Time-based exit
            datetime open_time = (datetime)ExtPosition.Time();
            if(TimeCurrent() - open_time > InpTimeoutCandles * 60)
            {
               Print("Timeout reached. Closing position.");
               ExtTrade.PositionClose(ExtPosition.Ticket());
            }
         }
      }
   }

   static bool OpenTrade(bool buy, double sl, double tp)
   {
      double sl_dist = MathAbs(SymbolInfoDouble(_Symbol, buy ? SYMBOL_ASK : SYMBOL_BID) - sl);
      double lots = CRiskManager::CalculateLotSize(sl_dist);
      
      if(lots <= 0) return false;
      
      bool res = false;
      if(buy) res = ExtTrade.Buy(lots, _Symbol, 0, sl, tp, "Liquidity Sweep Long");
      else    res = ExtTrade.Sell(lots, _Symbol, 0, sl, tp, "Liquidity Sweep Short");
      
      if(res)
      {
         trades_today++;
         last_trade_time = TimeCurrent();
      }
      return res;
   }
};

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // 0. Daily Reset Logic
   static int last_day = -1;
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.day != last_day)
   {
      trades_today = 0;
      daily_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
      daily_limit_hit = false;
      last_day = dt.day;
   }

   // 1. Update Indicators and VWAP
   if(!UpdateIndicators()) return;
   ExtVWAP.Update();
   double current_vwap = ExtVWAP.GetValue();
   
   // 2. Manage existing positions
   CTradeExecutor::ManagePositions(current_vwap);
   
   // 3. Trade Entry Logic
   if(PositionsTotal() > 0) return; // One trade at a time
   
   // Session and Risk Filters
   if(!CSessionManager::IsInSession()) return;
   if(CRiskManager::SkipTrade()) return;
   
   // Bias
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool long_bias = (price > current_vwap + InpVWAP_Buffer * _Point) && (vEMA20[0] > vEMA50[0]);
   bool short_bias = (price < current_vwap - InpVWAP_Buffer * _Point) && (vEMA20[0] < vEMA50[0]);

   if(!long_bias && !short_bias) return;
   
   // Liquidity Levels
   SSweepLevel m1, m5;
   if(!CSignalGenerator::GetLiquidityLevels(PERIOD_M1, InpLookback, m1)) return;
   if(!CSignalGenerator::GetLiquidityLevels(PERIOD_M5, InpLookback, m5)) return;
   
   double sweep_price = 0;
   if(CSignalGenerator::CheckSweep(long_bias, m1, m5, sweep_price))
   {
      MqlRates rates[];
      CopyRates(_Symbol, PERIOD_M1, 0, 1, rates);
      
      if(long_bias)
      {
         // Long Entry Conditions
         bool candle_above_ema = (rates[0].close > vEMA20[0]);
         bool rsi_rebound = (vRSI[0] >= 30 && vRSI[0] <= 45); // RSI rebounds from 30-40 zone
         
         if(candle_above_ema && rsi_rebound)
         {
            Print("Long entry conditions met.");
            double sl = sweep_price - InpSL_Buffer * _Point;
            double tp = rates[0].close + (rates[0].close - sl) * 2.0; // TP2 = 2R
            CTradeExecutor::OpenTrade(true, sl, tp);
         }
      }
      else
      {
         // Short Entry Conditions
         bool candle_below_ema = (rates[0].close < vEMA20[0]);
         bool rsi_rollover = (vRSI[0] <= 70 && vRSI[0] >= 55); // RSI rolls over from 60-70 zone
         
         if(candle_below_ema && rsi_rollover)
         {
            Print("Short entry conditions met.");
            double sl = sweep_price + InpSL_Buffer * _Point;
            double tp = rates[0].close - (sl - rates[0].close) * 2.0; // TP2 = 2R
            CTradeExecutor::OpenTrade(false, sl, tp);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Get Indicator Buffers                                            |
//+------------------------------------------------------------------+
bool UpdateIndicators()
{
   if(CopyBuffer(hEMA20, 0, 0, 3, vEMA20) < 3) return false;
   if(CopyBuffer(hEMA50, 0, 0, 3, vEMA50) < 3) return false;
   if(CopyBuffer(hRSI, 0, 0, 3, vRSI) < 3) return false;
   return true;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!ExtSymbol.Name(_Symbol))
      return INIT_FAILED;
      
   // Initialize Indicators
   hEMA20 = iMA(_Symbol, PERIOD_M1, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEMA50 = iMA(_Symbol, PERIOD_M1, InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   hRSI   = iRSI(_Symbol, PERIOD_M1, InpRSI_Period, PRICE_CLOSE);
   
   if(hEMA20 == INVALID_HANDLE || hEMA50 == INVALID_HANDLE || hRSI == INVALID_HANDLE)
   {
      Print("Failed to initialize indicators");
      return INIT_FAILED;
   }
   
   // Sizing/Risk Setup
   daily_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Array setup
   ArraySetAsSeries(vEMA20, true);
   ArraySetAsSeries(vEMA50, true);
   ArraySetAsSeries(vRSI, true);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hEMA20);
   IndicatorRelease(hEMA50);
   IndicatorRelease(hRSI);
}
