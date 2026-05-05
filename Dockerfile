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
//|                                     Ultra_Aggressive_Tick_Scalper|
//|                     Trades on every tick, high win rate pattern  |
//|                              Target: $5/day on $10 cent account  |
//+------------------------------------------------------------------+
#property copyright "Aggressive Scalper"
#property version   "5.00"
#property strict

#include <Trade\Trade.mqh>

// === Inputs (Extremely Aggressive for $10 Cent) ===
input string   t1 = "==== Money Management ====";
input double   RiskPercent       = 15.0;       // 15% risk per trade (very aggressive)
input int      StopLossPoints    = 60;         // 6 pips SL
input int      TakeProfitPoints  = 30;         // 3 pips TP (tiny, for high win rate)
input int      MaxConcurrentTrades = 2;        // Max positions at once
input int      MagicNumber       = 777123;

input string   t2 = "==== Tick Pattern ====";
input int      ConsecutiveTicksNeeded = 3;     // Number of same-direction ticks to start
input int      ReversalTicksRequired = 2;      // Opposite ticks to confirm reversal
input int      MinTickMovementPoints = 2;      // Minimum price change per tick (filter noise)

input string   t3 = "==== Aggressive Filters ====";
input int      MaxSpreadPoints   = 30;         // Max 3 pips spread (lenient)
input bool     UseTimeFilter     = true;       // Only trade during active sessions
input int      StartHour         = 8;          // GMT (London open)
input int      EndHour           = 20;         // GMT (NY close)
input bool     UseTrailingStop   = true;
input int      TrailingStartPts  = 15;         // Start trailing at 1.5 pips profit
input int      TrailingStepPts   = 8;          // Trail by 0.8 pips

input string   t4 = "==== Daily Limits ====";
input double   DailyTargetUSD    = 5.0;        // Stop after $5 profit (500 cents)
input double   MaxDailyLossUSD   = 2.0;        // Stop after $2 loss (200 cents)

// === Globals ===
CTrade trade;
datetime lastTradeTime = 0;
double lastPrice = 0;
int consecutiveUpTicks = 0;
int consecutiveDownTicks = 0;
int reversalCounter = 0;   // number of opposite ticks after a run
bool waitingForReversal = false;
bool lastDirectionUp = false;
double dailyProfit = 0.0;
double startBalance = 0.0;
bool tradingHalted = false;
int tradeCountToday = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   startBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   Print("==========================================");
   Print("⚡ ULTRA AGGRESSIVE TICK SCALPER");
   Print("   Balance: $", startBalance);
   Print("   Risk per trade: ", RiskPercent, "%");
   Print("   TP: 3 pips | SL: 6 pips");
   Print("   Pattern: ", ConsecutiveTicksNeeded, " ticks one way + ", ReversalTicksRequired, " opposite = trade");
   Print("   Daily target: $", DailyTargetUSD, " | Max loss: $", MaxDailyLossUSD);
   Print("==========================================");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinitialization                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   Print("EA stopped. Trades today: ", tradeCountToday);
}

//+------------------------------------------------------------------+
//| Tick function – runs on every price change                      |
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
   
   // --- Position limit ---
   int posCount = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         posCount++;
   }
   if(posCount >= MaxConcurrentTrades) return;
   
   // --- Cooldown: avoid multiple trades in same second ---
   if(TimeCurrent() - lastTradeTime < 1) return;
   
   // --- Get current bid price (for sells) and ask (for buys) ---
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   // --- Track tick direction and magnitude ---
   if(lastPrice != 0) {
      double movePoints = (currentBid - lastPrice) / point;
      
      // Only count ticks with minimum movement (filter noise)
      if(MathAbs(movePoints) >= MinTickMovementPoints) {
         if(movePoints > 0) {
            // Up tick
            if(waitingForReversal && !lastDirectionUp) {
               // We were in a down run, now an up tick → reversal count
               reversalCounter++;
            } else if(!waitingForReversal) {
               // Start a new run
               consecutiveDownTicks = 0;
               consecutiveUpTicks++;
               lastDirectionUp = true;
            }
         } else if(movePoints < 0) {
            // Down tick
            if(waitingForReversal && lastDirectionUp) {
               reversalCounter++;
            } else if(!waitingForReversal) {
               consecutiveUpTicks = 0;
               consecutiveDownTicks++;
               lastDirectionUp = false;
            }
         }
      }
      
      // Check if we have enough consecutive ticks to start waiting for reversal
      if(!waitingForReversal && (consecutiveUpTicks >= ConsecutiveTicksNeeded || consecutiveDownTicks >= ConsecutiveTicksNeeded)) {
         waitingForReversal = true;
         reversalCounter = 0;
      }
      
      // If waiting for reversal and we got enough opposite ticks → trade signal
      if(waitingForReversal && reversalCounter >= ReversalTicksRequired) {
         // Determine direction
         bool buySignal = (consecutiveDownTicks >= ConsecutiveTicksNeeded);  // down run then up reversal = buy
         bool sellSignal = (consecutiveUpTicks >= ConsecutiveTicksNeeded);   // up run then down reversal = sell
         
         if(buySignal || sellSignal) {
            double lot = CalculateLotSize();
            lot = MathMax(0.01, lot);
            
            if(buySignal) {
               double entry = currentAsk;
               double sl = entry - StopLossPoints * point;
               double tp = entry + TakeProfitPoints * point;
               sl = NormalizeDouble(sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
               tp = NormalizeDouble(tp, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
               if(trade.Buy(lot, _Symbol, entry, sl, tp, "TickRevBuy")) {
                  Print("🔥 BUY | Run: ", consecutiveDownTicks, " down ticks → ", reversalCounter, " up ticks | Lot=", lot);
                  lastTradeTime = TimeCurrent();
                  tradeCountToday++;
                  ResetPatternCounters();
               }
            } else if(sellSignal) {
               double entry = currentBid;
               double sl = entry + StopLossPoints * point;
               double tp = entry - TakeProfitPoints * point;
               sl = NormalizeDouble(sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
               tp = NormalizeDouble(tp, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
               if(trade.Sell(lot, _Symbol, entry, sl, tp, "TickRevSell")) {
                  Print("🔥 SELL | Run: ", consecutiveUpTicks, " up ticks → ", reversalCounter, " down ticks | Lot=", lot);
                  lastTradeTime = TimeCurrent();
                  tradeCountToday++;
                  ResetPatternCounters();
               }
            }
         }
      }
   }
   
   lastPrice = currentBid;
   
   // --- Apply trailing stop to existing positions ---
   if(UseTrailingStop) ApplyTrailingStop();
}

//+------------------------------------------------------------------+
//| Reset pattern counters after trade                              |
//+------------------------------------------------------------------+
void ResetPatternCounters() {
   consecutiveUpTicks = 0;
   consecutiveDownTicks = 0;
   waitingForReversal = false;
   reversalCounter = 0;
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk percentage                     |
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
//| Apply trailing stop                                             |
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
