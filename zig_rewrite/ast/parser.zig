//! The parser module provides a top-level `parse` function that converts
//! a stream of tokens into an AST.
//!
//! It's responsible for parsing the tokens into a structured AST representation.

const std = @import("std");
const lexer = @import("lexer.zig");

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
    names: std.ArrayListUnmanaged([]const u8),
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) RegMap {
        return .{ .names = .empty, .alloc = alloc };
    }

    fn deinit(self: *RegMap) void {
        self.names.deinit(self.alloc);
    }

    fn intern(self: *RegMap, name: []const u8) !lexer.RegIdx {
        for (self.names.items, 0..) |n, i|
            if (std.mem.eql(u8, n, name)) return @intCast(i);
        const idx: lexer.RegIdx = @intCast(self.names.items.len);
        if (idx == std.math.maxInt(lexer.RegIdx)) return error.TooManyRegisters;
        try self.names.append(self.alloc, name);
        return idx;
    }

    fn count(self: *const RegMap) u16 {
        return @intCast(self.names.items.len);
    }
};

const Parser = struct {
    tokens: []const lexer.Token,
    pos: usize,
    alloc: std.mem.Allocator,
    slab: *lexer.ExprSlab,

    fn peek(self: *Parser) lexer.Token {
        return self.tokens[self.pos];
    }

    fn advance(self: *Parser) lexer.Token {
        const t = self.tokens[self.pos];
        if (self.pos + 1 < self.tokens.len) self.pos += 1;
        return t;
    }

    fn expectTag(self: *Parser, tag: lexer.TokenTag) ParseError!lexer.Token {
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

    /// Accept any token that can serve as a function name in a call expression:
    /// .ident, .func, or any type/keyword token whose string we know statically.
    fn parseFuncName(self: *Parser) ParseError![]const u8 {
        return switch (self.advance()) {
            .ident => |s| s,
            .func => |s| s,
            .ty_int => "int",
            .ty_void => "void",
            .ty_string => "string",
            .ty_bool => "bool",
            .ty_float => "float",
            .ty_double => "double",
            else => error.ExpectedFuncName,
        };
    }

    fn parseTy(self: *Parser) ParseError!lexer.Ty {
        return switch (self.advance()) {
            .ty_int => .int,
            .ty_void => .void_,
            .ty_string => .str,
            .ty_bool => .bool_,
            .ty_float => .float_,
            .ty_double => .double_,
            .ident => .named,
            else => error.ExpectedType,
        };
    }

    fn parseArgs(self: *Parser, rm: *RegMap) ParseError!std.ArrayList(*lexer.Expr) {
        var args: std.ArrayList(*lexer.Expr) = .empty;
        if (std.meta.activeTag(self.peek()) != .lparen) return args;
        _ = self.advance();
        while (std.meta.activeTag(self.peek()) != .rparen) {
            try args.append(self.alloc, try self.parseExpr(rm));
            if (std.meta.activeTag(self.peek()) == .comma) _ = self.advance();
        }
        _ = try self.expectTag(.rparen);
        return args;
    }

    fn box(self: *Parser, e: lexer.Expr) ParseError!*lexer.Expr {
        return self.slab.alloc_node(e);
    }

    fn parseBinOp(self: *Parser, rm: *RegMap, comptime tag: lexer.TokenTag) ParseError!*lexer.Expr {
        _ = self.advance();
        const a = try self.parseExpr(rm);
        _ = try self.expectTag(.comma);
        const b = try self.parseExpr(rm);
        const payload = lexer.BinOp{ .a = a, .b = b };
        return self.box(switch (tag) {
            .kw_add => .{ .add = payload },
            .kw_sub => .{ .sub = payload },
            .kw_mul => .{ .mul = payload },
            .kw_div => .{ .div = payload },
            .kw_lt => .{ .lt = payload },
            .kw_gt => .{ .gt = payload },
            .kw_le => .{ .le = payload },
            .kw_ge => .{ .ge = payload },
            .kw_eq => .{ .eq = payload },
            else => unreachable,
        });
    }

    fn parseExpr(self: *Parser, rm: *RegMap) ParseError!*lexer.Expr {
        return switch (self.peek()) {
            .kw_const => blk: {
                _ = self.advance();
                const inner = try self.parseExpr(rm);
                if (std.meta.activeTag(self.peek()) == .colon) {
                    _ = self.advance();
                    const ty = try self.parseTy();
                    break :blk try self.box(.{ .cast = .{ .ty = ty, .expr = inner } });
                }
                break :blk inner;
            },
            .kw_add => try self.parseBinOp(rm, .kw_add),
            .kw_sub => try self.parseBinOp(rm, .kw_sub),
            .kw_mul => try self.parseBinOp(rm, .kw_mul),
            .kw_div => try self.parseBinOp(rm, .kw_div),
            .kw_lt => try self.parseBinOp(rm, .kw_lt),
            .kw_gt => try self.parseBinOp(rm, .kw_gt),
            .kw_le => try self.parseBinOp(rm, .kw_le),
            .kw_ge => try self.parseBinOp(rm, .kw_ge),
            .kw_eq => try self.parseBinOp(rm, .kw_eq),
            .kw_call => blk: {
                _ = self.advance();
                const name = try self.parseFuncName();
                break :blk try self.box(.{ .call = .{ .name = name, .args = try self.parseArgs(rm) } });
            },
            .kw_spawn => blk: {
                _ = self.advance(); // consume 'spawn'
                _ = try self.expectTag(.kw_call);
                const name = try self.parseFuncName();
                break :blk try self.box(.{ .spawn = .{ .name = name, .args = try self.parseArgs(rm) } });
            },
            .kw_sync => blk: {
                _ = self.advance();
                const r = try self.expectReg();
                const idx = try rm.intern(r);
                break :blk try self.box(.{ .sync = idx });
            },
            .kw_free => blk: {
                _ = self.advance();
                const r = try self.expectReg();
                const idx = try rm.intern(r);
                break :blk try self.box(.{ .free = idx });
            },
            .kw_arena_create => blk: {
                _ = self.advance();
                break :blk try self.box(.arena_create);
            },
            .kw_arena_alloc => blk: {
                _ = self.advance();
                const r = try self.expectReg();
                const arena_idx = try rm.intern(r);
                _ = try self.expectTag(.comma);
                const size_expr = try self.parseExpr(rm);
                break :blk try self.box(.{ .arena_alloc = .{ .arena = arena_idx, .size = size_expr } });
            },
            .kw_phi => blk: {
                _ = self.advance();
                _ = try self.expectTag(.lbracket);
                var arms: std.ArrayList(lexer.PhiArm) = .empty;
                while (std.meta.activeTag(self.peek()) != .rbracket) {
                    const lbl = try self.expectIdent();
                    _ = try self.expectTag(.colon);
                    const r = try self.expectReg();
                    const idx = try rm.intern(r);
                    try arms.append(self.alloc, .{ .label = lbl, .reg = idx });
                    if (std.meta.activeTag(self.peek()) == .comma) _ = self.advance();
                }
                _ = try self.expectTag(.rbracket);
                break :blk try self.box(.{ .phi = arms });
            },
            .kw_alloc => blk: {
                _ = self.advance();
                if (std.meta.activeTag(self.peek()) == .ident) {
                    const type_name = self.peek().ident;
                    _ = self.advance();
                    break :blk try self.box(.{ .alloc_type = type_name });
                }
                break :blk try self.box(.{ .alloc = try self.parseExpr(rm) });
            },
            .kw_alloc_array => blk: {
                _ = self.advance();
                if (std.meta.activeTag(self.peek()) == .ident) {
                    const type_name = self.peek().ident;
                    _ = self.advance();
                    _ = try self.expectTag(.comma);
                    const count = try self.parseExpr(rm);
                    break :blk try self.box(.{ .alloc_array_struct = .{ .type_name = type_name, .count = count } });
                }
                const elem_ty = try self.parseTy();
                _ = try self.expectTag(.comma);
                const count = try self.parseExpr(rm);
                break :blk try self.box(.{ .alloc_array = .{ .elem_ty = elem_ty, .count = count } });
            },
            .kw_load => blk: {
                _ = self.advance();
                const r = try self.expectReg();
                const idx = try rm.intern(r);
                break :blk try self.box(.{ .load = idx });
            },
            .kw_get_field_ref => blk: {
                _ = self.advance();
                const r = try self.expectReg();
                const ptr_idx = try rm.intern(r);
                _ = try self.expectTag(.comma);
                const field = try self.expectIdent();
                break :blk try self.box(.{ .get_field_ref = .{ .ptr = ptr_idx, .field = field } });
            },
            .kw_get_index_ref => blk: {
                _ = self.advance();
                const r = try self.expectReg();
                const arr_idx = try rm.intern(r);
                _ = try self.expectTag(.comma);
                const idx_expr = try self.parseExpr(rm);
                break :blk try self.box(.{ .get_index_ref = .{ .arr = arr_idx, .idx = idx_expr } });
            },
            .kw_cast => blk: {
                _ = self.advance();
                const ty = try self.parseTy();
                const inner = try self.parseExpr(rm);
                break :blk try self.box(.{ .cast = .{ .ty = ty, .expr = inner } });
            },
            .int => |n| blk: {
                _ = self.advance();
                break :blk try self.box(.{ .int = n });
            },
            .float => |f| blk: {
                _ = self.advance();
                break :blk try self.box(.{ .float_lit = f });
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
                    var fields: std.ArrayList(lexer.FieldInit) = .empty;
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
            .lbrace => blk: {
                _ = self.advance();
                var fields: std.ArrayList(lexer.FieldInit) = .empty;
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
                break :blk try self.box(.{ .struct_lit = .{ .name = "", .fields = fields } });
            },
            else => error.UnexpectedExprToken,
        };
    }

    fn parseStmt(self: *Parser, rm: *RegMap) ParseError!lexer.Stmt {
        return switch (self.peek()) {
            .ident => |name| blk: {
                if (self.pos + 1 < self.tokens.len and
                    std.meta.activeTag(self.tokens[self.pos + 1]) == .colon)
                {
                    _ = self.advance();
                    _ = self.advance();
                    break :blk .{ .label = name };
                }
                break :blk error.UnexpectedStmtToken;
            },
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
                const name = try self.parseFuncName();
                break :blk .{ .call = .{ .name = name, .args = try self.parseArgs(rm) } };
            },
            .kw_ret => blk: {
                _ = self.advance();
                const next = std.meta.activeTag(self.peek());
                if (next == .rbrace or next == .eof or next == .func) {
                    break :blk .ret_void;
                }
                break :blk .{ .ret = try self.parseExpr(rm) };
            },
            .kw_jmp => blk: {
                _ = self.advance();
                const target = try self.expectIdent();
                break :blk .{ .jmp = target };
            },
            .kw_br_if => blk: {
                _ = self.advance();
                const cond_name = try self.expectReg();
                const cond_idx = try rm.intern(cond_name);
                _ = try self.expectTag(.comma);
                const true_label = try self.expectIdent();
                _ = try self.expectTag(.comma);
                const false_label = try self.expectIdent();
                break :blk .{ .br_if = .{
                    .cond = cond_idx,
                    .true_label = true_label,
                    .false_label = false_label,
                } };
            },
            .kw_while => blk: {
                _ = self.advance();
                _ = try self.expectTag(.lparen);
                const cond = try self.parseExpr(rm);
                _ = try self.expectTag(.rparen);
                _ = try self.expectTag(.lbrace);
                var body: std.ArrayList(lexer.Stmt) = .empty;
                while (std.meta.activeTag(self.peek()) != .rbrace)
                    try body.append(self.alloc, try self.parseStmt(rm));
                _ = try self.expectTag(.rbrace);
                break :blk .{ .while_ = .{ .cond = cond, .body = body } };
            },
            .kw_store => blk: {
                _ = self.advance();
                const r = try self.expectReg();
                const ptr_idx = try rm.intern(r);
                _ = try self.expectTag(.comma);
                const val_expr = try self.parseExpr(rm);
                break :blk .{ .store = .{ .ptr = ptr_idx, .expr = val_expr } };
            },
            .kw_free => blk: {
                _ = self.advance();
                const r = try self.expectReg();
                const idx = try rm.intern(r);
                break :blk .{ .free = idx };
            },
            .kw_arena_destroy => blk: {
                _ = self.advance();
                const r = try self.expectReg();
                const idx = try rm.intern(r);
                break :blk .{ .arena_destroy = idx };
            },
            else => error.UnexpectedStmtToken,
        };
    }

    fn parseStruct(self: *Parser) ParseError!lexer.StructDef {
        _ = try self.expectTag(.kw_struct);
        const name = try self.expectIdent();
        _ = try self.expectTag(.lbrace);
        var fields: std.ArrayList(lexer.StructField) = .empty;
        while (std.meta.activeTag(self.peek()) != .rbrace) {
            const fname = try self.expectIdent();
            _ = try self.expectTag(.colon);
            try fields.append(self.alloc, .{ .name = fname, .ty = try self.parseTy() });
        }
        _ = try self.expectTag(.rbrace);
        return .{ .name = name, .fields = fields };
    }

    fn parseFunction(self: *Parser) ParseError!lexer.Function {
        const name = try self.expectFunc();
        var rm = RegMap.init(self.alloc);
        defer rm.deinit();

        var params: std.ArrayList(lexer.Param) = .empty;
        errdefer params.deinit(self.alloc);
        if (std.meta.activeTag(self.peek()) == .lparen) {
            _ = self.advance();
            while (std.meta.activeTag(self.peek()) != .rparen) {
                const pname = try self.expectReg();
                const ty: lexer.Ty = if (std.meta.activeTag(self.peek()) == .colon) blk: {
                    _ = self.advance();
                    break :blk try self.parseTy();
                } else .int;
                const idx = try rm.intern(pname);
                try params.append(self.alloc, .{ .name = pname, .ty = ty, .idx = idx });
                if (std.meta.activeTag(self.peek()) == .comma) _ = self.advance();
            }
            _ = try self.expectTag(.rparen);
        }
        const ret_ty: lexer.Ty = if (std.meta.activeTag(self.peek()) == .colon) blk: {
            _ = self.advance();
            break :blk try self.parseTy();
        } else .void_;
        _ = try self.expectTag(.lbrace);
        var body: std.ArrayList(lexer.Stmt) = .empty;
        errdefer {
            for (body.items) |*s| s.deinit(self.alloc);
            body.deinit(self.alloc);
        }
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

    fn parseProgram(self: *Parser) ParseError!lexer.Program {
        var structs: std.ArrayList(lexer.StructDef) = .empty;
        errdefer {
            for (structs.items) |*s| s.deinit(self.alloc);
            structs.deinit(self.alloc);
        }
        var functions: std.ArrayList(lexer.Function) = .empty;
        errdefer {
            for (functions.items) |*f| f.deinit(self.alloc);
            functions.deinit(self.alloc);
        }
        while (std.meta.activeTag(self.peek()) != .eof) {
            switch (self.peek()) {
                .kw_struct => try structs.append(self.alloc, try self.parseStruct()),
                .func => try functions.append(self.alloc, try self.parseFunction()),
                else => return error.UnexpectedTopLevel,
            }
        }
        return .{ .structs = structs, .functions = functions, .slab = undefined, .tokens = undefined };
    }
};

pub fn parse(tokens: []const lexer.Token, token_list: std.ArrayList(lexer.Token), alloc: std.mem.Allocator) !lexer.Program {
    var slab = try lexer.ExprSlab.init(alloc, tokens.len / 3 + 64);
    errdefer slab.deinit(alloc);
    var p = Parser{ .tokens = tokens, .pos = 0, .alloc = alloc, .slab = &slab };
    var prog = try p.parseProgram();
    prog.slab = slab;
    prog.tokens = token_list;
    return prog;
}
