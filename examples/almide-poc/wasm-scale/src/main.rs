// Mirrors Almide's runtime: AlmideMatrix::SmallF32 { rows, cols, data: Vec<f32> }.
// Wyve's scale kernel is linked in (extern C), called through the same ABI.
use std::env;

enum AlmideMatrix { SmallF32 { rows: usize, cols: usize, data: Vec<f32> } }

extern "C" {
    // Wyve: out[i] = a * x[i], SIMD128. count is i64 in Wyve IR -> u64.
    fn WyveScale_scale(a: f32, x: *const f32, y: *mut f32, n: u64);
}

// the seam: AlmideMatrix in, Wyve kernel, AlmideMatrix out
fn scale_wyve(m: &AlmideMatrix, s: f32) -> AlmideMatrix {
    match m {
        AlmideMatrix::SmallF32 { rows, cols, data } => {
            let n = data.len();
            let mut out = vec![0.0f32; n];
            unsafe { WyveScale_scale(s, data.as_ptr(), out.as_mut_ptr(), n as u64); }
            AlmideMatrix::SmallF32 { rows: *rows, cols: *cols, data: out }
        }
    }
}

// Almide's own scale (the fallback / reference): out[i] = data[i] * s
fn scale_almide(m: &AlmideMatrix, s: f32) -> AlmideMatrix {
    match m {
        AlmideMatrix::SmallF32 { rows, cols, data } => {
            let out: Vec<f32> = data.iter().map(|&x| x * s).collect();
            AlmideMatrix::SmallF32 { rows: *rows, cols: *cols, data: out }
        }
    }
}

fn data_of(m: &AlmideMatrix) -> &Vec<f32> { match m { AlmideMatrix::SmallF32 { data, .. } => data } }

fn main() {
    let mode = env::args().nth(1).unwrap_or_else(|| "diff".into());
    let n = 8192usize;
    let data: Vec<f32> = (0..n).map(|i| (i % 100) as f32 * 0.01).collect();
    let m = AlmideMatrix::SmallF32 { rows: 1, cols: n, data };
    match mode.as_str() {
        "diff" => {
            let w = scale_wyve(&m, 2.5);
            let a = scale_almide(&m, 2.5);
            let same = data_of(&w).iter().zip(data_of(&a)).all(|(x, y)| x == y);
            println!("Wyve seam vs Almide scale: {}", if same { "IDENTICAL" } else { "MISMATCH" });
        }
        "wyve" => {
            let mut acc = 0.0f32;
            for _ in 0..200_000 { let r = scale_wyve(&m, 1.0000001); acc += data_of(&r)[0]; }
            println!("wyve sink={}", acc);
        }
        "almide" => {
            let mut acc = 0.0f32;
            for _ in 0..200_000 { let r = scale_almide(&m, 1.0000001); acc += data_of(&r)[0]; }
            println!("almide sink={}", acc);
        }
        _ => println!("usage: diff | wyve | almide"),
    }
}
