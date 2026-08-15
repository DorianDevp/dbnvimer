# Quick query

`<leader>d<CR>`. A tab, an empty SQL buffer, and nothing else.

```sql
select status_id, count(*)
from orders
group by status_id;
```

`<CR>` runs the statement under the cursor. Results appear below. `q` closes
the tab.

| Key | Effect |
|---|---|
| `<CR>` `<C-CR>` | run the statement under the cursor |
| `<leader>dQ` | run every statement |
| `gs` | save this query |
| `gf` | open a saved one |
| `gc` | run it against a different connection |
| `q` | close the tab |

`gc` is the one worth remembering: the same statement against staging and
production without retyping it or switching connections.

For anything you will keep, use [the query buffer](buffer.md) instead — it
sits beside your data rather than taking over the screen.
