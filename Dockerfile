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
//|                     + London session filter (8-22)             |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property copyright "Omni-Apex ECB Arbitrage"
#property version   "5.00"
#property strict

// --- INPUTS --------------------------------------------------------+
input string   BaseCurrency           = "EUR";
input string   QuoteCurrency1         = "CHF";      // Primary arbitrage pair
input string   QuoteCurrency2         = "USD";      // Validation pair
input double   RiskPercent            = 3.0;        // % of equity per trade
input int      MinMispricingPoints    = 10;         // Minimum mispricing in points
input int      MaxOpenPositions       = 3;
input int      MagicNumber            = 999888;
input double   MinProfitUSD           = 1.00;
input double   TrailingLockStep       = 0.15;
input int      MaxConsecutiveLosses   = 3;
input double   MaxDailyLossPercent    = 8.0;
input int      StartHour              = 8;          // London session start (server time)
input int      EndHour                = 22;         // Session end – close all at this hour

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

ulong   lockTickets[];
double  lockValues[];

//+------------------------------------------------------------------+
//| Check if we are inside trading hours (server time)              |
//+------------------------------------------------------------------+
bool IsTradingTime() {
   int hour = TimeHour(TimeCurrent());
   return (hour >= StartHour && hour < EndHour);
}

//+------------------------------------------------------------------+
//| Close all positions (at session end)                            |
//+------------------------------------------------------------------+
void CloseAllPositions() {
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
         trade.PositionClose(ticket);
         Print("🕒 [SESSION END] Closed position ", ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Fetch ECB exchange rates using a more reliable endpoint         |
//| Returns true and fills ecb_chf_rate, ecb_usd_rate               |
//+------------------------------------------------------------------+
bool FetchECBRates(double &ecb_chf_rate, double &ecb_usd_rate) {
   // Alternative endpoint that returns the latest available observation
   // The previous URL sometimes returned only header. This one uses the generic series key.
   string url = "https://data-api.ecb.europa.eu/service/data/EXR/D.CHF.EUR.SP00.A?format=jsondata&lastNObservations=1";
   
   char post[], result[];
   string headers;
   int res = WebRequest("GET", url, NULL, NULL, 10000, post, 0, result, headers);
   if (res <= 0) {
      static int failCount = 0;
      if (failCount++ % 50 == 0) Print("❌ ECB WebRequest failed. Error: ", GetLastError());
      return false;
   }
   
   string response = CharArrayToString(result);
   
   // Parse the CHF rate: look for "value" under observations
   // The structure is: ... "observations":{"0":{"0":[value]}} ...
   int obsPos = StringFind(response, "\"observations\"");
   if (obsPos == -1) {
      static int parseFail = 0;
      if (parseFail++ % 20 == 0) Print("❌ No observations in ECB response. Raw: ", StringSubstr(response, 0, 300));
      return false;
   }
   
   // Find the first numeric value after "0":
   int valPos = StringFind(response, "\"0\":", obsPos);
   if (valPos == -1) return false;
   valPos = StringFind(response, "[", valPos);
   if (valPos == -1) return false;
   int start = valPos + 1;
   while (start < StringLen(response) && (StringSubstr(response, start, 1) == " " || 
          StringSubstr(response, start, 1) == "\"" || 
          StringSubstr(response, start, 1) == "[")) start++;
   int end = start;
   while (end < StringLen(response) && (StringSubstr(response, end, 1) >= "0" && 
          StringSubstr(response, end, 1) <= "9") || StringSubstr(response, end, 1) == ".") end++;
   if (end <= start) return false;
   string chfStr = StringSubstr(response, start, end - start);
   ecb_chf_rate = StringToDouble(chfStr);
   
   // Now fetch USD rate similarly
   url = "https://data-api.ecb.europa.eu/service/data/EXR/D.USD.EUR.SP00.A?format=jsondata&lastNObservations=1";
   res = WebRequest("GET", url, NULL, NULL, 10000, post, 0, result, headers);
   if (res <= 0) return false;
   response = CharArrayToString(result);
   obsPos = StringFind(response, "\"observations\"");
   if (obsPos == -1) return false;
   valPos = StringFind(response, "\"0\":", obsPos);
   if (valPos == -1) return false;
   valPos = StringFind(response, "[", valPos);
   if (valPos == -1) return false;
   start = valPos + 1;
   while (start < StringLen(response) && (StringSubstr(response, start, 1) == " " || 
          StringSubstr(response, start, 1) == "\"" || 
          StringSubstr(response, start, 1) == "[")) start++;
   end = start;
   while (end < StringLen(response) && (StringSubstr(response, end, 1) >= "0" && 
          StringSubstr(response, end, 1) <= "9") || StringSubstr(response, end, 1) == ".") end++;
   if (end <= start) return false;
   string usdStr = StringSubstr(response, start, end - start);
   ecb_usd_rate = StringToDouble(usdStr);
   
   return (ecb_chf_rate > 0 && ecb_usd_rate > 0);
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
   Print("🏦 ECB ARBITRAGE EA - SESSION FILTER v5.0");
   Print("   Pair: ", BaseCurrency, "/", QuoteCurrency1);
   Print("   Trading hours: ", StartHour, ":00 - ", EndHour, ":00 (server time)");
   Print("   MinMispricing: ", MinMispricingPoints, " pts | MinProfit: $", MinProfitUSD);
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Trailing lock helpers                                            |
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
   // --- SESSION FILTER: close all at EndHour, no trading outside hours
   if(!IsTradingTime()) {
      CloseAllPositions();
      return;
   }
   
   // Daily reset and loss limit
   if (TimeCurrent() - dayStart >= 86400) {
      dayStart = TimeCurrent();
      dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
      tradingEnabled = true;
      Print("✅ New trading day.");
   }
   
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
   }
   if (!tradingEnabled) return;
   
   // Close positions with trailing profit lock
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if (!PositionSelectByTicket(ticket)) continue;
      if (PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      double profit = PositionGetDouble(POSITION_PROFIT);
      int lockIdx = FindLockIndex(ticket);
      
      if (lockIdx == -1 && profit >= MinProfitUSD) {
         AddLock(ticket, profit - TrailingLockStep);
         Print("🔒 Trailing lock set at $", profit - TrailingLockStep);
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
               else consecutiveLosses = 0;
            }
            RemoveLock(lockIdx);
         }
      }
   }
   
   if (consecutiveLosses >= MaxConsecutiveLosses) {
      static int warn = 0;
      if (warn++ % 50 == 0) Print("⚠️ ", consecutiveLosses, " consecutive losses. Paused.");
      return;
   }
   
   if (PositionsTotal() >= MaxOpenPositions) return;
   if (TimeCurrent() - last_trade_time < 5) return;
   
   double ecb_chf, ecb_usd;
   if (!FetchECBRates(ecb_chf, ecb_usd)) return;
   
   string brokerSymbol = BaseCurrency + QuoteCurrency1; // e.g., "EURCHF"
   double mt5_ask = SymbolInfoDouble(brokerSymbol, SYMBOL_ASK);
   double mt5_bid = SymbolInfoDouble(brokerSymbol, SYMBOL_BID);
   if (mt5_ask <= 0 || mt5_bid <= 0) {
      Print("❌ MT5 price error for ", brokerSymbol);
      return;
   }
   double mt5_mid = (mt5_ask + mt5_bid) / 2.0;
   
   double point = SymbolInfoDouble(brokerSymbol, SYMBOL_POINT);
   double mispricing_points = (ecb_chf - mt5_mid) / point;
   
   double mt5_eurusd_mid = (SymbolInfoDouble("EURUSD", SYMBOL_ASK) + SymbolInfoDouble("EURUSD", SYMBOL_BID)) / 2.0;
   bool eur_direction_aligns = (ecb_usd > mt5_eurusd_mid) == (mispricing_points > 0);
   
   bool buy_signal  = (mispricing_points > MinMispricingPoints) && eur_direction_aligns;
   bool sell_signal = (mispricing_points < -MinMispricingPoints) && eur_direction_aligns;
   
   if (TimeCurrent() - last_debug >= 10) {
      last_debug = TimeCurrent();
      Print("========================================");
      Print("🏦 ECB Lead: EUR/", QuoteCurrency1, " = ", DoubleToString(ecb_chf, 5));
      Print("📊 MT5 Lag:  EUR/", QuoteCurrency1, " = ", DoubleToString(mt5_mid, 5));
      Print("📉 Mispricing: ", DoubleToString(mispricing_points, 2), " points");
      Print("🔍 Signal: ", buy_signal ? "BUY" : (sell_signal ? "SELL" : "HOLD"));
      Print("========================================");
   }
   
   if (!buy_signal && !sell_signal) return;
   
   double baseLot = NormalizeDouble(equity / 1000.0 * (RiskPercent / 100.0), 2);
   baseLot = MathMax(0.01, baseLot);
   double lot = baseLot * MathPow(1.3, MathMin(consecutiveLosses, 8));
   lot = MathMin(lot, SymbolInfoDouble(brokerSymbol, SYMBOL_VOLUME_MAX));
   
   bool executed = false;
   if (buy_signal) {
      executed = trade.Buy(lot, brokerSymbol, mt5_ask, 0, 0, "ECB Arb Buy");
      if (executed) Print("🔥 [BUY] Mispricing: ", mispricing_points, " pts | Lot: ", lot);
   } else if (sell_signal) {
      executed = trade.Sell(lot, brokerSymbol, mt5_bid, 0, 0, "ECB Arb Sell");
      if (executed) Print("🔥 [SELL] Mispricing: ", mispricing_points, " pts | Lot: ", lot);
   }
   
   if (executed) last_trade_time = TimeCurrent();
   else Print("❌ Order failed. Error: ", GetLastError());
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   Print("🏦 ECB Arbitrage EA stopped.");
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
