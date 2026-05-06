FROM python:3.11-slim-bookworm

USER root
ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind xvfb fluxbox x11vnc novnc websockify \
    wget curl procps cabextract unzip dos2unix xdotool \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir mt5linux rpyc
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# =========================================================
# V16.3 - PROFIT-MAX VELOCITY BOT (ULTRA PROFITABILITY)
# =========================================================
RUN cat > /root/VALETAX_TICK_BOT_V16.mq5 << 'EOF'
//+------------------------------------------------------------------+
//|                               Ultra_Aggressive_Tick_Scalper_PRO |
//|                 High Win Rate Tick Reversal Scalper with Filters|
//|                                   Target $5+/day on $10 cent    |
//+------------------------------------------------------------------+
#property copyright "SuperScalper"
#property version   "6.00"
#property strict

#include <Trade\Trade.mqh>

// ---------------------------------------------------------------
//  INPUTS – Optimized for Aggressive High Win Rate
// ---------------------------------------------------------------
input string   t1 = "==== Money Management ====";
input bool     UseFixedLot       = false;      // true = fixed lot, false = risk %
input double   FixedLotSize      = 0.01;       // Fixed lot when UseFixedLot = true
input double   RiskPercent       = 12.0;       // Risk per trade (% of equity)
input int      MaxConcurrentTrades = 2;        // Max positions at once
input int      MagicNumber       = 888123;

input string   t2 = "==== Dynamic TP/SL (ATR based) ====";
input bool     UseATR_TP_SL      = true;       // If false, uses fixed points below
input int      ATRPeriod         = 14;         // ATR period
input double   StopLossATRMult   = 1.2;        // SL = ATR * multiplier
input double   TakeProfitATRMult = 0.8;        // TP = ATR * multiplier (smaller for high win rate)
input int      FixedStopLossPoints = 60;       // used if UseATR_TP_SL = false (6 pips)
input int      FixedTakeProfitPoints = 30;     // used if UseATR_TP_SL = false (3 pips)

input string   t3 = "==== Tick Pattern & Filters ====";
input int      ConsecutiveTicksNeeded = 3;     // Same-direction ticks before reversal
input int      ReversalTicksRequired = 2;      // Opposite ticks to confirm reversal
input int      MinTickMovementPoints = 2;      // Minimum price change per tick (filter noise)
input bool     UseRSIFilter       = true;      // RSI confirmation
input int      RsiPeriod          = 7;
input int      RsiBuyLevel        = 40;        // Buy only if RSI < 40
input int      RsiSellLevel       = 60;        // Sell only if RSI > 60
input bool     UseEMATrendFilter  = true;      // Trade only with trend
input int      EMAPeriod          = 20;        // EMA period (on M1)
input bool     UseATRVolatilityFilter = true;  // Avoid quiet markets
input double   MinATRValuePoints  = 30;        // Minimum ATR in points (3 pips)

input string   t4 = "==== Risk Management / Exit ====";
input int      MaxSpreadPoints    = 30;        // Max spread in points (3 pips)
input bool     UseBreakevenStop   = true;      // Move SL to entry after X profit
input int      BreakevenTriggerPts = 20;       // Move SL to entry after 2 pips profit
input bool     UseTrailingStop    = true;
input int      TrailingStartPts   = 30;        // Start trailing after 3 pips profit
input int      TrailingStepPts    = 15;        // Trail by 1.5 pips

input string   t5 = "==== Time & Daily Limits ====";
input bool     UseTimeFilter      = true;
input int      StartHour          = 8;         // GMT (London open)
input int      EndHour            = 20;        // GMT (NY close)
input double   DailyTargetUSD     = 5.0;       // Stop after this profit
input double   MaxDailyLossUSD    = 2.0;       // Stop after this loss

// ---------------------------------------------------------------
//  GLOBALS
// ---------------------------------------------------------------
CTrade trade;
int      atr_handle, rsi_handle, ema_handle;
double   atr_buf[], rsi_buf[], ema_buf[];
datetime lastTradeTime = 0;
double   lastPrice = 0;
int      consecutiveUpTicks = 0;
int      consecutiveDownTicks = 0;
int      reversalCounter = 0;
bool     waitingForReversal = false;
bool     lastDirectionUp = false;
double   dailyProfit = 0.0;
double   startBalance = 0.0;
bool     tradingHalted = false;
int      tradeCountToday = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   // Create indicators
   atr_handle = iATR(_Symbol, PERIOD_M1, ATRPeriod);
   if(UseRSIFilter) rsi_handle = iRSI(_Symbol, PERIOD_M1, RsiPeriod, PRICE_CLOSE);
   if(UseEMATrendFilter) ema_handle = iMA(_Symbol, PERIOD_M1, EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   
   if(atr_handle == INVALID_HANDLE) return INIT_FAILED;
   ArraySetAsSeries(atr_buf, true);
   if(UseRSIFilter) ArraySetAsSeries(rsi_buf, true);
   if(UseEMATrendFilter) ArraySetAsSeries(ema_buf, true);
   
   startBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   Print("==================================================");
   Print("⚡ SUPER TICK SCALPER PRO (High Win Rate)");
   Print("   Balance: $", startBalance);
   if(UseFixedLot) Print("   Lot mode: FIXED | Lot = ", FixedLotSize);
   else Print("   Lot mode: RISK% | Risk = ", RiskPercent, "% per trade");
   if(UseATR_TP_SL)
      Print("   TP/SL: ATR based (SL=", StopLossATRMult, "*ATR, TP=", TakeProfitATRMult, "*ATR)");
   else
      Print("   TP/SL: FIXED (", FixedTakeProfitPoints/10.0, "/", FixedStopLossPoints/10.0, " pips)");
   Print("   Filters: RSI=", UseRSIFilter, " EMA Trend=", UseEMATrendFilter, " Volatility=", UseATRVolatilityFilter);
   Print("   Daily target: $", DailyTargetUSD, " | Max loss: $", MaxDailyLossUSD);
   Print("==================================================");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinitialization                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   IndicatorRelease(atr_handle);
   if(UseRSIFilter) IndicatorRelease(rsi_handle);
   if(UseEMATrendFilter) IndicatorRelease(ema_handle);
   Print("EA stopped. Trades today: ", tradeCountToday);
}

//+------------------------------------------------------------------+
//| Get dynamic TP/SL based on ATR                                  |
//+------------------------------------------------------------------+
void GetDynamicTPSL(double &slPoints, double &tpPoints) {
   if(!UseATR_TP_SL) {
      slPoints = FixedStopLossPoints;
      tpPoints = FixedTakeProfitPoints;
      return;
   }
   if(CopyBuffer(atr_handle, 0, 0, 1, atr_buf) < 1) {
      slPoints = FixedStopLossPoints;
      tpPoints = FixedTakeProfitPoints;
      return;
   }
   double atrValue = atr_buf[0] / _Point;   // ATR in points
   slPoints = MathMax(20, atrValue * StopLossATRMult);   // min 2 pips
   tpPoints = MathMax(10, atrValue * TakeProfitATRMult); // min 1 pip
}

//+------------------------------------------------------------------+
//| Check if RSI confirms signal                                    |
//+------------------------------------------------------------------+
bool RSIConfirms(bool buySignal) {
   if(!UseRSIFilter) return true;
   if(CopyBuffer(rsi_handle, 0, 0, 1, rsi_buf) < 1) return false;
   double rsi = rsi_buf[0];
   if(buySignal) return (rsi < RsiBuyLevel);
   else return (rsi > RsiSellLevel);
}

//+------------------------------------------------------------------+
//| Check EMA trend filter                                          |
//+------------------------------------------------------------------+
bool TrendFilter(bool buySignal) {
   if(!UseEMATrendFilter) return true;
   if(CopyBuffer(ema_handle, 0, 0, 1, ema_buf) < 1) return false;
   double ema = ema_buf[0];
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(buySignal) return (price > ema);
   else return (price < ema);
}

//+------------------------------------------------------------------+
//| Main tick function                                              |
//+------------------------------------------------------------------+
void OnTick() {
   // --- Daily limits & reset ---
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyProfit = currentBalance - startBalance;
   if(dailyProfit >= DailyTargetUSD) {
      if(!tradingHalted) Print("🎯 Daily target reached: $", dailyProfit);
      tradingHalted = true;
      return;
   }
   if(dailyProfit <= -MaxDailyLossUSD) {
      if(!tradingHalted) Print("💀 Daily loss limit hit: $", dailyProfit);
      tradingHalted = true;
      return;
   }
   if(tradingHalted) {
      static datetime lastReset = 0;
      datetime now = TimeCurrent();
      MqlDateTime dt;
      TimeToStruct(now, dt);
      dt.hour = 0; dt.min = 0; dt.sec = 0;
      datetime midnight = StructToTime(dt);
      if(midnight != lastReset) {
         lastReset = midnight;
         tradingHalted = false;
         startBalance = currentBalance;
         tradeCountToday = 0;
         Print("🔄 New day - Resuming");
      }
      return;
   }
   
   // --- Time filter ---
   if(UseTimeFilter) {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      int hour = dt.hour;
      if(hour < StartHour || hour > EndHour) return;
   }
   
   // --- Spread filter ---
   int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpreadPoints) return;
   
   // --- ATR volatility filter ---
   if(UseATRVolatilityFilter) {
      if(CopyBuffer(atr_handle, 0, 0, 1, atr_buf) < 1) return;
      double atrPoints = atr_buf[0] / _Point;
      if(atrPoints < MinATRValuePoints) return;  // market too quiet – skip
   }
   
   // --- Position limit & cooldown ---
   int posCount = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         posCount++;
   }
   if(posCount >= MaxConcurrentTrades) return;
   if(TimeCurrent() - lastTradeTime < 1) return;
   
   // --- Get prices ---
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   // --- Tick reversal pattern detection ---
   if(lastPrice != 0) {
      double movePoints = (currentBid - lastPrice) / point;
      if(MathAbs(movePoints) >= MinTickMovementPoints) {
         if(movePoints > 0) {
            if(waitingForReversal && !lastDirectionUp) reversalCounter++;
            else if(!waitingForReversal) {
               consecutiveDownTicks = 0;
               consecutiveUpTicks++;
               lastDirectionUp = true;
            }
         } else if(movePoints < 0) {
            if(waitingForReversal && lastDirectionUp) reversalCounter++;
            else if(!waitingForReversal) {
               consecutiveUpTicks = 0;
               consecutiveDownTicks++;
               lastDirectionUp = false;
            }
         }
      }
      
      // Start waiting for reversal if enough consecutive ticks
      if(!waitingForReversal && (consecutiveUpTicks >= ConsecutiveTicksNeeded || consecutiveDownTicks >= ConsecutiveTicksNeeded)) {
         waitingForReversal = true;
         reversalCounter = 0;
      }
      
      // Signal when reversal confirmed
      if(waitingForReversal && reversalCounter >= ReversalTicksRequired) {
         bool buySignal = (consecutiveDownTicks >= ConsecutiveTicksNeeded);
         bool sellSignal = (consecutiveUpTicks >= ConsecutiveTicksNeeded);
         
         // Apply extra filters
         if(buySignal && RSIConfirms(true) && TrendFilter(true)) {
            ExecuteTrade(ORDER_TYPE_BUY, currentAsk);
            ResetPatternCounters();
         } else if(sellSignal && RSIConfirms(false) && TrendFilter(false)) {
            ExecuteTrade(ORDER_TYPE_SELL, currentBid);
            ResetPatternCounters();
         }
      }
   }
   
   lastPrice = currentBid;
   
   // --- Manage open positions (breakeven & trailing) ---
   ManageOpenPositions();
}

//+------------------------------------------------------------------+
//| Execute a trade with dynamic TP/SL                              |
//+------------------------------------------------------------------+
void ExecuteTrade(int orderType, double price) {
   double slPoints, tpPoints;
   GetDynamicTPSL(slPoints, tpPoints);
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double sl = 0, tp = 0;
   if(orderType == ORDER_TYPE_BUY) {
      sl = price - slPoints * point;
      tp = price + tpPoints * point;
   } else {
      sl = price + slPoints * point;
      tp = price - tpPoints * point;
   }
   sl = NormalizeDouble(sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
   tp = NormalizeDouble(tp, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
   
   double lot = (UseFixedLot) ? FixedLotSize : CalculateRiskBasedLot(slPoints);
   lot = MathMax(0.01, lot);
   
   bool result = false;
   if(orderType == ORDER_TYPE_BUY)
      result = trade.Buy(lot, _Symbol, price, sl, tp, "TickProBuy");
   else
      result = trade.Sell(lot, _Symbol, price, sl, tp, "TickProSell");
   
   if(result) {
      Print("🔥 ", orderType == ORDER_TYPE_BUY ? "BUY" : "SELL", 
            " | Lot=", lot, " | TP=", tpPoints/10.0, "pips | SL=", slPoints/10.0, "pips");
      lastTradeTime = TimeCurrent();
      tradeCountToday++;
   } else {
      Print("❌ Order failed. Error: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Risk-based lot size                                             |
//+------------------------------------------------------------------+
double CalculateRiskBasedLot(double slPoints) {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * RiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double riskPerLot = slPoints * tickValue;
   double lot = (riskPerLot > 0) ? riskAmount / riskPerLot : 0.01;
   
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathMax(minLot, MathMin(maxLot, lot));
   lot = MathRound(lot / stepLot) * stepLot;
   return lot;
}

//+------------------------------------------------------------------+
//| Breakeven stop and trailing stop                                |
//+------------------------------------------------------------------+
void ManageOpenPositions() {
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ?
                            SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                            SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profitPoints = (currentPrice - openPrice) / _Point;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
         profitPoints = -profitPoints;
      
      // Breakeven stop
      if(UseBreakevenStop && profitPoints >= BreakevenTriggerPts && currentSL == 0) {
         double newSL = openPrice;
         if(trade.PositionModify(ticket, newSL, currentTP))
            Print("🔒 Breakeven activated for ticket ", ticket);
      }
      
      // Trailing stop (only if beyond breakeven or custom)
      if(UseTrailingStop && profitPoints >= TrailingStartPts) {
         double newSL = 0;
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
            newSL = currentPrice - TrailingStepPts * _Point;
            if(newSL > currentSL)
               trade.PositionModify(ticket, newSL, currentTP);
         } else {
            newSL = currentPrice + TrailingStepPts * _Point;
            if(newSL < currentSL || currentSL == 0)
               trade.PositionModify(ticket, newSL, currentTP);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Reset pattern counters                                          |
//+------------------------------------------------------------------+
void ResetPatternCounters() {
   consecutiveUpTicks = 0;
   consecutiveDownTicks = 0;
   waitingForReversal = false;
   reversalCounter = 0;
}
//+------------------------------------------------------------------+
EOF

# ============================================
# 3. INSTALLATION & ENTRYPOINT
# ============================================
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e
rm -rf /tmp/.X*
Xvfb :1 -screen 0 1280x1024x24 -ac &
sleep 2
fluxbox &
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &
websockify --web=/usr/share/novnc 8080 0.0.0.0:5900 &
wineboot --init
sleep 5
MT5_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"
[ ! -f "$MT5_EXE" ] && wine /root/mt5setup.exe /auto && sleep 90
wine "$MT5_EXE" &
sleep 30

DATA_DIR=$(find /root/.wine -type d -path "*MetaQuotes/Terminal/*/MQL5" | head -n 1)
[ -z "$DATA_DIR" ] && DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
mkdir -p "$DATA_DIR/Experts"
cp /root/VALETAX_TICK_BOT_V16.mq5 "$DATA_DIR/Experts/VALETAX_TICK_BOT_V16.mq5"
wine "/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe" /compile:"$DATA_DIR/Experts/VALETAX_TICK_BOT_V16.mq5" /log:"/root/compile.log"

python3 -m mt5linux --host 0.0.0.0 --port 8001 &
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh
EXPOSE 8080 8001
CMD ["/bin/bash", "/entrypoint.sh"]
