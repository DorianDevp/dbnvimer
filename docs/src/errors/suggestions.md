# Did you mean

```text
there is no column `statuz` — did you mean `status`?
```

The client already knows every table and column on the connection, so a
misspelled name is not the end of the conversation.

## The distance

Damerau, not plain Levenshtein: a transposition counts as one edit rather
than two.

| Typed | Meant | Levenshtein | Damerau |
|---|---|---|---|
| `statuz` | `status` | 1 | 1 |
| `nmae` | `name` | 2 | 1 |
| `craeted_at` | `created_at` | 2 | 1 |

Swapping two adjacent letters is the commonest typo there is. With plain
Levenshtein it costs two, which puts it outside any threshold tight enough to
be useful on a short name — so `nmae` would never have found `name`.

## The threshold

Scales with length. One wrong letter in a three-letter name is a different
word; one in a ten-letter name is a typo. A name that *contains* what you
typed also counts, so `user` suggests `user_account`.

## Where the candidates come from

The metadata cache, which is already populated. An error handler that goes
back to the server turns a fast failure into a slow one.
