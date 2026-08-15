# Drift

`<leader>dV` compares the live schema against the committed one.

```text
shop  vs  db/schema

changed on the server (1)
  table     order_items

missing from the repository (1)
  table     hotfix_notes

66 objects checked
```

Three kinds of finding, and they mean different things:

| Finding | Means |
|---|---|
| changed | the server and the repository disagree about this object |
| untracked | the server has it, the repository does not |
| dropped | the repository has it, the server does not |

`<CR>` on a finding opens the repository's copy beside the server's in diff
mode.

## What this is for

Finding the hotfix nobody wrote down. Someone adds a column on production at
two in the morning; six weeks later a migration fails for reasons that make no
sense. This is the check that catches it in between.

Running it after a deployment answers "did the migration actually apply", and
running it before one answers "is this environment what I think it is".
