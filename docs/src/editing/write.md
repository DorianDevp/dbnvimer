# Writing

`:w`.

```text
1 change

  update shop.orders  where id = 1
    status  new → open

y apply   n cancel
```

You get the change set as a summary and as the exact SQL. Confirm and it runs
in one transaction.

## Optimistic concurrency

Every write carries the values it expects to find:

```sql
update shop.orders
   set status = 'open'
 where id = 1
   and status = 'new'
```

If someone changed the row between your fetch and your write, nothing
matches, and the write fails and says so rather than quietly overwriting
their work.

## Several changes at once

Edit ten cells across five rows and `:w` once. They go in a single
transaction: all of them or none.

```text
5 changes

  update shop.orders  where id = 1
    status  new → open
  update shop.orders  where id = 4
    note   NULL → called the customer
  insert shop.orders
    reference SO-2026-1400, customer_id 7
  delete shop.orders  where id = 9
  ...
```

## What was actually run

`<leader>dl` is the statement log for this session: everything DBClient sent,
with timings and row counts.
