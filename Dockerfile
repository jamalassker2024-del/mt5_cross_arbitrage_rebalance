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
//|                                           Tick_Pattern_Scalper   |
//|                     Tick-based high-probability pattern scalper  |
//|                              Target: $5/day on $10 cent account  |
//+------------------------------------------------------------------+
#property copyright "Tick Scalper Pro"
#property version   "4.00"
#property strict

#include <Trade\Trade.mqh>

// === Inputs (Aggressive Settings for $10 Cent) ===
input string   t1 = "==== Money Management ====";
input double   RiskPercent       = 15.0;       // 15% risk per trade (highly aggressive)
input int      StopLossPoints    = 80;         // 8 pips SL
input int      TakeProfitPoints  = 40;         // 4 pips TP (fast wins)
input int      MaxConcurrentTrades = 2;        // Max positions at once
input int      MagicNumber       = 888123;

input string   t2 = "==== Tick Pattern Detection ====";
input bool     UseReversalPattern  = true;     // 5 ticks same direction then reversal tick
input int      ReversalTicksNeeded = 5;        // Number of consecutive same-direction ticks
input bool     UseAccelerationPattern = true;  // Tick speed increase + small breakout
input int      AccelerationThreshold = 3;      // Ticks per 0.5 second threshold (for acceleration)
input int      BreakoutPoints        = 5;      // Price must move X points to confirm

input string   t3 = "==== Filters ====";
input int      MaxSpreadPoints   = 25;         // Max 2.5 pips spread
input bool     UseTimeFilter     = true;       // Only trade during active sessions
input int      StartHour         = 8;          // GMT hour to start (London open)
input int      EndHour           = 18;         // GMT hour to end (NY close)
input bool     UseTrailingStop   = true;
input int      TrailingStartPts  = 20;         // Start trailing at 2 pips profit
input int      TrailingStepPts   = 10;         // Trail by 1 pip

input string   t4 = "==== Daily Limits ====";
input double   DailyTargetUSD    = 5.0;        // Stop after $5 profit (500 cents)
input double   MaxDailyLossUSD   = 2.0;        // Stop after $2 loss (200 cents)

// === Globals ===
CTrade trade;
datetime lastTickTime = 0;
double lastPrice = 0;
int consecutiveUpTicks = 0;
int consecutiveDownTicks = 0;
int ticksInLastHalfSec = 0;
datetime lastHalfSecCheck = 0;
double dailyProfit = 0.0;
double startBalance = 0.0;
bool tradingHalted = false;
int tradeCountToday = 0;
datetime lastTradeTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   startBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   Print("==========================================");
   Print("⚡ TICK PATTERN SCALPER ACTIVE");
   Print("   Balance: $", startBalance);
   Print("   Risk per trade: ", RiskPercent, "%");
   Print("   TP: ", TakeProfitPoints/10.0, " pips | SL: ", StopLossPoints/10.0, " pips");
   Print("   Reversal pattern: ON | Acceleration pattern: ON");
   Print("   Daily target: $", DailyTargetUSD, " | Daily loss limit: $", MaxDailyLossUSD);
   Print("==========================================");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinitialization                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   Print("EA stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Tick function (the magic happens here)                          |
//+------------------------------------------------------------------+
void OnTick() {
   // --- Daily limits check ---
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyProfit = currentBalance - startBalance;
   
   if(dailyProfit >= DailyTargetUSD) {
      if(!tradingHalted) Print("🎯 Daily target reached: $", dailyProfit, " - Halted");
      tradingHalted = true;
      return;
   }
   if(dailyProfit <= -MaxDailyLossUSD) {
      if(!tradingHalted) Print("💀 Daily loss limit reached: $", dailyProfit, " - Halted");
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
         Print("🔄 New trading day - Resuming");
      }
      return;
   }
   
   // --- Time filter (active session only) ---
   if(UseTimeFilter) {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      int hour = dt.hour;
      if(hour < StartHour || hour > EndHour) return;
   }
   
   // --- Spread check ---
   int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpreadPoints) return;
   
   // --- Count open positions (respect max concurrent) ---
   int posCount = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         posCount++;
   }
   if(posCount >= MaxConcurrentTrades) return;
   
   // --- Cooldown: prevent too many trades in a second ---
   if(TimeCurrent() - lastTradeTime < 1) return;
   
   // === TICK PATTERN DETECTION ===
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentMid = (currentBid + currentAsk) / 2.0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   // --- Update tick counters (reversal pattern) ---
   if(lastPrice != 0) {
      if(currentMid > lastPrice) {
         consecutiveUpTicks++;
         consecutiveDownTicks = 0;
      } else if(currentMid < lastPrice) {
         consecutiveDownTicks++;
         consecutiveUpTicks = 0;
      }
   }
   lastPrice = currentMid;
   
   // --- Update acceleration counter (ticks per half second) ---
   datetime now = TimeCurrent();
   if(now - lastHalfSecCheck >= 0.5) {
      ticksInLastHalfSec = 1; // reset, count current tick as 1
      lastHalfSecCheck = now;
   } else {
      ticksInLastHalfSec++;
   }
   
   // --- Evaluate signals ---
   bool buySignal = false;
   bool sellSignal = false;
   
   // 1. Reversal pattern: 5+ consecutive ticks in one direction, then a tick in opposite direction
   if(UseReversalPattern) {
      static int lastConsecutiveUp = 0;
      static int lastConsecutiveDown = 0;
      
      // Detect reversal: we had consecutive up ticks, now a down tick
      if(consecutiveUpTicks >= ReversalTicksNeeded && currentMid < lastPrice) {
         buySignal = false; // Actually this would be a sell signal? Wait: consecutive up (price rose), then price drops -> sell signal
         sellSignal = true;
         Print("📉 Reversal pattern detected: Sell after ", consecutiveUpTicks, " upticks");
      }
      // Consecutive down ticks, then an up tick -> buy signal
      else if(consecutiveDownTicks >= ReversalTicksNeeded && currentMid > lastPrice) {
         buySignal = true;
         sellSignal = false;
         Print("📈 Reversal pattern detected: Buy after ", consecutiveDownTicks, " downticks");
      }
   }
   
   // 2. Acceleration pattern: high tick frequency + small price breakout
   if(UseAccelerationPattern && !buySignal && !sellSignal) {
      // If we received > AccelerationThreshold ticks in half second, and price moved beyond a threshold
      static int tickCount = 0;
      static double priceSnapshot = 0;
      static datetime snapshotTime = 0;
      
      if(now - snapshotTime > 0.5) {
         // Reset snapshot
         priceSnapshot = currentMid;
         snapshotTime = now;
         tickCount = 0;
      } else {
         tickCount++;
         if(tickCount >= AccelerationThreshold) {
            double priceMovePoints = MathAbs(currentMid - priceSnapshot) / point;
            if(priceMovePoints >= BreakoutPoints) {
               if(currentMid > priceSnapshot) {
                  buySignal = true;
                  Print("⚡ Acceleration pattern: BUY (", tickCount, " ticks in 0.5s, move ", priceMovePoints, " pts)");
               } else if(currentMid < priceSnapshot) {
                  sellSignal = true;
                  Print("⚡ Acceleration pattern: SELL (", tickCount, " ticks in 0.5s, move ", priceMovePoints, " pts)");
               }
            }
         }
      }
   }
   
   // --- If no signal, exit ---
   if(!buySignal && !sellSignal) return;
   
   // --- Execute trade ---
   double lot = CalculateLotSize();
   lot = MathMax(0.01, lot);
   
   double entryPrice, slPrice, tpPrice;
   if(buySignal) {
      entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      slPrice = entryPrice - StopLossPoints * point;
      tpPrice = entryPrice + TakeProfitPoints * point;
      slPrice = NormalizeDouble(slPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      tpPrice = NormalizeDouble(tpPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      
      if(trade.Buy(lot, _Symbol, entryPrice, slPrice, tpPrice, "TickPatBuy")) {
         Print("🔥 BUY executed | Lot=", lot, " | TP=", tpPrice, " | SL=", slPrice);
         lastTradeTime = TimeCurrent();
         tradeCountToday++;
         // Reset consecutive counters after trade to avoid double entries
         consecutiveUpTicks = 0;
         consecutiveDownTicks = 0;
      } else {
         Print("❌ Buy failed. Error: ", GetLastError());
      }
   }
   else if(sellSignal) {
      entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      slPrice = entryPrice + StopLossPoints * point;
      tpPrice = entryPrice - TakeProfitPoints * point;
      slPrice = NormalizeDouble(slPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      tpPrice = NormalizeDouble(tpPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      
      if(trade.Sell(lot, _Symbol, entryPrice, slPrice, tpPrice, "TickPatSell")) {
         Print("🔥 SELL executed | Lot=", lot, " | TP=", tpPrice, " | SL=", slPrice);
         lastTradeTime = TimeCurrent();
         tradeCountToday++;
         consecutiveUpTicks = 0;
         consecutiveDownTicks = 0;
      } else {
         Print("❌ Sell failed. Error: ", GetLastError());
      }
   }
   
   // --- Apply trailing stop to open positions ---
   if(UseTrailingStop) ApplyTrailingStop();
}

//+------------------------------------------------------------------+
//| Calculate lot size (risk-based)                                 |
//+------------------------------------------------------------------+
double CalculateLotSize() {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * RiskPercent / 100.0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double slPoints = StopLossPoints;
   double riskPerLot = slPoints * tickValue;
   double lot = riskAmount / riskPerLot;
   
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathMax(minLot, MathMin(maxLot, lot));
   lot = MathRound(lot / stepLot) * stepLot;
   lot = MathMax(0.01, lot);
   return lot;
}

//+------------------------------------------------------------------+
//| Apply trailing stop to open positions                           |
//+------------------------------------------------------------------+
void ApplyTrailingStop() {
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      double currentSL = PositionGetDouble(POSITION_SL);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
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
               trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
         } else {
            newSL = currentPrice + TrailingStepPts * _Point;
            if(newSL < currentSL || currentSL == 0)
               trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
         }
      }
   }
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
