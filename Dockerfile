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

#property copyright "Omni-Apex V21.0"
#property version   "21.00"
#property strict

// --- INPUTS (ultra loose)
input string BinanceSymbol     = "BTCUSDT";
input double RiskPercent       = 5.0;       // Position size = equity * RiskPercent / 1000
input int    MinGap_BPS        = 0;         // Open trade on ANY positive gap
input int    Fee_BPS           = 1;         // Almost ignore fees (1 bps = 0.01%)
input int    MaxOpenPositions  = 30;
input int    MagicNumber       = 999021;

// --- GLOBALS
CTrade trade;
string binance_url;
datetime last_debug_time = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
   binance_url = "https://api.binance.com/api/v3/ticker/bookTicker?symbol=" + BinanceSymbol;
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   // Ensure symbol is visible in Market Watch
   SymbolSelect(_Symbol, true);
   
   Print("==============================================");
   Print("🟢 EA V21.0 INITIALIZED (Ultra Loose + Debug)");
   Print("   Target Binance Symbol: ", BinanceSymbol);
   Print("   MT5 Symbol: ", _Symbol);
   Print("   MinGap_BPS: ", MinGap_BPS);
   Print("   Fee_BPS: ", Fee_BPS);
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   Print("🔴 EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Helper: Extract double from JSON string                          |
//+------------------------------------------------------------------+
double GetJsonDouble(string text, string key) {
   int pos = StringFind(text, key);
   if(pos == -1) return -1;
   int start = pos + StringLen(key);
   int end = StringFind(text, "\"", start);
   if(end == -1) end = StringFind(text, ",", start);
   if(end == -1) end = StringLen(text);
   string substr = StringSubstr(text, start, end - start);
   return StringToDouble(substr);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
   // --- 1. CLOSE ANY POSITION WITH POSITIVE PROFIT (FAST OUT) ---
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
         double profit = PositionGetDouble(POSITION_PROFIT);
         if(profit > 0.0) {
            if(trade.PositionClose(ticket)) {
               Print("✅ [CLOSE] Ticket ", ticket, " closed with profit: ", profit);
            } else {
               Print("❌ [CLOSE] Failed to close ticket ", ticket, ", error: ", GetLastError());
            }
         }
      }
   }
   
   // --- 2. CHECK MAX POSITIONS ---
   if(PositionsTotal() >= MaxOpenPositions) {
      static int throttle = 0;
      if(throttle++ % 100 == 0) Print("⚠️ Max positions reached: ", PositionsTotal());
      return;
   }
   
   // --- 3. GET MT5 PRICES ---
   double m_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double m_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double m_spread = (m_ask - m_bid) / m_bid * 10000.0;  // spread in bps
   
   if(m_ask <= 0 || m_bid <= 0) {
      Print("❌ MT5 price error: Ask=", m_ask, " Bid=", m_bid);
      return;
   }
   
   // --- 4. FETCH BINANCE PRICES (WebRequest) ---
   char post[], result[];
   string headers;
   // Increase timeout to 5 seconds
   int timeout = 5000;
   int res = WebRequest("GET", binance_url, NULL, NULL, timeout, post, 0, result, headers);
   
   if(res <= 0) {
      Print("❌ WebRequest failed. Error code: ", GetLastError(), " HTTP response: ", res);
      return;
   }
   
   string resp = CharArrayToString(result);
   // Binance returns JSON like: {"symbol":"BTCUSDT","bidPrice":"12345.67","askPrice":"12346.78",...}
   double b_bid = GetJsonDouble(resp, "\"bidPrice\":\"");
   double b_ask = GetJsonDouble(resp, "\"askPrice\":\"");
   
   if(b_bid <= 0 || b_ask <= 0) {
      Print("❌ Failed to parse Binance prices. Raw response (first 200 chars): ", StringSubstr(resp, 0, 200));
      return;
   }
   
   // --- 5. CALCULATE ARBITRAGE GAPS (in basis points) ---
   // Buy gap = (Binance bid - MT5 ask) / MT5 ask * 10000
   double buy_gap  = (b_bid - m_ask) / m_ask * 10000.0;
   // Sell gap = (MT5 bid - Binance ask) / Binance ask * 10000
   double sell_gap = (m_bid - b_ask) / b_ask * 10000.0;
   
   // Threshold = MinGap_BPS + Fee_BPS (here 0 + 1 = 1 bps)
   double threshold = MinGap_BPS + Fee_BPS;
   
   // --- 6. DEBUG OUTPUT (once every 5 seconds to avoid spam) ---
   if(TimeCurrent() - last_debug_time >= 5) {
      last_debug_time = TimeCurrent();
      Print("========================================");
      Print("📊 MT5  Ask: ", DoubleToString(m_ask, _Digits), "  Bid: ", DoubleToString(m_bid, _Digits));
      Print("📊 Binance Ask: ", DoubleToString(b_ask, _Digits), " Bid: ", DoubleToString(b_bid, _Digits));
      Print("📊 Spread (MT5): ", DoubleToString(m_spread, 2), " bps");
      Print("📊 Buy Gap: ", DoubleToString(buy_gap, 2), " bps  (Binance bid - MT5 ask)");
      Print("📊 Sell Gap: ", DoubleToString(sell_gap, 2), " bps  (MT5 bid - Binance ask)");
      Print("📊 Threshold: ", threshold, " bps");
      Print("========================================");
   }
   
   // --- 7. OPEN TRADES ON POSITIVE GAP ---
   // BUY: if Binance bid is higher than MT5 ask (buy on MT5, sell on Binance)
   if(buy_gap > threshold) {
      double lot = NormalizeDouble(AccountInfoDouble(ACCOUNT_EQUITY) / 1000.0 * (RiskPercent / 100.0), 2);
      lot = MathMax(0.01, lot);  // Minimum 0.01 lot
      if(trade.Buy(lot, _Symbol, m_ask, 0, 0, "Sonic BUY")) {
         Print("🔥 [BUY OPEN] Gap: ", buy_gap, " bps | Lot: ", lot, " | Price: ", m_ask);
      } else {
         Print("❌ [BUY FAIL] Error: ", GetLastError());
      }
   }
   // SELL: if MT5 bid is higher than Binance ask (sell on MT5, buy on Binance)
   else if(sell_gap > threshold) {
      double lot = NormalizeDouble(AccountInfoDouble(ACCOUNT_EQUITY) / 1000.0 * (RiskPercent / 100.0), 2);
      lot = MathMax(0.01, lot);
      if(trade.Sell(lot, _Symbol, m_bid, 0, 0, "Sonic SELL")) {
         Print("🔥 [SELL OPEN] Gap: ", sell_gap, " bps | Lot: ", lot, " | Price: ", m_bid);
      } else {
         Print("❌ [SELL FAIL] Error: ", GetLastError());
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
