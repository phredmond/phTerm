// terminal.zig — raw mode setup, terminal size, CRT theme constants
const std = @import("std");

const c = @cImport({
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
    @cInclude("unistd.h");
});

var orig_termios: c.struct_termios = undefined;
var raw_active: bool = false;

pub const Size = struct { cols: u16, rows: u16 };

pub fn enableRawMode() !void {
    if (c.tcgetattr(c.STDIN_FILENO, &orig_termios) != 0)
        return error.TcgetattrFailed;

    var raw = orig_termios;
    raw.c_iflag &= ~@as(c_uint, c.BRKINT | c.ICRNL | c.INPCK | c.ISTRIP | c.IXON);
    raw.c_oflag &= ~@as(c_uint, c.OPOST);
    raw.c_cflag |= @as(c_uint, c.CS8);
    raw.c_lflag &= ~@as(c_uint, c.ECHO | c.ICANON | c.IEXTEN | c.ISIG);
    raw.c_cc[c.VMIN] = 0;
    raw.c_cc[c.VTIME] = 1; // 100 ms timeout

    if (c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &raw) != 0)
        return error.TcsetattrFailed;
    raw_active = true;
}

pub fn disableRawMode() void {
    if (raw_active) {
        _ = c.tcsetattr(c.STDIN_FILENO, c.TCSAFLUSH, &orig_termios);
        raw_active = false;
    }
}

pub fn getSize() !Size {
    var ws: c.struct_winsize = undefined;
    if (c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &ws) != 0)
        return error.IoctlFailed;
    return .{ .cols = ws.ws_col, .rows = ws.ws_row };
}

pub fn writeAll(data: []const u8) void {
    _ = std.posix.write(std.posix.STDOUT_FILENO, data) catch {};
}

pub fn hideCursor() void { writeAll("\x1b[?25l"); }
pub fn showCursor() void { writeAll("\x1b[?25h"); }
pub fn clearScreen() void { writeAll("\x1b[2J\x1b[H"); }

// ── CRT phosphor green theme ──────────────────────────────────────────────────
pub const CRT = struct {
    // Text styles
    pub const reset    = "\x1b[0m";
    pub const normal   = "\x1b[0;32m";   // normal green
    pub const bright   = "\x1b[1;32m";   // bright/bold green  (active border, labels)
    pub const dim      = "\x1b[2;32m";   // dim green          (inactive border)
    pub const blink    = "\x1b[5;32m";   // blinking green     (alerts)

    // Box drawing — single line (inactive panels)
    pub const hl  = "─";
    pub const vl  = "│";
    pub const tl  = "┌";
    pub const tr  = "┐";
    pub const bl  = "└";
    pub const br  = "┘";
    pub const ts  = "┬";
    pub const bs  = "┴";
    pub const ls  = "├";
    pub const rs  = "┤";
    pub const cr  = "┼";

    // Box drawing — double line (active panel)
    pub const hl2 = "═";
    pub const vl2 = "║";
    pub const tl2 = "╔";
    pub const tr2 = "╗";
    pub const bl2 = "╚";
    pub const br2 = "╝";

    // Status bar
    pub const bar_bg   = "\x1b[42;30m"; // green bg, black text
    pub const bar_key  = "\x1b[1;42;30m"; // bold black on green
};
