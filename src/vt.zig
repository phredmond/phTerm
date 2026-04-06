// vt.zig — VT100/xterm emulation: cell buffer + escape sequence parser
//
// Handles the sequences that real shells (bash/zsh) and programs
// (vim, less, nano, htop) actually emit.
const std = @import("std");

// ── Cell ─────────────────────────────────────────────────────────────────────

pub const MAX_COLS: u16 = 512;
pub const MAX_ROWS: u16 = 256;

/// Color: 0–7 standard, 8–15 bright, 256 = default fg/bg
pub const DEFAULT_FG: u16 = 256;
pub const DEFAULT_BG: u16 = 257;

pub const Cell = struct {
    ch:        u21  = ' ',
    fg:        u16  = DEFAULT_FG,
    bg:        u16  = DEFAULT_BG,
    bold:      bool = false,
    dim:       bool = false,
    italic:    bool = false,
    underline: bool = false,
    blink:     bool = false,
    reverse:   bool = false,
};

/// Cursor attributes in use when writing cells
pub const Pen = struct {
    fg:        u16  = DEFAULT_FG,
    bg:        u16  = DEFAULT_BG,
    bold:      bool = false,
    dim:       bool = false,
    italic:    bool = false,
    underline: bool = false,
    blink:     bool = false,
    reverse:   bool = false,

    pub fn toCell(p: Pen, ch: u21) Cell {
        return .{
            .ch = ch, .fg = p.fg, .bg = p.bg,
            .bold = p.bold, .dim = p.dim, .italic = p.italic,
            .underline = p.underline, .blink = p.blink, .reverse = p.reverse,
        };
    }

    pub fn reset(p: *Pen) void {
        p.* = .{};
    }
};

// ── Scrollback ────────────────────────────────────────────────────────────────

pub const SCROLLBACK_LINES: u16 = 500;

// ── Screen buffer ─────────────────────────────────────────────────────────────

pub const Screen = struct {
    cells:      [MAX_ROWS][MAX_COLS]Cell = undefined,
    cols:       u16 = 80,
    rows:       u16 = 24,
    cx:         u16 = 0,  // cursor column (0-based)
    cy:         u16 = 0,  // cursor row    (0-based)
    scroll_top: u16 = 0,  // top of scroll region (0-based)
    scroll_bot: u16 = 23, // bottom of scroll region (0-based, inclusive)
    pen:        Pen = .{},
    saved_cx:   u16 = 0,
    saved_cy:   u16 = 0,
    saved_pen:  Pen = .{},
    dirty:      bool = true,
    // ── Scrollback (enabled on main screen only) ──────────────────────────────
    sb:          [SCROLLBACK_LINES][MAX_COLS]Cell = undefined,
    sb_head:     u16 = 0,   // next write slot (ring buffer)
    sb_count:    u16 = 0,   // lines stored (0..SCROLLBACK_LINES)
    sb_enabled:  bool = false,
    scroll_offset: u16 = 0, // lines scrolled back from live view (0 = live)

    pub fn init(s: *Screen, cols: u16, rows: u16) void {
        s.cols = cols;
        s.rows = rows;
        s.scroll_top = 0;
        s.scroll_bot = rows -| 1;
        s.cx = 0;
        s.cy = 0;
        s.dirty = true;
        s.clearAll();
    }

    /// Adjust the view offset. Positive = scroll back (older), negative = scroll forward (newer).
    pub fn scrollView(s: *Screen, delta: i32) void {
        if (delta > 0) {
            const d: u16 = @intCast(@min(delta, @as(i32, std.math.maxInt(u16))));
            s.scroll_offset = @min(s.scroll_offset + d, s.sb_count);
        } else if (delta < 0) {
            const d: u16 = @intCast(@min(-delta, @as(i32, std.math.maxInt(u16))));
            s.scroll_offset = s.scroll_offset -| d;
        }
        s.dirty = true;
    }

    /// Return a pointer to the cell row to display for a given visual row,
    /// accounting for scroll_offset and the scrollback ring buffer.
    pub fn getDisplayRow(s: *const Screen, visual_row: u16) *const [MAX_COLS]Cell {
        if (s.scroll_offset == 0) {
            return &s.cells[@min(visual_row, s.rows -| 1)];
        }
        if (visual_row >= s.scroll_offset) {
            const live_row = visual_row - s.scroll_offset;
            return &s.cells[@min(live_row, s.rows -| 1)];
        }
        // In scrollback: index from oldest (0) to newest (sb_count-1)
        // visual_row=0 when scroll_offset=sb_count → sb index 0 (oldest)
        const sb_idx: u32 = @as(u32, s.sb_count) + @as(u32, visual_row) - @as(u32, s.scroll_offset);
        const ring: u32 = (@as(u32, s.sb_head) + SCROLLBACK_LINES - @as(u32, s.sb_count) + sb_idx) % SCROLLBACK_LINES;
        return &s.sb[ring];
    }

    pub fn resize(s: *Screen, cols: u16, rows: u16) void {
        s.cols = cols;
        s.rows = rows;
        if (s.scroll_bot >= rows) s.scroll_bot = rows -| 1;
        if (s.cy >= rows) s.cy = rows -| 1;
        if (s.cx >= cols) s.cx = cols -| 1;
        s.dirty = true;
    }

    fn blank(s: *Screen) Cell { return s.pen.toCell(' '); }

    pub fn clearAll(s: *Screen) void {
        const bl = s.blank();
        for (0..s.rows) |r| for (0..s.cols) |cc| { s.cells[r][cc] = bl; };
    }

    fn clearLine(s: *Screen, row: u16) void {
        const bl = s.blank();
        for (0..s.cols) |cc| s.cells[row][cc] = bl;
    }

    /// Scroll the scroll region up by n lines (text moves up, blank appears at bottom).
    fn scrollUp(s: *Screen, n: u16) void {
        var i: u16 = 0;
        while (i < n) : (i += 1) {
            var r = s.scroll_top;
            while (r < s.scroll_bot) : (r += 1) {
                s.cells[r] = s.cells[r + 1];
            }
            s.clearLine(s.scroll_bot);
        }
        s.dirty = true;
    }

    /// Scroll the scroll region down by n lines (text moves down, blank at top).
    fn scrollDown(s: *Screen, n: u16) void {
        var i: u16 = 0;
        while (i < n) : (i += 1) {
            var r = s.scroll_bot;
            while (r > s.scroll_top) : (r -= 1) {
                s.cells[r] = s.cells[r - 1];
            }
            s.clearLine(s.scroll_top);
        }
        s.dirty = true;
    }

    /// Write a character at cursor, advance.
    pub fn putChar(s: *Screen, ch: u21) void {
        if (s.cx >= s.cols) {
            // Wrap
            s.cx = 0;
            s.newline();
        }
        if (s.cy < s.rows) {
            s.cells[s.cy][s.cx] = s.pen.toCell(ch);
        }
        s.cx += 1;
        s.dirty = true;
    }

    pub fn newline(s: *Screen) void {
        if (s.cy == s.scroll_bot) {
            s.scrollUp(1);
        } else if (s.cy + 1 < s.rows) {
            s.cy += 1;
        }
    }
};

// ── Parser state ──────────────────────────────────────────────────────────────

const ParserState = enum {
    normal,
    escape,
    csi,
    csi_priv, // ESC [ ?
    osc,
    dcs,
};

const MAX_PARAMS = 16;
const MAX_OSC    = 256;

pub const VtParser = struct {
    screen:      Screen        = .{},
    alt:         Screen        = .{},   // alternate screen (vim, less)
    on_alt:      bool          = false,
    state:       ParserState   = .normal,
    params:      [MAX_PARAMS]u16 = [_]u16{0} ** MAX_PARAMS,
    param_count: u8            = 0,
    inter:       u8            = 0,    // single intermediate byte
    osc_buf:     [MAX_OSC]u8   = undefined,
    osc_len:     usize         = 0,
    utf8_remain: u3            = 0,    // continuation bytes still expected
    utf8_accum:  u21           = 0,    // codepoint being assembled

    pub fn init(vt: *VtParser, cols: u16, rows: u16) void {
        vt.screen.init(cols, rows);
        vt.alt.init(cols, rows);
        vt.state = .normal;
        vt.param_count = 0;
        vt.utf8_remain = 0;
        vt.utf8_accum  = 0;
    }

    pub fn resize(vt: *VtParser, cols: u16, rows: u16) void {
        vt.screen.resize(cols, rows);
        vt.alt.resize(cols, rows);
    }

    pub fn cur(vt: *VtParser) *Screen {
        return if (vt.on_alt) &vt.alt else &vt.screen;
    }

    pub fn feed(vt: *VtParser, data: []const u8) void {
        for (data) |byte| vt.feedByte(byte);
    }

    fn feedByte(vt: *VtParser, b: u8) void {
        const s = vt.cur();
        switch (vt.state) {
            .normal => switch (b) {
                0x07 => {}, // BEL — ignore
                0x08 => { // BS
                    if (s.cx > 0) s.cx -= 1;
                },
                0x09 => { // HT — tab
                    const next = (s.cx | 7) + 1;
                    s.cx = @min(next, s.cols -| 1);
                },
                0x0A, 0x0B, 0x0C => { // LF / VT / FF
                    s.newline();
                },
                0x0D => { // CR
                    s.cx = 0;
                },
                0x1B => {
                    vt.utf8_remain = 0; // abort any in-progress UTF-8 sequence
                    vt.state = .escape;
                },
                0x20...0x7E => { // printable ASCII
                    vt.utf8_remain = 0;
                    s.putChar(b);
                },
                0x80...0xBF => { // UTF-8 continuation byte
                    if (vt.utf8_remain > 0) {
                        vt.utf8_accum = (vt.utf8_accum << 6) | @as(u21, b & 0x3F);
                        vt.utf8_remain -= 1;
                        if (vt.utf8_remain == 0) s.putChar(vt.utf8_accum);
                    }
                    // stray continuation byte — ignore
                },
                0xC0...0xDF => { // 2-byte lead
                    vt.utf8_accum  = @as(u21, b & 0x1F);
                    vt.utf8_remain = 1;
                },
                0xE0...0xEF => { // 3-byte lead
                    vt.utf8_accum  = @as(u21, b & 0x0F);
                    vt.utf8_remain = 2;
                },
                0xF0...0xF7 => { // 4-byte lead
                    vt.utf8_accum  = @as(u21, b & 0x07);
                    vt.utf8_remain = 3;
                },
                else => {},
            },

            .escape => switch (b) {
                '[' => {
                    vt.state = .csi;
                    vt.param_count = 0;
                    @memset(&vt.params, 0);
                    vt.inter = 0;
                },
                ']' => {
                    vt.state = .osc;
                    vt.osc_len = 0;
                },
                'P' => { vt.state = .dcs; },
                'D' => { s.newline(); vt.state = .normal; },       // IND
                'E' => { s.cx = 0; s.newline(); vt.state = .normal; }, // NEL
                'M' => { // RI — reverse index (scroll down)
                    if (s.cy == s.scroll_top) s.scrollDown(1)
                    else if (s.cy > 0) s.cy -= 1;
                    vt.state = .normal;
                },
                '7' => { // DECSC save cursor
                    s.saved_cx = s.cx; s.saved_cy = s.cy;
                    s.saved_pen = s.pen;
                    vt.state = .normal;
                },
                '8' => { // DECRC restore cursor
                    s.cx = s.saved_cx; s.cy = s.saved_cy;
                    s.pen = s.saved_pen;
                    vt.state = .normal;
                },
                'c' => { // RIS — full reset
                    s.init(s.cols, s.rows);
                    vt.state = .normal;
                },
                else => { vt.state = .normal; },
            },

            .csi => {
                if (b == '?' or b == '>' or b == '<' or b == '=') {
                    // Private/gt parameter marker — route through csi_priv so the
                    // full sequence (params + final byte) gets consumed rather than
                    // treating the marker itself as a final byte.
                    vt.state = .csi_priv;
                } else if (b >= '0' and b <= '9') {
                    if (vt.param_count == 0) vt.param_count = 1;
                    const idx = vt.param_count - 1;
                    vt.params[idx] = vt.params[idx] *% 10 +% (b - '0');
                } else if (b == ';') {
                    if (vt.param_count < MAX_PARAMS) vt.param_count += 1;
                } else if (b >= 0x20 and b <= 0x2F) {
                    vt.inter = b; // intermediate
                } else {
                    // Final byte — dispatch
                    vt.dispatchCSI(b);
                    vt.state = .normal;
                }
            },

            .csi_priv => {
                if (b >= '0' and b <= '9') {
                    if (vt.param_count == 0) vt.param_count = 1;
                    const idx = vt.param_count - 1;
                    vt.params[idx] = vt.params[idx] *% 10 +% (b - '0');
                } else if (b == ';') {
                    if (vt.param_count < MAX_PARAMS) vt.param_count += 1;
                } else {
                    vt.dispatchDECPriv(b);
                    vt.state = .normal;
                }
            },

            .osc => {
                if (b == 0x07 or b == 0x9C) {
                    // OSC string done — we ignore (title changes etc.)
                    vt.state = .normal;
                } else if (b == 0x1B) {
                    vt.state = .escape; // might be ESC \ (ST)
                } else {
                    if (vt.osc_len < MAX_OSC) {
                        vt.osc_buf[vt.osc_len] = b;
                        vt.osc_len += 1;
                    }
                }
            },

            .dcs => {
                if (b == 0x1B) vt.state = .escape;
            },
        }
    }

    fn p(vt: *VtParser, idx: u8, default: u16) u16 {
        if (idx >= vt.param_count) return default;
        return if (vt.params[idx] == 0) default else vt.params[idx];
    }

    fn dispatchCSI(vt: *VtParser, final: u8) void {
        const s = vt.cur();
        switch (final) {
            'A' => { // CUU cursor up
                const n = vt.p(0, 1);
                s.cy -|= n;
                if (s.cy < s.scroll_top) s.cy = s.scroll_top;
            },
            'B' => { // CUD cursor down
                const n = vt.p(0, 1);
                s.cy = @min(s.cy + n, s.rows -| 1);
            },
            'C' => { // CUF cursor right
                const n = vt.p(0, 1);
                s.cx = @min(s.cx + n, s.cols -| 1);
            },
            'D' => { // CUB cursor left
                const n = vt.p(0, 1);
                s.cx -|= n;
            },
            'E' => { // CNL cursor next line
                const n = vt.p(0, 1);
                s.cy = @min(s.cy + n, s.rows -| 1);
                s.cx = 0;
            },
            'F' => { // CPL cursor prev line
                const n = vt.p(0, 1);
                s.cy -|= n;
                s.cx = 0;
            },
            'G' => { // CHA cursor horizontal absolute
                s.cx = @min(vt.p(0, 1) -| 1, s.cols -| 1);
            },
            'H', 'f' => { // CUP / HVP cursor position
                s.cy = @min(vt.p(0, 1) -| 1, s.rows -| 1);
                s.cx = @min(vt.p(1, 1) -| 1, s.cols -| 1);
            },
            'J' => { // ED erase in display
                switch (vt.p(0, 0)) {
                    0 => { // erase below
                        for (s.cx..s.cols) |cc| s.cells[s.cy][cc] = s.blank();
                        var r = s.cy + 1;
                        while (r < s.rows) : (r += 1) s.clearLine(r);
                    },
                    1 => { // erase above
                        var r: u16 = 0;
                        while (r < s.cy) : (r += 1) s.clearLine(r);
                        for (0..s.cx + 1) |cc| s.cells[s.cy][cc] = s.blank();
                    },
                    2, 3 => { s.clearAll(); s.cx = 0; s.cy = 0; },
                    else => {},
                }
                s.dirty = true;
            },
            'K' => { // EL erase in line
                switch (vt.p(0, 0)) {
                    0 => for (s.cx..s.cols) |cc| { s.cells[s.cy][cc] = s.blank(); },
                    1 => for (0..s.cx + 1) |cc| { s.cells[s.cy][cc] = s.blank(); },
                    2 => s.clearLine(s.cy),
                    else => {},
                }
                s.dirty = true;
            },
            'L' => { // IL insert lines
                const n = vt.p(0, 1);
                s.scrollDown(n);
            },
            'M' => { // DL delete lines
                const n = vt.p(0, 1);
                s.scrollUp(n);
            },
            'P' => { // DCH delete characters
                const n = vt.p(0, 1);
                const row = s.cy;
                var cc = s.cx;
                while (cc + n < s.cols) : (cc += 1) {
                    s.cells[row][cc] = s.cells[row][cc + n];
                }
                while (cc < s.cols) : (cc += 1) s.cells[row][cc] = s.blank();
                s.dirty = true;
            },
            '@' => { // ICH insert characters
                const n = vt.p(0, 1);
                const row = s.cy;
                var cc: i32 = @as(i32, s.cols) - 1;
                while (cc >= @as(i32, s.cx) + @as(i32, n)) : (cc -= 1) {
                    s.cells[row][@intCast(cc)] = s.cells[row][@intCast(cc - @as(i32, n))];
                }
                var i: u16 = 0;
                while (i < n and s.cx + i < s.cols) : (i += 1) {
                    s.cells[row][s.cx + i] = s.blank();
                }
                s.dirty = true;
            },
            'S' => { // SU scroll up
                s.scrollUp(vt.p(0, 1));
            },
            'T' => { // SD scroll down
                s.scrollDown(vt.p(0, 1));
            },
            'X' => { // ECH erase characters
                const n = vt.p(0, 1);
                var i: u16 = 0;
                while (i < n and s.cx + i < s.cols) : (i += 1) {
                    s.cells[s.cy][s.cx + i] = s.blank();
                }
                s.dirty = true;
            },
            'd' => { // VPA vertical position absolute
                s.cy = @min(vt.p(0, 1) -| 1, s.rows -| 1);
            },
            'r' => { // DECSTBM set scroll region
                const top = vt.p(0, 1) -| 1;
                const bot = (if (vt.param_count >= 2) vt.params[1] else 0);
                s.scroll_top = @min(top, s.rows -| 1);
                s.scroll_bot = if (bot == 0) s.rows -| 1 else @min(bot - 1, s.rows -| 1);
                s.cx = 0;
                s.cy = 0;
            },
            's' => { // DECSC (also used without ESC 7)
                s.saved_cx = s.cx; s.saved_cy = s.cy;
            },
            'u' => { // DECRC
                s.cx = s.saved_cx; s.cy = s.saved_cy;
            },
            'm' => { // SGR
                vt.applySGR();
            },
            'h' => { // SM — ignore most, handle ?-less variant
            },
            'l' => { // RM
            },
            'n' => { // DSR
                // cursor position report — we can't easily reply here
                // (would need a write-back channel); just ignore
            },
            else => {},
        }
    }

    fn dispatchDECPriv(vt: *VtParser, final: u8) void {
        if (vt.param_count == 0) vt.param_count = 1;
        const mode = vt.params[0];
        switch (final) {
            'h' => switch (mode) {
                25  => {}, // show cursor (we always show within panel)
                1049 => { // switch to alternate screen
                    if (!vt.on_alt) {
                        vt.alt.init(vt.screen.cols, vt.screen.rows);
                        vt.on_alt = true;
                    }
                },
                47, 1047 => {
                    if (!vt.on_alt) {
                        vt.alt.init(vt.screen.cols, vt.screen.rows);
                        vt.on_alt = true;
                    }
                },
                else => {},
            },
            'l' => switch (mode) {
                25  => {},
                1049, 47, 1047 => {
                    vt.on_alt = false;
                    vt.screen.dirty = true;
                },
                else => {},
            },
            else => {},
        }
    }

    fn applySGR(vt: *VtParser) void {
        const s = vt.cur();
        const count = if (vt.param_count == 0) @as(u8, 1) else vt.param_count;
        var i: u8 = 0;
        while (i < count) : (i += 1) {
            const p0 = vt.params[i];
            switch (p0) {
                0  => s.pen.reset(),
                1  => s.pen.bold      = true,
                2  => s.pen.dim       = true,
                3  => s.pen.italic    = true,
                4  => s.pen.underline = true,
                5  => s.pen.blink     = true,
                7  => s.pen.reverse   = true,
                22 => { s.pen.bold = false; s.pen.dim = false; },
                23 => s.pen.italic    = false,
                24 => s.pen.underline = false,
                25 => s.pen.blink     = false,
                27 => s.pen.reverse   = false,
                // standard fg 30–37
                30...37 => s.pen.fg = p0 - 30,
                38 => { // extended fg
                    if (i + 1 < count and vt.params[i + 1] == 5 and i + 2 < count) {
                        // 256-color: 38;5;n
                        s.pen.fg = vt.params[i + 2];
                        i += 2;
                    } else if (i + 1 < count and vt.params[i + 1] == 2) {
                        // 24-bit true color: 38;2;r;g;b — skip r,g,b, keep current fg
                        const skip: u8 = @min(3, count - 1 - (i + 1));
                        i += 1 + skip;
                    }
                },
                39 => s.pen.fg = DEFAULT_FG,
                // standard bg 40–47
                40...47 => s.pen.bg = p0 - 40,
                48 => { // extended bg
                    if (i + 1 < count and vt.params[i + 1] == 5 and i + 2 < count) {
                        // 256-color: 48;5;n
                        s.pen.bg = vt.params[i + 2];
                        i += 2;
                    } else if (i + 1 < count and vt.params[i + 1] == 2) {
                        // 24-bit true color: 48;2;r;g;b — skip r,g,b, keep current bg
                        const skip: u8 = @min(3, count - 1 - (i + 1));
                        i += 1 + skip;
                    }
                },
                49 => s.pen.bg = DEFAULT_BG,
                // bright fg 90–97
                90...97  => s.pen.fg = p0 - 90 + 8,
                // bright bg 100–107
                100...107 => s.pen.bg = p0 - 100 + 8,
                else => {},
            }
        }
    }
};
