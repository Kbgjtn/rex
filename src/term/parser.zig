const std = @import("std");
const Action = @import("actions.zig").Action;
const Sgr = @import("actions.zig").Sgr;
const SgrOp = @import("actions.zig").SgrOp;
const Control = @import("actions.zig").Control;
const Utf8Dfa = @import("unicode.zig").Utf8Dfa;

// Definitions
// Many controls use parameters, shown in italics.  If a control uses a
// single parameter, only one parameter name is listed.  Some parameters
// (along with separating ;  characters) may be optional.  Other characters
// in the control are required.
//
// C    A single (required) character.
// Ps   A single (usually optional) numeric parameter, composed of one or
//      more digits.
// Pm   Any number of single numeric parameters, separated by ;
//      character(s).  Individual values for the parameters are listed with
//      Ps .
// Pt   A text parameter composed of printable characters.
//
// see details (3. Device Control functions)[https://invisible island.net/xterm/ctlseqs/ctlseqs.html#h3 Device Control functions].

const Transition = union(enum) {
    complete: Action,
    next,
    abort,
};

/// Packed separator token used by the parser.
/// Stored as a 2-bit value inside a `u64` bitfield.
/// Up to 32 separators can be packed into a single `u64`.
pub const Separator = enum(u2) {
    /// Final parameter in the sequence.
    end = 0,

    /// Continue parsing sub-parameters.
    colon = 1,

    /// Advance to the next parameter.
    semicolon = 2,
};

/// Number of bits required to store a single `Separator`.
const separator_bits = @bitSizeOf(Separator);

/// Bit mask for a single packed separator field.
///
/// Example for `u2`: `0b11`
const separator_mask = (1 << separator_bits) - 1;

/// Maximum number of separators that fit inside a `u64`.
/// With 2-bit separators this evaluates to 32.
const max_separators = @bitSizeOf(u64) / separator_bits;

/// Reads a packed `Separator` from `bits` at `idx`.
/// Each separator occupies `separator_bits` bits inside the packed `u64`.
///
/// Panics in Debug mode if `index >= max_separators`.
fn getSeparator(bits: u64, index: usize) Separator {
    std.debug.assert(index < max_separators);

    const shift: u6 = @truncate(index * separator_bits);
    return @enumFromInt(@as(u2, @truncate(bits >> @intCast(shift))));
}

/// Writes `value` into the packed separator bitfield at `idx`.
/// Existing bits at the target slot are cleared before the new value
/// is written.
///
/// Panics in Debug mode if `index >= max_separators`.
fn setSeparator(bits: *u64, index: usize, value: Separator) void {
    std.debug.assert(index < max_separators);

    const shift: u6 = @truncate(index * separator_bits);
    const mask: u64 = @as(u64, separator_mask) << shift;
    bits.* =
        (bits.* & ~mask) |
        (@as(u64, @intFromEnum(value)) << shift);
}

fn testRoundTrip(source: []const Separator) !void {
    var bits: u64 = 0;

    for (source, 0..) |sep, i| {
        setSeparator(&bits, i, sep);
    }

    for (source, 0..) |expected, i| {
        try std.testing.expectEqual(
            expected,
            getSeparator(bits, i),
        );
    }
}
test "separator" {
    try testRoundTrip(&[_]Separator{.end});
    try testRoundTrip(&[_]Separator{.colon});
    try testRoundTrip(&[_]Separator{.semicolon});
    try testRoundTrip(&[_]Separator{ .colon, .semicolon, .end });
}

test "separator: round trip" {
    try testRoundTrip(&[_]Separator{
        .colon,
        .semicolon,
        .end,
        .colon,
    });
}

test "separator: maximum capacity" {
    var bits: u64 = 0;

    for (0..32) |i| {
        setSeparator(&bits, i, .semicolon);
    }

    for (0..32) |i| {
        try std.testing.expectEqual(
            Separator.semicolon,
            getSeparator(bits, i),
        );
    }
}

test "separator: overwrite existing separator" {
    var bits: u64 = 0;

    setSeparator(&bits, 5, .colon);
    try std.testing.expectEqual(
        Separator.colon,
        getSeparator(bits, 5),
    );

    setSeparator(&bits, 5, .end);
    try std.testing.expectEqual(
        Separator.end,
        getSeparator(bits, 5),
    );
}

test "separator: first and last index" {
    var bits: u64 = 0;

    setSeparator(&bits, 0, .colon);
    setSeparator(&bits, 31, .semicolon);

    try std.testing.expectEqual(
        Separator.colon,
        getSeparator(bits, 0),
    );

    try std.testing.expectEqual(
        Separator.semicolon,
        getSeparator(bits, 31),
    );
}

test "separator: random round trip" {
    var prng = std.Random.DefaultPrng.init(0);
    const rand = prng.random();

    for (0..10_000) |_| {
        var bits: u64 = 0;
        var expected: [32]Separator = undefined;

        for (0..32) |i| {
            const sep: Separator = @enumFromInt(rand.intRangeLessThan(u2, 0, 3));

            expected[i] = sep;
            setSeparator(&bits, i, sep);
        }

        for (0..32) |i| {
            try std.testing.expectEqual(
                expected[i],
                getSeparator(bits, i),
            );
        }
    }
}
pub const Csi = struct {
    state: enum { params, intermediates },
    final: u8,
    current: u16 = no_param,
    private_marker: enum(u3) {
        none,
        lt,
        eq,
        gt,
        question,
    },

    param_count: u4 = 0,
    intermediate_count: u3 = 0,

    params: [max_params]u16 = [_]u16{no_param} ** max_params,
    intermediates: [max_intermediates]u8 = [_]u8{0} ** max_intermediates,

    const empty: Csi = .{
        .final = 0,
        .state = .params,
        .private_marker = .none,

        .param_count = 0,
        .intermediate_count = 0,
    };

    pub fn feed(self: *Csi, byte: u8) Transition {
        return switch (self.state) {
            .params => switch (byte) {
                '<', '=', '>', '?' => blk: {
                    self.private_marker = @enumFromInt(byte - 0x3B);
                    break :blk .next;
                },

                '0'...'9' => blk: {
                    const digit: u16 = byte - '0';

                    if (self.current == no_param) {
                        self.current = digit;
                    } else {
                        const temp: u32 = @as(u32, @intCast(self.current)) * 10 + @as(u32, @intCast(digit));
                        if (temp > 0xFFFF) {
                            self.current = no_param;
                            break :blk .abort;
                        }
                        self.current = @intCast(temp);
                    }

                    break :blk .next;
                },

                ';' => blk: {
                    self.pushParam();
                    break :blk .next;
                },

                ':' => blk: {
                    break :blk .next;
                },

                0x20...0x2F => blk: {
                    self.state = .intermediates;
                    self.pushIntermediate(byte);
                    break :blk .next;
                },

                0x40...0x7E => blk: {
                    self.finish(byte);
                    break :blk .complete;
                },

                else => .abort,
            },

            .intermediates => switch (byte) {
                0x20...0x2F => blk: {
                    self.pushIntermediate(byte);
                    break :blk .next;
                },
                0x40...0x7E => blk: {
                    self.finish(byte);
                    break :blk .complete;
                },
                else => .abort,
            },
        };
    }

    pub fn reset(self: *Csi) void {
        self.final = 0;
        self.state = .params;
        self.param_count = 0;
        self.current = no_param;
        self.private_marker = .none;
        self.intermediate_count = 0;
    }

    fn pushIntermediate(self: *Csi, byte: u8) void {
        if (self.intermediate_count < self.intermediates.len) {
            self.intermediates[self.intermediate_count] = byte;
            self.intermediate_count += 1;
        }
    }

    fn pushParam(self: *Csi) void {
        if (self.param_count < self.params.len) {
            // self.params[self.param_count] = if (self.current == no_param) 0 else self.current;
            self.params[self.param_count] = self.current;
            self.param_count += 1;

            self.current = no_param;
        }
    }

    fn finish(self: *Csi, byte: u8) void {
        self.final = byte;

        // store trailing parameter
        if (self.current != no_param or self.param_count > 0) {
            self.pushParam();
        }
    }

    pub fn param(self: *const Csi, idx: usize, default: u16) u16 {
        if (idx >= self.param_count) return default;
        const value = self.params[idx];
        return if (value == no_param) default else value;
    }

    pub fn intermediateBySpace(self: *const Csi) bool {
        return self.intermediate_count >= 1 and self.intermediates[0] == ' ';
    }

    pub fn dispatch(self: *const Csi) Action {
        return switch (self.final) {
            '@' => blk: {
                const ps = self.param(0, 1);
                // [CSI Ps SP @]
                // Shift left Ps columns(s) (default = 1) (SL), ECMA-48.
                if (self.intermediateBySpace()) {
                    break :blk .{ .shift = .{ .direction = .left, .n = ps } };
                }

                // CSI Ps @
                // Insert Ps (Blank) Character(s) (default = 1) (ICH).
                break :blk .{ .padding_character = ps };
            },

            'A' => blk: {
                const ps = self.param(0, 1);

                // CSI Ps SP A
                // Shift right Ps columns(s) (default = 1) (SR), ECMA-48.
                if (self.intermediateBySpace()) {
                    break :blk .{ .shift = .{ .direction = .right, .n = ps } };
                }

                // CSI Ps A
                // Cursor Up Ps Times (default = 1) (CUU).
                break :blk .{ .cursor_rel = .{ .direction = .up, .n = ps } };
            },

            'B' => .{ .cursor_rel = .{ .direction = .down, .n = self.param(0, 1) } },
            'C' => .{ .cursor_rel = .{ .direction = .right, .n = self.param(0, 1) } },
            'D' => .{ .cursor_rel = .{ .direction = .left, .n = self.param(0, 1) } },
            'E' => .{ .cursor_next_line = self.param(0, 1) },
            'F' => .{ .cursor_previous_line = self.param(0, 1) },
            'G' => .{ .cursor_horizontal_abs = self.param(0, 1) },
            'H', 'f' => .{ // CUP/HVP
                // CSI Ps I
                // Cursor Forward Tabulation Ps tab stops (default = 1) (CHT).
                .cursor_abs = .{ .row = self.param(0, 1), .col = self.param(1, 1) },
            },
            'J' => .{ .erase_display = @enumFromInt(self.param(0, 0)) },
            'K' => .{ .erase_line = @enumFromInt(self.param(0, 0)) },
            'R' => .{ .cursor_abs = .{ .row = self.param(0, 0), .col = self.param(0, 0) } },

            // CSI Ps S
            // Scroll up Ps lines (default = 1) (SU), VT420, ECMA-48.
            'S' => .{ .scroll_rel = .{ .direction = .up, .n = self.param(0, 1) } },

            // CSI Ps T
            //      Scroll down Ps lines (default = 1) (SD), VT420.
            // CSI Ps ^
            //      Scroll down Ps lines (default = 1) (SD), ECMA-48.
            'T', '^' => blk: {
                // DEC/xterm private mode
                if (self.private_marker == .gt) {
                    break :blk .{ .xtrmtitle_reset = self.params[0..self.param_count] };
                }

                // XTHIMOUSE
                // Parameters are [func;startx;starty;firstrow;lastrow].
                // See the section [Mouse Tracking](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h2-Mouse-Tracking).
                if (self.param_count >= 5) {
                    break :blk .{
                        .xthimouse = .{
                            .func = self.param(0, 0),
                            .start_x = self.param(1, 0),
                            .start_y = self.param(2, 0),
                            .fisrt_row = self.param(3, 0),
                            .last_row = self.param(4, 0),
                        },
                    };
                }

                break :blk .{ .scroll_rel = .{ .direction = .down, .n = self.param(0, 1) } };
            },

            'm' => .{ .sgr = Sgr.decode(self.params[0..self.param_count]) },
            // CSI 5i | AUX Port On | Enable aux serial port usually for local serial printer
            // CSI 4i | AUX Port Off | Disable aux serial port usually for local serial printer
            else => .{ .ignored = {} }, // ignored
        };
    }
};

test "CSI: default actions" {
    var csi: Csi = .empty;

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .padding_character = 1 },
            csi.finish(0x40), // PAD
        );
    }

    {
        defer csi = .empty;
        csi.pushIntermediate(' ');
        try std.testing.expectEqualDeep(
            Action{ .shift = .{ .direction = .left, .n = 1 } },
            csi.finish(0x40), // Shift left Ps
        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .cursor_rel = .{ .n = 1, .direction = .up } },
            csi.finish(0x41), // CUU
        );
    }

    {
        defer csi = .empty;
        csi.pushIntermediate(' ');
        try std.testing.expectEqualDeep(
            Action{ .shift = .{ .direction = .right, .n = 1 } },
            csi.finish(0x41), // Shift right Ps
        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .cursor_rel = .{ .n = 1, .direction = .down } },
            csi.finish(0x42), // CUD
        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .cursor_rel = .{ .n = 1, .direction = .right } },
            csi.finish(0x43), // CUF
        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .cursor_rel = .{ .n = 1, .direction = .left } },
            csi.finish(0x44), // CUB
        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .cursor_next_line = 1 },
            csi.finish(0x45), // CNL
        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .cursor_previous_line = 1 },
            csi.finish(0x46), // CPL
        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .cursor_horizontal_abs = 1 },
            csi.finish(0x47), // CHA

        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .erase_display = .to_end },
            csi.finish(0x4A), // ED
        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .erase_line = .to_end },
            csi.finish(0x4B), // EL
        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .scroll_rel = .{ .direction = .up, .n = 1 } },
            csi.finish(0x53), // SU
        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .scroll_rel = .{ .direction = .down, .n = 1 } },
            csi.finish(0x54), // SD ('T') not ansi.system
        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .scroll_rel = .{ .direction = .down, .n = 1 } },
            csi.finish(0x5E), // SD ('^') ECMA-48
        );
    }

    {
        defer csi = .empty;
        try std.testing.expectEqualDeep(
            Action{ .cursor_abs = .{ .row = 0, .col = 0 } },
            csi.finish(0x52), // CPR
        );
    }
}

test "CSI: sgr" {
    var csi: Csi = .empty;
    var sgr: Sgr = undefined;

    // reset
    {
        defer csi = .empty;
        csi.current = 0;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp.reset, sgr.ops[0]);
    }

    // bold
    {
        defer csi = .empty;
        csi.current = 1;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .bold = true }, sgr.ops[0]);
    }

    // !bold
    {
        defer csi = .empty;
        csi.current = 22;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .bold = false }, sgr.ops[0]);
    }

    // dim
    {
        defer csi = .empty;
        csi.current = 2;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .dim = true }, sgr.ops[0]);
    }

    // italic
    {
        defer csi = .empty;
        csi.current = 3;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .italic = true }, sgr.ops[0]);
    }

    // !italic
    {
        defer csi = .empty;
        csi.current = 23;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .italic = false }, sgr.ops[0]);
    }

    // underline
    {
        defer csi = .empty;
        csi.current = 4;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .underline = true }, sgr.ops[0]);
    }

    // !underline
    {
        defer csi = .empty;
        csi.current = 24;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .underline = false }, sgr.ops[0]);
    }

    // blink
    {
        defer csi = .empty;
        csi.current = 5;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .blink = true }, sgr.ops[0]);
    }

    // !blink
    {
        defer csi = .empty;
        csi.current = 25;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .blink = false }, sgr.ops[0]);
    }

    // reverse
    {
        defer csi = .empty;
        csi.current = 7;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .reverse = true }, sgr.ops[0]);
    }

    // !reverse
    {
        defer csi = .empty;
        csi.current = 27;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .reverse = false }, sgr.ops[0]);
    }

    // hidden
    {
        defer csi = .empty;
        csi.current = 8;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .hidden = true }, sgr.ops[0]);
    }

    // !hidden
    {
        defer csi = .empty;
        csi.current = 28;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .hidden = false }, sgr.ops[0]);
    }

    // strikethrough
    {
        defer csi = .empty;
        csi.current = 9;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .strikethrough = true }, sgr.ops[0]);
    }

    // !strikethrough
    {
        defer csi = .empty;
        csi.current = 29;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .strikethrough = false }, sgr.ops[0]);
    }

    // Default foreground color
    {
        defer csi = .empty;
        csi.current = 39;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .fg = .default }, sgr.ops[0]);
    }

    // Default background color
    {
        defer csi = .empty;
        csi.current = 49;
        sgr = csi.finish(0x6D).sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqual(SgrOp{ .bg = .default }, sgr.ops[0]);
    }

    // 4-bit Colors

    // fg solid
    for (30..37) |v| {
        const expected: u4 = @intCast(v - 30);
        {
            defer csi = .empty;
            csi.current = @intCast(v);
            sgr = csi.finish(0x6D).sgr;
            try std.testing.expectEqual(1, sgr.len);
            try std.testing.expectEqual(SgrOp{ .fg = .{ .ansi = expected } }, sgr.ops[0]);
        }
    }

    // fg bright
    for (90..97) |v| {
        const expected: u4 = @intCast(v - 90 + 8);
        {
            defer csi = .empty;
            csi.current = @intCast(v);
            sgr = csi.finish(0x6D).sgr;
            try std.testing.expectEqual(1, sgr.len);
            try std.testing.expectEqual(SgrOp{ .fg = .{ .ansi = expected } }, sgr.ops[0]);
        }
    }

    // bg solid
    for (40..47) |v| {
        const expected: u4 = @intCast(v - 40);
        {
            defer csi = .empty;
            csi.current = @intCast(v);
            sgr = csi.finish(0x6D).sgr;
            try std.testing.expectEqual(1, sgr.len);
            try std.testing.expectEqual(SgrOp{ .bg = .{ .ansi = expected } }, sgr.ops[0]);
        }
    }

    // bg bright
    for (100..107) |v| {
        const expected: u4 = @intCast(v - 100 + 8);
        {
            defer csi = .empty;
            csi.current = @intCast(v);
            sgr = csi.finish(0x6D).sgr;
            try std.testing.expectEqual(1, sgr.len);
            try std.testing.expectEqual(SgrOp{ .bg = .{ .ansi = expected } }, sgr.ops[0]);
        }
    }

    // 8-bits color

    // indexed foreground color
    {
        defer csi = .empty;
        csi.params[0] = 38;
        csi.params[1] = 5;
        csi.current = 123;
        csi.param_count = 2;

        sgr = csi.finish('m').sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqualDeep(
            SgrOp{ .fg = .{ .indexed = 123 } },
            sgr.ops[0],
        );
    }

    // indexed background color
    {
        defer csi = .empty;
        csi.params[0] = 48;
        csi.params[1] = 5;
        csi.current = 200;
        csi.param_count = 2;

        sgr = csi.finish('m').sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqualDeep(
            SgrOp{ .bg = .{ .indexed = 200 } },
            sgr.ops[0],
        );
    }

    // rgb foreground color
    {
        defer csi = .empty;
        csi.params[0] = 38;
        csi.params[1] = 2;
        csi.params[2] = 255;
        csi.params[3] = 255;
        csi.current = 255;
        csi.param_count = 4;

        sgr = csi.finish('m').sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqualDeep(
            SgrOp{ .fg = .{ .rgb = .{ .b = 255, .r = 255, .g = 255 } } },
            sgr.ops[0],
        );
    }

    // rgb background color
    {
        defer csi = .empty;
        csi.params[0] = 48;
        csi.params[1] = 2;
        csi.params[2] = 32;
        csi.params[3] = 32;
        csi.current = 32;
        csi.param_count = 4;

        sgr = csi.finish('m').sgr;
        try std.testing.expectEqual(1, sgr.len);
        try std.testing.expectEqualDeep(
            SgrOp{ .bg = .{ .rgb = .{ .b = 32, .r = 32, .g = 32 } } },
            sgr.ops[0],
        );
    }
}
