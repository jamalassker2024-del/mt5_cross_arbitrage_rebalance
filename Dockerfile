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
//|                                      ECB_Arbitrage_Aggressor.mq5 |
//|                     Uses ECB official rates as lead data feed   |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>
#include <JSON.mqh>  // You'll need the JSON parser library

#property copyright "Omni-Apex ECB Arbitrage"
#property version   "4.00"
#property strict

// --- INPUTS --------------------------------------------------------+
input string   BaseCurrency           = "EUR";
input string   QuoteCurrency1         = "CHF";      // Primary arbitrage pair
input string   QuoteCurrency2         = "USD";      // Validation pair
input double   RiskPercent            = 3.0;        // % of equity per trade
input int      MinMispricingPoints    = 10;         // Minimum mispricing in points to trigger
input int      MaxOpenPositions       = 3;          // Concurrent trades limit
input int      MagicNumber            = 999888;
input double   MinProfitUSD           = 1.00;       // Minimum profit to close
input double   TrailingLockStep       = 0.15;       // Lock profit every $0.15 above min
input int      MaxConsecutiveLosses   = 3;          // Stop after N losses in a row
input double   MaxDailyLossPercent    = 8.0;        // Stop trading after -8% equity loss per day

// --- GLOBALS -------------------------------------------------------+
CTrade trade;
string ecb_url;
datetime last_debug = 0;
datetime last_trade_time = 0;
datetime dayStart = 0;
double dailyEquityStart = 0;
double dailyLoss = 0;
bool tradingEnabled = true;
int consecutiveLosses = 0;

// For profit trailing
ulong   lockTickets[];
double  lockValues[];

//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
int OnInit() {
   // ECB API endpoint: returns latest EUR/CHF and EUR/USD rates
   // This uses the official ECB Data Portal API – free, no API key required
   ecb_url = "https://data-api.ecb.europa.eu/service/data/EXR/D.CHF+USD.EUR.SP00.A?format=jsondata&lastNObservations=1";
   
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   SymbolSelect(_Symbol, true);
   dayStart = TimeCurrent();
   dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
   
   Print("==============================================");
   Print("🏦 ECB ARBITRAGE AGRESSOR - OFFICIAL RATES");
   Print("   Pair: ", BaseCurrency, "/", QuoteCurrency1);
   Print("   ECB API: ", ecb_url);
   Print("   MinMispricing: ", MinMispricingPoints, " pts | MinProfit: $", MinProfitUSD);
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Fetch ECB exchange rates (official, daily at ~16:00 CET)        |
//| Returns true and fills passed references                        |
//+------------------------------------------------------------------+
bool FetchECBRates(double &ecb_chf_rate, double &ecb_usd_rate) {
   char post[], result[];
   string headers;
   int res = WebRequest("GET", ecb_url, NULL, NULL, 10000, post, 0, result, headers);
   if (res <= 0) {
      static int failCount = 0;
      if (failCount++ % 50 == 0) Print("❌ ECB WebRequest failed. Error: ", GetLastError());
      return false;
   }
   
   string response = CharArrayToString(result);
   
   // Parse JSON to extract the latest observation values
   // The response structure contains dataSets -> series -> observations
   // This is a simplified parser; for production, use a full JSON library
   
   int chfPos = StringFind(response, "\"0:0:0:0:0\":{\"0\":");
   int usdPos = StringFind(response, "\"0:0:0:0:1\":{\"0\":");
   
   if (chfPos < 0 || usdPos < 0) {
      Print("❌ Failed to parse ECB response. Retrying next tick.");
      return false;
   }
   
   // Extract CHF rate
   int chfValStart = StringFind(response, ":", chfPos) + 1;
   int chfValEnd   = StringFind(response, ",", chfValStart);
   string chfStr = StringSubstr(response, chfValStart, chfValEnd - chfValStart);
   ecb_chf_rate = StringToDouble(chfStr);
   
   // Extract USD rate
   int usdValStart = StringFind(response, ":", usdPos) + 1;
   int usdValEnd   = StringFind(response, "}", usdValStart);
   string usdStr = StringSubstr(response, usdValStart, usdValEnd - usdValStart);
   ecb_usd_rate = StringToDouble(usdStr);
   
   return (ecb_chf_rate > 0 && ecb_usd_rate > 0);
}

//+------------------------------------------------------------------+
//| Helper for trailing profit management                            |
//+------------------------------------------------------------------+
int FindLockIndex(ulong ticket) {
   for (int i = 0; i < ArraySize(lockTickets); i++)
      if (lockTickets[i] == ticket) return i;
   return -1;
}

void RemoveLock(int idx) {
   int sz = ArraySize(lockTickets);
   for (int i = idx; i < sz - 1; i++) {
      lockTickets[i] = lockTickets[i+1];
      lockValues[i] = lockValues[i+1];
   }
   ArrayResize(lockTickets, sz - 1);
   ArrayResize(lockValues, sz - 1);
}

void AddLock(ulong ticket, double lockValue) {
   int sz = ArraySize(lockTickets);
   ArrayResize(lockTickets, sz + 1);
   ArrayResize(lockValues, sz + 1);
   lockTickets[sz] = ticket;
   lockValues[sz] = lockValue;
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
   // --- DAILY LOSS RESET ---
   if (TimeCurrent() - dayStart >= 86400) {
      dayStart = TimeCurrent();
      dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
      tradingEnabled = true;
      Print("✅ New trading day. Loss counter reset.");
   }
   
   // --- DAILY LOSS CHECK ---
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPercent = (dailyEquityStart - equity) / dailyEquityStart * 100.0;
   if (lossPercent >= MaxDailyLossPercent) {
      if (tradingEnabled) {
         Print("🚨 Daily loss limit reached (", lossPercent, "%). Trading disabled.");
         tradingEnabled = false;
      }
      return;
   } else if (!tradingEnabled && lossPercent < MaxDailyLossPercent - 2) {
      tradingEnabled = true;
      Print("✅ Daily loss recovered. Trading re-enabled.");
   }
   if (!tradingEnabled) return;
   
   // --- CLOSE POSITIONS WITH TRAILING PROFIT LOCK ---
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if (!PositionSelectByTicket(ticket)) continue;
      if (PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      double profit = PositionGetDouble(POSITION_PROFIT);
      int lockIdx = FindLockIndex(ticket);
      
      if (lockIdx == -1 && profit >= MinProfitUSD) {
         AddLock(ticket, profit - TrailingLockStep);
         Print("🔒 Trailing lock set at $", profit - TrailingLockStep, " for ticket ", ticket);
      }
      else if (lockIdx != -1) {
         if (profit > lockValues[lockIdx] + TrailingLockStep) {
            lockValues[lockIdx] = profit - TrailingLockStep;
            Print("🔓 Trail lock raised to $", lockValues[lockIdx]);
         }
         if (profit <= lockValues[lockIdx]) {
            if (trade.PositionClose(ticket)) {
               Print("✅ [CLOSE] Ticket ", ticket, " profit: $", profit);
               if (profit < 0) consecutiveLosses++;
               else {
                  consecutiveLosses = 0;
                  Print("🏆 Consecutive wins reset.");
               }
            } else Print("❌ [CLOSE FAIL] error ", GetLastError());
            RemoveLock(lockIdx);
         }
      }
   }
   
   // --- STOP IF TOO MANY LOSSES ---
   if (consecutiveLosses >= MaxConsecutiveLosses) {
      static int warn = 0;
      if (warn++ % 50 == 0) Print("⚠️ ", consecutiveLosses, " consecutive losses. EA paused.");
      return;
   }
   
   // --- POSITION LIMIT & COOLDOWN ---
   if (PositionsTotal() >= MaxOpenPositions) return;
   if (TimeCurrent() - last_trade_time < 5) return;
   
   // --- FETCH ECB RATES (Lead Data) ---
   double ecb_chf, ecb_usd;
   if (!FetchECBRates(ecb_chf, ecb_usd)) {
      static int wait = 0;
      if (wait++ % 100 == 0) Print("⏳ Waiting for ECB data...");
      return;
   }
   
   // --- GET MT5 BROKER PRICES (Lag Data) ---
   string brokerSymbol = BaseCurrency + QuoteCurrency1;  // e.g., "EURCHF"
   double mt5_ask = SymbolInfoDouble(brokerSymbol, SYMBOL_ASK);
   double mt5_bid = SymbolInfoDouble(brokerSymbol, SYMBOL_BID);
   if (mt5_ask <= 0 || mt5_bid <= 0) {
      Print("❌ MT5 price error for ", brokerSymbol);
      return;
   }
   double mt5_mid = (mt5_ask + mt5_bid) / 2.0;
   
   // --- CALCULATE MISPRICING ---
   // Mispricing = ECB rate (lead) - MT5 rate (lag) in points
   double point = SymbolInfoDouble(brokerSymbol, SYMBOL_POINT);
   double mispricing_points = (ecb_chf - mt5_mid) / point;
   
   // --- ADDITIONAL VALIDATION: Check EUR/USD direction ---
   // If EUR/USD is also showing directional divergence, confirms the mispricing
   double mt5_eurusd_mid = (SymbolInfoDouble("EURUSD", SYMBOL_ASK) + SymbolInfoDouble("EURUSD", SYMBOL_BID)) / 2.0;
   double usdchf_synthetic = ecb_usd * mt5_eurusd_mid;  // Synthetic USD/CHF for validation
   bool eur_direction_aligns = (ecb_usd > mt5_eurusd_mid) == (mispricing_points > 0);
   
   // --- GENERATE SIGNAL (only if validation confirms) ---
   bool buy_signal  = (mispricing_points > MinMispricingPoints) && eur_direction_aligns;
   bool sell_signal = (mispricing_points < -MinMispricingPoints) && eur_direction_aligns;
   
   // --- DEBUG OUTPUT (every 10 seconds) ---
   if (TimeCurrent() - last_debug >= 10) {
      last_debug = TimeCurrent();
      Print("========================================");
      Print("🏦 ECB Lead: EUR/", QuoteCurrency1, " = ", DoubleToString(ecb_chf, 5));
      Print("📊 MT5 Lag:  EUR/", QuoteCurrency1, " = ", DoubleToString(mt5_mid, 5));
      Print("📉 Mispricing: ", DoubleToString(mispricing_points, 2), " points");
      Print("📊 EUR/USD ECB: ", ecb_usd, " | MT5: ", mt5_eurusd_mid);
      Print("🔍 Signal: ", buy_signal ? "BUY" : (sell_signal ? "SELL" : "HOLD"));
      Print("📊 Daily Loss: $", DoubleToString(dailyLoss, 2), " (", DoubleToString(lossPercent,1), "%)");
      Print("========================================");
   }
   
   if (!buy_signal && !sell_signal) return;
   
   // --- POSITION SIZING (Dynamic compounding on wins) ---
   double baseLot = NormalizeDouble(equity / 1000.0 * (RiskPercent / 100.0), 2);
   baseLot = MathMax(0.01, baseLot);
   double lot = baseLot * MathPow(1.3, MathMin(consecutiveLosses, 8));  // Compounding increases after losses
   lot = MathMin(lot, SymbolInfoDouble(brokerSymbol, SYMBOL_VOLUME_MAX));
   
   // --- EXECUTE TRADE ---
   bool executed = false;
   if (buy_signal) {
      executed = trade.Buy(lot, brokerSymbol, mt5_ask, 0, 0, "ECB Arbitrage Buy");
      if (executed) Print("🔥 [BUY] Mispricing: ", mispricing_points, " pts | Lot: ", lot);
   }
   else if (sell_signal) {
      executed = trade.Sell(lot, brokerSymbol, mt5_bid, 0, 0, "ECB Arbitrage Sell");
      if (executed) Print("🔥 [SELL] Mispricing: ", mispricing_points, " pts | Lot: ", lot);
   }
   
   if (executed) {
      last_trade_time = TimeCurrent();
   } else {
      Print("❌ Order failed. Error: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   Print("🏦 ECB Arbitrage EA stopped. Daily loss: $", dailyLoss);
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
