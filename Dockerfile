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
//|                                        Aggressive_Cent_Scalper  |
//|                         Fixed lot option + News filter added    |
//|                              Opens trades frequently on M1      |
//|                                      Target $2/day on $10 cent  |
//+------------------------------------------------------------------+
#property copyright "Aggressive Scalper"
#property version   "3.10"
#property strict

#include <Trade\Trade.mqh>

// --- Inputs (Aggressive Settings) ---
input string   t1 = "==== Money Management ====";
input bool     UseFixedLot       = false;      // true = use fixed lot, false = use RiskPercent
input double   FixedLotSize      = 0.01;       // Fixed lot when UseFixedLot = true
input double   RiskPercent       = 10.0;       // 10% risk per trade (only if UseFixedLot = false)
input int      StopLossPoints    = 100;        // 10 pips SL
input int      TakeProfitPoints  = 50;         // 5 pips TP (faster wins)
input int      MaxConcurrentTrades = 3;        // Up to 3 positions at once
input int      MagicNumber       = 999888;

input string   t2 = "==== Entry Triggers (Aggressive) ====";
input bool     UseMomentum       = true;       // Trade on price momentum (recommended)
input int      MomentumPoints    = 15;         // If price moves 1.5 pips in last 5 seconds, trade
input bool     UseRSI            = true;       // Use RSI as secondary confirmation
input int      RsiPeriod         = 7;          // Fast RSI
input int      RsiBuyLevel       = 40;         // Buy when RSI < 40
input int      RsiSellLevel      = 60;         // Sell when RSI > 60
input bool     UseMA             = false;      // Optional moving average filter
input int      MAPeriod          = 20;         // For trend filter

input string   t3 = "==== Filters ====";
input int      MaxSpreadPoints   = 30;         // Max 3 pips spread
input bool     UseATRFilter      = false;      // Disable ATR filter for more trades
input double   MinATRMultiplier  = 0.1;        // Very low if enabled
input int      ATRPeriod         = 14;

input string   t4 = "==== Daily Limits ====";
input double   DailyTargetUSD    = 2.0;        // Stop after $2 profit
input double   MaxDailyLossUSD   = 1.0;        // Stop after $1 loss
input bool     UseTrailingStop   = true;
input int      TrailingStartPts  = 30;         // Start trailing at 3 pips profit
input int      TrailingStepPts   = 15;         // Trail by 1.5 pips

input string   t5 = "==== News Filter ====";
input bool     UseNewsFilter     = true;       // Enable news filter
input string   NewsTimes         = "08:30,10:00,14:30"; // Comma-separated news times (broker time, HH:MM)
input int      NewsBufferMinutes = 15;         // Stop trading X min before and after each news event

// --- Globals ---
CTrade trade;
int rsi_handle, atr_handle, ma_handle;
double rsi_buf[], atr_buf[], ma_buf[];
datetime lastBarTime = 0;
double dailyProfit = 0.0;
double startBalance = 0.0;
bool tradingHalted = false;
datetime lastTradeTime = 0;
int tradeCountToday = 0;

// --- News Filter Variables ---
int newsMinutesArray[50];
int newsMinutesCount = 0;

//+------------------------------------------------------------------+
//| Parse comma-separated news times                                 |
//+------------------------------------------------------------------+
void ParseNewsTimes() {
   newsMinutesCount = 0;
   string temp = NewsTimes;
   StringReplace(temp, " ", "");
   string parts[50];
   int partCount = StringSplit(temp, ',', parts);
   for(int i = 0; i < partCount && i < 50; i++) {
      int hour = (int)StringToInteger(StringSubstr(parts[i], 0, 2));
      int minute = (int)StringToInteger(StringSubstr(parts[i], 3, 2));
      newsMinutesArray[newsMinutesCount] = hour * 60 + minute;
      newsMinutesCount++;
   }
}

//+------------------------------------------------------------------+
//| Check if current time is inside news buffer                      |
//+------------------------------------------------------------------+
bool IsNewsTime() {
   if(!UseNewsFilter) return false;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int currentMinutes = dt.hour * 60 + dt.min;
   for(int i = 0; i < newsMinutesCount; i++) {
      int startMinutes = newsMinutesArray[i] - NewsBufferMinutes;
      int endMinutes   = newsMinutesArray[i] + NewsBufferMinutes;
      if(currentMinutes >= startMinutes && currentMinutes <= endMinutes) {
         return true;
      }
   }
   return false;
}
//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   // Create indicators
   if(UseRSI) rsi_handle = iRSI(_Symbol, PERIOD_M1, RsiPeriod, PRICE_CLOSE);
   if(UseATRFilter) atr_handle = iATR(_Symbol, PERIOD_M1, ATRPeriod);
   if(UseMA) ma_handle = iMA(_Symbol, PERIOD_M1, MAPeriod, 0, MODE_SMA, PRICE_CLOSE);
   
   ArraySetAsSeries(rsi_buf, true);
   ArraySetAsSeries(atr_buf, true);
   ArraySetAsSeries(ma_buf, true);
   
   // Initialize news filter
   ArrayResize(newsTimesArr, 20);
   ParseNewsTimes();
   
   startBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   Print("==========================================");
   Print("⚡ AGGRESSIVE CENT SCALPER ACTIVE");
   Print("   Balance: $", startBalance);
   if(UseFixedLot)
      Print("   Lot mode: FIXED | Lot = ", FixedLotSize);
   else
      Print("   Lot mode: RISK% | Risk = ", RiskPercent, "%");
   Print("   TP: ", TakeProfitPoints/10.0, " pips | SL: ", StopLossPoints/10.0, " pips");
   Print("   Momentum trigger: ", MomentumPoints, " points");
   Print("   Daily target: $", DailyTargetUSD);
   if(UseNewsFilter) {
      Print("   News filter: ON | Buffer = ", NewsBufferMinutes, " min");
      Print("   Times: ", NewsTimes);
   }
   Print("==========================================");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinitialization                                               |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   if(UseRSI) IndicatorRelease(rsi_handle);
   if(UseATRFilter) IndicatorRelease(atr_handle);
   if(UseMA) IndicatorRelease(ma_handle);
}

//+------------------------------------------------------------------+
//| Main tick function (very frequent trades)                       |
//+------------------------------------------------------------------+
void OnTick() {
   // --- NEWS FILTER: Pause during high-impact news ---
   if(IsNewsTime()) {
      Comment("News Filter ACTIVE: Trading paused."); // optional visual
      return;
   }
   
   // --- Daily profit limits ---
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyProfit = currentBalance - startBalance;
   
   if(dailyProfit >= DailyTargetUSD) {
      if(!tradingHalted) Print("🎯 Daily target $", DailyTargetUSD, " reached. Halted.");
      tradingHalted = true;
      return;
   }
   if(dailyProfit <= -MaxDailyLossUSD) {
      if(!tradingHalted) Print("💀 Max daily loss $", MaxDailyLossUSD, " hit. Halted.");
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
   
   // --- Spread filter ---
   int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpreadPoints) return;
   
   // --- Optional ATR filter (disabled by default for more trades)---
   if(UseATRFilter) {
      CopyBuffer(atr_handle, 0, 0, 2, atr_buf);
      double atrPips = atr_buf[0] / SymbolInfoDouble(_Symbol, SYMBOL_POINT) / 10.0;
      if(atrPips < MinATRMultiplier) return;
   }
   
   // --- Count open positions ---
   int posCount = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber) posCount++;
      }
   }
   if(posCount >= MaxConcurrentTrades) return;
   
   // --- COOLDOWN: avoid too many trades per second (0.5 sec) ---
   if(TimeCurrent() - lastTradeTime < 0.5) return;
   
   // --- Calculate signals ---
   bool buySignal = false;
   bool sellSignal = false;
   
   // 1. Momentum trigger (price movement in last few ticks)
   if(UseMomentum) {
      double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      static double previousPrice = 0;
      static datetime lastCheck = 0;
      
      if(TimeCurrent() - lastCheck >= 2) {  // Check every 2 seconds
         double move = MathAbs(currentPrice - previousPrice) / _Point;
         if(previousPrice != 0 && move >= MomentumPoints) {
            if(currentPrice > previousPrice) buySignal = true;
            else sellSignal = true;
         }
         previousPrice = currentPrice;
         lastCheck = TimeCurrent();
      }
   }
   
   // 2. RSI confirmation (if enabled and no momentum signal yet)
   if(UseRSI && !buySignal && !sellSignal) {
      if(CopyBuffer(rsi_handle, 0, 0, 2, rsi_buf) < 2) return;
      double rsi = rsi_buf[0];
      if(rsi < RsiBuyLevel) buySignal = true;
      if(rsi > RsiSellLevel) sellSignal = true;
   }
   
   // 3. Moving average trend filter (optional, can be disabled)
   if(UseMA && (buySignal || sellSignal)) {
      if(CopyBuffer(ma_handle, 0, 0, 2, ma_buf) < 2) return;
      double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(buySignal && price < ma_buf[0]) buySignal = false;  // Don't buy below MA
      if(sellSignal && price > ma_buf[0]) sellSignal = false;
   }
   
   // --- If no signal, do nothing ---
   if(!buySignal && !sellSignal) return;
   
   // --- Execute trade ---
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double lot = CalculateLotSize();
   lot = MathMax(0.01, lot);
   
   if(buySignal) {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl = ask - StopLossPoints * point;
      double tp = ask + TakeProfitPoints * point;
      sl = NormalizeDouble(sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      tp = NormalizeDouble(tp, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      
      if(trade.Buy(lot, _Symbol, ask, sl, tp, "AggBuy")) {
         Print("🔥 BUY | Lot=", lot, " | TP=", tp, " | SL=", sl);
         lastTradeTime = TimeCurrent();
         tradeCountToday++;
      } else {
         Print("❌ Buy failed. Error: ", GetLastError());
      }
   }
   else if(sellSignal) {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl = bid + StopLossPoints * point;
      double tp = bid - TakeProfitPoints * point;
      sl = NormalizeDouble(sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      tp = NormalizeDouble(tp, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      
      if(trade.Sell(lot, _Symbol, bid, sl, tp, "AggSell")) {
         Print("🔥 SELL | Lot=", lot, " | TP=", tp, " | SL=", sl);
         lastTradeTime = TimeCurrent();
         tradeCountToday++;
      } else {
         Print("❌ Sell failed. Error: ", GetLastError());
      }
   }
   
   // --- Apply trailing stop to open positions ---
   if(UseTrailingStop) ApplyTrailingStop();
}

//+------------------------------------------------------------------+
//| Calculate lot size based on fixed lot or risk %                 |
//+------------------------------------------------------------------+
double CalculateLotSize() {
   if(UseFixedLot) {
      // Use the fixed lot size directly
      double lot = FixedLotSize;
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      lot = MathMax(minLot, MathMin(maxLot, lot));
      lot = MathRound(lot / stepLot) * stepLot;
      return MathMax(minLot, lot);
   } else {
      // Original risk-based calculation
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
