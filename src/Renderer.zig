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
    try self.renderSnippetContent();
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

// Render the whole content of the snippet. This should
// include all single- and multi-line labels, file content preview,
// and highlighting.
fn renderSnippetContent(self: *Self) !void {
    top: for (self.analyzed_source.lines, 0..) |source_line, line_idx| {
        // Check if line contains any single- or multi-line labels.
        for (self.diagnostic.labels) |label| {
            if ((label.span.start > source_line.byte_offset and label.span.start < source_line.byte_offset + source_line.byte_len) or (label.span.end > source_line.byte_offset and label.span.end < source_line.byte_offset + source_line.byte_len)) {
                // This line should be rendered.
                try self.renderCodeSnippetLineWithLabels(line_idx);
                continue :top;
            }
        }
    }
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
    const vchar = if (line_no == null) char_set.vbar_gap else char_set.vbar;
    try self.writer.print("{u} ", .{vchar});

    // And now repeat for every active multiline label.
    for (self.active_multiline_labels.items) |active_label_color| {
        const style = ansi.Style{ .foreground = active_label_color };
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
    const char_set = self.diagnostic.config.char_set;

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
        const mll_style = ansi.Style{ .foreground = mll_color };
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
            const style = ansi.Style{ .foreground = fragment.color };
            try self.writer.print("{s}{s}{s}", .{ style, clean_text, ansi.Style.RESET });
        } else {
            try self.writer.print("{s}{s}{s}", .{ GUTTER_STYLE, clean_text, ansi.Style.RESET });
        }
    }

    try self.writer.writeByte('\n');

    if (!no_inline_labels) {
        // And now render line labels.
        var remaining_labels = std.ArrayList(LineFragment).init(self.allocator);
        defer remaining_labels.deinit();

        try self.renderGutter(null);
        var current_position: usize = 0;
        for (fragments) |fragment| {
            if (fragment.is_multiline) continue;
            if (fragment.associated_label) |_| {
                try remaining_labels.append(fragment); // This should be sorted, so that we can pop.

                // Adjust position to span start.
                try self.writer.writeByteNTimes(' ', fragment.local_span.start - current_position);
                current_position = fragment.local_span.end;

                // Write underline.
                const style = ansi.Style{ .foreground = fragment.color };
                try self.writer.print("{s}", .{style});

                const span_len = fragment.local_span.len();
                for (0..span_len) |i| {
                    if (i == @divFloor(span_len, 2))
                        try self.writer.print("{u}", .{char_set.underbar})
                    else
                        try self.writer.print("{u}", .{char_set.underline});
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
                const label_center = label.local_span.start + @divFloor(label.local_span.len(), 2);
                try self.writer.writeByteNTimes(' ', label_center - current_position);
                current_position = label_center + 1;
                const style = ansi.Style{ .foreground = label.color };
                try self.writer.print("{s}{u}", .{ style, char_set.vbar });
            }

            const label_center = current_label.local_span.start + @divFloor(current_label.local_span.len(), 2);
            try self.writer.writeByteNTimes(' ', label_center - current_position);
            const style = ansi.Style{ .foreground = current_label.color };
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
        const mll_style = ansi.Style{ .foreground = multiline_label_color.? };
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
