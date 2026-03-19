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

// Perfect hash for keywords — avoids 18 string comparisons per identifier
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
                var s = List(u8).empty;
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
                    const tok = keywordToken(word) orelse Token{ .ident = word };
                    try tokens.append(alloc, tok);
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
const Function = struct { name: []const u8, params: List(Param), ret_ty: Ty, body: List(Stmt) };
const Param = struct { name: []const u8, ty: Ty };
const Program = struct { structs: List(StructDef), functions: List(Function) };

const Stmt = union(enum) {
    assign: struct { reg: []const u8, expr: *Expr },
    set_field: struct { reg: []const u8, field: []const u8, expr: *Expr },
    call: struct { name: []const u8, args: List(*Expr) },
    ret: *Expr,
    while_: struct { cond: *Expr, body: List(Stmt) },
};

const BinOp = struct { a: *Expr, b: *Expr };
const FieldInit = struct { name: []const u8, expr: *Expr };
const Expr = union(enum) {
    int: i64,
    str: []const u8,
    reg: []const u8,
    field: struct { reg: []const u8, field: []const u8 },
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
    OutOfMemory,
};

const Parser = struct {
    tokens: []const Token,
    pos: usize,
    alloc: Allocator,

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

    fn parseArgs(self: *Parser) ParseError!List(*Expr) {
        var args = List(*Expr).empty;
        if (std.meta.activeTag(self.peek()) != .lparen) return args;
        _ = self.advance();
        while (std.meta.activeTag(self.peek()) != .rparen) {
            try args.append(self.alloc, try self.parseExpr());
            if (std.meta.activeTag(self.peek()) == .comma) _ = self.advance();
        }
        _ = try self.expectTag(.rparen);
        return args;
    }

    fn box(self: *Parser, e: Expr) ParseError!*Expr {
        const p = try self.alloc.create(Expr);
        p.* = e;
        return p;
    }

    fn parseBinOp(self: *Parser, comptime tag: TokenTag) ParseError!*Expr {
        _ = self.advance();
        const a = try self.parseExpr();
        _ = try self.expectTag(.comma);
        const b = try self.parseExpr();
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

    fn parseExpr(self: *Parser) ParseError!*Expr {
        return switch (self.peek()) {
            .kw_const => blk: {
                _ = self.advance();
                break :blk try self.box(.{ .const_ = try self.parseExpr() });
            },
            .kw_add => try self.parseBinOp(.kw_add),
            .kw_sub => try self.parseBinOp(.kw_sub),
            .kw_mul => try self.parseBinOp(.kw_mul),
            .kw_div => try self.parseBinOp(.kw_div),
            .kw_lt => try self.parseBinOp(.kw_lt),
            .kw_gt => try self.parseBinOp(.kw_gt),
            .kw_eq => try self.parseBinOp(.kw_eq),
            .kw_call => blk: {
                _ = self.advance();
                const name = switch (self.advance()) {
                    .ident => |s| s,
                    .func => |s| s,
                    else => return error.ExpectedFuncName,
                };
                break :blk try self.box(.{ .call = .{ .name = name, .args = try self.parseArgs() } });
            },
            .kw_alloc => blk: {
                _ = self.advance();
                break :blk try self.box(.{ .alloc = try self.parseExpr() });
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
                if (std.meta.activeTag(self.peek()) == .dot) {
                    _ = self.advance();
                    break :blk try self.box(.{ .field = .{ .reg = r, .field = try self.expectIdent() } });
                }
                break :blk try self.box(.{ .reg = r });
            },
            .ident => |name| blk: {
                _ = self.advance();
                if (std.meta.activeTag(self.peek()) == .lbrace) {
                    _ = self.advance();
                    var fields = List(FieldInit).empty;
                    while (std.meta.activeTag(self.peek()) != .rbrace) {
                        const fname = try self.expectIdent();
                        _ = try self.expectTag(.colon);
                        try fields.append(self.alloc, .{ .name = fname, .expr = try self.parseExpr() });
                    }
                    _ = try self.expectTag(.rbrace);
                    break :blk try self.box(.{ .struct_lit = .{ .name = name, .fields = fields } });
                }
                break :blk try self.box(.{ .named = name });
            },
            else => error.UnexpectedExprToken,
        };
    }

    fn parseStmt(self: *Parser) ParseError!Stmt {
        return switch (self.peek()) {
            .reg => |r| blk: {
                _ = self.advance();
                _ = try self.expectTag(.assign);
                break :blk .{ .assign = .{ .reg = r, .expr = try self.parseExpr() } };
            },
            .kw_set => blk: {
                _ = self.advance();
                const r = try self.expectReg();
                _ = try self.expectTag(.dot);
                const field = try self.expectIdent();
                _ = try self.expectTag(.assign);
                break :blk .{ .set_field = .{ .reg = r, .field = field, .expr = try self.parseExpr() } };
            },
            .kw_call => blk: {
                _ = self.advance();
                const name = switch (self.advance()) {
                    .ident => |s| s,
                    .func => |s| s,
                    else => return error.ExpectedFuncName,
                };
                break :blk .{ .call = .{ .name = name, .args = try self.parseArgs() } };
            },
            .kw_ret => blk: {
                _ = self.advance();
                break :blk .{ .ret = try self.parseExpr() };
            },
            .kw_while => blk: {
                _ = self.advance();
                _ = try self.expectTag(.lparen);
                const cond = try self.parseExpr();
                _ = try self.expectTag(.rparen);
                _ = try self.expectTag(.lbrace);
                var body = List(Stmt).empty;
                while (std.meta.activeTag(self.peek()) != .rbrace)
                    try body.append(self.alloc, try self.parseStmt());
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
        var fields = List(StructField).empty;
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
        var params = List(Param).empty;
        if (std.meta.activeTag(self.peek()) == .lparen) {
            _ = self.advance();
            while (std.meta.activeTag(self.peek()) != .rparen) {
                const pname = try self.expectReg();
                _ = try self.expectTag(.colon);
                try params.append(self.alloc, .{ .name = pname, .ty = try self.parseTy() });
                if (std.meta.activeTag(self.peek()) == .comma) _ = self.advance();
            }
            _ = try self.expectTag(.rparen);
        }
        const ret_ty: Ty = if (std.meta.activeTag(self.peek()) == .colon) blk: {
            _ = self.advance();
            break :blk try self.parseTy();
        } else .void_;
        _ = try self.expectTag(.lbrace);
        var body = List(Stmt).empty;
        while (std.meta.activeTag(self.peek()) != .rbrace)
            try body.append(self.alloc, try self.parseStmt());
        _ = try self.expectTag(.rbrace);
        return .{ .name = name, .params = params, .ret_ty = ret_ty, .body = body };
    }

    fn parseProgram(self: *Parser) ParseError!Program {
        var structs = List(StructDef).empty;
        var functions = List(Function).empty;
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
    var p = Parser{ .tokens = tokens, .pos = 0, .alloc = alloc };
    return p.parseProgram();
}

const Env = std.StringArrayHashMap(Value);

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

    fn evalExpr(self: *Vm, expr: *const Expr, env: *Env) anyerror!Value {
        return switch (expr.*) {
            .int => |n| .{ .int = n },
            .str => |s| .{ .str = s },
            .reg => |r| env.get(r) orelse return error.UndefinedRegister,
            .field => |f| blk: {
                const base = env.get(f.reg) orelse return error.UndefinedRegister;
                break :blk switch (base) {
                    .struct_ => |sv| sv.fields.get(f.field) orelse return error.NoSuchField,
                    else => return error.NotAStruct,
                };
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
            .int => |n| {
                const s = std.fmt.bufPrint(&tmp, "{d}\n", .{n}) catch return;
                writeStdout(s);
            },
            .str => |s| {
                writeStdout(s);
                writeStdout("\n");
            },
            .bool_ => |b| {
                writeStdout(if (b) "true\n" else "false\n");
            },
            .ptr => writeStdout("<ptr>\n"),
            .file => |fd| {
                const s = std.fmt.bufPrint(&tmp, "<fd:{d}>\n", .{fd}) catch return;
                writeStdout(s);
            },
            .void_ => {},
            .struct_ => |sv| {
                writeStdout(sv.name);
                writeStdout(" { ... }\n");
            },
        }
    }

    /// Use a fixed stack buffer for args to avoid heap allocation on every call
    fn callFunc(self: *Vm, name: []const u8, arg_exprs: []*Expr, env: *Env) anyerror!Value {
        var args_buf: [32]Value = undefined;
        const argc = arg_exprs.len;
        std.debug.assert(argc <= 32);
        for (arg_exprs, 0..) |a, i|
            args_buf[i] = try self.evalExpr(a, env);
        const args = args_buf[0..argc];

        if (std.mem.eql(u8, name, "puts")) {
            for (args) |a| self.printValue(a);
            flushStdout();
            return .void_;
        }
        if (std.mem.eql(u8, name, "open")) {
            const path = args[0].str;
            const mode = args[1].int;
            const fd = if (mode == 0) blk: {
                const f = try std.fs.cwd().openFile(path, .{});
                break :blk try self.allocFile(.{ .read = f });
            } else blk: {
                const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
                break :blk try self.allocFile(.{ .write = f });
            };
            return .{ .file = fd };
        }
        if (std.mem.eql(u8, name, "read")) {
            const fd: usize = @intCast(args[0].file);
            const size: usize = @intCast(args[2].int);
            const buf = try self.alloc.alloc(u8, size);
            const n = switch (self.files.items[fd].?) {
                .read => |f| try f.read(buf),
                else => return error.InvalidFileHandle,
            };
            return .{ .str = buf[0..n] };
        }
        if (std.mem.eql(u8, name, "write")) {
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
            return .{ .int = @intCast(data.len) };
        }
        if (std.mem.eql(u8, name, "close")) {
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
            return .void_;
        }

        const func = self.findFunc(name) orelse return error.UndefinedFunction;
        var new_env = Env.init(self.alloc);
        try new_env.ensureTotalCapacity(func.params.items.len + 4);
        for (func.params.items, 0..) |param, i|
            try new_env.put(param.name, args[i]);
        return (try self.execBody(func.body.items, &new_env)) orelse .void_;
    }

    fn execBody(self: *Vm, stmts: []const Stmt, env: *Env) anyerror!?Value {
        for (stmts) |*stmt|
            if (try self.execStmt(stmt, env)) |v| return v;
        return null;
    }

    fn execStmt(self: *Vm, stmt: *const Stmt, env: *Env) anyerror!?Value {
        switch (stmt.*) {
            .assign => |a| {
                try env.put(a.reg, try self.evalExpr(a.expr, env));
            },
            .set_field => |sf| {
                const val = try self.evalExpr(sf.expr, env);
                const entry = env.getPtr(sf.reg) orelse return error.UndefinedRegister;
                try entry.struct_.fields.put(sf.field, val);
            },
            .call => |c| {
                _ = try self.callFunc(c.name, c.args.items, env);
            },
            .ret => |e| return try self.evalExpr(e, env),
            .while_ => |w| {
                while (true) {
                    const cv = try self.evalExpr(w.cond, env);
                    const keep = switch (cv) {
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
    const main_func = vm.findFunc("main") orelse return error.NoMainFunction;
    var env = Env.init(alloc);
    _ = try vm.execBody(main_func.body.items, &env);
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

    const path = argv[1];
    const src = std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024) catch |e| {
        std.debug.print("Error reading {s}: {}\n", .{ path, e });
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
