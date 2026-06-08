# Riding the silver dragon

The technical docs say *what* Wyve is. This says *why*.

## Wyve doesn't try to be the dragon. It rides it.

**LLVM is the silver dragon** — the fastest beast alive. Its power is real,
but raw: ask it to vectorize a loop and you can only *pray* it flies where
you pointed. The optimization either fires or it doesn't, and when it
doesn't you get a scalar loop and no explanation. A wild dragon.

**Wyve is the rider.** It does not try to *become* the dragon — it doesn't
hand-write the fastest machine code itself. It climbs onto the dragon's back
and steers.

- **The contract is the reins.** `@noalias`, `@vectorize(require)`,
  `@tile`, `@parallel` — each one tells the dragon exactly where to fly.
- **`proven, not promised` is the proof the reins held.** Wyve verifies, for
  every contract, that the dragon actually obeyed: the dependence analysis is
  sound (checked in Lean), and the scheduling transforms are *bitwise-exact*
  — `@tile`, `@interchange`, `@parallel` change the result by not one bit;
  only `@fp(contract)` moves it, and only because you asked. The flight path
  is confirmed, not hoped.

"Promised, not proven" is praying to a wild dragon. "Proven" is the proof
the dragon flew true. No one else has put these reins on LLVM.

## The far side of *fastest*

Wyve's first aim was *"to reach the far side of fastest."* That was never
"faster than BLAS." It is this: **a wild-dragon optimizer gives you speed you
can only hope is correct; a ridden dragon gives you speed whose flight path
is proven.** Raw LLVM is fast-by-prayer. Wyve is fast-with-the-reins-held —
speed and certainty at once. That is the far side: not more velocity, but
velocity you can prove the destination of.

## Why Wyve doesn't brawl with BLAS

Accelerate, BLAS, MKL — and Apple's AMX coprocessor — are **a different
beast**. They live *outside* LLVM: hand-written assembly and intrinsics,
tuned for decades, reaching hardware (AMX) that LLVM can't even emit. They
aren't dragons you ride; they're beasts someone else tamed on the ground.

A rider who climbs down off the dragon to wrestle a different beast bare-
handed on the ground has forgotten what makes him strong. That is what
"beat BLAS at matmul on native" would be — and the measurements said so
plainly (Wyve loses 2.7–14× there). The rider is strongest *on the dragon's
back*.

So the rider does one of two things instead:

- **Where the ground-beast lives (native + Accelerate):** don't wrestle it.
  Point at it from the dragon's back — *let that beast carry this load* —
  and ride the rest (the contracts, the fusion edges, the verification).
  Cooperation, not combat.
- **Where only the dragon flies (WASM, embedded — no BLAS):** this is the
  open sky. Nothing on the ground to wrestle, only the dragon and the wind.
  Here the rider is fastest, and the measurements agree (WASM SIMD128 beats
  the autovectorizer 1.55×).

## The one line

> **Wyve is the rider, not the dragon. It holds the reins on LLVM — and
> proves they held.**

Optimization as a contract, not a prayer. A flight path confirmed, not hoped.
