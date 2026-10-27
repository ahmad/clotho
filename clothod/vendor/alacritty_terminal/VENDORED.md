# alacritty_terminal 0.26.0, patched

Vendored from crates.io (`src/`, `Cargo.toml` without the `ref` test target, license) and used via
`[patch.crates-io]` in `clothod/Cargo.toml`. One change:

- `src/grid/storage.rs`: `MAX_CACHE_SIZE` 1_000 → 100. Scrollback storage grows in chunks of this
  many rows, each allocated and filled at once. With 1_000, any pane that scrolled past one screen
  cost ~3 MB at 120 columns in clothod's VT; with 100, an idle pane with 100 lines of history costs
  ~0.8 MB (measured: 40 panes on Linux, serve RSS 4.4 → 0.8 MB per pane). Full history costs the
  same either way.

To move to a newer alacritty_terminal: copy its `src/` and `Cargo.toml` here, reapply the change,
and bump the version in the workspace dependency. Or drop the patch if upstream makes the
chunk size configurable.
