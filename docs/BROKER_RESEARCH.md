# Broker & Instrument Research

Findings that the engine's logic depends on. Recorded so they are not re-guessed.
Each entry carries a confidence level. **Anything below "verified" must be
self-checked by the code against live data rather than trusted.**

Last updated: 2026-08-09

---

## Weltrade — SyntX synthetic indices

Weltrade **does** offer synthetic indices. They are a proprietary family called
**SyntX**, traded on a dedicated SyntX account type on MT4/MT5, available 24/7.
Pricing comes from a patented RNG algorithm; the instruments do not track any
underlying asset.

They are *not* Boom/Crash — those are Deriv's. The behaviours are analogous but the
names, the variants and the leverage semantics are different.

### Instrument families

| Family | Variants seen | Behaviour | Analogue |
|---|---|---|---|
| **PainX** | 400, 600, 800, 999, 1200 | Gradual rises with **sharp drops** — spikes **down** | Crash |
| **GainX** | 400, 600, 800, 999, 1200 | Steady declines with **sudden spikes up** | Boom |
| **FlipX** | 1–5 | 50/50 up or down on **each tick** — driftless random walk | Step Index |
| **FX Vol** | 20, 40, 60, 80, 99 | Replicates forex at a fixed volatility. No spike mechanic | Volatility index |
| **SFX Vol** | several | FX Vol plus **simulated news releases** causing occasional spikes | — |
| **SwitchX** | — | **Alternates** between PainX and GainX mode after each jump | — |
| **BreakX** | — | Switches mode only when a new jump **breaches the previous jump's level** | — |
| **TrendX** | — | Reads the **last two jumps** and switches between PainX/GainX to follow momentum | — |
| Stock Market Index | — | Listed in the copy-trading conditions document | — |

### Leverage semantics — important

The number in `PainX 400` / `GainX 800` is **leverage percentage, not spike frequency.**
This is the opposite of Deriv's convention, where `Crash 1000` means one spike per
~1000 ticks.

- PainX 400 → 400% leverage; a price jump of 0.01 (1 pip) produces a **4 point** move.
- GainX 800 → 800% leverage; the same 0.01 jump produces an **8 point** move.
- Up to 1200% on the 1200 variants.

**Consequence for the engine:** the variant number must never be read as a spike-rate
hint. Nothing may be derived from it. Volatility differences are already captured by
ATR, which is what the engine actually uses.

### Contract details (partial)

- PainX 999 / GainX 999: spread **0.30**, minimum lot **0.01**, max 15 orders.
- SyntX instruments trade 24/7 with no session structure.

Confidence: **medium.** Read from a search summary of
`docs.weltrade.com/syntx-trading-limits-and-conditions.pdf`, not from the PDF itself.
The engine reads spread and lot limits from the symbol spec at runtime anyway, so
nothing depends on these numbers being exact.

### Confidence on spike direction

**Medium-high.** "PainX focuses on gradual rises with sharp drops while GainX involves
steady declines with sudden spikes" is corroborated across two independent search
summaries, and is consistent with the SwitchX description pairing the two behaviours.
It was **not** confirmed against Weltrade's own pages — `weltrade.com`,
`support.weltrade.com` and `docs.weltrade.com` are all blocked by this environment's
network egress proxy.

Because of that, the engine **measures** the spike direction from live bars and warns
when the observed direction contradicts the name-based assumption. If the mapping above
is backwards, the panel will say so rather than trading the wrong way silently.

### Mode-switching instruments

SwitchX, BreakX and TrendX **change direction by design**. A fixed name-based bias is
wrong for these. The engine classifies them as *adaptive* and takes the bias from the
measured recent spike direction instead.

---

## Deriv — Boom / Crash / Step

| Instrument | Behaviour |
|---|---|
| **Crash 1000/500/300** | Grinds up, drops sharply — on average one drop per N ticks |
| **Boom 1000/500/300** | Drifts down, spikes up — on average one spike per N ticks |
| **Step Index** | Equal probability of up/down with a **fixed step size of 0.1** |

Here the number **is** the spike frequency in ticks. Opposite convention to Weltrade.

Confidence: **verified** — the instrument descriptions appear in the terminal itself,
visible in the user's own screenshots ("On average one drop occurs in the price series
every 1000 ticks", "Equal probability of up/down with fixed step size of 0.1").

### The memorylessness question

If spike arrival is a Bernoulli trial per tick at p ≈ 1/1000, the process is
**memoryless** — ticks-since-last-spike then carries *no* predictive information, and
any tool claiming to count down to the next spike is selling a myth.

Whether the real implementation is exactly memoryless is **unverified**. The engine
should therefore measure the empirical hazard rather than assume either way. Planned,
not yet built.

---

## Symbol naming across brokers

- Brokers append their own suffixes: `EURUSD.m`, `AUDCHF.m`, `US100.s`. All symbol
  detection must use **substring matching**, never equality.
- Spacing and case vary (`Crash 1000 Index`, `PainX 400`, `Pain X 400` on some
  marketing pages). Detection strips spaces and upper-cases before matching.

---

## Working rule

Research the instrument before writing logic that depends on its behaviour, record it
here with a confidence level, and where confidence is below *verified*, make the code
check itself against live data and report a contradiction.
