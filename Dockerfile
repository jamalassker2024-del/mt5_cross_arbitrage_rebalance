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
الروبوت الرابح


#include <Trade\Trade.mqh>

#property copyright "Omni-Apex V22.0"
#property version   "22.00"
#property strict

// --- INPUTS (ultra loose)
input string BinanceSymbol     = "BTCUSDT";
input double RiskPercent       = 1.0;       // % of equity per trade
input int    MinDiff_Points    = 0;         // Any price difference triggers trade
input int    MaxOpenPositions  = 5;
input int    MagicNumber       = 999022;

// --- GLOBALS
CTrade trade;
string binance_url;
datetime last_debug_time = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
int OnInit() {
   binance_url = "https://api.binance.com/api/v3/ticker/bookTicker?symbol=" + BinanceSymbol;
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   SymbolSelect(_Symbol, true);
   
   Print("==============================================");
   Print("🟢 EA V22.0 - FORCE TRADE ON ANY PRICE DIFFERENCE");
   Print("   Binance Symbol: ", BinanceSymbol);
   Print("   MT5 Symbol: ", _Symbol);
   Print("   MinDiff_Points: ", MinDiff_Points, " (any difference > 0 opens trade)");
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Helper: Extract double from JSON                                 |
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
               Print("❌ [CLOSE] Failed, error: ", GetLastError());
            }
         }
      }
   }
   
   // --- 2. POSITION LIMIT ---
   if(PositionsTotal() >= MaxOpenPositions) {
      static int throttle = 0;
      if(throttle++ % 100 == 0) Print("⚠️ Max positions reached: ", PositionsTotal());
      return;
   }
   
   // --- 3. GET MT5 PRICES ---
   double mt5_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mt5_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(mt5_ask <= 0 || mt5_bid <= 0) {
      Print("❌ MT5 price error");
      return;
   }
   double mt5_mid = (mt5_ask + mt5_bid) / 2.0;
   
   // --- 4. FETCH BINANCE PRICES ---
   char post[], result[];
   string headers;
   int res = WebRequest("GET", binance_url, NULL, NULL, 5000, post, 0, result, headers);
   if(res <= 0) {
      Print("❌ WebRequest failed. Error: ", GetLastError());
      return;
   }
   
   string resp = CharArrayToString(result);
   double binance_bid = GetJsonDouble(resp, "\"bidPrice\":\"");
   double binance_ask = GetJsonDouble(resp, "\"askPrice\":\"");
   if(binance_bid <= 0 || binance_ask <= 0) {
      Print("❌ Binance parse error. Response: ", StringSubstr(resp, 0, 200));
      return;
   }
   double binance_mid = (binance_ask + binance_bid) / 2.0;
   
   // --- 5. CALCULATE DIFFERENCE (in points) ---
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double diff_points = (binance_mid - mt5_mid) / point;
   bool buy_signal = (diff_points > MinDiff_Points);
   bool sell_signal = (diff_points < -MinDiff_Points);
   
   // --- 6. DEBUG OUTPUT (every 5 seconds) ---
   if(TimeCurrent() - last_debug_time >= 5) {
      last_debug_time = TimeCurrent();
      Print("========================================");
      Print("📊 MT5   Ask: ", DoubleToString(mt5_ask, _Digits), "  Bid: ", DoubleToString(mt5_bid, _Digits));
      Print("📊 Binance Ask: ", DoubleToString(binance_ask, _Digits), " Bid: ", DoubleToString(binance_bid, _Digits));
      Print("📊 MT5 Mid: ", DoubleToString(mt5_mid, _Digits));
      Print("📊 Binance Mid: ", DoubleToString(binance_mid, _Digits));
      Print("📊 Difference: ", DoubleToString(diff_points, 2), " points");
      Print("📊 Buy signal: ", buy_signal ? "YES" : "NO", " | Sell signal: ", sell_signal ? "YES" : "NO");
      Print("========================================");
   }
   
   // --- 7. OPEN TRADE ON ANY DIFFERENCE ---
   double lot = NormalizeDouble(AccountInfoDouble(ACCOUNT_EQUITY) / 1000.0 * (RiskPercent / 100.0), 2);
   lot = MathMax(0.01, lot);
   
   if(buy_signal) {
      if(trade.Buy(lot, _Symbol, mt5_ask, 0, 0, "Force Buy")) {
         Print("🔥 [BUY OPEN] Diff: ", diff_points, " points | Lot: ", lot, " @ ", mt5_ask);
      } else {
         Print("❌ [BUY FAIL] Error: ", GetLastError());
      }
   }
   else if(sell_signal) {
      if(trade.Sell(lot, _Symbol, mt5_bid, 0, 0, "Force Sell")) {
         Print("🔥 [SELL OPEN] Diff: ", diff_points, " points | Lot: ", lot, " @ ", mt5_bid);
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
