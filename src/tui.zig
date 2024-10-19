const std = @import("std");

const autodoc = @import("Autodoc.zig");

pub fn tui_main(alloc: std.mem.Allocator, data: autodoc.DocData) !void {
    var raw_buffer = std.io.bufferedWriter(std.io.getStdOut().writer());
    var output = raw_buffer.writer();

    try output.writeAll("Welcome to Zirkon!\nUse `?` or `help` for help, `q` or `quit` to exit...\n");
    try raw_buffer.flush();
    var input = std.ArrayList(u8).init(alloc);
    defer input.deinit();
    var stdin = std.io.getStdIn().reader();
    while (true) {
        defer input.clearRetainingCapacity();
        try output.writeAll("> ");
        try raw_buffer.flush();
        try stdin.streamUntilDelimiter(input.writer(), '\n', null);
        var tokens = std.mem.tokenizeScalar(u8, std.mem.trim(u8, input.items, &std.ascii.whitespace), ' ');
        const cmd = tokens.next() orelse continue;
        if (strEq("q", cmd) or strEq("quit", cmd)) {
            break;
        } else if (strEq("?", cmd) or strEq("help", cmd)) {
            try output.writeAll("\n");
        } else if (strEq("info", cmd)) {
            inline for (@typeInfo(autodoc.DocData).Struct.fields) |field| {
                if (@typeInfo(field.type) != .Pointer) continue;
                try output.print("=> {s: <15}: {} entries\n", .{ field.name, @field(data, field.name).len });
            }
        } else if (strEq("exprs", cmd)) {
            const idx = std.fmt.parseInt(usize, (tokens.next() orelse {
                try output.writeAll("No idx given\n");
                continue;
            }), 10) catch {
                try output.writeAll("Invalid integer\n");
                continue;
            };
            if (idx >= data.exprs.len) {
                try output.writeAll("Invalid idx\n");
                continue;
            }
            try data.prettyPrint(data.exprs[idx], output);
            try output.writeAll("\n");
        } else if (strEq("decls", cmd)) {
            const idx = std.fmt.parseInt(usize, (tokens.next() orelse {
                try output.writeAll("No index given\n");
                continue;
            }), 10) catch {
                try output.writeAll("Invalid integer\n");
                continue;
            };
            if (idx >= data.decls.len) {
                try output.print("Index too big: Valid range 0-{}\n", .{data.decls.len - 1});
                continue;
            }
            try data.prettyPrint(data.decls[idx], output);
            try output.writeAll("\n");
        } else if (strEq("types", cmd)) {
            const idx = std.fmt.parseInt(usize, (tokens.next() orelse {
                try output.writeAll("No idx given\n");
                continue;
            }), 10) catch {
                try output.writeAll("Invalid integer\n");
                continue;
            };
            if (idx >= data.types.len) {
                try output.writeAll("Invalid idx\n");
                continue;
            }
            try data.prettyPrint(data.types[idx], output);
            try output.writeAll("\n");
        } else if (strEq("modules", cmd)) {
            const idx = std.fmt.parseInt(usize, (tokens.next() orelse {
                try output.writeAll("No idx given\n");
                continue;
            }), 10) catch {
                try output.writeAll("Invalid integer\n");
                continue;
            };
            if (idx >= data.modules.len) {
                try output.writeAll("Invalid idx\n");
                continue;
            }
            try data.prettyPrint(data.modules[idx], output);
        } else {
            try output.print("Unknown command: `{s}`. Use `help` or `?` for commands and `q` or `quit` to exit.\n", .{cmd});
        }
    }
}

fn strEq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
