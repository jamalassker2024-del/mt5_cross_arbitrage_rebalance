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
#include <Trade\Trade.mqh>

#property copyright "Omni-Apex V20.0"
#property version   "20.00"
#property strict

// --- AGGRESSIVE LOOSE INPUTS
input string BinanceSymbol     = "BTCUSDT";
input double RiskPercent       = 8.0;       // Larger risk for bigger lots
input int    MinGap_BPS        = 0;         // Any positive gap triggers trade
input int    Fee_BPS           = 3;         // Almost ignore fees
input int    MaxOpenPositions  = 50;        // Huge stacking allowed
input int    MagicNumber       = 999020;

// --- GLOBALS
CTrade trade;
string binance_url;

int OnInit() {
   binance_url = "https://api.binance.com/api/v3/ticker/bookTicker?symbol=" + BinanceSymbol;
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   Print("🛠️ DEBUG: V20.0 LOOSE MODE - Target Lead: ", BinanceSymbol);
   return(INIT_SUCCEEDED);
}

// --- HELPER: SAFE JSON EXTRACTION
double GetVal(string text, string key) {
   int pos = StringFind(text, key);
   if(pos == -1) return 0;
   int start = pos + StringLen(key);
   int end = StringFind(text, "\"", start);
   return StringToDouble(StringSubstr(text, start, end - start));
}

void OnTick() {
   // 1. INSTANT CLOSE ON ANY PROFIT (FAST OUT)
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
         double profit = PositionGetDouble(POSITION_PROFIT);
         if(profit > 0) {                       // Closes as soon as 1 cent profit
            trade.PositionClose(ticket);
            Print("✅ FAST EXIT! Profit: ", profit);
         }
      }
   }

   if(PositionsTotal() >= MaxOpenPositions) return;

   // 2. FETCH BINANCE DATA
   char post[], result[];
   string headers;
   int res = WebRequest("GET", binance_url, NULL, NULL, 50, post, 0, result, headers);

   if(res <= 0) {
      Print("⚠️ WebRequest Failed. Error: ", GetLastError());
      return;
   }

   string resp = CharArrayToString(result);
   double b_ask = GetVal(resp, "\"askPrice\":\"");
   double b_bid = GetVal(resp, "\"bidPrice\":\"");

   if(b_ask <= 0 || b_bid <= 0) {
      Print("⚠️ Failed to parse Binance JSON. Response: ", resp);
      return;
   }

   double m_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double m_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // 3. ARBITRAGE GAP (ULTRA LOOSE THRESHOLD)
   double buy_gap = (b_bid - m_ask) / m_ask * 10000.0;
   double sell_gap = (m_bid - b_ask) / b_ask * 10000.0;

   // 4. OPEN TRADES ON SMALLEST GAP (MinGap_BPS = 0)
   if(buy_gap > (MinGap_BPS + Fee_BPS)) {
      double lot = (AccountInfoDouble(ACCOUNT_EQUITY) / 1000.0) * (RiskPercent/2.0) * 0.2;
      if(trade.Buy(lot, _Symbol, m_ask, 0, 0, "Sonic Buy (Loose)"))
         PrintFormat("🔥 BUY OPEN | Gap: %.2f bps | Price: %.2f", buy_gap, m_ask);
   }
   else if(sell_gap > (MinGap_BPS + Fee_BPS)) {
      double lot = (AccountInfoDouble(ACCOUNT_EQUITY) / 1000.0) * (RiskPercent/2.0) * 0.2;
      if(trade.Sell(lot, _Symbol, m_bid, 0, 0, "Sonic Sell (Loose)"))
         PrintFormat("🔥 SELL OPEN | Gap: %.2f bps | Price: %.2f", sell_gap, m_bid);
   }
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
