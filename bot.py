#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import time
from datetime import datetime
from collections import deque
import MetaTrader5 as mt5


CONFIG = {
    "SYMBOLS": ["EURUSD", "GBPUSD", "BTCUSD"],
    "LOOKBACK": 30,
    "OFI_THRESHOLD": 1.2,
    "SLEEP": 1
}


# ================= INIT =================
print("\n==============================")
print("🔥 MT5 DEBUG BOT STARTING")
print("==============================")

if not mt5.initialize():
    print("❌ MT5 INIT FAILED")
    print("ERROR:", mt5.last_error())
    exit()

print("✅ MT5 CONNECTED")
print("ACCOUNT:", mt5.account_info())


class DebugBot:

    def __init__(self):
        self.buffers = {}
        self.trade_attempts = 0
        self.signals = 0

    # ================= SETUP =================
    def setup(self):
        print("\n🔍 SYMBOL CHECK")

        symbols = mt5.symbols_get()
        available = [s.name for s in symbols] if symbols else []

        print(f"📊 Total symbols in MT5: {len(available)}")

        for s in CONFIG["SYMBOLS"]:
            if s in available:
                mt5.symbol_select(s, True)
                self.buffers[s] = deque(maxlen=CONFIG["LOOKBACK"])
                print(f"✅ OK: {s}")
            else:
                print(f"❌ NOT FOUND: {s}")

        if not self.buffers:
            print("❌ NO SYMBOLS WORKING → STOP")
            exit()

    # ================= TICKS =================
    def get_ticks(self, symbol):
        ticks = mt5.copy_ticks_from(symbol, datetime.now(), 200, mt5.COPY_TICKS_ALL)

        if ticks is None:
            print(f"⚠️ {symbol} → None ticks | ERR:", mt5.last_error())
            return []

        if len(ticks) == 0:
            print(f"⚠️ {symbol} → EMPTY ticks")
            return []

        return [{"buy": t.ask > t.bid} for t in ticks[-CONFIG["LOOKBACK"]:]]

    # ================= OFI =================
    def ofi(self, symbol):
        buf = self.buffers[symbol]

        if len(buf) < 10:
            return None

        buys = sum(1 for x in buf if x["buy"])
        sells = len(buf) - buys or 1

        return buys / sells, buys, sells

    # ================= TRADE SIM =================
    def fake_trade(self, symbol):
        self.trade_attempts += 1
        print(f"📤 TRADE ATTEMPT #{self.trade_attempts} → {symbol}")

    # ================= LOOP =================
    def run(self):

        self.setup()

        while True:

            print("\n" + "=" * 60)
            print("🔄 NEW CYCLE:", datetime.now())
            print("=" * 60)

            any_signal = False

            for sym in self.buffers:

                print(f"\n🔎 SYMBOL: {sym}")

                ticks = self.get_ticks(sym)
                print(f"📊 ticks received: {len(ticks)}")

                for t in ticks:
                    self.buffers[sym].append(t)

                ratio_data = self.ofi(sym)

                if ratio_data is None:
                    print("⚠️ NOT ENOUGH DATA FOR OFI")
                    continue

                ratio, buys, sells = ratio_data

                print(f"📈 OFI: {ratio:.2f} | buys={buys} sells={sells}")

                # SIGNAL LOGIC
                if ratio >= CONFIG["OFI_THRESHOLD"]:
                    print("🟢 BUY SIGNAL DETECTED")
                    self.signals += 1
                    any_signal = True
                    self.fake_trade(sym)

                elif ratio <= 1 / CONFIG["OFI_THRESHOLD"]:
                    print("🔴 SELL SIGNAL DETECTED")
                    self.signals += 1
                    any_signal = True
                    self.fake_trade(sym)

                else:
                    print("⏸ NO SIGNAL")

            # ================= DIAGNOSTIC SUMMARY =================
            print("\n📊 CYCLE SUMMARY")
            print("Signals:", self.signals)
            print("Trade attempts:", self.trade_attempts)

            if not any_signal:
                print("❗ WHY NO TRADE?")
                print("→ OFI never reached threshold")
                print("→ OR tick data too weak / empty")
                print("→ OR symbol mismatch (.vx issue likely)")

            time.sleep(CONFIG["SLEEP"])
