const std = @import("std");
const Action = @import("actions.zig").Action;
const Sgr = @import("actions.zig").Sgr;
const SgrOp = @import("actions.zig").SgrOp;
const Control = @import("actions.zig").Control;
const Utf8Dfa = @import("unicode.zig").Utf8Dfa;

pub const Csi = struct {
    params: [16]u16 = [_]u16{0} ** 16,
    intermediates: [4]u8 = [_]u8{0} ** 4,

    param_count: u4 = 0,
    intermediate_count: u3 = 0,

    current: u16,
    final: u8,

    const NO_PARAM = 0xffff;
    const NO_INTERMEDIATE = 0xff;

    const empty: Csi = .{
        .final = 0,
        .current = NO_PARAM,

        .param_count = 0,
        .intermediate_count = 0,

        .params = [_]u16{NO_PARAM} ** 16,
        .intermediates = [_]u8{NO_INTERMEDIATE} ** 4,
    };

    pub fn reset(self: *Csi) void {
        self.final = 0;
        self.current = NO_PARAM;
        self.param_count = 0;
        self.intermediate_count = 0;
    }

    pub fn pushParam(self: *Csi) void {
        if (self.param_count < self.params.len) {
            self.params[self.param_count] = if (self.current == NO_PARAM) 0 else self.current;
            self.param_count += 1;
            self.current = NO_PARAM;
        }
    }

    pub fn finish(self: *Csi, final: u8) Action {
        self.final = final;

        // store trailing parameter
        if (self.current != NO_PARAM or self.param_count > 0) {
            self.pushParam();
        }

        return self.action();
    }

    pub fn param(self: *const Csi, idx: usize, default: u16) u16 {
        if (idx >= self.param_count) return default;
        return self.params[idx];
    }

    pub fn action(self: *const Csi) Action {
        return switch (self.final) {
            'A' => .{ .cursor_rel = .{ .direction = .up, .n = self.param(0, 1) } },
            'B' => .{ .cursor_rel = .{ .direction = .down, .n = self.param(0, 1) } },
            'C' => .{ .cursor_rel = .{ .direction = .right, .n = self.param(0, 1) } },
            'D' => .{ .cursor_rel = .{ .direction = .left, .n = self.param(0, 1) } },
            'E' => .{ .cursor_next_line = self.param(0, 1) },
            'F' => .{ .cursor_previous_line = self.param(0, 1) },
            'G' => .{ .cursor_horizontal_abs = self.param(0, 1) },
            'H', 'f' => .{ // CUP/HVP
                .cursor_abs = .{ .row = self.param(0, 1), .col = self.param(1, 1) },
            },
            'J' => .{ .erase_display = @enumFromInt(self.param(0, 0)) },
            'K' => .{ .erase_line = @enumFromInt(self.param(0, 0)) },
            'R' => .{ .cursor_abs = .{ .row = self.param(0, 0), .col = self.param(0, 0) } },
            'S' => .{ .scroll_rel = .{ .direction = .up, .n = self.param(0, 1) } },
            'T' => .{ .scroll_rel = .{ .direction = .down, .n = self.param(0, 1) } },
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
            Action{ .cursor_rel = .{ .n = 1, .direction = .up } },
            csi.finish(0x41), // CUU
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
            csi.finish(0x54), // SD
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
