# Saved queries

`gs` in a query buffer saves it. `<leader>df` browses what you have saved.

They are plain `.sql` files with a comment header:

```sql
-- name: orders awaiting payment
-- description: everything stuck before dispatch, oldest first
-- @conn: dev

select o.reference, c.name, o.created_at
from orders o
join customers c on c.id = o.customer_id
where o.status_id = 1
order by o.created_at;
```

## Two places

| Scope | Where | Commits with the repository |
|---|---|---|
| project | `.dbclient/queries/` | yes |
| global | `stdpath("data")/dbclient/queries/` | no |

Project queries are listed first. `p` in the browser moves one between the
two, which is how a query you wrote for yourself becomes a query the team has.

## The browser

| Key | Effect |
|---|---|
| `<CR>` `o` | open it |
| `r` | run it without opening it |
| `n` | write a new one |
| `e` | rename |
| `x` | delete |
| `y` | yank the SQL |
| `p` | move between project and global |
| `gr` | rescan the directories |

Because they are files, they diff, they merge, and `:vimgrep` finds them.
