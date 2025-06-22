const std = @import("std");

const ESC = "\x1B";
const CSI = ESC ++ "[";

pub const BasicColor = enum(u8) {
    // Standard ANSI colors 30-39 fg, 40-49 bg.
    black = 30,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    default = 39, // 38 is custom color, so we skip it.

    // Bright variants from aixterm spec. 90-97 fg, 100-107 bg.
    bright_black = 90,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,

    pub fn format(
        self: @This(),
        is_background: bool,
        writer: anytype,
    ) !void {
        const color_code: u8 = @intFromEnum(self) + if (is_background) @as(u8, 10) else @as(u8, 0);
        try writer.print("{s}{d}m", .{ CSI, color_code });
    }
};
pub const RgbColor = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn format(
        self: @This(),
        is_background: bool,
        writer: anytype,
    ) !void {
        const mode_code: u8 = if (is_background) 48 else 38;
        try writer.print("{s}{d};2;{d};{d};{d}m", .{ CSI, mode_code, self.r, self.g, self.b });
    }
};

pub const AnsiColor = union(enum) {
    basic: BasicColor,
    rgb: RgbColor,

    pub const DEFAULT: @This() = .{ .basic = .default };

    pub fn format(
        self: @This(),
        is_background: bool,
        writer: anytype,
    ) !void {
        switch (self) {
            // Just call .format on every variant.
            inline else => |variant| try variant.format(is_background, writer),
        }
    }
};

pub const ModifierKind = enum(u8) {
    reset,
    bold,
    faint,
    italic,
    underline,
    blinking,
    reverse = 7, // We skip 6.
    hidden,
    strikethrough,

    pub fn format(
        self: @This(),
        writer: anytype,
    ) !void {
        const modifier_code: u8 = @intFromEnum(self);
        try writer.print("{s}{d}m", .{ CSI, modifier_code });
    }
};

pub const Modifiers = packed struct {
    reset: bool = false,
    bold: bool = false,
    faint: bool = false,
    italic: bool = false,
    underline: bool = false,
    blinking: bool = false,
    reverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,

    pub fn format(
        self: @This(),
        writer: anytype,
    ) !void {
        // Apply all modifiers that are marked true.
        inline for (@typeInfo(@This()).@"struct".fields) |field| {
            if (@field(self, field.name))
                try @field(ModifierKind, field.name).format(writer);
        }
    }
};

pub const Style = struct {
    foreground: AnsiColor = .DEFAULT,
    background: AnsiColor = .DEFAULT,
    modifiers: Modifiers = .{},
    enabled: bool = true,

    pub const RESET: @This() = .{ .modifiers = .{ .reset = true } };

    // Format function compatible with builtin zig formatters.
    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        if (!self.enabled) return; // This is a hack, but it makes life a lot easier to put it here.

        try self.modifiers.format(writer);
        try self.foreground.format(false, writer);
        try self.background.format(true, writer);
    }
};

test "BasicColor format foreground and background" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const writer = buf.writer();

    try BasicColor.red.format(false, writer);
    try std.testing.expectEqualStrings("\x1B[31m", buf.items);
    buf.clearRetainingCapacity();

    try BasicColor.blue.format(true, writer);
    try std.testing.expectEqualStrings("\x1B[44m", buf.items);
}

test "RgbColor format foreground and background" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const writer = buf.writer();

    const rgb = RgbColor{ .r = 255, .g = 128, .b = 0 };
    try rgb.format(false, writer);
    try std.testing.expectEqualStrings("\x1B[38;2;255;128;0m", buf.items);
    buf.clearRetainingCapacity();

    try rgb.format(true, writer);
    try std.testing.expectEqualStrings("\x1B[48;2;255;128;0m", buf.items);
}

test "AnsiColor format basic and rgb" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const writer = buf.writer();

    const color1 = AnsiColor{ .basic = .green };
    try color1.format(false, writer);
    try std.testing.expectEqualStrings("\x1B[32m", buf.items);
    buf.clearRetainingCapacity();

    const color2 = AnsiColor{ .rgb = .{ .r = 10, .g = 20, .b = 30 } };
    try color2.format(true, writer);
    try std.testing.expectEqualStrings("\x1B[48;2;10;20;30m", buf.items);
}

test "ModifierKind format individual" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const writer = buf.writer();

    try ModifierKind.bold.format(writer);
    try std.testing.expectEqualStrings("\x1B[1m", buf.items);
}

test "Modifiers formats multiple flags" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const writer = buf.writer();

    const mods = Modifiers{
        .bold = true,
        .underline = true,
        .italic = true,
    };
    try mods.format(writer);
    try std.testing.expectEqualStrings("\x1B[1m\x1B[3m\x1B[4m", buf.items);
}

test "Style formats modifiers, foreground and background" {
    const style = Style{
        .foreground = .{ .basic = .cyan },
        .background = .{ .rgb = .{ .r = 0, .g = 0, .b = 0 } },
        .modifiers = .{ .bold = true, .reverse = true },
    };
    const buf = try std.fmt.allocPrint(std.testing.allocator, "{s}", .{style});
    defer std.testing.allocator.free(buf);
    try std.testing.expectEqualStrings(
        "\x1B[1m\x1B[7m\x1B[36m\x1B[48;2;0;0;0m",
        buf,
    );
}
