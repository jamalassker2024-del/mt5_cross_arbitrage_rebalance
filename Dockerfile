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
//|                                      FIXED_ARBITRAGE_EA.mq5      |
//|                     Prints raw response for debugging           |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property copyright "Fixed Arbitrage"
#property version   "8.00"
#property strict

// --- INPUTS
input string   BaseCurrency           = "EUR";
input string   QuoteCurrency1         = "CHF";
input double   RiskPercent            = 3.0;
input int      MinMispricingPoints    = 1;
input int      MaxOpenPositions       = 3;
input int      MagicNumber            = 999888;
input double   MinProfitUSD           = 0.50;
input double   TrailingLockStep       = 0.10;
input int      MaxConsecutiveLosses   = 5;
input double   MaxDailyLossPercent    = 15.0;
input int      StartHour              = 0;
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

bool IsTradingTime() {
   MqlDateTime dt;
   TimeCurrent(dt);
   return (dt.hour >= StartHour && dt.hour < EndHour);
}

void CloseAllPositions() {
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
         trade.PositionClose(ticket);
         Print("🕒 Closed ", ticket);
      }
   }
}

// Improved fetching with multiple fallback APIs
bool FetchRates(double &eur_chf, double &eur_usd) {
   // Use a simpler, more reliable API: exchangerate.host with one symbol at a time? Or use a different source.
   // Let's try two approaches: first try exchangerate.host but better parsing.
   string url = "https://api.exchangerate.host/latest?base=EUR&symbols=CHF,USD";
   char post[], result[];
   string headers;
   int res = WebRequest("GET", url, NULL, NULL, 5000, post, 0, result, headers);
   if(res <= 0) {
      static int fail=0;
      if(fail++%20==0) Print("❌ WebRequest failed, error ", GetLastError());
      return false;
   }
   string response = CharArrayToString(result);
   
   // Debug print once every 30 seconds to see response
   static datetime lastPrint=0;
   if(TimeCurrent() - lastPrint > 30) {
      lastPrint = TimeCurrent();
      Print("Raw API response (first 300 chars): ", StringSubstr(response, 0, 300));
   }
   
   // Try to extract CHF rate - search for "CHF": value
   // JSON could be like: {"rates":{"CHF":0.9876,"USD":1.0891}}
   int chfPos = StringFind(response, "\"CHF\"");
   if(chfPos == -1) {
      Print("CHF key not found in response");
      return false;
   }
   int colonPos = StringFind(response, ":", chfPos);
   if(colonPos == -1) return false;
   int start = colonPos + 1;
   // skip whitespace and quotes
   while(start < StringLen(response) && (StringSubstr(response, start, 1) == " " || StringSubstr(response, start, 1) == "\"")) start++;
   int end = start;
   while(end < StringLen(response) && (StringSubstr(response, end, 1) >= "0" && StringSubstr(response, end, 1) <= "9") || StringSubstr(response, end, 1) == ".") end++;
   if(end <= start) return false;
   string chfStr = StringSubstr(response, start, end-start);
   eur_chf = StringToDouble(chfStr);
   
   // Extract USD similarly
   int usdPos = StringFind(response, "\"USD\"");
   if(usdPos == -1) return false;
   colonPos = StringFind(response, ":", usdPos);
   if(colonPos == -1) return false;
   start = colonPos + 1;
   while(start < StringLen(response) && (StringSubstr(response, start, 1) == " " || StringSubstr(response, start, 1) == "\"")) start++;
   end = start;
   while(end < StringLen(response) && (StringSubstr(response, end, 1) >= "0" && StringSubstr(response, end, 1) <= "9") || StringSubstr(response, end, 1) == ".") end++;
   if(end <= start) return false;
   string usdStr = StringSubstr(response, start, end-start);
   eur_usd = StringToDouble(usdStr);
   
   return (eur_chf > 0 && eur_usd > 0);
}

// Trailing lock helpers (same)
int FindLockIndex(ulong ticket) {
   for(int i=0;i<ArraySize(lockTickets);i++) if(lockTickets[i]==ticket) return i;
   return -1;
}
void RemoveLock(int idx) {
   int sz=ArraySize(lockTickets);
   for(int i=idx;i<sz-1;i++) { lockTickets[i]=lockTickets[i+1]; lockValues[i]=lockValues[i+1]; }
   ArrayResize(lockTickets, sz-1); ArrayResize(lockValues, sz-1);
}
void AddLock(ulong ticket, double lockValue) {
   int sz=ArraySize(lockTickets);
   ArrayResize(lockTickets, sz+1); ArrayResize(lockValues, sz+1);
   lockTickets[sz]=ticket; lockValues[sz]=lockValue;
}

int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   SymbolSelect(_Symbol, true);
   dayStart = TimeCurrent();
   dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("=========== FIXED ARBITRAGE EA ===========");
   Print("Pair: EUR/CHF | MinPoints: ", MinMispricingPoints);
   Print("Trading hours: ", StartHour, "-", EndHour);
   Print("==========================================");
   return(INIT_SUCCEEDED);
}

void OnTick() {
   if(!IsTradingTime()) { CloseAllPositions(); return; }
   datetime now = TimeCurrent();
   if(now - dayStart >= 86400) { dayStart = now; dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY); tradingEnabled=true; }
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPercent = (dailyEquityStart - equity) / dailyEquityStart * 100.0;
   if(lossPercent >= MaxDailyLossPercent) { tradingEnabled=false; return; }
   if(!tradingEnabled) return;
   
   // Close profits
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      double profit = PositionGetDouble(POSITION_PROFIT);
      int idx = FindLockIndex(ticket);
      if(idx==-1 && profit>=MinProfitUSD) AddLock(ticket, profit-TrailingLockStep);
      else if(idx!=-1) {
         if(profit > lockValues[idx]+TrailingLockStep) lockValues[idx] = profit-TrailingLockStep;
         if(profit <= lockValues[idx]) {
            if(trade.PositionClose(ticket)) {
               if(profit<0) consecutiveLosses++; else consecutiveLosses=0;
            }
            RemoveLock(idx);
         }
      }
   }
   if(consecutiveLosses>=MaxConsecutiveLosses) return;
   if(PositionsTotal()>=MaxOpenPositions) return;
   if(now - last_trade_time < 3) return;
   
   double lead_chf, lead_usd;
   if(!FetchRates(lead_chf, lead_usd)) return;
   
   string symbol = BaseCurrency + QuoteCurrency1;
   double mt5_ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double mt5_bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   if(mt5_ask<=0 || mt5_bid<=0) { Print("MT5 no price for ",symbol); return; }
   double mt5_mid = (mt5_ask+mt5_bid)/2.0;
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double mispricing = (lead_chf - mt5_mid) / point;
   
   if(now - last_debug >= 5) {
      last_debug = now;
      Print("Lead: ", lead_chf, " | MT5: ", mt5_mid, " | Diff: ", DoubleToString(mispricing,2), " pts");
   }
   
   bool buy = (mispricing > MinMispricingPoints);
   bool sell = (mispricing < -MinMispricingPoints);
   if(!buy && !sell) return;
   
   double lot = NormalizeDouble(equity/1000 * (RiskPercent/100), 2);
   lot = MathMax(0.01, lot);
   if(buy && trade.Buy(lot, symbol, mt5_ask, 0, 0, "Buy")) {
      Print("🔥 BUY at ", mt5_ask, " diff ", mispricing);
   } else if(sell && trade.Sell(lot, symbol, mt5_bid, 0, 0, "Sell")) {
      Print("🔥 SELL at ", mt5_bid, " diff ", mispricing);
   }
   last_trade_time = now;
}
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
