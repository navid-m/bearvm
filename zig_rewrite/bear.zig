// Bear language VM - Zig rewrite (Zig 0.15)
// Single-file: lexer + parser + AST + interpreter

const std = @import("std");
const Allocator = std.mem.Allocator;

// We use an arena for all AST/token allocations so we never need to free individually.
// The ArrayList type in Zig 0.15 is unmanaged: pass allocator to append/deinit.
const List = std.ArrayList;

// ─── Lexer ────────────────────────────────────────────────────────────────────

const TokenTag = enum {
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

fn tokenize(src: []const u8, alloc: Allocator) !List(Token) {
    var tokens = List(Token).empty;
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
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
                    const tok: Token =
                        if (std.mem.eql(u8, word, "const")) .kw_const else if (std.mem.eql(u8, word, "add")) .kw_add else if (std.mem.eql(u8, word, "sub")) .kw_sub else if (std.mem.eql(u8, word, "mul")) .kw_mul else if (std.mem.eql(u8, word, "div")) .kw_div else if (std.mem.eql(u8, word, "lt")) .kw_lt else if (std.mem.eql(u8, word, "gt")) .kw_gt else if (std.mem.eql(u8, word, "eq")) .kw_eq else if (std.mem.eql(u8, word, "ret")) .kw_ret else if (std.mem.eql(u8, word, "call")) .kw_call else if (std.mem.eql(u8, word, "while")) .kw_while else if (std.mem.eql(u8, word, "alloc")) .kw_alloc else if (std.mem.eql(u8, word, "set")) .kw_set else if (std.mem.eql(u8, word, "struct")) .kw_struct else if (std.mem.eql(u8, word, "int")) .ty_int else if (std.mem.eql(u8, word, "void")) .ty_void else if (std.mem.eql(u8, word, "string")) .ty_string else if (std.mem.eql(u8, word, "bool")) .ty_bool else .{ .ident = word };
                    try tokens.append(alloc, tok);
                } else return error.UnexpectedChar;
            },
        }
    }
    try tokens.append(alloc, .eof);
    return tokens;
}

// ─── AST ──────────────────────────────────────────────────────────────────────

const Ty = enum { int, void_, str, bool_, named };

const StructDef = struct {
    name: []const u8,
    fields: List(StructField),
};
const StructField = struct { name: []const u8, ty: Ty };

const Function = struct {
    name: []const u8,
    params: List(Param),
    ret_ty: Ty,
    body: List(Stmt),
};
const Param = struct { name: []const u8, ty: Ty };

const Program = struct {
    structs: List(StructDef),
    functions: List(Function),
};

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

// ─── Parser ───────────────────────────────────────────────────────────────────

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

    fn expectTag(self: *Parser, tag: TokenTag) !Token {
        const t = self.advance();
        if (std.meta.activeTag(t) == tag) return t;
        return error.UnexpectedToken;
    }

    fn expectIdent(self: *Parser) ![]const u8 {
        return switch (self.advance()) {
            .ident => |s| s,
            else => error.ExpectedIdent,
        };
    }
    fn expectReg(self: *Parser) ![]const u8 {
        return switch (self.advance()) {
            .reg => |s| s,
            else => error.ExpectedReg,
        };
    }
    fn expectFunc(self: *Parser) ![]const u8 {
        return switch (self.advance()) {
            .func => |s| s,
            else => error.ExpectedFunc,
        };
    }

    fn parseTy(self: *Parser) !Ty {
        return switch (self.advance()) {
            .ty_int => .int,
            .ty_void => .void_,
            .ty_string => .str,
            .ty_bool => .bool_,
            .ident => .named,
            else => error.ExpectedType,
        };
    }

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

    fn parseBinOp(self: *Parser, tag: TokenTag) ParseError!*Expr {
        _ = self.advance();
        const a = try self.parseExpr();
        _ = try self.expectTag(.comma);
        const b = try self.parseExpr();
        return switch (tag) {
            .kw_add => try self.box(.{ .add = .{ .a = a, .b = b } }),
            .kw_sub => try self.box(.{ .sub = .{ .a = a, .b = b } }),
            .kw_mul => try self.box(.{ .mul = .{ .a = a, .b = b } }),
            .kw_div => try self.box(.{ .div = .{ .a = a, .b = b } }),
            .kw_lt => try self.box(.{ .lt = .{ .a = a, .b = b } }),
            .kw_gt => try self.box(.{ .gt = .{ .a = a, .b = b } }),
            .kw_eq => try self.box(.{ .eq = .{ .a = a, .b = b } }),
            else => unreachable,
        };
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
                    const f = try self.expectIdent();
                    break :blk try self.box(.{ .field = .{ .reg = r, .field = f } });
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

// ─── Interpreter ─────────────────────────────────────────────────────────────

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
    fields: std.StringHashMap(Value),
};

const FileHandle = union(enum) {
    read: std.fs.File,
    write: std.fs.File,
};

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

    fn evalExpr(self: *Vm, expr: *const Expr, env: *std.StringHashMap(Value)) anyerror!Value {
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
            .add => |op| .{ .int = (try self.evalExpr(op.a, env)).int + (try self.evalExpr(op.b, env)).int },
            .sub => |op| .{ .int = (try self.evalExpr(op.a, env)).int - (try self.evalExpr(op.b, env)).int },
            .mul => |op| .{ .int = (try self.evalExpr(op.a, env)).int * (try self.evalExpr(op.b, env)).int },
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
                var fields = std.StringHashMap(Value).init(self.alloc);
                for (sl.fields.items) |fi|
                    try fields.put(fi.name, try self.evalExpr(fi.expr, env));
                break :blk .{ .struct_ = .{ .name = sl.name, .fields = fields } };
            },
            .named => |name| if (std.mem.eql(u8, name, "READ")) .{ .int = 0 } else if (std.mem.eql(u8, name, "WRITE")) .{ .int = 1 } else return error.UnknownNamedConstant,
            .call => |c| try self.callFunc(c.name, c.args.items, env),
        };
    }

    fn printValue(_: *Vm, val: Value) void {
        switch (val) {
            .int => |n| std.debug.print("{d}\n", .{n}),
            .str => |s| std.debug.print("{s}\n", .{s}),
            .bool_ => |b| std.debug.print("{}\n", .{b}),
            .ptr => std.debug.print("<ptr>\n", .{}),
            .file => |fd| std.debug.print("<fd:{d}>\n", .{fd}),
            .void_ => {},
            .struct_ => |sv| std.debug.print("{s} {{ ... }}\n", .{sv.name}),
        }
    }

    fn callFunc(self: *Vm, name: []const u8, arg_exprs: []*Expr, env: *std.StringHashMap(Value)) anyerror!Value {
        var args = List(Value).empty;
        for (arg_exprs) |a| try args.append(self.alloc, try self.evalExpr(a, env));

        if (std.mem.eql(u8, name, "puts")) {
            for (args.items) |a| self.printValue(a);
            return .void_;
        }
        if (std.mem.eql(u8, name, "open")) {
            const path = args.items[0].str;
            const mode = args.items[1].int;
            const fd = if (mode == 0) blk: {
                const f = std.fs.cwd().openFile(path, .{}) catch |err| {
                    std.debug.print("failed: {}\n", .{err});
                    return error.InvalidFileHandle;
                };
                break :blk try self.allocFile(.{ .read = f });
            } else blk: {
                const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
                break :blk try self.allocFile(.{ .write = f });
            };
            return .{ .file = fd };
        }
        if (std.mem.eql(u8, name, "read")) {
            const fd: usize = @intCast(args.items[0].file);
            const size: usize = @intCast(args.items[2].int);
            const buf = try self.alloc.alloc(u8, size);
            const n = switch (self.files.items[fd].?) {
                .read => |f| try f.read(buf),
                else => return error.InvalidFileHandle,
            };
            return .{ .str = buf[0..n] };
        }
        if (std.mem.eql(u8, name, "write")) {
            const fd: usize = @intCast(args.items[0].file);
            const data: []const u8 = switch (args.items[1]) {
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
            const fd: usize = @intCast(args.items[0].file);
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

        // user-defined function
        const func = self.findFunc(name) orelse return error.UndefinedFunction;
        var new_env = std.StringHashMap(Value).init(self.alloc);
        for (func.params.items, 0..) |param, i|
            try new_env.put(param.name, args.items[i]);
        return (try self.execBody(func.body.items, &new_env)) orelse .void_;
    }

    fn execBody(self: *Vm, stmts: []const Stmt, env: *std.StringHashMap(Value)) anyerror!?Value {
        for (stmts) |*stmt|
            if (try self.execStmt(stmt, env)) |v| return v;
        return null;
    }

    fn execStmt(self: *Vm, stmt: *const Stmt, env: *std.StringHashMap(Value)) anyerror!?Value {
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
    var env = std.StringHashMap(Value).init(alloc);
    _ = try vm.execBody(main_func.body.items, &env);
}

// ─── Entry point ─────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const argv = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, argv);

    if (argv.len < 2) {
        std.debug.print("Usage: bear <file.bear>\n", .{});
        std.process.exit(1);
    }

    const path = argv[1];
    const src = std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024) catch |e| {
        std.debug.print("Error reading {s}: {}\n", .{ path, e });
        std.process.exit(1);
    };
    defer alloc.free(src);

    var tokens = tokenize(src, alloc) catch |e| {
        std.debug.print("Lex error: {}\n", .{e});
        std.process.exit(1);
    };
    defer tokens.deinit(alloc);

    const program = parse(tokens.items, alloc) catch |e| {
        std.debug.print("Parse error: {}\n", .{e});
        std.process.exit(1);
    };

    run(&program, alloc) catch |e| {
        std.debug.print("Runtime error: {}\n", .{e});
        std.process.exit(1);
    };
}
