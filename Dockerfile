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
//|                                      ULTRA_DEBUG_ARBITRAGE.mq5   |
//|                     Prints everything, trades on tiny gaps      |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property copyright "Debug Arbitrage"
#property version   "7.00"
#property strict

// --- INPUTS (aggressive)
input string   BaseCurrency           = "EUR";
input string   QuoteCurrency1         = "CHF";
input double   RiskPercent            = 3.0;
input int      MinMispricingPoints    = 1;          // ANY difference >=1 point triggers trade
input int      MaxOpenPositions       = 3;
input int      MagicNumber            = 999888;
input double   MinProfitUSD           = 0.50;       // Lower profit target for testing
input double   TrailingLockStep       = 0.10;
input int      MaxConsecutiveLosses   = 5;
input double   MaxDailyLossPercent    = 15.0;
input int      StartHour              = 0;          // TRADE ALL DAY for testing
input int      EndHour                = 24;

// --- GLOBALS
CTrade trade;
datetime last_debug = 0;
datetime last_trade_time = 0;
datetime dayStart = 0;
double dailyEquityStart = 0;
bool tradingEnabled = true;
int consecutiveLosses = 0;
ulong   lockTickets[];
double  lockValues[];

//+------------------------------------------------------------------+
//| Check trading hours (always true now)                           |
//+------------------------------------------------------------------+
bool IsTradingTime() {
   MqlDateTime dt;
   TimeCurrent(dt);
   int hour = dt.hour;
   // Force debug: print hour every 10 seconds
   if(TimeCurrent() - last_debug >= 10) {
      Print("⏰ Current server hour: ", hour, " (Trading hours: ", StartHour, "-", EndHour, ")");
   }
   return (hour >= StartHour && hour < EndHour);
}

//+------------------------------------------------------------------+
//| Close all positions                                             |
//+------------------------------------------------------------------+
void CloseAllPositions() {
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
         trade.PositionClose(ticket);
         Print("🕒 Closed position ", ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Fetch live EUR/CHF and EUR/USD from exchangerate.host           |
//+------------------------------------------------------------------+
bool FetchRates(double &eur_chf, double &eur_usd) {
   string url = "https://api.exchangerate.host/latest?base=EUR&symbols=CHF,USD";
   char post[], result[];
   string headers;
   int res = WebRequest("GET", url, NULL, NULL, 5000, post, 0, result, headers);
   if(res <= 0) {
      static int failCount = 0;
      if(failCount++ % 10 == 0) Print("❌ WebRequest failed, error: ", GetLastError());
      return false;
   }
   string response = CharArrayToString(result);
   // Parse JSON: {"rates":{"CHF":0.9876,"USD":1.0891}}
   int chfPos = StringFind(response, "\"CHF\":");
   if(chfPos < 0) { Print("CHF not found in response"); return false; }
   int chfStart = chfPos + 6;
   int chfEnd = StringFind(response, ",", chfStart);
   if(chfEnd < 0) chfEnd = StringFind(response, "}", chfStart);
   eur_chf = StringToDouble(StringSubstr(response, chfStart, chfEnd - chfStart));
   
   int usdPos = StringFind(response, "\"USD\":");
   if(usdPos < 0) return false;
   int usdStart = usdPos + 6;
   int usdEnd = StringFind(response, ",", usdStart);
   if(usdEnd < 0) usdEnd = StringFind(response, "}", usdStart);
   eur_usd = StringToDouble(StringSubstr(response, usdStart, usdEnd - usdStart));
   
   return (eur_chf > 0 && eur_usd > 0);
}

//+------------------------------------------------------------------+
//| Trailing lock helpers                                           |
//+------------------------------------------------------------------+
int FindLockIndex(ulong ticket) {
   for(int i=0; i<ArraySize(lockTickets); i++)
      if(lockTickets[i]==ticket) return i;
   return -1;
}
void RemoveLock(int idx) {
   int sz=ArraySize(lockTickets);
   for(int i=idx; i<sz-1; i++) {
      lockTickets[i]=lockTickets[i+1];
      lockValues[i]=lockValues[i+1];
   }
   ArrayResize(lockTickets, sz-1);
   ArrayResize(lockValues, sz-1);
}
void AddLock(ulong ticket, double lockValue) {
   int sz=ArraySize(lockTickets);
   ArrayResize(lockTickets, sz+1);
   ArrayResize(lockValues, sz+1);
   lockTickets[sz]=ticket;
   lockValues[sz]=lockValue;
}

//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   SymbolSelect(_Symbol, true);
   dayStart = TimeCurrent();
   dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("==============================================");
   Print("🚀 ULTRA DEBUG ARBITRAGE EA");
   Print("   Trading pair: ", BaseCurrency, QuoteCurrency1);
   Print("   Min mispricing: ", MinMispricingPoints, " points");
   Print("   Trading hours: ", StartHour, "-", EndHour, " (FORCED ALL DAY FOR TEST)");
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick                                                     |
//+------------------------------------------------------------------+
void OnTick() {
   // --- 1. Check trading hours and close if outside
   if(!IsTradingTime()) {
      CloseAllPositions();
      return;
   }
   
   // --- 2. Daily reset and loss limit
   datetime now = TimeCurrent();
   if(now - dayStart >= 86400) {
      dayStart = now;
      dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
      tradingEnabled = true;
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
   
   // --- 3. Close profitable positions with trailing lock
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      double profit = PositionGetDouble(POSITION_PROFIT);
      int lockIdx = FindLockIndex(ticket);
      if(lockIdx == -1 && profit >= MinProfitUSD) {
         AddLock(ticket, profit - TrailingLockStep);
         Print("🔒 Lock set at $", profit - TrailingLockStep);
      } else if(lockIdx != -1) {
         if(profit > lockValues[lockIdx] + TrailingLockStep) {
            lockValues[lockIdx] = profit - TrailingLockStep;
            Print("🔓 Trail lock raised to $", lockValues[lockIdx]);
         }
         if(profit <= lockValues[lockIdx]) {
            if(trade.PositionClose(ticket)) {
               Print("✅ Closed $", profit);
               if(profit < 0) consecutiveLosses++;
               else consecutiveLosses = 0;
            }
            RemoveLock(lockIdx);
         }
      }
   }
   
   if(consecutiveLosses >= MaxConsecutiveLosses) {
      static int warn=0;
      if(warn++%50==0) Print("⛔ Paused due to losses");
      return;
   }
   if(PositionsTotal() >= MaxOpenPositions) return;
   if(now - last_trade_time < 3) return;
   
   // --- 4. Fetch live lead rates
   double lead_chf, lead_usd;
   if(!FetchRates(lead_chf, lead_usd)) return;
   
   // --- 5. Get MT5 lag price for EURCHF
   string symbol = BaseCurrency + QuoteCurrency1; // "EURCHF"
   double mt5_ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double mt5_bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   if(mt5_ask <= 0 || mt5_bid <= 0) {
      Print("❌ MT5 no price for ", symbol);
      return;
   }
   double mt5_mid = (mt5_ask + mt5_bid) / 2.0;
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double mispricing_points = (lead_chf - mt5_mid) / point;
   
   // --- 6. Debug every 5 seconds
   if(now - last_debug >= 5) {
      last_debug = now;
      Print("========================================");
      Print("📊 Lead EUR/CHF: ", lead_chf, " | MT5: ", mt5_mid);
      Print("📉 Mispricing: ", DoubleToString(mispricing_points, 2), " points");
      Print("📈 Positions: ", PositionsTotal(), " | Loss streak: ", consecutiveLosses);
      Print("========================================");
   }
   
   // --- 7. Signal: any mispricing above threshold
   bool buy_signal = (mispricing_points > MinMispricingPoints);
   bool sell_signal = (mispricing_points < -MinMispricingPoints);
   if(!buy_signal && !sell_signal) return;
   
   // --- 8. Position sizing
   double lot = NormalizeDouble(equity / 1000.0 * (RiskPercent / 100.0), 2);
   lot = MathMax(0.01, lot);
   
   // --- 9. Execute
   if(buy_signal) {
      if(trade.Buy(lot, symbol, mt5_ask, 0, 0, "Debug Buy"))
         Print("🔥 BUY at ", mt5_ask, " mispricing: ", mispricing_points);
      else Print("❌ Buy failed: ", GetLastError());
   } else if(sell_signal) {
      if(trade.Sell(lot, symbol, mt5_bid, 0, 0, "Debug Sell"))
         Print("🔥 SELL at ", mt5_bid, " mispricing: ", mispricing_points);
      else Print("❌ Sell failed: ", GetLastError());
   }
   last_trade_time = now;
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
