const std = @import("std");
const bear_main = @import("bear.zig");

pub const TokenTag = enum(u8) {
    int,
    float,
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
    kw_le,
    kw_ge,
    kw_eq,
    kw_ret,
    kw_call,
    kw_while,
    kw_alloc,
    kw_alloc_array,
    kw_set,
    kw_struct,
    kw_jmp,
    kw_br_if,
    kw_spawn,
    kw_sync,
    kw_store,
    kw_load,
    kw_get_field_ref,
    kw_get_index_ref,
    kw_free,
    kw_arena_create,
    kw_arena_alloc,
    kw_arena_destroy,
    kw_phi,
    kw_cast,
    ty_int,
    ty_void,
    ty_string,
    ty_bool,
    ty_float,
    ty_double,
    lbrace,
    rbrace,
    lparen,
    rparen,
    lbracket,
    rbracket,
    colon,
    comma,
    dot,
    assign,
    eof,
};

pub const Token = union(TokenTag) {
    int: i64,
    float: f64,
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
    kw_le,
    kw_ge,
    kw_eq,
    kw_ret,
    kw_call,
    kw_while,
    kw_alloc,
    kw_alloc_array,
    kw_set,
    kw_struct,
    kw_jmp,
    kw_br_if,
    kw_spawn,
    kw_sync,
    kw_store,
    kw_load,
    kw_get_field_ref,
    kw_get_index_ref,
    kw_free,
    kw_arena_create,
    kw_arena_alloc,
    kw_arena_destroy,
    kw_phi,
    kw_cast,
    ty_int,
    ty_void,
    ty_string,
    ty_bool,
    ty_float,
    ty_double,
    lbrace,
    rbrace,
    lparen,
    rparen,
    lbracket,
    rbracket,
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
        .{ "le", Token.kw_le },
        .{ "ge", Token.kw_ge },
        .{ "eq", Token.kw_eq },
        .{ "alloc", Token.kw_alloc },
        .{ "alloc_array", Token.kw_alloc_array },
        .{ "set", Token.kw_set },
        .{ "struct", Token.kw_struct },
        .{ "jmp", Token.kw_jmp },
        .{ "br_if", Token.kw_br_if },
        .{ "spawn", Token.kw_spawn },
        .{ "sync", Token.kw_sync },
        .{ "store", Token.kw_store },
        .{ "load", Token.kw_load },
        .{ "get_field_ref", Token.kw_get_field_ref },
        .{ "get_index_ref", Token.kw_get_index_ref },
        .{ "free", Token.kw_free },
        .{ "arena_create", Token.kw_arena_create },
        .{ "arena_alloc", Token.kw_arena_alloc },
        .{ "arena_destroy", Token.kw_arena_destroy },
        .{ "phi", Token.kw_phi },
        .{ "cast", Token.kw_cast },
        .{ "int", Token.ty_int },
        .{ "void", Token.ty_void },
        .{ "string", Token.ty_string },
        .{ "bool", Token.ty_bool },
        .{ "float", Token.ty_float },
        .{ "double", Token.ty_double },
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
            '[' => {
                try tokens.append(alloc, .lbracket);
                i += 1;
            },
            ']' => {
                try tokens.append(alloc, .rbracket);
                i += 1;
            },
            '"' => {
                i += 1;
                var s: std.ArrayList(u8) = .empty;
                errdefer s.deinit(alloc);
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
                    if (i < src.len and src[i] == '.') {
                        i += 1;
                        while (i < src.len and std.ascii.isDigit(src[i])) i += 1;
                        const f = try std.fmt.parseFloat(f64, src[start - @as(usize, if (neg) 1 else 0) .. i]);
                        try tokens.append(alloc, .{ .float = f });
                    } else {
                        const n = try std.fmt.parseInt(i64, src[start..i], 10);
                        try tokens.append(alloc, .{ .int = if (neg) -n else n });
                    }
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

pub const Ty = enum { int, void_, str, bool_, named, float_, double_ };
pub const StructDef = struct {
    name: []const u8,
    fields: std.ArrayListUnmanaged(StructField),

    pub fn deinit(self: *StructDef, alloc: std.mem.Allocator) void {
        self.fields.deinit(alloc);
    }
};
pub const StructField = struct { name: []const u8, ty: Ty };
pub const RegIdx = u16;
pub const Function = struct {
    name: []const u8,
    params: std.ArrayListUnmanaged(Param),
    ret_ty: Ty,
    body: std.ArrayListUnmanaged(Stmt),
    n_regs: u16,

    pub fn deinit(self: *Function, alloc: std.mem.Allocator) void {
        for (self.body.items) |*s| s.deinit(alloc);
        self.body.deinit(alloc);
        self.params.deinit(alloc);
    }
};

pub const Param = struct { name: []const u8, ty: Ty, idx: RegIdx };
pub const Program = struct {
    structs: std.ArrayListUnmanaged(StructDef),
    functions: std.ArrayListUnmanaged(Function),
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
    call: struct { name: []const u8, args: std.ArrayListUnmanaged(*Expr) },
    ret: *Expr,
    while_: struct { cond: *Expr, body: std.ArrayListUnmanaged(Stmt) },
    label: []const u8,
    jmp: []const u8,
    br_if: struct { cond: RegIdx, true_label: []const u8, false_label: []const u8 },
    store: struct { ptr: RegIdx, expr: *Expr },
    free: RegIdx,
    arena_destroy: RegIdx,
    ret_void,

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
pub const PhiArm = struct { label: []const u8, reg: RegIdx };
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
    le: BinOp,
    ge: BinOp,
    eq: BinOp,
    call: struct { name: []const u8, args: std.ArrayListUnmanaged(*Expr) },
    alloc: *Expr,
    alloc_type: []const u8,
    alloc_array: struct { elem_ty: Ty, count: *Expr },
    alloc_array_struct: struct { type_name: []const u8, count: *Expr },
    load: RegIdx,
    get_field_ref: struct { ptr: RegIdx, field: []const u8 },
    get_index_ref: struct { arr: RegIdx, idx: *Expr },
    struct_lit: struct { name: []const u8, fields: std.ArrayListUnmanaged(FieldInit) },
    named: []const u8,
    spawn: struct { name: []const u8, args: std.ArrayListUnmanaged(*Expr) },
    sync: RegIdx,
    free: RegIdx,
    arena_create,
    arena_alloc: struct { arena: RegIdx, size: *Expr },
    phi: std.ArrayListUnmanaged(PhiArm),
    float_lit: f64,
    cast: struct { ty: Ty, expr: *Expr },
};

pub const ExprSlab = struct {
    buf: []Expr,
    used: usize,

    pub fn init(alloc: std.mem.Allocator, cap: usize) !ExprSlab {
        return .{ .buf = try alloc.alloc(Expr, cap), .used = 0 };
    }

    pub fn deinit(self: *ExprSlab, alloc: std.mem.Allocator) void {
        for (self.buf[0..self.used]) |*e| {
            switch (e.*) {
                .struct_lit => |*sl| sl.fields.deinit(alloc),
                .call => |*c| c.args.deinit(alloc),
                .spawn => |*s| s.args.deinit(alloc),
                .phi => |*arms| arms.deinit(alloc),
                else => {},
            }
        }
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
