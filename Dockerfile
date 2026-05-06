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
//|                                         Forced_Tick_Scalper.mq5 |
//|                           Minimal thresholds – guaranteed trades |
//|                                                  Debug included |
//+------------------------------------------------------------------+
#property copyright "Fix"
#property version   "9.00"
#property strict

#include <Trade\Trade.mqh>

// --- Inputs (lowest possible thresholds) ---
input string   t1 = "==== Money Management ====";
input bool     UseFixedLot       = false;
input double   FixedLotSize      = 0.01;
input double   RiskPercent       = 10.0;       // 10% risk per trade
input int      MaxConcurrentTrades = 2;
input int      MagicNumber       = 999001;

input string   t2 = "==== Tick Pattern (Forced) ====";
input int      ConsecutiveTicksNeeded = 2;     // Just 2 ticks same direction
input int      ReversalTicksRequired = 1;     // Just 1 opposite tick = trade
input int      MinTickMovementPoints = 1;      // 1 point movement

input string   t3 = "==== TP/SL ====";
input int      StopLossPoints    = 60;         // 6 pips
input int      TakeProfitPoints  = 30;         // 3 pips

input string   t4 = "==== Minimal Filters ====";
input int      MaxSpreadPoints   = 200;        // Very high – allow any spread
input bool     UseTimeFilter     = false;
input double   DailyTargetUSD    = 5.0;
input double   MaxDailyLossUSD   = 2.0;
input bool     UseTrailingStop   = true;
input int      TrailingStartPts  = 15;
input int      TrailingStepPts   = 8;

// --- Globals ---
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
int      debugCounter = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   startBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   Print("==========================================");
   Print("🔥 FORCED TICK SCALPER – WILL TRADE");
   Print("   Pattern: ", ConsecutiveTicksNeeded, " ticks → ", ReversalTicksRequired, " opposite");
   Print("   Spread limit: ", MaxSpreadPoints, " points");
   Print("   TP: ", TakeProfitPoints/10.0, " pips | SL: ", StopLossPoints/10.0, " pips");
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
//| Tick function (simplified & aggressive)                         |
//+------------------------------------------------------------------+
void OnTick() {
   // --- Daily limits (same as before) ---
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyProfit = currentBalance - startBalance;
   if(dailyProfit >= DailyTargetUSD) {
      if(!tradingHalted) Print("🎯 Daily target reached");
      tradingHalted = true;
      return;
   }
   if(dailyProfit <= -MaxDailyLossUSD) {
      if(!tradingHalted) Print("💀 Daily loss limit hit");
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
   
   // --- Spread filter (very tolerant) ---
   int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpreadPoints) {
      static int lastSpreadPrint = 0;
      if(TimeCurrent() - lastSpreadPrint > 10) {
         Print("❌ Spread too high: ", spread, " > ", MaxSpreadPoints);
         lastSpreadPrint = TimeCurrent();
      }
      return;
   }
   
   // --- Position limit ---
   int posCount = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         posCount++;
   }
   if(posCount >= MaxConcurrentTrades) return;
   
   // --- Cooldown (0.5 sec to avoid spam) ---
   if(TimeCurrent() - lastTradeTime < 0.5) return;
   
   // --- Get prices ---
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point == 0) return;
   
   // --- Debug: print every 100 ticks ---
   debugCounter++;
   if(debugCounter % 100 == 0) {
      Print("DEBUG: consecUp=", consecutiveUpTicks, " consecDown=", consecutiveDownTicks, 
            " waiting=", waitingForReversal, " revCnt=", reversalCounter);
   }
   
   // --- Tick direction detection ---
   if(lastPrice != 0) {
      double movePoints = (currentBid - lastPrice) / point;
      if(MathAbs(movePoints) >= MinTickMovementPoints) {
         if(movePoints > 0) {
            // Up tick
            if(waitingForReversal && !lastDirectionUp) reversalCounter++;
            else if(!waitingForReversal) {
               consecutiveDownTicks = 0;
               consecutiveUpTicks++;
               lastDirectionUp = true;
            }
         } else if(movePoints < 0) {
            // Down tick
            if(waitingForReversal && lastDirectionUp) reversalCounter++;
            else if(!waitingForReversal) {
               consecutiveUpTicks = 0;
               consecutiveDownTicks++;
               lastDirectionUp = false;
            }
         }
      }
      
      // Start waiting for reversal when enough consecutive ticks
      if(!waitingForReversal && (consecutiveUpTicks >= ConsecutiveTicksNeeded || consecutiveDownTicks >= ConsecutiveTicksNeeded)) {
         waitingForReversal = true;
         reversalCounter = 0;
         Print("🔔 Waiting for reversal after ", consecutiveUpTicks, " up / ", consecutiveDownTicks, " down ticks");
      }
      
      // Trigger trade when reversal ticks reach required count
      if(waitingForReversal && reversalCounter >= ReversalTicksRequired) {
         bool buySignal = (consecutiveDownTicks >= ConsecutiveTicksNeeded);
         bool sellSignal = (consecutiveUpTicks >= ConsecutiveTicksNeeded);
         
         if(buySignal || sellSignal) {
            double lot = (UseFixedLot) ? FixedLotSize : CalculateRiskBasedLot();
            lot = MathMax(0.01, lot);
            
            double sl, tp;
            if(buySignal) {
               double entry = currentAsk;
               sl = entry - StopLossPoints * point;
               tp = entry + TakeProfitPoints * point;
               if(trade.Buy(lot, _Symbol, entry, sl, tp, "FrcBuy")) {
                  Print("🔥 BUY | ticks down: ", consecutiveDownTicks, " → up: ", reversalCounter, " | Lot=", lot);
                  lastTradeTime = TimeCurrent();
                  tradeCountToday++;
                  ResetCounters();
               } else {
                  Print("❌ Buy failed, error: ", GetLastError());
               }
            } else if(sellSignal) {
               double entry = currentBid;
               sl = entry + StopLossPoints * point;
               tp = entry - TakeProfitPoints * point;
               if(trade.Sell(lot, _Symbol, entry, sl, tp, "FrcSell")) {
                  Print("🔥 SELL | ticks up: ", consecutiveUpTicks, " → down: ", reversalCounter, " | Lot=", lot);
                  lastTradeTime = TimeCurrent();
                  tradeCountToday++;
                  ResetCounters();
               } else {
                  Print("❌ Sell failed, error: ", GetLastError());
               }
            }
         }
      }
   }
   
   lastPrice = currentBid;
   
   // --- Trailing stop ---
   if(UseTrailingStop) ApplyTrailingStop();
}

//+------------------------------------------------------------------+
//| Risk‑based lot                                                   |
//+------------------------------------------------------------------+
double CalculateRiskBasedLot() {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * RiskPercent / 100.0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double riskPerLot = StopLossPoints * tickValue;
   double lot = riskAmount / riskPerLot;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathMax(minLot, MathMin(maxLot, lot));
   if(stepLot > 0) lot = MathRound(lot / stepLot) * stepLot;
   return lot;
}

//+------------------------------------------------------------------+
//| Trailing stop                                                    |
//+------------------------------------------------------------------+
void ApplyTrailingStop() {
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
      
      if(profitPoints >= TrailingStartPts) {
         double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ?
                        currentPrice - TrailingStepPts * _Point :
                        currentPrice + TrailingStepPts * _Point;
         if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && newSL > currentSL) ||
            (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (newSL < currentSL || currentSL == 0))) {
            trade.PositionModify(ticket, newSL, currentTP);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Reset counters                                                   |
//+------------------------------------------------------------------+
void ResetCounters() {
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
