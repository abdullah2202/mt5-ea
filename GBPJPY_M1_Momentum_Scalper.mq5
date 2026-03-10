//+------------------------------------------------------------------+
//|                                GBPJPY_M1_Momentum_Scalper.mq5 |
//|                                  Copyright 2024, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright   "Copyright 2024, Antigravity"
#property link        ""
#property version     "1.10"
#property strict
#property description "GBPJPY M1 Momentum Scalper - Optimized for Strategy Tester"

#include <Trade\Trade.mqh>

//--- Input Parameters
input double InpLotSize = 0.1; // Lot Size
input int InpStopLoss = 120; // Stop Loss in Points
input int InpTakeProfit = 100; // Take Profit in Points
input int InpTrailingStop = 50; // Trailing Stop in Points(0 to disable)

input int InpEMAPeriod = 20; // EMA Period for Momentum
input int InpRSIPeriod = 14; // RSI Period
input double InpMinRSIMomentum = 40.0; // Min RSI Level
input double InpMaxRSIMomentum = 60.0; // Max RSI Level

input bool InpUseTrendFilter = false; // Use 200 EMA Trend Filter
input int InpFilterEMAPeriod = 200; // Trend Filter EMA Period

input int InpStartHour = 8; // London Session Start Hour
input int InpEndHour = 12; // London Session End Hour
input long InpMagic = 12345; // Magic Number

//--- Global Variables
int handleEMA; // Handle for EMA Momentum
int handleRSI; // Handle for RSI
int handleFilterEMA; // Handle for Trend Filter EMA
CTrade trade; // Trade class instance

//+------------------------------------------------------------------+
//| Helper: Check if current time is within trading hours            |
//+------------------------------------------------------------------+
bool IsTradingTime()
{
    MqlDateTime dt;
    TimeCurrent(dt);
   
    if(dt.hour >= InpStartHour && dt.hour < InpEndHour)
    return true;
      
    return false;
}

//+------------------------------------------------------------------+
//| Helper: Select position by Magic Number                          |
//+------------------------------------------------------------------+
bool PositionSelectByMagic(string symbol, long magic)
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetString(POSITION_SYMBOL) == symbol && PositionGetInteger(POSITION_MAGIC) == magic)
            return true;
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| Helper: Manage Trailing Stop                                     |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
    if(InpTrailingStop <= 0) return;

    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    if(PositionSelectByMagic(_Symbol, InpMagic))
    {
        long type = PositionGetInteger(POSITION_TYPE);
        double sl = PositionGetDouble(POSITION_SL);
        double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);

        if(type == POSITION_TYPE_BUY)
        {
            if(bid - openPrice > InpTrailingStop * point)
            {
                double newSL = bid - InpTrailingStop * point;
                if(newSL > sl + 10 * point || sl == 0)
                {
                    trade.PositionModify(_Symbol, newSL, PositionGetDouble(POSITION_TP));
                }
            }
        }
        else if(type == POSITION_TYPE_SELL)
        {
            if(openPrice - ask > InpTrailingStop * point)
            {
                double newSL = ask + InpTrailingStop * point;
                if(newSL < sl - 10 * point || sl == 0)
                {
                    trade.PositionModify(_Symbol, newSL, PositionGetDouble(POSITION_TP));
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Check symbol
    if(_Symbol != "GBPJPY")
    {
        if(StringFind(_Symbol, "GBPJPY") < 0)
        {
            Print("Error: This EA is intended for GBPJPY only.");
            return(INIT_FAILED);
        }
    }

   // Check timeframe
    if(_Period != PERIOD_M1)
    {
        Print("Error: This EA is intended for M1 timeframe only.");
        return(INIT_FAILED);
    }

   // Initialize indicator handles
    handleEMA = iMA(_Symbol, _Period, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
    if(handleEMA == INVALID_HANDLE)
    {
        Print("Error creating EMA handle");
        return(INIT_FAILED);
    }

    handleRSI = iRSI(_Symbol, _Period, InpRSIPeriod, PRICE_CLOSE);
    if(handleRSI == INVALID_HANDLE)
    {
        Print("Error creating RSI handle");
        return(INIT_FAILED);
    }

    handleFilterEMA = iMA(_Symbol, _Period, InpFilterEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
    if(handleFilterEMA == INVALID_HANDLE)
    {
        Print("Error creating Filter EMA handle");
        return(INIT_FAILED);
    }

   // Set Magic Number
    trade.SetExpertMagicNumber(InpMagic);

    Print("GBPJPY Momentum Scalper Initialized.");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    IndicatorRelease(handleEMA);
    IndicatorRelease(handleRSI);
    IndicatorRelease(handleFilterEMA);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    if(!IsTradingTime()) return;

    if(PositionSelectByMagic(_Symbol, InpMagic))
    {
        ManageTrailingStop();
        return;
    }

    double emaValues[3];
    double rsiValues[1];
    double filterEMAValues[1];
   
    if(CopyBuffer(handleEMA, 0, 0, 3, emaValues) < 3) return;
    if(CopyBuffer(handleRSI, 0, 0, 1, rsiValues) < 1) return;
    if(CopyBuffer(handleFilterEMA, 0, 0, 1, filterEMAValues) < 1) return;

    ArraySetAsSeries(emaValues, true);
   
    double currentEMA = emaValues[0];
    double previousEMA = emaValues[1];
    double olderEMA = emaValues[2];
    double currentRSI = rsiValues[0];
    double currentFilterEMA = filterEMAValues[0];

    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

    double curClose = iClose(_Symbol, _Period, 0);
    double curLow = iLow(_Symbol, _Period, 0);
    double prevLow = iLow(_Symbol, _Period, 1);
    double curHigh = iHigh(_Symbol, _Period, 0);
    double prevHigh = iHigh(_Symbol, _Period, 1);

    bool rsiFilter = (currentRSI >= InpMinRSIMomentum && currentRSI <= InpMaxRSIMomentum);
    if(!rsiFilter) return;

    bool trendFilterBuy = (!InpUseTrendFilter || bid > currentFilterEMA);
    bool trendFilterSell = (!InpUseTrendFilter || ask < currentFilterEMA);

   // --- BUY LOGIC ---
    bool buySlope = (previousEMA > olderEMA);
    bool buyPriceAbove = (bid > currentEMA);
    bool buyTrigger = (curLow <= currentEMA || prevLow <= previousEMA);
    bool buyCloseAbove = (curClose > currentEMA);

    if(buySlope && buyPriceAbove && buyTrigger && buyCloseAbove && trendFilterBuy)
    {
        double sl = ask - InpStopLoss * point;
        double tp = ask + InpTakeProfit * point;
        trade.Buy(InpLotSize, _Symbol, ask, sl, tp, "Momentum Scalp Buy");
    }

   // --- SELL LOGIC ---
    bool sellSlope = (previousEMA < olderEMA);
    bool sellPriceBelow = (ask < currentEMA);
    bool sellTrigger = (curHigh >= currentEMA || prevHigh >= previousEMA);
    bool sellCloseBelow = (curClose < currentEMA);

    if(sellSlope && sellPriceBelow && sellTrigger && sellCloseBelow && trendFilterSell)
    {
        double sl = bid + InpStopLoss * point;
        double tp = bid - InpTakeProfit * point;
        trade.Sell(InpLotSize, _Symbol, bid, sl, tp, "Momentum Scalp Sell");
    }
}
