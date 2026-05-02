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

#property copyright "Omni-Apex V18"
#property version   "18.00"
#property strict

// --- INPUTS
input string BinanceSymbol     = "BTCUSDT";  // Binance Reference Symbol
input double RiskPercent       = 2.0;         // Exponential Growth[cite: 2]
input int    MinGap_BPS        = 8;           // Min Gap to trade (8bps)[cite: 1]
input int    Fee_BPS           = 16;          // Fees to cover (15.5bps rounded)[cite: 1]
input int    MaxSpread_Pips    = 500;         
input int    MagicNumber       = 999018;

// --- GLOBALS
CTrade trade;
string binance_url;

int OnInit() {
   binance_url = "https://api.binance.com/api/v3/ticker/bookTicker?symbol=" + BinanceSymbol;
   trade.SetExpertMagicNumber(MagicNumber);
   
   // Check if WebRequest is allowed
   if(!TerminalInfoInteger(TERMINAL_HTTP_ENABLED)) {
      Print("❌ ERROR: WebRequest is not enabled. Add api.binance.com to the allowed list.");
      return(INIT_FAILED);
   }
   
   Print("V18 ARBITRAGE START: Lead=", BinanceSymbol, " | Lag=", _Symbol);
   return(INIT_SUCCEEDED);
}

// --- EXPONENTIAL LOT CALCULATION[cite: 2]
double GetDynamicLot() {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lot = (equity * (RiskPercent / 100.0)) / 1000.0; // Simplified scaling
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   return NormalizeDouble(MathMax(minLot, lot), 2);
}

void OnTick() {
   char post[], result[];
   string headers;
   int res = WebRequest("GET", binance_url, NULL, NULL, 50, post, 0, result, headers);

   if(res == -1) {
      Print("WebRequest Error: ", GetLastError());
      return;
   }

   // --- FAST PARSE BINANCE PRICE (Simple string search)
   string response = CharArrayToString(result);
   int ask_pos = StringFind(response, "\"askPrice\":\"");
   if(ask_pos == -1) return;
   
   string ask_str = StringSubstr(response, ask_pos + 12);
   double binance_ask = StringToDouble(StringSubstr(ask_str, 0, StringFind(ask_str, "\"")));
   
   int bid_pos = StringFind(response, "\"bidPrice\":\"");
   string bid_str = StringSubstr(response, bid_pos + 12);
   double binance_bid = StringToDouble(StringSubstr(bid_str, 0, StringFind(bid_str, "\"")));

   // --- COMPARE WITH MT5 LAG
   double mt5_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mt5_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   // Calculate Gap in Basis Points (BPS)[cite: 1]
   double buy_gap_bps = (binance_bid - mt5_ask) / mt5_ask * 10000;
   double sell_gap_bps = (mt5_bid - binance_ask) / binance_ask * 10000;

   if(PositionsTotal() >= 1) return;

   // EXECUTE IF PROFITABLE AFTER FEES[cite: 1]
   if(buy_gap_bps > (MinGap_BPS + Fee_BPS)) {
      double lot = GetDynamicLot();
      double tp = mt5_ask + (buy_gap_bps * 0.5 * point * 10); // Take profit halfway
      PrintFormat("🎯 ARB BUY: Gap %.2f bps | Lot: %.2f", buy_gap_bps, lot);
      trade.Buy(lot, _Symbol, mt5_ask, 0, tp, "Arb Lead Buy");
   }
   else if(sell_gap_bps > (MinGap_BPS + Fee_BPS)) {
      double lot = GetDynamicLot();
      double tp = mt5_bid - (sell_gap_bps * 0.5 * point * 10);
      PrintFormat("🎯 ARB SELL: Gap %.2f bps | Lot: %.2f", sell_gap_bps, lot);
      trade.Sell(lot, _Symbol, mt5_bid, 0, tp, "Arb Lead Sell");
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
