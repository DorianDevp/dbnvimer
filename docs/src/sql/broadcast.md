# Every connection at once

`<leader>dB` runs one statement against every open connection and compares
the answers.

```text
select count(*) from orders where status_id = 1

  dev        412
  staging    418
  prod    18 204

3 distinct results across 3 connections
```

When the answers agree it says so, which is often the point:

```text
select version_hash from schema_meta

  every connection returned the same rows
```

## What it is for

"Is this row on production too." "Did the migration run everywhere." "Are
these two environments actually the same." Questions that otherwise mean four
windows and a lot of squinting.

## Safety

Each connection's own access level still applies. Broadcasting a `DELETE` to
a set of connections where one is `read` runs it on the others and refuses on
that one, and the report says which.
