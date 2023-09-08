const std = @import("std");

const autodoc = @import("Autodoc.zig");
const render = @import("render.zig");
const gemini_render = @import("gemini/render_source.zig");

pub const GeminiOptions = struct {
    project_page: ?[]const u8,
    project_name: ?[]const u8,
};

pub fn gemini_main(alloc: std.mem.Allocator, data: autodoc.DocData, output_dir_path: []const u8, src_dir_path: []const u8, options: GeminiOptions) !void {
    var output_dir = try std.fs.cwd().makeOpenPath(output_dir_path, .{});
    defer output_dir.close();
    var index_doc = render.Document.init(alloc);
    defer index_doc.deinit();

    var index_file = try output_dir.createFile("index.gmi", .{});
    defer index_file.close();
    var index_file_writer = index_file.writer();

    const root_mod = data.modules[data.rootMod];
    const root_mod_name = root_mod.name;
    const heading = try std.fmt.allocPrint(alloc, "Generated documentation for: {s}", .{root_mod_name});
    defer alloc.free(heading);
    try index_doc.addHeading(.h1, heading);
    try index_doc.addText("This is the index file for a set of gemini documents rendered from data generated by Zig's Autodoc for this module.");
    try index_doc.addLink("by_ns/index.gmi", "Default documentation (by namespace)");
    try index_doc.addLink("by_file/index.gmi", "Documentation by file");
    try index_doc.addLink("modules.gmi", "All modules");
    try index_doc.addLink("src/index.gmi", "Rendered source of all files included in the data");
    try index_doc.addHeading(.h2, "Links:");
    if (options.project_page) |page| {
        try index_doc.addHeading(.h3, "This project:");
        try index_doc.addLink(page, options.project_name);
        try index_doc.addHeading(.h3, "Other links:");
    }
    try index_doc.addLink("https://ziglang.org", "Zig programming language");
    try index_doc.addLink("https://github.com/der-teufel-programming/zirkon-docs", "Zirkon - the tool used to create this page");

    try index_doc.renderTo(index_file_writer);

    var src_dir = output_dir.openDir("src", .{}) catch |err| blk: {
        switch (err) {
            error.FileNotFound => {
                try output_dir.makeDir("src");
                break :blk try output_dir.openDir("src", .{});
            },
            else => return err,
        }
    };
    defer src_dir.close();
    const src_idx_file = try src_dir.createFile("index.gmi", .{});
    defer src_idx_file.close();
    var src_idx = src_idx_file.writer();
    var src_idx_doc = render.Document.init(alloc);
    defer src_idx_doc.deinit();
    try src_idx_doc.addHeading(.h1, "Sources");

    var raw_src_dir = try std.fs.cwd().openDir(src_dir_path, .{});
    defer raw_src_dir.close();

    var elems = std.ArrayListUnmanaged([]const u8){};
    defer elems.deinit(alloc);

    for (data.files) |file| {
        const gen_name = try std.fmt.allocPrint(alloc, "{s}.gmi", .{std.fs.path.basename(file.name)});
        defer alloc.free(gen_name);

        var ci = try std.fs.path.componentIterator(file.name);
        defer elems.clearRetainingCapacity();
        while (ci.next()) |comp| {
            try elems.append(alloc, comp.name);
        }
        const file_link = try std.mem.join(alloc, "/", elems.items);
        defer alloc.free(file_link);
        _ = elems.pop();
        try elems.append(alloc, gen_name);
        const real_link = try std.mem.join(alloc, "/", elems.items);
        defer alloc.free(real_link);

        try src_idx_doc.addLink(real_link, file_link);

        const output_file = if (elems.items.len > 1) blk: {
            var dir = try src_dir.makeOpenPath(std.fs.path.dirname(file.name) orelse ".", .{});
            defer dir.close();
            break :blk try dir.createFile(std.fs.path.basename(gen_name), .{});
        } else try src_dir.createFile(gen_name, .{});
        defer output_file.close();

        const f = raw_src_dir.openFile(file.name, .{}) catch {
            try output_file.writer().print("# {s}\n## Error:\nThis source rendering is unfortunately empty", .{file_link});
            continue;
        };
        defer f.close();

        var buff = std.io.bufferedReader(f.reader());
        var reader = buff.reader();
        var r = render.ZigRender.init(alloc, true);
        defer r.deinit();

        try gemini_render.genSrc(alloc, reader, file_link, &r);
        try r.doc.renderTo(output_file.writer());
    }

    try src_idx_doc.renderTo(src_idx);
}