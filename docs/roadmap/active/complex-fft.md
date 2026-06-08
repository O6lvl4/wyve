<!-- description: @simd to a real FFT — complex (interleaved re/im) arithmetic and float8/16 networks -->
# Complex FFT

@simd has the real moving parts: shuffle (permutation), floatN arithmetic,
scalar broadcast (twiddle).

**Found: complex multiply needs nothing new.** With a structure-of-arrays
layout in a float4 — [re0 re1 im0 im1] — the complex product is shuffles +
vector mul/add/sub, already expressible. examples/complex-mul.wyv is
normative and verified ((1+2i)(3+4i) = -5+10i). The twiddle that drives
every butterfly is exactly this.

The reach to a full FFT from here:

- a `cmul(x, y)` helper so the broadcasting shuffles aren't spelled out by
  hand each time (sugar over what already works).
- float8 / float16 networks for radix-4/8 and wider transforms.
- a composed transform (butterflies + bit-reversal) as a normative example,
  benchmarked against a scalar FFT.

The hard part — that @simd can express the math an FFT needs — is done.
What remains is ergonomics and scale.
