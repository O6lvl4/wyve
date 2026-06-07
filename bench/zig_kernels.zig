// The opponent. Two tiers per kernel:
//   zig_*       — idiomatic Zig: what real code looks like. No noalias, no
//                 float-mode pragmas, because nothing checks them and lying
//                 is UB. This is the tier Wyve's thesis targets.
//   zig_*_tuned — Zig with the unchecked annotations dialed up by hand:
//                 noalias parameters, @setFloatMode(.optimized). The honest
//                 strong baseline.
// Compiled with -O ReleaseFast, native CPU (same as the Wyve side's clang).

export fn zig_saxpy(a: f32, x: [*]const f32, y: [*]f32, n: usize) void {
    for (0..n) |i| y[i] = a * x[i] + y[i];
}

export fn zig_saxpy_tuned(a: f32, noalias x: [*]const f32, noalias y: [*]f32, n: usize) void {
    for (0..n) |i| y[i] = a * x[i] + y[i];
}

export fn zig_sum(x: [*]const f32, n: usize) f32 {
    var acc: f32 = 0;
    for (0..n) |i| acc += x[i];
    return acc;
}

export fn zig_sum_tuned(x: [*]const f32, n: usize) f32 {
    @setFloatMode(.optimized);
    var acc: f32 = 0;
    for (0..n) |i| acc += x[i];
    return acc;
}

export fn zig_blur3(src: [*]const f32, dst: [*]f32, n: usize) void {
    var i: usize = 1;
    while (i + 1 < n) : (i += 1) {
        dst[i] = (src[i - 1] + src[i] + src[i + 1]) * (1.0 / 3.0);
    }
}

export fn zig_blur3_tuned(noalias src: [*]const f32, noalias dst: [*]f32, n: usize) void {
    var i: usize = 1;
    while (i + 1 < n) : (i += 1) {
        dst[i] = (src[i - 1] + src[i] + src[i + 1]) * (1.0 / 3.0);
    }
}

//   zig_*_simd  — Zig at its strongest: hand-written @Vector SIMD. This is
//                 rung (b) of the ladder; nothing is left on the table.

export fn zig_saxpy_simd(a: f32, noalias x: [*]const f32, noalias y: [*]f32, n: usize) void {
    const V = @Vector(8, f32);
    const av: V = @splat(a);
    var i: usize = 0;
    while (i + 8 <= n) : (i += 8) {
        const xv: V = x[i..][0..8].*;
        const yv: V = y[i..][0..8].*;
        y[i..][0..8].* = av * xv + yv;
    }
    while (i < n) : (i += 1) y[i] = a * x[i] + y[i];
}

export fn zig_sum_simd(x: [*]const f32, n: usize) f32 {
    const V = @Vector(8, f32);
    var acc0: V = @splat(0);
    var acc1: V = @splat(0);
    var acc2: V = @splat(0);
    var acc3: V = @splat(0);
    var i: usize = 0;
    while (i + 32 <= n) : (i += 32) {
        acc0 += @as(V, x[i..][0..8].*);
        acc1 += @as(V, x[i + 8 ..][0..8].*);
        acc2 += @as(V, x[i + 16 ..][0..8].*);
        acc3 += @as(V, x[i + 24 ..][0..8].*);
    }
    var s = @reduce(.Add, (acc0 + acc1) + (acc2 + acc3));
    while (i < n) : (i += 1) s += x[i];
    return s;
}

export fn zig_matmul(noalias a: [*]const f32, noalias b: [*]const f32, noalias c: [*]f32, m: usize, n: usize, k: usize) void {
    for (0..m) |i| {
        for (0..n) |j| {
            var acc: f32 = 0;
            for (0..k) |p| acc += a[i * k + p] * b[p * n + j];
            c[i * n + j] = acc;
        }
    }
}

// the human rewrites the loops by hand to tile — Wyve's @tile does this
// as one verified contract line on the naive source
export fn zig_matmul_tiled(noalias a: [*]const f32, noalias b: [*]const f32, noalias c: [*]f32, m: usize, n: usize, k: usize) void {
    const T = 64;
    var ii: usize = 0;
    while (ii < m) : (ii += T) {
        var jj: usize = 0;
        while (jj < n) : (jj += T) {
            const iend = @min(ii + T, m);
            const jend = @min(jj + T, n);
            for (ii..iend) |i| {
                for (jj..jend) |j| {
                    var acc: f32 = 0;
                    for (0..k) |p| acc += a[i * k + p] * b[p * n + j];
                    c[i * n + j] = acc;
                }
            }
        }
    }
}

// the ikj schedule, hand-rewritten (what @interchange(p, j) does to the
// naive source automatically, with a proof)
export fn zig_matmul_ikj(noalias a: [*]const f32, noalias b: [*]const f32, noalias c: [*]f32, m: usize, n: usize, k: usize) void {
    for (0..m) |i| {
        for (0..n) |j| c[i * n + j] = 0;
        for (0..k) |p| {
            const ap = a[i * k + p];
            for (0..n) |j| c[i * n + j] += ap * b[p * n + j];
        }
    }
}

export fn zig_blur3_simd(noalias src: [*]const f32, noalias dst: [*]f32, n: usize) void {
    if (n < 3) return;
    const V = @Vector(8, f32);
    const k: V = @splat(1.0 / 3.0);
    var i: usize = 1;
    while (i + 8 <= n - 1) : (i += 8) {
        const a: V = src[i - 1 ..][0..8].*;
        const b: V = src[i..][0..8].*;
        const c: V = src[i + 1 ..][0..8].*;
        dst[i..][0..8].* = (a + b + c) * k;
    }
    while (i + 1 < n) : (i += 1) {
        dst[i] = (src[i - 1] + src[i] + src[i + 1]) * (1.0 / 3.0);
    }
}
