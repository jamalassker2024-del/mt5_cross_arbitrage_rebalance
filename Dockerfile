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
//|                                    Pairs_Trading_Strict_One.mq5  |
//|                     Only one active pair, closes on profit/time |
//|                     No SL/TP, only profit exit + time limit     |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property copyright "Strict Pairs Trading"
#property version   "5.0"
#property strict

// --- INPUTS --------------------------------------------------------+
input string   AssetA           = "EURUSD.vx";
input string   AssetB           = "GBPUSD.vx";
input double   RiskPercent      = 2.0;              // % equity per trade (total for both legs)
input int      LookbackPeriod   = 50;               // Period for spread mean/std dev
input double   EntryZScore      = 2.0;              // Entry threshold (absolute)
input int      MaxHoldMinutes   = 60;               // Max holding time (minutes) – force close
input bool     CloseOnAnyProfit = true;             // Close when total profit > 0
input double   MinProfitUSD     = 1.00;             // Min profit to close (if CloseOnAnyProfit=false)
input int      MagicNumber      = 777888;
input int      StartHour        = 0;                // Trading hours
input int      EndHour          = 24;
input double   MaxDailyLossPercent = 10.0;          // Daily loss limit
input bool     DebugPrint       = true;

// --- GLOBALS -------------------------------------------------------+
CTrade tradeA, tradeB;
double spreadBuffer[];
datetime lastDebug = 0;
datetime lastTrade = 0;
datetime dayStart = 0;
double dailyEquityStart = 0;
int consecutiveLosses = 0;
bool tradingEnabled = true;

// --- Single active pair trade -------------------------------------+
struct ActivePair {
   ulong ticketA;
   ulong ticketB;
   datetime openTime;
   bool isOpen;
};
ActivePair currentPair;

//+------------------------------------------------------------------+
//| Check trading hours                                             |
//+------------------------------------------------------------------+
bool IsTradingTime() {
   MqlDateTime dt;
   TimeCurrent(dt);
   return (dt.hour >= StartHour && dt.hour < EndHour);
}

//+------------------------------------------------------------------+
//| Calculate Z-Score of spread (bidA - bidB)                       |
//+------------------------------------------------------------------+
double GetZScore() {
   double bidA = SymbolInfoDouble(AssetA, SYMBOL_BID);
   double bidB = SymbolInfoDouble(AssetB, SYMBOL_BID);
   if(bidA <= 0 || bidB <= 0) return 0;
   double spread = bidA - bidB;
   
   int sz = ArraySize(spreadBuffer);
   if(sz < LookbackPeriod) {
      ArrayResize(spreadBuffer, LookbackPeriod);
      for(int i=sz; i<LookbackPeriod; i++) spreadBuffer[i] = spread;
   }
   for(int i=LookbackPeriod-1; i>0; i--)
      spreadBuffer[i] = spreadBuffer[i-1];
   spreadBuffer[0] = spread;
   
   double mean = 0, sum = 0;
   for(int i=0; i<LookbackPeriod; i++) sum += spreadBuffer[i];
   mean = sum / LookbackPeriod;
   double variance = 0;
   for(int i=0; i<LookbackPeriod; i++) variance += MathPow(spreadBuffer[i] - mean, 2);
   double stdDev = MathSqrt(variance / LookbackPeriod);
   if(stdDev == 0) return 0;
   return (spread - mean) / stdDev;
}

//+------------------------------------------------------------------+
//| Close the current pair trade                                    |
//+------------------------------------------------------------------+
void ClosePairTrade(string reason) {
   if(!currentPair.isOpen) return;
   if(currentPair.ticketA != 0 && PositionSelectByTicket(currentPair.ticketA))
      tradeA.PositionClose(currentPair.ticketA);
   if(currentPair.ticketB != 0 && PositionSelectByTicket(currentPair.ticketB))
      tradeB.PositionClose(currentPair.ticketB);
   currentPair.isOpen = false;
   Print("Closed pair trade: ", reason);
}

//+------------------------------------------------------------------+
//| Initialize                                                      |
//+------------------------------------------------------------------+
int OnInit() {
   tradeA.SetExpertMagicNumber(MagicNumber);
   tradeB.SetExpertMagicNumber(MagicNumber+1);
   SymbolSelect(AssetA, true);
   SymbolSelect(AssetB, true);
   currentPair.isOpen = false;
   currentPair.ticketA = 0;
   currentPair.ticketB = 0;
   dayStart = TimeCurrent();
   dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("==============================================");
   Print("📊 STRICT PAIRS TRADING EA (Single pair)");
   Print("   ", AssetA, " <-> ", AssetB);
   Print("   Entry Z‑Score: ±", EntryZScore);
   Print("   Max hold time: ", MaxHoldMinutes, " min");
   Print("   Close on any profit: ", CloseOnAnyProfit);
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Tick handler                                                    |
//+------------------------------------------------------------------+
void OnTick() {
   // --- Session filter ---
   if(!IsTradingTime()) {
      if(currentPair.isOpen) ClosePairTrade("Session ended");
      return;
   }
   
   // --- Daily loss & reset ---
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
   
   // --- Manage active pair trade (if any) ---
   if(currentPair.isOpen) {
      // Calculate total profit of the pair
      double profit = 0;
      if(currentPair.ticketA != 0 && PositionSelectByTicket(currentPair.ticketA))
         profit += PositionGetDouble(POSITION_PROFIT);
      if(currentPair.ticketB != 0 && PositionSelectByTicket(currentPair.ticketB))
         profit += PositionGetDouble(POSITION_PROFIT);
      
      // Fast exit on profit
      if(CloseOnAnyProfit && profit > 0) {
         ClosePairTrade("Profit > 0 ($" + DoubleToString(profit,2) + ")");
         consecutiveLosses = 0;
         return;
      }
      if(!CloseOnAnyProfit && profit >= MinProfitUSD) {
         ClosePairTrade("Profit target $" + DoubleToString(MinProfitUSD));
         consecutiveLosses = 0;
         return;
      }
      // Force close after max holding time
      if(MaxHoldMinutes > 0 && (now - currentPair.openTime) >= MaxHoldMinutes * 60) {
         ClosePairTrade("Max holding time (" + IntegerToString(MaxHoldMinutes) + " min)");
         // Do NOT reset consecutiveLosses here – this is a neutral exit.
         return;
      }
      return; // still holding
   }
   
   // --- No active pair: check if we can open a new one ---
   if(consecutiveLosses >= 3) {
      static int warn=0; if(warn++%50==0) Print("⛔ Paused due to consecutive losses");
      return;
   }
   if(now - lastTrade < 10) return; // cooldown
   
   // Get entry signal
   double zScore = GetZScore();
   if(zScore == 0 || ArraySize(spreadBuffer) < LookbackPeriod) return;
   
   // Debug output every 5 seconds
   if(DebugPrint && now - lastDebug >= 5) {
      lastDebug = now;
      double bidA = SymbolInfoDouble(AssetA, SYMBOL_BID);
      double bidB = SymbolInfoDouble(AssetB, SYMBOL_BID);
      Print("📊 Spread: ", DoubleToString(bidA-bidB,5), " Z‑Score: ", DoubleToString(zScore,2));
   }
   
   bool openShortA_LongB = (zScore > EntryZScore);   // short A, long B
   bool openLongA_ShortB = (zScore < -EntryZScore);  // long A, short B
   if(!openShortA_LongB && !openLongA_ShortB) return;
   
   // Calculate lot size (equal for both legs)
   double lot = NormalizeDouble(equity / 1000.0 * (RiskPercent / 100.0), 2);
   lot = MathMax(0.01, lot);
   lot = MathMin(lot, SymbolInfoDouble(AssetA, SYMBOL_VOLUME_MAX));
   
   double askA = SymbolInfoDouble(AssetA, SYMBOL_ASK);
   double bidA = SymbolInfoDouble(AssetA, SYMBOL_BID);
   double askB = SymbolInfoDouble(AssetB, SYMBOL_ASK);
   double bidB = SymbolInfoDouble(AssetB, SYMBOL_BID);
   
   // Open the pair trade (no SL/TP)
   ulong ticketA = 0, ticketB = 0;
   if(openShortA_LongB) {
      ticketA = tradeA.Sell(lot, AssetA, bidA, 0, 0, "Short A");
      ticketB = tradeB.Buy(lot, AssetB, askB, 0, 0, "Long B");
   } else {
      ticketA = tradeA.Buy(lot, AssetA, askA, 0, 0, "Long A");
      ticketB = tradeB.Sell(lot, AssetB, bidB, 0, 0, "Short B");
   }
   
   if(ticketA != 0 && ticketB != 0) {
      currentPair.ticketA = ticketA;
      currentPair.ticketB = ticketB;
      currentPair.openTime = now;
      currentPair.isOpen = true;
      lastTrade = now;
      Print("🔥 Opened pair trade. Lots=", lot, " Z=", zScore);
   } else {
      // Clean up partial orders
      if(ticketA != 0) tradeA.PositionClose(ticketA);
      if(ticketB != 0) tradeB.PositionClose(ticketB);
      Print("❌ Failed to open pair trade");
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
