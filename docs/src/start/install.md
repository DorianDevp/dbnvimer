# Install

```lua
{
  "you/dbclient.nvim",
  config = function()
    require("dbclient").setup({})
  end,
}
```

`setup({})` with no arguments is a complete configuration.

## The core binary

A Rust daemon does the database work. Binaries are bundled for Linux, macOS
and Windows on x86-64 and aarch64. If none matches, build it once:

```console
$ cd rust/dbclient-core
$ cargo build --release
```

The plugin prefers a locally built binary, then the bundled one, then
`dbclient-core` on `$PATH`.

## Check

```vim
:checkhealth dbclient
```

Six sections: environment, core binary, protocol version, whether the daemon
answers, every connection with what is wrong with it, and where things are
stored.

`:DBClientRestart` starts a fresh daemon if one gets stuck.

Then press `<leader>dd`.
