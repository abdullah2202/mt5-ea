//+------------------------------------------------------------------+
//|                                             Universal_M30_EA.mq5 |
//|                                                      Antigravity |
//+------------------------------------------------------------------+
#property copyright   "Antigravity"
#property link        ""
#property version     "1.00"
#property description "Universal M30 Breakout EA - No discretionary logic"

//--- Input Parameters
input string InpSessions = "--- Session settings ---";
input int InpLondonStartHour = 10; // London Session Start Hour(Server Time)
input int InpLondonEndHour = 18; // London Session End Hour
input int InpNYStartHour = 15; // NY Session Start Hour
input int InpNYEndHour = 23; // NY Session End Hour
input double InpRiskPercent = 1.0; // Risk Percentage per trade
input string InpBotID = "Universal_M30_EA"; // Bot Name(for logging)
input string InpDashboardURL = "http://192.168.0.25:5000 / api / event"; // Dashboard URL
input long InpMagicNumber = 123456;// Magic Number
input double InpFirstTP = 20.0; // First TP
input double InpTrailingStart = 30.0; // Trailing Start Profit
input int InpATRPeriod = 14; // ATR Period for Max Candle Body
input double InpPipValue = 0.1; // Pip Value(e.g. 0.1 for XAUUSD, 0.01 for GBPJPY)

//--- Global Variables
double g_pip;
double g_point;
int g_atr_handle = INVALID_HANDLE;

datetime g_setup_time = 0;
double g_setup_high = 0;
double g_setup_low = 0;
bool g_setup_valid_long = false;
bool g_setup_valid_short = false;
bool g_wick_formed_long = false;
bool g_wick_formed_short = false;

double g_nearest_res = 0;
double g_nearest_sup = 0;

double g_setup_sl = 0;

int g_ticket = 0;
bool g_partial_closed = false;
bool g_sl_partial_closed = false;
bool g_trailing_activated = false;

double g_total_partial_pips = 0.0;
double g_total_partial_profit = 0.0;
int g_total_partial_trades = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    if(_Period != PERIOD_M30)
    {
        Print("This EA must be run on the M30 timeframe.");
        return(INIT_FAILED);
    }
     
    g_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    g_pip = InpPipValue; // Use the chosen pip value directly
   
    Print("g_pip: ", g_pip, " on symbol: ", _Symbol);
    
    g_atr_handle = iATR(_Symbol, _Period, InpATRPeriod);
    if(g_atr_handle == INVALID_HANDLE)
    {
        Print("Failed to create ATR handle");
        return(INIT_FAILED);
    }
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(g_atr_handle != INVALID_HANDLE)
    IndicatorRelease(g_atr_handle);
}

//+------------------------------------------------------------------+
//| Subroutine: Session Filtering                                    |
//+------------------------------------------------------------------+
bool IsValidSession()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int h = dt.hour;
   
    bool isLondon = (h >= InpLondonStartHour && h < InpLondonEndHour);
    bool isNY = (h >= InpNYStartHour && h <= InpNYEndHour);
   
    return(isLondon || isNY);
}

//+------------------------------------------------------------------+
//| Subroutine: HTTP Event Logging                                   |
//+------------------------------------------------------------------+
void LogEvent(string event_type, string details)
{
    char post_data[], result[];
    string result_headers;
    string headers = "Content - Type: application / json\r\n";
    int timeout = 5000;
   
    MqlDateTime dt;
    TimeCurrent(dt);
    string timestamp = StringFormat(" % 04d - % 02d - % 02dT % 02d: % 02d: % 02dZ", dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec);
   
    string payload = StringFormat(" {\"bot_id\":\" % s\", \"event_type\":\" % s\", \"timestamp\":\" % s\", \"details\": { % s}}",
        InpBotID, event_type, timestamp, details);
                                 
        StringToCharArray(payload, post_data, 0, WHOLE_ARRAY, CP_UTF8);
        ArrayResize(post_data, ArraySize(post_data) - 1);
   
        ResetLastError();
        // return;
        int res = WebRequest("POST", InpDashboardURL, headers, timeout, post_data, result, result_headers);
        if(res == - 1)
        Print("WebRequest Error: ", GetLastError());
    }

//+------------------------------------------------------------------+
//| Subroutine: Calculate Lot Size                                   |
//+------------------------------------------------------------------+
    double CalculateLotSize(double price, double sl)
    {
        double sl_distance = MathAbs(price - sl);
        if(sl_distance == 0) return 0.0;

        double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double risk_amount = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPercent / 100.0);

        double sl_ticks = sl_distance / tick_size;
        double lot_size = risk_amount / (sl_ticks * tick_value);

        double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
        double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
        double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

        lot_size = MathRound(lot_size / lot_step) * lot_step;
        if(lot_size < min_lot * 2) lot_size = min_lot * 2;
        if(lot_size > max_lot) lot_size = max_lot;
        return lot_size;
    }

//+------------------------------------------------------------------+
//| Subroutine: Get Filling Mode                                     |
//+------------------------------------------------------------------+
    ENUM_ORDER_TYPE_FILLING GetFillingMode()
    {
        int filling = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
        if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
        if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
        return ORDER_FILLING_RETURN;
    }

//+------------------------------------------------------------------+
//| Subroutine: S/R Detection                                        |
//+------------------------------------------------------------------+
    void DetectSupportResistance()
    {
        double rates_open[], rates_close[], rates_high[], rates_low[];
        ArraySetAsSeries(rates_open, true);
        ArraySetAsSeries(rates_close, true);
        ArraySetAsSeries(rates_high, true);
        ArraySetAsSeries(rates_low, true);

        if(CopyOpen(_Symbol, _Period, 1, 100, rates_open) < 100) return;
        if(CopyClose(_Symbol, _Period, 1, 100, rates_close) < 100) return;
        if(CopyHigh(_Symbol, _Period, 1, 100, rates_high) < 100) return;
        if(CopyLow(_Symbol, _Period, 1, 100, rates_low) < 100) return;

        double temp_res = 0;
        double temp_sup = 0;

// Find initial resistance
        for(int i = 1; i < 99; i++)
        {
            bool is_bullish = (rates_close[i + 1] > rates_open[i + 1]);
            bool is_bearish = (rates_close[i] < rates_open[i]);
            if(is_bullish && is_bearish)
            {
                temp_res = rates_close[i + 1]; // Close of bullish candle
                break;
            }
        }
  
// Find initial support
        for(int i = 1; i < 99; i++)
        {
            bool is_bearish = (rates_close[i + 1] < rates_open[i + 1]);
            bool is_bullish = (rates_close[i] > rates_open[i]);
            if(is_bearish && is_bullish)
            {
                temp_sup = rates_close[i + 1]; // Close of bearish candle
                break;
            }
        }
  
// Scan for updates within 100 candles
        for(int i = 1; i < 99; i++)
        {
  // Resistance update rule
            bool is_bullish_res = (rates_close[i + 1] > rates_open[i + 1]);
            bool is_bearish_res = (rates_close[i] < rates_open[i]);
            if(is_bullish_res && is_bearish_res)
            {
                double candidate_res = rates_close[i + 1];
                if(temp_res > 0 && candidate_res > temp_res && candidate_res <= temp_res + 10 * g_pip)
                {
                    temp_res = candidate_res;
                }
            }
    
  // Support update rule
            bool is_bearish_sup = (rates_close[i + 1] < rates_open[i + 1]);
            bool is_bullish_sup = (rates_close[i] > rates_open[i]);
            if(is_bearish_sup && is_bullish_sup)
            {
                double candidate_sup = rates_close[i + 1];
                if(temp_sup > 0 && candidate_sup < temp_sup && candidate_sup >= temp_sup - 10 * g_pip)
                {
                    temp_sup = candidate_sup;
                }
            }
        }
  
        g_nearest_res = temp_res;
        g_nearest_sup = temp_sup;
    }

//+------------------------------------------------------------------+
//| Subroutine: Validate Candle Body and Wicks                       |
//+------------------------------------------------------------------+
    bool IsValidCandleSetup(double last_open, double last_close, double last_high, double last_low)
    {
        double body = MathAbs(last_close - last_open);
        double upper_wick = last_high - MathMax(last_open, last_close);
        double lower_wick = MathMin(last_open, last_close) - last_low;

// Get ATR for max body
        double atr_buffer[1];
        if(CopyBuffer(g_atr_handle, 0, 1, 1, atr_buffer) < 1)
        {
            Print("Failed to copy ATR buffer");
            return false;
        }
        double max_body = atr_buffer[0];

// Candle body rules
        if(body < 5 * g_pip || body > max_body) {
            Print("Setup Invalidated: Body size is not in range");
            return false;
        }

// Wick rules (both upper and lower wicks)
        if(upper_wick < 1 * g_pip || upper_wick > body * 0.5) {
            Print("Setup Invalidated: Upper wick is not in range");
            return false;
        }
        if(lower_wick < 1 * g_pip || lower_wick > body * 0.5) {
            Print("Setup Invalidated: Lower wick is not in range");
            return false;
        }

        return true;
    }

//+------------------------------------------------------------------+
//| Subroutine: Setup Validation (Called on New Candle Open)         |
//+------------------------------------------------------------------+
    void EvaluateSetup()
    {
// Invalidate previous setups
        if(g_setup_valid_long) LogEvent("Setup Cancelled", "\"reason\":\"New candle open\"");
        if(g_setup_valid_short) LogEvent("Setup Cancelled", "\"reason\":\"New candle open\"");

        g_setup_valid_long = false;
        g_setup_valid_short = false;
        g_wick_formed_long = false;
        g_wick_formed_short = false;

        double last_open = iOpen(_Symbol, _Period, 1);
        double last_close = iClose(_Symbol, _Period, 1);
        double last_high = iHigh(_Symbol, _Period, 1);
        double last_low = iLow(_Symbol, _Period, 1);

        if(last_open == 0 || last_close == 0) return;

// Setup Conditions for Long
        if(g_nearest_res > 0)
        {
            if(last_open < g_nearest_res && last_close > g_nearest_res)
            {
                if((last_close - g_nearest_res) >= 1 * g_pip)
                {
                    if(IsValidCandleSetup(last_open, last_close, last_high, last_low))
                    {
                        g_setup_valid_long = true;
                        g_setup_time = iTime(_Symbol, _Period, 1);
                        g_setup_high = last_high;
                        g_setup_low = last_low;
            
                    // SL will be calculated at the moment of entry in CheckEntry()
                        g_setup_sl = 0;

                        double entry_price = g_setup_high + 1 * g_pip;
                        double est_lot = CalculateLotSize(entry_price, g_setup_sl);
                        LogEvent("Setup Found", StringFormat("\"direction\":\"BUY\", \"price\": % f, \"sl\": % f, \"lot_size\": % f", entry_price, g_setup_sl, est_lot));
                    }
                }
            }
        }
  
// Setup Conditions for Short
        if(g_nearest_sup > 0 && !g_setup_valid_long) // No overlapping setups
        {
            if(last_open > g_nearest_sup && last_close < g_nearest_sup)
            {
                if((g_nearest_sup - last_close) >= 1 * g_pip)
                {
                    if(IsValidCandleSetup(last_open, last_close, last_high, last_low))
                    {
                        g_setup_valid_short = true;
                        g_setup_time = iTime(_Symbol, _Period, 1);
                        g_setup_high = last_high;
                        g_setup_low = last_low;
            
                    // SL will be calculated at the moment of entry in CheckEntry()
                        g_setup_sl = 0;

                        double entry_price = g_setup_low - 1 * g_pip;
                        double est_lot = CalculateLotSize(entry_price, g_setup_sl);
                        LogEvent("Setup Found", StringFormat("\"direction\":\"SELL\", \"price\": % f, \"sl\": % f, \"lot_size\": % f", entry_price, g_setup_sl, est_lot));
                    }
                }
            }
        }
    }

//+------------------------------------------------------------------+
//| Subroutine: Entry Logic and Validation                           |
//+------------------------------------------------------------------+
    void CheckEntry()
    {
        if(!IsValidSession()) return;

        double current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double current_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        double entry_low = iLow(_Symbol, _Period, 0);
        double entry_high = iHigh(_Symbol, _Period, 0);
        double entry_open = iOpen(_Symbol, _Period, 0);

// Long Entry Check
        if(g_setup_valid_long)
        {
  // Setup invalid if entry candle breaks below setup candle low
            if(current_price < g_setup_low)
            {
                g_setup_valid_long = false;
                LogEvent("Setup Cancelled", "\"reason\":\"Price broke below setup candle low before entry\"");
                Print("Entry Invalidated: Price broke below setup candle low before entry");
                return;
            }
    
  // Lower wick must be >= 2 pips and form BEFORE breaking setup candle high
            double current_lower_wick = entry_open - entry_low;
            if(current_lower_wick >= 2 * g_pip)
            g_wick_formed_long = true;
     
  // Check entry trigger: lower wick formed BEFORE breaking setup candle high
            if(g_wick_formed_long && current_ask >= g_setup_high + 1 * g_pip)
            {
                double entry_sl = iLow(_Symbol, _Period, 0) - 1 * g_pip;
                ExecuteOrder(ORDER_TYPE_BUY, g_setup_high + 1 * g_pip, entry_sl);
                Print("=== New Order: ORDER_TYPE_BUY at: ", g_setup_high + 1 * g_pip);
                g_setup_valid_long = false; // Prevent further entries
            }
        }
  
// Short Entry Check
        if(g_setup_valid_short)
        {
  // Setup invalid if entry candle breaks above setup candle high
            if(current_price > g_setup_high)
            {
                g_setup_valid_short = false;
                LogEvent("Setup Cancelled", "\"reason\":\"Price broke above setup candle high before entry\"");
                Print("Entry Invalidated: Price broke above setup candle high before entry");
                return;
            }
    
  // Upper wick must be >= 2 pips and form BEFORE breaking setup candle low
            double current_upper_wick = entry_high - entry_open;
            if(current_upper_wick >= 2 * g_pip)
            g_wick_formed_short = true;
     
  // Check entry trigger: upper wick formed BEFORE breaking setup candle low
            if(g_wick_formed_short && current_price <= g_setup_low - 1 * g_pip)
            {
                double entry_sl = iHigh(_Symbol, _Period, 0) + 1 * g_pip;
                ExecuteOrder(ORDER_TYPE_SELL, g_setup_low - 1 * g_pip, entry_sl);
                Print("=== New Order: ORDER_TYPE_SELL at: ", g_setup_low - 1 * g_pip);
                g_setup_valid_short = false; // Prevent further entries
            }
        }
    }

//+------------------------------------------------------------------+
//| Subroutine: Execute Order                                        |
//+------------------------------------------------------------------+
    void ExecuteOrder(ENUM_ORDER_TYPE type, double price, double sl)
    {
        if(PositionsTotal() > 0) return; // Max 1 open trade

        double lot_size = CalculateLotSize(price, sl);
        if(lot_size == 0) return;

        MqlTradeRequest request;
        MqlTradeResult result;
        ZeroMemory(request);
        ZeroMemory(result);

        request.action = TRADE_ACTION_DEAL;
        request.symbol = _Symbol;
        request.volume = lot_size;
        request.type = type;
        request.price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
        request.sl = sl;
        request.deviation = 10;
        request.magic = InpMagicNumber;
        request.type_filling = GetFillingMode();

        if(OrderSend(request, result))
        {
            if(result.retcode == TRADE_RETCODE_DONE)
            {
                g_partial_closed = false;
                g_sl_partial_closed = false;
                g_trailing_activated = false;
                LogEvent("Entry", StringFormat("\"symbol\":\" % s\", \"direction\":\" % s\", \"price\": % f, \"volume\": % f",
                _Symbol, (type == ORDER_TYPE_BUY) ? "BUY" : "SELL", request.price, request.volume));
            }
            else
            {
                LogEvent("Error", StringFormat("\"reason\":\"OrderSend partial failure retcode % d\"", result.retcode));
            }
        }
        else
        {
            LogEvent("Error", StringFormat("\"reason\":\"OrderSend failed with error % d\"", GetLastError()));
        }
    }

//+------------------------------------------------------------------+
//| Subroutine: Trade Management                                     |
//+------------------------------------------------------------------+
    void ManageTrades()
    {
        if(PositionsTotal() == 0) return;

        for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
            ulong ticket = PositionGetTicket(i);
            if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
            continue;
     
            double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
            double current_price = PositionGetDouble(POSITION_PRICE_CURRENT);
            double sl_price = PositionGetDouble(POSITION_SL);
            double volume = PositionGetDouble(POSITION_VOLUME);
            long type = PositionGetInteger(POSITION_TYPE);
  
            double profit_pips = 0;
            if(type == POSITION_TYPE_BUY)
            profit_pips = (current_price - open_price) / g_pip;
            else if(type == POSITION_TYPE_SELL)
            profit_pips = (open_price - current_price) / g_pip;
     
        // Print("profit pips: ", profit_pips);
        // Defensive Partial Close: 50% of position if price reaches 50% of SL
            if(!g_partial_closed && !g_sl_partial_closed && sl_price > 0)
            {
                bool trigger_defensive = false;
                if(type == POSITION_TYPE_BUY && current_price <= (open_price + sl_price) / 2.0) trigger_defensive = true;
                if(type == POSITION_TYPE_SELL && current_price >= (open_price + sl_price) / 2.0) trigger_defensive = true;

                if(trigger_defensive)
                {
                    return;
                    MqlTradeRequest request;
                    MqlTradeResult result;
                    ZeroMemory(request);
                    ZeroMemory(result);
                    Print("Defensive Close 50 % at 50 % of SL reached");
                    request.action = TRADE_ACTION_DEAL;
                    request.position = ticket;
                    request.symbol = _Symbol;
                    request.volume = NormalizeDouble(volume / 2.0, 2);
                    if(request.volume > 0)
                    {
                        request.type = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
                        request.price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                        request.magic = InpMagicNumber;
                        request.type_filling = GetFillingMode();
                        if(OrderSend(request, result))
                        {
                            g_sl_partial_closed = true;
                            double part_pnl = PositionGetDouble(POSITION_PROFIT) / 2.0;
                            LogEvent("Update", StringFormat("\"action\":\"DEFENSIVE_CLOSE_PARTIAL\", \"old_lot_size\": % f, \"new_lot_size\": % f, \"partial_pnl\": % f", volume, volume - request.volume, part_pnl));
                        }
                    }
                }
            }

  // Rule: At +10 pips profit, close 50% and move SL to breakeven
            if(!g_partial_closed && profit_pips >= InpFirstTP)
            {
                MqlTradeRequest request;
                MqlTradeResult result;
                ZeroMemory(request);
                ZeroMemory(result);
                Print("Close 50 % and SL to BE at: ", profit_pips);
                request.action = TRADE_ACTION_DEAL;
                request.position = ticket;
                request.symbol = _Symbol;
                request.volume = NormalizeDouble(volume / 2.0, 2);
                if(request.volume > 0)
                {
                    request.type = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
                    request.price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                    request.magic = InpMagicNumber;
                    request.type_filling = GetFillingMode();
                    if(OrderSend(request, result))
                    {
                        g_partial_closed = true;
                        double part_pnl = PositionGetDouble(POSITION_PROFIT) / 2.0;
                    
                        g_total_partial_pips = g_total_partial_pips + profit_pips;
                        g_total_partial_profit = g_total_partial_profit + (request.volume * 10.0 * profit_pips);
                        g_total_partial_trades++;
                    
                        LogEvent("Update", StringFormat("\"action\":\"CLOSE_PARTIAL\", \"old_lot_size\": % f, \"new_lot_size\": % f, \"partial_pnl\": % f", volume, volume - request.volume, part_pnl));
                    }
                }
       
     // Move SL to Breakeven
                if(sl_price != open_price)
                {
                    ZeroMemory(request);
                    ZeroMemory(result);
                    request.action = TRADE_ACTION_SLTP;
                    request.position = ticket;
                    request.symbol = _Symbol;
                    request.sl = open_price;
                    request.tp = PositionGetDouble(POSITION_TP);
                    if(OrderSend(request, result))
                    {
                        LogEvent("Update", StringFormat("\"action\":\"MOVE_SL_TO_BE\", \"old_sl\": % f, \"new_sl\": % f", sl_price, open_price));
                    }
                }
            }
    
  // Rule: At +20 pips profit, activate 10 pips trailing stop forwards only
            if(!g_trailing_activated && profit_pips >= InpTrailingStart)
            {
                g_trailing_activated = true;
            }
    
            if(g_trailing_activated)
            {
                double new_sl = 0;
                if(type == POSITION_TYPE_BUY)
                {
                    new_sl = current_price - 10 * g_pip;
                    if(new_sl > sl_price + 0.1)
                    {
                        MqlTradeRequest request;
                        MqlTradeResult result;
                        ZeroMemory(request);
                        ZeroMemory(result);
                        request.action = TRADE_ACTION_SLTP;
                        request.position = ticket;
                        request.symbol = _Symbol;
                        request.sl = new_sl;
                        request.tp = PositionGetDouble(POSITION_TP);
                        if(OrderSend(request, result))
                        {
                            LogEvent("Update", StringFormat("\"action\":\"UPDATE_TRAILING_SL\", \"old_sl\": % f, \"new_sl\": % f", sl_price, new_sl));
                        }
                    }
                }
                else if(type == POSITION_TYPE_SELL)
                {
                    new_sl = current_price + 10 * g_pip;
                    if(new_sl < sl_price || sl_price == 0)
                    {
                        MqlTradeRequest request;
                        MqlTradeResult result;
                        ZeroMemory(request);
                        ZeroMemory(result);
                        request.action = TRADE_ACTION_SLTP;
                        request.position = ticket;
                        request.symbol = _Symbol;
                        request.sl = new_sl;
                        request.tp = PositionGetDouble(POSITION_TP);
                        if(OrderSend(request, result))
                        {
                            LogEvent("Update", StringFormat("\"action\":\"UPDATE_TRAILING_SL\", \"old_sl\": % f, \"new_sl\": % f", sl_price, new_sl));
                        }
                    }
                }
            }
        }
    }

//+------------------------------------------------------------------+
//| Trade Transaction Event                                          |
//+------------------------------------------------------------------+
    void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& request, const MqlTradeResult& result)
    {
        if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
        {
            if(HistoryDealSelect(trans.deal))
            {
                long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
                if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
                {
                    double pnl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
                    long magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
                    if(magic == InpMagicNumber)
                    {
                        LogEvent("Exit", StringFormat("\"symbol\":\" % s\", \"pnl\": % f", trans.symbol, pnl));
                    }
                }
            }
        }
    }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
    void OnTick()
    {
        static datetime last_bar_time = 0;
        datetime current_bar_time = iTime(_Symbol, _Period, 0);

// Check for new bar
        if(current_bar_time != last_bar_time)
        {
            last_bar_time = current_bar_time;
            DetectSupportResistance();
            EvaluateSetup();
            Print("Total Partial Pips: ", g_total_partial_pips);
            Print("Total Partial Profit: ", g_total_partial_profit);
            Print("Total Partial Trades: ", g_total_partial_trades);
        }
  
// Always execute tick-level checks if conditions are met
        if(PositionsTotal() == 0)
        {
            CheckEntry();
        }
  
        ManageTrades();
    }
//+------------------------------------------------------------------+
