# Results and records

What a query returned, and what a row is connected to.

## Result buffer

| Key | Does |
|---|---|
| `K` | inspect the full cell value |
| `gs` | statistics for this column |
| `gt` | transposed view of this row |
| `gy` | yank cell, row or selection as... |
| `ge` | export: formats, encodings, partitioning |
| `gg` | chart these rows |
| `gS` | save this result set as a snapshot |
| `gV` | compare with a saved snapshot |
| `g!` | pipe the rows through a shell command |
| `]c` | next cell |
| `[c` | previous cell |
| `]r` | next row |
| `[r` | previous row |
| `q` | close the result buffer |
| `g?` | show this help |

## Record

| Key | Does |
|---|---|
| `<CR>` | open this table, filtered to these rows |
| `gu` | reveal masked values |
| `gr` | fetch the record again |
| `q` | close the record |
| `g?` | show this help |

