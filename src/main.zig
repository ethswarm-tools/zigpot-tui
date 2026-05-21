//! zigpot-tui — a terminal browser for a zigpot Proximity Order Trie,
//! built on libvaxis.
//!
//!   zigpot-tui                              # a built-in demo index
//!   zigpot-tui --dir <path> --root <hex>    # load a real index from disk
//!
//! Left pane: the key/value entries (j / k move the selection).
//! Right pane: the POT structure — each node indented by depth and
//! labelled with the proximity order it branches at; the node holding the
//! selected key is highlighted. q or Esc quits.
//!
//! Note: requires a real terminal to run; headless it can only compile.

const std = @import("std");
const vaxis = @import("vaxis");
const zigpot = @import("zigpot");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

const Row = struct { key: []const u8, value: []const u8 };

/// Flattens the index's entries into a list for the left pane.
const KvCollector = struct {
    rows: [1024]Row = undefined,
    n: usize = 0,
    fn visit(self: *KvCollector, key: []const u8, value: []const u8) void {
        if (self.n < self.rows.len) {
            self.rows[self.n] = .{ .key = key, .value = value };
            self.n += 1;
        }
    }
};

const TreeNode = struct { depth: usize, po: ?usize, key: []const u8 };

/// Flattens the trie structure (depth-first) for the right pane.
const TreeCollector = struct {
    nodes: [1024]TreeNode = undefined,
    n: usize = 0,
    fn visit(self: *TreeCollector, depth: usize, po: ?usize, key: []const u8, value: []const u8) void {
        _ = value;
        if (self.n < self.nodes.len) {
            self.nodes[self.n] = .{ .depth = depth, .po = po, .key = key };
            self.n += 1;
        }
    }
};

fn demoIndex(allocator: std.mem.Allocator) !zigpot.Index {
    var idx = zigpot.Index.init(allocator, 256);
    errdefer idx.deinit();
    const seed = [_]Row{
        .{ .key = "name", .value = "ada" },
        .{ .key = "lang", .value = "zig" },
        .{ .key = "store", .value = "swarm" },
        .{ .key = "struct", .value = "proximity-order-trie" },
        .{ .key = "hash", .value = "bmt-keccak256" },
        .{ .key = "root", .value = "content-addressed" },
        .{ .key = "node", .value = "one-chunk" },
        .{ .key = "depth", .value = "po-bounded" },
    };
    for (seed) |r| try idx.put(r.key, r.value);
    return idx;
}

/// Build the index to browse: `--dir <path> --root <hex>` loads from a
/// local FileStore; otherwise a built-in demo.
fn loadIndex(allocator: std.mem.Allocator, io: std.Io, args: std.process.Args) !zigpot.Index {
    var it = std.process.Args.Iterator.init(args);
    _ = it.next(); // skip the program name

    var dir: ?[]const u8 = null;
    var root_hex: ?[]const u8 = null;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--dir")) {
            if (it.next()) |v| dir = v;
        } else if (std.mem.eql(u8, arg, "--root")) {
            if (it.next()) |v| root_hex = v;
        }
    }

    if (dir) |d| if (root_hex) |rh| {
        var fs = try zigpot.FileStore.init(io, d);
        defer fs.deinit();
        var addr: zigpot.Address = undefined;
        _ = try std.fmt.hexToBytes(&addr, rh);
        return zigpot.Index.load(allocator, fs.store(), addr, 256);
    };
    return demoIndex(allocator);
}

/// Render one trie node: indent by depth, label with its branch PO.
fn formatNode(buf: []u8, node: TreeNode) []const u8 {
    const spaces = "                                ";
    const ind = spaces[0..@min(node.depth * 2, spaces.len)];
    return if (node.po) |po|
        std.fmt.bufPrint(buf, "{s}+[po {d}] {s}", .{ ind, po, node.key }) catch node.key
    else
        std.fmt.bufPrint(buf, "{s}* {s}", .{ ind, node.key }) catch node.key;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var idx = try loadIndex(allocator, io, init.minimal.args);
    defer idx.deinit();

    var kv = KvCollector{};
    idx.iterate(&kv, KvCollector.visit);
    const rows = kv.rows[0..kv.n];

    var tree = TreeCollector{};
    idx.walkStructure(&tree, TreeCollector.visit);
    const nodes = tree.nodes[0..tree.n];

    // --- libvaxis setup (io, gpa, env map all provided by the runtime) ---
    var tty_buf: [8192]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();
    const writer = tty.writer();

    var vx = try vaxis.Vaxis.init(io, allocator, init.environ_map, .{});
    defer vx.deinit(allocator, writer);

    var loop: vaxis.Loop(Event) = vaxis.Loop(Event).init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(writer);
    try vx.queryTerminal(writer, std.Io.Duration.fromSeconds(1));

    var selected: usize = 0;
    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('q', .{}) or key.matches(vaxis.Key.escape, .{})) break;
                if (key.matches('j', .{}) and selected + 1 < rows.len) selected += 1;
                if (key.matches('k', .{}) and selected > 0) selected -= 1;
            },
            .winsize => |ws| try vx.resize(allocator, writer, ws),
        }

        const win = vx.window();
        win.clear();

        _ = win.printSegment(.{
            .text = "zigpot-tui — POT browser   (j/k move · q quit)",
            .style = .{ .bold = true },
        }, .{ .row_offset = 0 });

        const half = win.width / 2;
        const left = win.child(.{ .x_off = 0, .y_off = 1, .width = half, .height = win.height -| 1 });
        const right = win.child(.{ .x_off = @intCast(half), .y_off = 1, .width = win.width -| half, .height = win.height -| 1 });

        const sel_key: []const u8 = if (rows.len > 0) rows[selected].key else "";

        // left pane: entries
        _ = left.printSegment(.{ .text = "entries", .style = .{ .bold = true } }, .{ .row_offset = 0 });
        for (rows, 0..) |row, i| {
            var buf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{s} = {s}", .{ row.key, row.value }) catch row.key;
            const style: vaxis.Style = if (i == selected) .{ .reverse = true } else .{};
            _ = left.printSegment(.{ .text = line, .style = style }, .{ .row_offset = @intCast(i + 1), .wrap = .none });
        }

        // right pane: trie structure
        _ = right.printSegment(.{ .text = "proximity-order trie", .style = .{ .bold = true } }, .{ .row_offset = 0 });
        for (nodes, 0..) |node, i| {
            var buf: [256]u8 = undefined;
            const line = formatNode(&buf, node);
            const style: vaxis.Style = if (std.mem.eql(u8, node.key, sel_key)) .{ .reverse = true } else .{};
            _ = right.printSegment(.{ .text = line, .style = style }, .{ .row_offset = @intCast(i + 1), .wrap = .none });
        }

        try vx.render(writer);
    }
}
