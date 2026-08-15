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

## When to run it

After a deployment, to answer "did the migration apply". Before one, to answer
"is this environment what I think it is".
