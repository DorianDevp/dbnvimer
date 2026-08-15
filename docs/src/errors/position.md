# Where an error lands

On the token, as a real diagnostic. `]d` jumps to it.

```sql
select * FORM orders
         ~~~~
```

## Getting the position

Each backend reports a different amount, and each is handled.

| Backend | What it reports | What is done with it |
|---|---|---|
| PostgreSQL | a character offset | used directly |
| MySQL / MariaDB | the fragment it choked on, and a line | the offset is recovered by searching for the fragment, starting at that line |
| SQLite | a byte offset | converted to characters |

Searching from the reported line matters: `near 'from'` in a statement with
two subqueries would otherwise put the caret on the first one.

## In a script

An error in statement seven maps back to the line *in your file*, not to line
one of the statement. The splitter reports each statement's byte offset, and
that composes with the position the server gave.

```text
migrations/0042.sql

  6 │ select * FORM orders;
             ~~~~
```

The findings also go to the quickfix list, so `]q` walks them.

## Characters, not bytes

The position the server reports counts characters; Neovim's column counts
bytes. Every accented character before the error moves them apart. They are
converted, which is why the caret lands on the token in a table full of
`Kraków` rather than two columns to its left.
