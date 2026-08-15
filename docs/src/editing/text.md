# Cells are text

The data buffer is modifiable. Change a cell the way you change any text.

```text
ciw     change the word under the cursor
cic     change the whole cell
:%s/pending/awaiting/g      across every row on the page
```

Nothing has been sent. The buffer is modified, `u` undoes it, and closing
without writing throws it away.

## What identifies a row

Not its position. Each row carries an extmark, and the change set is
reconciled against the primary key: the key decides which buffer line is
which snapshot row, and marks only fill in for rows whose key you edited.

That is why a line-wise edit — `:m`, a block paste, deleting three rows and
retyping them — still writes to the rows you meant.

## What cannot be edited in place

A value the grid truncated. It ends in `…`, the buffer does not hold the rest,
and writing it back would lose it. `:w` refuses and names the column; use `K`
and edit it there.

## A table with no primary key

Refuses to be written at all. There is no way to address a row, so any
`UPDATE` would be a guess. The buffer still opens and still reads.
