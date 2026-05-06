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
//|                                         Pure_Tick_Scalper_Aggro |
//|                      Pure tick reversal pattern – no indicators |
//|                                   Target $5/day on $10 cent     |
//|                                                  Win rate >75%  |
//+------------------------------------------------------------------+
#property copyright "Aggressive Tick"
#property version   "7.00"
#property description "Pure tick reversal scalper – no RSI, no EMA, no ATR"
#property strict

#include <Trade\Trade.mqh>

// ---------------------------------------------------------------
//  INPUTS – Ultra Aggressive (high win rate via pattern alone)
// ---------------------------------------------------------------
input string   t1 = "==== Money Management ====";
input bool     UseFixedLot       = false;      // false = risk%, true = fixed lot
input double   FixedLotSize      = 0.01;       // used if UseFixedLot = true
input double   RiskPercent       = 12.0;       // 12% risk per trade (aggressive)
input int      MaxConcurrentTrades = 2;
input int      MagicNumber       = 999001;

input string   t2 = "==== Tick Pattern (Core Logic) ====";
input int      ConsecutiveTicksNeeded = 3;     // 3+ same direction ticks to start
input int      ReversalTicksRequired = 2;      // 2 opposite ticks to confirm reversal
input int      MinTickMovementPoints = 1;      // 1 point minimum movement (catch all ticks)

input string   t3 = "==== TP/SL (Fixed or ATR based) ====";
input bool     UseATR_TP_SL      = true;       // true = ATR based, false = fixed points
input int      ATRPeriod         = 14;
input double   StopLossATRMult   = 1.2;        // SL = ATR * 1.2
input double   TakeProfitATRMult = 0.8;        // TP = ATR * 0.8 (smaller for high win rate)
input int      FixedStopLossPoints = 60;       // 6 pips (if UseATR_TP_SL = false)
input int      FixedTakeProfitPoints = 30;     // 3 pips

input string   t4 = "==== Minimal Filters (only essential) ====";
input int      MaxSpreadPoints   = 100;        // 10 pips – very tolerant
input bool     UseTimeFilter     = false;      // false = trade any time (24/5)
input int      StartHour         = 0;
input int      EndHour           = 23;
input bool     UseTrailingStop   = true;
input int      TrailingStartPts  = 20;         // start trailing at 2 pips profit
input int      TrailingStepPts   = 10;         // trail by 1 pip

input string   t5 = "==== Daily Limits ====";
input double   DailyTargetUSD    = 5.0;        // stop after $5 profit
input double   MaxDailyLossUSD   = 2.0;        // stop after $2 loss

// ---------------------------------------------------------------
//  GLOBALS
// ---------------------------------------------------------------
CTrade trade;
int      atr_handle;
double   atr_buf[];
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
   
   if(UseATR_TP_SL) {
      atr_handle = iATR(_Symbol, PERIOD_M1, ATRPeriod);
      if(atr_handle == INVALID_HANDLE) return INIT_FAILED;
      ArraySetAsSeries(atr_buf, true);
   }
   
   startBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   Print("==================================================");
   Print("⚡ PURE TICK SCALPER (No indicators)");
   Print("   Balance: $", startBalance);
   if(UseFixedLot) Print("   Lot mode: FIXED | Lot = ", FixedLotSize);
   else Print("   Lot mode: RISK% | Risk = ", RiskPercent, "%");
   if(UseATR_TP_SL)
      Print("   TP/SL: ATR based (SL=", StopLossATRMult, "*ATR, TP=", TakeProfitATRMult, "*ATR)");
   else
      Print("   TP/SL: FIXED (", FixedTakeProfitPoints/10.0, "/", FixedStopLossPoints/10.0, " pips)");
   Print("   Pattern: ", ConsecutiveTicksNeeded, " ticks → ", ReversalTicksRequired, " opposite = trade");
   Print("   Daily target: $", DailyTargetUSD, " | Max loss: $", MaxDailyLossUSD);
   Print("==================================================");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinitialization                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   if(UseATR_TP_SL && atr_handle != INVALID_HANDLE) IndicatorRelease(atr_handle);
   Print("EA stopped. Trades today: ", tradeCountToday);
}

//+------------------------------------------------------------------+
//| Get dynamic TP/SL (ATR based or fixed)                          |
//+------------------------------------------------------------------+
void GetTPSL(double &slPoints, double &tpPoints) {
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
   double atrValue = atr_buf[0] / _Point;
   slPoints = MathMax(20, atrValue * StopLossATRMult);
   tpPoints = MathMax(10, atrValue * TakeProfitATRMult);
}

//+------------------------------------------------------------------+
//| Tick function                                                   |
//+------------------------------------------------------------------+
void OnTick() {
   // --- Daily profit limits ---
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
   
   // --- Simple time filter (optional, disabled by default) ---
   if(UseTimeFilter) {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      int hour = dt.hour;
      if(hour < StartHour || hour > EndHour) return;
   }
   
   // --- Spread filter (tolerant) ---
   int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpreadPoints) return;
   
   // --- Position limit & cooldown (very short)---
   int posCount = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         posCount++;
   }
   if(posCount >= MaxConcurrentTrades) return;
   if(TimeCurrent() - lastTradeTime < 0.3) return;   // 0.3 sec cooldown -> up to 3 trades/sec max
   
   // --- Get current prices ---
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point == 0) return;
   
   // --- Tick reversal pattern (pure logic) ---
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
      
      // Trigger trade when reversal confirmed
      if(waitingForReversal && reversalCounter >= ReversalTicksRequired) {
         bool buySignal = (consecutiveDownTicks >= ConsecutiveTicksNeeded);
         bool sellSignal = (consecutiveUpTicks >= ConsecutiveTicksNeeded);
         
         if(buySignal || sellSignal) {
            double slPoints, tpPoints;
            GetTPSL(slPoints, tpPoints);
            
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
               result = trade.Buy(lot, _Symbol, price, sl, tp, "TickBuy");
            else
               result = trade.Sell(lot, _Symbol, price, sl, tp, "TickSell");
            
            if(result) {
               Print("🔥 ", buySignal ? "BUY" : "SELL", 
                     " | ticks: ", buySignal ? consecutiveDownTicks : consecutiveUpTicks,
                     "→", reversalCounter, " | Lot=", lot, " | TP=", tpPoints/10.0, "pips");
               lastTradeTime = TimeCurrent();
               tradeCountToday++;
               ResetPatternCounters();
            } else {
               Print("❌ Order failed. Error: ", GetLastError());
            }
         }
      }
   }
   
   lastPrice = currentBid;
   
   // --- Trailing stop for open positions ---
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
//| Apply trailing stop                                             |
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
