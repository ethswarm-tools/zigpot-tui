# zigpot-tui

A terminal UI for [zigpot](https://github.com/ethswarm-tools/zigpot) — a
browser and **proximity-order-trie visualizer** for a content-addressed
key/value store on Swarm, built on
[libvaxis](https://github.com/rockorager/libvaxis).

Kept a **separate binary** from zigpot so the core library/CLI stays
zero-dependency; this is the only part that pulls in libvaxis.

## What it shows

- **Left pane** — the key/value entries; `j` / `k` move the selection.
- **Right pane** — the POT *structure*: each node indented by tree depth
  and labelled with the proximity order it branches at (`[po N]`). The
  node holding the selected key is highlighted, so you can see where any
  key sits in the trie.
- `q` / `Esc` quits.

## Usage

```sh
zig build run                                    # a built-in demo index
zig build run -- --bee <url>  --root <hex>       # load from a running Bee node
zig build run -- --dir <path> --root <hex>       # load a local zigpot store
```

`--root` is the root chunk address (the handle printed by `zigpot put`/`del`).
`--bee` reads the chunks from a Bee node over HTTP (read-only — no postage
batch needed); `--dir` reads them from a local store directory. Add `--dump`
to print the entries + trie as text instead of opening the TUI. Requires a
real terminal to run interactively (it opens the tty).

## Requirements

Zig 0.16.x. Depends on zigpot (v0.2.0+, for `walkStructure`) and
libvaxis 0.6, both fetched by `zig build`.
