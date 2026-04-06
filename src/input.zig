// input.zig — key sequence detection and command mapping
const std = @import("std");

pub const KeyKind = enum {
    char,       // regular printable / control character — send to panel
    f1,         // toggle help
    f2,         // split vertical (side by side)
    f3,         // split horizontal (stacked)
    f4,         // close panel
    f5,         // force redraw
    f6,         // next panel
    f7,         // prev panel
    f8,         // new shell in active panel
    f9,         // (reserved / menu)
    f10,        // quit
    tab,        // next panel (same as F6)
    shift_tab,  // prev panel (same as F7)
    ctrl_left,  // resize panel: shrink width
    ctrl_right, // resize panel: grow width
    ctrl_up,    // resize panel: shrink height
    ctrl_down,  // resize panel: grow height
    unknown,    // unrecognised escape — discard
};

pub const Key = struct {
    kind:  KeyKind,
    // raw bytes (when kind == .char, forwarded verbatim to the active panel)
    data:  [16]u8 = undefined,
    len:   usize  = 0,
};

pub fn parse(raw: []const u8) Key {
    if (raw.len == 0) return .{ .kind = .unknown };

    // ── Function keys (xterm / vt220 sequences) ──────────────────────────────
    if (std.mem.eql(u8, raw, "\x1b[11~") or std.mem.eql(u8, raw, "\x1bOP"))
        return .{ .kind = .f1 };
    if (std.mem.eql(u8, raw, "\x1b[12~") or std.mem.eql(u8, raw, "\x1bOQ"))
        return .{ .kind = .f2 };
    if (std.mem.eql(u8, raw, "\x1b[13~") or std.mem.eql(u8, raw, "\x1bOR"))
        return .{ .kind = .f3 };
    if (std.mem.eql(u8, raw, "\x1b[14~") or std.mem.eql(u8, raw, "\x1bOS"))
        return .{ .kind = .f4 };
    if (std.mem.eql(u8, raw, "\x1b[15~"))
        return .{ .kind = .f5 };
    if (std.mem.eql(u8, raw, "\x1b[17~"))
        return .{ .kind = .f6 };
    if (std.mem.eql(u8, raw, "\x1b[18~"))
        return .{ .kind = .f7 };
    if (std.mem.eql(u8, raw, "\x1b[19~"))
        return .{ .kind = .f8 };
    if (std.mem.eql(u8, raw, "\x1b[20~"))
        return .{ .kind = .f9 };
    if (std.mem.eql(u8, raw, "\x1b[21~"))
        return .{ .kind = .f10 };

    // macOS Terminal.app / iTerm2 sometimes send these for F1-F4:
    if (std.mem.eql(u8, raw, "\x1bO P")) return .{ .kind = .f1 };
    if (std.mem.eql(u8, raw, "\x1bO Q")) return .{ .kind = .f2 };
    if (std.mem.eql(u8, raw, "\x1bO R")) return .{ .kind = .f3 };
    if (std.mem.eql(u8, raw, "\x1bO S")) return .{ .kind = .f4 };

    // ── Tab / Shift-Tab ───────────────────────────────────────────────────────
    if (raw.len == 1 and raw[0] == 0x09)
        return .{ .kind = .tab };
    if (std.mem.eql(u8, raw, "\x1b[Z"))
        return .{ .kind = .shift_tab };

    // ── Ctrl+Arrow (resize) ───────────────────────────────────────────────────
    // xterm sends ESC[1;5A/B/C/D for Ctrl+Arrow
    if (std.mem.eql(u8, raw, "\x1b[1;5D")) return .{ .kind = .ctrl_left  };
    if (std.mem.eql(u8, raw, "\x1b[1;5C")) return .{ .kind = .ctrl_right };
    if (std.mem.eql(u8, raw, "\x1b[1;5A")) return .{ .kind = .ctrl_up    };
    if (std.mem.eql(u8, raw, "\x1b[1;5B")) return .{ .kind = .ctrl_down  };

    // ── Unknown pure-escape sequences ─────────────────────────────────────────
    if (raw.len > 1 and raw[0] == 0x1B) {
        return .{ .kind = .unknown };
    }

    // ── Regular character / control sequence — pass through ───────────────────
    var k = Key{ .kind = .char };
    const n = @min(raw.len, k.data.len);
    @memcpy(k.data[0..n], raw[0..n]);
    k.len = n;
    return k;
}

// ── Read a key from stdin (non-blocking, called after poll) ──────────────────

pub fn readKey(buf: []u8) !usize {
    // Read up to 16 bytes (escape sequences can be up to ~8 bytes)
    const n = std.posix.read(std.posix.STDIN_FILENO, buf) catch return 0;
    return n;
}
