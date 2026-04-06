// panel.zig — panel data, binary split-tree layout, and panel manager
const std = @import("std");
const vt  = @import("vt.zig");
const pty = @import("pty.zig");

// ── Panel ─────────────────────────────────────────────────────────────────────

pub const Panel = struct {
    id:     u32,
    master: std.posix.fd_t,
    pid:    std.posix.pid_t,
    vtemu: vt.VtParser,
    // Geometry computed by layout engine
    x:  u16 = 0,
    y:  u16 = 0,
    w:  u16 = 80,
    h:  u16 = 24,
    alive: bool = true,

    pub fn init(id: u32, cols: u16, rows: u16) !Panel {
        const p = try pty.spawn(cols, rows);
        var panel = Panel{
            .id     = id,
            .master = p.master,
            .pid    = p.pid,
            .vtemu  = .{},
        };
        panel.vtemu.init(cols, rows);
        panel.w = cols;
        panel.h = rows;
        return panel;
    }

    pub fn deinit(self: *Panel) void {
        std.posix.close(self.master);
        pty.reapChild(self.pid);
    }

    pub fn feed(self: *Panel, data: []const u8) void {
        self.vtemu.feed(data);
    }

    pub fn resize(self: *Panel, cols: u16, rows: u16) void {
        self.w = cols;
        self.h = rows;
        self.vtemu.resize(cols, rows);
        pty.resize(self.master, cols, rows);
    }

    pub fn write(self: *Panel, data: []const u8) void {
        var off: usize = 0;
        while (off < data.len) {
            const n = std.posix.write(self.master, data[off..]) catch break;
            off += n;
        }
    }
};

// ── Layout tree ───────────────────────────────────────────────────────────────

pub const SplitDir = enum { horiz, vert };

pub const NodeTag = enum { leaf, split };

pub const Node = struct {
    tag:   NodeTag,
    // leaf
    panel: ?*Panel = null,
    // split
    dir:   SplitDir = .horiz,
    ratio: f32      = 0.5,
    a:     ?*Node   = null, // left/top child
    b:     ?*Node   = null, // right/bottom child
    parent: ?*Node  = null,
    // computed geometry
    x: u16 = 0,
    y: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,
};

// ── Manager ───────────────────────────────────────────────────────────────────

pub const PanelManager = struct {
    allocator: std.mem.Allocator,
    nodes:     std.ArrayList(*Node),
    panels:    std.ArrayList(*Panel),
    root:      ?*Node = null,
    active:    ?*Panel = null,
    next_id:   u32 = 0,
    term_cols: u16,
    term_rows: u16,

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16) !PanelManager {
        return .{
            .allocator  = allocator,
            .nodes      = std.ArrayList(*Node).init(allocator),
            .panels     = std.ArrayList(*Panel).init(allocator),
            .term_cols  = cols,
            .term_rows  = rows,
        };
    }

    pub fn deinit(self: *PanelManager) void {
        for (self.panels.items) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
        for (self.nodes.items) |n| self.allocator.destroy(n);
        self.panels.deinit();
        self.nodes.deinit();
    }

    // Content area = full terminal minus 1-row status bar
    fn contentH(self: *PanelManager) u16 { return self.term_rows -| 1; }

    /// Create the first panel filling the content area.
    pub fn addFirst(self: *PanelManager) !void {
        const panel = try self.newPanel(self.term_cols, self.contentH());
        const node  = try self.newNode(.{
            .tag   = .leaf,
            .panel = panel,
        });
        self.root   = node;
        self.active = panel;
        self.relayout();
    }

    /// Split the active panel.  dir = .horiz → side-by-side, .vert → stacked.
    pub fn splitActive(self: *PanelManager, dir: SplitDir) !void {
        const active_panel = self.active orelse return;
        const leaf = self.findLeaf(active_panel) orelse return;

        // New panel starts with same geometry (will be fixed by relayout)
        const new_panel = try self.newPanel(active_panel.w, active_panel.h);
        const new_leaf  = try self.newNode(.{ .tag = .leaf, .panel = new_panel });

        // Wrap the existing leaf in a new split node
        const split = try self.newNode(.{
            .tag    = .split,
            .dir    = dir,
            .ratio  = 0.5,
            .a      = leaf,
            .b      = new_leaf,
            .parent = leaf.parent,
        });
        leaf.parent    = split;
        new_leaf.parent = split;

        if (split.parent) |par| {
            if (par.a == leaf) par.a = split else par.b = split;
        } else {
            self.root = split;
        }

        self.active = new_panel;
        self.relayout();
    }

    /// Close the active panel.
    pub fn closeActive(self: *PanelManager) void {
        const active_panel = self.active orelse return;
        const leaf = self.findLeaf(active_panel) orelse return;

        if (leaf.parent == null) {
            // Only panel — nothing to close into
            return;
        }

        const par = leaf.parent.?;
        // Sibling takes over the parent's geometry
        const sibling: *Node = if (par.a == leaf) par.b.? else par.a.?;
        sibling.parent = par.parent;

        if (par.parent) |gp| {
            if (gp.a == par) gp.a = sibling else gp.b = sibling;
        } else {
            self.root = sibling;
        }

        // Remove panel + nodes from lists
        active_panel.deinit();
        self.removePanelFromList(active_panel);
        self.allocator.destroy(active_panel);
        self.removeNodeFromList(leaf);
        self.allocator.destroy(leaf);
        self.removeNodeFromList(par);
        self.allocator.destroy(par);

        // Select another panel
        self.active = self.panels.items[0];
        self.relayout();
    }

    pub fn nextPanel(self: *PanelManager) void {
        if (self.panels.items.len == 0) return;
        const cur = self.active orelse { self.active = self.panels.items[0]; return; };
        for (self.panels.items, 0..) |p, i| {
            if (p == cur) {
                self.active = self.panels.items[(i + 1) % self.panels.items.len];
                return;
            }
        }
    }

    pub fn prevPanel(self: *PanelManager) void {
        if (self.panels.items.len == 0) return;
        const cur = self.active orelse { self.active = self.panels.items[0]; return; };
        for (self.panels.items, 0..) |p, i| {
            if (p == cur) {
                const prev = if (i == 0) self.panels.items.len - 1 else i - 1;
                self.active = self.panels.items[prev];
                return;
            }
        }
    }

    pub fn resizeTerm(self: *PanelManager, cols: u16, rows: u16) void {
        self.term_cols = cols;
        self.term_rows = rows;
        self.relayout();
    }

    /// Walk tree and assign geometry; resize each panel's PTY.
    pub fn relayout(self: *PanelManager) void {
        if (self.root) |r| {
            r.x = 0;
            r.y = 0;
            r.w = self.term_cols;
            r.h = self.contentH();
            self.layoutNode(r);
        }
    }

    fn layoutNode(self: *PanelManager, n: *Node) void {
        switch (n.tag) {
            .leaf => {
                if (n.panel) |p| {
                    // Inner content = node area minus 2 for border (top+bottom / left+right)
                    const inner_w: u16 = if (n.w > 2) n.w - 2 else 1;
                    const inner_h: u16 = if (n.h > 2) n.h - 2 else 1;
                    p.x = n.x + 1;
                    p.y = n.y + 1;
                    p.resize(inner_w, inner_h);
                }
            },
            .split => {
                const a = n.a orelse return;
                const b = n.b orelse return;
                if (n.dir == .horiz) { // side by side
                    const aw = @max(1, @as(u16, @intFromFloat(@round(@as(f32, @floatFromInt(n.w)) * n.ratio))));
                    const bw = if (n.w > aw) n.w - aw else 1;
                    a.x = n.x; a.y = n.y; a.w = aw; a.h = n.h;
                    b.x = n.x + aw; b.y = n.y; b.w = bw; b.h = n.h;
                } else { // stacked
                    const ah = @max(1, @as(u16, @intFromFloat(@round(@as(f32, @floatFromInt(n.h)) * n.ratio))));
                    const bh = if (n.h > ah) n.h - ah else 1;
                    a.x = n.x; a.y = n.y; a.w = n.w; a.h = ah;
                    b.x = n.x; b.y = n.y + ah; b.w = n.w; b.h = bh;
                }
                self.layoutNode(a);
                self.layoutNode(b);
            },
        }
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    fn newPanel(self: *PanelManager, cols: u16, rows: u16) !*Panel {
        const id = self.next_id;
        self.next_id += 1;
        const p = try self.allocator.create(Panel);
        p.* = try Panel.init(id, cols, rows);
        try self.panels.append(p);
        return p;
    }

    fn newNode(self: *PanelManager, init_val: Node) !*Node {
        const n = try self.allocator.create(Node);
        n.* = init_val;
        try self.nodes.append(n);
        return n;
    }

    pub fn findLeafPub(self: *PanelManager, panel: *Panel) ?*Node {
        return self.findLeaf(panel);
    }

    fn findLeaf(self: *PanelManager, panel: *Panel) ?*Node {
        for (self.nodes.items) |n| {
            if (n.tag == .leaf and n.panel == panel) return n;
        }
        return null;
    }

    fn removePanelFromList(self: *PanelManager, panel: *Panel) void {
        for (self.panels.items, 0..) |p, i| {
            if (p == panel) { _ = self.panels.swapRemove(i); return; }
        }
    }

    fn removeNodeFromList(self: *PanelManager, node: *Node) void {
        for (self.nodes.items, 0..) |n, i| {
            if (n == node) { _ = self.nodes.swapRemove(i); return; }
        }
    }

    /// Collect leaf nodes in left-to-right / top-to-bottom order.
    pub fn collectLeaves(self: *PanelManager, out: *std.ArrayList(*Node)) !void {
        out.clearRetainingCapacity();
        if (self.root) |r| try self.walkLeaves(r, out);
    }

    fn walkLeaves(self: *PanelManager, n: *Node, out: *std.ArrayList(*Node)) !void {
        switch (n.tag) {
            .leaf  => try out.append(n),
            .split => {
                if (n.a) |a| try self.walkLeaves(a, out);
                if (n.b) |b| try self.walkLeaves(b, out);
            },
        }
    }
};
