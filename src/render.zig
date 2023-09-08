const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn create(alloc: Allocator) !void {
    _ = alloc;
}

pub const Document = struct {
    text: std.ArrayList(u8),

    pub fn init(alloc: Allocator) Document {
        return .{
            .text = std.ArrayList(u8).init(alloc),
        };
    }

    pub fn deinit(self: Document) void {
        self.text.deinit();
    }

    /// Empties the document's text, caller owns memory
    pub fn getDocument(self: *Document) ![]const u8 {
        return self.text.toOwnedSlice();
    }

    pub fn renderTo(self: Document, writer: anytype) !void {
        try writer.writeAll(self.text.items);
    }

    pub fn addText(self: *Document, text: []const u8) !void {
        try self.text.appendSlice(text);
        if (text[text.len - 1] != '\n') try self.text.append('\n');
    }

    pub fn addLink(self: *Document, link: []const u8, name: ?[]const u8) !void {
        try self.text.writer().print("=> {s}", .{link});
        if (name) |label| {
            try self.text.writer().print(" {s}", .{label});
        }
        try self.text.append('\n');
    }

    pub const Heading = enum { h1, h2, h3 };
    pub fn addHeading(self: *Document, level: Heading, text: []const u8) !void {
        switch (level) {
            .h1 => try self.text.append('#'),
            .h2 => try self.text.appendNTimes('#', 2),
            .h3 => try self.text.appendNTimes('#', 3),
        }
        try self.text.writer().print(" {s}\n", .{text});
    }

    pub fn addList(self: *Document, items: []const []const u8) !void {
        for (items) |item| {
            self.text.writer().print("* {s}\n", .{item});
        }
    }

    pub fn addQuote(self: *Document, text: []const u8) !void {
        try self.text.writer().print("> {s}\n", .{text});
    }

    pub fn addPreformatted(self: *Document, raw: []const u8, alt: ?[]const u8) !void {
        try self.text.appendSlice("```");
        if (alt) |alt_text| {
            try self.text.appendSlice(alt_text);
        }
        try self.text.append('\n');
        try self.text.appendSlice(raw);
        if (raw[raw.len - 1] != '\n') try self.text.append('\n');
        try self.text.appendSlice("```\n");
    }

    pub fn addPreformattedLines(self: *Document, lines: []const []const u8, alt: ?[]const u8) !void {
        try self.text.appendSlice("```");
        if (alt) |alt_text| {
            try self.text.appendSlice(alt_text);
        }
        try self.text.append('\n');
        for (lines) |line| {
            try self.text.writer().print("{s}\n", .{line});
        }
        try self.text.appendSlice("```\n");
    }
};

pub const ZigRender = struct {
    doc: Document,
    temp: std.ArrayList(u8),
    color: bool,

    pub fn init(alloc: Allocator, color: bool) ZigRender {
        return .{
            .doc = Document.init(alloc),
            .temp = std.ArrayList(u8).init(alloc),
            .color = color,
        };
    }
    pub fn deinit(self: ZigRender) void {
        self.doc.deinit();
        self.temp.deinit();
    }

    pub const Token = struct {
        source: []const u8,
        tag: Tag,

        pub const Tag = enum {
            comment,
            keyword,
            str,
            none,
            builtin,
            null,
            tok_fn,
            type,
            identifier,
            number,
            doc_comment,
        };
    };

    pub fn initBlock(self: *ZigRender) void {
        self.temp.clearRetainingCapacity();
    }

    pub fn endBlock(self: *ZigRender, alt: ?[]const u8) !void {
        try self.doc.addPreformatted(self.temp.items, alt);
    }

    pub fn write(self: *ZigRender, token: Token) !void {
        if (self.color and false) {
            try self.writeColor(token);
        } else {
            try self.temp.appendSlice(token.source);
        }
    }

    pub fn rawWrite(self: *ZigRender, src: []const u8) !void {
        try self.write(.{ .source = src, .tag = .none });
    }

    fn writeColor(self: *ZigRender, token: Token) !void {
        switch (token.tag) {}
        try self.temp.appendSlice(token.source);
    }
};
