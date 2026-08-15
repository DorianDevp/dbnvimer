# The trail

Every jump is recorded. Walk `orders → customers → addresses` and you can step
back one at a time, or jump straight back to the start.

| Key | Effect |
|---|---|
| `g[` | back one |
| `g]` | forward one |
| `gb` | pick any point on the trail |

With a count: `3g[` goes back three.

## The breadcrumb

```text
shop.orders › shop.customers[id = '7'] › [shop.addresses[id = '4']]
```

Each step carries the filter that got you there, so going back restores what
you were looking at, not just which table it was in.

## It behaves like the jumplist

Navigating from a rewound position drops the forward branch, the same rule
`<C-o>` and `<C-i>` follow. Nothing surprising happens if you go back two
steps and then follow a different key.

## Where it is kept

Per session, capped, and included in a [workspace](../config/reference.md)
when you save one.
