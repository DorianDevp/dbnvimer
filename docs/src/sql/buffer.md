# The query buffer

`<leader>dq`. A real `sql` buffer, so treesitter, your completion setup and
your own mappings all apply.

| Key | Effect |
|---|---|
| `<C-CR>` | run the statement at the cursor |
| `<leader>dq` | the same, and works on a visual selection |
| `<leader>dQ` | run every statement, one line of report each |
| `<leader>de` | explain it |
| `<leader>dE` | explain analyze it |
| `<leader>dR` | show which rows it would change |
| `K` | describe the table or column under the cursor |
| `gd` | open the DDL for the table under the cursor |
| `gs` `gf` | save this query; open a saved one |

## Statements are split properly

By the Rust core, which understands string literals, comments, dollar quoting
and `DELIMITER`. So this is *one* statement, not five:

```sql
create function bump(n int) returns int as $$
begin
  return n + 1;  -- not a statement boundary
end;
$$ language plpgsql;
```

## Running the whole buffer

`<leader>dQ` reports one line per statement and stops at the first failure,
naming which one it was.

```text
 1  OK       0.4 ms      4 rows   select count(*) from orders
 2  OK      12.1 ms   updated 3   update orders set status_id = 2 where …
 3  FAILED               syntax error at or near "FORM"
    select * FORM customers
```

## What was run

`<leader>dl` is the statement log for this session: every statement DBClient
sent, with its timing, row count and whether it succeeded. `<leader>dh` is the
history of statements *you* ran, which persists across sessions.
