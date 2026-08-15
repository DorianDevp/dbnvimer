# Plans

`<leader>de` explains the statement at the cursor. `<leader>dE` runs it and
measures.

```text
Aggregate  (cost=3582.00..3582.01 rows=1)
└─ Seq Scan on orders  (cost=0.00..3582.00 rows=1 width=0)
     Filter: (reference = 'SO-2026-1042')
     Rows Removed by Filter: 199 999          ← 200 000 read to return 1
```

A folded tree rather than a wall of text.

| Key | Effect |
|---|---|
| `<CR>` | fold or unfold this node |
| `gj` | jump to the most expensive node |
| `ga` | switch to `EXPLAIN ANALYZE` |
| `gr` | run it again |

## What is highlighted

Nodes are coloured by their share of the total cost, so the expensive one is
visible without reading. And where the planner's row estimate was badly wrong,
that node is marked:

```text
└─ Nested Loop  (rows=12 actual=48 210)     ← estimate off by 4000×
```

That mark is usually the answer. A planner that expects twelve rows picks a
plan that is catastrophic for forty-eight thousand, and the fix is nearly
always statistics rather than the query.
