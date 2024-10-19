const std = @import("std");
const autodoc = @import("../Autodoc.zig");
const src_render = @import("render_source.zig");
const gem = @import("../render.zig");

const assert = std.debug.assert;

const Self = @This();

data: autodoc.DocData,
canvas: *gem.Document,
alloc: std.mem.Allocator,

pub fn renderContainer(
    self: *Self,
    container_idx: usize,
    name: []const u8,
) !void {
    const cont = self.data.types[container_idx];
    assert(typeIsContainer(cont));

    const pubDecls = switch (cont) {
        .Struct => |s| s.pubDecls,
        .Enum => |e| e.pubDecls,
        .Union => |u| u.pubDecls,
        .Opaque => |o| o.pubDecls,
        else => unreachable,
    };

    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    var types: DeclList = .{};
    var values: DeclList = .{};
    var vars: DeclList = .{};
    var namespaces: DeclList = .{};
    var funcs: DeclList = .{};
    var uns: DeclList = .{};
    defer {
        types.deinit(alloc);
        values.deinit(alloc);
        vars.deinit(alloc);
        namespaces.deinit(alloc);
        funcs.deinit(alloc);
        uns.deinit(alloc);
    }

    try self.categorizeDecls(
        pubDecls,
        alloc,
        &types,
        &values,
        &vars,
        &namespaces,
        &funcs,
        &uns,
    );

    while (uns.items.len > 0) {
        const un: autodoc.Decl = uns.pop();
        const un_value = try self.resolveValue(un.value);
        if (un_value.expr != .type) continue;
        const uns_type = self.data.types[un_value.expr.type];
        if (!typeIsContainer(uns_type)) continue;
        const uns_pubDecls = switch (uns_type) {
            .Struct => |s| s.pubDecls,
            .Enum => |e| e.pubDecls,
            .Union => |u| u.pubDecls,
            .Opaque => |o| o.pubDecls,
            else => unreachable,
        };
        try self.categorizeDecls(
            uns_pubDecls,
            alloc,
            &types,
            &values,
            &vars,
            &namespaces,
            &funcs,
            &uns,
        );
    }

    if (namespaces.items.len > 0) {
        try self.canvas.addHeading(.h2, "Namespaces");
        for (namespaces.items) |nsp| {
            const link = try std.fmt.allocPrint(
                alloc,
                "{s}/{s}.gmi",
                .{ name, nsp.name },
            );
            defer alloc.free(link);
            try self.canvas.addLink(link, nsp.name);
            const ast = self.data.astNodes[nsp.src];
            if (ast.docs) |docs| {
                try self.canvas.addPreformatted(docs, "Doc comment");
            }
            try self.canvas.addText("");
        }
    }

    if (types.items.len > 0) {
        try self.canvas.addHeading(.h2, "Types");
        for (types.items) |t| {
            const link = try std.fmt.allocPrint(
                alloc,
                "{s}/{s}.gmi",
                .{ name, t.name },
            );
            defer alloc.free(link);
            try self.canvas.addLink(link, t.name);
            const ast = self.data.astNodes[t.src];
            if (ast.docs) |docs| {
                try self.canvas.addPreformatted(docs, "Doc comment");
            }
            try self.canvas.addText("");
        }
    }

    if (funcs.items.len > 0) {
        try self.canvas.addHeading(.h2, "Functions");
        for (funcs.items) |f| {
            const link = try std.fmt.allocPrint(
                alloc,
                "{s}/{s}.gmi",
                .{ name, f.name },
            );
            defer alloc.free(link);
            try self.canvas.addLink(link, f.name);
            try self.renderFnSignature(f);
            const ast = self.data.astNodes[f.src];
            if (ast.docs) |docs| {
                try self.canvas.addPreformatted(docs, "Doc comment");
            }
            try self.canvas.addText("");
        }
    }

    if (values.items.len > 0) {
        try self.canvas.addHeading(.h2, "Values");
        for (values.items) |v| {
            const link = try std.fmt.allocPrint(
                alloc,
                "{s}/{s}.gmi",
                .{ name, v.name },
            );
            defer alloc.free(link);
            try self.canvas.addLink(link, v.name);
            const ast = self.data.astNodes[v.src];
            if (ast.docs) |docs| {
                try self.canvas.addPreformatted(docs, "Doc comment");
            }
            try self.canvas.addText("");
        }
    }

    if (vars.items.len > 0) {
        try self.canvas.addHeading(.h2, "Variables");
        for (vars.items) |v| {
            const link = try std.fmt.allocPrint(
                alloc,
                "{s}/{s}.gmi",
                .{ name, v.name },
            );
            defer alloc.free(link);
            try self.canvas.addLink(link, v.name);
            const ast = self.data.astNodes[v.src];
            if (ast.docs) |docs| {
                try self.canvas.addPreformatted(docs, "Doc comment");
            }
            try self.canvas.addText("");
        }
    }
}

const DeclList = std.ArrayListUnmanaged(autodoc.Decl);

fn categorizeDecls(
    self: Self,
    decls: []const usize,
    alloc: std.mem.Allocator,
    types: *DeclList,
    values: *DeclList,
    vars: *DeclList,
    namespaces: *DeclList,
    funcs: *DeclList,
    uns: *DeclList,
) !void {
    for (decls) |decl_idx| {
        const decl = self.data.decls[decl_idx];
        const decl_value = try self.resolveValue(decl.value);

        // std.log.debug("categorizing: {}", .{decl});

        if (std.mem.eql(u8, "var", decl.kind)) {
            try vars.append(alloc, decl);
            continue;
        }
        if (std.mem.eql(u8, "const", decl.kind)) {
            if (decl_value.expr == .type) {
                const type_expr = self.data.types[decl_value.expr.type];
                if (type_expr == .Fn) {
                    const func_ret_expr = try self.resolveValue(
                        .{
                            .typeRef = null,
                            .expr = type_expr.Fn.ret,
                        },
                    );
                    if (func_ret_expr.expr == .type and func_ret_expr.expr.type == self.findTypeType()) {
                        const func_ret_type = self.data.types[func_ret_expr.expr.type];
                        switch (func_ret_type) {
                            .Struct => |s| {
                                if (s.field_types.len == 0) {
                                    try namespaces.append(alloc, decl);
                                } else {
                                    try types.append(alloc, decl);
                                }
                            },
                            else => try types.append(alloc, decl),
                        }
                    } else {
                        try funcs.append(alloc, decl);
                    }
                } else {
                    if (type_expr == .Struct) {
                        if (type_expr.Struct.field_types.len == 0) {
                            try namespaces.append(alloc, decl);
                        } else {
                            try types.append(alloc, decl);
                        }
                    } else {
                        try types.append(alloc, decl);
                    }
                }
            } else {
                try values.append(alloc, decl);
            }
        }

        if (decl.is_uns) {
            try uns.append(alloc, decl);
        }
    }
}

fn typeIsContainer(t: autodoc.Type) bool {
    return switch (t) {
        .Struct,
        .Union,
        .Enum,
        .Opaque,
        => true,
        else => false,
    };
}

fn resolveValue(self: Self, v: autodoc.WalkResult) !autodoc.WalkResult {
    var value = v;

    var i: usize = 0;
    while (true) : (i += 1) {
        if (i >= 10000) {
            return error.QuotaExceeded;
        }

        if (value.expr == .refPath) {
            value.expr = value.expr.refPath[value.expr.refPath.len - 1];
            value.typeRef = null;
            continue;
        }

        if (value.expr == .declRef) {
            value = self.data.decls[value.expr.declRef].value;
            continue;
        }

        if (value.expr == .as) {
            value = .{
                .typeRef = self.data.exprs[value.expr.as.typeRefArg.?],
                .expr = self.data.exprs[value.expr.as.exprArg],
            };
            continue;
        }

        return value;
    }
}

fn findTypeType(self: Self) usize {
    for (self.data.types, 0..) |t, idx| {
        if (t == .Type and std.mem.eql(u8, t.Type.name, "type")) return idx;
    }
    unreachable;
}

fn renderFnSignature(self: *Self, fn_decl: autodoc.Decl) !void {
    const value = try self.resolveValue(fn_decl.value);
    const fn_type = self.data.types[value.expr.type];
    const ast_node = self.data.astNodes[fn_decl.src];
    _ = ast_node;

    var fn_sig = std.ArrayList(u8).init(self.alloc);
    defer fn_sig.deinit();
    var writer = fn_sig.writer();
    try writer.print("fn {s}(", .{fn_decl.name});
    for (fn_type.Fn.params orelse &.{}, 0..) |p, idx| {
        try self.renderInline(p, writer);
        if (idx + 1 < (fn_type.Fn.params orelse &.{}).len) {
            try writer.writeAll(", ");
        }
    }
    try writer.writeAll(") ");
    try self.renderInline(fn_type.Fn.ret, writer);

    try self.canvas.addPreformatted(fn_sig.items, null);
}

fn renderInline(self: *Self, expr: autodoc.Expr, writer: anytype) !void {
    switch (expr) {
        .type => |t_idx| {
            const typ = self.data.types[t_idx];
            switch (typ) {
                .Fn => |f| {
                    try writer.writeAll("fn (");
                    for (f.params orelse &.{}, 0..) |p, idx| {
                        try self.renderInline(p, writer);
                        if (idx + 1 < (f.params orelse &.{}).len) {
                            try writer.writeAll(", ");
                        }
                    }
                    try writer.writeAll(")");
                },
                else => {
                    try writer.print("{}", .{typ});
                },
            }
        },
        .call => |call_idx| {
            const call = self.data.calls[call_idx];
            try self.renderInline(call.func, writer);
            try writer.writeAll("(");
            if (call.args.len > 0) {
                try self.renderInline(call.args[0], writer);
                for (call.args[1..]) |arg| {
                    try writer.writeAll(", {}");
                    try self.renderInline(arg, writer);
                }
            }
            try writer.writeAll(")");
        },
        .declRef => |ref| {
            try writer.writeAll(self.data.decls[ref].name);
        },
        .comptimeExpr => |cte_idx| {
            const cte = self.data.comptimeExprs[cte_idx];
            try writer.writeAll(cte.code);
        },
        else => try writer.print("{}", .{expr}),
    }
}
