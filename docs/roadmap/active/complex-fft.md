<!-- description: @simd to a real FFT — complex (interleaved re/im) arithmetic and float8/16 networks -->
# Complex FFT

@simd has the real moving parts: shuffle (permutation), floatN arithmetic,
scalar broadcast (twiddle).

**Found: complex multiply needs nothing new.** With a structure-of-arrays
layout in a float4 — [re0 re1 im0 im1] — the complex product is shuffles +
vector mul/add/sub, already expressible. examples/complex-mul.wyv is
normative and verified ((1+2i)(3+4i) = -5+10i). The twiddle that drives
every butterfly is exactly this.

**Done: the `cmul` builtin.** `cmul(x, y)` complex-multiplies the lanes of
an even-width vector (SoA, real then imaginary halves), expanding to the
broadcast-shuffle + mul/add/sub network. complex-mul.wyv is now a one-liner,
verified ((1+2i)(3+4i) = -5+10i).

**Done: the FFT core.** examples/fft-butterfly.wyv is a twiddled radix-2
butterfly — `out0 = a + w·b`, `out1 = a − w·b` — built from `cmul` + shuffle
+ vector add/sub, verified exact (a=1+2i, b=3+4i, w=i → −3+5i, 5−1i). This is
the operation every FFT is composed from.

The reach to a full N-point FFT from here:

- compose butterflies across stages with kernel calls (`[Butterfly bf:…]`),
  threading a twiddle table and a bit-reversal permutation.
- float8 / float16 networks for radix-4/8 and wider butterflies.
- the composed transform as a normative example, benchmarked against a
  scalar FFT.

The hard part — that @simd can express the math an FFT needs, exactly — is
done. What remains is composition and scale.
