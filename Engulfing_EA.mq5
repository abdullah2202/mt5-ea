//+------------------------------------------------------------------+
//|                                                Engulfing_EA.mq5 |
//|                                                      Antigravity |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright   "Antigravity"
#property link        "https://www.mql5.com"
#property version     "1.00"
#property description "Engulfing Strategy - M30"
#property strict

//--- Input Parameters
input string InpSessions = "--- Session Settings ---";
input int InpLondonStartHour = 8; // London Start(Server Hour)
input int InpLondonEndHour = 17; // London End
input int InpNYStartHour = 13; // NY Start
input int InpNYEndHour = 22; // NY End

input string InpTradeSettings = "--- Trade Settings ---";
input double InpRiskPercent = 1.0; // Risk % per trade
input long InpMagicNumber = 220201; // Magic Number
input int InpBodyLimitPips = 50; // Max Setup Candle Body(Pips)
input int InpWickReqPips = 2; // Min Wick Req(Pips)
input int InpBreakoutPips = 1; // Breakout Offset(Pips)

input string InpMgmtSettings = "--- Management ---";
input int InpPartialPips = 10; // Partial Close @ (Pips)
input int InpTrailingStart = 20; // Trailing Start @ (Pips)
input int InpTrailingStep = 10; // Trailing Distance(Pips)

//--- Global Variables
double g_pip;
double g_point;

datetime g_setup_time = 0;
double g_setup_high = 0;
double g_setup_low = 0;
bool g_setup_long = false;
bool g_setup_short = false;
bool g_wick_formed = false;

bool g_partial_closed = false;
bool g_trailing_active = false;

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
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    
    // Robust pip calculation for various instruments
    if(digits == 3 || digits == 5) g_pip = g_point * 10;
    else if(digits == 2 || digits == 4) g_pip = g_point;
    else g_pip = g_point;

    // Special case for Gold (XAUUSD)
    if(StringFind(_Symbol, "XAUUSD") >= 0 || StringFind(_Symbol, "GOLD") >= 0)
    {
        g_pip = 0.1;
    }

    Print("EA Initialized on ", _Symbol, " M30. Pip size: ", g_pip);
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Check if current time is within allowed sessions                |
//+------------------------------------------------------------------+
bool IsValidSession()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int h = dt.hour;
    
    bool isLondon = (h >= InpLondonStartHour && h < InpLondonEndHour);
    bool isNY = (h >= InpNYStartHour && h < InpNYEndHour);
    
    return(isLondon || isNY);
}

//+------------------------------------------------------------------+
//| Detect Setup (Called on New Bar)                                 |
//+------------------------------------------------------------------+
void DetectSetup()
{
    g_setup_long = false;
    g_setup_short = false;
    g_wick_formed = false;
    g_setup_time = 0;

    if(!IsValidSession()) return;

    // Need at least 4 candles (3 directional + 1 engulfing)
    double o[5], c[5], h[5], l[5];
    if(CopyOpen(_Symbol, _Period, 1, 4, o) < 4 ||
    CopyClose(_Symbol, _Period, 1, 4, c) < 4 ||
    CopyHigh(_Symbol, _Period, 1, 4, h) < 4 ||
    CopyLow(_Symbol, _Period, 1, 4, l) < 4) return;

    // Array is [0] oldest to [3] most recent (candle 1)
    // Setup candle is candle 1 (index 3)
    
    // Long Setup: 3 bear (index 0,1,2) + 1 bull (index 3)
    bool three_bear = (c[0] < o[0] && c[1] < o[1] && c[2] < o[2]);
    bool engulf_bull = (c[3] > o[3]);
    if(three_bear && engulf_bull)
    {
        double setup_body = c[3] - o[3];
        double last_bear_body = o[2] - c[2];
        if(setup_body > last_bear_body && setup_body <= InpBodyLimitPips * g_pip)
        {
            g_setup_long = true;
            g_setup_high = h[3];
            g_setup_low = l[3];
            g_setup_time = iTime(_Symbol, _Period, 1);
            Print("Long Setup Detected at ", g_setup_time);
        }
    }

    // Short Setup: 3 bull (index 0,1,2) + 1 bear (index 3)
    bool three_bull = (c[0] > o[0] && c[1] > o[1] && c[2] > o[2]);
    bool engulf_bear = (c[3] < o[3]);
    if(three_bull && engulf_bear)
    {
        double setup_body = o[3] - c[3];
        double last_bull_body = c[2] - o[2];
        if(setup_body > last_bull_body && setup_body <= InpBodyLimitPips * g_pip)
        {
            g_setup_short = true;
            g_setup_high = h[3];
            g_setup_low = l[3];
            g_setup_time = iTime(_Symbol, _Period, 1);
            Print("Short Setup Detected at ", g_setup_time);
        }
    }
}

//+------------------------------------------------------------------+
//| Monitor Entry (Called on Every Tick)                             |
//+------------------------------------------------------------------+
void MonitorEntry()
{
    if(!g_setup_long && !g_setup_short) return;
    if(!IsValidSession())
    {
        g_setup_long = false;
        g_setup_short = false;
        return;
    }

    // Current candle data
    double entry_open = iOpen(_Symbol, _Period, 0);
    double entry_high = iHigh(_Symbol, _Period, 0);
    double entry_low = iLow(_Symbol, _Period, 0);
    double current_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double current_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    if(g_setup_long)
    {
        // 1. Check for bottom wick (min 2 pips)
        double bottom_wick = entry_open - entry_low;
        if(bottom_wick >= InpWickReqPips * g_pip) g_wick_formed = true;

        // 2. Setup invalidated if High is broken BEFORE wick
        if(!g_wick_formed && current_ask > g_setup_high)
        {
            Print("Long Setup Invalidated: High broken before wick.");
            g_setup_long = false;
            return;
        }

        // 3. Trigger Trade: Wick formed AND High broken by 1 pip
        if(g_wick_formed && current_ask >= g_setup_high + InpBreakoutPips * g_pip)
        {
            double sl = entry_low + 1 * g_pip; // As requested: Low + 1 pip
            ExecuteTrade(ORDER_TYPE_BUY, current_ask, sl);
            g_setup_long = false;
        }
    }
    else if(g_setup_short)
    {
        // 1. Check for top wick (min 2 pips)
        double top_wick = entry_high - entry_open;
        if(top_wick >= InpWickReqPips * g_pip) g_wick_formed = true;

        // 2. Setup invalidated if Low is broken BEFORE wick
        if(!g_wick_formed && current_bid < g_setup_low)
        {
            Print("Short Setup Invalidated: Low broken before wick.");
            g_setup_short = false;
            return;
        }

        // 3. Trigger Trade: Wick formed AND Low broken by 1 pip
        if(g_wick_formed && current_bid <= g_setup_low - InpBreakoutPips * g_pip)
        {
            double sl = entry_high - 1 * g_pip; // Symmetric logic: High - 1 pip
            ExecuteTrade(ORDER_TYPE_SELL, current_bid, sl);
            g_setup_short = false;
        }
    }
}

//+------------------------------------------------------------------+
//| Execute Trade                                                    |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type, double price, double sl)
{
    if(PositionsTotal() > 0) return; // Limit to 1 trade

    double lot = CalculateLotSize(price, sl);
    if(lot <= 0) return;

    MqlTradeRequest request;
    MqlTradeResult result;
    ZeroMemory(request);
    ZeroMemory(result);

    request.action = TRADE_ACTION_DEAL;
    request.symbol = _Symbol;
    request.volume = lot;
    request.type = type;
    request.price = price;
    request.sl = sl;
    request.magic = InpMagicNumber;
    request.deviation = 10;
    request.type_filling = ORDER_FILLING_FOK; // FOK usually works, or detect automatically

    if(!OrderSend(request, result))
    {
        Print("OrderSend Error: ", GetLastError());
    }
    else
    {
        g_partial_closed = false;
        g_trailing_active = false;
        Print("Trade Opened: ", EnumToString(type), " Lots: ", lot, " SL: ", sl);
    }
}

//+------------------------------------------------------------------+
//| Calculate Lot Size based on Risk                                 |
//+------------------------------------------------------------------+
double CalculateLotSize(double price, double sl)
{
    double sl_dist = MathAbs(price - sl);
    if(sl_dist <= 0) return 0;

    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double risk_val = balance * (InpRiskPercent / 100.0);
    double tick_val = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    
    if(tick_size == 0 || tick_val == 0) return 0;

    double lot = risk_val / (sl_dist / tick_size * tick_val);
    
    double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    lot = MathFloor(lot / step) * step;
    if(lot < min_lot) lot = min_lot;
    if(lot > max_lot) lot = max_lot;

    return lot;
}

//+------------------------------------------------------------------+
//| Manage Active Trades                                             |
//+------------------------------------------------------------------+
void ManageTrades()
{
    if(PositionsTotal() == 0) return;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(!PositionSelectByTicket(ticket)) continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

        double open_p = PositionGetDouble(POSITION_PRICE_OPEN);
        double curr_p = PositionGetDouble(POSITION_PRICE_CURRENT);
        double sl_p = PositionGetDouble(POSITION_SL);
        double vol = PositionGetDouble(POSITION_VOLUME);
        ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

        double profit_pips = (type == POSITION_TYPE_BUY) ? (curr_p - open_p) / g_pip : (open_p - curr_p) / g_pip;

        // 1. Partial Close @ 10 pips + SL to BE
        if(!g_partial_closed && profit_pips >= InpPartialPips)
        {
            if(ClosePartial(ticket, vol / 2.0))
            {
                g_partial_closed = true;
                MoveSL(ticket, open_p);
            }
        }

        // 2. Trailing Stop @ 20 pips
        if(profit_pips >= InpTrailingStart) g_trailing_active = true;

        if(g_trailing_active)
        {
            double desired_sl = (type == POSITION_TYPE_BUY) ? (curr_p - InpTrailingStep * g_pip) : (curr_p + InpTrailingStep * g_pip);
            
            bool update = false;
            if(type == POSITION_TYPE_BUY && desired_sl > sl_p + 1 * g_pip) update = true;
            if(type == POSITION_TYPE_SELL && (desired_sl < sl_p - 1 * g_pip || sl_p == 0)) update = true;

            if(update) MoveSL(ticket, desired_sl);
        }
    }
}

//+------------------------------------------------------------------+
//| Close Part of Position                                          |
//+------------------------------------------------------------------+
bool ClosePartial(ulong ticket, double volume)
{
    MqlTradeRequest request;
    MqlTradeResult result;
    ZeroMemory(request);
    ZeroMemory(result);

    volume = MathFloor(volume / SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP)) * SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    if(volume < SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)) return false;

    request.action = TRADE_ACTION_DEAL;
    request.position = ticket;
    request.symbol = _Symbol;
    request.volume = volume;
    request.type = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
    request.price = (request.type == ORDER_TYPE_SELL) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    request.magic = InpMagicNumber;
    request.deviation = 10;
    request.type_filling = ORDER_FILLING_FOK;

    if(OrderSend(request, result))
    {
        Print("Partial Close Executed: ", volume);
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| Move Stop Loss                                                   |
//+------------------------------------------------------------------+
void MoveSL(ulong ticket, double sl)
{
    MqlTradeRequest request;
    MqlTradeResult result;
    ZeroMemory(request);
    ZeroMemory(result);

    request.action = TRADE_ACTION_SLTP;
    request.position = ticket;
    request.symbol = _Symbol;
    request.sl = sl;
    request.tp = PositionGetDouble(POSITION_TP);

    if(!OrderSend(request, result))
    {
        Print("Move SL Error: ", GetLastError());
    }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    static datetime last_bar = 0;
    datetime curr_bar = iTime(_Symbol, _Period, 0);

    if(curr_bar != last_bar)
    {
        last_bar = curr_bar;
        DetectSetup();
    }

    if(PositionsTotal() == 0)
    {
        MonitorEntry();
    }

    ManageTrades();
}
