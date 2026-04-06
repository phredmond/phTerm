// renderer.zig — composites all panels onto the real terminal with CRT aesthetic
const std = @import("std");
const tm  = @import("terminal.zig");
const vtm = @import("vt.zig");
const pm  = @import("panel.zig");

const Writer = std.ArrayList(u8).Writer;

// ── ANSI 256-color lookup (terminal default → CRT green fallback) ─────────────

/// Emit an ANSI color sequence for a panel cell color value.
/// We let real app colors through unchanged; only override the
/// panel-default (256/257) with our CRT green palette.
fn emitFg(w: Writer, color: u16, bold: bool) !void {
    switch (color) {
        vtm.DEFAULT_FG => {
            if (bold)
                try w.writeAll("\x1b[1;32m")   // bright CRT green
            else
                try w.writeAll("\x1b[0;32m");   // normal CRT green
        },
        0...7   => try w.print("\x1b[{}m",    .{color + 30}),
        8...15  => try w.print("\x1b[{}m",    .{color - 8 + 90}),
        else    => try w.print("\x1b[38;5;{}m", .{color}),
    }
}

fn emitBg(w: Writer, color: u16) !void {
    switch (color) {
        vtm.DEFAULT_BG => try w.writeAll("\x1b[40m"), // force black background
        0...7   => try w.print("\x1b[{}m",    .{color + 40}),
        8...15  => try w.print("\x1b[{}m",    .{color - 8 + 100}),
        else    => try w.print("\x1b[48;5;{}m", .{color}),
    }
}

// ── Border helpers ────────────────────────────────────────────────────────────

fn drawBorder(
    w: Writer,
    x: u16, y: u16, width: u16, height: u16,
    active: bool,
    title: []const u8,
) !void {
    const color  = if (active) tm.CRT.bright else tm.CRT.dim;
    const h_ch   = if (active) tm.CRT.hl2    else tm.CRT.hl;
    const v_ch   = if (active) tm.CRT.vl2    else tm.CRT.vl;
    const tl_ch  = if (active) tm.CRT.tl2    else tm.CRT.tl;
    const tr_ch  = if (active) tm.CRT.tr2    else tm.CRT.tr;
    const bl_ch  = if (active) tm.CRT.bl2    else tm.CRT.bl;
    const br_ch  = if (active) tm.CRT.br2    else tm.CRT.br;

    try w.writeAll(color);
    try w.writeAll("\x1b[40m"); // black bg for chrome

    // ── Top edge ─────────────────────────────────────────────────────────────
    try w.print("\x1b[{};{}H", .{ y + 1, x + 1 });
    try w.writeAll(tl_ch);

    // title (truncated)
    const max_title = if (width > 6) width - 6 else 0;
    const short_title = title[0..@min(title.len, max_title)];
    if (short_title.len > 0) {
        try w.writeAll("[ ");
        try w.writeAll(short_title);
        try w.writeAll(" ]");
        var i: u16 = @intCast(short_title.len + 4);
        while (i < width -| 2) : (i += 1) try w.writeAll(h_ch);
    } else {
        var i: u16 = 0;
        while (i < width -| 2) : (i += 1) try w.writeAll(h_ch);
    }
    try w.writeAll(tr_ch);

    // ── Side edges ───────────────────────────────────────────────────────────
    var row: u16 = 1;
    while (row < height -| 1) : (row += 1) {
        try w.print("\x1b[{};{}H", .{ y + row + 1, x + 1 });
        try w.writeAll(v_ch);
        try w.print("\x1b[{};{}H", .{ y + row + 1, x + width });
        try w.writeAll(v_ch);
    }

    // ── Bottom edge ──────────────────────────────────────────────────────────
    try w.print("\x1b[{};{}H", .{ y + height, x + 1 });
    try w.writeAll(bl_ch);
    var i: u16 = 0;
    while (i < width -| 2) : (i += 1) try w.writeAll(h_ch);
    try w.writeAll(br_ch);
}

// ── Panel content ─────────────────────────────────────────────────────────────

fn drawPanelContent(w: Writer, panel: *pm.Panel) !void {
    const screen = panel.vtemu.cur();
    const rows = screen.rows;
    const cols = screen.cols;
    const ox = panel.x;
    const oy = panel.y;

    var last_fg:  u16  = 9999;
    var last_bg:  u16  = 9999;
    var last_bold: bool = false;
    var last_dim:  bool = false;
    var last_ul:   bool = false;
    var last_rev:  bool = false;
    var last_blnk: bool = false;

    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        try w.print("\x1b[{};{}H", .{ oy + row + 1, ox + 1 });
        var col: u16 = 0;
        while (col < cols) : (col += 1) {
            const cell = screen.cells[row][col];

            // Only emit attribute changes
            var attr_changed = false;
            if (cell.fg != last_fg or cell.bg != last_bg or
                cell.bold != last_bold or cell.dim != last_dim or
                cell.underline != last_ul or cell.reverse != last_rev or
                cell.blink != last_blnk)
            {
                attr_changed = true;
            }

            if (attr_changed) {
                try w.writeAll("\x1b[0m"); // reset then rebuild
                try emitBg(w, cell.bg);
                try emitFg(w, cell.fg, cell.bold);
                if (cell.dim)       try w.writeAll("\x1b[2m");
                if (cell.italic)    try w.writeAll("\x1b[3m");
                if (cell.underline) try w.writeAll("\x1b[4m");
                if (cell.blink)     try w.writeAll("\x1b[5m");
                if (cell.reverse)   try w.writeAll("\x1b[7m");
                last_fg   = cell.fg;
                last_bg   = cell.bg;
                last_bold = cell.bold;
                last_dim  = cell.dim;
                last_ul   = cell.underline;
                last_rev  = cell.reverse;
                last_blnk = cell.blink;
            }

            // Encode the codepoint as UTF-8
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cell.ch, &buf) catch 1;
            if (len == 1 and (buf[0] < 0x20 or buf[0] == 0x7F)) {
                try w.writeByte(' ');
            } else {
                try w.writeAll(buf[0..len]);
            }
        }
    }
}

// ── Status bar ────────────────────────────────────────────────────────────────

fn drawStatusBar(w: Writer, mgr: *pm.PanelManager) !void {
    const row = mgr.term_rows;
    const cols = mgr.term_cols;

    try w.print("\x1b[{};1H", .{row});
    try w.writeAll(tm.CRT.bar_bg);

    // Build bar text
    var panel_num: usize = 0;
    const total = mgr.panels.items.len;
    for (mgr.panels.items, 0..) |p, i| {
        if (p == mgr.active) { panel_num = i + 1; break; }
    }

    // Left section — app name
    const left = " phTerm ";
    // Right section — panel info
    var rbuf: [64]u8 = undefined;
    const right = std.fmt.bufPrint(&rbuf, " Panel {}/{} ", .{ panel_num, total }) catch " ";

    // Middle — key hints (truncated to fit)
    const hints = "F2:VSplit  F3:HSplit  F4:Close  F6:Next  F7:Prev  F1:Help  F10:Quit";

    try w.writeAll(left);
    try w.writeAll(tm.CRT.bar_key);
    try w.writeAll("─");
    try w.writeAll(tm.CRT.bar_bg);

    // Hints — clipped
    const avail: usize = if (cols > left.len + right.len + 2)
        cols - left.len - right.len - 2
    else
        0;
    const hint_slice = hints[0..@min(hints.len, avail)];
    try w.writeAll(hint_slice);

    // Pad + right section
    const used = left.len + 1 + hint_slice.len + right.len;
    if (cols > used) {
        const pad = cols - used;
        var k: usize = 0;
        while (k < pad) : (k += 1) try w.writeByte(' ');
    }
    try w.writeAll(tm.CRT.bar_key);
    try w.writeAll(right);
    try w.writeAll(tm.CRT.reset);
}

// ── Help overlay ─────────────────────────────────────────────────────────────

pub fn drawHelp(buf: *std.ArrayList(u8), cols: u16, rows: u16) !void {
    const w = buf.writer();
    const lines = [_][]const u8{
        "┌─────────────────────────────────────────┐",
        "│          phTerm  Key Bindings            │",
        "├─────────────────────────────────────────┤",
        "│  F2          Split panel vertically      │",
        "│  F3          Split panel horizontally    │",
        "│  F4          Close active panel          │",
        "│  F6  / Tab   Focus next panel            │",
        "│  F7          Focus previous panel        │",
        "│  F8          New panel (replace shell)   │",
        "│  F1          Toggle this help            │",
        "│  F10         Quit phTerm                 │",
        "│  Ctrl+Arrow  Resize panel (±5 cols/rows) │",
        "├─────────────────────────────────────────┤",
        "│  All other keys sent to active panel.   │",
        "└─────────────────────────────────────────┘",
    };
    const bw: u16 = 45;
    const bh: u16 = @intCast(lines.len);
    const sx: u16 = if (cols > bw) (cols - bw) / 2 else 0;
    const sy: u16 = if (rows > bh) (rows - bh) / 2 else 0;

    try w.writeAll(tm.CRT.bright);
    try w.writeAll("\x1b[40m");
    for (lines, 0..) |line, i| {
        try w.print("\x1b[{};{}H{s}", .{ sy + i + 1, sx + 1, line });
    }
    try w.writeAll(tm.CRT.reset);
}

// ── Main render entry point ───────────────────────────────────────────────────

pub fn render(
    buf:      *std.ArrayList(u8),
    mgr:      *pm.PanelManager,
    show_help: bool,
) !void {
    const w = buf.writer();
    // Collect leaf nodes
    var leaves = std.ArrayList(*pm.Node).init(mgr.allocator);
    defer leaves.deinit();
    try mgr.collectLeaves(&leaves);

    for (leaves.items) |leaf| {
        const panel = leaf.panel orelse continue;
        const is_active = (panel == mgr.active);
        const screen = panel.vtemu.cur();

        if (!screen.dirty and !is_active) continue; // skip if unchanged & inactive

        // Draw border
        var tbuf: [32]u8 = undefined;
        const title = std.fmt.bufPrint(&tbuf, "Shell {}", .{panel.id + 1}) catch "Shell";
        try drawBorder(w, leaf.x, leaf.y, leaf.w, leaf.h, is_active, title);

        // Draw content
        try drawPanelContent(w, panel);

        screen.dirty = false;
    }

    // Status bar (always redraw)
    try drawStatusBar(w, mgr);

    // Help overlay
    if (show_help) {
        try drawHelp(buf, mgr.term_cols, mgr.term_rows);
    }

    // Position cursor at active panel's cursor position
    if (mgr.active) |ap| {
        const scr = ap.vtemu.cur();
        const cx = ap.x + scr.cx;
        const cy = ap.y + scr.cy;
        try w.print("\x1b[{};{}H", .{ cy + 1, cx + 1 });
    }

    // Flush
    tm.writeAll(buf.items);
    buf.clearRetainingCapacity();
}
