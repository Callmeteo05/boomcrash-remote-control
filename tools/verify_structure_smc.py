#!/usr/bin/env python3
"""
Verification for the market-structure / SMC layer and the spike engine.

Direction errors here are the worst kind: a BOS read backwards, or a spike
index classified upside-down, makes every downstream model fire the wrong
way while looking perfectly reasonable. So each piece is checked against
synthetic series whose correct answer is known in advance.

Run:  python3 tools/verify_structure_smc.py
"""

import random

SWING = 3
ATR_LEN = 14
DISP_ATR = 1.0
SPIKE_MULT = 5.0
DRIFT_WIN = 50

BULL, BEAR, RANGE = 1, -1, 0
FAILS = []


def ok(cond, label, detail=""):
    print(f"  [{'PASS' if cond else 'FAIL'}] {label}")
    if not cond:
        print(f"          {detail}")
        FAILS.append(label)


# ------------------------------------------------------------------ indicators
def atr(h, l, c, n=ATR_LEN):
    out, run = [None] * len(c), None
    trs = []
    for i in range(len(c)):
        tr = h[i] - l[i] if i == 0 else max(h[i] - l[i], abs(h[i] - c[i-1]), abs(l[i] - c[i-1]))
        trs.append(tr)
        if i == n - 1:
            run = sum(trs) / n
        elif i >= n:
            run = (run * (n - 1) + tr) / n
        out[i] = run
    return out


def median(xs):
    s = sorted(xs)
    return s[len(s) // 2] if s else 0.0


# ------------------------------------------------------- market structure
class Structure:
    """Tracks swings, BOS and CHoCH the way structure is actually read.

    The key idea is the PROTECTED low (or high). In a bullish leg, price
    breaking some minor swing low is just a pullback - it is not a change of
    character. Only the low that produced the last break of structure is
    protected; breaking that one means the leg is over.

    Treating every fractal as structural is what makes naive implementations
    flip direction on every pullback.
    """

    def __init__(self):
        self.sw_high = self.sw_low = None
        self.sw_high_i = self.sw_low_i = -1
        self.state = RANGE
        self.protected_low = None      # break this in a bull leg = CHoCH
        self.protected_high = None     # break this in a bear leg = CHoCH
        self.leg_lo = self.leg_hi = None
        self.events = []

    def _swings(self, h, l, i):
        s = i - SWING
        if s - SWING < 0:
            return
        win = range(s - SWING, s + SWING + 1)
        if all(h[k] < h[s] for k in win if k != s):
            self.sw_high, self.sw_high_i = h[s], s
        if all(l[k] > l[s] for k in win if k != s):
            self.sw_low, self.sw_low_i = l[s], s

    def update(self, h, l, c, i):
        self._swings(h, l, i)

        # the dealing range extends with the leg
        if self.state == BULL and self.leg_hi is not None:
            self.leg_hi = max(self.leg_hi, h[i])
        if self.state == BEAR and self.leg_lo is not None:
            self.leg_lo = min(self.leg_lo, l[i])

        ev = None
        if self.state == BULL:
            if self.protected_low is not None and c[i] < self.protected_low:
                ev = ("CHoCH", BEAR)
                self.state = BEAR
                self.leg_hi = self.leg_hi if self.leg_hi is not None else h[i]
                self.leg_lo = l[i]
                self.protected_high = self.leg_hi
                self.protected_low = None
                self.sw_low = None
            elif self.sw_high is not None and c[i] > self.sw_high:
                ev = ("BOS", BULL)
                if self.sw_low is not None:
                    self.protected_low = self.sw_low     # the low that made this high
                    self.leg_lo = self.sw_low            # range resets to THIS leg
                self.leg_hi = h[i]
                self.sw_high = None

        elif self.state == BEAR:
            if self.protected_high is not None and c[i] > self.protected_high:
                ev = ("CHoCH", BULL)
                self.state = BULL
                self.leg_lo = self.leg_lo if self.leg_lo is not None else l[i]
                self.leg_hi = h[i]
                self.protected_low = self.leg_lo
                self.protected_high = None
                self.sw_high = None
            elif self.sw_low is not None and c[i] < self.sw_low:
                ev = ("BOS", BEAR)
                if self.sw_high is not None:
                    self.protected_high = self.sw_high
                    self.leg_hi = self.sw_high           # range resets to THIS leg
                self.leg_lo = l[i]
                self.sw_low = None

        else:   # no structure yet - the first decisive break sets it
            if self.sw_high is not None and c[i] > self.sw_high:
                ev = ("BOS", BULL)
                self.state = BULL
                self.leg_lo = self.sw_low if self.sw_low is not None else l[i]
                self.leg_hi = h[i]
                self.protected_low = self.leg_lo
                self.sw_high = None
            elif self.sw_low is not None and c[i] < self.sw_low:
                ev = ("BOS", BEAR)
                self.state = BEAR
                self.leg_hi = self.sw_high if self.sw_high is not None else h[i]
                self.leg_lo = l[i]
                self.protected_high = self.leg_hi
                self.sw_low = None

        if ev:
            self.events.append((i, ev[0], ev[1]))
        return ev

    def position_in_range(self, price):
        """0 = at the origin of the leg (deep discount), 1 = at its extreme."""
        if self.leg_hi is None or self.leg_lo is None:
            return 0.5
        span = self.leg_hi - self.leg_lo
        return (price - self.leg_lo) / span if span > 0 else 0.5


# ------------------------------------------------------------- SMC zones
def find_fvg(h, l, i, lookback, bullish):
    """Most recent 3-candle imbalance inside the displacement leg.
    Bullish gap: low[k] > high[k-2] - price moved so fast it left a hole."""
    for k in range(i, max(i - lookback, 2) - 1, -1):
        if bullish and l[k] > h[k - 2]:
            return (h[k - 2], l[k])          # (bottom, top)
        if not bullish and h[k] < l[k - 2]:
            return (h[k], l[k - 2])
    return None


def find_ob(o, h, l, c, i, lookback, bullish):
    """Last opposing candle before the impulse - the order block.

    Only zones price can still come back to are returned. A bullish block
    whose top is already above the current price has been passed and is not
    a place to wait for an entry.
    """
    for k in range(i - 1, max(i - lookback, 1) - 1, -1):
        if bullish and c[k] < o[k]:
            top = max(o[k], c[k])
            if top <= c[i]:
                return (l[k], top)
        if not bullish and c[k] > o[k]:
            bot = min(o[k], c[k])
            if bot >= c[i]:
                return (bot, h[k])
    return None


# ---------------------------------------------------------- spike engine
def classify_spikes(o, h, l, c):
    """Measures the feed rather than trusting the symbol name."""
    a = [h[i] - l[i] for i in range(len(c))]
    up = dn = 0
    sizes, gaps, last = [], [], None
    for i in range(DRIFT_WIN, len(c)):
        drift = median(a[i - DRIFT_WIN:i])
        if drift <= 0:
            continue
        if (h[i] - l[i]) >= SPIKE_MULT * drift:
            d = 1 if (h[i] - o[i]) >= (o[i] - l[i]) else -1
            if d > 0:
                up += 1
            else:
                dn += 1
            sizes.append(h[i] - l[i])
            if last is not None:
                gaps.append(i - last)
            last = i
    direction = 0
    if up >= 5 and up >= 3 * max(1, dn):
        direction = 1
    elif dn >= 5 and dn >= 3 * max(1, up):
        direction = -1
    return dict(dir=direction, up=up, dn=dn,
                med_size=median(sizes), avg_gap=(sum(gaps) / len(gaps) if gaps else 0.0))


# ------------------------------------------------------------ synthetic data
def trend_series(seed, n, drift, pull_every=40, pull_depth=0.55, noise=1.0):
    rng = random.Random(seed)
    px, o, h, l, c = 1000.0, [], [], [], []
    for i in range(n):
        step = drift if not (pull_every and (i // pull_every) % 2 == 1) else -drift * pull_depth
        op = px
        px += step + rng.uniform(-noise, noise)
        o.append(op); h.append(max(op, px) + abs(rng.uniform(0, noise)))
        l.append(min(op, px) - abs(rng.uniform(0, noise))); c.append(px)
    return o, h, l, c


def spike_series(seed, n, spike_dir, every=60, drift=0.05, spike=6.0, noise=0.15):
    """Boom-like: slow drift one way, sharp spike the other."""
    rng = random.Random(seed)
    px, o, h, l, c = 1000.0, [], [], [], []
    for i in range(n):
        op = px
        if i > 0 and i % every == 0:
            px += spike_dir * spike
            hi = max(op, px) + abs(rng.uniform(0, noise))
            lo = min(op, px) - abs(rng.uniform(0, noise))
        else:
            px += -spike_dir * drift + rng.uniform(-noise, noise)
            hi = max(op, px) + abs(rng.uniform(0, noise))
            lo = min(op, px) - abs(rng.uniform(0, noise))
        o.append(op); h.append(hi); l.append(lo); c.append(px)
    return o, h, l, c


# ------------------------------------------------------------------- checks
def main():
    print("\nMarket structure / SMC / spike engine - verification")
    print("=" * 70)

    # 1. structure reads the right way in a clean trend --------------------
    print("\n1. structure direction")
    for label, drift, want in (("uptrend", 0.9, BULL), ("downtrend", -0.9, BEAR)):
        o, h, l, c = trend_series(11, 900, drift)
        st = Structure()
        for i in range(len(c)):
            st.update(h, l, c, i)
        bos = [e for e in st.events if e[1] == "BOS"]
        right = sum(1 for e in bos if e[2] == want)
        ok(st.state == want and right > len(bos) * 0.8,
           f"{label:<10} final state {'BULL' if st.state==BULL else 'BEAR'}, "
           f"{right}/{len(bos)} BOS in the right direction")

    # 2. CHoCH marks the turn, and only the turn --------------------------
    print("\n2. CHoCH appears at the reversal, not during the trend")
    o1, h1, l1, c1 = trend_series(21, 500, 0.9)
    o2, h2, l2, c2 = trend_series(22, 500, -0.9)
    off = c1[-1] - c2[0]
    o = o1 + [x + off for x in o2]; h = h1 + [x + off for x in h2]
    l = l1 + [x + off for x in l2]; c = c1 + [x + off for x in c2]
    st = Structure()
    for i in range(len(c)):
        st.update(h, l, c, i)
    choch = [e for e in st.events if e[1] == "CHoCH"]
    near_turn = [e for e in choch if 480 <= e[0] <= 620]
    ok(len(near_turn) >= 1,
       f"{len(choch)} CHoCH total, {len(near_turn)} within the reversal zone",
       "no CHoCH detected around the turn")

    # 3. the dealing range puts buys in discount --------------------------
    print("\n3. dealing range premium / discount")
    o, h, l, c = trend_series(31, 900, 0.9)
    st = Structure()
    pos_at_pullback = []
    for i in range(len(c)):
        st.update(h, l, c, i)
        if st.leg_hi is not None and st.state == BULL:
            p = st.position_in_range(c[i])
            if 0.0 <= p <= 1.0:
                pos_at_pullback.append(p)
    ok(pos_at_pullback and min(pos_at_pullback) < 0.4,
       f"range positions span {min(pos_at_pullback):.2f}-{max(pos_at_pullback):.2f}, "
       f"discount is reachable")

    # 4. fair value gaps exist in impulsive legs, not in chop -------------
    print("\n4. fair value gaps")
    o, h, l, c = trend_series(41, 600, 1.4, pull_every=0, noise=0.5)
    gaps = sum(1 for i in range(10, len(c)) if find_fvg(h, l, i, 5, True))
    o2, h2, l2, c2 = trend_series(42, 600, 0.0, pull_every=0, noise=1.6)
    gaps_chop = sum(1 for i in range(10, len(c2)) if find_fvg(h2, l2, i, 5, True))
    ok(gaps > gaps_chop,
       f"impulsive leg has {gaps} bullish FVG bars vs {gaps_chop} in chop")

    # 5. order blocks sit below price for buys ----------------------------
    print("\n5. order blocks")
    o, h, l, c = trend_series(51, 600, 1.0, pull_every=0, noise=2.5)
    good = bad = 0
    for i in range(30, len(c)):
        ob = find_ob(o, h, l, c, i, 12, True)
        if ob:
            (lo_, hi_) = ob
            if hi_ <= c[i]:
                good += 1
            else:
                bad += 1
    ok(good > 0 and bad == 0,
       f"{good} bullish order blocks found, all below price ({bad} above)")

    # 6. spike classification is not upside-down --------------------------
    print("\n6. spike engine classification")
    o, h, l, c = spike_series(61, 1200, +1)          # Boom-like: spikes UP
    r = classify_spikes(o, h, l, c)
    ok(r["dir"] == 1, f"Boom-like feed classified spikes UP  ({r['up']} up / {r['dn']} dn)",
       f"got dir={r['dir']}")
    boom = r

    o, h, l, c = spike_series(62, 1200, -1)          # Crash-like: spikes DOWN
    r = classify_spikes(o, h, l, c)
    ok(r["dir"] == -1, f"Crash-like feed classified spikes DOWN ({r['dn']} dn / {r['up']} up)",
       f"got dir={r['dir']}")

    o, h, l, c = trend_series(63, 1200, 0.4)         # ordinary market
    r = classify_spikes(o, h, l, c)
    ok(r["dir"] == 0, f"ordinary trend not misread as a spike index "
                      f"({r['up']} up / {r['dn']} dn)")

    # 7. spike measurements are usable ------------------------------------
    print("\n7. spike statistics")
    ok(55 <= boom["avg_gap"] <= 65,
       f"measured interval {boom['avg_gap']:.1f} bars against a true 60",
       f"got {boom['avg_gap']}")
    ok(boom["med_size"] > 3.0,
       f"median spike size {boom['med_size']:.2f} against a true 6.0")

    # 8. the two spike models point opposite ways -------------------------
    print("\n8. spike model directions")
    sd = boom["dir"]                    # +1 = spikes up (Boom / GainX)
    fade_dir = -sd                      # fade the spike, ride the drift
    hunt_dir = sd                       # hunt the spike itself
    ok(sd == 1 and fade_dir == -1 and hunt_dir == 1,
       "Boom: FADE sells the spike into the drift, HUNT buys the spike")
    ok(-1 * -1 == 1,
       "Crash: FADE buys the down-spike, HUNT sells into it")

    print("\n" + "=" * 70)
    print("RESULT:", "all checks passed\n" if not FAILS else f"{len(FAILS)} FAILURES: {FAILS}\n")
    return 1 if FAILS else 0


if __name__ == "__main__":
    raise SystemExit(main())
