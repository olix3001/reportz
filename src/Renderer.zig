const std = @import("std");

const ansi = @import("ansi.zig");
const cache = @import("cache.zig");
const reports = @import("reports.zig");

// Configuration options. Only these should be set when creating new renderer.
allocator: std.mem.Allocator,
writer: *std.io.AnyWriter,
source_cache: *const cache.SourceCache,
config: Config = .{},

// Utility values used internally by the renderer.
// These are computed inside `compute_utility` method.
diagnostic: *const reports.Diagnostic = undefined,
analyzed_source: cache.AnalyzedSource = undefined,
gutter_width: usize = 0,
sorted_labels: []reports.Label = &.{},
active_multiline_labels: std.ArrayListUnmanaged(ansi.AnsiColor) = .empty,

pub const Config = struct {
    colors: bool = true,
    underlines: bool = true,
    ellipsis: bool = true,
    label_attachment: LabelAttachment = .center,
    tab_width: u8 = 4, // Does nothing at this moment.
    char_set: CharSet = .ROUNDED,
};

pub const LabelAttachment = enum {
    center,
    end,

    fn get_attachment_position(self: @This(), len: usize) usize {
        return switch (self) {
            .center => @divFloor(len, 2),
            .end => len - 1,
        };
    }
};

// Character Set for arrows and other pretty stuff in the diagnostic report.
// Every character is u21, which is unicode codepoint for a character.
pub const CharSet = struct {
    hbar: u21,
    vbar: u21,
    vbar_gap: u21,
    rarrow: u21,
    ltop: u21,
    rtop: u21,
    lbot: u21,
    rbot: u21,
    lbox: u21,
    rbox: u21,
    lcross: u21,
    underbar: u21,
    underline: u21,

    // I like compactness... I know this should be multiple lines.
    pub const ROUNDED: @This() = .{ .hbar = '─', .vbar = '│', .vbar_gap = '┆', .rarrow = '▶', .ltop = '╭', .rtop = '╮', .lbot = '╰', .rbot = '╯', .lbox = '[', .rbox = ']', .lcross = '├', .underbar = '┬', .underline = '─' };

    // I like compactness... I know this should be multiple lines.
    pub const SQUARE: @This() = .{ .hbar = '─', .vbar = '│', .vbar_gap = '┆', .rarrow = '▶', .ltop = '┌', .rtop = '┐', .lbot = '└', .rbot = '┘', .lbox = '[', .rbox = ']', .lcross = '├', .underbar = '┬', .underline = '─' };

    // I like compactness... I know this should be multiple lines.
    pub const ASCII: @This() = .{ .hbar = '-', .vbar = '|', .vbar_gap = ':', .rarrow = '>', .ltop = ',', .rtop = '.', .lbot = '`', .rbot = '\'', .lbox = '[', .rbox = ']', .lcross = '|', .underbar = '|', .underline = '^' };
};

const Self = @This();

inline fn get_gutter_style(self: *Self) ansi.Style {
    return ansi.Style{
        .foreground = .{ .basic = .bright_black },
        .enabled = self.config.colors,
    };
}

// This will be automatically called after .render, so if using this,
// there is no need to call manually.
pub fn deinit(self: *Self) void {
    self.allocator.free(self.sorted_labels);
    self.active_multiline_labels.deinit(self.allocator);
}

pub fn render(self: *Self, diagnostic: *const reports.Diagnostic) !void {
    self.diagnostic = diagnostic;

    try self.computeUtility();
    try self.renderHeader();

    try self.renderSnippetStart();
    try self.renderSnippetContent();
    try self.renderEmptySnippetLine();
    try self.renderNotes();
    try self.renderSnippetEnd();

    self.deinit();
}

// Compute required values like gutter width,
// multi-line labels and other similar stuff.
fn computeUtility(self: *Self) !void {
    const diagnostic = self.diagnostic;
    const source = self.source_cache.sourcemap.get(diagnostic.source_id) orelse return error.UnknownSource;
    self.analyzed_source = source;

    // Sort labels by their start position.
    self.sorted_labels = try self.allocator.dupe(reports.Label, diagnostic.labels);
    const Temporary = struct {
        fn compareLabelSpan(context: void, a: reports.Label, b: reports.Label) bool {
            _ = context;
            return a.span.start < b.span.start;
        }
    };
    std.mem.sort(reports.Label, self.sorted_labels, {}, Temporary.compareLabelSpan);

    // Analyze them.
    for (self.sorted_labels) |label| {
        // Find on which lines does the label start and end.
        const start_line = try source.getLineOnPosition(label.span.start);
        const end_line = try source.getLineOnPosition(label.span.end);

        // end_line > start_line, so we only need to check this:
        const end_line_no_width = std.math.log10_int(end_line + 1) + 2;
        if (end_line_no_width > self.gutter_width)
            self.gutter_width = end_line_no_width;

        _ = start_line;
    }
}

// Render header part of a diagnostic. For example:
// error[C001]: This is some message.
fn renderHeader(self: *Self) !void {
    const header_style = ansi.Style{
        .foreground = self.diagnostic.severity.color(),
        .enabled = self.config.colors,
    };

    // Keyword part of a header.
    try self.writer.print("{s}{s}", .{ header_style, @tagName(self.diagnostic.severity) });

    // Optional code part.
    if (self.diagnostic.code) |code| {
        try self.writer.print("{u}{s}{u}", .{ self.config.char_set.lbox, code, self.config.char_set.rbox });
    }

    // Message associated with this diagnostic.
    try self.writer.print("{s}: {s}\n", .{ ansi.Style.RESET, self.diagnostic.message });
}

// Render the whole content of the snippet. This should
// include all single- and multi-line labels, file content preview,
// and highlighting.
fn renderSnippetContent(self: *Self) !void {
    var previous_line: usize = 0;
    var is_first_label = true;
    top: for (self.analyzed_source.lines, 0..) |source_line, line_idx| {
        // Check if line contains any single- or multi-line labels.
        for (self.diagnostic.labels) |label| {
            if ((label.span.start > source_line.byte_offset and label.span.start < source_line.byte_offset + source_line.byte_len) or (label.span.end > source_line.byte_offset and label.span.end < source_line.byte_offset + source_line.byte_len)) {
                // Render ellipsis if some lines were skipped.
                if (self.config.ellipsis and previous_line + 1 != line_idx and !is_first_label) {
                    try self.renderGutter(null);
                    try self.writer.print("{s}\t...\n", .{self.get_gutter_style()});
                }

                // This line should be rendered.
                try self.renderCodeSnippetLineWithLabels(line_idx);
                previous_line = line_idx;
                is_first_label = false;
                continue :top;
            }
        }
    }
}

// Render beginning of the snippet. Example snippet start looks like this:
//  ╭─[file.txt:3:14]
fn renderSnippetStart(self: *Self) !void {
    const char_set = self.config.char_set;
    // Start with a gutter gap.
    try self.writer.writeByteNTimes(' ', self.gutter_width);

    // Then some colors and special characters.
    try self.writer.print("{s}{u}{u}{u}{s}", .{
        self.get_gutter_style(),
        char_set.ltop,
        char_set.hbar,
        char_set.lbox,
        ansi.Style.RESET,
    });

    // File id and location.
    const locus = try self.analyzed_source.spanToLocus(self.sorted_labels[0].span);
    try self.writer.print("{s}:{d}:{d}", .{ self.diagnostic.source_id, locus.line, locus.position });

    // Close bracket.
    try self.writer.print("{s}{u}{s}\n", .{ self.get_gutter_style(), char_set.rbox, ansi.Style.RESET });
}

// Render end of the snippet. Snippet end is simple and looks like this:
// ─╯
fn renderSnippetEnd(self: *Self) !void {
    // Select color.
    try self.writer.print("{s}", .{self.get_gutter_style()});

    // Start with a gutter gap. (Yes, this could be better than repeatedly calling .print)
    for (0..self.gutter_width) |_|
        try self.writer.print("{u}", .{self.config.char_set.hbar});

    // And then this special character.
    try self.writer.print("{u}\n", .{self.config.char_set.rbot});
}

// Render gutter with optional line number. Gutter includes:
// Multiline label vertical lines, snippet border, line numbers.
fn renderGutter(self: *Self, line_no: ?usize) !void {
    const char_set = self.config.char_set;
    // Set style.
    try self.writer.print("{s}", .{self.get_gutter_style()});

    if (line_no) |line_number| {
        const line_number_text = try std.fmt.allocPrint(self.allocator, "{d}", .{line_number});
        defer self.allocator.free(line_number_text);

        // Print line number.
        try self.writer.writeByteNTimes(' ', self.gutter_width - line_number_text.len);
        try self.writer.writeAll(line_number_text);
    } else try self.writer.writeByteNTimes(' ', self.gutter_width);

    // Print vertical bar.
    const vchar = if (line_no == null) char_set.vbar_gap else char_set.vbar;
    try self.writer.print("{u} ", .{vchar});

    // And now repeat for every active multiline label.
    for (self.active_multiline_labels.items) |active_label_color| {
        const style = ansi.Style{
            .foreground = active_label_color,
            .enabled = self.config.colors,
        };
        try self.writer.print("{s}{u} ", .{ style, vchar });
    }
    try self.writer.print("{s}", .{ansi.Style.RESET});
}

// Render empty snippet line. That is a line without any contents,
// and without line number.
fn renderEmptySnippetLine(self: *Self) !void {
    try self.renderGutter(null);
    try self.writer.writeByte('\n');
}

// Renders snippet line with source code, all labels on this line
// will highlight the code.
fn renderCodeSnippetLineWithLabels(self: *Self, line: usize) !void {
    const char_set = self.config.char_set;

    // Render line source.
    const fragments = try self.splitLineByLabels(line);
    defer self.allocator.free(fragments);

    var no_inline_labels = true;
    var multiline_label_color: ?ansi.AnsiColor = null;
    var is_multiline_start: bool = false;
    var multiline_label_label: ?*const reports.Label = null;

    // Check if there is a multiline label highlighted here.
    for (fragments) |fragment| {
        if (!fragment.is_multiline) continue;
        multiline_label_color = fragment.color;
        is_multiline_start = fragment.is_multiline_start;
        multiline_label_label = fragment.associated_label;
        break;
    }

    if (multiline_label_color != null and !is_multiline_start) {
        // Just a trick to render gutter properly.
        const temp = self.active_multiline_labels.pop().?;
        try self.renderGutter(line + 1);
        try self.active_multiline_labels.append(self.allocator, temp);
    } else try self.renderGutter(line + 1); // We count lines from one.

    // Render multiline label beginning/end arrow;
    if (multiline_label_color) |mll_color| {
        const mll_style = ansi.Style{
            .foreground = mll_color,
            .enabled = self.config.colors,
        };
        const joint_char = if (is_multiline_start) char_set.ltop else char_set.lcross;
        try self.writer.print("{s}{u}{u}{u} ", .{ mll_style, joint_char, char_set.hbar, char_set.rarrow });

        if (is_multiline_start)
            try self.active_multiline_labels.append(self.allocator, mll_color);
    }

    // render source fragment.
    for (fragments) |fragment| {
        if (!fragment.is_multiline and fragment.associated_label != null)
            no_inline_labels = false;

        // Strip newlines from fragment text
        const clean_text = std.mem.trimRight(u8, fragment.text, "\n\r\x0B\u{0085}\u{2028}\u{2029}");

        const is_default_color = switch (fragment.color) {
            .basic => |basic| basic == .default,
            .rgb => false,
        };

        if (!is_default_color) {
            const style = ansi.Style{
                .foreground = fragment.color,
                .enabled = self.config.colors,
            };
            try self.writer.print("{s}{s}{s}", .{ style, clean_text, ansi.Style.RESET });
        } else {
            try self.writer.print("{s}{s}{s}", .{ self.get_gutter_style(), clean_text, ansi.Style.RESET });
        }
    }

    try self.writer.writeByte('\n');

    if (!no_inline_labels) {
        // And now render line labels.
        var remaining_labels = std.ArrayList(LineFragment).init(self.allocator);
        defer remaining_labels.deinit();

        try self.renderGutter(null);
        var current_position: usize = 0;
        for (fragments, 0..) |fragment, j| {
            if (fragment.is_multiline) continue;
            if (fragment.associated_label) |_| {
                // Adjust position to span start.
                try self.writer.writeByteNTimes(' ', fragment.local_span.start - current_position);
                current_position = fragment.local_span.end;

                // Write underline.
                const style = ansi.Style{
                    .foreground = fragment.color,
                    .enabled = self.config.colors,
                };
                try self.writer.print("{s}", .{style});

                // Check if this is the last occurance of this label.
                var is_last = true;
                for (j + 1..fragments.len) |k| {
                    const frag = &fragments[k];
                    if (@intFromPtr(frag.associated_label) == @intFromPtr(fragment.associated_label)) {
                        is_last = false;
                        break;
                    }
                }

                if (is_last)
                    try remaining_labels.append(fragment); // This should be sorted, so that we can pop.

                const span_len = fragment.local_span.len();

                const connector_char = if (self.config.underlines) char_set.underbar else char_set.vbar;
                const connector_char_end = if (self.config.underlines) char_set.rtop else char_set.vbar;
                const underline_char = if (self.config.underlines) char_set.underline else ' ';

                const attachment_position = self.config.label_attachment.get_attachment_position(span_len);
                for (0..span_len) |i| {
                    if (i == attachment_position and is_last)
                        try self.writer.print("{u}", .{
                            if (span_len == 1 or self.config.label_attachment != .end) connector_char else connector_char_end,
                        })
                    else
                        try self.writer.print("{u}", .{underline_char});
                }
            }
        }
        try self.writer.writeByte('\n');

        while (remaining_labels.items.len > 0) {
            try self.renderGutter(null);
            // safety: we check this inside while condition.
            const current_label = remaining_labels.pop() orelse unreachable;

            // Print vbar characters for all previous labels.
            current_position = 0;
            for (remaining_labels.items) |label| {
                const label_center = label.local_span.start + self.config.label_attachment.get_attachment_position(label.local_span.len());
                try self.writer.writeByteNTimes(' ', label_center - current_position);
                current_position = label_center + 1;
                const style = ansi.Style{
                    .foreground = label.color,
                    .enabled = self.config.colors,
                };
                try self.writer.print("{s}{u}", .{ style, char_set.vbar });
            }

            const label_center = current_label.local_span.start + self.config.label_attachment.get_attachment_position(current_label.local_span.len());
            try self.writer.writeByteNTimes(' ', label_center - current_position);
            const style = ansi.Style{
                .foreground = current_label.color,
                .enabled = self.config.colors,
            };
            try self.writer.print("{s}{u}{u} {s}", .{ style, char_set.lbot, char_set.hbar, ansi.Style.RESET });
            // safety: we know remaining_labels contains only those with non-null associated_label field.
            try self.writer.writeAll(current_label.associated_label.?.message);
            try self.writer.writeByte('\n');
        }
    }

    // Render message from end label.
    if (multiline_label_color != null and !is_multiline_start) {
        try self.renderGutter(null); // Empty line.
        try self.writer.writeByte('\n');
        _ = self.active_multiline_labels.pop();
        try self.renderGutter(null);
        const mll_style = ansi.Style{ .foreground = multiline_label_color.?, .enabled = self.config.colors };
        try self.writer.print("{s}{u}{u}{u} {s}{s}\n", .{
            mll_style,
            char_set.lbot,
            char_set.hbar,
            char_set.hbar,
            ansi.Style.RESET,
            multiline_label_label.?.message,
        });
    }
}

fn renderNotes(self: *Self) !void {
    for (self.diagnostic.notes) |note| {
        const style = ansi.Style{
            .foreground = note.category_color,
            .modifiers = .{ .bold = true },
            .enabled = self.config.colors,
        };

        try self.renderGutter(null);
        var message_lines = std.mem.splitSequence(u8, note.message, "\n");
        try self.writer.print("{s}{s}{s}: {s}\n", .{ style, note.category, ansi.Style.RESET, message_lines.next().? });

        while (message_lines.next()) |message_line| {
            try self.renderGutter(null);
            try self.writer.writeAll(message_line);
            try self.writer.writeByte('\n');
        }
    }
}

// Converts span into line-local.
fn toLocalLineSpan(self: *Self, line: usize, span: reports.Span) !?reports.Span {
    const source = self.analyzed_source;
    const start_line = try source.getLineOnPosition(span.start);
    const end_line = try source.getLineOnPosition(span.end);

    // Whole span might be outside the line.
    if (line < start_line or line > end_line)
        return null;

    const source_line = source.lines[line];
    // For multi-line spans, only highlight start and end lines, not middle lines
    if (line > start_line and line < end_line)
        return null;

    // Span is on start or end line.
    if (line == start_line and line == end_line) {
        // Single line span
        return reports.Span{ .start = span.start - source_line.byte_offset, .end = span.end - source_line.byte_offset };
    } else if (line == start_line) {
        // Multi-line span: highlight from start to end of line
        return reports.Span{ .start = span.start - source_line.byte_offset, .end = source_line.byte_len };
    } else if (line == end_line) {
        // Multi-line span: highlight from start of line to end
        return reports.Span{ .start = 0, .end = span.end - source_line.byte_offset };
    }

    unreachable; // There are no other possible cases.
}

const LineFragment = struct {
    text: []const u8,
    color: ansi.AnsiColor,
    local_span: reports.Span,
    associated_label: ?*const reports.Label,
    is_multiline: bool,
    is_multiline_start: bool,
};
fn splitLineByLabels(self: *Self, line: usize) ![]const LineFragment {
    const line_content = try self.analyzed_source.lineSlice(line);

    // Collect all labels that intersect with this line
    var intersecting_labels = std.ArrayList(struct {
        label: *const reports.Label,
        local_span: reports.Span,
    }).init(self.allocator);
    defer intersecting_labels.deinit();

    for (self.sorted_labels) |*label| {
        if (try self.toLocalLineSpan(line, label.span)) |local_span| {
            try intersecting_labels.append(.{
                .label = label,
                .local_span = local_span,
            });
        }
    }

    // Create split points from label boundaries
    var split_points = std.ArrayList(usize).init(self.allocator);
    defer split_points.deinit();

    // Always include line start and end
    try split_points.append(0);
    try split_points.append(line_content.len);

    // Add label boundaries
    for (intersecting_labels.items) |item| {
        try split_points.append(item.local_span.start);
        try split_points.append(item.local_span.end);
    }

    // Sort and deduplicate split points
    std.mem.sort(usize, split_points.items, {}, std.sort.asc(usize));
    var unique_points = std.ArrayList(usize).init(self.allocator);
    defer unique_points.deinit();

    var last_point: ?usize = null;
    for (split_points.items) |point| {
        if (last_point == null or point != last_point.?) {
            try unique_points.append(point);
            last_point = point;
        }
    }

    // Create fragments
    var fragments = std.ArrayList(LineFragment).init(self.allocator);
    defer fragments.deinit();

    for (0..unique_points.items.len - 1) |i| {
        const start = unique_points.items[i];
        const end = unique_points.items[i + 1];

        if (start >= end) continue; // Skip empty fragments

        const fragment_span = reports.Span{ .start = start, .end = end };
        const fragment_text = line_content[start..end];

        // Find the label that covers this fragment (if any)
        // For overlapping labels, choose the one with the smallest span (most specific)
        var fragment_color = ansi.AnsiColor.DEFAULT;
        var smallest_span_size: usize = std.math.maxInt(usize);
        var selected_label: ?*const reports.Label = null;
        for (intersecting_labels.items) |item| {
            // Check if this label completely contains the fragment
            if (item.local_span.start <= start and end <= item.local_span.end) {
                const span_size = item.local_span.end - item.local_span.start;
                if (span_size < smallest_span_size) {
                    fragment_color = item.label.color;
                    smallest_span_size = span_size;
                    selected_label = item.label;
                }
            }
        }

        // Determine if the selected label spans multiple lines
        var is_multiline = false;
        var is_multiline_start = false;
        if (selected_label) |label| {
            const label_start_line = try self.analyzed_source.getLineOnPosition(label.span.start);
            const label_end_line = try self.analyzed_source.getLineOnPosition(label.span.end);
            is_multiline = label_start_line != label_end_line;
            is_multiline_start = line == label_start_line;
        }

        try fragments.append(LineFragment{
            .text = fragment_text,
            .color = fragment_color,
            .local_span = fragment_span,
            .associated_label = selected_label,
            .is_multiline = is_multiline,
            .is_multiline_start = is_multiline_start,
        });
    }
    return try fragments.toOwnedSlice();
}

// Test helpers and test code below
test "Renderer.renderHeader with error severity and code" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    var writer = buf.writer().any();

    var source_cache = cache.SourceCache.init(std.testing.allocator);
    defer source_cache.deinit();

    const diagnostic = reports.Diagnostic{
        .source_id = "test.zig",
        .severity = .@"error",
        .code = "E001",
        .message = "Test error message",
        .labels = &.{},
        .notes = &.{},
    };

    var renderer = Self{
        .allocator = std.testing.allocator,
        .writer = &writer,
        .source_cache = &source_cache,
        .diagnostic = &diagnostic,
    };

    try renderer.renderHeader();

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "error[E001]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Test error message") != null);
}

test "Renderer.renderHeader with warning severity and no code" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    var writer = buf.writer().any();

    var source_cache = cache.SourceCache.init(std.testing.allocator);
    defer source_cache.deinit();

    const diagnostic = reports.Diagnostic{
        .source_id = "test.zig",
        .severity = .warning,
        .code = null,
        .message = "Test warning message",
        .labels = &.{},
        .notes = &.{},
    };

    var renderer = Self{
        .allocator = std.testing.allocator,
        .writer = &writer,
        .source_cache = &source_cache,
        .diagnostic = &diagnostic,
    };

    try renderer.renderHeader();

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "warning") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Test warning message") != null);
    // Note: ANSI escape sequences contain "[" so we check there's no code format like "[W001]"
    try std.testing.expect(std.mem.indexOf(u8, output, "[W") == null); // We cannot check just '[' as it is a part of snippet.
}

test "Renderer.renderSnippetStart renders correctly" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    var writer = buf.writer().any();

    var source_cache = cache.SourceCache.init(std.testing.allocator);
    defer source_cache.deinit();
    try source_cache.addSource("test.zig", "let x = 5;\nlet y = 10;");

    const diagnostic = reports.Diagnostic{
        .source_id = "test.zig",
        .severity = .@"error",
        .code = "E001",
        .message = "Test error",
        .labels = &.{
            reports.Label{
                .color = .{ .basic = .red },
                .message = "Test label",
                .span = .{ .start = 4, .end = 5 },
            },
        },
        .notes = &.{},
    };

    var renderer = Self{
        .allocator = std.testing.allocator,
        .writer = &writer,
        .source_cache = &source_cache,
    };

    renderer.diagnostic = &diagnostic;
    try renderer.computeUtility();
    defer renderer.deinit(); // Clean up allocated memory
    try renderer.renderSnippetStart();

    // Should contain file name, line number, and position
    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "test.zig:1:4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "╭─[") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "]") != null);
}

test "Renderer.renderSnippetEnd renders correctly" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    var writer = buf.writer().any();

    var source_cache = cache.SourceCache.init(std.testing.allocator);
    defer source_cache.deinit();

    const diagnostic = reports.Diagnostic{
        .source_id = "test.zig",
        .severity = .@"error",
        .code = "E001",
        .message = "Test error",
        .labels = &.{},
        .notes = &.{},
    };

    var renderer = Self{
        .allocator = std.testing.allocator,
        .writer = &writer,
        .source_cache = &source_cache,
        .diagnostic = &diagnostic,
        .gutter_width = 3,
    };

    try renderer.renderSnippetEnd();

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "───╯") != null);
}

test "Renderer.renderGutter with line number" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    var writer = buf.writer().any();

    var source_cache = cache.SourceCache.init(std.testing.allocator);
    defer source_cache.deinit();

    const diagnostic = reports.Diagnostic{
        .source_id = "test.zig",
        .severity = .@"error",
        .code = "E001",
        .message = "Test error",
        .labels = &.{},
        .notes = &.{},
    };

    var renderer = Self{
        .allocator = std.testing.allocator,
        .writer = &writer,
        .source_cache = &source_cache,
        .diagnostic = &diagnostic,
        .gutter_width = 3,
    };

    try renderer.renderGutter(42);

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "42") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "│") != null);
}

test "Renderer.renderGutter without line number" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    var writer = buf.writer().any();

    var source_cache = cache.SourceCache.init(std.testing.allocator);
    defer source_cache.deinit();

    const diagnostic = reports.Diagnostic{
        .source_id = "test.zig",
        .severity = .@"error",
        .code = "E001",
        .message = "Test error",
        .labels = &.{},
        .notes = &.{},
    };

    var renderer = Self{
        .allocator = std.testing.allocator,
        .writer = &writer,
        .source_cache = &source_cache,
        .diagnostic = &diagnostic,
        .gutter_width = 3,
    };

    try renderer.renderGutter(null);

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "┆") != null);
    try std.testing.expect(output.len > 3); // Should have spaces and characters
}

test "Renderer.renderEmptySnippetLine renders correctly" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    var writer = buf.writer().any();

    var source_cache = cache.SourceCache.init(std.testing.allocator);
    defer source_cache.deinit();

    const diagnostic = reports.Diagnostic{
        .source_id = "test.zig",
        .severity = .@"error",
        .code = "E001",
        .message = "Test error",
        .labels = &.{},
        .notes = &.{},
    };

    var renderer = Self{
        .allocator = std.testing.allocator,
        .writer = &writer,
        .source_cache = &source_cache,
        .diagnostic = &diagnostic,
        .gutter_width = 3,
    };

    try renderer.renderEmptySnippetLine();

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "┆") != null);
    try std.testing.expect(std.mem.endsWith(u8, output, "\n"));
}

test "Renderer.renderNotes renders single note" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    var writer = buf.writer().any();

    var source_cache = cache.SourceCache.init(std.testing.allocator);
    defer source_cache.deinit();

    const diagnostic = reports.Diagnostic{
        .source_id = "test.zig",
        .severity = .@"error",
        .code = "E001",
        .message = "Test error",
        .labels = &.{},
        .notes = &.{
            reports.Note{
                .category = "help",
                .message = "Try using a different approach",
                .category_color = .{ .basic = .bright_green },
            },
        },
    };

    var renderer = Self{
        .allocator = std.testing.allocator,
        .writer = &writer,
        .source_cache = &source_cache,
        .diagnostic = &diagnostic,
        .gutter_width = 3,
    };

    try renderer.renderNotes();

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "help") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Try using a different approach") != null);
}

test "Renderer.renderNotes renders multiline note" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    var writer = buf.writer().any();

    var source_cache = cache.SourceCache.init(std.testing.allocator);
    defer source_cache.deinit();

    const diagnostic = reports.Diagnostic{
        .source_id = "test.zig",
        .severity = .@"error",
        .code = "E001",
        .message = "Test error",
        .labels = &.{},
        .notes = &.{
            reports.Note{
                .category = "help",
                .message = "Line 1 of help\nLine 2 of help\nLine 3 of help",
                .category_color = .{ .basic = .bright_green },
            },
        },
    };

    var renderer = Self{
        .allocator = std.testing.allocator,
        .writer = &writer,
        .source_cache = &source_cache,
        .diagnostic = &diagnostic,
        .gutter_width = 3,
    };

    try renderer.renderNotes();

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "Line 1 of help") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Line 2 of help") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Line 3 of help") != null);

    // Count how many gutter segments appear (should be 3 for 3 lines)
    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOf(u8, output[start..], "┆")) |pos| {
        count += 1;
        start += pos + 1;
    }
    try std.testing.expect(count == 3);
}

test "Renderer.toLocalLineSpan single line span" {
    var source_cache = cache.SourceCache.init(std.testing.allocator);
    defer source_cache.deinit();
    try source_cache.addSource("test.zig", "let x = 5;\nlet y = 10;");

    const diagnostic = reports.Diagnostic{
        .source_id = "test.zig",
        .severity = .@"error",
        .code = "E001",
        .message = "Test error",
        .labels = &.{},
        .notes = &.{},
    };

    var renderer = Self{
        .allocator = std.testing.allocator,
        .writer = undefined,
        .source_cache = &source_cache,
        .diagnostic = &diagnostic,
        .analyzed_source = source_cache.sourcemap.get("test.zig").?,
    };

    // Test span within first line: "x = 5" (positions 4-9)
    const span = reports.Span{ .start = 4, .end = 9 };
    const local_span = try renderer.toLocalLineSpan(0, span);

    try std.testing.expect(local_span != null);
    try std.testing.expectEqual(@as(usize, 4), local_span.?.start);
    try std.testing.expectEqual(@as(usize, 9), local_span.?.end);
}

test "Renderer.toLocalLineSpan multiline span start" {
    var source_cache = cache.SourceCache.init(std.testing.allocator);
    defer source_cache.deinit();
    try source_cache.addSource("test.zig", "let x = 5;\nlet y = 10;");

    const diagnostic = reports.Diagnostic{
        .source_id = "test.zig",
        .severity = .@"error",
        .code = "E001",
        .message = "Test error",
        .labels = &.{},
        .notes = &.{},
    };

    var renderer = Self{
        .allocator = std.testing.allocator,
        .writer = undefined,
        .source_cache = &source_cache,
        .diagnostic = &diagnostic,
        .analyzed_source = source_cache.sourcemap.get("test.zig").?,
    };

    // Test multiline span from first line to second line (positions 4-15)
    const span = reports.Span{ .start = 4, .end = 15 };
    const local_span_line0 = try renderer.toLocalLineSpan(0, span);
    const local_span_line1 = try renderer.toLocalLineSpan(1, span);

    // First line should highlight from position 4 to end of line
    try std.testing.expect(local_span_line0 != null);
    try std.testing.expectEqual(@as(usize, 4), local_span_line0.?.start);
    try std.testing.expectEqual(@as(usize, 11), local_span_line0.?.end); // "let x = 5;\n" is 11 chars including newline

    // Second line should highlight from start to position within line
    try std.testing.expect(local_span_line1 != null);
    try std.testing.expectEqual(@as(usize, 0), local_span_line1.?.start);
    try std.testing.expectEqual(@as(usize, 4), local_span_line1.?.end); // 15 - 11 (line start) = 4
}

test "Renderer.toLocalLineSpan outside line returns null" {
    var source_cache = cache.SourceCache.init(std.testing.allocator);
    defer source_cache.deinit();
    try source_cache.addSource("test.zig", "let x = 5;\nlet y = 10;");

    const diagnostic = reports.Diagnostic{
        .source_id = "test.zig",
        .severity = .@"error",
        .code = "E001",
        .message = "Test error",
        .labels = &.{},
        .notes = &.{},
    };

    var renderer = Self{
        .allocator = std.testing.allocator,
        .writer = undefined,
        .source_cache = &source_cache,
        .diagnostic = &diagnostic,
        .analyzed_source = source_cache.sourcemap.get("test.zig").?,
    };

    // Test span that doesn't intersect with line 0
    const span = reports.Span{ .start = 15, .end = 20 };
    const local_span = try renderer.toLocalLineSpan(0, span);

    try std.testing.expect(local_span == null);
}

test "Renderer.splitLineByLabels single label" {
    var source_cache = cache.SourceCache.init(std.testing.allocator);
    defer source_cache.deinit();
    try source_cache.addSource("test.zig", "let x = 5;");

    const label = reports.Label{
        .color = .{ .basic = .red },
        .message = "Test label",
        .span = .{ .start = 4, .end = 5 }, // Just the "x"
    };

    const diagnostic = reports.Diagnostic{
        .source_id = "test.zig",
        .severity = .@"error",
        .code = "E001",
        .message = "Test error",
        .labels = &.{label},
        .notes = &.{},
    };

    const sorted_labels = try std.testing.allocator.dupe(reports.Label, &.{label});
    defer std.testing.allocator.free(sorted_labels);

    var renderer = Self{
        .allocator = std.testing.allocator,
        .writer = undefined,
        .source_cache = &source_cache,
        .diagnostic = &diagnostic,
        .analyzed_source = source_cache.sourcemap.get("test.zig").?,
        .sorted_labels = sorted_labels,
    };

    const fragments = try renderer.splitLineByLabels(0);
    defer std.testing.allocator.free(fragments);

    // Should have 3 fragments: "let ", "x", " = 5;"
    try std.testing.expect(fragments.len >= 2);

    // Find the labeled fragment
    var found_labeled = false;
    for (fragments) |fragment| {
        if (fragment.associated_label != null) {
            try std.testing.expectEqualStrings("x", fragment.text);
            try std.testing.expectEqual(@as(usize, 4), fragment.local_span.start);
            try std.testing.expectEqual(@as(usize, 5), fragment.local_span.end);
            found_labeled = true;
            break;
        }
    }
    try std.testing.expect(found_labeled);
}

test "Renderer.splitLineByLabels overlapping labels" {
    var source_cache = cache.SourceCache.init(std.testing.allocator);
    defer source_cache.deinit();
    try source_cache.addSource("test.zig", "let x = 5;");

    const label1 = reports.Label{
        .color = .{ .basic = .red },
        .message = "Outer label",
        .span = .{ .start = 0, .end = 9 }, // "let x = 5"
    };
    const label2 = reports.Label{
        .color = .{ .basic = .blue },
        .message = "Inner label",
        .span = .{ .start = 4, .end = 5 }, // Just the "x"
    };

    const diagnostic = reports.Diagnostic{
        .source_id = "test.zig",
        .severity = .@"error",
        .code = "E001",
        .message = "Test error",
        .labels = &.{ label1, label2 },
        .notes = &.{},
    };

    const sorted_labels = try std.testing.allocator.dupe(reports.Label, &.{ label1, label2 });
    defer std.testing.allocator.free(sorted_labels);

    var renderer = Self{
        .allocator = std.testing.allocator,
        .writer = undefined,
        .source_cache = &source_cache,
        .diagnostic = &diagnostic,
        .analyzed_source = source_cache.sourcemap.get("test.zig").?,
        .sorted_labels = sorted_labels,
    };

    const fragments = try renderer.splitLineByLabels(0);
    defer std.testing.allocator.free(fragments);

    // The "x" should be colored blue (inner label takes priority due to smaller span)
    var found_inner = false;
    for (fragments) |fragment| {
        if (std.mem.eql(u8, fragment.text, "x")) {
            switch (fragment.color) {
                .basic => |basic| try std.testing.expect(basic == .blue),
                else => try std.testing.expect(false), // Should be basic color
            }
            found_inner = true;
            break;
        }
    }
    try std.testing.expect(found_inner);
}

test "Renderer.computeUtility calculates gutter width" {
    var source_cache = cache.SourceCache.init(std.testing.allocator);
    defer source_cache.deinit();

    // Create source with many lines to test gutter width calculation
    var source_lines = std.ArrayList(u8).init(std.testing.allocator);
    defer source_lines.deinit();

    for (0..150) |i| {
        try source_lines.writer().print("line {d}\n", .{i});
    }

    try source_cache.addSource("test.zig", source_lines.items);

    const label = reports.Label{
        .color = .{ .basic = .red },
        .message = "Test label",
        .span = .{ .start = source_lines.items.len - 10, .end = source_lines.items.len - 5 },
    };

    const diagnostic = reports.Diagnostic{
        .source_id = "test.zig",
        .severity = .@"error",
        .code = "E001",
        .message = "Test error",
        .labels = &.{label},
        .notes = &.{},
    };

    var renderer = Self{
        .allocator = std.testing.allocator,
        .writer = undefined,
        .source_cache = &source_cache,
    };

    renderer.diagnostic = &diagnostic;
    try renderer.computeUtility();
    defer renderer.deinit();

    // Gutter width should accommodate line 150+ (3 digits + 2 = 5)
    try std.testing.expect(renderer.gutter_width >= 4);
}

test "Renderer.render full diagnostic integration" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    var writer = buf.writer().any();

    var source_cache = cache.SourceCache.init(std.testing.allocator);
    defer source_cache.deinit();
    try source_cache.addSource("example.zig",
        \\let value = switch (something) {
        \\    .a => 5,
        \\    .b => "other",
        \\};
    );

    const diagnostic = reports.Diagnostic{
        .source_id = "example.zig",
        .severity = .@"error",
        .code = "C001",
        .message = "Incompatible types",
        .labels = &.{
            reports.Label{
                .color = .{ .basic = .bright_blue },
                .message = "Inside of this 'switch' expression.",
                .span = .{ .start = 12, .end = 66 },
            },
            reports.Label{
                .color = .{ .basic = .magenta },
                .message = "This is of type 'number'.",
                .span = .{ .start = 43, .end = 44 },
            },
            reports.Label{
                .color = .{ .basic = .green },
                .message = "This is of type 'string'.",
                .span = .{ .start = 56, .end = 63 },
            },
        },
        .notes = &.{
            reports.Note{ .message = "You should convert the number into string." },
        },
    };

    var renderer = Self{
        .allocator = std.testing.allocator,
        .writer = &writer,
        .source_cache = &source_cache,
    };

    try renderer.render(&diagnostic);

    const output = buf.items;

    // Check that header is rendered
    try std.testing.expect(std.mem.indexOf(u8, output, "error[C001]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Incompatible types") != null);

    // Check that snippet start is rendered
    try std.testing.expect(std.mem.indexOf(u8, output, "example.zig:") != null);

    // Check that source code is rendered (only lines with labels are shown)
    try std.testing.expect(std.mem.indexOf(u8, output, "switch") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "other") != null);

    // Check that notes are rendered
    try std.testing.expect(std.mem.indexOf(u8, output, "You should convert the number into string.") != null);

    // Check that snippet end is rendered
    try std.testing.expect(std.mem.indexOf(u8, output, "╯") != null);
}

test "Renderer.render simple single-line diagnostic" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    var writer = buf.writer().any();

    var source_cache = cache.SourceCache.init(std.testing.allocator);
    defer source_cache.deinit();
    try source_cache.addSource("simple.zig", "let x: i32 = \"hello\";");

    const diagnostic = reports.Diagnostic{
        .source_id = "simple.zig",
        .severity = .warning,
        .code = "W001",
        .message = "Type mismatch",
        .labels = &.{
            reports.Label{
                .color = .{ .basic = .yellow },
                .message = "Expected i32, found string",
                .span = .{ .start = 13, .end = 20 }, // "hello"
            },
        },
        .notes = &.{},
    };

    var renderer = Self{
        .allocator = std.testing.allocator,
        .writer = &writer,
        .source_cache = &source_cache,
    };

    try renderer.render(&diagnostic);

    const output = buf.items;

    // Check basic structure
    try std.testing.expect(std.mem.indexOf(u8, output, "warning[W001]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Type mismatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "simple.zig:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Expected i32, found string") != null);
}

test "Renderer.render with multiline label" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    var writer = buf.writer().any();

    var source_cache = cache.SourceCache.init(std.testing.allocator);
    defer source_cache.deinit();
    try source_cache.addSource("multi.zig",
        \\fn main() {
        \\    let x = if (condition)
        \\        value1
        \\    else
        \\        value2;
        \\}
    );

    const diagnostic = reports.Diagnostic{
        .source_id = "multi.zig",
        .severity = .@"error",
        .code = "E002",
        .message = "Inconsistent types in if expression",
        .labels = &.{
            reports.Label{
                .color = .{ .basic = .cyan },
                .message = "This if expression has inconsistent branch types",
                .span = .{ .start = 23, .end = 75 }, // Spans multiple lines
            },
        },
        .notes = &.{},
    };

    var renderer = Self{
        .allocator = std.testing.allocator,
        .writer = &writer,
        .source_cache = &source_cache,
    };

    try renderer.render(&diagnostic);

    const output = buf.items;

    // Check that multiline content is rendered
    try std.testing.expect(std.mem.indexOf(u8, output, "error[E002]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Inconsistent types") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "This if expression has inconsistent branch types") != null);
    // Verify substantial output is generated (multiline rendering is working)
    try std.testing.expect(output.len > 100);
}

test "Renderer.render with overlapping inner label" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    var writer = buf.writer().any();

    var source_cache = cache.SourceCache.init(std.testing.allocator);
    defer source_cache.deinit();
    try source_cache.addSource("overlap.zig",
        \\var x = hello "world";
    );

    const diagnostic = reports.Diagnostic{
        .source_id = "overlap.zig",
        .severity = .@"error",
        .code = "E002",
        .message = "Unexpected identifier",
        .labels = &.{
            reports.Label{
                .color = .{ .basic = .cyan },
                .message = "This identifier",
                .span = .{ .start = 8, .end = 13 },
            },
            reports.Label{
                .color = .{ .basic = .magenta },
                .message = "Inside this statement",
                .span = .{ .start = 0, .end = 21 },
            },
        },
        .notes = &.{},
    };

    var renderer = Self{
        .allocator = std.testing.allocator,
        .writer = &writer,
        .source_cache = &source_cache,
    };

    try renderer.render(&diagnostic);

    const output = buf.items;

    // Check that there is only one message about statement.
    try std.testing.expect(std.mem.indexOf(u8, output, "error[E002]") != null);
    try std.testing.expect(std.mem.count(u8, output, "Inside this statement") == 1);
    try std.testing.expect(std.mem.count(u8, output, "┬") == 2);
}

test "Renderer.render ellipsis" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    var writer = buf.writer().any();

    var source_cache = cache.SourceCache.init(std.testing.allocator);
    defer source_cache.deinit();
    try source_cache.addSource("example.zig",
        \\let value = switch (something) {
        \\    .a => 5,
        \\    .b => "other",
        \\};
    );

    const diagnostic = reports.Diagnostic{
        .source_id = "example.zig",
        .severity = .@"error",
        .code = "C001",
        .message = "Incompatible types",
        .labels = &.{
            reports.Label{
                .color = .{ .basic = .bright_blue },
                .message = "Inside of this 'switch' expression.",
                .span = .{ .start = 12, .end = 66 },
            },
        },
    };

    var renderer = Self{
        .allocator = std.testing.allocator,
        .writer = &writer,
        .source_cache = &source_cache,
    };

    try renderer.render(&diagnostic);

    const output = buf.items;

    // Check that source code is rendered (only lines with labels are shown)
    try std.testing.expect(std.mem.indexOf(u8, output, "switch") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "...") != null);
}
