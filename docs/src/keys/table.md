# Table view

The data buffer. It is editable, so only navigation and inspection are mapped; nothing shadows an editing key.

## Data buffer

| Key | Does |
|---|---|
| `K` | inspect the full cell value |
| `gK` | the whole record: everything related to this row |
| `gd` | follow the foreign key under the cursor |
| `gU` | open the rows that reference this one |
| `gu` | list referencing rows in the quickfix |
| `g[` | back along the navigation trail |
| `g]` | forward along the navigation trail |
| `gb` | jump to any point on the trail |
| `gs` | statistics for this column |
| `gS` | sort by this column |
| `gf` | filter rows with a WHERE expression |
| `gF` | clear the filter and sort |
| `gt` | transposed view of this row |
| `gh` | hide this column |
| `gH` | show all columns |
| `gn` | set this cell to SQL NULL |
| `gy` | yank cell, row or selection as... |
| `gp` | duplicate this row as a new INSERT |
| `gx` | extract this row plus everything it needs |
| `gr` | reload from the database |
| `gD` | open the DDL for this table |
| `gG` | generate code from this table |
| `gI` | import a CSV into this table |
| `ge` | export this table |
| `]c` | next cell |
| `[c` | previous cell |
| `]r` | next row |
| `[r` | previous row |
| `]p` | next page |
| `[p` | previous page |
| `g?` | show this help |

## Text objects

| Key | Does |
|---|---|
| `ic` | inner cell |
| `ac` | a cell, including its separator |
| `ir` | inner row |
| `ar` | a row, including the newline |
| `iC` | inner column, every row of it |
| `aC` | a column, including its separator |

