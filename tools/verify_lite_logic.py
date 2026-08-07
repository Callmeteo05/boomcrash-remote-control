#!/usr/bin/env python3
"""
Logic verification for CRT_Sniper_Lite.

This is a faithful Python re-implementation of the indicator's decision chain,
run against synthetic price series whose correct answer is known in advance.

It does NOT measure profitability - that needs your real broker data. What it
does prove is that the rules behave the way they are described:

  * signals only appear when the chart and higher timeframe agree
  * buys appear in uptrends, sells in downtrends, neither in a range
  * buys enter in the lower part of the range, sells in the upper part
  * the stop is always on the losing side of entry and the targets on the
    winning side, at the configured R multiples

Run:  python3 tools/verify_lite_logic.py
"""

import math
import random

# ---------------------------------------------------------------- parameters
EMA_FAST, EMA_SLOW = 50, 200
ATR_LEN            = 14
SWING_LEN          = 3
RANGE_LOOK         = 50
MIN_SEP_ATR        = 0.15
MAX_BUY_LOC        = 0.55
MIN_SELL_LOC       = 0.45
SL_LOOKBACK        = 6
SL_BUF_ATR         = 0.30
RR1, RR2           = 2.0, 3.0
MIN_SCORE          = 70
COOLDOWN           = 5
HTF_RATIO          = 12          # 12 chart bars per higher-timeframe bar

TR_RANGE, TR_UP, TR_DOWN = 0, 1, 2
M_TPB, M_SWEEP = 0, 1
MODEL_NAME = {M_TPB: "Trend pullback", M_SWEEP: "Liquidity sweep"}


# ---------------------------------------------------------------- indicators
def ema(values, length):
    out, k = [None] * len(values), 2.0 / (length + 1.0)
    run = None
    for i, v in enumerate(values):
        run = v if run is None else v * k + run * (1.0 - k)
        if i >= length - 1:
            out[i] = run
    return out


def atr(high, low, close, length):
    out, trs, run = [None] * len(close), [], None
    for i in range(len(close)):
        tr = high[i] - low[i] if i == 0 else max(
            high[i] - low[i], abs(high[i] - close[i - 1]), abs(low[i] - close[i - 1]))
        trs.append(tr)
        if i == length - 1:
            run = sum(trs) / length
        elif i >= length:
            run = (run * (length - 1) + tr) / length
        out[i] = run
    return out


def highest(a, f, t):
    f = max(f, 0)
    return max(a[f:t + 1]) if t >= f else None


def lowest(a, f, t):
    f = max(f, 0)
    return min(a[f:t + 1]) if t >= f else None


# ---------------------------------------------------------------- candles
def bull_candle(o, h, l, c, i, a):
    body, rng = abs(c[i] - o[i]), h[i] - l[i]
    if rng <= 0 or a is None or a <= 0:
        return ""
    up = h[i] - max(o[i], c[i])
    dn = min(o[i], c[i]) - l[i]
    if c[i] > o[i] and c[i-1] < o[i-1] and c[i] >= o[i-1] and o[i] <= c[i-1] and body > 0.3 * a:
        return "bullish engulfing"
    if dn >= 2.0 * body and up <= 0.6 * body and c[i] >= l[i] + 0.6 * rng:
        return "hammer"
    if c[i-1] < o[i-1] and o[i] < c[i-1] and c[i] > (o[i-1] + c[i-1]) * 0.5 and c[i] < o[i-1]:
        return "piercing"
    if dn >= 0.45 * rng and c[i] > o[i] and rng > 0.45 * a:
        return "rejection wick"
    if h[i-1] < h[i-2] and l[i-1] > l[i-2] and c[i] > h[i-1] and c[i] > o[i]:
        return "inside bar break"
    if abs(l[i] - l[i-1]) <= 0.12 * a and c[i] > o[i] and c[i-1] < o[i-1]:
        return "double bottom bar"
    if body > 0.45 * rng and c[i] >= l[i] + 0.7 * rng and body > 0.35 * a:
        return "momentum close"
    return ""


def bear_candle(o, h, l, c, i, a):
    body, rng = abs(c[i] - o[i]), h[i] - l[i]
    if rng <= 0 or a is None or a <= 0:
        return ""
    up = h[i] - max(o[i], c[i])
    dn = min(o[i], c[i]) - l[i]
    if c[i] < o[i] and c[i-1] > o[i-1] and c[i] <= o[i-1] and o[i] >= c[i-1] and body > 0.3 * a:
        return "bearish engulfing"
    if up >= 2.0 * body and dn <= 0.6 * body and c[i] <= h[i] - 0.6 * rng:
        return "shooting star"
    if c[i-1] > o[i-1] and o[i] > c[i-1] and c[i] < (o[i-1] + c[i-1]) * 0.5 and c[i] > o[i-1]:
        return "dark cloud"
    if up >= 0.45 * rng and c[i] < o[i] and rng > 0.45 * a:
        return "rejection wick"
    if h[i-1] < h[i-2] and l[i-1] > l[i-2] and c[i] < l[i-1] and c[i] < o[i]:
        return "inside bar break"
    if abs(h[i] - h[i-1]) <= 0.12 * a and c[i] < o[i] and c[i-1] > o[i-1]:
        return "double top bar"
    if body > 0.45 * rng and c[i] <= h[i] - 0.7 * rng and body > 0.35 * a:
        return "momentum close"
    return ""


def candle_strength(p):
    return {"bullish engulfing": 20, "bearish engulfing": 20,
            "hammer": 17, "shooting star": 17,
            "piercing": 15, "dark cloud": 15,
            "inside bar break": 14, "double bottom bar": 13, "double top bar": 13,
            "rejection wick": 12, "momentum close": 10}.get(p, 0)


def clamp01(v):
    return 0.0 if v < 0 else (1.0 if v > 1 else v)


# ---------------------------------------------------------------- the engine
def run(o, h, l, c):
    fast, slow = ema(c, EMA_FAST), ema(c, EMA_SLOW)
    a = atr(h, l, c, ATR_LEN)

    # higher timeframe: EMA 50 of the closes of completed HTF blocks
    htf_close = [c[min((k + 1) * HTF_RATIO - 1, len(c) - 1)]
                 for k in range(len(c) // HTF_RATIO)]
    htf_ema = ema(htf_close, EMA_FAST)

    sw_high = sw_low = None
    sw_high_bar = sw_low_bar = -1
    brt_dir, brt_level, brt_bar, brt_src = 0, None, -1, -1
    last_sig = -10 ** 6
    signals = []

    start = EMA_SLOW + RANGE_LOOK + 30
    for i in range(start, len(c) - 1):
        if a[i] is None or fast[i] is None or slow[i] is None:
            continue

        # swing structure
        s = i - SWING_LEN
        if s - SWING_LEN >= 0:
            win = range(s - SWING_LEN, s + SWING_LEN + 1)
            if all(h[k] < h[s] for k in win if k != s):
                sw_high, sw_high_bar = h[s], s
            if all(l[k] > l[s] for k in win if k != s):
                sw_low, sw_low_bar = l[s], s

        # higher-timeframe trend (uses the last COMPLETED htf block)
        blk = i // HTF_RATIO - 1
        if blk < 0 or blk >= len(htf_ema) or htf_ema[blk] is None:
            continue
        hc, he = htf_close[blk], htf_ema[blk]
        htf_trend = TR_UP if hc > he else (TR_DOWN if hc < he else TR_RANGE)

        chart_trend = TR_RANGE
        if abs(fast[i] - slow[i]) >= MIN_SEP_ATR * a[i]:
            if fast[i] > slow[i] and c[i] > slow[i]:
                chart_trend = TR_UP
            if fast[i] < slow[i] and c[i] < slow[i]:
                chart_trend = TR_DOWN

        trend = TR_RANGE
        if chart_trend == TR_UP and htf_trend == TR_UP:
            trend = TR_UP
        if chart_trend == TR_DOWN and htf_trend == TR_DOWN:
            trend = TR_DOWN

        r_hi = highest(h, i - RANGE_LOOK + 1, i)
        r_lo = lowest(l, i - RANGE_LOOK + 1, i)
        loc = (c[i] - r_lo) / (r_hi - r_lo) if r_hi > r_lo else 0.5

        # break-and-retest level bookkeeping
        # re-arm on every NEWLY broken swing, not just the first one
        if sw_high_bar > 0 and sw_high_bar != brt_src and c[i] > sw_high \
                and (c[i] - sw_high) >= 0.80 * a[i] and (i - sw_high_bar) >= 8:
            brt_dir, brt_level, brt_bar, brt_src = 1, sw_high, i, sw_high_bar
        if sw_low_bar > 0 and sw_low_bar != brt_src and c[i] < sw_low \
                and (sw_low - c[i]) >= 0.80 * a[i] and (i - sw_low_bar) >= 8:
            brt_dir, brt_level, brt_bar, brt_src = -1, sw_low, i, sw_low_bar
        if brt_dir != 0 and i - brt_bar > 30:
            brt_dir = 0

        if trend == TR_RANGE or i - last_sig < COOLDOWN:
            continue

        buy = trend == TR_UP
        candle = bull_candle(o, h, l, c, i, a[i]) if buy else bear_candle(o, h, l, c, i, a[i])

        # --- which model triggered (retest first: it is the most precise) ----
        model, trig = None, 0.0
        if True:
            lvl = lowest(l, i - 20, i - 1) if buy else highest(h, i - 20, i - 1)
            pen = (lvl - l[i]) if buy else (h[i] - lvl)
            swept = (l[i] < lvl < c[i]) if buy else (h[i] > lvl > c[i])
            if swept and pen >= 0.15 * a[i]:
                model, trig = M_SWEEP, clamp01(pen / (0.8 * a[i]))
        if model is None and ((buy and l[i] <= fast[i] < c[i]) or (not buy and h[i] >= fast[i] > c[i])):
            model = M_TPB
            trig = clamp01(abs(fast[i] - slow[i]) / (1.5 * a[i]))
        if model is None:
            continue
        if not candle and trig < 0.75:
            continue

        # --- entry location, measured against what the model actually means --
        # A break-and-retest sits high in the range by definition, so judging it
        # against the 50-bar range would veto every one of them. It is measured
        # against its own breakout leg instead.
        if buy and loc > MAX_BUY_LOC:
            continue
        if not buy and loc < MIN_SELL_LOC:
            continue
        loc_depth = clamp01((MAX_BUY_LOC - loc) / max(MAX_BUY_LOC, .01)) if buy \
            else clamp01((loc - MIN_SELL_LOC) / max(1 - MIN_SELL_LOC, .01))

        entry = c[i]
        sl = (lowest(l, i - SL_LOOKBACK + 1, i) - SL_BUF_ATR * a[i]) if buy \
            else (highest(h, i - SL_LOOKBACK + 1, i) + SL_BUF_ATR * a[i])
        risk = abs(entry - sl)
        if risk <= 0:
            continue
        tp1 = entry + (1 if buy else -1) * risk * RR1
        tp2 = entry + (1 if buy else -1) * risk * RR2

        # trend strength: EMA separation plus how far the HTF sits from its own EMA
        sep_q = clamp01(abs(fast[i] - slow[i]) / (1.2 * a[i]))
        htf_q = clamp01(abs(hc - he) / max(abs(he) * 0.004, 1e-9))
        trend_q = 0.6 * sep_q + 0.4 * htf_q
        rr_to_tp2 = abs(tp2 - entry) / risk
        score = round(20 * trend_q) + round(20 * loc_depth) + candle_strength(candle) + \
            round(20 * trig) + round(20 * clamp01(rr_to_tp2 / 3.0))
        if score < MIN_SCORE:
            continue

        signals.append(dict(bar=i, dir=1 if buy else -1, model=model, score=int(score),
                            entry=entry, sl=sl, tp1=tp1, tp2=tp2, loc=loc, candle=candle))
        last_sig = i
    return signals


# ---------------------------------------------------------------- synthetic data
def make_series(seed, n, drift, pullback_every=0, pullback_depth=0.0, noise=1.0):
    """Deterministic OHLC with a controlled drift and periodic pullbacks."""
    rng = random.Random(seed)
    px, o, h, l, c = 1000.0, [], [], [], []
    for i in range(n):
        step = drift
        if pullback_every and (i // pullback_every) % 2 == 1:
            step = -drift * pullback_depth
        op = px
        px += step + rng.uniform(-noise, noise)
        hi = max(op, px) + abs(rng.uniform(0, noise))
        lo = min(op, px) - abs(rng.uniform(0, noise))
        o.append(op); h.append(hi); l.append(lo); c.append(px)
    return o, h, l, c


def check(label, sigs, expect_dir, bars):
    """expect_dir: 1 buy-only, -1 sell-only, 0 expect (almost) nothing."""
    buys = sum(1 for s in sigs if s["dir"] > 0)
    sells = sum(1 for s in sigs if s["dir"] < 0)
    problems = []

    for s in sigs:
        if s["dir"] > 0:
            if not (s["sl"] < s["entry"] < s["tp1"] < s["tp2"]):
                problems.append(f"bar {s['bar']}: buy levels out of order")
            if s["loc"] > MAX_BUY_LOC + 1e-9:
                problems.append(f"bar {s['bar']}: buy above the location limit")
        else:
            if not (s["sl"] > s["entry"] > s["tp1"] > s["tp2"]):
                problems.append(f"bar {s['bar']}: sell levels out of order")
            if s["loc"] < MIN_SELL_LOC - 1e-9:
                problems.append(f"bar {s['bar']}: sell below the location limit")
        r = abs(s["tp1"] - s["entry"]) / abs(s["entry"] - s["sl"])
        if abs(r - RR1) > 0.01:
            problems.append(f"bar {s['bar']}: TP1 is {r:.2f}R, expected {RR1}R")
        if s["score"] < MIN_SCORE:
            problems.append(f"bar {s['bar']}: score {s['score']} below the filter")

    if expect_dir == 1 and sells:
        problems.append(f"{sells} sell signals inside an uptrend")
    if expect_dir == -1 and buys:
        problems.append(f"{buys} buy signals inside a downtrend")
    if expect_dir == 0 and len(sigs) > bars * 0.01:
        problems.append(f"{len(sigs)} signals in a rangebound market")
    if expect_dir != 0 and not sigs:
        problems.append("no signals at all in a clean trend")

    status = "PASS" if not problems else "FAIL"
    print(f"  [{status}] {label:<34} {buys:>3} buys  {sells:>3} sells")
    for p in problems[:6]:
        print(f"          - {p}")
    return not problems


def main():
    print("\nCRT Sniper Lite - logic verification")
    print("=" * 62)
    all_ok = True

    o, h, l, c = make_series(1, 1400, drift=0.9, pullback_every=40, pullback_depth=0.55)
    up = run(o, h, l, c)
    all_ok &= check("uptrend with pullbacks", up, 1, 1400)

    o, h, l, c = make_series(2, 1400, drift=-0.9, pullback_every=40, pullback_depth=0.55)
    dn = run(o, h, l, c)
    all_ok &= check("downtrend with pullbacks", dn, -1, 1400)

    o, h, l, c = make_series(3, 1400, drift=0.0, noise=1.4)
    rg = run(o, h, l, c)
    all_ok &= check("rangebound / no trend", rg, 0, 1400)

    print("-" * 62)
    every = up + dn
    if every:
        by_model = {}
        for s in every:
            by_model[s["model"]] = by_model.get(s["model"], 0) + 1
        print("  model mix: " + ", ".join(
            f"{MODEL_NAME[k]} {v}" for k, v in sorted(by_model.items())))
        print(f"  score range: {min(s['score'] for s in every)} - "
              f"{max(s['score'] for s in every)}")
        avg_gap = (sum(every[i]["bar"] - every[i-1]["bar"]
                       for i in range(1, len(up))) / max(1, len(up) - 1))
        print(f"  average gap between signals in the uptrend: {avg_gap:.0f} bars")
    print("=" * 62)
    print("RESULT:", "all checks passed\n" if all_ok else "FAILURES ABOVE\n")
    return 0 if all_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
