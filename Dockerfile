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

#property copyright "Omni-Apex V18.1"
#property version   "18.10"
#property strict

// --- INPUTS
input string BinanceSymbol     = "BTCUSDT";  // Binance Lead Symbol
input double RiskPercent       = 2.0;        // Risk per trade for Exponential Growth[cite: 2]
input int    MinGap_BPS        = 8;          // Minimum profitable spread in bps[cite: 1]
input int    Fee_BPS           = 16;         // Total fees to cover (~15.5 bps)[cite: 1]
input int    MagicNumber       = 999018;

// --- GLOBALS
CTrade trade;
string binance_url;

int OnInit() {
   binance_url = "https://api.binance.com/api/v3/ticker/bookTicker?symbol=" + BinanceSymbol;
   trade.SetExpertMagicNumber(MagicNumber);
   
   Print("V18.1 ARB ONLINE: Monitoring Binance Lead for Lag on ", _Symbol);
   return(INIT_SUCCEEDED);
}

// --- DYNAMIC LOTS FOR EXPONENTIAL GROWTH[cite: 2]
double GetDynamicLot() {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   // Scale lot based on equity; for crypto, 0.01 per $1000 is a common starting point
   double lot = (equity / 1000.0) * (RiskPercent / 2.0) * 0.1; 
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   return NormalizeDouble(MathMax(minLot, MathMin(maxLot, lot)), 2);
}

void OnTick() {
   char post[], result[];
   string headers;
   // Small timeout (50ms) to ensure we stay in the "Lead" window[cite: 1]
   int res = WebRequest("GET", binance_url, NULL, NULL, 50, post, 0, result, headers);

   if(res == -1) {
      int err = GetLastError();
      if(err == 4014) Print("❌ WebRequest Error: Add api.binance.com to Tools -> Options -> Expert Advisors");
      return;
   }

   string response = CharArrayToString(result);
   
   // --- PARSE BINANCE (LEAD) PRICES[cite: 1]
   int ask_pos = StringFind(response, "\"askPrice\":\"");
   int bid_pos = StringFind(response, "\"bidPrice\":\"");
   if(ask_pos == -1 || bid_pos == -1) return;
   
   double b_ask = StringToDouble(StringSubstr(response, ask_pos + 12));
   double b_bid = StringToDouble(StringSubstr(response, bid_pos + 12));

   // --- GET MT5 (LAG) PRICES
   double m_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double m_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // Calculate Gap in Basis Points (BPS)[cite: 1]
   // Buy on MT5 if Binance Bid is higher than MT5 Ask + Fees
   double buy_gap_bps = (b_bid - m_ask) / m_ask * 10000;
   // Sell on MT5 if Binance Ask is lower than MT5 Bid - Fees
   double sell_gap_bps = (m_bid - b_ask) / b_ask * 10000;

   if(PositionsTotal() >= 1) return;

   // EXECUTE IF GAP COVERS MIN SPREAD + FEES[cite: 1]
   if(buy_gap_bps > (MinGap_BPS + Fee_BPS)) {
      double lot = GetDynamicLot();
      PrintFormat("🎯 LEAD-LAG BUY | Gap: %.2f bps | BinanceBid: %.2f | MT5Ask: %.2f", buy_gap_bps, b_bid, m_ask);
      trade.Buy(lot, _Symbol, m_ask, 0, 0, "Apex Arb Buy");
   }
   else if(sell_gap_bps > (MinGap_BPS + Fee_BPS)) {
      double lot = GetDynamicLot();
      PrintFormat("🎯 LEAD-LAG SELL | Gap: %.2f bps | BinanceAsk: %.2f | MT5Bid: %.2f", sell_gap_bps, b_ask, m_bid);
      trade.Sell(lot, _Symbol, m_bid, 0, 0, "Apex Arb Sell");
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
