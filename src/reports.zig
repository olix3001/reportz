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

    pub fn len(self: @This()) usize {
        return self.end - self.start;
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
    // Diagnostic configuration. This tells the printer how to format the final report.
    config: Config = .{},

    pub const Config = struct {
        colors: bool = true,
        underlines: bool = true,
        compact: bool = false,
        tab_width: u8 = 4,
        char_set: CharSet = .ROUNDED,
    };
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
    // Category of the note, that is `help` in
    // help: Please use this feature instead.
    category: []const u8,
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

// Character Set for arrows and other pretty stuff in the diagnostic report.
// Every character is u21, which is unicode codepoint for a character.
pub const CharSet = struct {
    hbar: u21,
    vbar: u21,
    xbar: u21,
    vbar_break: u21,
    vbar_gap: u21,
    uarrow: u21,
    rarrow: u21,
    ltop: u21,
    mtop: u21,
    rtop: u21,
    lbot: u21,
    rbot: u21,
    mbot: u21,
    lbox: u21,
    rbox: u21,
    lcross: u21,
    rcross: u21,
    underbar: u21,
    underline: u21,

    pub const ROUNDED: @This() = .{
        .hbar = '─',
        .vbar = '│',
        .xbar = '┼',
        .vbar_break = '┆',
        .vbar_gap = '┆',
        .uarrow = '▲',
        .rarrow = '▶',
        .ltop = '╭',
        .mtop = '┬',
        .rtop = '╮',
        .lbot = '╰',
        .mbot = '┴',
        .rbot = '╯',
        .lbox = '[',
        .rbox = ']',
        .lcross = '├',
        .rcross = '┤',
        .underbar = '┬',
        .underline = '─',
    };

    pub const ASCII: @This() = .{
        .hbar = '-',
        .vbar = '|',
        .xbar = '+',
        .vbar_break = '*',
        .vbar_gap = ':',
        .uarrow = '^',
        .rarrow = '>',
        .ltop = ',',
        .mtop = 'v',
        .rtop = '.',
        .lbot = '`',
        .mbot = '^',
        .rbot = '\'',
        .lbox = '[',
        .rbox = ']',
        .lcross = '|',
        .rcross = '|',
        .underbar = '|',
        .underline = '^',
    };
};
