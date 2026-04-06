// main.zig — phTerm: CRT-style terminal multiplexer for macOS and Linux
//
// Key bindings (no prefix key required):
//   F2         Split active panel vertically   (side by side)
//   F3         Split active panel horizontally (stacked)
//   F4         Close active panel
//   F6 / Tab   Focus next panel
//   F7         Focus previous panel
//   F8         Open new shell in active panel
//   F1         Toggle help overlay
//   F10        Quit
//   Ctrl+←/→   Resize active panel width  (±5%)
//   Ctrl+↑/↓   Resize active panel height (±5%)
//
// All other keys are forwarded verbatim to the active panel.

const std      = @import("std");
const posix    = std.posix;
const terminal = @import("terminal.zig");
const panel_m  = @import("panel.zig");
const renderer = @import("renderer.zig");
const input    = @import("input.zig");
const pty_m    = @import("pty.zig");

// ── Global signal flags ───────────────────────────────────────────────────────

var g_sigwinch: bool = false;
var g_sigchld:  bool = false;

fn onSigwinch(sig: i32) callconv(.C) void { _ = sig; g_sigwinch = true; }
fn onSigchld(sig:  i32) callconv(.C) void { _ = sig; g_sigchld  = true; }

fn installSignals() void {
    const empty = posix.empty_sigset;

    posix.sigaction(posix.SIG.WINCH, &posix.Sigaction{
        .handler = .{ .handler = onSigwinch },
        .mask    = empty,
        .flags   = 0,
    }, null);

    posix.sigaction(posix.SIG.CHLD, &posix.Sigaction{
        .handler = .{ .handler = onSigchld },
        .mask    = empty,
        .flags   = 0,
    }, null);

    // Ignore SIGPIPE so broken PTY writes don't kill us
    posix.sigaction(posix.SIG.PIPE, &posix.Sigaction{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask    = empty,
        .flags   = 0,
    }, null);
}

// ── Resize helper: adjust active panel's parent split ratio ───────────────────

fn adjustRatio(mgr: *panel_m.PanelManager, delta: f32, dir: panel_m.SplitDir) void {
    const active = mgr.active orelse return;
    const leaf   = mgr.findLeafPub(active) orelse return;
    const par    = leaf.parent orelse return;
    if (par.dir != dir) return;
    par.ratio = std.math.clamp(par.ratio + delta, 0.1, 0.9);
    mgr.relayout();
}

// ── Entry point ───────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try terminal.enableRawMode();
    defer terminal.disableRawMode();
    defer terminal.showCursor();

    installSignals();

    var ts = try terminal.getSize();

    var mgr = try panel_m.PanelManager.init(allocator, ts.cols, ts.rows);
    defer mgr.deinit();
    try mgr.addFirst();

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    try buf.ensureTotalCapacity(256 * 1024);

    // Initial draw
    terminal.clearScreen();
    terminal.hideCursor();
    for (mgr.panels.items) |p| p.vtemu.cur().dirty = true;
    try renderer.render(&buf, &mgr, false);

    // ── Event loop ────────────────────────────────────────────────────────────
    var quit:      bool = false;
    var show_help: bool = false;
    var raw_in:    [64]u8    = undefined;
    var pty_buf:   [4096]u8  = undefined;

    const MAX_PANELS = 64;
    var pfds: [MAX_PANELS + 1]posix.pollfd = undefined;

    while (!quit) {

        // ── SIGWINCH ─────────────────────────────────────────────────────────
        if (g_sigwinch) {
            g_sigwinch = false;
            ts = terminal.getSize() catch ts;
            mgr.resizeTerm(ts.cols, ts.rows);
            for (mgr.panels.items) |p| p.vtemu.cur().dirty = true;
            terminal.clearScreen();
        }

        // ── SIGCHLD ───────────────────────────────────────────────────────────
        if (g_sigchld) {
            g_sigchld = false;
            pty_m.reapChildren();
        }

        // ── Build poll list ───────────────────────────────────────────────────
        pfds[0] = .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 };
        const n_panels = @min(mgr.panels.items.len, MAX_PANELS);
        for (0..n_panels) |i| {
            pfds[i + 1] = .{
                .fd     = mgr.panels.items[i].master,
                .events = posix.POLL.IN,
                .revents = 0,
            };
        }
        const nfds = n_panels + 1;

        _ = posix.poll(pfds[0..nfds], 33) catch 0; // ≈30 fps

        var needs_render = false;

        // ── PTY output ────────────────────────────────────────────────────────
        for (0..n_panels) |i| {
            if (pfds[i + 1].revents & posix.POLL.IN != 0) {
                const panel = mgr.panels.items[i];
                const n = posix.read(panel.master, &pty_buf) catch continue;
                if (n > 0) {
                    panel.feed(pty_buf[0..n]);
                    needs_render = true;
                }
            }
        }

        // ── Keyboard input ────────────────────────────────────────────────────
        if (pfds[0].revents & posix.POLL.IN != 0) {
            const n = input.readKey(&raw_in) catch 0;
            if (n > 0) {
                const key = input.parse(raw_in[0..n]);
                switch (key.kind) {
                    .f1 => {
                        show_help = !show_help;
                        needs_render = true;
                    },
                    .f2 => {
                        try mgr.splitActive(.horiz);
                        for (mgr.panels.items) |p| p.vtemu.cur().dirty = true;
                        terminal.clearScreen();
                        needs_render = true;
                    },
                    .f3 => {
                        try mgr.splitActive(.vert);
                        for (mgr.panels.items) |p| p.vtemu.cur().dirty = true;
                        terminal.clearScreen();
                        needs_render = true;
                    },
                    .f4 => {
                        if (mgr.panels.items.len > 1) {
                            mgr.closeActive();
                            for (mgr.panels.items) |p| p.vtemu.cur().dirty = true;
                            terminal.clearScreen();
                            needs_render = true;
                        }
                    },
                    .f5 => {
                        for (mgr.panels.items) |p| p.vtemu.cur().dirty = true;
                        terminal.clearScreen();
                        needs_render = true;
                    },
                    .f6, .tab => {
                        mgr.nextPanel();
                        needs_render = true;
                    },
                    .f7, .shift_tab => {
                        mgr.prevPanel();
                        needs_render = true;
                    },
                    .f8 => {
                        if (mgr.active) |ap| {
                            const new_pty = try pty_m.spawn(ap.w, ap.h);
                            posix.close(ap.master);
                            ap.master = new_pty.master;
                            ap.pid    = new_pty.pid;
                            ap.vtemu.init(ap.w, ap.h);
                            needs_render = true;
                        }
                    },
                    .f10 => { quit = true; },
                    .ctrl_left  => { adjustRatio(&mgr, -0.05, .horiz); needs_render = true; },
                    .ctrl_right => { adjustRatio(&mgr,  0.05, .horiz); needs_render = true; },
                    .ctrl_up    => { adjustRatio(&mgr, -0.05, .vert);  needs_render = true; },
                    .ctrl_down  => { adjustRatio(&mgr,  0.05, .vert);  needs_render = true; },
                    .char => {
                        if (mgr.active) |ap| ap.write(key.data[0..key.len]);
                    },
                    else => {},
                }
            }
        }

        if (needs_render) {
            terminal.hideCursor();
            try renderer.render(&buf, &mgr, show_help);
            if (!show_help) terminal.showCursor();
        }
    }

    terminal.clearScreen();
    terminal.showCursor();
}
