mod ast;
mod vm;
mod lexer;
mod parser;
mod qbe;

use std::env;
use std::fs;
use std::process;

fn main() {
    let args: Vec<String> = env::args().collect();

    match args.as_slice() {
        [_, path] => {
            run_interpreter(path);
        }
        [_, mode, path] if mode == "qbe" => {
            run_qbe(path, false);
        }
        [_, mode, path, flag] if mode == "qbe" && (flag == "-c" || flag == "--compile") => {
            run_qbe(path, true);
        }
        _ => {
            eprintln!("Usage:");
            eprintln!("  bear <file.bear>                  Run via interpreter");
            eprintln!("  bear qbe <file.bear>              Emit QBE IR");
            eprintln!("  bear qbe <file.bear> -c           Compile with QBE");
            process::exit(1);
        }
    }
}

fn load(path: &str) -> ast::Program {
    let src = fs::read_to_string(path).unwrap_or_else(|e| {
        eprintln!("Error reading {path}: {e}");
        process::exit(1);
    });
    let tokens = lexer::tokenize(&src).unwrap_or_else(|e| {
        eprintln!("Lex error: {e}");
        process::exit(1);
    });
    parser::parse(tokens).unwrap_or_else(|e| {
        eprintln!("Parse error: {e}");
        process::exit(1);
    })
}

fn run_interpreter(path: &str) {
    let program = load(path);
    vm::run(&program).unwrap_or_else(|e| {
        eprintln!("Runtime error: {e}");
        process::exit(1);
    });
}

fn run_qbe(path: &str, compile: bool) {
    let program = load(path);
    let ir = qbe::emit(&program).unwrap_or_else(|e| {
        eprintln!("Codegen error: {e}");
        process::exit(1);
    });

    if !compile {
        println!("{ir}");
        return;
    }

    let stem = std::path::Path::new(path)
        .file_stem()
        .unwrap()
        .to_string_lossy();
    let ir_path = format!("/tmp/{stem}.ssa");
    let asm_path = format!("/tmp/{stem}.s");
    let out_path = format!("./{stem}");

    fs::write(&ir_path, &ir).unwrap_or_else(|e| {
        eprintln!("Failed to write IR: {e}");
        process::exit(1);
    });

    let status = process::Command::new("qbe")
        .args(["-o", &asm_path, &ir_path])
        .status()
        .unwrap_or_else(|e| {
            eprintln!("Failed to run qbe: {e}");
            process::exit(1);
        });
    if !status.success() {
        eprintln!("qbe failed");
        process::exit(1);
    }

    let status = process::Command::new("cc")
        .args([&asm_path, "-o", &out_path])
        .status()
        .unwrap_or_else(|e| {
            eprintln!("Failed to run cc: {e}");
            process::exit(1);
        });
    if !status.success() {
        eprintln!("cc failed");
        process::exit(1);
    }

    println!("Compiled to {out_path}");
}
