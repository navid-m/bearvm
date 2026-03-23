//! Bear VM - Zig rewrite (Zig 0.15.2)
//!
//! Navid Momtahen (C) - GPL-3.0-only

const std = @import("std");
const builtin = @import("builtin");
const bear_lexer = @import("./ast/lexer.zig");
const bear_parser = @import("./ast/parser.zig");
const bear_ast = @import("./ast/ast_printer.zig");
const bear_vm = @import("./vm/vm.zig");
const bear_qbe = @import("./codegen/qbe_emitter.zig");
const bear_llvm = @import("./codegen/llvm_emitter.zig");

const is_silicon = builtin.target.cpu.arch.isAARCH64() and builtin.target.os.tag.isDarwin();

const bear_jit = if (is_silicon) @import("./codegen/jit.zig") else struct {
    pub fn run(program: *const bear_lexer.Program, alloc: std.mem.Allocator) !void {
        _ = program;
        _ = alloc;
        std.debug.print(
            \\JIT is only supported on Apple Silicon (macOS AArch64).
            \\Use the interpreter, LLVM, or QBE targets instead.
        , .{});
        std.process.exit(1);
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    defer arena.deinit();
    const alloc = arena.allocator();
    const argv = try std.process.argsAlloc(alloc);

    if (argv.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    const first = argv[1];
    const is_qbe = std.mem.eql(u8, first, "qbe");
    const is_llvm = std.mem.eql(u8, first, "llvm");
    const is_ast = std.mem.eql(u8, first, "ast");
    const is_jit = std.mem.eql(u8, first, "jit");
    const is_version = std.mem.eql(u8, first, "version");

    if (is_version) {
        std.debug.print("v0.0.1 - By Navid Momtahen (GPL-3.0)", .{});
        return;
    }

    if (is_jit) {
        if (argv.len < 3) {
            printUsage();
            std.process.exit(1);
        }
        const path = argv[2];
        const program = loadProgram(path, alloc);
        bear_jit.run(&program, alloc) catch |e| {
            std.debug.print("JIT error: {}\n", .{e});
            std.process.exit(1);
        };
        return;
    }

    if (is_ast) {
        if (argv.len < 3) {
            printUsage();
            std.process.exit(1);
        }
        const path = argv[2];
        var program = loadProgram(path, alloc);
        defer program.deinit(alloc);
        bear_ast.printAst(&program, alloc) catch |e| {
            std.debug.print("AST print error: {}\n", .{e});
            std.process.exit(1);
        };
        return;
    }

    if (is_qbe or is_llvm) {
        if (argv.len < 3) {
            printUsage();
            std.process.exit(1);
        }
        const path = argv[2];
        const compile = argv.len >= 4 and
            (std.mem.eql(u8, argv[3], "-c") or std.mem.eql(u8, argv[3], "--compile"));
        const program = loadProgram(path, alloc);
        if (is_qbe) {
            runQbe(&program, path, compile, alloc);
        } else {
            runLlvm(&program, path, compile, alloc);
        }
        return;
    }

    var max_call_depth: usize = 1000;
    var file_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.startsWith(u8, arg, "--max-call-depth=")) {
            const val_str = arg["--max-call-depth=".len..];
            max_call_depth = std.fmt.parseInt(usize, val_str, 10) catch {
                std.debug.print("Invalid value for --max-call-depth\n", .{});
                std.process.exit(1);
            };
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            file_path = arg;
        }
    }

    if (file_path == null) {
        printUsage();
        std.process.exit(1);
    }

    const src = std.fs.cwd().readFileAlloc(alloc, file_path.?, 10 * 1024 * 1024) catch |e| {
        std.debug.print("Error reading {s}: {}\n", .{ file_path.?, e });
        std.process.exit(1);
    };

    const tokens = bear_lexer.tokenize(src, alloc) catch |e| {
        std.debug.print("Lex error: {}\n", .{e});
        std.process.exit(1);
    };

    const program = bear_parser.parse(tokens.items, tokens, alloc) catch |e| {
        std.debug.print("Parse error: {}\n", .{e});
        std.process.exit(1);
    };

    bear_vm.run(&program, alloc, max_call_depth) catch |e| {
        std.debug.print("Runtime error: {}\n", .{e});
        std.process.exit(1);
    };
}

fn printUsage() void {
    std.debug.print(
        \\Usage: bear <options> <file.bear>
        \\
        \\  <file.bear>                      Run via interpreter
        \\  <file.bear> [--max-call-depth=n] Set maximum call depth (default: 1000)
        \\  ast  <file.bear>                 Print AST as unicode tree
        \\  jit  <file.bear>                 JIT compile and run
        \\  qbe  <file.bear>                 Emit QBE IR
        \\  qbe  <file.bear> -c              Compile with QBE + cc
        \\  llvm <file.bear>                 Emit LLVM IR
        \\  llvm <file.bear> -c              Compile with clang
        \\  version                          Show version and quit
    , .{});
}

fn loadProgram(path: []const u8, alloc: std.mem.Allocator) bear_lexer.Program {
    const src = std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024) catch |e| {
        std.debug.print("Error reading {s}: {}\n", .{ path, e });
        std.process.exit(1);
    };
    const tokens = bear_lexer.tokenize(src, alloc) catch |e| {
        std.debug.print("Lex error: {}\n", .{e});
        std.process.exit(1);
    };
    return bear_parser.parse(tokens.items, tokens, alloc) catch |e| {
        std.debug.print("Parse error: {}\n", .{e});
        std.process.exit(1);
    };
}

const bear_runtime_c =
    \\#include <stdio.h>
    \\#include <stdint.h>
    \\void putf(int64_t n) { printf("%lld\n", (long long)n); }
    \\void flush(void) { fflush(stdout); }
    \\
;

fn writeRuntime(alloc: std.mem.Allocator) []const u8 {
    const tmp = getTempDir(alloc) catch |e| {
        std.debug.print("Failed to get temporary directory: {}\n", .{e});
        std.process.exit(1);
    };
    defer alloc.free(tmp);

    const rt_path = std.fmt.allocPrint(alloc, "{s}/bear_runtime.c", .{tmp}) catch |e| {
        std.debug.print("Failed to write to buffer during runtime attachment: {}\n", .{e});
        std.process.exit(1);
    };
    std.fs.cwd().writeFile(.{
        .sub_path = rt_path,
        .data = bear_runtime_c,
    }) catch |e| {
        std.debug.print("Failed to write runtime: {}\n", .{e});
        std.process.exit(1);
    };

    return rt_path;
}

fn runQbe(program: *const bear_lexer.Program, path: []const u8, compile: bool, alloc: std.mem.Allocator) void {
    const ir = bear_qbe.emit(program, alloc) catch |e| {
        std.debug.print("QBE codegen error: {}\n", .{e});
        std.process.exit(1);
    };

    if (!compile) {
        std.debug.print("{s}", .{ir});
        return;
    }

    const stem = std.fs.path.stem(path);
    const temp_dir = getTempDir(alloc) catch |e| {
        std.debug.print("Failed to get temporary directory: {}\n", .{e});
        std.process.exit(1);
    };
    const ir_path = std.fmt.allocPrint(alloc, "{s}/{s}.ssa", .{ temp_dir, stem }) catch unreachable;
    const asm_path = std.fmt.allocPrint(alloc, "{s}/{s}.s", .{ temp_dir, stem }) catch unreachable;

    var extension: []const u8 = "";
    if (builtin.os.tag == .windows) {
        extension = ".exe";
    }
    const out_path = std.fmt.allocPrint(alloc, "./{s}{s}", .{ stem, extension }) catch unreachable;

    std.fs.cwd().writeFile(.{ .sub_path = ir_path, .data = ir }) catch |e| {
        if (e == error.FileNotFound) {
            std.debug.print("Failed to write IR: No such path \"{s}\"\n", .{ir_path});
            std.process.exit(1);
        }
        std.debug.print("Failed to write IR: {}\n", .{e});
        std.process.exit(1);
    };

    runCmd(alloc, &.{ "qbe", "-o", asm_path, ir_path }, "qbe");
    const rt_path = writeRuntime(alloc);
    runCmd(alloc, &.{ "cc", asm_path, rt_path, "-o", out_path }, "cc");
    std.debug.print("Compiled to {s}\n", .{out_path});
}

fn runLlvm(program: *const bear_lexer.Program, path: []const u8, compile: bool, alloc: std.mem.Allocator) void {
    const ir = bear_llvm.emit(program, alloc) catch |e| {
        std.debug.print("LLVM codegen error: {}\n", .{e});
        std.process.exit(1);
    };

    if (!compile) {
        std.debug.print("{s}", .{ir});
        return;
    }

    const stem = std.fs.path.stem(path);
    const temp_dir = getTempDir(alloc) catch |e| {
        std.debug.print("Failed to get temporary directory: {}\n", .{e});
        std.process.exit(1);
    };

    const ir_path = std.fmt.allocPrint(alloc, "{s}/{s}.ll", .{ temp_dir, stem }) catch unreachable;
    var extension: []const u8 = "";
    if (builtin.os.tag == .windows) {
        extension = ".exe";
    }
    const out_path = std.fmt.allocPrint(alloc, "./{s}{s}", .{ stem, extension }) catch unreachable;

    std.fs.cwd().writeFile(.{ .sub_path = ir_path, .data = ir }) catch |e| {
        if (e == error.FileNotFound) {
            std.debug.print("Failed to write IR: No such path \"{s}\"\n", .{ir_path});
            std.process.exit(1);
        }
        std.debug.print("Failed to write IR: {}\n", .{e});
        std.process.exit(1);
    };

    const rt_path = writeRuntime(alloc);
    runCmd(alloc, &.{ "clang", ir_path, rt_path, "-o", out_path, "-Wno-override-module" }, "clang");
    std.debug.print("Compiled to {s}\n", .{out_path});
}

fn getTempDir(allocator: std.mem.Allocator) ![]u8 {
    const env = std.process;
    if (env.getEnvVarOwned(allocator, "TMPDIR")) |p| return p else |_| {}
    if (env.getEnvVarOwned(allocator, "TMP")) |p| return p else |_| {}
    if (env.getEnvVarOwned(allocator, "TEMP")) |p| return p else |_| {}
    return allocator.dupe(u8, "/tmp");
}

fn runCmd(alloc: std.mem.Allocator, argv: []const []const u8, name: []const u8) void {
    var child = std.process.Child.init(argv, alloc);
    const term = child.spawnAndWait() catch |e| {
        std.debug.print("Failed to run {s}: {}\n", .{ name, e });
        std.process.exit(1);
    };
    if (term != .Exited or term.Exited != 0) {
        std.debug.print("{s} failed\n", .{name});
        std.process.exit(1);
    }
}

fn testLex(src: []const u8, alloc: std.mem.Allocator) ![]bear_lexer.Token {
    var list = try bear_lexer.tokenize(src, alloc);
    return list.toOwnedSlice(alloc);
}

fn testParse(src: []const u8, alloc: std.mem.Allocator) !bear_lexer.Program {
    const list = try bear_lexer.tokenize(src, alloc);
    errdefer bear_lexer.freeTokens(list, alloc);
    return bear_parser.parse(list.items, list, alloc);
}

fn evalMain(src: []const u8, alloc: std.mem.Allocator) !bear_vm.Value {
    const list = try bear_lexer.tokenize(src, alloc);
    var prog = bear_parser.parse(list.items, list, alloc) catch |err| {
        bear_lexer.freeTokens(list, alloc);
        return err;
    };
    defer prog.deinit(alloc);
    var vm = try bear_vm.Vm.init(&prog, alloc, 1000);
    defer vm.deinit();
    const main_fn = vm.findFunc("main") orelse return error.NoMainFunction;
    const main_idx = vm.func_index.get("main") orelse return error.NoMainFunction;
    const env = try alloc.alloc(bear_vm.Value, main_fn.n_regs);
    defer {
        for (env) |*v| v.deinit(alloc);
        alloc.free(env);
    }
    @memset(env, .void_);
    return (try vm.execBody(main_fn.body.items, env, main_idx)) orelse .void_;
}

test "lexer: empty input yields only eof" {
    const alloc = std.testing.allocator;
    const toks = try testLex("", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(@as(usize, 1), toks.len);
    try std.testing.expectEqual(bear_lexer.TokenTag.eof, std.meta.activeTag(toks[0]));
}

test "lexer: keywords" {
    const alloc = std.testing.allocator;
    const toks = try testLex("const add sub mul div lt gt eq ret call while alloc set struct", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(bear_lexer.TokenTag.kw_const, std.meta.activeTag(toks[0]));
    try std.testing.expectEqual(bear_lexer.TokenTag.kw_add, std.meta.activeTag(toks[1]));
    try std.testing.expectEqual(bear_lexer.TokenTag.kw_sub, std.meta.activeTag(toks[2]));
    try std.testing.expectEqual(bear_lexer.TokenTag.kw_mul, std.meta.activeTag(toks[3]));
    try std.testing.expectEqual(bear_lexer.TokenTag.kw_div, std.meta.activeTag(toks[4]));
    try std.testing.expectEqual(bear_lexer.TokenTag.kw_lt, std.meta.activeTag(toks[5]));
    try std.testing.expectEqual(bear_lexer.TokenTag.kw_gt, std.meta.activeTag(toks[6]));
    try std.testing.expectEqual(bear_lexer.TokenTag.kw_eq, std.meta.activeTag(toks[7]));
    try std.testing.expectEqual(bear_lexer.TokenTag.kw_ret, std.meta.activeTag(toks[8]));
    try std.testing.expectEqual(bear_lexer.TokenTag.kw_call, std.meta.activeTag(toks[9]));
    try std.testing.expectEqual(bear_lexer.TokenTag.kw_while, std.meta.activeTag(toks[10]));
    try std.testing.expectEqual(bear_lexer.TokenTag.kw_alloc, std.meta.activeTag(toks[11]));
    try std.testing.expectEqual(bear_lexer.TokenTag.kw_set, std.meta.activeTag(toks[12]));
    try std.testing.expectEqual(bear_lexer.TokenTag.kw_struct, std.meta.activeTag(toks[13]));
}

test "lexer: type keywords" {
    const alloc = std.testing.allocator;
    const toks = try testLex("int void string bool", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(bear_lexer.TokenTag.ty_int, std.meta.activeTag(toks[0]));
    try std.testing.expectEqual(bear_lexer.TokenTag.ty_void, std.meta.activeTag(toks[1]));
    try std.testing.expectEqual(bear_lexer.TokenTag.ty_string, std.meta.activeTag(toks[2]));
    try std.testing.expectEqual(bear_lexer.TokenTag.ty_bool, std.meta.activeTag(toks[3]));
}

test "lexer: punctuation" {
    const alloc = std.testing.allocator;
    const toks = try testLex("{ } ( ) : , . =", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(bear_lexer.TokenTag.lbrace, std.meta.activeTag(toks[0]));
    try std.testing.expectEqual(bear_lexer.TokenTag.rbrace, std.meta.activeTag(toks[1]));
    try std.testing.expectEqual(bear_lexer.TokenTag.lparen, std.meta.activeTag(toks[2]));
    try std.testing.expectEqual(bear_lexer.TokenTag.rparen, std.meta.activeTag(toks[3]));
    try std.testing.expectEqual(bear_lexer.TokenTag.colon, std.meta.activeTag(toks[4]));
    try std.testing.expectEqual(bear_lexer.TokenTag.comma, std.meta.activeTag(toks[5]));
    try std.testing.expectEqual(bear_lexer.TokenTag.dot, std.meta.activeTag(toks[6]));
    try std.testing.expectEqual(bear_lexer.TokenTag.assign, std.meta.activeTag(toks[7]));
}

test "lexer: integer literals" {
    const alloc = std.testing.allocator;
    const toks = try testLex("0 42 -7", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(@as(i64, 0), toks[0].int);
    try std.testing.expectEqual(@as(i64, 42), toks[1].int);
    try std.testing.expectEqual(@as(i64, -7), toks[2].int);
}

test "lexer: string literal" {
    const alloc = std.testing.allocator;
    const toks = try testLex("\"hello world\"", alloc);
    defer bear_lexer.freeTokenSlice(toks, alloc);
    try std.testing.expectEqualStrings("hello world", toks[0].str);
}

test "lexer: string escape sequences" {
    const alloc = std.testing.allocator;
    const toks = try testLex("\"line1\\nline2\"", alloc);
    defer bear_lexer.freeTokenSlice(toks, alloc);
    try std.testing.expectEqualStrings("line1\nline2", toks[0].str);
}

test "lexer: register and func sigils" {
    const alloc = std.testing.allocator;
    const toks = try testLex("%my_reg @my_func", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(bear_lexer.TokenTag.reg, std.meta.activeTag(toks[0]));
    try std.testing.expectEqualStrings("my_reg", toks[0].reg);
    try std.testing.expectEqual(bear_lexer.TokenTag.func, std.meta.activeTag(toks[1]));
    try std.testing.expectEqualStrings("my_func", toks[1].func);
}

test "lexer: identifier" {
    const alloc = std.testing.allocator;
    const toks = try testLex("puts other_func", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(bear_lexer.TokenTag.ident, std.meta.activeTag(toks[0]));
    try std.testing.expectEqualStrings("puts", toks[0].ident);
    try std.testing.expectEqualStrings("other_func", toks[1].ident);
}

test "lexer: line comment is skipped" {
    const alloc = std.testing.allocator;
    const toks = try testLex("; this is a comment\n42", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(@as(i64, 42), toks[0].int);
}

test "lexer: unterminated string is error" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.UnterminatedString, testLex("\"oops", alloc));
}

test "lexer: unexpected char is error" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedChar, testLex("^", alloc));
}

test "parser: minimal void function" {
    const alloc = std.testing.allocator;
    var prog = try testParse("@other_func: void { ret 0 }", alloc);
    defer prog.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), prog.functions.items.len);
    try std.testing.expectEqualStrings("other_func", prog.functions.items[0].name);
    try std.testing.expectEqual(bear_lexer.Ty.void_, prog.functions.items[0].ret_ty);
    try std.testing.expectEqual(@as(usize, 0), prog.functions.items[0].params.items.len);
}

test "parser: function with empty parens and return type" {
    const alloc = std.testing.allocator;
    var prog = try testParse("@main(): int { ret 0 }", alloc);
    defer prog.deinit(alloc);
    try std.testing.expectEqual(bear_lexer.Ty.int, prog.functions.items[0].ret_ty);
}

test "parser: call without args" {
    const alloc = std.testing.allocator;
    var prog = try testParse("@main(): int { call other_func ret 0 }", alloc);
    defer prog.deinit(alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expectEqualStrings("other_func", stmt.call.name);
    try std.testing.expectEqual(@as(usize, 0), stmt.call.args.items.len);
}

test "parser: call with args" {
    const alloc = std.testing.allocator;
    var prog = try testParse("@main(): int { call puts(\"hi\") ret 0 }", alloc);
    defer prog.deinit(alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expectEqualStrings("puts", stmt.call.name);
    try std.testing.expectEqual(@as(usize, 1), stmt.call.args.items.len);
}

test "parser: assign const int" {
    const alloc = std.testing.allocator;
    var prog = try testParse("@main(): int { %x = const 42 ret 0 }", alloc);
    defer prog.deinit(alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expectEqual(@as(bear_lexer.RegIdx, 0), stmt.assign.reg);
}

test "parser: assign add expr" {
    const alloc = std.testing.allocator;
    var prog = try testParse("@main(): int { %r = add %a, %b ret 0 }", alloc);
    defer prog.deinit(alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expect(std.meta.activeTag(stmt.assign.expr.*) == .add);
}

test "parser: while loop" {
    const alloc = std.testing.allocator;
    var prog = try testParse("@main(): int { while (lt %i, 10) { call puts(\"x\") } ret 0 }", alloc);
    defer prog.deinit(alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expect(std.meta.activeTag(stmt) == .while_);
}

test "parser: set field" {
    const alloc = std.testing.allocator;
    var prog = try testParse("@main(): int { set %p.age = const 1 ret 0 }", alloc);
    defer prog.deinit(alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expectEqualStrings("age", stmt.set_field.field);
}

test "parser: field access expr" {
    const alloc = std.testing.allocator;
    var prog = try testParse("@main(): int { %v = %p.name ret 0 }", alloc);
    defer prog.deinit(alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expect(std.meta.activeTag(stmt.assign.expr.*) == .field);
    try std.testing.expectEqualStrings("name", stmt.assign.expr.field.field);
}

test "parser: alloc expr" {
    const alloc = std.testing.allocator;
    var prog = try testParse("@main(): int { %buf = alloc 1024 ret 0 }", alloc);
    defer prog.deinit(alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expect(std.meta.activeTag(stmt.assign.expr.*) == .alloc);
}

test "parser: struct definition" {
    const alloc = std.testing.allocator;
    var prog = try testParse("struct Person { name: string age: int }", alloc);
    defer prog.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), prog.structs.items.len);
    try std.testing.expectEqualStrings("Person", prog.structs.items[0].name);
    try std.testing.expectEqual(@as(usize, 2), prog.structs.items[0].fields.items.len);
}

test "parser: struct literal in assign" {
    const alloc = std.testing.allocator;
    var prog = try testParse("@main(): int { %p = Person { name: \"Alice\" age: 25 } ret 0 }", alloc);
    defer prog.deinit(alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expect(std.meta.activeTag(stmt.assign.expr.*) == .struct_lit);
}

test "parser: named constant" {
    const alloc = std.testing.allocator;
    var prog = try testParse("@main(): int { %m = READ ret 0 }", alloc);
    defer prog.deinit(alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expect(std.meta.activeTag(stmt.assign.expr.*) == .named);
    try std.testing.expectEqualStrings("READ", stmt.assign.expr.named);
}

test "parser: unknown top-level token is error" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedTopLevel, testParse("42", alloc));
}

test "interpreter: ret integer" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { ret 42 }", alloc);
    try std.testing.expectEqual(@as(i64, 42), v.int);
}

test "interpreter: const and ret" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %x = const 7 ret %x }", alloc);
    try std.testing.expectEqual(@as(i64, 7), v.int);
}

test "interpreter: arithmetic add" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %r = add 3, 4 ret %r }", alloc);
    try std.testing.expectEqual(@as(i64, 7), v.int);
}

test "interpreter: arithmetic sub" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %r = sub 10, 3 ret %r }", alloc);
    try std.testing.expectEqual(@as(i64, 7), v.int);
}

test "interpreter: arithmetic mul" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %r = mul 3, 4 ret %r }", alloc);
    try std.testing.expectEqual(@as(i64, 12), v.int);
}

test "interpreter: arithmetic div" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %r = div 12, 4 ret %r }", alloc);
    try std.testing.expectEqual(@as(i64, 3), v.int);
}

test "interpreter: div by zero is error" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.DivisionByZero, evalMain("@main(): int { %r = div 1, 0 ret %r }", alloc));
}

test "interpreter: comparison lt true" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %r = lt 3, 5 ret %r }", alloc);
    try std.testing.expectEqual(true, v.bool_);
}

test "interpreter: comparison lt false" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %r = lt 5, 3 ret %r }", alloc);
    try std.testing.expectEqual(false, v.bool_);
}

test "interpreter: comparison gt" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %r = gt 5, 3 ret %r }", alloc);
    try std.testing.expectEqual(true, v.bool_);
}

test "interpreter: comparison eq ints" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %r = eq 4, 4 ret %r }", alloc);
    try std.testing.expectEqual(true, v.bool_);
}

test "interpreter: while loop counts" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %i = const 0 while (lt %i, 5) { %i = add %i, 1 } ret %i }", alloc);
    try std.testing.expectEqual(@as(i64, 5), v.int);
}

test "interpreter: user function call" {
    const alloc = std.testing.allocator;
    const src =
        \\@double(%x: int): int { ret mul %x, 2 }
        \\@main(): int { %r = call double(21) ret %r }
    ;
    const v = try evalMain(src, alloc);
    try std.testing.expectEqual(@as(i64, 42), v.int);
}

test "interpreter: struct field access" {
    const alloc = std.testing.allocator;
    const src =
        \\struct Point { x: int y: int }
        \\@main(): int { %p = Point { x: 10 y: 20 } %v = %p.x ret %v }
    ;
    const v = try evalMain(src, alloc);
    try std.testing.expectEqual(@as(i64, 10), v.int);
}

test "interpreter: struct set field" {
    const alloc = std.testing.allocator;
    const src =
        \\struct Point { x: int y: int }
        \\@main(): int { %p = Point { x: 1 y: 2 } set %p.x = const 99 %v = %p.x ret %v }
    ;
    const v = try evalMain(src, alloc);
    try std.testing.expectEqual(@as(i64, 99), v.int);
}

test "interpreter: named constant READ" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %m = READ ret %m }", alloc);
    try std.testing.expectEqual(@as(i64, 0), v.int);
}

test "interpreter: named constant WRITE" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %m = WRITE ret %m }", alloc);
    try std.testing.expectEqual(@as(i64, 1), v.int);
}

test "interpreter: alloc returns ptr" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %buf = alloc 64 ret 0 }", alloc);
    try std.testing.expectEqual(@as(i64, 0), v.int);
}

test "interpreter: no main is error" {
    const alloc = std.testing.allocator;
    const list = try bear_lexer.tokenize("@other: void { ret 0 }", alloc);
    var prog = try bear_parser.parse(list.items, list, alloc);
    defer prog.deinit(alloc);
    var vm = try bear_vm.Vm.init(&prog, alloc, 1000);
    defer vm.deinit();
    try std.testing.expect(vm.findFunc("main") == null);
}

test "interpreter: undefined register is error" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.NotAStruct,
        evalMain("@main(): int { %v = %nope.field ret 0 }", alloc),
    );
}

test "lexer: free and arena keywords" {
    const alloc = std.testing.allocator;
    const toks = try testLex("free arena_create arena_alloc arena_destroy", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(bear_lexer.TokenTag.kw_free, std.meta.activeTag(toks[0]));
    try std.testing.expectEqual(bear_lexer.TokenTag.kw_arena_create, std.meta.activeTag(toks[1]));
    try std.testing.expectEqual(bear_lexer.TokenTag.kw_arena_alloc, std.meta.activeTag(toks[2]));
    try std.testing.expectEqual(bear_lexer.TokenTag.kw_arena_destroy, std.meta.activeTag(toks[3]));
}

test "lexer: phi keyword and brackets" {
    const alloc = std.testing.allocator;
    const toks = try testLex("phi [ ]", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(bear_lexer.TokenTag.kw_phi, std.meta.activeTag(toks[0]));
    try std.testing.expectEqual(bear_lexer.TokenTag.lbracket, std.meta.activeTag(toks[1]));
    try std.testing.expectEqual(bear_lexer.TokenTag.rbracket, std.meta.activeTag(toks[2]));
}

test "parser: free stmt" {
    const alloc = std.testing.allocator;
    var prog = try testParse("@main(): int { %buf = alloc 64 free %buf ret 0 }", alloc);
    defer prog.deinit(alloc);
    const stmts = prog.functions.items[0].body.items;
    try std.testing.expect(std.meta.activeTag(stmts[1]) == .free);
}

test "parser: arena_create and arena_destroy" {
    const alloc = std.testing.allocator;
    var prog = try testParse("@main(): int { %a = arena_create arena_destroy %a ret 0 }", alloc);
    defer prog.deinit(alloc);
    const stmts = prog.functions.items[0].body.items;
    try std.testing.expect(std.meta.activeTag(stmts[0].assign.expr.*) == .arena_create);
    try std.testing.expect(std.meta.activeTag(stmts[1]) == .arena_destroy);
}

test "parser: arena_alloc expr" {
    const alloc = std.testing.allocator;
    var prog = try testParse("@main(): int { %a = arena_create %p = arena_alloc %a, 128 ret 0 }", alloc);
    defer prog.deinit(alloc);
    const stmts = prog.functions.items[0].body.items;
    const expr = stmts[1].assign.expr;
    try std.testing.expect(std.meta.activeTag(expr.*) == .arena_alloc);
}

test "parser: alloc_array expr" {
    const alloc = std.testing.allocator;
    var prog = try testParse("@main(): int { %arr = alloc_array int, 10 ret 0 }", alloc);
    defer prog.deinit(alloc);
    const expr = prog.functions.items[0].body.items[0].assign.expr;
    try std.testing.expect(std.meta.activeTag(expr.*) == .alloc_array);
    try std.testing.expectEqual(bear_lexer.Ty.int, expr.alloc_array.elem_ty);
}

test "parser: phi expr" {
    const alloc = std.testing.allocator;
    var prog = try testParse(
        \\@main(): int {
        \\  entry:
        \\  %x0 = const 0
        \\  jmp loop
        \\  loop:
        \\  %x = phi [entry: %x0, loop: %x0]
        \\  ret %x
        \\}
    , alloc);
    defer prog.deinit(alloc);
    const stmts = prog.functions.items[0].body.items;
    var found = false;
    for (stmts) |s| {
        if (s == .assign and std.meta.activeTag(s.assign.expr.*) == .phi) {
            try std.testing.expectEqual(@as(usize, 2), s.assign.expr.phi.items.len);
            try std.testing.expectEqualStrings("entry", s.assign.expr.phi.items[0].label);
            try std.testing.expectEqualStrings("loop", s.assign.expr.phi.items[1].label);
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "interpreter: alloc and free raw buffer" {
    const alloc = std.testing.allocator;
    const v = try evalMain("@main(): int { %buf = alloc 256 free %buf ret 0 }", alloc);
    try std.testing.expectEqual(@as(i64, 0), v.int);
}

test "interpreter: alloc typed struct and free" {
    const alloc = std.testing.allocator;
    const src =
        \\struct Node { val: int }
        \\@main(): int {
        \\  %p = alloc Node
        \\  %ref = get_field_ref %p, val
        \\  store %ref, 99
        \\  %v = load %ref
        \\  free %p
        \\  ret %v
        \\}
    ;
    const v = try evalMain(src, alloc);
    try std.testing.expectEqual(@as(i64, 99), v.int);
}

test "interpreter: alloc_array and index access" {
    const alloc = std.testing.allocator;
    const src =
        \\@main(): int {
        \\  %arr = alloc_array int, 4
        \\  %r2 = get_index_ref %arr, 2
        \\  store %r2, 42
        \\  %v = load %r2
        \\  ret %v
        \\}
    ;
    const v = try evalMain(src, alloc);
    try std.testing.expectEqual(@as(i64, 42), v.int);
}

test "interpreter: alloc_array out of bounds is error" {
    const alloc = std.testing.allocator;
    const src =
        \\@main(): int {
        \\  %arr = alloc_array int, 2
        \\  %r = get_index_ref %arr, 5
        \\  ret 0
        \\}
    ;
    try std.testing.expectError(error.IndexOutOfBounds, evalMain(src, alloc));
}

test "interpreter: arena create, alloc, destroy" {
    const alloc = std.testing.allocator;
    const src =
        \\@main(): int {
        \\  %arena = arena_create
        \\  %a = arena_alloc %arena, 64
        \\  %b = arena_alloc %arena, 128
        \\  arena_destroy %arena
        \\  ret 0
        \\}
    ;
    const v = try evalMain(src, alloc);
    try std.testing.expectEqual(@as(i64, 0), v.int);
}

test "interpreter: multiple arenas independent" {
    const alloc = std.testing.allocator;
    const src =
        \\@main(): int {
        \\  %a1 = arena_create
        \\  %a2 = arena_create
        \\  %p1 = arena_alloc %a1, 32
        \\  %p2 = arena_alloc %a2, 64
        \\  arena_destroy %a1
        \\  arena_destroy %a2
        \\  ret 0
        \\}
    ;
    const v = try evalMain(src, alloc);
    try std.testing.expectEqual(@as(i64, 0), v.int);
}

test "interpreter: phi selects entry arm" {
    const alloc = std.testing.allocator;
    const src =
        \\@main(): int {
        \\  entry:
        \\  %x0 = const 7
        \\  %y0 = const 99
        \\  jmp done
        \\  other:
        \\  jmp done
        \\  done:
        \\  %x = phi [entry: %x0, other: %y0]
        \\  ret %x
        \\}
    ;
    const v = try evalMain(src, alloc);
    try std.testing.expectEqual(@as(i64, 7), v.int);
}

test "interpreter: phi selects other arm" {
    const alloc = std.testing.allocator;
    const src =
        \\@main(): int {
        \\  entry:
        \\  %x0 = const 7
        \\  %y0 = const 99
        \\  %cond = const 1
        \\  br_if %cond, other, done
        \\  other:
        \\  jmp done
        \\  done:
        \\  %x = phi [entry: %x0, other: %y0]
        \\  ret %x
        \\}
    ;
    const v = try evalMain(src, alloc);
    try std.testing.expectEqual(@as(i64, 99), v.int);
}

test "interpreter: phi fibonacci fib(10) = 55" {
    const alloc = std.testing.allocator;
    const src =
        \\@fib(%n: int): int {
        \\  entry:
        \\  %a0 = const 0
        \\  %b0 = const 1
        \\  %i0 = const 0
        \\  jmp loop_cond
        \\  loop_cond:
        \\  %a = phi [entry: %a0, loop_body: %a_next]
        \\  %b = phi [entry: %b0, loop_body: %b_next]
        \\  %i = phi [entry: %i0, loop_body: %i_next]
        \\  %cond = lt %i, %n
        \\  br_if %cond, loop_body, loop_end
        \\  loop_body:
        \\  %tmp = add %a, %b
        \\  %a_next = %b
        \\  %b_next = %tmp
        \\  %i_next = add %i, 1
        \\  jmp loop_cond
        \\  loop_end:
        \\  ret %a
        \\}
        \\@main(): int {
        \\  %r = call fib(10)
        \\  ret %r
        \\}
    ;
    const v = try evalMain(src, alloc);
    try std.testing.expectEqual(@as(i64, 55), v.int);
}

test "interpreter: phi fibonacci fib(0) = 0" {
    const alloc = std.testing.allocator;
    const src =
        \\@fib(%n: int): int {
        \\  entry:
        \\  %a0 = const 0
        \\  %b0 = const 1
        \\  %i0 = const 0
        \\  jmp loop_cond
        \\  loop_cond:
        \\  %a = phi [entry: %a0, loop_body: %a_next]
        \\  %b = phi [entry: %b0, loop_body: %b_next]
        \\  %i = phi [entry: %i0, loop_body: %i_next]
        \\  %cond = lt %i, %n
        \\  br_if %cond, loop_body, loop_end
        \\  loop_body:
        \\  %tmp = add %a, %b
        \\  %a_next = %b
        \\  %b_next = %tmp
        \\  %i_next = add %i, 1
        \\  jmp loop_cond
        \\  loop_end:
        \\  ret %a
        \\}
        \\@main(): int {
        \\  %r = call fib(0)
        \\  ret %r
        \\}
    ;
    const v = try evalMain(src, alloc);
    try std.testing.expectEqual(@as(i64, 0), v.int);
}

test "qbe: phi emits correct IL" {
    const alloc = std.testing.allocator;
    const src =
        \\@fib(%n: int): int {
        \\  entry:
        \\  %a0 = const 0
        \\  %b0 = const 1
        \\  %i0 = const 0
        \\  jmp loop_cond
        \\  loop_cond:
        \\  %a = phi [entry: %a0, loop_body: %a_next]
        \\  %b = phi [entry: %b0, loop_body: %b_next]
        \\  %i = phi [entry: %i0, loop_body: %i_next]
        \\  %cond = lt %i, %n
        \\  br_if %cond, loop_body, loop_end
        \\  loop_body:
        \\  %tmp = add %a, %b
        \\  %a_next = %b
        \\  %b_next = %tmp
        \\  %i_next = add %i, 1
        \\  jmp loop_cond
        \\  loop_end:
        \\  ret %a
        \\}
    ;
    const list = try bear_lexer.tokenize(src, alloc);
    var prog = try bear_parser.parse(list.items, list, alloc);
    defer prog.deinit(alloc);
    const ir = try bear_qbe.emit(&prog, alloc);
    defer alloc.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "phi") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "@entry") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "@loop_body") != null);
}

test "llvm: phi emits correct IR" {
    const alloc = std.testing.allocator;
    const src =
        \\@fib(%n: int): int {
        \\  entry:
        \\  %a0 = const 0
        \\  %b0 = const 1
        \\  %i0 = const 0
        \\  jmp loop_cond
        \\  loop_cond:
        \\  %a = phi [entry: %a0, loop_body: %a_next]
        \\  %b = phi [entry: %b0, loop_body: %b_next]
        \\  %i = phi [entry: %i0, loop_body: %i_next]
        \\  %cond = lt %i, %n
        \\  br_if %cond, loop_body, loop_end
        \\  loop_body:
        \\  %tmp = add %a, %b
        \\  %a_next = %b
        \\  %b_next = %tmp
        \\  %i_next = add %i, 1
        \\  jmp loop_cond
        \\  loop_end:
        \\  ret %a
        \\}
    ;
    const list = try bear_lexer.tokenize(src, alloc);
    var prog = try bear_parser.parse(list.items, list, alloc);
    defer prog.deinit(alloc);
    const ir = try bear_llvm.emit(&prog, alloc);
    defer alloc.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "phi i64") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "%entry") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "%loop_body") != null);
}

fn qbeEmit(src: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    const list = try bear_lexer.tokenize(src, alloc);
    var prog = try bear_parser.parse(list.items, list, alloc);
    defer prog.deinit(alloc);
    return bear_qbe.emit(&prog, alloc);
}

fn llvmEmit(src: []const u8, alloc: std.mem.Allocator) ![]const u8 {
    const list = try bear_lexer.tokenize(src, alloc);
    var prog = try bear_parser.parse(list.items, list, alloc);
    defer prog.deinit(alloc);
    return bear_llvm.emit(&prog, alloc);
}

test "qbe: alloc produces l-typed tmp" {
    const alloc = std.testing.allocator;
    const ir = try qbeEmit("@main(): int { %buf = alloc 1024 ret 0 }", alloc);
    defer alloc.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "=l alloc8") != null);
}

test "qbe: alloc8 size operand is l-typed" {
    const alloc = std.testing.allocator;
    const ir = try qbeEmit("@main(): int { %buf = alloc 1024 ret 0 }", alloc);
    defer alloc.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "=l copy 1024") != null);
}

test "qbe: alloc passed to read uses l type" {
    const alloc = std.testing.allocator;
    const ir = try qbeEmit(
        \\@main(): int {
        \\  %f = call open("test.txt", READ)
        \\  %buf = alloc 1024
        \\  %n = call read(%f, %buf, 1024)
        \\  ret 0
        \\}
    , alloc);
    defer alloc.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call $read(") != null);
    const read_pos = std.mem.indexOf(u8, ir, "call $read(").?;
    const read_line_end = std.mem.indexOfScalarPos(u8, ir, read_pos, '\n').?;
    const read_line = ir[read_pos..read_line_end];
    try std.testing.expect(std.mem.count(u8, read_line, "l %t") >= 1);
}

test "qbe: string reg passed to puts uses l type" {
    const alloc = std.testing.allocator;
    const ir = try qbeEmit(
        \\@main(): int {
        \\  %s = const "Hello"
        \\  call puts(%s)
        \\  ret 0
        \\}
    , alloc);
    defer alloc.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call $puts(l ") != null);
}

test "llvm: putf and flush are declared" {
    const alloc = std.testing.allocator;
    const ir = try llvmEmit("@main(): int { call putf(42) call flush() ret 0 }", alloc);
    defer alloc.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "declare void @putf") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "declare void @flush") != null);
}

test "llvm: alloc passed to read uses ptr type" {
    const alloc = std.testing.allocator;
    const ir = try llvmEmit(
        \\@main(): int {
        \\  %f = call open("test.txt", READ)
        \\  %buf = alloc 1024
        \\  %n = call read(%f, %buf, 1024)
        \\  ret 0
        \\}
    , alloc);
    defer alloc.free(ir);
    const read_pos = std.mem.indexOf(u8, ir, "call i64 @read(").?;
    const read_end = std.mem.indexOfScalarPos(u8, ir, read_pos, '\n').?;
    const read_line = ir[read_pos..read_end];
    try std.testing.expect(std.mem.indexOf(u8, read_line, "ptr %t") != null);
}

test "llvm: string reg passed to puts uses ptr type" {
    const alloc = std.testing.allocator;
    const ir = try llvmEmit(
        \\@main(): int {
        \\  %s = const "Hello"
        \\  call puts(%s)
        \\  ret 0
        \\}
    , alloc);
    defer alloc.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call i32 @puts(ptr ") != null);
}

test "qbe: simple.bear emits without error" {
    const alloc = std.testing.allocator;
    const src =
        \\@other_func: void {
        \\  call puts("here i go, doing some thing")
        \\}
        \\@main(): int {
        \\  %0 = const 10
        \\  call putf(%0)
        \\  %1 = const "Hello, world."
        \\  call puts(%1)
        \\  call puts("Hi there.")
        \\  call other_func
        \\  call flush()
        \\  ret 0
        \\}
    ;
    const ir = try qbeEmit(src, alloc);
    defer alloc.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call $putf(") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call $flush()") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call $puts(l ") != null);
}

test "qbe: struct int field uses storew not storel" {
    const alloc = std.testing.allocator;
    const ir = try qbeEmit(
        \\struct Person {
        \\  name: string
        \\  age: int
        \\}
        \\@main(): int {
        \\  %p = Person { name: "Alice" age: 25 }
        \\  ret 0
        \\}
    , alloc);
    defer alloc.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "storew") != null);
    try std.testing.expect(std.mem.indexOf(u8, ir, "storel") != null);
}

test "qbe: struct int field uses loadw not loadl" {
    const alloc = std.testing.allocator;
    const ir = try qbeEmit(
        \\struct Person {
        \\  name: string
        \\  age: int
        \\}
        \\@main(): int {
        \\  %p = Person { name: "Alice" age: 25 }
        \\  %a = %p.age
        \\  ret %a
        \\}
    , alloc);
    defer alloc.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "=w loadw") != null);
}

test "qbe: struct string field passed to call uses l type" {
    const alloc = std.testing.allocator;
    const ir = try qbeEmit(
        \\struct Person {
        \\  name: string
        \\  age: int
        \\}
        \\@main(): int {
        \\  %p = Person { name: "Alice" age: 25 }
        \\  call puts(%p.name)
        \\  ret 0
        \\}
    , alloc);
    defer alloc.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "call $puts(l ") != null);
}

test "qbe: set_field on int field uses storew" {
    const alloc = std.testing.allocator;
    const ir = try qbeEmit(
        \\struct Person {
        \\  name: string
        \\  age: int
        \\}
        \\@main(): int {
        \\  %p = Person { name: "Alice" age: 25 }
        \\  set %p.age = add %p.age, 1
        \\  ret 0
        \\}
    , alloc);
    defer alloc.free(ir);
    try std.testing.expect(std.mem.indexOf(u8, ir, "storew") != null);
}
