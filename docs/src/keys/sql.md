# SQL buffers

The query buffer, the quick-query tab, and the saved-query browser.

## Query buffer

| Key | Does |
|---|---|
| `<C-CR>` | run the statement at the cursor |
| `<leader>dq` | run the statement or selection |
| `<leader>dQ` | run every statement in the buffer |
| `<leader>de` | explain the statement |
| `<leader>dE` | explain analyze the statement |
| `<leader>dR` | show which rows this would change |
| `K` | describe the table or column under the cursor |
| `gd` | open the DDL for the table under the cursor |
| `gs` | save this query |
| `gf` | open a saved query |
| `g?` | show this help |

## Quick query

| Key | Does |
|---|---|
| `<CR>` | run the statement under the cursor |
| `<C-CR>` | run it |
| `<leader>dQ` | run every statement |
| `gs` | save this query |
| `gf` | open a saved query |
| `gc` | run against another connection |
| `q` | close the tab |
| `g?` | show this help |

## Saved queries

| Key | Does |
|---|---|
| `<CR>` | open the query |
| `o` | open the query |
| `r` | run it without opening it |
| `n` | write a new query |
| `e` | rename it |
| `x` | delete it |
| `y` | yank the SQL |
| `p` | move between project and global |
| `gr` | rescan the query directories |
| `q` | close the browser |
| `g?` | show this help |

