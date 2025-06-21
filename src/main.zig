const std = @import("std");

const lib = @import("reportz_lib");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var stdout = std.io.getStdOut();
    var stdout_writer = stdout.writer().any();

    const example_diagnostic: lib.reports.Diagnostic = .{
        .source_id = "internal_0",
        .severity = .@"error",
        .code = "C001",
        .message = "Incompatible types",

        .labels = &.{
            lib.reports.Label{
                .color = .{ .basic = .bright_blue },
                .message = "Inside of this 'switch' expression.",
                .span = .{ .start = 12, .end = 66 },
            },
            lib.reports.Label{
                .color = .{ .basic = .magenta },
                .message = "This is of type 'number'.",
                .span = .{ .start = 43, .end = 44 },
            },
            lib.reports.Label{
                .color = .{ .basic = .cyan },
                .message = "This is an identifier lol. (just for showcase)",
                .span = .{ .start = 38, .end = 39 },
            },
            lib.reports.Label{
                .color = .{ .basic = .green },
                .message = "This is of type 'string'.",
                .span = .{ .start = 56, .end = 63 },
            },
        },
    };

    var source_cache = lib.cache.SourceCache.init(allocator);
    defer source_cache.deinit();

    try source_cache.addSource("internal_0",
        \\let value = switch (something) {
        \\    .a => 5,
        \\    .b => "other",
        \\};
    );

    var renderer = lib.Renderer{
        .allocator = allocator,
        .writer = &stdout_writer,

        .source_cache = &source_cache,
    };
    try renderer.render(&example_diagnostic);
}
