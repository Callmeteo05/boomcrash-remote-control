# Working rules for this repository

## Research before coding

Before writing any logic that depends on how a broker, instrument or platform actually
behaves, **research it first**. Do not infer behaviour from a name, a convention on
another broker, or memory.

This matters because the conventions genuinely conflict. Deriv's `Crash 1000` means one
spike per ~1000 ticks. Weltrade's `PainX 400` means 400% leverage. Same-looking number,
completely different meaning. Code written on an assumption here is silently wrong.

## Record what you find

Findings go in `docs/BROKER_RESEARCH.md` with:

- the specific claim
- a **confidence level** — verified / medium-high / medium / unverified
- how it was established, and what could not be reached

## Where confidence is below "verified", make the code check itself

Do not encode an uncertain fact as a silent constant. Measure it from live data and
surface a warning when observation contradicts the assumption. The engine should tell
the user it may be wrong rather than trade the wrong way quietly.

## Honesty in output

- No fixed pip values. Every distance derives from ATR, structure or the symbol spec.
- Non-repainting is a property of the code, not a label — closed bars only, nothing
  already drawn ever moves.
- Statistics are computed pessimistically. An ambiguous bar counts as the loss.
- When an instrument has no edge to offer (a driftless random walk), say so rather than
  generating signals for it.

## Environment note

`weltrade.com`, `support.weltrade.com`, `docs.weltrade.com`, `mql5.com` and several
broker/review sites are blocked by this environment's network egress proxy. `WebSearch`
works and its result summaries are usable; direct `WebFetch` of those hosts is not.
Record that a source could not be reached rather than presenting a search summary as
primary.
