//! Bear VM - Zig rewrite (Zig 0.15.2)

const std = @import("std");
const bear_lexer = @import("lexer.zig");
const bear_io = @import("io.zig");
const bear_parser = @import("parser.zig");
const bear_vm = @import("vm.zig");
const bear_qbe = @import("qbe_emitter.zig");
const bear_llvm = @import("llvm_emitter.zig");

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

    // default: interpret
    const src = std.fs.cwd().readFileAlloc(alloc, first, 10 * 1024 * 1024) catch |e| {
        std.debug.print("Error reading {s}: {}\n", .{ first, e });
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

    bear_vm.run(&program, alloc) catch |e| {
        std.debug.print("Runtime error: {}\n", .{e});
        std.process.exit(1);
    };
}

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  bear <file.bear>              Run via interpreter
        \\  bear qbe <file.bear>          Emit QBE IR
        \\  bear qbe <file.bear> -c       Compile with QBE + cc
        \\  bear llvm <file.bear>         Emit LLVM IR
        \\  bear llvm <file.bear> -c      Compile with llc + cc
        \\
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
    const ir_path = std.fmt.allocPrint(alloc, "/tmp/{s}.ssa", .{stem}) catch unreachable;
    const asm_path = std.fmt.allocPrint(alloc, "/tmp/{s}.s", .{stem}) catch unreachable;
    const out_path = std.fmt.allocPrint(alloc, "./{s}", .{stem}) catch unreachable;

    std.fs.cwd().writeFile(.{ .sub_path = ir_path, .data = ir }) catch |e| {
        std.debug.print("Failed to write IR: {}\n", .{e});
        std.process.exit(1);
    };

    runCmd(alloc, &.{ "qbe", "-o", asm_path, ir_path }, "qbe");
    runCmd(alloc, &.{ "cc", asm_path, "-o", out_path }, "cc");
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
    const ir_path = std.fmt.allocPrint(alloc, "/tmp/{s}.ll", .{stem}) catch unreachable;
    const obj_path = std.fmt.allocPrint(alloc, "/tmp/{s}.o", .{stem}) catch unreachable;
    const out_path = std.fmt.allocPrint(alloc, "./{s}", .{stem}) catch unreachable;

    std.fs.cwd().writeFile(.{ .sub_path = ir_path, .data = ir }) catch |e| {
        std.debug.print("Failed to write IR: {}\n", .{e});
        std.process.exit(1);
    };

    runCmd(alloc, &.{ "llc", "-filetype=obj", "-o", obj_path, ir_path }, "llc");
    runCmd(alloc, &.{ "cc", obj_path, "-o", out_path }, "cc");
    std.debug.print("Compiled to {s}\n", .{out_path});
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
    var vm = try bear_vm.Vm.init(&prog, alloc);
    defer vm.deinit();
    const main_fn = vm.findFunc("main") orelse return error.NoMainFunction;
    const env = try alloc.alloc(bear_vm.Value, main_fn.n_regs);
    defer {
        for (env) |*v| v.deinit(alloc);
        alloc.free(env);
    }
    @memset(env, .void_);
    return (try vm.execBody(main_fn.body.items, env)) orelse .void_;
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
    var vm = try bear_vm.Vm.init(&prog, alloc);
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
