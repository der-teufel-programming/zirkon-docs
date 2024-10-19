const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn parseDocs(data_dir_path: []const u8, alloc: Allocator) !std.json.Parsed(DocData) {
    var data_dir = std.fs.cwd().openDir(data_dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("FileNotFound: {s}\n", .{data_dir_path});
            return err;
        },
        else => return err,
    };
    defer data_dir.close();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer {
        // std.log.debug("Size used in arena: {}", .{std.fmt.fmtIntSizeDec(arena.queryCapacity())});
        arena.deinit();
    }

    var data: DocData = undefined;
    var data_arena = try alloc.create(std.heap.ArenaAllocator);
    data_arena.* = std.heap.ArenaAllocator.init(alloc);

    inline for (std.meta.fields(DocData)) |f| {
        const field_name = f.name;
        const file_name = "data-" ++ field_name ++ ".js";
        const data_js_f = data_dir.openFile(file_name, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("FileNotFound: {s}\n", .{file_name});
                return err;
            },
            else => return err,
        };
        defer data_js_f.close();

        var buffer = std.io.bufferedReader(data_js_f.reader());
        const reader = buffer.reader();

        try reader.skipUntilDelimiterOrEof('=');

        var json = std.json.reader(alloc, reader);
        defer json.deinit();
        const raw_data = try std.json.Value.jsonParse(arena.allocator(), &json, .{ .max_value_len = std.math.maxInt(u32) });

        @field(data, field_name) = try std.json.parseFromValueLeaky(f.type, data_arena.allocator(), raw_data, .{});
    }

    return .{
        .value = data,
        .arena = data_arena,
    };
}

pub const DocData = struct {
    typeKinds: []const []const u8,
    rootMod: u32,
    modules: []const Module,
    astNodes: []const AstNode,
    files: []const File,
    calls: []const Call,
    types: []const Type,
    exprs: []const Expr,
    comptimeExprs: []const ComptimeExpr,
    decls: []const Decl,
    guideSections: []const Section,

    pub fn prettyPrint(self: DocData, value: anytype, writer: anytype) !void {
        try value.prettyPrint(self, writer);
    }
};

pub const Module = struct {
    name: []const u8,
    file: usize,
    main: usize,
    table: std.StringArrayHashMapUnmanaged(usize),

    pub fn jsonParseFromValue(
        alloc: Allocator,
        value: std.json.Value,
        options: std.json.ParseOptions,
    ) !Module {
        _ = options;

        const module_value = value.object;
        const name = try alloc.dupe(u8, module_value.get("name").?.string);
        const file: usize = @intCast(module_value.get("file").?.integer);
        const main: usize = @intCast(module_value.get("main").?.integer);
        var table: std.StringArrayHashMapUnmanaged(usize) = .{};
        try parseTable(module_value.get("table").?, &table, alloc);
        return .{
            .name = name,
            .file = file,
            .main = main,
            .table = table,
        };
    }

    fn parseTable(
        value: std.json.Value,
        table: *std.StringArrayHashMapUnmanaged(usize),
        alloc: Allocator,
    ) !void {
        const table_value = value.object;
        var it = table_value.iterator();
        while (it.next()) |entry| {
            const name = try alloc.dupe(u8, entry.key_ptr.*);
            try table.put(alloc, name, @intCast(entry.value_ptr.*.integer));
        }
    }

    pub fn format(
        value: Module,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        try writer.print(
            "{{ name: `{s}`, file: {}, main: {}, table: {{ ",
            .{ value.name, value.file, value.main },
        );
        var it = value.table.iterator();
        while (it.next()) |entry| {
            try writer.print(
                "{s}: {}, ",
                .{ entry.key_ptr.*, entry.value_ptr.* },
            );
        }
        try writer.writeAll("} }");
    }

    pub fn prettyPrint(value: Module, data: DocData, writer: anytype) !void {
        try writer.print(
            "name: {s}\nfile: {s}\ntable:\n",
            .{ value.name, data.files[value.file].name },
        );
        var it = value.table.iterator();
        while (it.next()) |entry| {
            try writer.print(
                " - {s}: {}\n",
                .{ entry.key_ptr.*, entry.value_ptr.* },
            );
        }
    }
};

pub const AstNode = struct {
    file: usize = 0,
    line: usize = 0,
    col: usize = 0,
    name: ?[]const u8 = null,
    code: ?[]const u8 = null,
    docs: ?[]const u8 = null,
    fields: ?[]usize = null,
    @"comptime": bool = false,

    pub fn jsonParseFromValue(
        alloc: Allocator,
        value: std.json.Value,
        options: std.json.ParseOptions,
    ) !AstNode {
        const array = value.array.items;
        var node: AstNode = undefined;
        inline for (@typeInfo(AstNode).Struct.fields, 0..) |field, idx| {
            @field(node, field.name) = try std.json.parseFromValueLeaky(
                field.type,
                alloc,
                array[idx],
                options,
            );
        }
        return node;
    }

    pub fn format(
        value: AstNode,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        try writer.print("{{ {}:{}:{}, ", .{ value.file, value.line, value.col });
        if (value.name) |v| {
            try writer.print(".name: `{s}`, ", .{v});
        }
        if (value.code) |v| {
            try writer.print(".code: `{s}`, ", .{v});
        }
        if (value.docs) |v| {
            try writer.print(".docs: `{}`, ", .{std.fmt.fmtSliceEscapeLower(v)});
        }
        if (value.fields) |v| {
            try writer.print(".fields: {any}, ", .{v});
        }
        try writer.print(".comptime: {} }}", .{value.@"comptime"});
    }
};

pub const File = struct {
    name: []const u8,
    main_type: usize,

    pub fn jsonParseFromValue(
        alloc: Allocator,
        value: std.json.Value,
        options: std.json.ParseOptions,
    ) !File {
        _ = options;
        const name = try alloc.dupe(u8, value.array.items[0].string);
        const idx: usize = @intCast(value.array.items[1].integer);
        return .{
            .name = name,
            .main_type = idx,
        };
    }
    pub fn format(
        value: File,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        try writer.print(
            "{{ name: '{s}', main_type: {}}}",
            .{ value.name, value.main_type },
        );
    }
};

pub const Call = struct {
    func: Expr,
    args: []const Expr,
    ret: Expr,

    pub fn format(
        value: Call,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        try writer.print(
            "{}({any}) -> {}",
            .{ value.func, value.args, value.ret },
        );
    }
};

pub const Type = union(enum) {
    Unanalyzed: struct {},
    Type: struct { name: []const u8 },
    Void: struct { name: []const u8 },
    Bool: struct { name: []const u8 },
    NoReturn: struct { name: []const u8 },
    Int: struct { name: []const u8 },
    Float: struct { name: []const u8 },
    Pointer: struct {
        size: std.builtin.Type.Pointer.Size,
        child: Expr,
        sentinel: ?Expr,
        @"align": ?Expr,
        address_space: ?Expr,
        bit_start: ?Expr,
        host_size: ?Expr,
        is_ref: bool,
        is_allowzero: bool,
        is_mutable: bool,
        is_volatile: bool,
        has_sentinel: bool,
        has_align: bool,
        has_addrspace: bool,
        has_bit_range: bool,
    },
    Array: struct {
        len: Expr,
        child: Expr,
        sentinel: ?Expr,
    },
    Struct: struct {
        name: []const u8,
        src: usize, // index into astNodes
        privDecls: []const usize, // index into decls
        pubDecls: []const usize, // index into decls
        field_types: []const Expr, // (use src->fields to find names)
        field_defaults: []const ?Expr, // default values is specified
        backing_int: ?Expr, // backing integer if specified
        is_tuple: bool,
        line_number: usize,
        parent_container: ?usize, // index into `types`
        layout: ?Expr, // if different than Auto
    },
    ComptimeExpr: struct { name: []const u8 },
    ComptimeFloat: struct { name: []const u8 },
    ComptimeInt: struct { name: []const u8 },
    Undefined: struct { name: []const u8 },
    Null: struct { name: []const u8 },
    Optional: struct {
        name: []const u8,
        child: Expr,
    },
    ErrorUnion: struct { lhs: Expr, rhs: Expr },
    InferredErrorUnion: struct { payload: Expr },
    ErrorSet: struct {
        name: []const u8,
        fields: ?[]const Field,
        // TODO: fn field for inferred error sets?
    },
    Enum: struct {
        name: []const u8,
        src: usize, // index into astNodes
        privDecls: []const usize, // index into decls
        pubDecls: []const usize, // index into decls
        // (use src->fields to find field names)
        tag: ?Expr, // tag type if specified
        values: []const ?Expr, // tag values if specified
        nonexhaustive: bool,
        parent_container: ?usize, // index into `types`
    },
    Union: struct {
        name: []const u8,
        src: usize, // index into astNodes
        privDecls: []const usize, // index into decls
        pubDecls: []const usize, // index into decls
        fields: []const Expr, // (use src->fields to find names)
        tag: ?Expr, // tag type if specified
        auto_enum: bool, // tag is an auto enum
        parent_container: ?usize, // index into `types`
        layout: ?Expr, // if different than Auto
    },
    Fn: struct {
        name: []const u8,
        src: ?usize, // index into `astNodes`
        ret: Expr,
        generic_ret: ?Expr,
        params: ?[]const Expr, // (use src->fields to find names)
        lib_name: []const u8,
        is_var_args: bool,
        is_inferred_error: bool,
        has_lib_name: bool,
        has_cc: bool,
        cc: ?usize,
        @"align": ?usize,
        has_align: bool,
        is_test: bool,
        is_extern: bool,
    },
    Opaque: struct {
        name: []const u8,
        src: usize, // index into astNodes
        privDecls: []const usize, // index into decls
        pubDecls: []const usize, // index into decls
        parent_container: ?usize, // index into `types`
    },
    Frame: struct { name: []const u8 },
    AnyFrame: struct { name: []const u8 },
    Vector: struct { name: []const u8 },
    EnumLiteral: struct { name: []const u8 },

    const Field = struct {
        name: []const u8,
        docs: []const u8,
        pub fn format(
            value: Field,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = options;
            _ = fmt;
            try writer.print(".{s}", .{value.name});
        }
    };

    pub fn jsonParseFromValue(
        alloc: Allocator,
        value: std.json.Value,
        options: std.json.ParseOptions,
    ) !Type {
        const array = value.array.items;
        const typeKind: std.meta.Tag(Type) = @enumFromInt(array[0].integer);
        return parseUnionFromSlice(
            alloc,
            Type,
            @tagName(typeKind),
            array[1..],
            options,
        );
    }

    pub fn format(
        value: Type,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (value) {
            .Type => |v| try writer.print("{s} (type)", .{v.name}),
            .ComptimeExpr => |v| try writer.print(
                "{s} (ComptimeExpr)",
                .{v.name},
            ),
            .Void => try writer.writeAll("void"),
            .Bool => try writer.writeAll("bool"),
            .NoReturn => try writer.writeAll("noreturn"),
            .Int => |v| try writer.print("{s} (int)", .{v.name}),
            .Float => |v| try writer.print("{s} (float)", .{v.name}),
            .ComptimeInt => try writer.writeAll("comptime_int"),
            .ComptimeFloat => try writer.writeAll("comptime_float"),
            .Null => try writer.writeAll("@TypeOf(null)"),
            .EnumLiteral => try writer.writeAll("(enum literal)"),
            .AnyFrame => try writer.writeAll("anyframe"),
            .Undefined => try writer.writeAll("@TypeOf(undefined)"),
            .Pointer => |p| {
                switch (p.size) {
                    .One => try writer.writeAll("*"),
                    .Many => {
                        const maybe_sent = p.sentinel;
                        if (maybe_sent) |sent| {
                            try writer.print("[*:{}]", .{sent});
                        } else {
                            try writer.writeAll("[*]");
                        }
                    },
                    .Slice => {
                        if (p.is_ref) try writer.writeAll("*");
                        const maybe_sent = p.sentinel;
                        if (maybe_sent) |sent| {
                            try writer.print("[:{}]", .{sent});
                        } else {
                            try writer.writeAll("[]");
                        }
                    },
                    .C => {
                        const maybe_sent = p.sentinel;
                        if (maybe_sent) |sent| {
                            try writer.print("[*c:{}]", .{sent});
                        } else {
                            try writer.writeAll("[*c]");
                        }
                    },
                }
                if (!p.is_mutable) try writer.writeAll("const ");
                if (p.is_allowzero) try writer.writeAll("allowzero ");
                // if (ptrObj.is_volatile) {
                //   yield { src: "volatile", tag: Tag.keyword_volatile };
                // }
                // if (ptrObj.has_addrspace) {
                //   yield { src: "addrspace", tag: Tag.keyword_addrspace };
                //   yield Tok.l_paren;
                //   yield Tok.period;
                //   yield Tok.r_paren;
                // }
                if (p.has_align) try writer.print("align({}) ", .{p.@"align".?});
                try writer.print("{}", .{p.child});
            },
            .Optional => |opt| try writer.print(
                "?{} ({s})",
                .{ opt.child, opt.name },
            ),
            .ErrorUnion => |eu| try writer.print(
                "({})!({})",
                .{ eu.lhs, eu.rhs },
            ),
            .ErrorSet => |es| try writer.print(
                "error {{{?any}}} ({s})",
                .{ es.fields, es.name },
            ),
            .Struct => |s| {
                try writer.writeAll("struct { fields: { ");
                for (s.field_types, s.field_defaults) |ft, fdef| {
                    try writer.print(": {}", .{ft});
                    if (fdef) |def| {
                        try writer.print(" = {}, ", .{def});
                    } else {
                        try writer.writeAll(", ");
                    }
                }
                try writer.writeAll(" }, ");
                try writer.writeAll("}");
            },
            .Array => |arr| {
                try writer.print("[{}", .{arr.len});
                if (arr.sentinel) |sent| {
                    try writer.print(":{}]{}", .{ sent, arr.child });
                } else {
                    try writer.print("]{}", .{arr.child});
                }
            },
            .Fn => |func| {
                try writer.print(
                    "Fn({s}){{ args: {any} }}",
                    .{ func.name, func.params orelse &[_]Expr{} },
                );
            },
            inline else => |v| try writer.print(
                "{} ({s})",
                .{ v, @tagName(value) },
            ),
        }
    }

    pub fn prettyPrint(
        value: Type,
        data: DocData,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        switch (value) {
            .Type => |v| try writer.print("{s} (type)", .{v.name}),
            .ComptimeExpr => |v| try writer.print("{s} (ComptimeExpr)", .{v.name}),
            .Void => try writer.writeAll("void"),
            .Bool => try writer.writeAll("bool"),
            .NoReturn => try writer.writeAll("noreturn"),
            .Int => |v| try writer.print("{s}", .{v.name}),
            .Float => |v| try writer.print("{s}", .{v.name}),
            .ComptimeInt => try writer.writeAll("comptime_int"),
            .ComptimeFloat => try writer.writeAll("comptime_float"),
            .Null => try writer.writeAll("@TypeOf(null)"),
            .EnumLiteral => try writer.writeAll("(enum literal)"),
            .AnyFrame => try writer.writeAll("anyframe"),
            .Undefined => try writer.writeAll("@TypeOf(undefined)"),
            .Pointer => |p| {
                switch (p.size) {
                    .One => try writer.writeAll("*"),
                    .Many => {
                        const maybe_sent = p.sentinel;
                        if (maybe_sent) |sent| {
                            try writer.print("[*:{}]", .{sent});
                        } else {
                            try writer.writeAll("[*]");
                        }
                    },
                    .Slice => {
                        if (p.is_ref) try writer.writeAll("*");
                        const maybe_sent = p.sentinel;
                        if (maybe_sent) |sent| {
                            try writer.print("[:{}]", .{sent});
                        } else {
                            try writer.writeAll("[]");
                        }
                    },
                    .C => {
                        const maybe_sent = p.sentinel;
                        if (maybe_sent) |sent| {
                            try writer.print("[*c:{p}]", .{sent});
                        } else {
                            try writer.writeAll("[*c]");
                        }
                    },
                }
                if (!p.is_mutable) try writer.writeAll("const ");
                if (p.is_allowzero) try writer.writeAll("allowzero ");
                // if (ptrObj.is_volatile) {
                //   yield { src: "volatile", tag: Tag.keyword_volatile };
                // }
                // if (ptrObj.has_addrspace) {
                //   yield { src: "addrspace", tag: Tag.keyword_addrspace };
                //   yield Tok.l_paren;
                //   yield Tok.period;
                //   yield Tok.r_paren;
                // }
                if (p.has_align) try writer.print("align({p}) ", .{p.@"align".?});
                try p.child.prettyPrint(data, writer);
            },
            .Optional => |opt| {
                try writer.writeAll("?");
                try opt.child.prettyPrint(data, writer);
            },
            .ErrorUnion => |eu| {
                try eu.lhs.prettyPrint(data, writer);
                try writer.writeAll("!");
                try eu.rhs.prettyPrint(data, writer);
            },
            .InferredErrorUnion => |ieu| {
                try writer.writeAll("!");
                try ieu.payload.prettyPrint(data, writer);
            },
            .ErrorSet => |es| try writer.print(
                "error {{{?any}}} ({s})",
                .{ es.fields, es.name },
            ),
            .Struct => |s| {
                try writer.writeAll("struct {\n");
                const ast = data.astNodes[s.src];
                const fields = ast.fields orelse &.{};
                for (s.field_types, s.field_defaults, fields) |ft, fdef, fname_idx| {
                    const fname = data.astNodes[fname_idx].name orelse "";
                    try writer.print("{s}: {p}", .{ fname, ft });
                    if (fdef) |def| {
                        try writer.print(" = {p},\n", .{def});
                    } else {
                        try writer.writeAll(",\n");
                    }
                }
                try writer.writeAll("}");
            },
            .Array => |arr| {
                try writer.print("[{p}", .{arr.len});
                if (arr.sentinel) |sent| {
                    try writer.print(":{}]", .{sent});
                } else {
                    try writer.writeAll("]");
                }
                try arr.child.prettyPrint(data, writer);
            },
            .Fn => |func| {
                try writer.writeAll("fn (\n");
                if (func.src) |src| {
                    const ast = data.astNodes[src];
                    const args = ast.fields orelse &.{};
                    const params = func.params orelse &.{};
                    for (args, params) |arg, param| {
                        try writer.print(
                            "    {s}: ",
                            .{data.astNodes[arg].name orelse ""},
                        );
                        try param.prettyPrint(data, writer);
                        try writer.writeAll(",\n");
                    }
                } else {
                    const params = func.params orelse &.{};
                    for (params) |param| {
                        try writer.writeAll("    _: ");
                        try param.prettyPrint(data, writer);
                        try writer.writeAll(",\n");
                    }
                }
                try writer.writeAll(") ");
                try func.ret.prettyPrint(data, writer);
            },

            inline else => |v| try writer.print(
                "{} ({s})",
                .{ v, @tagName(value) },
            ),
        }
    }
};

pub const Decl = struct {
    name: []const u8,
    kind: []const u8,
    src: usize, // index into astNodes
    value: WalkResult,
    // The index in astNodes of the `test declname { }` node
    decltest: ?usize,
    is_uns: bool, // usingnamespace
    parent_container: ?usize, // index into `types`

    pub fn jsonParseFromValue(
        alloc: Allocator,
        value: std.json.Value,
        options: std.json.ParseOptions,
    ) !Decl {
        return parseStructFromSlice(alloc, Decl, value.array.items, options);
    }

    pub fn format(
        value: Decl,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        try writer.print(
            "{{ .name = {s}, .kind = {s}, .src = {}, .value = {}, .decltest = {?}, .is_uns = {}, .parent_container = {?} }}",
            .{
                value.name,
                value.kind,
                value.src,
                value.value,
                value.decltest,
                value.is_uns,
                value.parent_container,
            },
        );
    }
    pub fn prettyPrint(value: Decl, data: DocData, writer: anytype) !void {
        _ = data;
        try writer.print("{s}", .{value.name});
    }
};

pub const WalkResult = struct {
    typeRef: ?Expr,
    expr: Expr,
};

pub const Expr = union(enum) {
    comptimeExpr: usize, // index in `comptimeExprs`
    void: struct {},
    @"unreachable": struct {},
    null: struct {},
    undefined: struct {},
    @"struct": []const FieldVal,
    bool: bool,
    @"anytype": struct {},
    @"&": usize, // index in `exprs`
    type: usize, // index in `types`
    this: usize, // index in `types`
    declRef: usize,
    declIndex: usize, // same as above
    declName: []const u8, // unresolved decl name
    builtinField: enum { len, ptr },
    fieldRef: FieldRef,
    refPath: []const Expr,
    int: i65,
    int_big: struct {
        value: []const u8, // string representation
        negated: bool = false,
    },
    float: f64, // direct value
    float128: f128, // direct value
    array: []const usize, // index in `exprs`
    call: usize, // index in `calls`
    enumLiteral: []const u8, // direct value
    typeOf: usize, // index in `exprs`
    typeOf_peer: []const usize,
    errorUnion: usize, // index in `types`
    as: As,
    sizeOf: usize, // index in `exprs`
    bitSizeOf: usize, // index in `exprs`
    compileError: usize, //index in `exprs`
    optionalPayload: usize, // index in `exprs`
    elemVal: ElemVal,
    errorSets: usize,
    string: []const u8, // direct value
    sliceIndex: usize,
    slice: Slice,
    sliceLength: SliceLength,
    cmpxchgIndex: usize,
    cmpxchg: Cmpxchg,
    builtin: Builtin,
    builtinIndex: usize,
    builtinBin: BuiltinBin,
    builtinBinIndex: usize,
    unionInit: UnionInit,
    builtinCall: BuiltinCall,
    mulAdd: MulAdd,
    switchIndex: usize, // index in `exprs`
    switchOp: SwitchOp,
    unOp: UnOp,
    unOpIndex: usize,
    binOp: BinOp,
    binOpIndex: usize,
    load: usize, // index in `exprs`

    const UnOp = struct {
        param: usize, // index in `exprs`
        name: []const u8 = "", // tag name
    };
    const BinOp = struct {
        lhs: usize, // index in `exprs`
        rhs: usize, // index in `exprs`
        name: []const u8 = "", // tag name
    };
    const SwitchOp = struct {
        cond_index: usize,
        file_name: []const u8,
        src: usize,
        outer_decl: usize, // index in `types`
    };
    const BuiltinBin = struct {
        name: []const u8 = "", // fn name
        lhs: usize, // index in `exprs`
        rhs: usize, // index in `exprs`
    };
    const Builtin = struct {
        name: []const u8 = "", // fn name
        param: usize, // index in `exprs`
    };
    const BuiltinCall = struct {
        modifier: usize, // index in `exprs`
        function: usize, // index in `exprs`
        args: usize, // index in `exprs`
    };
    const MulAdd = struct {
        mulend1: usize, // index in `exprs`
        mulend2: usize, // index in `exprs`
        addend: usize, // index in `exprs`
        type: usize, // index in `exprs`
    };
    const UnionInit = struct {
        type: usize, // index in `exprs`
        field: usize, // index in `exprs`
        init: usize, // index in `exprs`
    };
    const Slice = struct {
        lhs: usize, // index in `exprs`
        start: usize,
        end: ?usize = null,
        sentinel: ?usize = null, // index in `exprs`
    };
    const SliceLength = struct {
        lhs: usize,
        start: usize,
        len: usize,
        sentinel: ?usize = null,
    };
    const Cmpxchg = struct {
        name: []const u8,
        type: usize,
        ptr: usize,
        expected_value: usize,
        new_value: usize,
        success_order: usize,
        failure_order: usize,
    };
    const As = struct {
        typeRefArg: ?usize, // index in `exprs`
        exprArg: usize, // index in `exprs`
    };
    const FieldRef = struct {
        type: usize, // index in `types`
        index: usize, // index in type.fields
    };

    const FieldVal = struct {
        name: []const u8,
        val: WalkResult,
        pub fn format(
            fv: FieldVal,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = options;
            _ = fmt;
            try writer.print(
                "(.{s} = ({?}){}",
                .{ fv.name, fv.val.typeRef, fv.val.expr },
            );
        }
    };
    const ElemVal = struct {
        lhs: usize, // index in `exprs`
        rhs: usize, // index in `exprs`
    };

    pub fn format(
        value: Expr,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (value) {
            .undefined => try writer.writeAll("undefined"),
            .null => try writer.writeAll("null"),
            .int => |int| try writer.print("{}", .{int}),
            .string => |str| try writer.print("\"{s}\"", .{str}),
            .enumLiteral => |el| try writer.print(".{s}", .{el}),
            .builtin => |bt| try writer.print("@{s}(%{})", .{ bt.name, bt.param }),
            .builtinIndex => |bti| try writer.print("Builtin(%{})", .{bti}),
            .builtinBinIndex => |btbi| try writer.print(
                "BuiltinBin(%{})",
                .{btbi},
            ),
            .binOp => |bin| try writer.print(
                "{s}(%{}, %{})",
                .{ bin.name, bin.lhs, bin.rhs },
            ),
            .builtinBin => |bbin| try writer.print(
                "@{s}(%{}, %{})",
                .{ bbin.name, bbin.lhs, bbin.rhs },
            ),
            .binOpIndex => |bin_idx| try writer.print("BinOp(%{})", .{bin_idx}),
            .as => |as| try writer.print(
                "as(%{?}, %{})",
                .{ as.typeRefArg, as.exprArg },
            ),
            .type => |t| try writer.print("type(%{})", .{t}),
            .typeOf => |to| try writer.print("@TypeOf(%{})", .{to}),
            .comptimeExpr => |cte| try writer.print("cte(%{})", .{cte}),
            .declRef => |dref| try writer.print("decl(%{})", .{dref}),
            .call => |call| try writer.print("call(%{})", .{call}),
            .fieldRef => |fref| try writer.print(
                "field(%{}, %{})",
                .{ fref.type, fref.index },
            ),
            .declName => |name| try writer.writeAll(name),
            .@"struct" => |st| {
                if (st.len == 0) {
                    try writer.writeAll(".{}");
                    return;
                }
                try writer.print(".{{ {}", .{st[0]});
                for (st[1..]) |f| {
                    try writer.print(", {}", .{f});
                }
                try writer.writeAll(" }");
            },
            .refPath => |rp| {
                try writer.print("{}", .{rp[0]});
                for (rp[1..]) |ref| {
                    try writer.print(".{}", .{ref});
                }
            },
            inline else => |v| try writer.print(
                "{{ Expr.{s} = {any} }}",
                .{ @tagName(value), v },
            ),
        }
    }

    pub fn prettyPrint(
        value: Expr,
        data: DocData,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        switch (value) {
            .undefined => try writer.writeAll("undefined"),
            .null => try writer.writeAll("null"),
            .int => |int| try writer.print("{}", .{int}),
            .string => |str| try writer.print("\"{s}\"", .{str}),
            .enumLiteral => |el| try writer.print(".{s}", .{el}),
            .builtin => |bt| {
                try writer.print("@{s}(", .{bt.name});
                try data.exprs[bt.param].prettyPrint(data, writer);
                try writer.writeAll(")\n");
            },
            .builtinIndex => |bti| try data.exprs[bti].prettyPrint(data, writer),
            .builtinBinIndex => |btbi| try data.exprs[btbi].prettyPrint(data, writer),
            .binOp => |bin| try writer.print("{s}(%{}, %{})", .{ bin.name, bin.lhs, bin.rhs }),
            .builtinBin => |bbin| try writer.print("@{s}(%{}, %{})", .{ bbin.name, bbin.lhs, bbin.rhs }),
            .binOpIndex => |bin_idx| try writer.print("BinOp(%{})", .{bin_idx}),
            .as => |as| try writer.print("as(%{?}, %{})", .{ as.typeRefArg, as.exprArg }),
            .type => |t| try data.types[t].prettyPrint(data, writer),
            .typeOf => |to| try writer.print("@TypeOf(%{})", .{to}),
            .typeInfo => |ti| try writer.print("@typeInfo(%{})", .{ti}),
            .comptimeExpr => |cte| try writer.print("cte(%{})", .{cte}),
            .declRef => |dref| try data.decls[dref].prettyPrint(data, writer),
            .call => |call| try writer.print("call(%{})", .{call}),
            .fieldRef => |fref| try writer.print("field(%{}, %{})", .{ fref.type, fref.index }),
            .declName => |name| try writer.writeAll(name),
            .@"struct" => |st| {
                if (st.len == 0) {
                    try writer.writeAll(".{}");
                    return;
                }
                try writer.print(".{{ {}", .{st[0]});
                for (st[1..]) |f| {
                    try writer.print(", {}", .{f});
                }
                try writer.writeAll(" }");
            },
            .refPath => |rp| {
                try rp[0].prettyPrint(data, writer);
                for (rp[1..]) |ref| {
                    try writer.writeAll(".");
                    try ref.prettyPrint(data, writer);
                }
            },
            .errorUnion => |eu| try data.types[eu].prettyPrint(data, writer),
            inline else => |v| try writer.print("{{ Expr.{s} = {any} }}", .{ @tagName(value), v }),
        }
    }
};

pub const ComptimeExpr = struct {
    code: []const u8,
};

pub const Section = struct {
    name: []const u8, // empty string is the default section
    guides: []const Guide,

    const Guide = struct {
        name: []const u8,
        body: []const u8,
    };
};

fn parseUnionFromSlice(
    alloc: Allocator,
    comptime Union: type,
    tag_name: []const u8,
    slice: []const std.json.Value,
    options: std.json.ParseOptions,
) !Union {
    inline for (@typeInfo(Union).Union.fields) |u_field| {
        if (std.mem.eql(u8, u_field.name, tag_name)) {
            var union_value = @unionInit(Union, u_field.name, undefined);
            inline for (std.meta.fields(u_field.type), 0..) |field, idx| {
                @field(@field(union_value, u_field.name), field.name) = try std.json.parseFromValueLeaky(
                    field.type,
                    alloc,
                    slice[idx],
                    options,
                );
            }
            return union_value;
        }
    }
    unreachable;
}

fn parseStructFromSlice(
    alloc: Allocator,
    comptime Struct: type,
    slice: []const std.json.Value,
    options: std.json.ParseOptions,
) !Struct {
    var struct_value: Struct = undefined;
    inline for (std.meta.fields(Struct), 0..) |field, idx| {
        @field(struct_value, field.name) = try std.json.parseFromValueLeaky(
            field.type,
            alloc,
            slice[idx],
            options,
        );
    }
    return struct_value;
}

const SearchRes = struct {
    data: []const u8,
    idx: usize,
};

fn searchComptimeExprs(
    data: DocData,
    term: []const u8,
    alloc: Allocator,
) ![]const SearchRes {
    var list = std.ArrayList(SearchRes).init(alloc);
    for (data.comptimeExprs, 0..) |cte, idx| {
        if (std.mem.containsAtLeast(u8, cte.code, 1, term)) {
            try list.append(.{
                .data = cte.code,
                .idx = idx,
            });
        }
    }
    return list.toOwnedSlice();
}

const SearchExpr = struct {
    data: Expr,
    idx: usize,
};

fn searchExprs(
    data: DocData,
    terms: []const SearchRes,
    alloc: Allocator,
) ![]const SearchExpr {
    var list = std.ArrayList(SearchExpr).init(alloc);
    for (data.exprs, 0..) |exp, idx| {
        for (terms) |t| {
            if (exp == .comptimeExpr and exp.comptimeExpr == t.idx) {
                try list.append(.{
                    .data = exp,
                    .idx = idx,
                });
            }
        }
    }
    return list.toOwnedSlice();
}

test {
    const zig = @import("zig");
    const expr_kinds_exp_raw = std.meta.fieldNames(zig.DocData.Expr);
    const expr_kinds_raw = std.meta.fieldNames(Expr);
    const expr_kinds_exp = try std.testing.allocator.dupe([]const u8, expr_kinds_exp_raw);
    defer std.testing.allocator.free(expr_kinds_exp);
    const expr_kinds = try std.testing.allocator.dupe([]const u8, expr_kinds_raw);
    defer std.testing.allocator.free(expr_kinds);
    std.mem.sort([]const u8, expr_kinds_exp, {}, orderStrings);
    std.mem.sort([]const u8, expr_kinds, {}, orderStrings);
    for (expr_kinds_exp, expr_kinds) |exp, val| {
        if (!std.mem.eql(u8, exp, val)) {
            std.debug.print("Not equal: '{s}' '{s}'\n", .{ exp, val });
        } else {
            std.debug.print("Yes equal: '{s}' '{s}'\n", .{ exp, val });
        }
    }
}

fn orderStrings(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
