# Moving around

## Cells, rows, pages

| Key | Moves to |
|---|---|
| `]c` `[c` | next and previous cell |
| `]r` `[r` | next and previous row |
| `]p` `[p` | next and previous page |

A page is `ui.preview_limit` rows, 200 by default.

`w` and `b` step between cells rather than words, because in a grid that is
what "next thing" means.

## Text objects

The grid has three nouns, so every operator you know works on it.

| Object | Selects |
|---|---|
| `ic` `ac` | inner cell; a cell including its separator |
| `ir` `ar` | inner row; a row including the newline |
| `iC` `aC` | inner column, every row of it, blockwise |

So:

```text
yic     yank this cell
cic     change this cell
yiC     yank this column, all 200 rows of it
daC     delete this column and its separator
```

And `.` repeats whatever you did, because these are ordinary operators on
ordinary text.

## The header stays put

The header row is pinned to the winbar while you scroll, so you always know
which column you are in. Turn it off with `ui.sticky_header = false`.
