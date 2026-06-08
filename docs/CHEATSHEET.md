# Wyve Cheatsheet

Everything the language is, on one page. Wyve writes numeric **kernels** —
naive loops with **contracts** that the compiler proves and lowers to LLVM.
Grammar is Objective-C; there is no runtime.

## File shape

```objc
@interface Name                    // the contract surface
@effect(reads(x), writes(y))
@vectorize(require, width: 8)
+ (void)kernel:(float)a
             x:(@noalias const float *)x
             y:(@noalias float *)y
         count:(usize)n;
@end

@implementation Name               // checked against the @interface
+ (void)kernel:(float)a ... { ... }
@end
```

Kernels are class methods (`+`). The selector (`kernel:x:y:count:`) names
the kernel; it mangles to `Name_kernel` in the C ABI.

## Types

| Type | LLVM | Notes |
| --- | --- | --- |
| `float` / `double` | `float` / `double` | f32 / f64 |
| `usize` / `int` | `i64` / `i32` | unsigned index / signed value |
| `floatN` (N∈2,4,8,16) | `<N x float>` | vector locals, `@simd` only |
| `T *`, `const T *` | `ptr` | pointer parameters |

Literals: `1.0f` is float, `1.0` is double, a bare integer is `usize` or
`int` by context (`c[i] = c[i] + 1` puts `1` in `int` because `c` is).

## Expressions

```
a + b   a - b   a * b   a / b   a % b   -a    arithmetic (same type)
a < b   <=  >   >=  ==  !=                comparison (-> bool, for if/loops)
x[i]                                       pointer subscript (i is usize)
min(a,b) max(a,b) abs(x) sqrt(x) fma(a,b,c)  math builtins -> LLVM intrinsics
```

`@simd` only:
```
a[i : N]              slice load  -> floatN
shuffle(a, b, i0, …)  lane permutation -> LLVM shufflevector
cmul(x, y)            complex multiply, SoA [re… im…]
```

## Statements

```objc
float t = a * x[i];                    // local (must be initialized)
y[i] = a * x[i];                       // store
acc += x[i];                           // compound assign
for (usize i = 0; i < n; i++) { … }    // unit-stride loop
if (x[i] > 0.0f) { … } else { … }      // branch
[Other kern:a x:x y:y count:n];        // call another (void) kernel
return acc;                            // return (non-void kernels)
b[i : N] = v;                          // slice store (@simd)
```

## Contracts

**Alias / effect**
```objc
@noalias              // this pointer aliases nothing else (proven, even across calls)
@effect(reads(x), writes(y))   // checked against every access in the body
```

**Layout / emission**
```objc
@checked              // integer overflow & runtime div-by-zero trap (defined, not UB)
@bounds(x: n)         // x holds n elements — every x[i] is PROVEN in range (WVN070)
@align(64)            // pointer alignment promise (parameter qualifier)
@stream               // write-only stores bypass cache (nontemporal)
```

**Optimizer control (verified against LLVM's reply)**
```objc
@vectorize(require, width: 8, interleave: 4, predicate, scalable)
@vectorize(disable)                 // must stay scalar
@unroll(require, count: 4)
@fp(reassoc | contract | nsz | arcp | afn | nnan | ninf)   // grant one at a time
```

**Scheduling above LLVM (proven legal, applied by wyvec)**
```objc
@tile(i: 64, j: 64)                 // strip-mine + interchange (perfect nest)
@interchange(p, j)                  // scalar expansion + interchange (reductions)
@parallel(i)                        // dispatch iterations across cores
```

**Data-parallel**
```objc
@batch(8)             // write one signal's scalar kernel; wyvec widens
                      // every op to a float8 across 8 signals (signal-major)
```

**Explicit vectors**
```objc
@vectorize(manual, width: 8)        // wyvec emits the vector loop itself
@simd                               // straight-line vector code (slice/shuffle/cmul)
```

## CLI

```console
$ racket -l wyve/cli -- check <file.wyv>    # verify contracts
$ racket -l wyve/cli -- build <file.wyv>    # emit LLVM IR (-o out.ll)
$ racket -l wyve/cli -- talk  <file.wyv>    # converse with the optimizer
$ racket -l wyve/cli -- run   <file.wyv>    # talk, then execute on LLVM
$ racket -l wyve/cli -- tune  <file.wyv>    # search schedules, suggest the best
$ racket <file.wyv>                         # #lang wyve: run directly
```

REPL (`(require wyve/repl)`):
```racket
(wyve-load "k.wyv")
(ask)                                  ; full conversation with LLVM
(ask #:without-noalias '("x") #:force #t)  ; retract a contract, ask anyway
(ask #:width 4 #:interleave 8)             ; twist knobs, listen
(tune)                                     ; sweep schedules
```

## Diagnostics

Rejections carry a `WVN…` code — see [DIAGNOSTICS.md](DIAGNOSTICS.md). The
`examples/invalid/` directory is normative: every file there must be
rejected with the code its header documents.
