# The workload

`<leader>dW`. Every statement the *server* has run, aggregated by it.

```text
dev   204 statements   via performance_schema

     calls      total    average  statement
    84 122     57 min      41 ms  select … from orders join customers …
       312      4 min     890 ms  select count(*) from audit_log …
    12 004       36 s       3 ms  select … from customers where email = ?
```

Ranked by **total** time, not average. The statement that takes four
milliseconds eighty thousand times an hour is the problem, and no slow-query
threshold catches it.

## Where it comes from

| Backend | Source |
|---|---|
| PostgreSQL | `pg_stat_statements` |
| MySQL, MariaDB | `performance_schema.events_statements_summary_by_digest` |

## What is marked

A statement that examines far more rows than it returns is coloured. That is
the shape of a missing index, and it is worth seeing from across the room.

## Opening one

`<CR>` puts the statement in a query buffer rather than explaining it. A
digest has had its literals stripped, so `where id = ?` would either fail to
parse or, worse, plan for a value nobody used. Put the parameters back and
explain it yourself.

## If there is nothing to show

MariaDB ships with `performance_schema` off, and PostgreSQL needs
`pg_stat_statements` loaded at startup. Rather than an empty table you get the
reason and the exact steps, including which of them need a restart.

```text
dev is not keeping statement statistics

  performance_schema is off

  MariaDB ships with it off, which is why a default install has nothing here.
  Add `performance_schema = ON` to my.cnf and restart; it cannot be changed
  at runtime. It costs some memory and a few percent of throughput.

  Until then, `<leader>dl` lists the statements DBClient itself ran.
```
