# Notebooks

`<leader>dn` turns the markdown buffer you are in into a notebook. `sql`
fenced blocks become runnable, and results are written back underneath them.

````markdown
# Why did dispatch slow down in March?

Orders per status, before and after:

```sql
select s.name, count(*)
from orders o
join order_status s on s.id = o.status_id
where o.created_at >= '2026-03-01'
group by s.name;
```

| name             | count |
|------------------|-------|
| awaiting payment |   412 |
| picking          |    88 |
| dispatched       |   704 |

Most of it is stuck before payment.
````

`<CR>` on a block runs it. `<leader>dQ` runs every block in order.

## Why this is useful

The document is the analysis *and* the record of it. It commits, it diffs,
someone else can re-run it in a month and see whether the answer changed, and
nothing is trapped in a screenshot.

Results are written as markdown tables, so the file stays readable to anyone
who never opens Neovim.
