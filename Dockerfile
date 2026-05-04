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
//|                                    TrendFilteredArbitrageV26.mq5|
//|                     Fixed iMA + more aggressive entry           |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property copyright "Omni-Apex V26.0"
#property version   "26.00"
#property strict

// --- INPUTS (adjust for your asset) ----------------------------------+
input string BinanceSymbol               = "ETHUSDT";
input double RiskPercent                 = 2.0;          // % equity per trade
input int    MAPeriod                    = 200;          // EMA period for trend
input ENUM_TIMEFRAMES TrendTF            = PERIOD_H1;    // Trend timeframe
input double MinGapPoints                = 50;           // Minimum price difference in points (no ATR)
input int    MaxOpenPositions            = 2;
input int    MagicNumber                 = 999026;
input int    TradeCooldownSeconds        = 5;

// --- GLOBALS -------------------------------------------------------+
CTrade trade;
string binance_url;
datetime last_debug = 0;
datetime last_trade = 0;
int ma_handle;
double ma_buffer[];

//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
int OnInit() {
   binance_url = "https://api.binance.com/api/v3/ticker/bookTicker?symbol=" + BinanceSymbol;
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   SymbolSelect(_Symbol, true);
   
   // Create MA handle (correct way)
   ma_handle = iMA(_Symbol, TrendTF, MAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(ma_handle == INVALID_HANDLE) {
      Print("Failed to create MA handle, error: ", GetLastError());
      return INIT_FAILED;
   }
   ArraySetAsSeries(ma_buffer, true);
   
   Print("==============================================");
   Print("🟢 TREND-FILTERED ARBITRAGE V26");
   Print("   Binance: ", BinanceSymbol, " | MT5: ", _Symbol);
   Print("   Trend EMA(", MAPeriod, ") on ", EnumToString(TrendTF));
   Print("   Min gap: ", MinGapPoints, " points");
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Get current trend (1=up, -1=down, 0=flat/bad data)             |
//+------------------------------------------------------------------+
int GetTrend() {
   if(CopyBuffer(ma_handle, 0, 0, 1, ma_buffer) < 1) return 0;
   double ma_value = ma_buffer[0];
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(price > ma_value) return 1;
   if(price < ma_value) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| Get Binance mid price                                           |
//+------------------------------------------------------------------+
double GetBinanceMid() {
   char post[], result[];
   string headers;
   int res = WebRequest("GET", binance_url, NULL, NULL, 5000, post, 0, result, headers);
   if(res <= 0) return -1;
   string resp = CharArrayToString(result);
   
   // Parse JSON manually
   int bidPos = StringFind(resp, "\"bidPrice\":\"");
   int askPos = StringFind(resp, "\"askPrice\":\"");
   if(bidPos < 0 || askPos < 0) return -1;
   
   int bidStart = bidPos + 11;
   int bidEnd = StringFind(resp, "\"", bidStart);
   double bid = StringToDouble(StringSubstr(resp, bidStart, bidEnd - bidStart));
   
   int askStart = askPos + 11;
   int askEnd = StringFind(resp, "\"", askStart);
   double ask = StringToDouble(StringSubstr(resp, askStart, askEnd - askStart));
   
   return (ask + bid) / 2.0;
}

//+------------------------------------------------------------------+
//| Expert tick function                                            |
//+------------------------------------------------------------------+
void OnTick() {
   // 1. Close profitable positions immediately
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
         double profit = PositionGetDouble(POSITION_PROFIT);
         if(profit > 0.0) {
            if(trade.PositionClose(ticket))
               Print("✅ [CLOSE] Ticket ", ticket, " profit: ", profit);
         }
      }
   }
   
   // 2. Limits
   if(PositionsTotal() >= MaxOpenPositions) return;
   if(TimeCurrent() - last_trade < TradeCooldownSeconds) return;
   
   // 3. Get MT5 prices
   double mt5_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mt5_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(mt5_ask <= 0 || mt5_bid <= 0) return;
   double mt5_mid = (mt5_ask + mt5_bid) / 2.0;
   
   // 4. Get Binance mid
   double binance_mid = GetBinanceMid();
   if(binance_mid <= 0) return;
   
   // 5. Difference in points
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double diff_pts = (binance_mid - mt5_mid) / point;
   
   // 6. Get trend
   int trend = GetTrend();
   
   // 7. Debug every 10 seconds
   if(TimeCurrent() - last_debug >= 10) {
      last_debug = TimeCurrent();
      Print("========================================");
      Print("📊 MT5 Mid: ", DoubleToString(mt5_mid, _Digits));
      Print("📊 Binance Mid: ", DoubleToString(binance_mid, _Digits));
      Print("📊 Diff: ", DoubleToString(diff_pts, 0), " pts");
      Print("📊 Trend: ", trend == 1 ? "UP" : (trend == -1 ? "DOWN" : "UNKNOWN"));
      Print("📊 Min gap required: ", MinGapPoints);
      Print("========================================");
   }
   
   // 8. Signal: trend aligned + difference exceeds threshold
   bool buy_signal = (trend == 1) && (diff_pts > MinGapPoints);
   bool sell_signal = (trend == -1) && (diff_pts < -MinGapPoints);
   
   if(!buy_signal && !sell_signal) return;
   
   // 9. Position sizing
   double lot = NormalizeDouble(AccountInfoDouble(ACCOUNT_EQUITY) / 1000.0 * (RiskPercent / 100.0), 2);
   lot = MathMax(0.01, lot);
   lot = MathMin(lot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX));
   
   // 10. Execute (no stop loss)
   if(buy_signal) {
      if(trade.Buy(lot, _Symbol, mt5_ask, 0, 0, "Trend Buy")) {
         Print("🔥 [BUY] Diff: ", diff_pts, " pts | Lot: ", lot);
         last_trade = TimeCurrent();
      } else {
         Print("❌ [BUY FAIL] Error: ", GetLastError());
      }
   }
   else if(sell_signal) {
      if(trade.Sell(lot, _Symbol, mt5_bid, 0, 0, "Trend Sell")) {
         Print("🔥 [SELL] Diff: ", diff_pts, " pts | Lot: ", lot);
         last_trade = TimeCurrent();
      } else {
         Print("❌ [SELL FAIL] Error: ", GetLastError());
      }
   }
}

//+------------------------------------------------------------------+
//| Cleanup                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   IndicatorRelease(ma_handle);
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
