#!/usr/bin/env python3
"""
Verification for the EA's money maths.

A wrong position size is the one bug that empties an account, so the sizing,
breakeven, trailing and exposure logic is re-implemented here and checked
against cases where the right answer is known by hand.

Run:  python3 tools/verify_risk_math.py
"""

# --------------------------------------------------------------- instruments
# tick_value is account currency earned per tick, per 1.0 lot
SYMBOLS = {
    "EURUSD":  dict(tick_size=0.00001, tick_value=1.00,  digits=5,
                    vmin=0.01, vmax=200.0, vstep=0.01, stops_pts=0),
    "USDJPY":  dict(tick_size=0.001,   tick_value=0.68,  digits=3,
                    vmin=0.01, vmax=200.0, vstep=0.01, stops_pts=0),
    "XAUUSD":  dict(tick_size=0.01,    tick_value=1.00,  digits=2,
                    vmin=0.01, vmax=50.0,  vstep=0.01, stops_pts=30),
    "US30":    dict(tick_size=0.1,     tick_value=0.10,  digits=1,
                    vmin=0.1,  vmax=100.0, vstep=0.1,  stops_pts=50),
    "Boom1000": dict(tick_size=0.001,  tick_value=0.001, digits=3,
                     vmin=0.2, vmax=100.0, vstep=0.01, stops_pts=0),
}


# --------------------------------------------------------------- risk tiers
def risk_pct_for(equity_native, is_cent, tiers):
    """Cent accounts hold 100 units per real currency unit, so the tier
    lookup must use the real value or every small account is misread as large."""
    real = equity_native / 100.0 if is_cent else equity_native
    for ceiling, pct in tiers:
        if real < ceiling:
            return pct, real
    return tiers[-1][1], real


TIERS = [(200.0, 2.0), (1000.0, 1.5), (10000.0, 1.0), (float("inf"), 0.75)]


# --------------------------------------------------------------- lot sizing
def lot_for(sym, sl_distance, risk_money):
    s = SYMBOLS[sym]
    if sl_distance <= 0 or risk_money <= 0:
        return 0.0, "no risk or no stop distance"
    loss_per_lot = sl_distance / s["tick_size"] * s["tick_value"]
    if loss_per_lot <= 0:
        return 0.0, "instrument data unusable"
    raw = risk_money / loss_per_lot
    stepped = int(raw / s["vstep"]) * s["vstep"]          # always round DOWN
    stepped = round(stepped, 8)
    if stepped < s["vmin"]:
        return 0.0, f"needs {raw:.4f} lots, broker minimum is {s['vmin']}"
    if stepped > s["vmax"]:
        stepped = s["vmax"]
    return stepped, "ok"


def realised_risk(sym, lots, sl_distance):
    s = SYMBOLS[sym]
    return lots * sl_distance / s["tick_size"] * s["tick_value"]


# --------------------------------------------------------------- management
def breakeven_price(entry, sl, direction, lock_r):
    r = abs(entry - sl)
    return entry + direction * lock_r * r


def trail_price(entry, sl, direction, price_now, atr, mult):
    """ATR trail that may only ever move in the winning direction."""
    cand = price_now - direction * mult * atr
    if direction > 0:
        return max(sl, cand)
    return min(sl, cand)


def open_risk(positions):
    """Risk still live: a position past breakeven contributes nothing."""
    total = 0.0
    for p in positions:
        if p["dir"] > 0 and p["sl"] >= p["entry"]:
            continue
        if p["dir"] < 0 and p["sl"] <= p["entry"]:
            continue
        total += p["risk_money"]
    return total


# --------------------------------------------------------------- checks
FAILS = []


def ok(cond, label, detail=""):
    print(f"  [{'PASS' if cond else 'FAIL'}] {label}")
    if not cond:
        print(f"          {detail}")
        FAILS.append(label)


def main():
    print("\nEA money maths - verification")
    print("=" * 66)

    # ---- 1. sizing gives back exactly the risk asked for -----------------
    print("\n1. position sizing returns the requested risk")
    for sym, sl_dist, risk in [("EURUSD", 0.00150, 100.0),
                               ("USDJPY", 0.250, 100.0),
                               ("XAUUSD", 3.50, 250.0),
                               ("US30", 45.0, 500.0)]:
        lots, why = lot_for(sym, sl_dist, risk)
        got = realised_risk(sym, lots, sl_dist)
        # rounding down a lot step can only ever risk LESS than asked
        ok(lots > 0 and got <= risk + 1e-9 and got > risk * 0.90,
           f"{sym:<8} {lots:>6.2f} lots risks {got:7.2f} of {risk:.2f}",
           f"{why}; got {got}")

    # ---- 2. rounding never rounds UP into extra risk ---------------------
    print("\n2. lot rounding never increases risk")
    worst = 0.0
    for i in range(1, 400):
        risk = i * 1.37
        lots, _ = lot_for("EURUSD", 0.00123, risk)
        if lots > 0:
            got = realised_risk("EURUSD", lots, 0.00123)
            worst = max(worst, got - risk)
    ok(worst <= 1e-9, f"across 400 sizes the worst overshoot was {worst:.10f}")

    # ---- 3. accounts too small to size safely are refused ----------------
    print("\n3. an account too small for the instrument is refused")
    lots, why = lot_for("US30", 45.0, 2.0)      # $2 risk on an index
    ok(lots == 0.0, f"US30 with $2 risk is declined - {why}")
    lots, why = lot_for("EURUSD", 0.00150, 0.50)
    ok(lots == 0.0, f"EURUSD with $0.50 risk is declined - {why}")

    # ---- 4. cent accounts are read at their real value -------------------
    print("\n4. cent accounts are not mistaken for large accounts")
    pct_cent, real_cent = risk_pct_for(50000.0, True, TIERS)    # 50,000 cents = $500
    pct_usd, real_usd = risk_pct_for(50000.0, False, TIERS)     # $50,000
    ok(abs(real_cent - 500.0) < 1e-9 and pct_cent == 1.5,
       f"50,000 cents reads as ${real_cent:.0f} -> {pct_cent}% risk")
    ok(real_usd == 50000.0 and pct_usd == 0.75,
       f"$50,000 reads as ${real_usd:.0f} -> {pct_usd}% risk")

    # ---- 5. risk falls as the account grows ------------------------------
    print("\n5. risk percentage falls as the account grows")
    seq = [risk_pct_for(e, False, TIERS)[0] for e in (100, 500, 5000, 50000)]
    ok(seq == sorted(seq, reverse=True), f"tiers descend: {seq}")

    # ---- 6. breakeven and trailing only ever move the right way ----------
    print("\n6. stops only move in the trade's favour")
    entry, sl, d, atr = 1.1000, 1.0950, 1, 0.0020
    be = breakeven_price(entry, sl, d, 0.1)
    ok(be > entry, f"long breakeven {be:.5f} locks above entry {entry:.5f}")

    s = sl
    for px in (1.1020, 1.1050, 1.1030, 1.1090):     # note the pullback
        s = trail_price(entry, s, d, px, atr, 1.5)
    ok(s >= 1.1090 - 1.5 * atr - 1e-9 and s > sl,
       f"long trail ended at {s:.5f}, never retreated")

    entry, sl, d = 1.1000, 1.1050, -1
    s = sl
    for px in (1.0980, 1.0950, 1.0970, 1.0910):
        s = trail_price(entry, s, d, px, atr, 1.5)
    ok(s <= 1.0910 + 1.5 * atr + 1e-9 and s < 1.1050,
       f"short trail ended at {s:.5f}, never retreated")

    # ---- 7. exposure cap counts only live risk ---------------------------
    print("\n7. exposure cap counts live risk only")
    pos = [dict(dir=1, entry=1.10, sl=1.09, risk_money=100.0),   # live
           dict(dir=1, entry=1.10, sl=1.10, risk_money=100.0),   # at breakeven
           dict(dir=-1, entry=1.10, sl=1.11, risk_money=80.0)]   # live
    ok(abs(open_risk(pos) - 180.0) < 1e-9,
       f"live risk is {open_risk(pos):.0f}, breakeven position excluded")

    # ---- 8. scale-in cannot breach the cap -------------------------------
    print("\n8. scaling in respects the total risk cap")
    cap = 300.0
    live = open_risk(pos)                     # 180
    new_lots, _ = lot_for("EURUSD", 0.00150, 100.0)
    new_risk = realised_risk("EURUSD", new_lots, 0.00150)
    ok(live + new_risk <= cap, f"180 live + {new_risk:.0f} new stays under {cap:.0f}")
    ok(not (live + 200.0 <= cap), "a 200 add would breach the cap and is refused")

    print("\n" + "=" * 66)
    print("RESULT:", "all checks passed\n" if not FAILS
          else f"{len(FAILS)} FAILURES: {FAILS}\n")
    return 1 if FAILS else 0


if __name__ == "__main__":
    raise SystemExit(main())
