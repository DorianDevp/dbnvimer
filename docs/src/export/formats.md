# Formats

| Format | Notes |
|---|---|
| `csv` | any delimiter, any quoting rule |
| `tsv` | tabs |
| `json` | one array |
| `jsonl` | one object per line |
| `sql` | `INSERT` statements against the source table |
| `markdown` | a table you can paste into a ticket |
| `html` | a standalone page |
| `xml` | |
| `xlsx` | a real workbook, numbers stay numbers |
| `table` | the aligned grid, as you see it |

## Presets

`gp` in the export editor.

| Preset | What it sets |
|---|---|
| `csv_strict` | RFC 4180, the interchange default |
| `excel` | semicolon, UTF-8 BOM, comma decimal separator |
| `postgres_copy` | reads back with `\copy` |
| `mysql_load` | backslash escapes and `\N` |
| `spreadsheet` | XLSX, header frozen |
| `report` | Markdown |
| `backup` | batched inserts in one transaction |
| `archive` | gzipped chunks with a manifest |
| `share` | redacted, no manifest, safe to send on |

The `excel` preset sets all three of its settings together, because getting
one of them wrong is what produces a file that looks fine and imports wrong.

## NULL versus empty

The rule that most tools get wrong:

```csv
id,name,note
1,"Alice",
2,"Bob","",
```

`NULL` is written unquoted even when everything else is quoted. An empty
quoted field means an empty string; nothing at all means `NULL`. So a table
survives the round trip.

`null_as` changes what is written; the distinction is kept either way.

## Partitioning and redaction

`partition_rows` splits by count; `partition_by` splits by the value of a
column, one file per value. `redact` masks named columns before writing,
which is what `share` uses.
