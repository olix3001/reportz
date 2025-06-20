const std = @import("std");

pub fn SourceCache(comptime SourceId: type) type {
    return struct {
        allocator: std.mem.Allocator,
        arena: std.heap.ArenaAllocator,
        sourcemap: std.AutoHashMapUnmanaged(SourceId, AnalyzedSource) = .{},

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .arena = .init(allocator),
            };
        }
        pub fn deinit(self: *Self) void {
            self.sourcemap.deinit(self.allocator);
            self.arena.deinit();
        }

        pub fn addSourcePreanalyzed(self: *Self, id: SourceId, analyzed_source: AnalyzedSource) !void {
            try self.sourcemap.put(self.allocator, id, analyzed_source);
        }

        pub fn addSource(self: *Self, id: SourceId, source: []const u8) !void {
            if (self.sourcemap.contains(id)) return; // Compute source only once.
            const analyzed_source: AnalyzedSource = try .compute(self.arena.allocator(), source);
            try self.sourcemap.put(self.allocator, id, analyzed_source);
        }
    };
}

pub const AnalyzedSource = struct {
    raw: []const u8,
    lines: []const Line,
    char_len: usize, // Length in unicode codepoints.
    byte_len: usize,

    pub const Line = struct {
        char_offset: usize, // Offset in unicode codepoints.
        char_len: usize = 0,
        byte_offset: usize,
        byte_len: usize = 0,
    };

    const Self = @This();
    pub fn compute(allocator: std.mem.Allocator, raw_source: []const u8) !Self {
        const SEPARATORS = [_]u21{
            '\n', // Line feed
            '\x0B', // Vertical tab
            '\u{0085}', // Next line
            '\u{2028}', // Line separator
            '\u{2029}', // Paragraph separator
        };

        var lines = std.ArrayList(Line).init(allocator);
        try lines.append(.{ .char_offset = 0, .byte_offset = 0 });

        var unicode_iter = (try std.unicode.Utf8View.init(raw_source)).iterator();
        var char_position: usize = 0;
        var byte_position: usize = 0;
        while (unicode_iter.nextCodepoint()) |codepoint| {
            // safety: We know this is a valid codepoint as It was returned by Utf8View.
            const codepoint_length: usize = std.unicode.utf8CodepointSequenceLength(codepoint) catch unreachable;
            defer { // Ensure this is handled on all break and continue expressions.
                char_position += 1;
                byte_position += codepoint_length;
            }

            var current_line = &lines.items[lines.items.len - 1];
            // Check if we should go to the next line.
            for (SEPARATORS) |separator| {
                if (codepoint == separator)
                    try lines.append(.{
                        .char_offset = char_position + 1,
                        .byte_offset = byte_position + codepoint_length,
                    });
            }

            current_line.char_len += 1;
            current_line.byte_len += codepoint_length;
        }

        return Self{
            .raw = raw_source,
            .lines = try lines.toOwnedSlice(),
            .char_len = char_position,
            .byte_len = byte_position,
        };
    }
};

test "AnalyzedSource.compute handles ASCII and line splits" {
    const source = "hello\nworld";
    const analyzed = try AnalyzedSource.compute(std.testing.allocator, source);
    defer std.testing.allocator.free(analyzed.lines);

    try std.testing.expectEqualStrings(source, analyzed.raw);
    try std.testing.expectEqual(@as(usize, 11), analyzed.byte_len); // "hello\nworld" = 11 bytes
    try std.testing.expectEqual(@as(usize, 11), analyzed.char_len); // all ASCII, so same as byte_len

    try std.testing.expectEqual(@as(usize, 2), analyzed.lines.len);

    try std.testing.expectEqual(analyzed.lines[0].char_offset, 0);
    try std.testing.expectEqual(analyzed.lines[0].char_len, 6);
    try std.testing.expectEqual(analyzed.lines[0].byte_offset, 0);
    try std.testing.expectEqual(analyzed.lines[0].byte_len, 6);

    try std.testing.expectEqual(analyzed.lines[1].char_offset, 6);
    try std.testing.expectEqual(analyzed.lines[1].char_len, 5);
    try std.testing.expectEqual(analyzed.lines[1].byte_offset, 6);
    try std.testing.expectEqual(analyzed.lines[1].byte_len, 5);
}

test "AnalyzedSource.compute handles Unicode characters" {
    const source = "héllö\n🦀Rust!";
    const analyzed = try AnalyzedSource.compute(std.testing.allocator, source);
    defer std.testing.allocator.free(analyzed.lines);

    try std.testing.expectEqual(@as(usize, 17), analyzed.byte_len); // multibyte chars included
    try std.testing.expectEqual(@as(usize, 12), analyzed.char_len); // Unicode scalar count

    try std.testing.expectEqual(@as(usize, 2), analyzed.lines.len);
    try std.testing.expectEqual(@as(usize, 6), analyzed.lines[0].char_len); // héllö\n
    try std.testing.expectEqual(@as(usize, 8), analyzed.lines[0].byte_len); // héllö\n
    try std.testing.expectEqual(@as(usize, 6), analyzed.lines[1].char_len); // 🦀Rust!
    try std.testing.expectEqual(@as(usize, 9), analyzed.lines[1].byte_len); // 🦀Rust!
}

test "SourceCache.addSource and deduplication works" {
    const SourceId = u32;
    var cache = SourceCache(SourceId).init(std.testing.allocator);
    defer cache.deinit();

    const id: SourceId = 1;
    const source = "line 1\nline 2";
    try cache.addSource(id, source);
    try cache.addSource(id, "another source"); // should be ignored

    const entry = cache.sourcemap.get(id).?;
    try std.testing.expectEqualStrings(source, entry.raw);
    try std.testing.expectEqual(@as(usize, 2), entry.lines.len);
}

test "SourceCache.addSourcePreanalyzed inserts directly" {
    const SourceId = u8;
    var cache = SourceCache(SourceId).init(std.testing.allocator);
    defer cache.deinit();

    const fake = try AnalyzedSource.compute(std.testing.allocator, "preloaded\nsource");
    defer std.testing.allocator.free(fake.lines);

    try cache.addSourcePreanalyzed(42, fake);

    const result = cache.sourcemap.get(42).?;
    try std.testing.expectEqualStrings("preloaded\nsource", result.raw);
}
