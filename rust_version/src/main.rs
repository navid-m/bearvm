mod ast;
mod ast_printer;
mod lexer;
mod parser;
mod qbe;
mod vm;

use clap::{Parser, Subcommand};
use std::fs;
use std::process;

#[derive(Parser)]
#[command(name = "bear")]
#[command(about = "BearVM - VM for QBE/SSA and interpreted modes of execution")]
#[command(help_template = "\
Usage:
  {bin} <file.bear>                  Run via interpreter
  {bin} qbe <file.bear>              Emit QBE IR
  {bin} qbe <file.bear> -c           Compile with QBE

Options:
  --print-ast                       Print the AST and exit
  -h, --help                        Print help
")]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,

    /// Path to the source file
    #[arg(value_name = "FILE")]
    file: Option<String>,

    /// Print the AST and exit
    #[arg(long)]
    print_ast: bool,
}

#[derive(Subcommand)]
enum Commands {
    /// Emit QBE IR or compile with QBE
    Qbe {
        /// Path to the source file
        file: String,

        /// Compile with QBE (run qbe and cc)
        #[arg(short, long)]
        compile: bool,
    },
}

fn main() {
    let cli = Cli::parse();

    match cli.command {
        Some(Commands::Qbe { file, compile }) => {
            run_qbe(&file, compile);
        }
        None => {
            let Some(file) = cli.file else {
                eprintln!("Error: No input file specified");
                process::exit(1);
            };
            if cli.print_ast {
                print_ast(&file);
            } else {
                run_interpreter(&file);
            }
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

fn print_ast(path: &str) {
    ast_printer::AstPrinter::print(&load(path));
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
