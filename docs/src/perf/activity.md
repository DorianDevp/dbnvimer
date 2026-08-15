# Activity and locks

## What is running now

`<leader>da`.

```text
pid    user   state              elapsed  statement
────────────────────────────────────────────────────────────────
1842   app    active               4.2 s  update orders set status_id = …
1855   app    idle in transaction  92 s
1901   app    active               0.1 s  select … from customers …
```

| Key | Effect |
|---|---|
| `x` | cancel the statement under the cursor |
| `X` | terminate that session |
| `gt` | toggle auto refresh |
| `gr` | refresh now |

`idle in transaction` for ninety-two seconds is the row to look at. It is
holding locks and doing nothing.

## Who is blocking whom

`<leader>dL` draws it as a tree.

```text
1842  update orders set status_id = 2 where id = 12
  └─ 1901  waiting 38 s   select … from orders where id = 12 for update
       └─ 1955  waiting 12 s   update orders set note = … where id = 12
```

The root is what to cancel.

## Cancelling your own

`<leader>dk`. It cancels on the server, not just in the editor. The daemon
holds a cancellation handle per session, so the query actually stops.

## Watching something change

`<leader>dw` re-runs a statement on a timer and redraws the result, which is
the queue-length-over-time view without writing a loop. `<leader>dp` times a
statement over several runs and reports the spread.
