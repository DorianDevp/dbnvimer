# Appearance

Colours are generated, not shipped.

Each role is defined as a hue and a **contrast target**, and the lightness is
solved against your colourscheme's actual background. The same design
therefore holds on a light theme and a dark one, rather than being tuned for
one and unreadable on the other.

```vim
:DBClientPalette
```

```text
background #1a1b26    foreground #c0caf5    dark

role                   colour    contrast   sample
accent                 #3ca7f5    6.54:1    ▉▉▉▉▉▉▉▉
identifier             #60a6df    6.53:1    ▉▉▉▉▉▉▉▉
key                    #e0b45f    9.01:1    ▉▉▉▉▉▉▉▉
temporal               #ac97c5    6.50:1    ▉▉▉▉▉▉▉▉
danger                 #f57c74    6.53:1    ▉▉▉▉▉▉▉▉
subtle                 #6f7477    3.61:1    ▉▉▉▉▉▉▉▉
```

Six hues, used sparingly. Values sit at 6.5:1 rather than at the 4.5:1
accessibility floor, because a colour exactly on the threshold reads muddy on
a dark terminal.

## Overriding

```lua
require("dbclient").setup({
  ui = {
    theme = {
      -- one role, everywhere it is used
      overrides = { palette = { accent = "#ff8800" } },
    },
  },
})
```

Or a single highlight group:

```lua
overrides = { groups = { DBClientHeader = { fg = "#ffffff", bold = true } } }
```

Or turn the whole thing off and inherit your colourscheme's stock groups:

```lua
ui = { theme = { enabled = false } }
```

## The grid's rules

```lua
ui = { grid_style = "ascii" }   -- if your font mangles box characters
```

Stored values are identical either way, so it is purely a display choice.
