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

#property copyright "Omni-Apex V19.3 FIXED"
#property version   "19.30"
#property strict

// --- INPUTS
input string BinanceSymbol     = "BTCUSDT";
input double RiskPercent       = 3.0;
input int    MinGap_BPS        = 2;          // MODIFIED: Lowered to 2 for ultra-sensitivity
input int    Fee_BPS           = 14;
input int    TradeCooldown_Sec = 1;
input int    MaxOpenPositions  = 10;
input int    MaxSpreadPoints   = 500;
input int    MagicNumber       = 999019;

// --- GLOBALS
CTrade trade;
string binance_url;
datetime last_trade_time = 0;

double ExtractPrice(string text, string key) {
   int pos = StringFind(text, key);
   if(pos == -1) return 0;
   int start = pos + StringLen(key);
   int end = StringFind(text, "\"", start);
   if(end == -1) return 0;
   return StringToDouble(StringSubstr(text, start, end - start));
}

double GetDynamicLot() {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lot = (equity / 1000.0) * (RiskPercent / 2.0) * 0.2;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   return NormalizeDouble(MathMax(minLot, lot), 2);
}

void OnInit() {
   binance_url = "https://api.binance.com/api/v3/ticker/bookTicker?symbol=" + BinanceSymbol;
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   trade.SetDeviationInPoints(30);
   Print("🚀 V19.3 ULTRA-SENSITIVE ONLINE | MinGap: 2");
}

void OnTick() {
   if(PositionsTotal() >= MaxOpenPositions) return;
   if(TimeCurrent() - last_trade_time < TradeCooldown_Sec) return;

   double m_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double m_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spread = (m_ask - m_bid) / _Point;
   if(spread > MaxSpreadPoints) return;

   char post[], result[];
   string headers;
   int timeout = 100;
   
   int res = WebRequest("GET", binance_url, NULL, NULL, timeout, post, 0, result, headers);
   if(res <= 0) return;

   string response = CharArrayToString(result);
   double b_ask = ExtractPrice(response, "\"askPrice\":\"");
   double b_bid = ExtractPrice(response, "\"bidPrice\":\"");
   if(b_ask <= 0 || b_bid <= 0) return;

   double buy_gap = (b_bid - m_ask) / m_ask * 10000.0;
   double sell_gap = (m_bid - b_ask) / b_ask * 10000.0;
   double lot = GetDynamicLot();

   if(buy_gap > (MinGap_BPS + Fee_BPS)) {
      if(trade.Buy(lot, _Symbol, m_ask, 0, 0, "Apex Aggressor")) {
         last_trade_time = TimeCurrent();
         Print("🔥 BUY | Gap: ", buy_gap);
      }
   }
   else if(sell_gap > (MinGap_BPS + Fee_BPS)) {
      if(trade.Sell(lot, _Symbol, m_bid, 0, 0, "Apex Aggressor")) {
         last_trade_time = TimeCurrent();
         Print("🔥 SELL | Gap: ", sell_gap);
      }
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
