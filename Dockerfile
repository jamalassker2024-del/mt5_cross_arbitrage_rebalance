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
//|                                            SMC_Scalper.mq5       |
//|                          Smart Money Concepts Scalper for GOLD   |
//|                              High Probability Entries on M1      |
//+------------------------------------------------------------------+
#property copyright "SMC Scalper"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Math\Stat\Math.mqh> // For ATR-based volatility filter

// --- Inputs (Configurable for your $10 cent account) ---
input string   t1 = "==== Strategy Selection ====";
input bool     ActivateOrderBlock     = true;   // Trade Order Blocks (High Win Rate)
input bool     ActivateFairValueGap   = true;   // Trade Fair Value Gaps (High Win Rate)
input bool     ActivateLiquiditySweep = true;   // Trade Liquidity Sweeps (High Win Rate)

input string   t2 = "==== Money Management ====";
input double   RiskPercent            = 12.0;   // Risk per trade (% of equity)
input ENUM_LOT_MODE LotMode           = LOT_CENTS; // 0.01 per $10 balance for cent accounts
input int      StopLossPoints         = 150;    // Stop Loss (15 pips)
input int      TakeProfitPoints       = 200;    // Take Profit (20 pips)
input int      MaxConcurrentTrades    = 2;      // Max positions at once
input int      MagicNumber            = 887766;

input string   t3 = "==== Filters / Daily Limits ====";
input double   MaxDailyProfitUSD      = 5.0;    // Stop after $5 profit (500 cents)
input double   MaxDailyLossUSD        = 1.0;    // Stop after $1 loss (100 cents)
input int      MinATRPoints           = 50;     // Minimum volatility filter (5 pips)
input int      MaxSpreadPoints        = 25;     // Max spread (2.5 pips)

// --- Globals ---
CTrade trade;
int      rsi_handle, atr_handle;
double   rsi_buf[], atr_buf[];
datetime lastBarTime = 0;
double   dailyProfit = 0.0;
double   startBalance = 0.0;
bool     tradingHalted = false;
datetime lastTradeTime = 0;
int      consecutiveLosses = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   startBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   // Create indicators
   rsi_handle = iRSI(_Symbol, PERIOD_M1, 7, PRICE_CLOSE);
   atr_handle = iATR(_Symbol, PERIOD_M1, 14);
   
   if(rsi_handle == INVALID_HANDLE || atr_handle == INVALID_HANDLE) {
      Print("Error creating indicators");
      return INIT_FAILED;
   }
   
   ArraySetAsSeries(rsi_buf, true);
   ArraySetAsSeries(atr_buf, true);
   
   Print("==================================================");
   Print("✅ SMC SCALPER ACTIVATED for $10 Cent Account");
   Print("   Strategies: OB=", ActivateOrderBlock, " FVG=", ActivateFairValueGap, " LS=", ActivateLiquiditySweep);
   Print("   Target: $5/day | Risk: ", RiskPercent, "% of balance per trade");
   Print("==================================================");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinitialization function                                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   IndicatorRelease(rsi_handle);
   IndicatorRelease(atr_handle);
   Print("EA Stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Tick function (Main logic for all strategies)                    |
//+------------------------------------------------------------------+
void OnTick() {
   // --- Daily Limits Check (Protects your capital) ---
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyProfit = currentBalance - startBalance;
   
   if(dailyProfit >= MaxDailyProfitUSD) {
      if(!tradingHalted) Print("🎯 Daily target of $", MaxDailyProfitUSD, " reached. Trading halted.");
      tradingHalted = true;
      return;
   }
   if(dailyProfit <= -MaxDailyLossUSD) {
      if(!tradingHalted) Print("💀 Max daily loss of $", MaxDailyLossUSD, " hit. Trading halted.");
      tradingHalted = true;
      return;
   }
   if(tradingHalted) {
      static datetime lastReset = 0;
      datetime now = TimeCurrent();
      MqlDateTime dt;
      TimeToStruct(now, dt);
      dt.hour = 0; dt.min = 0; dt.sec = 0;
      datetime midnight = StructToTime(dt);
      if(midnight != lastReset) {
         lastReset = midnight;
         tradingHalted = false;
         startBalance = currentBalance;
         Print("🔄 New trading day - Resuming");
      }
      return;
   }
   
   // --- Filters (Spread, Volatility) ---
   int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpreadPoints) return;
   
   CopyBuffer(atr_handle, 0, 0, 2, atr_buf);
   double atrPoints = atr_buf[0] / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(atrPoints < MinATRPoints) return;
   
   // --- Count Open Positions ---
   int posCount = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         posCount++;
   }
   if(posCount >= MaxConcurrentTrades) return;
   
   // --- Cooldown: prevent overtrading ---
   if(TimeCurrent() - lastTradeTime < 15) return;
   
   // === 1. ORDER BLOCK STRATEGY ===
   if(ActivateOrderBlock) {
      int limit = 30;
      double high[], low[], close[], open[];
      ArraySetAsSeries(high, true);
      ArraySetAsSeries(low, true);
      ArraySetAsSeries(close, true);
      ArraySetAsSeries(open, true);
      
      CopyHigh(_Symbol, PERIOD_M1, 0, limit, high);
      CopyLow(_Symbol, PERIOD_M1, 0, limit, low);
      CopyClose(_Symbol, PERIOD_M1, 0, limit, close);
      CopyOpen(_Symbol, PERIOD_M1, 0, limit, open);
      
      // Bullish OB detection
      for(int i=2; i<limit-3; i++) {
         if(close[i] > open[i] && close[i+1] < open[i+1] && high[i] < high[i-1] && close[i] > close[i+1]) {
            double obHigh = high[i+1];
            double entryPrice = obHigh + 2 * _Point;
            double sl = entryPrice - StopLossPoints * _Point;
            double tp = entryPrice + TakeProfitPoints * _Point;
            entryPrice = NormalizeDouble(entryPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
            sl = NormalizeDouble(sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
            tp = NormalizeDouble(tp, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
            double lot = CalculateLotSize();
            if(trade.Buy(lot, _Symbol, entryPrice, sl, tp, "OB Buy")) {
               Print("🔥 BUY ORDER BLOCK TRIGGERED | Price=", entryPrice, " | Lot=", lot);
               lastTradeTime = TimeCurrent();
               return;
            }
         }
      }
      
      // Bearish OB detection
      for(int i=2; i<limit-3; i++) {
         if(close[i] < open[i] && close[i+1] > open[i+1] && low[i] > low[i-1] && close[i] < close[i+1]) {
            double obLow = low[i+1];
            double entryPrice = obLow - 2 * _Point;
            double sl = entryPrice + StopLossPoints * _Point;
            double tp = entryPrice - TakeProfitPoints * _Point;
            entryPrice = NormalizeDouble(entryPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
            sl = NormalizeDouble(sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
            tp = NormalizeDouble(tp, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
            double lot = CalculateLotSize();
            if(trade.Sell(lot, _Symbol, entryPrice, sl, tp, "OB Sell")) {
               Print("🔥 SELL ORDER BLOCK TRIGGERED | Price=", entryPrice, " | Lot=", lot);
               lastTradeTime = TimeCurrent();
               return;
            }
         }
      }
   }
   
   // === 2. FAIR VALUE GAP (FVG) STRATEGY ===
   if(ActivateFairValueGap) {
      int limit = 30;
      double high[], low[];
      ArraySetAsSeries(high, true);
      ArraySetAsSeries(low, true);
      CopyHigh(_Symbol, PERIOD_M1, 0, limit, high);
      CopyLow(_Symbol, PERIOD_M1, 0, limit, low);
      
      // Bullish FVG: Candle 2 low > Candle 1 high
      for(int i=2; i<limit-3; i++) {
         if(low[i] > high[i+1]) {
            double entryPrice = low[i] - 2 * _Point;
            double sl = entryPrice - StopLossPoints * _Point;
            double tp = entryPrice + TakeProfitPoints * _Point;
            entryPrice = NormalizeDouble(entryPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
            sl = NormalizeDouble(sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
            tp = NormalizeDouble(tp, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
            double lot = CalculateLotSize();
            if(trade.Buy(lot, _Symbol, entryPrice, sl, tp, "FVG Buy")) {
               Print("🔥 BUY FAIR VALUE GAP TRIGGERED | Price=", entryPrice, " | Lot=", lot);
               lastTradeTime = TimeCurrent();
               return;
            }
         }
      }
      
      // Bearish FVG: Candle 2 high < Candle 1 low
      for(int i=2; i<limit-3; i++) {
         if(high[i] < low[i+1]) {
            double entryPrice = high[i] + 2 * _Point;
            double sl = entryPrice + StopLossPoints * _Point;
            double tp = entryPrice - TakeProfitPoints * _Point;
            entryPrice = NormalizeDouble(entryPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
            sl = NormalizeDouble(sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
            tp = NormalizeDouble(tp, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
            double lot = CalculateLotSize();
            if(trade.Sell(lot, _Symbol, entryPrice, sl, tp, "FVG Sell")) {
               Print("🔥 SELL FAIR VALUE GAP TRIGGERED | Price=", entryPrice, " | Lot=", lot);
               lastTradeTime = TimeCurrent();
               return;
            }
         }
      }
   }
   
   // === 3. LIQUIDITY SWEEP STRATEGY ===
   if(ActivateLiquiditySweep) {
      int limit = 20;
      double high[], low[], close[];
      ArraySetAsSeries(high, true);
      ArraySetAsSeries(low, true);
      ArraySetAsSeries(close, true);
      CopyHigh(_Symbol, PERIOD_M1, 0, limit, high);
      CopyLow(_Symbol, PERIOD_M1, 0, limit, low);
      CopyClose(_Symbol, PERIOD_M1, 0, limit, close);
      
      // Bullish Sweep: Price trades below a recent low, then closes back above it
      double recentLow = low[ArrayMinimum(low, 1, 10)];
      if(close[0] > recentLow && low[0] < recentLow) {
         double entryPrice = recentLow + 2 * _Point;
         double sl = entryPrice - StopLossPoints * _Point;
         double tp = entryPrice + TakeProfitPoints * _Point;
         entryPrice = NormalizeDouble(entryPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
         sl = NormalizeDouble(sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
         tp = NormalizeDouble(tp, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
         double lot = CalculateLotSize();
         if(trade.Buy(lot, _Symbol, entryPrice, sl, tp, "LiqSweep Buy")) {
            Print("🔥 BUY LIQUIDITY SWEEP TRIGGERED | Price=", entryPrice, " | Lot=", lot);
            lastTradeTime = TimeCurrent();
            return;
         }
      }
      
      // Bearish Sweep: Price trades above a recent high, then closes back below it
      double recentHigh = high[ArrayMaximum(high, 1, 10)];
      if(close[0] < recentHigh && high[0] > recentHigh) {
         double entryPrice = recentHigh - 2 * _Point;
         double sl = entryPrice + StopLossPoints * _Point;
         double tp = entryPrice - TakeProfitPoints * _Point;
         entryPrice = NormalizeDouble(entryPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
         sl = NormalizeDouble(sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
         tp = NormalizeDouble(tp, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
         double lot = CalculateLotSize();
         if(trade.Sell(lot, _Symbol, entryPrice, sl, tp, "LiqSweep Sell")) {
            Print("🔥 SELL LIQUIDITY SWEEP TRIGGERED | Price=", entryPrice, " | Lot=", lot);
            lastTradeTime = TimeCurrent();
            return;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate Lot Size (For Cent Accounts)                         |
//+------------------------------------------------------------------+
double CalculateLotSize() {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * RiskPercent / 100.0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double slPoints = StopLossPoints;
   double riskPerLot = slPoints * tickValue;
   double lot = riskAmount / riskPerLot;
   
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   if(LotMode == LOT_CENTS) {
      // For cent accounts, 0.01 is the standard minimum
      minLot = 0.01;
      lot = MathMax(minLot, MathMin(maxLot, lot));
      lot = MathRound(lot / stepLot) * stepLot;
      lot = MathMax(0.01, lot);
   } else {
      lot = MathMax(minLot, MathMin(maxLot, lot));
      lot = MathRound(lot / stepLot) * stepLot;
   }
   return lot;
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
