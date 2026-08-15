# Schema as files

`<leader>dD`. One `.sql` file per table, view and routine.

```text
db/schema/
  shop/
    tables/
      customers.sql
      orders.sql
      order_items.sql
    views/
      active_customers.sql
    routines/
      recalculate_totals.sql
```

Once the schema is files, the editor's own tools work on it. None of this
needed writing:

```vim
:vimgrep /customer_id/ db/schema/**
:argdo %s/old_schema/new_schema/g
:Telescope find_files cwd=db/schema
```

*Which routine touches this column* becomes a `:vimgrep`.

## No header, no timestamp

Deliberately. A generated-on line would make every dump a diff, which would
make the diffs worthless. Two dumps of an unchanged schema are byte-identical.

Commit the tree and `git diff` shows what a migration actually did to the
database, rather than what the migration file claims it did.

## Pruning

Files for objects that no longer exist are removed, so a dropped table
disappears from the tree. Only files the dump owns are candidates; a
hand-written file elsewhere is never touched. `:DBClientSchemaDump!` keeps
stale files.

## Speed

On a 66-table schema: 66 files in about 23 milliseconds, and a second run
writes nothing.
