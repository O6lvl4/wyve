mod ast;
mod codegen;
mod diag;
mod lexer;
mod parser;
mod sema;

use std::process::ExitCode;

const USAGE: &str = "usage: wyvec <build|check> <file.wyv> [-o <out.ll>]\n";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(msg) => {
            eprint!("{}", msg);
            ExitCode::FAILURE
        }
    }
}

fn run(args: &[String]) -> Result<(), String> {
    let (cmd, rest) = args.split_first().ok_or_else(|| USAGE.to_string())?;
    if cmd != "build" && cmd != "check" {
        return Err(USAGE.into());
    }
    let mut file = None;
    let mut out_path = None;
    let mut it = rest.iter();
    while let Some(a) = it.next() {
        if a == "-o" {
            out_path = Some(it.next().ok_or("error: missing path after -o\n")?.clone());
        } else if file.is_none() {
            file = Some(a.clone());
        } else {
            return Err(USAGE.into());
        }
    }
    let file = file.ok_or_else(|| USAGE.to_string())?;
    let src = std::fs::read_to_string(&file).map_err(|e| format!("error: cannot read {}: {}\n", file, e))?;

    let toks = lexer::lex(&src).map_err(|d| d.render(&file))?;
    let module = parser::parse(toks).map_err(|d| d.render(&file))?;
    let kernels = sema::check(&module)
        .map_err(|ds| ds.iter().map(|d| d.render(&file)).collect::<Vec<_>>().join(""))?;

    if cmd == "check" {
        println!("ok: {} kernel(s), contracts verified", kernels.len());
        return Ok(());
    }

    let src_name = std::path::Path::new(&file)
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| file.clone());
    let ir = codegen::emit(&src_name, &kernels);
    match out_path {
        Some(p) => std::fs::write(&p, ir).map_err(|e| format!("error: cannot write {}: {}\n", p, e))?,
        None => print!("{}", ir),
    }
    Ok(())
}
