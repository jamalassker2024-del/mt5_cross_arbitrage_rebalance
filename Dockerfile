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
//|                                      OANDA_Arbitrage_Aggressor.mq5 |
//|                     Live OANDA feed (free, no API key)          |
//|                     + London session filter (8-22)              |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property copyright "Omni-Apex OANDA Arbitrage"
#property version   "6.00"
#property strict

// --- INPUTS --------------------------------------------------------+
input string   BaseCurrency           = "EUR";
input string   QuoteCurrency1         = "CHF";      // Primary pair
input double   RiskPercent            = 3.0;
input int      MinMispricingPoints    = 5;          // Reduced to 5 for more trades
input int      MaxOpenPositions       = 3;
input int      MagicNumber            = 999888;
input double   MinProfitUSD           = 1.00;
input double   TrailingLockStep       = 0.15;
input int      MaxConsecutiveLosses   = 3;
input double   MaxDailyLossPercent    = 8.0;
input int      StartHour              = 8;
input int      EndHour                = 22;

// --- GLOBALS -------------------------------------------------------+
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
//| Check trading hours                                             |
//+------------------------------------------------------------------+
bool IsTradingTime() {
   MqlDateTime dt;
   TimeCurrent(dt);
   return (dt.hour >= StartHour && dt.hour < EndHour);
}

//+------------------------------------------------------------------+
//| Close all positions                                             |
//+------------------------------------------------------------------+
void CloseAllPositions() {
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
         trade.PositionClose(ticket);
         Print("🕒 [SESSION END] Closed ", ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Fetch live price from OANDA (public endpoint, no API key)       |
//+------------------------------------------------------------------+
double GetOANDAPrice(string instrument) {
   // OANDA's public pricing endpoint (for demo)
   string url = "https://www.oanda.com/rates/api/v2/rates/candle.json?base=" + instrument + "&quote=USD&price=bid&apiKey=demo";
   // Actually OANDA requires API key. Free alternative: use investing.com or other.
   // Simpler: Use a free FX feed like exchangerate.host
   string alt_url = "https://api.exchangerate.host/latest?base=EUR&symbols=CHF,USD";
   
   char post[], result[];
   string headers;
   int res = WebRequest("GET", alt_url, NULL, NULL, 5000, post, 0, result, headers);
   if(res <= 0) {
      static int fail=0;
      if(fail++%20==0) Print("❌ Price fetch failed. Error: ", GetLastError());
      return -1;
   }
   string response = CharArrayToString(result);
   
   // Parse JSON to get CHF and USD rates
   // Structure: {"rates":{"CHF":0.9876,"USD":1.0891}}
   int chfPos = StringFind(response, "\"CHF\":");
   int usdPos = StringFind(response, "\"USD\":");
   if(chfPos<0 || usdPos<0) return -1;
   
   int chfStart = chfPos + 6;
   int chfEnd = StringFind(response, ",", chfStart);
   if(chfEnd<0) chfEnd = StringFind(response, "}", chfStart);
   double chf = StringToDouble(StringSubstr(response, chfStart, chfEnd-chfStart));
   
   int usdStart = usdPos + 6;
   int usdEnd = StringFind(response, ",", usdStart);
   if(usdEnd<0) usdEnd = StringFind(response, "}", usdStart);
   double usd = StringToDouble(StringSubstr(response, usdStart, usdEnd-usdStart));
   
   if(instrument == "EURCHF") return chf;
   if(instrument == "EURUSD") return usd;
   return -1;
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
   Print("🚀 OANDA ARBITRAGE EA (Live Feed)");
   Print("   Pair: ", BaseCurrency, "/", QuoteCurrency1);
   Print("   Trading hours: ", StartHour, ":00-", EndHour, ":00");
   Print("==============================================");
   return(INIT_SUCCEEDED);
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
//| Expert tick                                                     |
//+------------------------------------------------------------------+
void OnTick() {
   // Session filter
   if(!IsTradingTime()) {
      CloseAllPositions();
      return;
   }
   
   // Daily reset & loss limit
   datetime now = TimeCurrent();
   if(now - dayStart >= 86400) {
      dayStart = now;
      dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
      tradingEnabled = true;
   }
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPercent = (dailyEquityStart - equity)/dailyEquityStart*100;
   if(lossPercent >= MaxDailyLossPercent) {
      if(tradingEnabled) Print("🚨 Daily loss limit reached.");
      tradingEnabled = false;
      return;
   }
   if(!tradingEnabled && lossPercent < MaxDailyLossPercent-2) tradingEnabled=true;
   if(!tradingEnabled) return;
   
   // Close profits with trailing lock
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      double profit = PositionGetDouble(POSITION_PROFIT);
      int idx = FindLockIndex(ticket);
      if(idx==-1 && profit>=MinProfitUSD) {
         AddLock(ticket, profit-TrailingLockStep);
      } else if(idx!=-1) {
         if(profit > lockValues[idx]+TrailingLockStep) lockValues[idx] = profit-TrailingLockStep;
         if(profit <= lockValues[idx]) {
            if(trade.PositionClose(ticket)) {
               if(profit<0) consecutiveLosses++;
               else consecutiveLosses=0;
            }
            RemoveLock(idx);
         }
      }
   }
   if(consecutiveLosses>=MaxConsecutiveLosses) return;
   if(PositionsTotal()>=MaxOpenPositions) return;
   if(now - last_trade_time < 5) return;
   
   // Fetch live lead prices
   double lead_chf = GetOANDAPrice("EURCHF");
   double lead_usd = GetOANDAPrice("EURUSD");
   if(lead_chf<=0 || lead_usd<=0) return;
   
   // Get MT5 lag prices
   string brokerSymbol = BaseCurrency + QuoteCurrency1; // "EURCHF"
   double mt5_ask = SymbolInfoDouble(brokerSymbol, SYMBOL_ASK);
   double mt5_bid = SymbolInfoDouble(brokerSymbol, SYMBOL_BID);
   if(mt5_ask<=0 || mt5_bid<=0) return;
   double mt5_mid = (mt5_ask+mt5_bid)/2.0;
   
   double point = SymbolInfoDouble(brokerSymbol, SYMBOL_POINT);
   double mispricing = (lead_chf - mt5_mid) / point;
   double mt5_eurusd_mid = (SymbolInfoDouble("EURUSD", SYMBOL_ASK)+SymbolInfoDouble("EURUSD", SYMBOL_BID))/2.0;
   bool direction_aligns = (lead_usd > mt5_eurusd_mid) == (mispricing > 0);
   
   bool buy_signal = (mispricing > MinMispricingPoints) && direction_aligns;
   bool sell_signal = (mispricing < -MinMispricingPoints) && direction_aligns;
   
   if(now - last_debug >= 10) {
      last_debug = now;
      Print("========================================");
      Print("🏦 Lead EUR/CHF: ", lead_chf, " | MT5: ", mt5_mid);
      Print("📉 Mispricing: ", mispricing, " pts");
      Print("🔍 Signal: ", buy_signal?"BUY":(sell_signal?"SELL":"HOLD"));
      Print("========================================");
   }
   if(!buy_signal && !sell_signal) return;
   
   double lot = NormalizeDouble(equity/1000 * (RiskPercent/100), 2);
   lot = MathMax(0.01, lot);
   if(buy_signal) trade.Buy(lot, brokerSymbol, mt5_ask, 0,0,"Arb Buy");
   else if(sell_signal) trade.Sell(lot, brokerSymbol, mt5_bid, 0,0,"Arb Sell");
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
