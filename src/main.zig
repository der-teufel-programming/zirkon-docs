const std = @import("std");
const autodoc = @import("Autodoc.zig");

const ux = @import("ux.zig");

const Options = struct {
    data_file: ?[]const u8 = null,
    output_dir: ?[]const u8 = null,
    src_dir: ?[]const u8 = null,
    proj_page: ?[]const u8 = null,
    proj_name: ?[]const u8 = null,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = try std.process.ArgIterator.initWithAllocator(alloc);
    defer args.deinit();

    _ = args.skip();
    var opts: Options = .{};

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--data")) {
            if (opts.data_file == null) {
                opts.data_file = args.next();
            } else {
                try std.io.getStdErr().writeAll("Only one data file path possible!\n");
                return error.TooManyArgs;
            }
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            if (opts.output_dir == null) {
                opts.output_dir = args.next();
            } else {
                try std.io.getStdErr().writeAll("Only one output directory path possible!\n");
                return error.TooManyArgs;
            }
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--sources")) {
            if (opts.src_dir == null) {
                opts.src_dir = args.next();
            } else {
                try std.io.getStdErr().writeAll("Only one sources directory path possible!\n");
                return error.TooManyArgs;
            }
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--page")) {
            if (opts.proj_page == null) {
                opts.proj_page = args.next();
            } else {
                try std.io.getStdErr().writeAll("Only one project page URL possible!\n");
                return error.TooManyArgs;
            }
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--name")) {
            if (opts.proj_name == null) {
                opts.proj_name = args.next();
            } else {
                try std.io.getStdErr().writeAll("Only one project name possible!\n");
                return error.TooManyArgs;
            }
        }
    }
    if (opts.data_file == null) {
        try std.io.getStdErr().writeAll("No input data file specified!\n");
        return error.NotEnoughArgs;
    }

    const file = try std.fs.cwd().openFile(opts.data_file.?, .{});
    defer file.close();
    var reader = file.reader();
    _ = reader;
    var buff = std.io.bufferedReader(file.reader());
    var data = buff.reader();
    try data.skipBytes(41, .{});
    const autodoc_data = try autodoc.parseDocs(data, alloc);
    defer autodoc_data.deinit();

    const output_dir = opts.output_dir orelse "gemdocs";
    const src_dir = opts.src_dir orelse ".";
    const project_page = opts.proj_page;
    const project_name = opts.proj_name;
    try ux.gemini_main(
        alloc,
        autodoc_data.value,
        output_dir,
        src_dir,
        .{ .project_page = project_page, .project_name = project_name },
    );
}
