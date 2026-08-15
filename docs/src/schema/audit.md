# The audit

`<leader>dA`, or `gA` on a schema in the sidebar.

```text
shop — 15 findings

  [hint] order_items    IDX_A7AD6D71 (order_id) is a prefix of
                        PRIMARY (order_id, product_id)
  [warn] shipments      customer_id references customers.id but has no index
  [warn] audit_log      no primary key: rows cannot be addressed individually
  [warn] invoices       total is decimal(10,2) but orders.total is decimal(12,2)
  [hint] customers      deleted_at is NULL in every row
```

Findings go to the quickfix list, so `]q` walks them, and each one carries the
SQL that fixes it.

## What it looks for

| Finding | Why it matters |
|---|---|
| no primary key | rows cannot be addressed, so the data buffer cannot write |
| unindexed foreign key | every parent delete scans the child table |
| redundant index | one whose columns are a prefix of another's: pure write cost |
| foreign key type mismatch | silently prevents index use on the join |
| always null, never null, single value | a column that is not doing what it claims |

## Redundant indexes are the common one

An ORM adds a single-column index for every relation. On a join table whose
primary key is `(order_id, product_id)`, the separate index on `order_id` is
dead weight — the primary key already starts with it.

The check is precise about this: the index on the *second* column is not a
prefix of anything and is genuinely needed for the reverse lookup, so it is
not flagged.

A unique index is never reported as redundant even when it is a prefix,
because it is enforcing something rather than speeding something up.
