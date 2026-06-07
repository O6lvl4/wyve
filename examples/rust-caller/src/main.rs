//! Wyve kernels called from Rust. The unsafe surface is two extern decls;
//! the safe wrappers take slices, so the borrow checker proves at the call
//! boundary exactly what the kernel's @noalias contract assumes — Rust
//! closes the last trust gap for free.
use std::time::Instant;

extern "C" {
    fn Naive_matmul(a: *const f32, b: *const f32, c: *mut f32, m: usize, n: usize, k: usize);
    fn Full_matmul(a: *const f32, b: *const f32, c: *mut f32, m: usize, n: usize, k: usize);
}

fn matmul_naive(a: &[f32], b: &[f32], c: &mut [f32], m: usize, n: usize, k: usize) {
    assert_eq!(a.len(), m * k);
    assert_eq!(b.len(), k * n);
    assert_eq!(c.len(), m * n);
    // &mut c cannot alias &a/&b — the borrow checker just proved @noalias
    unsafe { Naive_matmul(a.as_ptr(), b.as_ptr(), c.as_mut_ptr(), m, n, k) }
}

fn matmul_full(a: &[f32], b: &[f32], c: &mut [f32], m: usize, n: usize, k: usize) {
    assert_eq!(a.len(), m * k);
    assert_eq!(b.len(), k * n);
    assert_eq!(c.len(), m * n);
    unsafe { Full_matmul(a.as_ptr(), b.as_ptr(), c.as_mut_ptr(), m, n, k) }
}

fn gflops(s: usize, secs: f64) -> f64 {
    2.0 * (s as f64).powi(3) / secs / 1e9
}

fn main() {
    let s = 1024;
    let a: Vec<f32> = (0..s * s).map(|i| (i % s) as f32 * 1e-4 + 0.5).collect();
    let b: Vec<f32> = (0..s * s).map(|i| (i % s) as f32 * 2e-4 + 0.25).collect();
    let mut c0 = vec![0.0f32; s * s];
    let mut c1 = vec![0.0f32; s * s];

    println!("matmul {s}x{s}, Wyve kernels called from Rust\n");

    let t = Instant::now();
    matmul_naive(&a, &b, &mut c0, s, s, s);
    let naive = t.elapsed().as_secs_f64();
    println!("  naive (no schedule)              {:>7.2} GFLOPS", gflops(s, naive));

    let t = Instant::now();
    matmul_full(&a, &b, &mut c1, s, s, s);
    let full = t.elapsed().as_secs_f64();
    println!("  @parallel @interchange @fp(contract) {:>7.2} GFLOPS   ({:.0}x)",
             gflops(s, full), naive / full);

    let max_rel = c0.iter().zip(&c1)
        .map(|(x, y)| ((x - y) / x.max(1.0)).abs())
        .fold(0.0f32, f32::max);
    println!("\n  results agree within {max_rel:.2e} (FMA tolerance)");
}
