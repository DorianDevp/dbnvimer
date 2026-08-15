# Finding your way

## `g?`

In any DBClient buffer, `g?` lists that buffer's keys.

```text
Data buffer

  K       inspect the full cell value
  gK      the whole record: everything related to this row
  gd      follow the foreign key under the cursor
  gU      open the rows that reference this one
  ...
```

It is generated from the same table that registers the mappings, so it cannot
disagree with what is actually bound. `:DBClientHelp` shows every group at
once.

## The leader prefix

Global mappings sit under `g:dbclient_leader`, which defaults to `<leader>d`.
Set it before `setup()` and everything follows, including the generated help
and this book's key reference.

```lua
vim.g.dbclient_leader = "<leader>b"
require("dbclient").setup({})
```

## Everything has a command

Every mapping has a `:DBClient…` command behind it, so nothing is reachable
only by keystroke. See [Commands](../commands.md).
