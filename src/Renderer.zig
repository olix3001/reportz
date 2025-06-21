const std = @import("std");

const ansi = @import("ansi.zig");
const cache = @import("cache.zig");
const reports = @import("reports.zig");

allocator: std.mem.Allocator,
writer: *std.io.AnyWriter,

source_cache: *const cache.SourceCache,
diagnostic: *const reports.Diagnostic = undefined,

// Utility values used internally by the renderer.
// These are computed inside `compute_utility` method.
analyzed_source: cache.AnalyzedSource = undefined,
gutter_width: usize = 0,
sorted_labels: []reports.Label = &.{},
active_multiline_labels: std.ArrayListUnmanaged(ansi.AnsiColor) = .empty,

const Self = @This();

const GUTTER_STYLE = ansi.Style{ .foreground = .{ .basic = .bright_black } };

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
    try self.renderEmptySnippetLine();

    try self.renderCodeSnippetLineWithLabels(0);
    try self.renderCodeSnippetLineWithLabels(1);
    try self.renderCodeSnippetLineWithLabels(2);
    try self.renderCodeSnippetLineWithLabels(3);

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
    };

    // Keyword part of a header.
    try self.writer.print("{s}{s}", .{ header_style, @tagName(self.diagnostic.severity) });

    // Optional code part.
    if (self.diagnostic.code) |code| {
        try self.writer.print("[{s}]", .{code});
    }

    // Message associated with this diagnostic.
    try self.writer.print("{s}: {s}\n", .{ ansi.Style.RESET, self.diagnostic.message });
}

// Render beginning of the snippet. Example snippet start looks like this:
//  ╭─[file.txt:3:14]
fn renderSnippetStart(self: *Self) !void {
    const char_set = self.diagnostic.config.char_set;
    // Start with a gutter gap.
    try self.writer.writeByteNTimes(' ', self.gutter_width);

    // Then some colors and special characters.
    try self.writer.print("{s}{u}{u}[{s}", .{ GUTTER_STYLE, char_set.ltop, char_set.hbar, ansi.Style.RESET });

    // File id and location.
    const locus = try self.analyzed_source.spanToLocus(self.sorted_labels[0].span);
    try self.writer.print("{s}:{d}:{d}", .{ self.diagnostic.source_id, locus.line, locus.position });

    // Close bracket.
    try self.writer.print("{s}]{s}\n", .{ GUTTER_STYLE, ansi.Style.RESET });
}

// Render end of the snippet. Snippet end is simple and looks like this:
// ─╯
fn renderSnippetEnd(self: *Self) !void {
    // Select color.
    try self.writer.print("{s}", .{GUTTER_STYLE});

    // Start with a gutter gap. (Yes, this could be better than repeatedly calling .print)
    for (0..self.gutter_width) |_|
        try self.writer.print("{u}", .{self.diagnostic.config.char_set.hbar});

    // And then this special character.
    try self.writer.print("{u}\n", .{self.diagnostic.config.char_set.rbot});
}

// Render gutter with optional line number. Gutter includes:
// Multiline label vertical lines, snippet border, line numbers.
fn renderGutter(self: *Self, line_no: ?usize) !void {
    const char_set = self.diagnostic.config.char_set;
    // Set style.
    try self.writer.print("{s}", .{GUTTER_STYLE});

    if (line_no) |line_number| {
        const line_number_text = try std.fmt.allocPrint(self.allocator, "{d}", .{line_number});
        defer self.allocator.free(line_number_text);

        // Print line number.
        try self.writer.writeByteNTimes(' ', self.gutter_width - line_number_text.len);
        try self.writer.writeAll(line_number_text);
    } else try self.writer.writeByteNTimes(' ', self.gutter_width);

    // Print vertical bar.
    try self.writer.print("{u} {s}", .{ char_set.vbar, ansi.Style.RESET });
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
    try self.renderGutter(line + 1); // We count lines from one.

    // Render line source.
    const fragments = try self.splitLineByLabels(line);
    defer self.allocator.free(fragments);

    for (fragments) |fragment| {
        // Strip newlines from fragment text
        const clean_text = std.mem.trimRight(u8, fragment.text, "\n\r\x0B\u{0085}\u{2028}\u{2029}");

        const is_default_color = switch (fragment.color) {
            .basic => |basic| basic == .default,
            .rgb => false,
        };

        if (!is_default_color) {
            const style = ansi.Style{ .foreground = fragment.color };
            try self.writer.print("{s}{s}{s}", .{ style, clean_text, ansi.Style.RESET });
        } else {
            try self.writer.print("{s}{s}{s}", .{ GUTTER_STYLE, clean_text, ansi.Style.RESET });
        }
    }

    try self.writer.writeByte('\n');

    // And now render line labels.

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
        if (selected_label) |label| {
            const label_start_line = try self.analyzed_source.getLineOnPosition(label.span.start);
            const label_end_line = try self.analyzed_source.getLineOnPosition(label.span.end);
            is_multiline = label_start_line != label_end_line;
        }

        try fragments.append(LineFragment{
            .text = fragment_text,
            .color = fragment_color,
            .local_span = fragment_span,
            .associated_label = selected_label,
            .is_multiline = is_multiline,
        });
    }
    return try fragments.toOwnedSlice();
}
