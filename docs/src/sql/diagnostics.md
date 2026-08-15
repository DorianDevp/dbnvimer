# Diagnostics

Two kinds appear as you type, both as ordinary `vim.diagnostic` entries.

## The static lint

Runs in the core on the text alone. Catches the things that are wrong
regardless of what the database contains.

```sql
select * from orders where status = 'open' or status = 'new' and id > 5
                                                             ~~~~~~~~~~
-- mixing and/or without parentheses: `and` binds tighter than `or`
```

## The server's own opinion

Each statement is `PREPARE`d and thrown away. Nothing executes, and you get
real name and type errors before you run anything.

```sql
select customer_nmae from orders
       ~~~~~~~~~~~~~
-- there is no column `customer_nmae` — did you mean `customer_name`?
```

This is why a misspelled column surfaces while you type rather than when you
press run.

## Completion

Tables, columns and routines, from the metadata cache, scoped to what is in
the `FROM` clause where that can be worked out. Registers itself with
nvim-cmp when nvim-cmp is present.

## Hover

`K` on an identifier describes it: the column's type, whether it is nullable,
its default, whether it is a key, and what it references.
