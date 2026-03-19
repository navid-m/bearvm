const std = @import("std");
const bear_main = @import("bear.zig");

pub const TokenTag = enum(u8) {
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

pub const Token = union(TokenTag) {
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
pub fn keywordToken(word: []const u8) ?Token {
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

pub fn freeTokenSlice(tokens: []Token, alloc: std.mem.Allocator) void {
    for (tokens) |tok| {
        if (tok == .str) alloc.free(tok.str);
    }
    alloc.free(tokens);
}

pub fn freeTokens(tokens: std.ArrayList(Token), alloc: std.mem.Allocator) void {
    for (tokens.items) |tok| {
        if (tok == .str) alloc.free(tok.str);
    }
    var t = tokens;
    t.deinit(alloc);
}

pub fn tokenize(src: []const u8, alloc: std.mem.Allocator) !std.ArrayList(Token) {
    var tokens = try std.ArrayList(Token).initCapacity(alloc, src.len / 4 + 8);
    errdefer freeTokens(tokens, alloc);
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
                var s: std.ArrayList(u8) = .empty;
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

pub const Ty = enum { int, void_, str, bool_, named };
pub const StructDef = struct {
    name: []const u8,
    fields: std.ArrayList(StructField),

    pub fn deinit(self: *StructDef, alloc: std.mem.Allocator) void {
        self.fields.deinit(alloc);
    }
};
pub const StructField = struct { name: []const u8, ty: Ty };
pub const RegIdx = u16;
pub const Function = struct {
    name: []const u8,
    params: std.ArrayList(Param),
    ret_ty: Ty,
    body: std.ArrayList(Stmt),
    n_regs: u16,

    pub fn deinit(self: *Function, alloc: std.mem.Allocator) void {
        for (self.body.items) |*s| s.deinit(alloc);
        self.body.deinit(alloc);
        self.params.deinit(alloc);
    }
};

pub const Param = struct { name: []const u8, ty: Ty, idx: RegIdx };
pub const Program = struct {
    structs: std.ArrayList(StructDef),
    functions: std.ArrayList(Function),
    slab: ExprSlab,
    tokens: std.ArrayList(Token),

    pub fn deinit(self: *Program, alloc: std.mem.Allocator) void {
        for (self.structs.items) |*s| s.deinit(alloc);
        self.structs.deinit(alloc);
        for (self.functions.items) |*f| f.deinit(alloc);
        self.functions.deinit(alloc);
        self.slab.deinit(alloc);
        freeTokens(self.tokens, alloc);
    }
};
pub const Stmt = union(enum) {
    assign: struct { reg: RegIdx, expr: *Expr },
    set_field: struct { reg: RegIdx, field: []const u8, expr: *Expr },
    call: struct { name: []const u8, args: std.ArrayList(*Expr) },
    ret: *Expr,
    while_: struct { cond: *Expr, body: std.ArrayList(Stmt) },

    pub fn deinit(self: *Stmt, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .call => |*c| c.args.deinit(alloc),
            .while_ => |*w| {
                for (w.body.items) |*s| s.deinit(alloc);
                w.body.deinit(alloc);
            },
            else => {},
        }
    }
};

pub const BinOp = struct { a: *Expr, b: *Expr };
pub const FieldInit = struct { name: []const u8, expr: *Expr };
pub const Expr = union(enum) {
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
    call: struct { name: []const u8, args: std.ArrayList(*Expr) },
    alloc: *Expr,
    struct_lit: struct { name: []const u8, fields: std.ArrayList(FieldInit) },
    named: []const u8,
};

pub const ExprSlab = struct {
    buf: []Expr,
    used: usize,

    pub fn init(alloc: std.mem.Allocator, cap: usize) !ExprSlab {
        return .{ .buf = try alloc.alloc(Expr, cap), .used = 0 };
    }

    pub fn deinit(self: *ExprSlab, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
    }

    pub fn alloc_node(self: *ExprSlab, e: Expr) error{OutOfMemory}!*Expr {
        if (self.used >= self.buf.len) return error.OutOfMemory;
        const p = &self.buf[self.used];
        p.* = e;
        self.used += 1;
        return p;
    }
};
