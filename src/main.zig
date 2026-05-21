//! zigpot-tui — a terminal browser for a zigpot Proximity Order Trie,
//! built on libvaxis.
//!
//!   zigpot-tui                              # a built-in demo index
//!   zigpot-tui --bee <url>  --root <hex>    # load from a running Bee node
//!   zigpot-tui --dir <path> --root <hex>    # load a real index from disk
//!   (append --dump to print as text instead of opening the TUI)
//!
//! Left pane: the key/value entries (j / k move the selection).
//! Right pane: the POT structure drawn as a tree (branch glyphs, each
//! node labelled with the proximity order it branches at); the selected
//! entry's node is highlighted. q or Esc quits.
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
    rows: [4096]Row = undefined,
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
    nodes: [4096]TreeNode = undefined,
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

/// Build the index to browse:
///   --bee <url> --root <hex>   loads from a Bee node (read-only)
///   --dir <path> --root <hex>  loads from a local FileStore
/// otherwise a built-in demo.
fn loadIndex(allocator: std.mem.Allocator, io: std.Io, args: std.process.Args) !zigpot.Index {
    var it = std.process.Args.Iterator.init(args);
    _ = it.next(); // skip the program name

    var dir: ?[]const u8 = null;
    var bee: ?[]const u8 = null;
    var root_hex: ?[]const u8 = null;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--dir")) {
            if (it.next()) |v| dir = v;
        } else if (std.mem.eql(u8, arg, "--bee")) {
            if (it.next()) |v| bee = v;
        } else if (std.mem.eql(u8, arg, "--root")) {
            if (it.next()) |v| root_hex = v;
        }
    }

    // Need a root to load anything; without one, show the demo.
    const rh = root_hex orelse return demoIndex(allocator);
    var addr: zigpot.Address = undefined;
    _ = try std.fmt.hexToBytes(&addr, rh);

    if (bee) |url| {
        // Read-only: downloads don't need a postage batch.
        var bs = zigpot.BeeStore.init(io, allocator, url, null);
        defer bs.deinit();
        return zigpot.Index.load(allocator, bs.store(), addr, 256);
    }
    if (dir) |d| {
        var fs = try zigpot.FileStore.init(io, d);
        defer fs.deinit();
        return zigpot.Index.load(allocator, fs.store(), addr, 256);
    }
    return demoIndex(allocator);
}

/// For each node (pre-order DFS), whether it is the last child of its
/// parent — i.e. no later sibling exists before we pop above its depth.
fn computeIsLast(nodes: []const TreeNode, is_last: []bool) void {
    for (nodes, 0..) |node, i| {
        const d = node.depth;
        var last = true;
        var j = i + 1;
        while (j < nodes.len) : (j += 1) {
            if (nodes[j].depth < d) break; // left this subtree → last sibling
            if (nodes[j].depth == d) {
                last = false; // another sibling at the same depth
                break;
            }
        }
        is_last[i] = last;
    }
}

fn appendStr(buf: []u8, n: *usize, s: []const u8) void {
    if (n.* + s.len <= buf.len) {
        @memcpy(buf[n.* .. n.* + s.len], s);
        n.* += s.len;
    }
}

/// Render node `i` as a tree row with branch glyphs. Maintains `last_flags`
/// (the last-child status of the current DFS path) and must be called in
/// pre-order. Allocates a program-lifetime string from `gpa`.
fn buildTreeLine(
    gpa: std.mem.Allocator,
    nodes: []const TreeNode,
    is_last: []const bool,
    last_flags: []bool,
    i: usize,
) []const u8 {
    const node = nodes[i];
    const d = node.depth;
    if (d < last_flags.len) last_flags[d] = is_last[i];

    var pbuf: [2048]u8 = undefined;
    var pn: usize = 0;

    // Vertical guides for ancestors at depths 1..d-1: draw "│" if that
    // ancestor still has siblings below it, else blank.
    var a: usize = 1;
    while (a + 1 <= d) : (a += 1) {
        const cont = a < last_flags.len and !last_flags[a];
        appendStr(&pbuf, &pn, if (cont) "\u{2502}  " else "   ");
    }
    // This node's connector (the root, depth 0, has none).
    if (d >= 1) appendStr(&pbuf, &pn, if (is_last[i]) "\u{2514}\u{2500} " else "\u{251C}\u{2500} ");

    const prefix = pbuf[0..pn];
    return if (node.po) |po|
        std.fmt.allocPrint(gpa, "{s}[po {d}] {s}", .{ prefix, po, node.key }) catch node.key
    else
        std.fmt.allocPrint(gpa, "{s}{s}", .{ prefix, node.key }) catch node.key;
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

    // Precompute display lines once — the trie is static, so only the
    // highlight changes between frames. (Entries and trie nodes share the
    // same pre-order, so index `i` refers to the same node in both.)
    // Allocated from an arena freed at exit — the lines outlive every
    // frame, and the arena reclaims them all at once (no per-line frees).
    var line_arena = std.heap.ArenaAllocator.init(allocator);
    defer line_arena.deinit();
    const la = line_arena.allocator();

    const is_last = try la.alloc(bool, nodes.len);
    computeIsLast(nodes, is_last);
    var last_flags = [_]bool{false} ** 256;
    const tree_lines = try la.alloc([]const u8, nodes.len);
    for (0..nodes.len) |i| tree_lines[i] = buildTreeLine(la, nodes, is_last, &last_flags, i);
    const kv_lines = try la.alloc([]const u8, rows.len);
    for (rows, 0..) |r, i| kv_lines[i] = std.fmt.allocPrint(la, "{s} = {s}", .{ r.key, r.value }) catch r.key;

    // --dump: print entries + trie as text and exit (no terminal needed).
    {
        var it = std.process.Args.Iterator.init(init.minimal.args);
        while (it.next()) |a| {
            if (std.mem.eql(u8, a, "--dump")) {
                var dbuf: [4096]u8 = undefined;
                var dfw = std.Io.File.stdout().writer(io, &dbuf);
                const w = &dfw.interface;
                try w.print("entries ({d}):\n", .{rows.len});
                for (kv_lines) |l| try w.print("  {s}\n", .{l});
                try w.print("\nproximity-order trie ({d} nodes):\n", .{nodes.len});
                for (tree_lines) |l| try w.print("  {s}\n", .{l});
                try w.flush();
                return;
            }
        }
    }

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
    var scroll: usize = 0; // index of the first visible row
    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('q', .{}) or key.matches(vaxis.Key.escape, .{})) break;
                if (key.matches('j', .{}) and selected + 1 < rows.len) selected += 1;
                if (key.matches('k', .{}) and selected > 0) selected -= 1;
                if (key.matches('g', .{})) selected = 0;
                if (key.matches('G', .{}) and rows.len > 0) selected = rows.len - 1;
            },
            .winsize => |ws| try vx.resize(allocator, writer, ws),
        }

        const win = vx.window();
        win.clear();

        // Scroll so the selection stays visible. Each pane shows its
        // height minus the header row; the title takes the top line.
        const visible: usize = if (win.height > 2) win.height - 2 else 1;
        if (selected < scroll) scroll = selected;
        if (selected >= scroll + visible) scroll = selected + 1 - visible;
        const end = @min(scroll + visible, rows.len);

        var titlebuf: [160]u8 = undefined;
        const pos = if (rows.len == 0) 0 else selected + 1;
        const title = std.fmt.bufPrint(&titlebuf, "zigpot-tui — POT browser   [{d}/{d}]   (j/k/g/G move · q quit)", .{ pos, rows.len }) catch "zigpot-tui — POT browser";
        _ = win.printSegment(.{ .text = title, .style = .{ .bold = true } }, .{ .row_offset = 0 });

        const half = win.width / 2;
        const left = win.child(.{ .x_off = 0, .y_off = 1, .width = half, .height = win.height -| 1 });
        const right = win.child(.{ .x_off = @intCast(half), .y_off = 1, .width = win.width -| half, .height = win.height -| 1 });

        _ = left.printSegment(.{ .text = "entries", .style = .{ .bold = true } }, .{ .row_offset = 0 });
        _ = right.printSegment(.{ .text = "proximity-order trie", .style = .{ .bold = true } }, .{ .row_offset = 0 });

        var r = scroll;
        while (r < end) : (r += 1) {
            const style: vaxis.Style = if (r == selected) .{ .reverse = true } else .{};
            const ro: u16 = @intCast(r - scroll + 1);
            _ = left.printSegment(.{ .text = kv_lines[r], .style = style }, .{ .row_offset = ro, .wrap = .none });
            _ = right.printSegment(.{ .text = tree_lines[r], .style = style }, .{ .row_offset = ro, .wrap = .none });
        }

        try vx.render(writer);
    }
}
