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

# ============================================
# V16 - ULTRA-AGGRESSIVE MOMENTUM TICK BOT
# ============================================
RUN cat > /root/VALETAX_TICK_BOT_V16.mq5 << 'EOF'
#include <Trade\Trade.mqh>
#property copyright "Omni-Apex V17.1"
#property version   "17.10"
#property strict

input double RiskPercent      = 2.0;      
input double OFI_Threshold    = 1.15;     
input int    LookbackTicks    = 12;       
input double RewardToSpread   = 2.5;      
input double SLToSpread       = 1.5;      
input int    MaxSpread_Pips   = 450;      
input int    MagicNumber      = 999017;

struct TickRecord { int dir; long vol; long msc; };
TickRecord tickBuffer[];
int tickIdx = 0;
CTrade trade;
double lastPrice = 0;

int OnInit() {
   ArrayResize(tickBuffer, LookbackTicks);
   trade.SetExpertMagicNumber(MagicNumber);
   uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0) trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((filling & SYMBOL_FILLING_IOC) != 0) trade.SetTypeFilling(ORDER_FILLING_IOC);
   else trade.SetTypeFilling(ORDER_FILLING_RETURN);
   Print("V17.1 ONLINE");
   return(INIT_SUCCEEDED);
}

double GetDynamicLot(double sl_points) {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(sl_points <= 0 || tickValue <= 0) return 0.1;
   double lot = (equity * (RiskPercent / 100.0)) / (sl_points * (tickValue / tickSize));
   return NormalizeDouble(MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), lot)), 2);
}

void OnTick() {
   MqlTick curr;
   if(!SymbolInfoTick(_Symbol, curr)) return;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double spread_points = (curr.ask - curr.bid) / point;
   int direction = (lastPrice > 0) ? (curr.bid > lastPrice ? 1 : (curr.bid < lastPrice ? -1 : 0)) : 0;
   lastPrice = curr.bid;
   tickBuffer[tickIdx % LookbackTicks].dir = direction;
   tickBuffer[tickIdx % LookbackTicks].vol = (curr.volume_real > 0) ? (long)curr.volume_real : 1;
   tickBuffer[tickIdx % LookbackTicks].msc = curr.time_msc;
   tickIdx++;
   if(tickIdx < LookbackTicks || PositionsTotal() >= 1) return;
   long buyVol = 0, sellVol = 0; int momentum = 0;
   for(int i=0; i<LookbackTicks; i++) {
      if(tickBuffer[i].dir > 0) { buyVol += tickBuffer[i].vol; momentum++; }
      if(tickBuffer[i].dir < 0) { sellVol += tickBuffer[i].vol; momentum--; }
   }
   long timeElapsed = tickBuffer[(tickIdx-1)%LookbackTicks].msc - tickBuffer[tickIdx%LookbackTicks].msc;
   if(timeElapsed > 1500 || timeElapsed <= 0) return;
   double ratio = (sellVol > 0) ? (double)buyVol / (double)sellVol : (double)buyVol;
   double sl_dist_pts = spread_points * SLToSpread;
   double tp_dist_pts = spread_points * RewardToSpread;
   double lot = GetDynamicLot(sl_dist_pts);
   if(ratio >= OFI_Threshold && momentum > (LookbackTicks/2)) {
      trade.Buy(lot, _Symbol, curr.ask, curr.ask - (sl_dist_pts * point), curr.ask + (tp_dist_pts * point), "Apex");
   } else if(ratio <= (1.0 / OFI_Threshold) && momentum < -(LookbackTicks/2)) {
      trade.Sell(lot, _Symbol, curr.bid, curr.bid + (sl_dist_pts * point), curr.bid - (tp_dist_pts * point), "Apex");
   }
}

EOF

# ============================================
# 5. ENTRYPOINT WITH AUTO-ATTACH & COMPILE
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

# Compile EA
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
