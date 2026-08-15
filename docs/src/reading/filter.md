# Filtering and sorting

## Filter

`gf`, then a `WHERE` expression — the condition only, no keyword.

```text
filter ▸ status_id = 3 and created_at > '2026-03-01'
```

It runs on the server, so it applies to the whole table rather than to the
page in front of you. `gF` clears both the filter and the sort.

The filter is part of where you are: following a key sets one, and walking
[the trail](../relations/trail.md) back restores the one you had.

## Sort

`gS` on a column sorts by it; press it again to reverse. Previews are ordered
by the primary key by default, so paging is stable — without an `ORDER BY`
the server is free to return rows in a different order each time, which makes
"page 2" meaningless.

## Hide what you are not reading

| Key | Effect |
|---|---|
| `gh` | hide the column under the cursor |
| `gH` | show them all again |
| `gt` | transpose this row — one field per line |

`gt` is the answer to a table with fifty columns.
