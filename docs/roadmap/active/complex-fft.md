<!-- description: @simd to a real FFT — complex (interleaved re/im) arithmetic and float8/16 networks -->
# Complex FFT

@simd has the real moving parts: shuffle (permutation), floatN arithmetic,
scalar broadcast (twiddle) — a real-valued radix-2 butterfly runs and
verifies. The reach to a real FFT:

- complex lanes (interleaved re/im in a floatN), so a twiddle multiply is
  the complex product, not a scalar scale — needs a small grammar addition
  (a complex-multiply helper, or shuffle+arith spelled out).
- float8 / float16 networks for radix-4/8 and wider transforms.
- a composed transform (butterflies + bit-reversal) as a normative example,
  benchmarked against a scalar FFT.

This is the proof that @simd reaches a workload people actually run, not
just a kernel-shaped demo.
