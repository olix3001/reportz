const ansi = @import("ansi.zig");

pub const Severity = enum {
    @"error",
    warning,
    advice,

    pub fn color(self: Severity) ansi.AnsiColor {
        return switch (self) {
            .@"error" => .{ .basic = .bright_red },
            .warning => .{ .basic = .yellow },
            .advice => .{ .basic = .bright_green },
        };
    }
};

pub const Span = struct {
    start: usize,
    end: usize,

    pub const empty: @This() = .{ .start = 0, .end = 0 };

    pub inline fn len(self: @This()) usize {
        return self.end - self.start;
    }

    pub fn offset_by(self: @This(), offset: usize) @This() {
        return .{ .start = self.start - offset, .end = self.end - offset };
    }
};
pub const Locus = struct { line: usize, position: usize };

pub const Diagnostic = struct {
    // ID of the source this diagnostic refers to. This will be
    // used to render file contents based on `cache.SourceCache` information.
    source_id: []const u8,
    // Severity of the diagnostic, error being the highest and advice being the lowest.
    severity: Severity,
    // Diagnostic code. This can be used to easily identify error in the
    // documentation of the language. It is optional.
    code: ?[]const u8,
    // Message about an error. This should be descriptive about why
    // the error occured.
    message: []const u8,
    // Labels (code span + message) associated with this diagnostic.
    labels: []const Label = &.{},
    // Additional info, like description or help message for the diagnostic.
    notes: []const Note = &.{},
};

pub const Label = struct {
    // Span to which given label should be attached.
    span: Span,
    // Message associated with this label.
    message: []const u8,
    // Color of the label. This will affect given span and the message itself.
    color: ansi.AnsiColor,
};

pub const Note = struct {
    // Color that this category label should be rendered with.
    category_color: ansi.AnsiColor = .{ .basic = .bright_green },
    // Category of the note, that is `help` in
    // help: Please use this feature instead.
    category: []const u8 = "help",
    // Message of the note.
    message: []const u8,
};

pub const LineFragment = struct {
    // The text content of this fragment
    text: []const u8,
    // Optional label associated with this fragment
    label: ?*const Label,
    // Whether this fragment is part of a labeled span
    is_labeled: bool,
};
