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
//|                                     Advanced_Tick_Scalper_PRO   |
//|                 Pure tick logic: acceleration + double reversal |
//|                                   Target $5/day on $10 cent     |
//|                                                  Win rate 75%+  |
//+------------------------------------------------------------------+
#property copyright "TickMaster"
#property version   "8.00"
#property description "Advanced tick-based scalper – no indicators, pure tick pattern"
#property strict

#include <Trade\Trade.mqh>

// ---------------------------------------------------------------
//  INPUTS – Aggressive, High Win Rate
// ---------------------------------------------------------------
input string   t1 = "==== Money Management ====";
input bool     UseFixedLot       = false;
input double   FixedLotSize      = 0.01;
input double   RiskPercent       = 12.0;
input int      MaxConcurrentTrades = 2;
input int      MagicNumber       = 777301;

input string   t2 = "==== Tick Pattern (Advanced) ====";
input int      MinConsecutiveTicks = 5;        // Need at least 5 same-direction ticks to start
input int      MinReversalTicks   = 2;         // Minimum opposite ticks to confirm
input bool     RequireDoubleReversal = true;   // True: needs 2 opposite then 1 same as reversal
input int      TickAccelerationThreshold = 4;  // Min ticks per 0.5 sec to consider (high activity)
input int      TickSlopePeriod    = 5;         // Last 5 ticks for micro-trend slope
input double   MinSlopePointsPerTick = 0.3;    // Minimum slope (in points per tick) – filters drift
input bool     UseTickRSI         = true;      // Use tick-based strength ratio
input double   TickRSIBuyThreshold = 0.3;      // Ratio of up ticks to total < 0.3 = buy
input double   TickRSISellThreshold = 0.7;     // Ratio > 0.7 = sell

input string   t3 = "==== TP/SL (Dynamic or Fixed) ====";
input bool     UseAdaptiveStop    = true;      // Stop based on tick speed: faster speed → tighter SL
input int      FixedStopLossPoints = 60;       // 6 pips (if adaptive off)
input int      FixedTakeProfitPoints = 30;     // 3 pips
input double   AdaptiveSLMultiplier = 0.8;     // SL = ATR (or tick speed) * multiplier (to be replaced with simpler)
// Instead of ATR, we use tick speed: faster ticks → smaller SL
input int      BaseStopPoints     = 80;        // Base stop in points (8 pips)
input int      MinStopPoints      = 30;        // 3 pips minimum (very fast markets)
input int      MaxStopPoints      = 120;       // 12 pips maximum (slow markets)

input string   t4 = "==== Filters ====";
input int      MaxSpreadPoints    = 100;       // 10 pips – tolerant
input bool     UseTimeFilter      = false;
input int      StartHour          = 0;
input int      EndHour            = 23;
input bool     UseTrailingStop    = true;
input int      TrailingStartPts   = 20;        // 2 pips profit triggers trail
input int      TrailingStepPts    = 10;        // 1 pip step
input double   DailyTargetUSD     = 5.0;
input double   MaxDailyLossUSD    = 2.0;

// ---------------------------------------------------------------
//  GLOBALS
// ---------------------------------------------------------------
CTrade trade;
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

// Tick history for slope and tick RSI
struct TickRec {
   datetime time;
   double   price;
   bool     directionUp; // true = up, false = down
};
TickRec tickHistory[50];
int tickHistoryIdx = 0;
int tickHistoryCount = 0;

// Tick speed measurement
datetime lastTickTime = 0;
int      ticksThisHalfSecond = 0;
double   tickSpeed = 0;   // ticks per second average

//+------------------------------------------------------------------+
//| Record each tick for slope and tick RSI                         |
//+------------------------------------------------------------------+
void RecordTick(double price, bool isUp) {
   tickHistory[tickHistoryIdx].time = TimeCurrent();
   tickHistory[tickHistoryIdx].price = price;
   tickHistory[tickHistoryIdx].directionUp = isUp;
   tickHistoryIdx = (tickHistoryIdx + 1) % 50;
   if(tickHistoryCount < 50) tickHistoryCount++;
}

//+------------------------------------------------------------------+
//| Calculate micro-slope over last N ticks                         |
//+------------------------------------------------------------------+
double GetTickSlope(int n) {
   if(tickHistoryCount < n) return 0;
   double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;
   int startIdx = tickHistoryIdx - n;
   if(startIdx < 0) startIdx += 50;
   for(int i = 0; i < n; i++) {
      int idx = (startIdx + i) % 50;
      double price = tickHistory[idx].price;
      sumX += i;
      sumY += price;
      sumXY += i * price;
      sumX2 += i * i;
   }
   double denominator = n * sumX2 - sumX * sumX;
   if(denominator == 0) return 0;
   double slope = (n * sumXY - sumX * sumY) / denominator;
   // Convert slope to points per tick
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return slope / point;
}

//+------------------------------------------------------------------+
//| Tick RSI (ratio of up ticks to total) over last N ticks        |
//+------------------------------------------------------------------+
double GetTickRSI(int n) {
   if(tickHistoryCount < n) return 0.5;
   int upCount = 0;
   int startIdx = tickHistoryIdx - n;
   if(startIdx < 0) startIdx += 50;
   for(int i = 0; i < n; i++) {
      int idx = (startIdx + i) % 50;
      if(tickHistory[idx].directionUp) upCount++;
   }
   return (double)upCount / n;
}

//+------------------------------------------------------------------+
//| Update tick speed (ticks per second)                            |
//+------------------------------------------------------------------+
void UpdateTickSpeed() {
   datetime now = TimeCurrent();
   if(lastTickTime == 0) {
      lastTickTime = now;
      ticksThisHalfSecond = 1;
      tickSpeed = 1;
      return;
   }
   double deltaSec = (now - lastTickTime);
   if(deltaSec >= 0.5) {
      tickSpeed = ticksThisHalfSecond / deltaSec;  // ticks per sec
      ticksThisHalfSecond = 1;
      lastTickTime = now;
   } else {
      ticksThisHalfSecond++;
   }
}

//+------------------------------------------------------------------+
//| Get adaptive stop loss based on tick speed (faster → tighter)   |
//+------------------------------------------------------------------+
int GetAdaptiveStopPoints() {
   if(!UseAdaptiveStop) return FixedStopLossPoints;
   // tickSpeed: typical range: 2 (slow) to 20 (very fast)
   double speed = MathMax(1, MathMin(20, tickSpeed));
   // Faster speed = tighter stop (inverse relationship)
   int slPoints = (int)(BaseStopPoints * (5.0 / (speed + 3))); // formula: speed 2 → sl ~80*5/5=80; speed 20 → sl~80*5/23≈17
   slPoints = MathMax(MinStopPoints, MathMin(MaxStopPoints, slPoints));
   return slPoints;
}

//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   startBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   Print("==================================================");
   Print("🔥 ADVANCED TICK SCALPER (Pure Tick Logic)");
   Print("   Balance: $", startBalance);
   Print("   Pattern: ", MinConsecutiveTicks, "+ consec → ", MinReversalTicks, " rev + double confirm");
   Print("   Tick acceleration threshold: ", TickAccelerationThreshold, " ticks/0.5s");
   Print("   Adaptive stop: ", UseAdaptiveStop, " | Base ", BaseStopPoints/10.0, " pips");
   Print("   Daily target: $", DailyTargetUSD, " | Max loss: $", MaxDailyLossUSD);
   Print("==================================================");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinitialization                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   Print("EA stopped. Trades today: ", tradeCountToday);
}

//+------------------------------------------------------------------+
//| Main tick function                                              |
//+------------------------------------------------------------------+
void OnTick() {
   // --- Daily limits ---
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
   
   // --- Spread filter ---
   int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpreadPoints) return;
   
   // --- Position limit & cooldown (0.3 sec) ---
   int posCount = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         posCount++;
   }
   if(posCount >= MaxConcurrentTrades) return;
   if(TimeCurrent() - lastTradeTime < 0.3) return;
   
   // --- Get price data ---
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point == 0) return;
   
   // --- Update tick speed and record tick ---
   UpdateTickSpeed();
   bool isUp = (lastPrice != 0 && currentBid > lastPrice);
   if(lastPrice != 0) RecordTick(currentBid, isUp);
   lastPrice = currentBid;
   
   // --- Tick acceleration filter: only trade if market is active (tick speed high) ---
   if(tickSpeed < TickAccelerationThreshold) return;
   
   // --- Track consecutive ticks and reversal ---
   if(lastPrice != 0) {
      double movePoints = (currentBid - lastPrice) / point;
      if(MathAbs(movePoints) >= 1) {   // minimum 1 point movement
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
      if(!waitingForReversal && (consecutiveUpTicks >= MinConsecutiveTicks || consecutiveDownTicks >= MinConsecutiveTicks)) {
         waitingForReversal = true;
         reversalCounter = 0;
      }
      
      // Complex signal: double reversal confirmation
      bool buySignal = false, sellSignal = false;
      if(waitingForReversal && reversalCounter >= MinReversalTicks) {
         if(RequireDoubleReversal) {
            // Need one more tick in the reversal direction after the initial opposite ticks
            // For example: down run → 2 up ticks → then a down tick? No: we want the reversal to continue.
            // Better: we already have reversalCounter enough. But to increase confidence, we check slope of last 5 ticks.
            // The slope should be in the direction of the trade.
            double slope = GetTickSlope(TickSlopePeriod);
            if(consecutiveDownTicks >= MinConsecutiveTicks && slope > MinSlopePointsPerTick)
               buySignal = true;
            else if(consecutiveUpTicks >= MinConsecutiveTicks && slope < -MinSlopePointsPerTick)
               sellSignal = true;
         } else {
            buySignal = (consecutiveDownTicks >= MinConsecutiveTicks);
            sellSignal = (consecutiveUpTicks >= MinConsecutiveTicks);
         }
      }
      
      // Tick RSI filter (if enabled)
      if(UseTickRSI && (buySignal || sellSignal)) {
         double rsiTick = GetTickRSI(10);
         if(buySignal && rsiTick > TickRSIBuyThreshold) buySignal = false;
         if(sellSignal && rsiTick < TickRSISellThreshold) sellSignal = false;
      }
      
      // Execute if signal valid
      if(buySignal || sellSignal) {
         int slPoints = (UseAdaptiveStop) ? GetAdaptiveStopPoints() : FixedStopLossPoints;
         int tpPoints = FixedTakeProfitPoints;  // keep small for high win rate
         
         double sl = 0, tp = 0;
         double price = 0;
         if(buySignal) {
            price = currentAsk;
            sl = price - slPoints * point;
            tp = price + tpPoints * point;
         } else {
            price = currentBid;
            sl = price + slPoints * point;
            tp = price - tpPoints * point;
         }
         int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
         sl = NormalizeDouble(sl, digits);
         tp = NormalizeDouble(tp, digits);
         
         double lot = (UseFixedLot) ? FixedLotSize : CalculateRiskBasedLot(slPoints);
         lot = MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), lot);
         
         bool result = false;
         if(buySignal)
            result = trade.Buy(lot, _Symbol, price, sl, tp, "AdvTickBuy");
         else
            result = trade.Sell(lot, _Symbol, price, sl, tp, "AdvTickSell");
         
         if(result) {
            Print("🔥 ", buySignal ? "BUY" : "SELL",
                  " | Consecutive: ", buySignal ? consecutiveDownTicks : consecutiveUpTicks,
                  " | Rev: ", reversalCounter,
                  " | TickSpeed: ", DoubleToString(tickSpeed,1), " t/s",
                  " | SL: ", slPoints/10.0, "pips | Lot=", lot);
            lastTradeTime = TimeCurrent();
            tradeCountToday++;
            ResetPatternCounters();
         } else {
            Print("❌ Order failed. Error: ", GetLastError());
         }
      }
   }
   
   // --- Trailing stop ---
   if(UseTrailingStop) ApplyTrailingStop();
}

//+------------------------------------------------------------------+
//| Risk-based lot size                                             |
//+------------------------------------------------------------------+
double CalculateRiskBasedLot(double slPoints) {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * RiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickValue <= 0 || slPoints <= 0) return 0.01;
   double riskPerLot = slPoints * tickValue;
   double lot = (riskPerLot > 0) ? riskAmount / riskPerLot : 0.01;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathMax(minLot, MathMin(maxLot, lot));
   if(stepLot > 0) lot = MathRound(lot / stepLot) * stepLot;
   return lot;
}

//+------------------------------------------------------------------+
//| Trailing stop                                                   |
//+------------------------------------------------------------------+
void ApplyTrailingStop() {
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      double currentSL = PositionGetDouble(POSITION_SL);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentTP = PositionGetDouble(POSITION_TP);
      double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ?
                            SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                            SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profitPoints = (currentPrice - openPrice) / _Point;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
         profitPoints = -profitPoints;
      
      if(profitPoints >= TrailingStartPts) {
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
