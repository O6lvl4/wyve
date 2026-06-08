// Same seam as wasm-scale: AlmideMatrix::SmallF32 ABI, Wyve kernel via extern C.
// Here: 8x8 transpose (Wyve's shuffle network) vs Almide's naive transpose.
use std::env;

enum AlmideMatrix { SmallF32 { rows: usize, cols: usize, data: Vec<f32> } }

extern "C" { fn Transpose_t8(a: *const f32, b: *mut f32); }  // 8x8 fixed

fn transpose_wyve(m: &AlmideMatrix) -> AlmideMatrix {
    match m {
        AlmideMatrix::SmallF32 { rows, cols, data } => {
            let mut out = vec![0.0f32; 64];
            unsafe { Transpose_t8(data.as_ptr(), out.as_mut_ptr()); }
            AlmideMatrix::SmallF32 { rows: *cols, cols: *rows, data: out }
        }
    }
}

fn transpose_almide(m: &AlmideMatrix) -> AlmideMatrix {
    match m {
        AlmideMatrix::SmallF32 { rows, cols, data } => {
            let (r, c) = (*rows, *cols);
            let mut out = vec![0.0f32; r * c];
            for i in 0..r { for j in 0..c { out[j * r + i] = data[i * c + j]; } }
            AlmideMatrix::SmallF32 { rows: c, cols: r, data: out }
        }
    }
}

fn data_of(m: &AlmideMatrix) -> &Vec<f32> { match m { AlmideMatrix::SmallF32 { data, .. } => data } }

fn main() {
    let mode = env::args().nth(1).unwrap_or_else(|| "diff".into());
    let data: Vec<f32> = (0..64).map(|i| i as f32).collect();
    let m = AlmideMatrix::SmallF32 { rows: 8, cols: 8, data };
    match mode.as_str() {
        "diff" => {
            let w = transpose_wyve(&m);
            let a = transpose_almide(&m);
            let same = data_of(&w).iter().zip(data_of(&a)).all(|(x, y)| x == y);
            println!("Wyve transpose vs Almide: {}", if same { "IDENTICAL" } else { "MISMATCH" });
        }
        "wyve"   => { let mut s=0.0f32; for _ in 0..3_000_000 { let r=transpose_wyve(&m); s+=data_of(&r)[1]; } println!("wyve sink={}",s); }
        "almide" => { let mut s=0.0f32; for _ in 0..3_000_000 { let r=transpose_almide(&m); s+=data_of(&r)[1]; } println!("almide sink={}",s); }
        _ => {}
    }
}
