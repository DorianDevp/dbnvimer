# Install

With any plugin manager:

```lua
{
  "you/dbclient.nvim",
  config = function()
    require("dbclient").setup({})
  end,
}
```

`setup({})` with no arguments is a complete configuration. Everything has a
default, and connections are found in the project without being told about.

## The core binary

The database work happens in a Rust daemon rather than in Lua. A binary is
bundled for Linux, macOS and Windows on x86-64 and aarch64, and the plugin
picks the right one.

If none matches your platform, build it once:

```console
$ cd rust/dbclient-core
$ cargo build --release
```

The plugin looks for a locally built binary first, then the bundled one, then
`dbclient-core` on `$PATH`.

## Checking it works

```vim
:checkhealth dbclient
```

If the daemon ever gets into a strange state, `:DBClientRestart` starts a new
one. Open connections are closed cleanly first.
