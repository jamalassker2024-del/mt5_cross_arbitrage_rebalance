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
//|                                 Pairs_Trading_StatArb_EA.mq5     |
//|                     For Valetax .vx symbols, fast profit exit   |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>
// No external libraries needed

#property copyright "Omni-Apex Statistical Arbitrage"
#property version   "2.1"
#property strict

// --- INPUTS (CHANGE THESE TO YOUR BROKER'S SYMBOLS) ---------------+
input string   AssetA           = "EURUSD.vx";     // e.g., EURUSD.vx
input string   AssetB           = "GBPUSD.vx";     // e.g., GBPUSD.vx
input double   RiskPercent      = 2.0;             // % equity per trade (total of both legs)
input int      LookbackPeriod   = 50;              // Period for spread mean/std dev (bars)
input double   EntryZScore      = 2.0;             // Entry threshold (absolute Z‑Score)
input double   ExitZScore       = 0.5;             // Exit threshold (Z‑Score)
input double   MinProfitUSD     = 1.00;            // Minimum total profit to close (optional)
input int      MaxOpenPositions = 1;               // Max concurrent pair positions
input int      MagicNumber      = 777888;
input int      StartHour        = 0;               // For testing, set to 0-24; change to 8-22 later
input int      EndHour          = 24;
input double   MaxDailyLossPercent = 8.0;
input bool     DebugPrint       = true;            // Show spread and Z‑Score every 5 sec

// --- GLOBALS -------------------------------------------------------+
CTrade tradeA, tradeB;
double spreadBuffer[];
datetime lastDebug = 0;
datetime lastTrade = 0;
datetime dayStart = 0;
double dailyEquityStart = 0;
int consecutiveLosses = 0;
bool tradingEnabled = true;

struct PairTrade {
   ulong ticketA;
   ulong ticketB;
   double profitLock;
   bool closed;
};
PairTrade activeTrades[];

//+------------------------------------------------------------------+
//| Check trading hours                                             |
//+------------------------------------------------------------------+
bool IsTradingTime() {
   MqlDateTime dt;
   TimeCurrent(dt);
   return (dt.hour >= StartHour && dt.hour < EndHour);
}

//+------------------------------------------------------------------+
//| Calculate mean of array                                         |
//+------------------------------------------------------------------+
double CalcMean(double &arr[], int length) {
   double sum = 0.0;
   for(int i=0; i<length; i++) sum += arr[i];
   return sum/length;
}

//+------------------------------------------------------------------+
//| Calculate standard deviation                                     |
//+------------------------------------------------------------------+
double CalcStdDev(double &arr[], double mean, int length) {
   double sum = 0.0;
   for(int i=0; i<length; i++) sum += MathPow(arr[i] - mean, 2);
   return MathSqrt(sum/length);
}

//+------------------------------------------------------------------+
//| Update spread buffer and get Z-Score                            |
//+------------------------------------------------------------------+
double GetZScore() {
   double bidA = SymbolInfoDouble(AssetA, SYMBOL_BID);
   double bidB = SymbolInfoDouble(AssetB, SYMBOL_BID);
   if(bidA <= 0 || bidB <= 0) {
      if(DebugPrint && TimeCurrent()-lastDebug>=5)
         Print("❌ No price for ", AssetA, " or ", AssetB);
      return 0;
   }
   double spread = bidA - bidB;
   
   // Shift buffer
   int sz = ArraySize(spreadBuffer);
   if(sz < LookbackPeriod) {
      ArrayResize(spreadBuffer, LookbackPeriod);
      for(int i=sz; i<LookbackPeriod; i++) spreadBuffer[i] = spread;
   }
   for(int i=LookbackPeriod-1; i>0; i--)
      spreadBuffer[i] = spreadBuffer[i-1];
   spreadBuffer[0] = spread;
   
   double mean = CalcMean(spreadBuffer, LookbackPeriod);
   double stdDev = CalcStdDev(spreadBuffer, mean, LookbackPeriod);
   if(stdDev == 0) return 0;
   return (spread - mean) / stdDev;
}

//+------------------------------------------------------------------+
//| Close a pair trade                                               |
//+------------------------------------------------------------------+
void ClosePairTrade(int idx) {
   if(activeTrades[idx].ticketA > 0) tradeA.PositionClose(activeTrades[idx].ticketA);
   if(activeTrades[idx].ticketB > 0) tradeB.PositionClose(activeTrades[idx].ticketB);
   activeTrades[idx].closed = true;
}

//+------------------------------------------------------------------+
//| Initialize                                                      |
//+------------------------------------------------------------------+
int OnInit() {
   tradeA.SetExpertMagicNumber(MagicNumber);
   tradeB.SetExpertMagicNumber(MagicNumber+1);
   // Ensure symbols are visible
   SymbolSelect(AssetA, true);
   SymbolSelect(AssetB, true);
   ArrayResize(spreadBuffer, 0);
   ArrayResize(activeTrades, 0);
   dayStart = TimeCurrent();
   dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("==============================================");
   Print("📊 Statistical Arbitrage EA (Pairs Trading)");
   Print("   Pair: ", AssetA, " vs ", AssetB);
   Print("   Entry Z‑Score: ±", EntryZScore, " | Exit Z‑Score: ±", ExitZScore);
   Print("   Trading hours: ", StartHour, ":00 - ", EndHour, ":00");
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Tick handler                                                    |
//+------------------------------------------------------------------+
void OnTick() {
   // Session filter
   if(!IsTradingTime()) {
      for(int i=0; i<ArraySize(activeTrades); i++) if(!activeTrades[i].closed) ClosePairTrade(i);
      return;
   }
   
   // Daily loss & reset
   datetime now = TimeCurrent();
   if(now - dayStart >= 86400) {
      dayStart = now;
      dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
      tradingEnabled = true;
      consecutiveLosses = 0;
      Print("✅ New trading day");
   }
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPercent = (dailyEquityStart - equity) / dailyEquityStart * 100.0;
   if(lossPercent >= MaxDailyLossPercent) {
      if(tradingEnabled) Print("🚨 Daily loss limit reached");
      tradingEnabled = false;
      return;
   }
   if(!tradingEnabled && lossPercent < MaxDailyLossPercent-2) tradingEnabled = true;
   if(!tradingEnabled) return;
   
   // Close profitable pair trades (fast out + trailing lock)
   for(int i=0; i<ArraySize(activeTrades); i++) {
      if(activeTrades[i].closed) continue;
      double profit = 0;
      if(PositionSelectByTicket(activeTrades[i].ticketA)) profit += PositionGetDouble(POSITION_PROFIT);
      if(PositionSelectByTicket(activeTrades[i].ticketB)) profit += PositionGetDouble(POSITION_PROFIT);
      
      if(activeTrades[i].profitLock == 0 && profit >= MinProfitUSD) {
         activeTrades[i].profitLock = profit - 0.10;
         Print("🔒 Lock set at $", activeTrades[i].profitLock);
      }
      else if(activeTrades[i].profitLock > 0) {
         if(profit > activeTrades[i].profitLock + 0.10) {
            activeTrades[i].profitLock = profit - 0.10;
            Print("🔓 Trail lock raised to $", activeTrades[i].profitLock);
         }
         if(profit <= activeTrades[i].profitLock) {
            ClosePairTrade(i);
            Print("✅ Pair trade closed with profit: $", profit);
            if(profit < 0) consecutiveLosses++;
            else consecutiveLosses = 0;
         }
      }
      else if(profit > MinProfitUSD && activeTrades[i].profitLock == 0) {
         ClosePairTrade(i);
         Print("✅ Pair trade closed (no lock) profit: $", profit);
         consecutiveLosses = 0;
      }
   }
   
   // Remove closed trades
   for(int i=ArraySize(activeTrades)-1; i>=0; i--) {
      if(activeTrades[i].closed) {
         for(int j=i; j<ArraySize(activeTrades)-1; j++) activeTrades[j] = activeTrades[j+1];
         ArrayResize(activeTrades, ArraySize(activeTrades)-1);
      }
   }
   
   // Limits
   if(ArraySize(activeTrades) >= MaxOpenPositions) return;
   if(consecutiveLosses >= 3) {
      static int warn=0; if(warn++%50==0) Print("⛔ Paused due to losses");
      return;
   }
   if(now - lastTrade < 10) return;
   
   // Calculate Z‑Score
   double zScore = GetZScore();
   if(zScore == 0 || ArraySize(spreadBuffer) < LookbackPeriod) return;
   
   // Debug
   if(DebugPrint && now - lastDebug >= 5) {
      lastDebug = now;
      double bidA = SymbolInfoDouble(AssetA, SYMBOL_BID);
      double bidB = SymbolInfoDouble(AssetB, SYMBOL_BID);
      double spread = bidA - bidB;
      Print("========================================");
      Print("📊 Spread: ", DoubleToString(spread,5), " | Z‑Score: ", DoubleToString(zScore,2));
      Print("   Active pairs: ", ArraySize(activeTrades));
      Print("========================================");
   }
   
   // Signals
   bool buyPair = (zScore > EntryZScore);   // short A, long B
   bool sellPair = (zScore < -EntryZScore); // long A, short B
   if(!buyPair && !sellPair) return;
   
   // Position sizing
   double lot = NormalizeDouble(equity / 1000.0 * (RiskPercent / 100.0), 2);
   lot = MathMax(0.01, lot);
   lot = MathMin(lot, SymbolInfoDouble(AssetA, SYMBOL_VOLUME_MAX));
   
   PairTrade newTrade;
   newTrade.closed = false;
   newTrade.profitLock = 0;
   
   if(buyPair) {
      newTrade.ticketA = tradeA.Sell(lot, AssetA, SymbolInfoDouble(AssetA, SYMBOL_BID), 0, 0, "Short A");
      newTrade.ticketB = tradeB.Buy(lot, AssetB, SymbolInfoDouble(AssetB, SYMBOL_ASK), 0, 0, "Long B");
      if(newTrade.ticketA && newTrade.ticketB)
         Print("🔥 OPENED: Short ", AssetA, " + Long ", AssetB, " | Z=", zScore);
      else {
         if(newTrade.ticketA) tradeA.PositionClose(newTrade.ticketA);
         if(newTrade.ticketB) tradeB.PositionClose(newTrade.ticketB);
         Print("❌ Failed to open pair");
         return;
      }
   }
   else if(sellPair) {
      newTrade.ticketA = tradeA.Buy(lot, AssetA, SymbolInfoDouble(AssetA, SYMBOL_ASK), 0, 0, "Long A");
      newTrade.ticketB = tradeB.Sell(lot, AssetB, SymbolInfoDouble(AssetB, SYMBOL_BID), 0, 0, "Short B");
      if(newTrade.ticketA && newTrade.ticketB)
         Print("🔥 OPENED: Long ", AssetA, " + Short ", AssetB, " | Z=", zScore);
      else {
         if(newTrade.ticketA) tradeA.PositionClose(newTrade.ticketA);
         if(newTrade.ticketB) tradeB.PositionClose(newTrade.ticketB);
         Print("❌ Failed to open pair");
         return;
      }
   }
   
   int sz = ArraySize(activeTrades);
   ArrayResize(activeTrades, sz+1);
   activeTrades[sz] = newTrade;
   lastTrade = now;
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
