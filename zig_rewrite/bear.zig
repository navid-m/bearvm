//! Bear VM - Zig rewrite (Zig 0.15.2)

const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayList;

var stdout_buf: [65536]u8 = undefined;
var stdout_pos: usize = 0;

fn flushStdout() void {
    if (stdout_pos == 0) return;
    _ = std.fs.File.stdout().writeAll(stdout_buf[0..stdout_pos]) catch {};
    stdout_pos = 0;
}

fn writeStdout(s: []const u8) void {
    if (stdout_pos + s.len > stdout_buf.len) flushStdout();
    if (s.len > stdout_buf.len) {
        _ = std.fs.File.stdout().writeAll(s) catch {};
        return;
    }
    @memcpy(stdout_buf[stdout_pos..][0..s.len], s);
    stdout_pos += s.len;
}

const TokenTag = enum(u8) {
    int,
    str,
    ident,
    reg,
    func,
    kw_const,
    kw_add,
    kw_sub,
    kw_mul,
    kw_div,
    kw_lt,
    kw_gt,
    kw_eq,
    kw_ret,
    kw_call,
    kw_while,
    kw_alloc,
    kw_set,
    kw_struct,
    ty_int,
    ty_void,
    ty_string,
    ty_bool,
    lbrace,
    rbrace,
    lparen,
    rparen,
    colon,
    comma,
    dot,
    assign,
    eof,
};

const Token = union(TokenTag) {
    int: i64,
    str: []const u8,
    ident: []const u8,
    reg: []const u8,
    func: []const u8,
    kw_const,
    kw_add,
    kw_sub,
    kw_mul,
    kw_div,
    kw_lt,
    kw_gt,
    kw_eq,
    kw_ret,
    kw_call,
    kw_while,
    kw_alloc,
    kw_set,
    kw_struct,
    ty_int,
    ty_void,
    ty_string,
    ty_bool,
    lbrace,
    rbrace,
    lparen,
    rparen,
    colon,
    comma,
    dot,
    assign,
    eof,
};

/// Comptime keyword table — avoids 18 string comparisons per identifier.
fn keywordToken(word: []const u8) ?Token {
    const kws = .{
        .{ "const", Token.kw_const },
        .{ "ret", Token.kw_ret },
        .{ "call", Token.kw_call },
        .{ "while", Token.kw_while },
        .{ "add", Token.kw_add },
        .{ "sub", Token.kw_sub },
        .{ "mul", Token.kw_mul },
        .{ "div", Token.kw_div },
        .{ "lt", Token.kw_lt },
        .{ "gt", Token.kw_gt },
        .{ "eq", Token.kw_eq },
        .{ "alloc", Token.kw_alloc },
        .{ "set", Token.kw_set },
        .{ "struct", Token.kw_struct },
        .{ "int", Token.ty_int },
        .{ "void", Token.ty_void },
        .{ "string", Token.ty_string },
        .{ "bool", Token.ty_bool },
    };
    inline for (kws) |kw| {
        if (std.mem.eql(u8, word, kw[0])) return kw[1];
    }
    return null;
}

fn tokenize(src: []const u8, alloc: Allocator) !List(Token) {
    var tokens = try List(Token).initCapacity(alloc, src.len / 4 + 8);
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c <= ' ') {
            i += 1;
            continue;
        }
        if (c == ';') {
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        }
        switch (c) {
            '{' => {
                try tokens.append(alloc, .lbrace);
                i += 1;
            },
            '}' => {
                try tokens.append(alloc, .rbrace);
                i += 1;
            },
            '(' => {
                try tokens.append(alloc, .lparen);
                i += 1;
            },
            ')' => {
                try tokens.append(alloc, .rparen);
                i += 1;
            },
            ':' => {
                try tokens.append(alloc, .colon);
                i += 1;
            },
            ',' => {
                try tokens.append(alloc, .comma);
                i += 1;
            },
            '.' => {
                try tokens.append(alloc, .dot);
                i += 1;
            },
            '=' => {
                try tokens.append(alloc, .assign);
                i += 1;
            },
            '"' => {
                i += 1;
                var s: List(u8) = .empty;
                while (i < src.len and src[i] != '"') {
                    if (src[i] == '\\' and i + 1 < src.len) {
                        i += 1;
                        const esc: u8 = switch (src[i]) {
                            'n' => '\n',
                            't' => '\t',
                            '"' => '"',
                            '\\' => '\\',
                            else => blk: {
                                try s.append(alloc, '\\');
                                break :blk src[i];
                            },
                        };
                        try s.append(alloc, esc);
                    } else {
                        try s.append(alloc, src[i]);
                    }
                    i += 1;
                }
                if (i >= src.len) return error.UnterminatedString;
                i += 1;
                try tokens.append(alloc, .{ .str = try s.toOwnedSlice(alloc) });
            },
            '%' => {
                i += 1;
                const start = i;
                while (i < src.len and (std.ascii.isAlphanumeric(src[i]) or src[i] == '_')) i += 1;
                try tokens.append(alloc, .{ .reg = src[start..i] });
            },
            '@' => {
                i += 1;
                const start = i;
                while (i < src.len and (std.ascii.isAlphanumeric(src[i]) or src[i] == '_')) i += 1;
                try tokens.append(alloc, .{ .func = src[start..i] });
            },
            else => {
                if (std.ascii.isDigit(c) or (c == '-' and i + 1 < src.len and std.ascii.isDigit(src[i + 1]))) {
                    const neg = c == '-';
                    if (neg) i += 1;
                    const start = i;
                    while (i < src.len and std.ascii.isDigit(src[i])) i += 1;
                    const n = try std.fmt.parseInt(i64, src[start..i], 10);
                    try tokens.append(alloc, .{ .int = if (neg) -n else n });
                } else if (std.ascii.isAlphabetic(c) or c == '_') {
                    const start = i;
                    while (i < src.len and (std.ascii.isAlphanumeric(src[i]) or src[i] == '_')) i += 1;
                    const word = src[start..i];
                    try tokens.append(alloc, keywordToken(word) orelse Token{ .ident = word });
                } else return error.UnexpectedChar;
            },
        }
    }
    try tokens.append(alloc, .eof);
    return tokens;
}

const Ty = enum { int, void_, str, bool_, named };
const StructDef = struct { name: []const u8, fields: List(StructField) };
const StructField = struct { name: []const u8, ty: Ty };
const RegIdx = u16;

const Function = struct {
    name: []const u8,
    params: List(Param),
    ret_ty: Ty,
    body: List(Stmt),
    n_regs: u16,
};

const Param = struct { name: []const u8, ty: Ty, idx: RegIdx };
const Program = struct { structs: List(StructDef), functions: List(Function) };
const Stmt = union(enum) {
    assign: struct { reg: RegIdx, expr: *Expr },
    set_field: struct { reg: RegIdx, field: []const u8, expr: *Expr },
    call: struct { name: []const u8, args: List(*Expr) },
    ret: *Expr,
    while_: struct { cond: *Expr, body: List(Stmt) },
};

const BinOp = struct { a: *Expr, b: *Expr };
const FieldInit = struct { name: []const u8, expr: *Expr };
const Expr = union(enum) {
    int: i64,
    str: []const u8,
    reg: RegIdx,
    field: struct { reg: RegIdx, field: []const u8 },
    const_: *Expr,
    add: BinOp,
    sub: BinOp,
    mul: BinOp,
    div: BinOp,
    lt: BinOp,
    gt: BinOp,
    eq: BinOp,
    call: struct { name: []const u8, args: List(*Expr) },
    alloc: *Expr,
    struct_lit: struct { name: []const u8, fields: List(FieldInit) },
    named: []const u8,
};

const ExprSlab = struct {
    buf: []Expr,
    used: usize,

    fn init(alloc: Allocator, cap: usize) !ExprSlab {
        return .{ .buf = try alloc.alloc(Expr, cap), .used = 0 };
    }

    fn alloc_node(self: *ExprSlab, e: Expr) error{OutOfMemory}!*Expr {
        if (self.used >= self.buf.len) return error.OutOfMemory;
        const p = &self.buf[self.used];
        p.* = e;
        self.used += 1;
        return p;
    }
};

const ParseError = error{
    UnexpectedToken,
    ExpectedIdent,
    ExpectedReg,
    ExpectedFunc,
    ExpectedType,
    ExpectedFuncName,
    UnexpectedExprToken,
    UnexpectedStmtToken,
    UnexpectedTopLevel,
    TooManyRegisters,
    OutOfMemory,
};

/// Per-function register name -> index map built during parsing.
const RegMap = struct {
    names: List([]const u8),
    alloc: Allocator,

    fn init(alloc: Allocator) RegMap {
        return .{ .names = .empty, .alloc = alloc };
    }

    fn intern(self: *RegMap, name: []const u8) !RegIdx {
        for (self.names.items, 0..) |n, i|
            if (std.mem.eql(u8, n, name)) return @intCast(i);
        const idx: RegIdx = @intCast(self.names.items.len);
        if (idx == std.math.maxInt(RegIdx)) return error.TooManyRegisters;
        try self.names.append(self.alloc, name);
        return idx;
    }

    fn count(self: *const RegMap) u16 {
        return @intCast(self.names.items.len);
    }
};

const Parser = struct {
    tokens: []const Token,
    pos: usize,
    alloc: Allocator,
    slab: *ExprSlab,

    fn peek(self: *Parser) Token {
        return self.tokens[self.pos];
    }

    fn advance(self: *Parser) Token {
        const t = self.tokens[self.pos];
        if (self.pos + 1 < self.tokens.len) self.pos += 1;
        return t;
    }

    fn expectTag(self: *Parser, tag: TokenTag) ParseError!Token {
        const t = self.advance();
        if (std.meta.activeTag(t) == tag) return t;
        return error.UnexpectedToken;
    }

    fn expectIdent(self: *Parser) ParseError![]const u8 {
        return switch (self.advance()) {
            .ident => |s| s,
            else => error.ExpectedIdent,
        };
    }

    fn expectReg(self: *Parser) ParseError![]const u8 {
        return switch (self.advance()) {
            .reg => |s| s,
            else => error.ExpectedReg,
        };
    }

    fn expectFunc(self: *Parser) ParseError![]const u8 {
        return switch (self.advance()) {
            .func => |s| s,
            else => error.ExpectedFunc,
        };
    }

    fn parseTy(self: *Parser) ParseError!Ty {
        return switch (self.advance()) {
            .ty_int => .int,
            .ty_void => .void_,
            .ty_string => .str,
            .ty_bool => .bool_,
            .ident => .named,
            else => error.ExpectedType,
        };
    }

    fn parseArgs(self: *Parser, rm: *RegMap) ParseError!List(*Expr) {
        var args: List(*Expr) = .empty;
        if (std.meta.activeTag(self.peek()) != .lparen) return args;
        _ = self.advance();
        while (std.meta.activeTag(self.peek()) != .rparen) {
            try args.append(self.alloc, try self.parseExpr(rm));
            if (std.meta.activeTag(self.peek()) == .comma) _ = self.advance();
        }
        _ = try self.expectTag(.rparen);
        return args;
    }

    fn box(self: *Parser, e: Expr) ParseError!*Expr {
        return self.slab.alloc_node(e);
    }

    fn parseBinOp(self: *Parser, rm: *RegMap, comptime tag: TokenTag) ParseError!*Expr {
        _ = self.advance();
        const a = try self.parseExpr(rm);
        _ = try self.expectTag(.comma);
        const b = try self.parseExpr(rm);
        const payload = BinOp{ .a = a, .b = b };
        return self.box(switch (tag) {
            .kw_add => .{ .add = payload },
            .kw_sub => .{ .sub = payload },
            .kw_mul => .{ .mul = payload },
            .kw_div => .{ .div = payload },
            .kw_lt => .{ .lt = payload },
            .kw_gt => .{ .gt = payload },
            .kw_eq => .{ .eq = payload },
            else => unreachable,
        });
    }

    fn parseExpr(self: *Parser, rm: *RegMap) ParseError!*Expr {
        return switch (self.peek()) {
            .kw_const => blk: {
                _ = self.advance();
                break :blk try self.box(.{ .const_ = try self.parseExpr(rm) });
            },
            .kw_add => try self.parseBinOp(rm, .kw_add),
            .kw_sub => try self.parseBinOp(rm, .kw_sub),
            .kw_mul => try self.parseBinOp(rm, .kw_mul),
            .kw_div => try self.parseBinOp(rm, .kw_div),
            .kw_lt => try self.parseBinOp(rm, .kw_lt),
            .kw_gt => try self.parseBinOp(rm, .kw_gt),
            .kw_eq => try self.parseBinOp(rm, .kw_eq),
            .kw_call => blk: {
                _ = self.advance();
                const name = switch (self.advance()) {
                    .ident => |s| s,
                    .func => |s| s,
                    else => return error.ExpectedFuncName,
                };
                break :blk try self.box(.{ .call = .{ .name = name, .args = try self.parseArgs(rm) } });
            },
            .kw_alloc => blk: {
                _ = self.advance();
                break :blk try self.box(.{ .alloc = try self.parseExpr(rm) });
            },
            .int => |n| blk: {
                _ = self.advance();
                break :blk try self.box(.{ .int = n });
            },
            .str => |s| blk: {
                _ = self.advance();
                break :blk try self.box(.{ .str = s });
            },
            .reg => |r| blk: {
                _ = self.advance();
                const idx = try rm.intern(r);
                if (std.meta.activeTag(self.peek()) == .dot) {
                    _ = self.advance();
                    break :blk try self.box(.{ .field = .{
                        .reg = idx,
                        .field = try self.expectIdent(),
                    } });
                }
                break :blk try self.box(.{ .reg = idx });
            },
            .ident => |name| blk: {
                _ = self.advance();
                if (std.meta.activeTag(self.peek()) == .lbrace) {
                    _ = self.advance();
                    var fields: List(FieldInit) = .empty;
                    while (std.meta.activeTag(self.peek()) != .rbrace) {
                        const fname = try self.expectIdent();
                        _ = try self.expectTag(.colon);
                        try fields.append(self.alloc, .{
                            .name = fname,
                            .expr = try self.parseExpr(rm),
                        });
                        if (std.meta.activeTag(self.peek()) == .comma) _ = self.advance();
                    }
                    _ = try self.expectTag(.rbrace);
                    break :blk try self.box(.{ .struct_lit = .{ .name = name, .fields = fields } });
                }
                break :blk try self.box(.{ .named = name });
            },
            else => error.UnexpectedExprToken,
        };
    }

    fn parseStmt(self: *Parser, rm: *RegMap) ParseError!Stmt {
        return switch (self.peek()) {
            .reg => |r| blk: {
                _ = self.advance();
                const idx = try rm.intern(r);
                _ = try self.expectTag(.assign);
                break :blk .{ .assign = .{ .reg = idx, .expr = try self.parseExpr(rm) } };
            },
            .kw_set => blk: {
                _ = self.advance();
                const r = try self.expectReg();
                const idx = try rm.intern(r);
                _ = try self.expectTag(.dot);
                const field = try self.expectIdent();
                _ = try self.expectTag(.assign);
                break :blk .{ .set_field = .{
                    .reg = idx,
                    .field = field,
                    .expr = try self.parseExpr(rm),
                } };
            },
            .kw_call => blk: {
                _ = self.advance();
                const name = switch (self.advance()) {
                    .ident => |s| s,
                    .func => |s| s,
                    else => return error.ExpectedFuncName,
                };
                break :blk .{ .call = .{ .name = name, .args = try self.parseArgs(rm) } };
            },
            .kw_ret => blk: {
                _ = self.advance();
                break :blk .{ .ret = try self.parseExpr(rm) };
            },
            .kw_while => blk: {
                _ = self.advance();
                _ = try self.expectTag(.lparen);
                const cond = try self.parseExpr(rm);
                _ = try self.expectTag(.rparen);
                _ = try self.expectTag(.lbrace);
                var body: List(Stmt) = .empty;
                while (std.meta.activeTag(self.peek()) != .rbrace)
                    try body.append(self.alloc, try self.parseStmt(rm));
                _ = try self.expectTag(.rbrace);
                break :blk .{ .while_ = .{ .cond = cond, .body = body } };
            },
            else => error.UnexpectedStmtToken,
        };
    }

    fn parseStruct(self: *Parser) ParseError!StructDef {
        _ = try self.expectTag(.kw_struct);
        const name = try self.expectIdent();
        _ = try self.expectTag(.lbrace);
        var fields: List(StructField) = .empty;
        while (std.meta.activeTag(self.peek()) != .rbrace) {
            const fname = try self.expectIdent();
            _ = try self.expectTag(.colon);
            try fields.append(self.alloc, .{ .name = fname, .ty = try self.parseTy() });
        }
        _ = try self.expectTag(.rbrace);
        return .{ .name = name, .fields = fields };
    }

    fn parseFunction(self: *Parser) ParseError!Function {
        const name = try self.expectFunc();
        var rm = RegMap.init(self.alloc);

        var params: List(Param) = .empty;
        if (std.meta.activeTag(self.peek()) == .lparen) {
            _ = self.advance();
            while (std.meta.activeTag(self.peek()) != .rparen) {
                const pname = try self.expectReg();
                _ = try self.expectTag(.colon);
                const ty = try self.parseTy();
                const idx = try rm.intern(pname);
                try params.append(self.alloc, .{ .name = pname, .ty = ty, .idx = idx });
                if (std.meta.activeTag(self.peek()) == .comma) _ = self.advance();
            }
            _ = try self.expectTag(.rparen);
        }
        const ret_ty: Ty = if (std.meta.activeTag(self.peek()) == .colon) blk: {
            _ = self.advance();
            break :blk try self.parseTy();
        } else .void_;
        _ = try self.expectTag(.lbrace);
        var body: List(Stmt) = .empty;
        while (std.meta.activeTag(self.peek()) != .rbrace)
            try body.append(self.alloc, try self.parseStmt(&rm));
        _ = try self.expectTag(.rbrace);
        return .{
            .name = name,
            .params = params,
            .ret_ty = ret_ty,
            .body = body,
            .n_regs = rm.count(),
        };
    }

    fn parseProgram(self: *Parser) ParseError!Program {
        var structs: List(StructDef) = .empty;
        var functions: List(Function) = .empty;
        while (std.meta.activeTag(self.peek()) != .eof) {
            switch (self.peek()) {
                .kw_struct => try structs.append(self.alloc, try self.parseStruct()),
                .func => try functions.append(self.alloc, try self.parseFunction()),
                else => return error.UnexpectedTopLevel,
            }
        }
        return .{ .structs = structs, .functions = functions };
    }
};

fn parse(tokens: []const Token, alloc: Allocator) !Program {
    var slab = try ExprSlab.init(alloc, tokens.len / 3 + 64);
    var p = Parser{ .tokens = tokens, .pos = 0, .alloc = alloc, .slab = &slab };
    return p.parseProgram();
}

const Value = union(enum) {
    int: i64,
    str: []const u8,
    bool_: bool,
    ptr: []u8,
    file: i64,
    void_,
    struct_: StructVal,
};

const StructVal = struct {
    name: []const u8,
    fields: std.StringArrayHashMap(Value),
};

const FileHandle = union(enum) { read: std.fs.File, write: std.fs.File };
const BuiltinTag = enum { puts, open, read, write, close };
const builtin_map = std.StaticStringMap(BuiltinTag).initComptime(.{
    .{ "puts", .puts },
    .{ "open", .open },
    .{ "read", .read },
    .{ "write", .write },
    .{ "close", .close },
});

const Vm = struct {
    program: *const Program,
    files: List(?FileHandle),
    alloc: Allocator,

    fn init(program: *const Program, alloc: Allocator) Vm {
        return .{ .program = program, .files = .empty, .alloc = alloc };
    }

    fn findFunc(self: *Vm, name: []const u8) ?*const Function {
        for (self.program.functions.items) |*f|
            if (std.mem.eql(u8, f.name, name)) return f;
        return null;
    }

    fn allocFile(self: *Vm, handle: FileHandle) !i64 {
        for (self.files.items, 0..) |slot, i| {
            if (slot == null) {
                self.files.items[i] = handle;
                return @intCast(i);
            }
        }
        try self.files.append(self.alloc, handle);
        return @intCast(self.files.items.len - 1);
    }

    fn evalExpr(self: *Vm, expr: *const Expr, env: []Value) anyerror!Value {
        return switch (expr.*) {
            .int => |n| .{ .int = n },
            .str => |s| .{ .str = s },
            .reg => |r| env[r],
            .field => |f| switch (env[f.reg]) {
                .struct_ => |sv| sv.fields.get(f.field) orelse return error.NoSuchField,
                else => return error.NotAStruct,
            },
            .const_ => |inner| try self.evalExpr(inner, env),
            .add => |op| .{ .int = (try self.evalExpr(op.a, env)).int +% (try self.evalExpr(op.b, env)).int },
            .sub => |op| .{ .int = (try self.evalExpr(op.a, env)).int -% (try self.evalExpr(op.b, env)).int },
            .mul => |op| .{ .int = (try self.evalExpr(op.a, env)).int *% (try self.evalExpr(op.b, env)).int },
            .div => |op| blk: {
                const b = (try self.evalExpr(op.b, env)).int;
                if (b == 0) return error.DivisionByZero;
                break :blk .{ .int = @divTrunc((try self.evalExpr(op.a, env)).int, b) };
            },
            .lt => |op| .{ .bool_ = (try self.evalExpr(op.a, env)).int < (try self.evalExpr(op.b, env)).int },
            .gt => |op| .{ .bool_ = (try self.evalExpr(op.a, env)).int > (try self.evalExpr(op.b, env)).int },
            .eq => |op| blk: {
                const a = try self.evalExpr(op.a, env);
                const b = try self.evalExpr(op.b, env);
                break :blk switch (a) {
                    .int => |x| .{ .bool_ = x == b.int },
                    .str => |x| .{ .bool_ = std.mem.eql(u8, x, b.str) },
                    else => return error.TypeMismatch,
                };
            },
            .alloc => |size_expr| blk: {
                const n: usize = @intCast((try self.evalExpr(size_expr, env)).int);
                const buf = try self.alloc.alloc(u8, n);
                @memset(buf, 0);
                break :blk .{ .ptr = buf };
            },
            .struct_lit => |sl| blk: {
                var fields = std.StringArrayHashMap(Value).init(self.alloc);
                for (sl.fields.items) |fi|
                    try fields.put(fi.name, try self.evalExpr(fi.expr, env));
                break :blk .{ .struct_ = .{ .name = sl.name, .fields = fields } };
            },
            .named => |name| if (std.mem.eql(u8, name, "READ")) .{ .int = 0 } else if (std.mem.eql(u8, name, "WRITE")) .{ .int = 1 } else return error.UnknownNamedConstant,
            .call => |c| try self.callFunc(c.name, c.args.items, env),
        };
    }

    fn printValue(_: *Vm, val: Value) void {
        var tmp: [64]u8 = undefined;
        switch (val) {
            .int => |n| writeStdout(std.fmt.bufPrint(&tmp, "{d}\n", .{n}) catch return),
            .str => |s| {
                writeStdout(s);
                writeStdout("\n");
            },
            .bool_ => |b| writeStdout(if (b) "true\n" else "false\n"),
            .ptr => writeStdout("<ptr>\n"),
            .file => |fd| writeStdout(std.fmt.bufPrint(&tmp, "<fd:{d}>\n", .{fd}) catch return),
            .void_ => {},
            .struct_ => |sv| {
                writeStdout(sv.name);
                writeStdout(" { ... }\n");
            },
        }
    }

    fn callFunc(self: *Vm, name: []const u8, arg_exprs: []*Expr, env: []Value) anyerror!Value {
        var args_buf: [32]Value = undefined;
        const argc = arg_exprs.len;
        if (argc > 32) return error.TooManyArguments;
        for (arg_exprs, 0..) |a, i|
            args_buf[i] = try self.evalExpr(a, env);
        const args = args_buf[0..argc];

        if (builtin_map.get(name)) |tag| {
            return switch (tag) {
                .puts => blk: {
                    for (args) |a| self.printValue(a);
                    flushStdout();
                    break :blk .void_;
                },
                .open => blk: {
                    const path = args[0].str;
                    const mode = args[1].int;
                    const fd = if (mode == 0) inner: {
                        const f = try std.fs.cwd().openFile(path, .{});
                        break :inner try self.allocFile(.{ .read = f });
                    } else inner: {
                        const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
                        break :inner try self.allocFile(.{ .write = f });
                    };
                    break :blk .{ .file = fd };
                },
                .read => blk: {
                    const fd: usize = @intCast(args[0].file);
                    const size: usize = @intCast(args[2].int);
                    const buf = try self.alloc.alloc(u8, size);
                    const n = switch (self.files.items[fd].?) {
                        .read => |f| try f.read(buf),
                        else => return error.InvalidFileHandle,
                    };
                    break :blk .{ .str = buf[0..n] };
                },
                .write => blk: {
                    const fd: usize = @intCast(args[0].file);
                    const data: []const u8 = switch (args[1]) {
                        .str => |s| s,
                        .ptr => |p| p,
                        else => return error.TypeMismatch,
                    };
                    switch (self.files.items[fd].?) {
                        .write => |f| try f.writeAll(data),
                        else => return error.InvalidFileHandle,
                    }
                    break :blk .{ .int = @intCast(data.len) };
                },
                .close => blk: {
                    const fd: usize = @intCast(args[0].file);
                    if (fd < self.files.items.len) {
                        if (self.files.items[fd]) |fh| {
                            switch (fh) {
                                .read => |f| f.close(),
                                .write => |f| f.close(),
                            }
                            self.files.items[fd] = null;
                        }
                    }
                    break :blk .void_;
                },
            };
        }

        const func = self.findFunc(name) orelse return error.UndefinedFunction;
        const new_env = try self.alloc.alloc(Value, func.n_regs);

        @memset(new_env, .void_);

        for (func.params.items, 0..) |param, i|
            new_env[param.idx] = args[i];

        return (try self.execBody(func.body.items, new_env)) orelse .void_;
    }

    fn execBody(self: *Vm, stmts: []const Stmt, env: []Value) anyerror!?Value {
        for (stmts) |*stmt|
            if (try self.execStmt(stmt, env)) |v| return v;
        return null;
    }

    fn execStmt(self: *Vm, stmt: *const Stmt, env: []Value) anyerror!?Value {
        switch (stmt.*) {
            .assign => |a| {
                env[a.reg] = try self.evalExpr(a.expr, env);
            },
            .set_field => |sf| {
                const val = try self.evalExpr(sf.expr, env);
                try env[sf.reg].struct_.fields.put(sf.field, val);
            },
            .call => |c| {
                _ = try self.callFunc(c.name, c.args.items, env);
            },
            .ret => |e| return try self.evalExpr(e, env),
            .while_ => |w| {
                while (true) {
                    const keep = switch (try self.evalExpr(w.cond, env)) {
                        .bool_ => |b| b,
                        .int => |n| n != 0,
                        else => return error.TypeMismatch,
                    };
                    if (!keep) break;
                    if (try self.execBody(w.body.items, env)) |v| return v;
                }
            },
        }
        return null;
    }
};

fn run(program: *const Program, alloc: Allocator) !void {
    var vm = Vm.init(program, alloc);
    const main_fn = vm.findFunc("main") orelse return error.NoMainFunction;
    const env = try alloc.alloc(Value, main_fn.n_regs);
    @memset(env, .void_);
    _ = try vm.execBody(main_fn.body.items, env);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const argv = try std.process.argsAlloc(alloc);

    if (argv.len < 2) {
        std.debug.print("Usage: bear <file.bear>\n", .{});
        std.process.exit(1);
    }

    const src = std.fs.cwd().readFileAlloc(alloc, argv[1], 10 * 1024 * 1024) catch |e| {
        std.debug.print("Error reading {s}: {}\n", .{ argv[1], e });
        std.process.exit(1);
    };

    var tokens = tokenize(src, alloc) catch |e| {
        std.debug.print("Lex error: {}\n", .{e});
        std.process.exit(1);
    };
    _ = &tokens;

    const program = parse(tokens.items, alloc) catch |e| {
        std.debug.print("Parse error: {}\n", .{e});
        std.process.exit(1);
    };

    run(&program, alloc) catch |e| {
        std.debug.print("Runtime error: {}\n", .{e});
        std.process.exit(1);
    };
}

fn testLex(src: []const u8, alloc: Allocator) ![]Token {
    var list = try tokenize(src, alloc);
    return list.toOwnedSlice(alloc);
}

fn testParse(src: []const u8, alloc: Allocator) !Program {
    const list = try tokenize(src, alloc);
    return parse(list.items, alloc);
}

fn evalMain(src: []const u8, alloc: Allocator) !Value {
    const list = try tokenize(src, alloc);
    const prog = try parse(list.items, alloc);
    var vm = Vm.init(&prog, alloc);
    const main_fn = vm.findFunc("main") orelse return error.NoMainFunction;
    const env = try alloc.alloc(Value, main_fn.n_regs);
    @memset(env, .void_);
    return (try vm.execBody(main_fn.body.items, env)) orelse .void_;
}

test "lexer: empty input yields only eof" {
    const alloc = std.testing.allocator;
    const toks = try testLex("", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(@as(usize, 1), toks.len);
    try std.testing.expectEqual(TokenTag.eof, std.meta.activeTag(toks[0]));
}

test "lexer: keywords" {
    const alloc = std.testing.allocator;
    const toks = try testLex("const add sub mul div lt gt eq ret call while alloc set struct", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(TokenTag.kw_const, std.meta.activeTag(toks[0]));
    try std.testing.expectEqual(TokenTag.kw_add, std.meta.activeTag(toks[1]));
    try std.testing.expectEqual(TokenTag.kw_sub, std.meta.activeTag(toks[2]));
    try std.testing.expectEqual(TokenTag.kw_mul, std.meta.activeTag(toks[3]));
    try std.testing.expectEqual(TokenTag.kw_div, std.meta.activeTag(toks[4]));
    try std.testing.expectEqual(TokenTag.kw_lt, std.meta.activeTag(toks[5]));
    try std.testing.expectEqual(TokenTag.kw_gt, std.meta.activeTag(toks[6]));
    try std.testing.expectEqual(TokenTag.kw_eq, std.meta.activeTag(toks[7]));
    try std.testing.expectEqual(TokenTag.kw_ret, std.meta.activeTag(toks[8]));
    try std.testing.expectEqual(TokenTag.kw_call, std.meta.activeTag(toks[9]));
    try std.testing.expectEqual(TokenTag.kw_while, std.meta.activeTag(toks[10]));
    try std.testing.expectEqual(TokenTag.kw_alloc, std.meta.activeTag(toks[11]));
    try std.testing.expectEqual(TokenTag.kw_set, std.meta.activeTag(toks[12]));
    try std.testing.expectEqual(TokenTag.kw_struct, std.meta.activeTag(toks[13]));
}

test "lexer: type keywords" {
    const alloc = std.testing.allocator;
    const toks = try testLex("int void string bool", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(TokenTag.ty_int, std.meta.activeTag(toks[0]));
    try std.testing.expectEqual(TokenTag.ty_void, std.meta.activeTag(toks[1]));
    try std.testing.expectEqual(TokenTag.ty_string, std.meta.activeTag(toks[2]));
    try std.testing.expectEqual(TokenTag.ty_bool, std.meta.activeTag(toks[3]));
}

test "lexer: punctuation" {
    const alloc = std.testing.allocator;
    const toks = try testLex("{ } ( ) : , . =", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(TokenTag.lbrace, std.meta.activeTag(toks[0]));
    try std.testing.expectEqual(TokenTag.rbrace, std.meta.activeTag(toks[1]));
    try std.testing.expectEqual(TokenTag.lparen, std.meta.activeTag(toks[2]));
    try std.testing.expectEqual(TokenTag.rparen, std.meta.activeTag(toks[3]));
    try std.testing.expectEqual(TokenTag.colon, std.meta.activeTag(toks[4]));
    try std.testing.expectEqual(TokenTag.comma, std.meta.activeTag(toks[5]));
    try std.testing.expectEqual(TokenTag.dot, std.meta.activeTag(toks[6]));
    try std.testing.expectEqual(TokenTag.assign, std.meta.activeTag(toks[7]));
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
    defer alloc.free(toks);
    try std.testing.expectEqualStrings("hello world", toks[0].str);
}

test "lexer: string escape sequences" {
    const alloc = std.testing.allocator;
    const toks = try testLex("\"line1\\nline2\"", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqualStrings("line1\nline2", toks[0].str);
}

test "lexer: register and func sigils" {
    const alloc = std.testing.allocator;
    const toks = try testLex("%my_reg @my_func", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(TokenTag.reg, std.meta.activeTag(toks[0]));
    try std.testing.expectEqualStrings("my_reg", toks[0].reg);
    try std.testing.expectEqual(TokenTag.func, std.meta.activeTag(toks[1]));
    try std.testing.expectEqualStrings("my_func", toks[1].func);
}

test "lexer: identifier" {
    const alloc = std.testing.allocator;
    const toks = try testLex("puts other_func", alloc);
    defer alloc.free(toks);
    try std.testing.expectEqual(TokenTag.ident, std.meta.activeTag(toks[0]));
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
    const prog = try testParse("@other_func: void { ret 0 }", alloc);
    try std.testing.expectEqual(@as(usize, 1), prog.functions.items.len);
    try std.testing.expectEqualStrings("other_func", prog.functions.items[0].name);
    try std.testing.expectEqual(Ty.void_, prog.functions.items[0].ret_ty);
    try std.testing.expectEqual(@as(usize, 0), prog.functions.items[0].params.items.len);
}

test "parser: function with empty parens and return type" {
    const alloc = std.testing.allocator;
    const prog = try testParse("@main(): int { ret 0 }", alloc);
    try std.testing.expectEqual(Ty.int, prog.functions.items[0].ret_ty);
}

test "parser: call without args" {
    const alloc = std.testing.allocator;
    const prog = try testParse("@main(): int { call other_func ret 0 }", alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expectEqualStrings("other_func", stmt.call.name);
    try std.testing.expectEqual(@as(usize, 0), stmt.call.args.items.len);
}

test "parser: call with args" {
    const alloc = std.testing.allocator;
    const prog = try testParse("@main(): int { call puts(\"hi\") ret 0 }", alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expectEqualStrings("puts", stmt.call.name);
    try std.testing.expectEqual(@as(usize, 1), stmt.call.args.items.len);
}

test "parser: assign const int" {
    const alloc = std.testing.allocator;
    const prog = try testParse("@main(): int { %x = const 42 ret 0 }", alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expectEqual(@as(RegIdx, 0), stmt.assign.reg);
}

test "parser: assign add expr" {
    const alloc = std.testing.allocator;
    const prog = try testParse("@main(): int { %r = add %a, %b ret 0 }", alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expect(std.meta.activeTag(stmt.assign.expr.*) == .add);
}

test "parser: while loop" {
    const alloc = std.testing.allocator;
    const prog = try testParse("@main(): int { while (lt %i, 10) { call puts(\"x\") } ret 0 }", alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expect(std.meta.activeTag(stmt) == .while_);
}

test "parser: set field" {
    const alloc = std.testing.allocator;
    const prog = try testParse("@main(): int { set %p.age = const 1 ret 0 }", alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expectEqualStrings("age", stmt.set_field.field);
}

test "parser: field access expr" {
    const alloc = std.testing.allocator;
    const prog = try testParse("@main(): int { %v = %p.name ret 0 }", alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expect(std.meta.activeTag(stmt.assign.expr.*) == .field);
    try std.testing.expectEqualStrings("name", stmt.assign.expr.field.field);
}

test "parser: alloc expr" {
    const alloc = std.testing.allocator;
    const prog = try testParse("@main(): int { %buf = alloc 1024 ret 0 }", alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expect(std.meta.activeTag(stmt.assign.expr.*) == .alloc);
}

test "parser: struct definition" {
    const alloc = std.testing.allocator;
    const prog = try testParse("struct Person { name: string age: int }", alloc);
    try std.testing.expectEqual(@as(usize, 1), prog.structs.items.len);
    try std.testing.expectEqualStrings("Person", prog.structs.items[0].name);
    try std.testing.expectEqual(@as(usize, 2), prog.structs.items[0].fields.items.len);
}

test "parser: struct literal in assign" {
    const alloc = std.testing.allocator;
    const prog = try testParse("@main(): int { %p = Person { name: \"Alice\" age: 25 } ret 0 }", alloc);
    const stmt = prog.functions.items[0].body.items[0];
    try std.testing.expect(std.meta.activeTag(stmt.assign.expr.*) == .struct_lit);
}

test "parser: named constant" {
    const alloc = std.testing.allocator;
    const prog = try testParse("@main(): int { %m = READ ret 0 }", alloc);
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
    const list = try tokenize("@other: void { ret 0 }", alloc);
    const prog = try parse(list.items, alloc);
    var vm = Vm.init(&prog, alloc);
    try std.testing.expect(vm.findFunc("main") == null);
}

test "interpreter: undefined register is error" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.NotAStruct,
        evalMain("@main(): int { %v = %nope.field ret 0 }", alloc),
    );
}
