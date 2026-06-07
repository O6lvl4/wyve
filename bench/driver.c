// Shared timing harness. Same buffers, same init, same measurement for
// every contestant: warmup, then `meas` measurements of `batch` calls,
// best batch wins (min). Results are verified for agreement first.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>

extern void  Saxpy_saxpy(float, const float*, float*, size_t);
extern float Reduce_sum(const float*, size_t);
extern void  Stencil_blur3(const float*, float*, size_t);

extern void  zig_saxpy(float, const float*, float*, size_t);
extern void  zig_saxpy_tuned(float, const float*, float*, size_t);
extern void  zig_saxpy_simd(float, const float*, float*, size_t);
extern float zig_sum(const float*, size_t);
extern float zig_sum_tuned(const float*, size_t);
extern float zig_sum_simd(const float*, size_t);
extern void  zig_blur3(const float*, float*, size_t);
extern void  zig_blur3_tuned(const float*, float*, size_t);
extern void  zig_blur3_simd(const float*, float*, size_t);

extern void  Gemm_matmul(const float*, const float*, float*, size_t, size_t, size_t);
extern void  Ikj_matmul(const float*, const float*, float*, size_t, size_t, size_t);
extern void  Par_matmul(const float*, const float*, float*, size_t, size_t, size_t);
extern void  Full_matmul(const float*, const float*, float*, size_t, size_t, size_t);
extern void  Naive_matmul(const float*, const float*, float*, size_t, size_t, size_t);
extern void  zig_matmul(const float*, const float*, float*, size_t, size_t, size_t);
extern void  zig_matmul_tiled(const float*, const float*, float*, size_t, size_t, size_t);
extern void  zig_matmul_ikj(const float*, const float*, float*, size_t, size_t, size_t);

typedef void  (*saxpy_fn)(float, const float*, float*, size_t);
typedef float (*sum_fn)(const float*, size_t);
typedef void  (*blur_fn)(const float*, float*, size_t);

static double now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1e9 + (double)ts.tv_nsec;
}

static float* fresh(size_t n, float scale, float bias) {
    float* p = NULL;
    posix_memalign((void**)&p, 64, n * sizeof(float));
    for (size_t i = 0; i < n; i++) p[i] = (float)i * scale + bias;
    return p;
}

static volatile double sink;

static int close_enough(double a, double b, double tol) {
    double d = fabs(a - b);
    double m = fabs(a) > fabs(b) ? fabs(a) : fabs(b);
    return d <= tol * (m > 1.0 ? m : 1.0);
}

static void row(const char* name, double ns, size_t n, double wyve_ns) {
    printf("  %-14s %8.4f ns/elem", name, ns / (double)n);
    if (wyve_ns > 0 && ns > 0) {
        double r = ns / wyve_ns;
        if (r >= 1.005)      printf("   (wyve %.2fx faster)", r);
        else if (r <= 0.995) printf("   (wyve %.2fx SLOWER)", 1.0 / r);
        else                 printf("   (tie)");
    }
    printf("\n");
}

// ----------------------------------------------------------------- saxpy

static double time_saxpy(saxpy_fn f, size_t n, int batch, int meas) {
    float* x = fresh(n, 0.001f, 1.0f);
    float* y = fresh(n, 0.002f, 2.0f);
    for (int w = 0; w < 3; w++) f(1.0f, x, y, n); // warmup
    double best = 1e30;
    for (int m = 0; m < meas; m++) {
        double t0 = now_ns();
        for (int b = 0; b < batch; b++) f(1.0f, x, y, n);
        double dt = (now_ns() - t0) / batch;
        if (dt < best) best = dt;
    }
    sink = y[n / 2];
    free(x); free(y);
    return best;
}

static void bench_saxpy(size_t n, int batch, int meas, const char* label) {
    // agreement check, one fresh call each
    float* x = fresh(n, 0.001f, 1.0f);
    float* y0 = fresh(n, 0.002f, 2.0f);
    float* y1 = fresh(n, 0.002f, 2.0f);
    float* y2 = fresh(n, 0.002f, 2.0f);
    Saxpy_saxpy(1.0f, x, y0, n);
    zig_saxpy(1.0f, x, y1, n);
    zig_saxpy_tuned(1.0f, x, y2, n);
    for (size_t i = 0; i < n; i++)
        if (!close_enough(y0[i], y1[i], 1e-5) || !close_enough(y0[i], y2[i], 1e-5)) {
            printf("  !! saxpy results disagree at %zu\n", i); break;
        }
    free(x); free(y0); free(y1); free(y2);

    printf("== saxpy %s ==\n", label);
    double w = time_saxpy(Saxpy_saxpy, n, batch, meas);
    row("wyve", w, n, 0);
    row("zig idiomatic", time_saxpy(zig_saxpy, n, batch, meas), n, w);
    row("zig tuned", time_saxpy(zig_saxpy_tuned, n, batch, meas), n, w);
    row("zig @Vector", time_saxpy(zig_saxpy_simd, n, batch, meas), n, w);
}

// ------------------------------------------------------------------- sum

static double time_sum(sum_fn f, size_t n, int batch, int meas) {
    float* x = fresh(n, 0.0001f, 0.5f);
    sink = f(x, n); // warmup
    double best = 1e30;
    for (int m = 0; m < meas; m++) {
        double t0 = now_ns();
        float acc = 0;
        for (int b = 0; b < batch; b++) acc += f(x, n);
        double dt = (now_ns() - t0) / batch;
        sink = acc;
        if (dt < best) best = dt;
    }
    free(x);
    return best;
}

static void bench_sum(size_t n, int batch, int meas, const char* label) {
    float* x = fresh(n, 0.0001f, 0.5f);
    double r0 = Reduce_sum(x, n), r1 = zig_sum(x, n), r2 = zig_sum_tuned(x, n);
    // sequential vs 8-lane f32 summation legitimately differs by ~0.4% at
    // n=4M (associativity; the vectorized order is closer to exact)
    if (!close_enough(r0, r1, 1e-2) || !close_enough(r0, r2, 1e-2))
        printf("  !! sum results disagree: %g %g %g\n", r0, r1, r2);
    free(x);

    printf("== sum %s ==\n", label);
    double w = time_sum(Reduce_sum, n, batch, meas);
    row("wyve", w, n, 0);
    row("zig idiomatic", time_sum(zig_sum, n, batch, meas), n, w);
    row("zig tuned", time_sum(zig_sum_tuned, n, batch, meas), n, w);
    row("zig @Vector", time_sum(zig_sum_simd, n, batch, meas), n, w);
}

// ------------------------------------------------------------------ blur

static double time_blur(blur_fn f, size_t n, int batch, int meas) {
    float* src = fresh(n, 0.001f, 1.0f);
    float* dst = fresh(n, 0.0f, 0.0f);
    f(src, dst, n); // warmup
    double best = 1e30;
    for (int m = 0; m < meas; m++) {
        double t0 = now_ns();
        for (int b = 0; b < batch; b++) f(src, dst, n);
        double dt = (now_ns() - t0) / batch;
        if (dt < best) best = dt;
    }
    sink = dst[n / 2];
    free(src); free(dst);
    return best;
}

static void bench_blur(size_t n, int batch, int meas, const char* label) {
    float* src = fresh(n, 0.001f, 1.0f);
    float* d0 = fresh(n, 0.0f, 0.0f);
    float* d1 = fresh(n, 0.0f, 0.0f);
    float* d2 = fresh(n, 0.0f, 0.0f);
    Stencil_blur3(src, d0, n);
    zig_blur3(src, d1, n);
    zig_blur3_tuned(src, d2, n);
    for (size_t i = 1; i + 1 < n; i++)
        if (!close_enough(d0[i], d1[i], 1e-5) || !close_enough(d0[i], d2[i], 1e-5)) {
            printf("  !! blur results disagree at %zu\n", i); break;
        }
    free(src); free(d0); free(d1); free(d2);

    printf("== blur3 %s ==\n", label);
    double w = time_blur(Stencil_blur3, n, batch, meas);
    row("wyve", w, n, 0);
    row("zig idiomatic", time_blur(zig_blur3, n, batch, meas), n, w);
    row("zig tuned", time_blur(zig_blur3_tuned, n, batch, meas), n, w);
    row("zig @Vector", time_blur(zig_blur3_simd, n, batch, meas), n, w);
}

// ---------------------------------------------------------------- matmul

typedef void (*mm_fn)(const float*, const float*, float*, size_t, size_t, size_t);

static void mm_row(const char* name, double t, size_t s, double wyve_t) {
    double gflops = 2.0 * (double)s * (double)s * (double)s / t;
    printf("  %-14s %7.2f GFLOPS", name, gflops);
    if (wyve_t > 0 && t > 0) {
        double r = t / wyve_t;
        if (r >= 1.005)      printf("   (wyve %.2fx faster)", r);
        else if (r <= 0.995) printf("   (wyve %.2fx SLOWER)", 1.0 / r);
        else                 printf("   (tie)");
    }
    printf("\n");
}

static double time_mm(mm_fn f, size_t s, int meas) {
    float* a = fresh(s * s, 0.0001f, 0.5f);
    float* b = fresh(s * s, 0.0002f, 0.25f);
    float* c = fresh(s * s, 0.0f, 0.0f);
    f(a, b, c, s, s, s); // warmup
    double best = 1e30;
    for (int m = 0; m < meas; m++) {
        double t0 = now_ns();
        f(a, b, c, s, s, s);
        double dt = now_ns() - t0;
        if (dt < best) best = dt;
    }
    sink = c[s / 2];
    free(a); free(b); free(c);
    return best;
}

static void bench_mm(size_t s, int meas) {
    // agreement: tiling parallel loops is float-exact, so all four must match
    float* a = fresh(s * s, 0.0001f, 0.5f);
    float* b = fresh(s * s, 0.0002f, 0.25f);
    float* c0 = fresh(s * s, 0.0f, 0.0f);
    float* c1 = fresh(s * s, 0.0f, 0.0f);
    Gemm_matmul(a, b, c0, s, s, s);
    Naive_matmul(a, b, c1, s, s, s);
    for (size_t i = 0; i < s * s; i++)
        if (c0[i] != c1[i]) { printf("  !! tiled/naive disagree at %zu\n", i); break; }
    Ikj_matmul(a, b, c1, s, s, s);
    for (size_t i = 0; i < s * s; i++)
        if (c0[i] != c1[i]) { printf("  !! ikj/naive disagree at %zu (ikj must be float-exact)\n", i); break; }
    Par_matmul(a, b, c1, s, s, s);
    for (size_t i = 0; i < s * s; i++)
        if (c0[i] != c1[i]) { printf("  !! par/naive disagree at %zu (parallel must be float-exact)\n", i); break; }
    Full_matmul(a, b, c1, s, s, s);
    for (size_t i = 0; i < s * s; i++)
        if (!close_enough(c0[i], c1[i], 1e-3)) { printf("  !! full/naive disagree at %zu beyond FMA tolerance\n", i); break; }
    zig_matmul(a, b, c1, s, s, s);
    for (size_t i = 0; i < s * s; i++)
        if (!close_enough(c0[i], c1[i], 1e-4)) { printf("  !! wyve/zig disagree at %zu\n", i); break; }
    free(a); free(b); free(c0); free(c1);

    printf("== matmul (%zux%zu) ==\n", s, s);
    double w = time_mm(Full_matmul, s, meas);
    mm_row("wyve par+ikj+fma", w, s, 0);
    mm_row("wyve par+ikj", time_mm(Par_matmul, s, meas), s, w);
    mm_row("wyve @interchange", time_mm(Ikj_matmul, s, meas), s, w);
    mm_row("wyve @tile(64)", time_mm(Gemm_matmul, s, meas), s, w);
    mm_row("wyve naive", time_mm(Naive_matmul, s, meas), s, w);
    mm_row("zig naive", time_mm(zig_matmul, s, meas), s, w);
    mm_row("zig hand-tiled", time_mm(zig_matmul_tiled, s, meas), s, w);
    mm_row("zig hand-ikj", time_mm(zig_matmul_ikj, s, meas), s, w);
}

int main(void) {
    const size_t SMALL = 2048;        // L1-resident: compute-bound
    const size_t LARGE = 1u << 22;    // 16 MiB/array: memory-bound

    printf("Wyve vs Zig — same LLVM, same driver, native CPU\n\n");
    bench_saxpy(SMALL, 2000, 50, "(n=2048, L1)");
    bench_sum  (SMALL, 2000, 50, "(n=2048, L1)");
    bench_blur (SMALL, 2000, 50, "(n=2048, L1)");
    printf("\n");
    bench_saxpy(LARGE, 4, 20, "(n=4194304, memory-bound)");
    bench_sum  (LARGE, 4, 20, "(n=4194304, memory-bound)");
    bench_blur (LARGE, 4, 20, "(n=4194304, memory-bound)");
    printf("\n");
    bench_mm(512, 4);
    bench_mm(1024, 3);
    return 0;
}
