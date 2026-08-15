# Keybindings

Keys differ by context. `g?` in any DBClient buffer lists that buffer's.

| Page | Where you are |
|---|---|
| [Anywhere](anywhere.md) | any buffer, under the leader prefix |
| [Sidebar](sidebar.md) | the object tree |
| [Table view](table.md) | a table's data |
| [SQL buffers](sql.md) | the query buffer, the quick-query tab, saved queries |
| [Results and records](results.md) | a result set, or a record page |
| [Other panels](panels.md) | plans, activity, DDL, export, connections |

## The ones to learn first

| Key | Does |
|---|---|
| `<leader>dd` | open the sidebar |
| `<CR>` | connect, expand, or open, whichever the node under the cursor needs |
| `g?` | the keys for this buffer |
| `q` | close this panel |
| `:w` | commit your edits |
| `<leader>d!` | explain the last error |

## Changing the prefix

Global mappings sit under `g:dbclient_leader`, `<leader>d` by default. Set it
before `setup()` and everything follows, including `g?` and this chapter.

```lua
vim.g.dbclient_leader = "<leader>b"
require("dbclient").setup({})
```

Every mapping also has a command behind it, so nothing is reachable only by
keystroke. See [Commands](../commands.md).

