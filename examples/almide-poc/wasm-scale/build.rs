use std::process::Command;
use std::env;
fn main() {
    let out = env::var("OUT_DIR").unwrap();
    let here = env::var("CARGO_MANIFEST_DIR").unwrap();
    let clang = "/usr/local/opt/llvm/bin/clang";
    let ar    = "/usr/local/opt/llvm/bin/llvm-ar";
    let ll = format!("{}/scale.ll", out);
    let obj = format!("{}/scale.o", out);
    let s = Command::new("racket")
        .args(["-l","wyve/cli","--","build",&format!("{}/scale.wyv",here),"-o",&ll])
        .status().expect("wyvec"); assert!(s.success());
    // LLVM clang: opt (vectorize) + llc, emits SIMD128 + LLVM wasm object
    let s = Command::new(clang)
        .args(["-target","wasm32-wasi","-msimd128","-O2","-Wno-override-module","-c",&ll,"-o",&obj])
        .status().expect("clang"); assert!(s.success());
    Command::new(ar).args(["crs",&format!("{}/libscale.a",out),&obj]).status().unwrap();
    println!("cargo:rustc-link-search=native={}", out);
    println!("cargo:rustc-link-lib=static=scale");
    println!("cargo:rerun-if-changed={}/scale.wyv", here);
}
