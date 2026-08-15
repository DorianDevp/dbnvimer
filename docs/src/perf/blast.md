# Blast radius

`<leader>dR` on an `UPDATE` or `DELETE` shows you the rows it would touch,
without touching them.

```sql
delete from orders where created_at < '2020-01-01'
```

```text
would delete 4 118 rows

id  │ reference    │ created_at
────┼──────────────┼─────────────────────
  3 │ SO-2019-0003 │ 2019-01-04 10:22:00
  7 │ SO-2019-0007 │ 2019-01-11 14:05:00
...
```

## How

The statement is rewritten into the equivalent `SELECT`, in the core:

- for a `DELETE`, everything after the top-level `from` is already a valid
  source
- for an `UPDATE`, the table between `update` and `set`, plus the `where` at
  depth zero

Parenthesis-depth aware, and comments and string literals are not searched for
keywords.

## When it declines

A multi-table delete has no single equivalent `SELECT`. Rather than showing
you rows from one of the tables and letting you believe that is the answer, it
says it cannot preview this one.

## Automatically

The same rewrite runs before any data-buffer write that would touch more than
`guard.preview_writes_over` rows. See [Guards](../editing/guards.md).
