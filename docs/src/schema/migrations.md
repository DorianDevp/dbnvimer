# Migration lock review

`<leader>dM` on a migration file.

```text
0042_add_priority.sql   3 statements   MariaDB 10.2

1 blocking   2 caution   0 note

!!  1. rewrites the whole table   on orders  (1 200 000 rows)
      ALTER TABLE orders ADD priority INT DEFAULT 0 NOT NULL
      lock: writes blocked for the rewrite
      MariaDB 10.2 rewrites the table to add a column with a default,
      holding a metadata lock throughout. MySQL 8.0 and MariaDB 10.3 do
      this instantly; on this server, add the column without a default
      and backfill in batches.

 !  2. building the index may block writes   on orders  (1 200 000 rows)
      CREATE INDEX idx_priority ON orders (priority)
      Say `ALGORITHM=INPLACE, LOCK=NONE` so it fails loudly instead of
      quietly locking.
```

## Why it needs a connection

Because the answer depends on the server. The same statement:

| Server | Verdict |
|---|---|
| MariaDB 10.2 | rewrites the table, writes blocked |
| MariaDB 10.3+, MySQL 8.0+ | instant |
| PostgreSQL 10 | rewrites the table under `ACCESS EXCLUSIVE` |
| PostgreSQL 11+ | catalogue only |

Getting that backwards is the difference between a deployment nobody notices
and forty seconds of blocked writes. Row counts come from the same server, so
"rewrites the table" becomes "rewrites 1.2 million rows".

## What it reads

Plain `.sql`, and the frameworks that hide SQL in a string argument — Doctrine,
Alembic, Rails, golang-migrate. It matches on the call that takes the SQL
rather than on the framework, so a project it has never seen still works.

Only the forward direction. A `down()` full of `DROP TABLE` is a rollback that
never runs on a deployment, and reporting it as irreversible is how a tool
teaches people to ignore it.

## What it will not tell you

That a table created earlier in the same migration is empty — it works that
out and says nothing, because an `ADD CONSTRAINT` on a table that was created
three statements ago cannot block anything.
