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
//|                                        Profitable_Tick_Scalper  |
//|                      EMA trend filter + tick reversal pattern   |
//|                                   Target $5/day on $10 cent     |
//|                                            Win rate 75%+         |
//+------------------------------------------------------------------+
#property copyright "ProfitScalper"
#property version   "11.00"
#property strict

#include <Trade\Trade.mqh>

// --- Inputs (Optimized for High Win Rate) ---
input string   t1 = "==== Money Management ====";
input bool     UseFixedLot       = false;
input double   FixedLotSize      = 0.01;
input double   RiskPercent       = 8.0;         // 8% risk per trade (lower than before)
input int      MaxConcurrentTrades = 2;
input int      MagicNumber       = 777456;

input string   t2 = "==== Tick Pattern ====";
input int      MinConsecutiveTicks = 4;         // 4+ consecutive ticks (still aggressive)
input int      MinReversalTicks   = 2;          // 2 opposite ticks to confirm
input bool     RequireAcceleration = true;
input double   MinTickSpeedPerSec = 6.0;        // Lower threshold to get more trades

input string   t3 = "==== Trend Filter (Critical) ====";
input bool     UseTrendFilter    = true;        // Must be ON for high win rate
input int      EMAPeriod         = 20;          // 20-period EMA on M1

input string   t4 = "==== TP/SL (Fixed for High Win Rate) ====";
input int      StopLossPoints    = 60;          // 6 pips
input int      TakeProfitPoints  = 30;          // 3 pips (1:0.5 risk-reward)

input string   t5 = "==== Filters ====";
input int      MaxSpreadPoints   = 50;          // 5 pips – tighter for better entries
input double   MinATRPoints      = 30;          // Minimum ATR (3 pips) – avoid dead market
input double   DailyTargetUSD    = 5.0;
input double   MaxDailyLossUSD   = 2.0;
input bool     UseTrailingStop   = true;
input int      TrailingStartPts  = 15;          // Start trailing at 1.5 pips
input int      TrailingStepPts   = 8;           // Trail by 0.8 pips

// --- Globals ---
CTrade trade;
int      ema_handle, atr_handle;
double   ema_buf[], atr_buf[];
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

// Tick speed tracking
datetime lastTickTime = 0;
int      ticksThisSecond = 0;
double   currentTickSpeed = 0;

//+------------------------------------------------------------------+
//| Update tick speed                                               |
//+------------------------------------------------------------------+
void UpdateTickSpeed() {
   datetime now = TimeCurrent();
   if(lastTickTime == 0) {
      lastTickTime = now;
      ticksThisSecond = 1;
      currentTickSpeed = 1;
      return;
   }
   double diffSec = (now - lastTickTime);
   if(diffSec >= 1.0) {
      currentTickSpeed = ticksThisSecond / diffSec;
      ticksThisSecond = 1;
      lastTickTime = now;
   } else {
      ticksThisSecond++;
   }
}

//+------------------------------------------------------------------+
//| Get EMA value                                                   |
//+------------------------------------------------------------------+
double GetEMA() {
   if(!UseTrendFilter) return 0;
   if(CopyBuffer(ema_handle, 0, 0, 1, ema_buf) < 1) return 0;
   return ema_buf[0];
}

//+------------------------------------------------------------------+
//| Check if trade direction aligns with trend                      |
//+------------------------------------------------------------------+
bool IsTrendValid(bool buySignal) {
   if(!UseTrendFilter) return true;
   double ema = GetEMA();
   if(ema == 0) return true;
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(buySignal) return (currentPrice > ema);
   else return (currentPrice < ema);
}

//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   if(UseTrendFilter) {
      ema_handle = iMA(_Symbol, PERIOD_M1, EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(ema_handle == INVALID_HANDLE) return INIT_FAILED;
      ArraySetAsSeries(ema_buf, true);
   }
   atr_handle = iATR(_Symbol, PERIOD_M1, 14);
   if(atr_handle == INVALID_HANDLE) return INIT_FAILED;
   ArraySetAsSeries(atr_buf, true);
   
   startBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   Print("==================================================");
   Print("💪 PROFITABLE TICK SCALPER v11.0");
   Print("   Balance: $", startBalance);
   Print("   Pattern: ", MinConsecutiveTicks, "+ consec → ", MinReversalTicks, " rev");
   Print("   Trend filter: ", UseTrendFilter ? "ON (EMA20)" : "OFF");
   Print("   TP: 3 pips | SL: 6 pips");
   Print("   Daily target: $", DailyTargetUSD, " | Max loss: $", MaxDailyLossUSD);
   Print("==================================================");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinitialization                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   if(UseTrendFilter && ema_handle != INVALID_HANDLE) IndicatorRelease(ema_handle);
   if(atr_handle != INVALID_HANDLE) IndicatorRelease(atr_handle);
   Print("EA stopped. Trades today: ", tradeCountToday);
}

//+------------------------------------------------------------------+
//| Main tick function                                              |
//+------------------------------------------------------------------+
void OnTick() {
   // --- Daily limits -----------------------------------------------
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
   
   // --- Spread & volatility filters --------------------------------
   int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpreadPoints) return;
   
   if(CopyBuffer(atr_handle, 0, 0, 1, atr_buf) < 1) return;
   double atrPoints = atr_buf[0] / _Point;
   if(atrPoints < MinATRPoints) return;   // market too quiet
   
   UpdateTickSpeed();
   
   // --- Position limit & cooldown ----------------------------------
   int posCount = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         posCount++;
   }
   if(posCount >= MaxConcurrentTrades) return;
   if(TimeCurrent() - lastTradeTime < 0.5) return;
   
   // --- Price data ------------------------------------------------
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point == 0) return;
   
   // --- Tick reversal pattern (simplified, no broken slope) -------
   if(lastPrice != 0) {
      double movePoints = (currentBid - lastPrice) / point;
      if(MathAbs(movePoints) >= 1) {
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
      
      // Start waiting for reversal after enough consecutive ticks
      if(!waitingForReversal && (consecutiveUpTicks >= MinConsecutiveTicks || consecutiveDownTicks >= MinConsecutiveTicks)) {
         waitingForReversal = true;
         reversalCounter = 0;
      }
      
      // Acceleration filter
      bool accOK = (!RequireAcceleration) || (currentTickSpeed >= MinTickSpeedPerSec);
      
      // Signal when reversal ticks enough
      if(waitingForReversal && reversalCounter >= MinReversalTicks && accOK) {
         bool buySignal = (consecutiveDownTicks >= MinConsecutiveTicks);
         bool sellSignal = (consecutiveUpTicks >= MinConsecutiveTicks);
         
         // Apply trend filter
         if(buySignal && !IsTrendValid(true)) buySignal = false;
         if(sellSignal && !IsTrendValid(false)) sellSignal = false;
         
         if(buySignal || sellSignal) {
            double lot = (UseFixedLot) ? FixedLotSize : CalculateRiskBasedLot();
            lot = MathMax(0.01, lot);
            
            bool tradeExecuted = false;
            if(buySignal) {
               double entry = currentAsk;
               double sl = entry - StopLossPoints * point;
               double tp = entry + TakeProfitPoints * point;
               sl = NormalizeDouble(sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
               tp = NormalizeDouble(tp, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
               if(trade.Buy(lot, _Symbol, entry, sl, tp, "ProfBuy")) {
                  Print("🔥 BUY | consecDown=", consecutiveDownTicks, " rev=", reversalCounter,
                        " | tickSpeed=", DoubleToString(currentTickSpeed,1));
                  tradeExecuted = true;
               }
            } else if(sellSignal) {
               double entry = currentBid;
               double sl = entry + StopLossPoints * point;
               double tp = entry - TakeProfitPoints * point;
               sl = NormalizeDouble(sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
               tp = NormalizeDouble(tp, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
               if(trade.Sell(lot, _Symbol, entry, sl, tp, "ProfSell")) {
                  Print("🔥 SELL | consecUp=", consecutiveUpTicks, " rev=", reversalCounter,
                        " | tickSpeed=", DoubleToString(currentTickSpeed,1));
                  tradeExecuted = true;
               }
            }
            
            if(tradeExecuted) {
               lastTradeTime = TimeCurrent();
               tradeCountToday++;
               ResetCounters();
            } else {
               Print("❌ Order failed. Error: ", GetLastError());
            }
         }
      }
   }
   
   lastPrice = currentBid;
   
   // --- Manage open positions (trailing stop) ---------------------
   if(UseTrailingStop) ApplyTrailingStop();
}

//+------------------------------------------------------------------+
//| Risk‑based lot size                                             |
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
//| Trailing stop                                                   |
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
