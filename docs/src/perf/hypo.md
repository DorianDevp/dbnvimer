# Hypothetical indexes

`<leader>dI`. Would this index help?

On PostgreSQL with [HypoPG](https://hypopg.readthedocs.io/) installed, the
index is created hypothetically — it exists only in the planner's imagination,
costs nothing to make, and is gone when the session ends.

```text
create index on orders (customer_id, created_at)

  before                              after
  Seq Scan on orders                  Index Scan using <hypo>
  cost 3582.00                        cost 8.44
                                      424× cheaper
```

Nothing is written. No lock is taken. The table is not touched.

## Without HypoPG

It says so, and what to install:

```text
this needs the hypopg extension

  create extension hypopg;

  It plans against indexes that do not exist, so nothing is built and
  nothing is locked. Available in most PostgreSQL distributions.
```

## On MySQL and MariaDB

There is no equivalent — the optimiser cannot be told about an index that does
not exist. The honest answer is to build it on a copy, and
[the audit](../schema/audit.md) will at least tell you which foreign keys have
no index at all, which is the common case.
