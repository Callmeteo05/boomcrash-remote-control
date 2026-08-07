#!/usr/bin/env python3
"""
Verification for the session engine and the news models.

Two things go wrong here and both are silent:

  * the broker's server clock is not GMT, so a killzone computed from raw
    bar times lands on the wrong hours and the filter quietly blocks the
    sessions it was meant to allow
  * a sweep-and-reclaim read backwards turns a Judas long into a short

Both are checked against cases whose answer is known in advance.

Run:  python3 tools/verify_sessions_news.py
"""

ASIA   = (0, 6)      # GMT hours, [start, end)
LONDON = (7, 12)
NY     = (12, 17)

S_OFF, S_ASIA, S_LON, S_NY = 0, 1, 2, 3
FAILS = []


def ok(cond, label, detail=""):
    print(f"  [{'PASS' if cond else 'FAIL'}] {label}")
    if not cond:
        print(f"          {detail}")
        FAILS.append(label)


# ---------------------------------------------------------------- the clock
def gmt_hour(server_hour, server_gmt_offset):
    """Brokers run their servers on all sorts of offsets - GMT+2 and GMT+3 are
    the common ones. Sessions must be computed in GMT or they drift."""
    return (server_hour - server_gmt_offset) % 24


def session_of(gmt_h):
    if ASIA[0] <= gmt_h < ASIA[1]:
        return S_ASIA
    if LONDON[0] <= gmt_h < LONDON[1]:
        return S_LON
    if NY[0] <= gmt_h < NY[1]:
        return S_NY
    return S_OFF


# ------------------------------------------------------------- Asian range
def asian_range(bars):
    """bars = [(gmt_hour, high, low)]. Only Asia-window bars count."""
    hi = lo = None
    for gh, h, l in bars:
        if ASIA[0] <= gh < ASIA[1]:
            hi = h if hi is None else max(hi, h)
            lo = l if lo is None else min(lo, l)
    return hi, lo


def judas(asia_hi, asia_lo, bar_high, bar_low, bar_close, bias):
    """London sweeps one side of the Asian range and reclaims it.
    Returns +1 for a long, -1 for a short, 0 for nothing."""
    if asia_hi is None or asia_lo is None or asia_hi <= asia_lo:
        return 0
    if bias >= 0 and bar_low < asia_lo and bar_close > asia_lo:
        return +1                      # swept the low, reclaimed - buy
    if bias <= 0 and bar_high > asia_hi and bar_close < asia_hi:
        return -1                      # swept the high, rejected - sell
    return 0


# ----------------------------------------------------------------- news
def news_breakout(pre_hi, pre_lo, close, atr, disp=1.0):
    if close > pre_hi + disp * atr:
        return +1
    if close < pre_lo - disp * atr:
        return -1
    return 0


def news_reversal(pre_hi, pre_lo, post_hi, post_lo, close, atr, spike=1.5):
    """The release spikes out of the pre-news range then closes back inside.
    The trade is the way back IN, not the way out.

    Price must actually BE back inside the range. Without that condition a
    close far outside satisfies "below the high" and the model fires against
    a live breakout. Requiring it inside also makes this mutually exclusive
    with the breakout model, which requires price outside.

    When the release whipsaws both ways, the larger excursion is the one
    that failed, so that is the side faded.
    """
    if not (pre_lo < close < pre_hi):
        return 0
    up_ex = post_hi - pre_hi
    dn_ex = pre_lo - post_lo
    if up_ex >= spike * atr and up_ex >= dn_ex:
        return -1                      # spiked up, rejected - sell
    if dn_ex >= spike * atr and dn_ex > up_ex:
        return +1                      # spiked down, reclaimed - buy
    return 0


# --------------------------------------------------------------- checks
def main():
    print("\nSessions and news - verification")
    print("=" * 66)

    # 1. server clock conversion -----------------------------------------
    print("\n1. broker server clock converted to GMT")
    # a GMT+3 broker showing 10:00 is really 07:00 GMT = London open
    ok(gmt_hour(10, 3) == 7, "GMT+3 server 10:00 -> 07:00 GMT")
    ok(gmt_hour(2, 3) == 23, "GMT+3 server 02:00 -> 23:00 GMT (previous day)")
    ok(gmt_hour(1, -5) == 6, "GMT-5 server 01:00 -> 06:00 GMT")
    ok(gmt_hour(12, 0) == 12, "GMT+0 server unchanged")

    print("\n2. the same wall-clock hour maps to different sessions per broker")
    a = session_of(gmt_hour(10, 3))     # GMT+3 -> 07 GMT -> London
    b = session_of(gmt_hour(10, 0))     # GMT+0 -> 10 GMT -> London
    c = session_of(gmt_hour(10, 8))     # GMT+8 -> 02 GMT -> Asia
    ok(a == S_LON and b == S_LON and c == S_ASIA,
       f"server 10:00 reads London / London / Asia on GMT+3 / +0 / +8",
       f"got {a} {b} {c}")

    print("\n3. session boundaries")
    ok(session_of(0) == S_ASIA and session_of(5) == S_ASIA, "00:00-05:59 is Asia")
    ok(session_of(6) == S_OFF, "06:00 is the gap between Asia and London")
    ok(session_of(7) == S_LON and session_of(11) == S_LON, "07:00-11:59 is London")
    ok(session_of(12) == S_NY, "12:00 hands over to New York")
    ok(session_of(20) == S_OFF, "20:00 is outside every killzone")

    # 4. Asian range only accumulates inside its window -------------------
    print("\n4. Asian range")
    bars = [(22, 90, 80),        # previous evening, must be ignored
            (0, 101, 99), (2, 105, 98), (5, 103, 97),
            (8, 130, 60)]        # London expansion, must be ignored
    hi, lo = asian_range(bars)
    ok(hi == 105 and lo == 97,
       f"range {lo}-{hi} taken from Asia bars only", f"got {lo}-{hi}")

    # 5. the Judas swing points the right way -----------------------------
    print("\n5. Judas sweep direction")
    ok(judas(105, 97, 104, 95, 99, bias=+1) == +1,
       "swept the Asian low and closed back inside -> BUY")
    ok(judas(105, 97, 108, 100, 103, bias=-1) == -1,
       "swept the Asian high and closed back inside -> SELL")
    ok(judas(105, 97, 104, 95, 96, bias=+1) == 0,
       "swept the low but closed below it -> no trade")
    ok(judas(105, 97, 104, 95, 99, bias=-1) == 0,
       "a long setup is refused when the bias is bearish")

    # 6. news models point the right way ----------------------------------
    print("\n6. news model direction")
    ok(news_breakout(105, 97, 108, atr=2.0) == +1, "closed 1.5 ATR above the range -> BUY")
    ok(news_breakout(105, 97, 94, atr=2.0) == -1, "closed 1.5 ATR below the range -> SELL")
    ok(news_breakout(105, 97, 106, atr=2.0) == 0, "barely above the range -> no trade")

    ok(news_reversal(105, 97, 110, 97, 103, atr=2.0) == -1,
       "spiked 2.5 ATR above then closed back inside -> SELL the failure")
    ok(news_reversal(105, 97, 105, 92, 99, atr=2.0) == +1,
       "spiked 2.5 ATR below then reclaimed -> BUY the failure")
    ok(news_reversal(105, 97, 110, 97, 108, atr=2.0) == 0,
       "spiked up and stayed out -> that is a breakout, not a reversal")
    ok(news_reversal(105, 97, 112, 90, 101, atr=2.0) == -1,
       "whipsawed both ways, the larger excursion (up 7 vs down 7... up wins ties) is faded")

    # 7. breakout and reversal never fire together ------------------------
    print("\n7. the two news models are mutually exclusive")
    clashes = 0
    for close in range(90, 116):
        bo = news_breakout(105, 97, close, atr=2.0)
        rv = news_reversal(105, 97, 110, 92, close, atr=2.0)
        if bo != 0 and rv != 0:
            clashes += 1
    ok(clashes == 0, f"across 26 closing prices there were {clashes} conflicts")

    print("\n" + "=" * 66)
    print("RESULT:", "all checks passed\n" if not FAILS else f"{len(FAILS)} FAILURES: {FAILS}\n")
    return 1 if FAILS else 0


if __name__ == "__main__":
    raise SystemExit(main())
