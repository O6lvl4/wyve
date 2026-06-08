use std::process::Command;
use std::env;
fn main() {
    let out = env::var("OUT_DIR").unwrap();
    let here = env::var("CARGO_MANIFEST_DIR").unwrap();
    let target = env::var("TARGET").unwrap_or_default();
    let clang = "/usr/local/opt/llvm/bin/clang";
    let ar    = "/usr/local/opt/llvm/bin/llvm-ar";
    let ll = format!("{}/scale.ll", out);
    let obj = format!("{}/scale.o", out);
    let s = Command::new("racket")
        .args(["-l","wyve/cli","--","build",&format!("{}/scale.wyv",here),"-o",&ll])
        .status().expect("wyvec"); assert!(s.success());
    let mut cc = Command::new(clang);
    if target.contains("wasm32") {
        cc.args(["-target","wasm32-wasi","-msimd128","-O2","-Wno-override-module","-c",&ll,"-o",&obj]);
    } else {
        cc.args(["-O2","-march=native","-Wno-override-module","-c",&ll,"-o",&obj]);
    }
    assert!(cc.status().expect("clang").success());
    Command::new(ar).args(["crs",&format!("{}/libscale.a",out),&obj]).status().unwrap();
    println!("cargo:rustc-link-search=native={}", out);
    println!("cargo:rustc-link-lib=static=scale");
    println!("cargo:rerun-if-changed={}/scale.wyv", here);
}
