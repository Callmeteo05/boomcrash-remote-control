#!/usr/bin/env python3
"""
Verification for the trade-management ladder.

Management runs over open positions, which carry no memory of how they were
opened. Everything it needs - the ORIGINAL stop distance, the style, whether
a partial has already been taken - has to be tracked by the EA itself. Three
real bugs came from not doing that:

  * the partial-taken flag was looked for in the position comment, which
    never contained it and cannot be edited after the fact, so the position
    was sliced again on every tick until it hit the volume minimum
  * R was rebuilt using one hardcoded style's reward multiple, so after
    breakeven every other style measured R wrongly by up to 40%
  * the trail and the time stop were computed on a fixed M15 ATR, so a swing
    trade on H4 was trailed with a scalper's stop

Run:  python3 tools/verify_trade_mgmt.py
"""

FAILS = []
STYLE_RR2 = {"scalp": 2.0, "intraday": 3.0, "swing": 5.0}
STYLE_TF_MIN = {"scalp": 5, "intraday": 15, "swing": 240}

BE_AT_R, BE_LOCK_R = 1.0, 0.10
PARTIAL_AT_R, PARTIAL_PCT = 2.0, 50.0
TRAIL_ATR = 1.5


def ok(cond, label, detail=""):
    print(f"  [{'PASS' if cond else 'FAIL'}] {label}")
    if not cond:
        print(f"          {detail}")
        FAILS.append(label)


class Position:
    """A position plus the metadata the EA must remember about it."""

    def __init__(self, style, direction, entry, sl, volume, atr):
        self.style = style
        self.dir = direction
        self.entry = entry
        self.sl = sl
        self.volume = volume
        self.atr = atr
        # --- metadata the broker does not keep for us
        self.risk_dist = abs(entry - sl)      # the ORIGINAL stop distance
        self.be_done = False
        self.partial_done = False
        self.partials_taken = 0
        self.closed_volume = 0.0

    def r_now(self, price):
        """Always measured from the original stop, never the current one."""
        return (price - self.entry) * self.dir / self.risk_dist


def manage(pos, price, vmin=0.01, vstep=0.01):
    """One management pass, in the order the EA runs it."""
    r = pos.r_now(price)

    # 1. breakeven
    if not pos.be_done and r >= BE_AT_R:
        new_sl = pos.entry + pos.dir * BE_LOCK_R * pos.risk_dist
        if (pos.dir > 0 and new_sl > pos.sl) or (pos.dir < 0 and new_sl < pos.sl):
            pos.sl = new_sl
            pos.be_done = True

    # 2. partial - exactly once
    if not pos.partial_done and r >= PARTIAL_AT_R:
        part = int((pos.volume * PARTIAL_PCT / 100.0) / vstep) * vstep
        if part >= vmin and (pos.volume - part) >= vmin:
            pos.volume = round(pos.volume - part, 8)
            pos.closed_volume += part
            pos.partials_taken += 1
        pos.partial_done = True          # set even if the size was too small

    # 3. trail, on the ATR of the position's OWN timeframe
    if pos.partial_done and pos.atr > 0:
        cand = price - pos.dir * TRAIL_ATR * pos.atr
        if (pos.dir > 0 and cand > pos.sl) or (pos.dir < 0 and cand < pos.sl):
            pos.sl = cand
    return pos


def main():
    print("\nTrade management ladder - verification")
    print("=" * 68)

    # 1. the partial happens once, not on every tick ----------------------
    print("\n1. partial profit is taken exactly once")
    p = Position("intraday", +1, 1.1000, 1.0950, 1.00, 0.0010)
    for _ in range(200):                       # 200 ticks all above 2R
        manage(p, 1.1150)
    ok(p.partials_taken == 1 and abs(p.volume - 0.50) < 1e-9,
       f"{p.partials_taken} partial(s) taken, {p.volume:.2f} lots remain of 1.00",
       f"volume {p.volume}, taken {p.partials_taken}")

    # 2. R keeps its meaning after the stop has moved ---------------------
    print("\n2. R is measured from the original stop, not the current one")
    for style, rr2 in STYLE_RR2.items():
        p = Position(style, +1, 100.0, 95.0, 1.0, 0.5)     # risk = 5.0
        manage(p, 105.0)                                   # +1R -> breakeven
        r_after = p.r_now(110.0)                           # should read exactly 2R
        ok(abs(r_after - 2.0) < 1e-9,
           f"{style:<9} reads {r_after:.2f}R at +10.0 with a 5.0 stop", f"got {r_after}")

    print("\n   the old code rebuilt risk from the target using one fixed style:")
    for style, rr2 in STYLE_RR2.items():
        wrong = abs(100.0 + rr2 * 5.0 - 100.0) / STYLE_RR2["intraday"]   # tp/3.0
        err = abs(wrong - 5.0) / 5.0 * 100.0
        print(f"     {style:<9} would have used risk {wrong:.2f} instead of 5.00  "
              f"({err:.0f}% error)")

    # 3. stops never move backwards ---------------------------------------
    print("\n3. stops only ever move in the trade's favour")
    p = Position("intraday", +1, 100.0, 95.0, 1.0, 1.0)
    path = [105, 110, 112, 108, 115, 109, 120]
    seen = []
    for px in path:
        manage(p, px)
        seen.append(p.sl)
    ok(all(seen[i] >= seen[i-1] - 1e-9 for i in range(1, len(seen))),
       f"long stop path {[round(x,2) for x in seen]} never retreated")

    p = Position("intraday", -1, 100.0, 105.0, 1.0, 1.0)
    seen = []
    for px in [95, 90, 88, 92, 85, 91, 80]:
        manage(p, px)
        seen.append(p.sl)
    ok(all(seen[i] <= seen[i-1] + 1e-9 for i in range(1, len(seen))),
       f"short stop path {[round(x,2) for x in seen]} never retreated")

    # 4. breakeven actually locks something -------------------------------
    print("\n4. breakeven locks a small profit rather than scratching")
    p = Position("intraday", +1, 100.0, 95.0, 1.0, 0.5)
    manage(p, 105.0)
    ok(p.sl > p.entry, f"stop moved to {p.sl:.2f}, above the entry at {p.entry:.2f}")
    p = Position("intraday", -1, 100.0, 105.0, 1.0, 0.5)
    manage(p, 95.0)
    ok(p.sl < p.entry, f"short stop moved to {p.sl:.2f}, below the entry")

    # 5. the trail must scale with the position's own timeframe -----------
    print("\n5. the trail uses the position's own timeframe")
    #    ATR roughly scales with the square root of the timeframe
    atr_m15, atr_h4 = 1.0, 1.0 * (240 / 15) ** 0.5
    swing = Position("swing", +1, 100.0, 90.0, 1.0, atr_h4)
    manage(swing, 125.0)
    wrong_trail = 125.0 - TRAIL_ATR * atr_m15          # if M15 ATR were used
    ok(swing.sl < wrong_trail,
       f"H4 trail sits at {swing.sl:.2f}; an M15 ATR would have put it at "
       f"{wrong_trail:.2f}, {wrong_trail - swing.sl:.2f} tighter")

    # 6. a tiny position is not sliced below the broker minimum -----------
    print("\n6. a position too small to split is left whole")
    p = Position("scalp", +1, 100.0, 99.0, 0.01, 0.2)
    manage(p, 103.0, vmin=0.01, vstep=0.01)
    ok(p.partials_taken == 0 and abs(p.volume - 0.01) < 1e-9 and p.partial_done,
       f"0.01 lots left intact, and the stage is marked done so it is not retried")

    print("\n" + "=" * 68)
    print("RESULT:", "all checks passed\n" if not FAILS else f"{len(FAILS)} FAILURES: {FAILS}\n")
    return 1 if FAILS else 0


if __name__ == "__main__":
    raise SystemExit(main())
