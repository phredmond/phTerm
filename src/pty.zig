// pty.zig — pseudo-terminal creation and shell spawning (macOS + Linux)
const std = @import("std");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
    @cInclude("string.h");
});

pub const Pty = struct {
    master: std.posix.fd_t,
    pid:    std.posix.pid_t,
};

/// Spawn a shell inside a new PTY of the given size.
pub fn spawn(cols: u16, rows: u16) !Pty {
    // Open PTY master via POSIX interface
    const master = c.posix_openpt(c.O_RDWR | c.O_NOCTTY);
    if (master < 0) return error.OpenPtFailed;
    if (c.grantpt(master) != 0) return error.GrantptFailed;
    if (c.unlockpt(master) != 0) return error.UnlockptFailed;

    const slave_name = c.ptsname(master) orelse return error.PtsnameFailed;

    // Set initial window size on slave
    const slave = c.open(slave_name, c.O_RDWR);
    if (slave < 0) return error.OpenSlaveFailed;
    defer _ = c.close(slave);

    var ws: c.struct_winsize = .{
        .ws_col = cols,
        .ws_row = rows,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    _ = c.ioctl(slave, c.TIOCSWINSZ, &ws);

    const pid = try std.posix.fork();
    if (pid == 0) {
        // ── Child process ─────────────────────────────────────────────────────
        _ = c.close(master);
        _ = c.setsid();

        const slave2 = c.open(slave_name, c.O_RDWR);
        if (slave2 < 0) std.posix.exit(1);

        _ = c.ioctl(slave2, c.TIOCSCTTY, @as(c_int, 0));

        _ = c.dup2(slave2, 0);
        _ = c.dup2(slave2, 1);
        _ = c.dup2(slave2, 2);
        if (slave2 > 2) _ = c.close(slave2);

        _ = c.setenv("TERM", "xterm-256color", 1);
        _ = c.setenv("COLORTERM", "truecolor", 1);

        // Resolve shell path
        const shell_env = c.getenv("SHELL");
        const shell: [*:0]const u8 = if (shell_env != null) shell_env.? else "/bin/bash";

        // execvp: char *const argv[]  →  [*c]const [*c]u8
        var argv_buf: [2][*c]u8 = .{
            @ptrCast(@constCast(shell)),
            null,
        };
        _ = c.execvp(shell, @as([*c]const [*c]u8, @ptrCast(&argv_buf)));
        std.posix.exit(1);
    }

    // ── Parent ───────────────────────────────────────────────────────────────
    return .{ .master = @intCast(master), .pid = pid };
}

/// Reap a specific child (blocking).
pub fn reapChild(pid: std.posix.pid_t) void {
    _ = c.waitpid(@intCast(pid), null, 0);
}

/// Non-blocking reap of all finished children (call from SIGCHLD handler).
pub fn reapChildren() void {
    while (c.waitpid(-1, null, c.WNOHANG) > 0) {}
}

/// Notify the PTY of a terminal resize.
pub fn resize(master: std.posix.fd_t, cols: u16, rows: u16) void {
    var ws: c.struct_winsize = .{
        .ws_col = cols,
        .ws_row = rows,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    _ = c.ioctl(master, c.TIOCSWINSZ, &ws);
}
