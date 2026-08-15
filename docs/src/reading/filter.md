# Filtering and sorting

`gf`, then a `WHERE` expression. The condition only:

```text
filter ▸ status_id = 3 and created_at > '2026-03-01'
```

It runs on the server, so it applies to the whole table rather than the page
in front of you. `gF` clears the filter and the sort.

The filter is part of where you are. Following a key sets one, and walking
[the trail](../relations/trail.md) back restores it.

## Sorting

`gS` sorts by the column under the cursor, again to reverse.

Previews are ordered by primary key by default. Without an `ORDER BY` the
server may return rows in a different order each time, which makes "page 2"
meaningless.

## Narrowing the view

`gh` hides the column under the cursor, `gH` brings them all back, `gt`
transposes the row for a table with fifty columns.
