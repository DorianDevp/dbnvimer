# Transactions

| Key | Effect |
|---|---|
| `<leader>db` | begin |
| `<leader>dm` | commit |
| `<leader>dr` | roll back |

While a transaction is open the winbar says so, in a colour you will not
miss, and the sidebar marks the connection.

```text
 dev  shop  ● IN TRANSACTION
```

## What is inside one

Everything that connection runs until you commit or roll back: statements you
type, and writes from the data buffer. A data buffer `:w` inside an open
transaction joins it rather than opening its own.

## The one that catches people out

On PostgreSQL, an error inside a transaction aborts it: every subsequent
statement fails with *"current transaction is aborted"* until the transaction
ends. The error panel recognises this and offers `r` to roll back, so you can
carry on without looking up the incantation.

## Never leaving one open

Closing a connection rolls back an open transaction. So does quitting Neovim.
The daemon is torn down cleanly on `VimLeavePre`, which also closes any
replication slot [change streaming](../perf/activity.md) opened.

## Trying something you do not want to keep

`access = "sandbox"` on a connection wraps every write in a transaction and
always rolls it back. See [Access levels](../config/access.md).
