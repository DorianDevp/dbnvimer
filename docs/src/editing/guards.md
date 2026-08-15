# Guards

Three of them, and they are on by default.

## A write that touches more than one row shows you which

Before running an `UPDATE` or `DELETE`, DBClient rewrites it into the
equivalent `SELECT` and shows you the rows.

```text
update shop.orders set status = 'closed' where customer_id = 7

  would change 14 rows

  id  │ reference    │ status
  ────┼──────────────┼────────
   12 │ SO-2026-1050 │ open
   19 │ SO-2026-1057 │ open
  ...
```

The rewrite is parenthesis-depth aware, and it declines rather than guessing
on a multi-table delete — showing you different rows than the statement would
touch is worse than showing none.

Set `guard.preview_writes_over` to a larger number, or `false` to turn it off.

## An unfiltered write asks twice

`delete from orders` with no `WHERE` is almost always a mistake. Turn it off
with `guard.confirm_unfiltered_writes = false`.

## Destructive statements want the name typed

On a connection whose access is `write`, `DROP TABLE orders` asks you to type
`orders`. Which connections do this is `guard.typed_confirmation_for`.

## The guard you cannot argue with

[Access levels](../config/access.md) are enforced in the Rust core rather than
in the interface. A `read` connection refuses a write before it leaves your
machine, and nothing in the front end can talk its way past it.
