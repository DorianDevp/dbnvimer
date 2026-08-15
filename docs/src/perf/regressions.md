# Regressions

`s` in the workload view saves the counters. Later, `c` compares the server
against that reading.

```text
prod   2026-03-01 09:14  →  now
1 slower · 0 faster · 0 new

slower
   271.3×    0.04 ms →     10 ms  select count(*) from products where name = $1
```

Someone dropped an index.

## The arithmetic is the whole feature

Both sources report totals since the server started. Their published average
is therefore the average over the process's entire life, which on a server
that has been up for a month says nothing about this week.

What matters is the average over the *window* between two readings:

```text
window_avg = (total_after - total_before) / (calls_after - calls_before)
```

That isolates what happened since the snapshot, even though the counters still
have the fast period in them.

## Counters that went backwards

Mean the server restarted or the view was reset. There is nothing to compare,
and treating the smaller numbers as a change would report the entire workload
as having got faster. So it reports nothing for those.

## What is filtered out

- statements called fewer than five times in the window; one slow call is
  noise, not a regression
- changes smaller than 1.5× in either direction

Results are ranked by how much time the change actually costs: twice as slow
on a statement called ten thousand times matters more than ten times slower on
one called twice.

## Taking a snapshot without opening anything

```vim
:DBClientStatements! before the release
```
