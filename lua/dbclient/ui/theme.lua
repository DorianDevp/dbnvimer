--- The design system.
---
--- Terminal UIs usually pick colours one highlight group at a time, which is
--- why most of them read as a pile of decisions rather than one thing. This is
--- built the way a design system is built:
---
---   **Foundation** — a neutral ramp derived from whatever background the
---   user's colourscheme actually has, in even perceptual steps.
---
---   **Roles** — a small set of semantic names (`identifier`, `numeric`,
---   `destructive`, `pending`) each defined as a hue and a *contrast target*,
---   not as a hex value. The lightness is solved for the real background, so
---   the same palette works on a light theme and a dark one.
---
---   **Tokens** — every highlight group refers to a role. Nothing refers to a
---   colour. Changing what "destructive" means changes it everywhere at once.
---
--- The restraint is deliberate. Six hues, used sparingly, with hierarchy
--- carried mostly by weight and by how far text is allowed to recede — not by
--- painting more of the screen. A column of data should be the loudest thing
--- in a data buffer; the chrome around it should be almost invisible.

local color = require("dbclient.ui.color")

local M = {
  --- The palette in use, exposed for tests and for user overrides.
  ---@type table<string, string>
  palette = {},
  ---@type { background: string, foreground: string, dark: boolean }
  foundation = {},
}

-- ---------------------------------------------------------------------------
-- Roles
-- ---------------------------------------------------------------------------

--- Hues, in Oklch degrees.
---
--- Six, chosen far enough apart to be told apart at a glance and close enough
--- in character to look related. Anything that does not need a hue does not get
--- one: types, metadata and chrome live on the neutral ramp.
local HUE = {
  blue = 245,
  cyan = 205,
  green = 150,
  amber = 80,
  red = 25,
  violet = 305,
}

--- Chroma. Low enough that a screenful is calm, high enough to read as colour.
local CHROMA = {
  strong = 0.15,
  normal = 0.11,
  quiet = 0.07,
  --- Barely a hue at all: a warm or cool grey rather than a colour.
  trace = 0.035,
}

--- Contrast targets, as WCAG ratios against the background.
---
---   9.0  the one thing a view is about
---   6.5  ordinary values and labels
---   3.6  deliberately quiet text: nulls, hints, metadata
---   1.9  chrome that is not text at all: rules and separators
---
--- 4.5 is the AA threshold and would pass an audit, but a colour sitting
--- exactly on it reads muddy on a dark terminal — the floor is not the target.
--- Everything here clears AA with room to spare, and the quiet tier clears the
--- 3:1 threshold that applies to text one is not meant to read first.
local TARGET = {
  primary = 9.0,
  value = 6.5,
  quiet = 3.6,
  chrome = 1.9,
}

--- Every semantic role. This table is the whole design.
---
--- Some roles share a colour on purpose: "added" and "positive" are the same
--- green because they mean the same thing in two places, and a consistent
--- language is worth more than novelty. What is *not* allowed is two roles
--- that appear side by side looking alike — a primary key marker and a warning
--- both being amber, say — and the spec checks the pairs that actually
--- co-occur.
local ROLES = {
  -- Structure: what a thing *is*.
  identifier = { hue = HUE.blue, chroma = CHROMA.normal, target = TARGET.value },
  identifier_strong = { hue = HUE.blue, chroma = CHROMA.strong, target = TARGET.primary },
  relation = { hue = HUE.cyan, chroma = CHROMA.quiet, target = TARGET.quiet },
  -- The identity column earns emphasis: brighter and more saturated than the
  -- warning amber it sits next to in a table listing.
  key = { hue = HUE.amber, chroma = CHROMA.strong, target = TARGET.primary },

  -- Values: what a thing *holds*.
  -- Numbers are already right-aligned, which is the real signal, so this is a
  -- warm grey rather than a colour — enough to pick a numeric column out of a
  -- grid, not enough to compete with it.
  numeric = { hue = HUE.amber, chroma = CHROMA.trace, target = TARGET.value },
  temporal = { hue = HUE.violet, chroma = CHROMA.quiet, target = TARGET.value },
  boolean = { hue = HUE.cyan, chroma = CHROMA.normal, target = TARGET.value },
  structured = { hue = HUE.green, chroma = CHROMA.quiet, target = TARGET.value },
  binary = { hue = HUE.violet, chroma = CHROMA.quiet, target = TARGET.quiet },

  -- State: what is happening to a thing.
  added = { hue = HUE.green, chroma = CHROMA.normal, target = TARGET.value },
  changed = { hue = HUE.blue, chroma = CHROMA.normal, target = TARGET.value },
  removed = { hue = HUE.red, chroma = CHROMA.normal, target = TARGET.value },

  -- Severity, in one family so they read as a scale.
  danger = { hue = HUE.red, chroma = CHROMA.strong, target = TARGET.value },
  caution = { hue = HUE.amber, chroma = CHROMA.normal, target = TARGET.value },
  positive = { hue = HUE.green, chroma = CHROMA.normal, target = TARGET.value },
  info = { hue = HUE.blue, chroma = CHROMA.quiet, target = TARGET.value },

  -- The single accent, used for the one thing that matters most in a view.
  accent = { hue = HUE.blue, chroma = CHROMA.strong, target = TARGET.value },
}

--- Connection colours, offered by name in a connection spec.
---
--- These are the one place a loud colour is correct: a production connection
--- should be impossible to mistake, so they are generated at the strong chroma
--- and the primary contrast target.
local CONNECTION_HUES = {
  red = HUE.red,
  orange = 55,
  amber = HUE.amber,
  green = HUE.green,
  teal = 175,
  cyan = HUE.cyan,
  blue = HUE.blue,
  violet = HUE.violet,
  magenta = 340,
  -- Kept because connection specs in the wild already name them.
  yellow = HUE.amber,
  purple = HUE.violet,
  grey = false,
}

-- ---------------------------------------------------------------------------
-- Building the palette
-- ---------------------------------------------------------------------------

--- Read the colourscheme's own background and foreground.
---@return string background, string foreground
local function foundation_colors()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local background = normal and normal.bg and ("#%06x"):format(normal.bg)
  local foreground = normal and normal.fg and ("#%06x"):format(normal.fg)

  if not background then
    background = vim.o.background == "light" and "#ffffff" or "#101215"
  end
  if not foreground then
    foreground = vim.o.background == "light" and "#1c1e22" or "#d8dce3"
  end
  return background, foreground
end

--- The neutral ramp: everything that is not a hue.
---
--- Every step is *solved* for a contrast ratio against the background rather
--- than nudged by a fixed lightness delta. A delta looks fine on a mid-grey
--- background and does nothing at all on pure black, where Oklab lightness is
--- so compressed that +0.02 rounds back to the same byte.
---@param background string
---@param foreground string
---@param dark boolean
---@return table<string, string>
local function neutral_ramp(background, foreground, dark)
  local _ = dark

  --- A near-neutral surface at a given distance from the page.
  local function surface_at(target)
    return color.solve_lightness({
      background = background,
      hue = HUE.blue,
      chroma = 0.004,
      target = target,
    })
  end

  return {
    surface = background,
    -- A float sits above the page — lifted, not a different room.
    raised = surface_at(1.16),
    -- A row stripe has to be felt more than seen. Any more and the grid turns
    -- into a barcode.
    stripe = surface_at(1.09),

    -- Chrome. Separators and borders are structure, not content, and belong at
    -- the edge of visibility.
    rule = color.solve_lightness({
      background = background,
      hue = HUE.blue,
      chroma = 0.006,
      target = TARGET.chrome,
    }),

    -- Text, in four weights of presence. `text` is the colourscheme's own
    -- foreground, so ordinary content still looks like the rest of the editor;
    -- the others are placed around it.
    subtle = color.solve_lightness({
      background = background,
      hue = HUE.blue,
      chroma = 0.008,
      target = TARGET.quiet,
    }),
    muted = color.solve_lightness({
      background = background,
      hue = HUE.blue,
      chroma = 0.010,
      target = 5.2,
    }),
    text = foreground,
    -- Emphasis has to out-shout `text`, and some colourschemes already use a
    -- near-white foreground, so the target is pushed past whatever that is.
    bright = color.solve_lightness({
      background = background,
      hue = HUE.blue,
      chroma = 0.004,
      target = math.max(14.0, color.contrast(foreground, background) + 1.0),
    }),
  }
end

--- Build the whole palette for a background.
---@param opts? { background?: string, foreground?: string }
---@return table<string, string>
function M.build(opts)
  opts = opts or {}
  local background = opts.background
  local foreground = opts.foreground
  if not background or not foreground then
    local detected_background, detected_foreground = foundation_colors()
    background = background or detected_background
    foreground = foreground or detected_foreground
  end

  local dark = color.is_dark(background)
  M.foundation = { background = background, foreground = foreground, dark = dark }

  local palette = neutral_ramp(background, foreground, dark)

  for name, role in pairs(ROLES) do
    palette[name] = color.solve_lightness({
      background = background,
      hue = role.hue,
      chroma = role.chroma,
      target = role.target,
    })
  end

  for name, hue in pairs(CONNECTION_HUES) do
    if hue then
      palette["connection_" .. name] = color.solve_lightness({
        background = background,
        hue = hue,
        chroma = CHROMA.strong,
        target = TARGET.value,
      })
    else
      palette["connection_" .. name] = palette.muted
    end
  end

  -- Surfaces for the few places a colour is used as a background rather than
  -- as text: they have to stay far enough from the page to register and close
  -- enough that text on top still reads.
  for _, name in ipairs({ "added", "changed", "removed", "caution", "danger" }) do
    palette[name .. "_surface"] = color.mix(background, palette[name], dark and 0.16 or 0.12)
  end

  M.palette = palette
  return palette
end

-- ---------------------------------------------------------------------------
-- Tokens
-- ---------------------------------------------------------------------------

--- Every highlight group DBClient defines, as `{ fg role, options }`.
---
--- Nothing here names a colour. That is the point: the meaning of a group is
--- stated once, and what it looks like is decided by the palette.
local function tokens(palette)
  local groups = {}

  local function set(name, spec)
    groups[name] = spec
  end

  -- Grid ------------------------------------------------------------------
  -- The header carries weight rather than colour, so the data below it stays
  -- the loudest thing on screen.
  set("DBClientHeader", { fg = palette.bright, bold = true })
  set("DBClientHeaderRule", { fg = palette.rule })
  set("DBClientSeparator", { fg = palette.rule })
  set("DBClientStripe", { bg = palette.stripe })

  -- Values, by class. Text gets no colour at all: it is the default, and
  -- colouring the common case is what makes a screen look busy.
  set("DBClientNumber", { fg = palette.numeric })
  set("DBClientBool", { fg = palette.boolean })
  set("DBClientTemporal", { fg = palette.temporal })
  set("DBClientJson", { fg = palette.structured })
  set("DBClientBinary", { fg = palette.binary })
  set("DBClientNull", { fg = palette.subtle, italic = true })
  set("DBClientTruncated", { fg = palette.caution })

  -- Objects ---------------------------------------------------------------
  set("DBClientSchema", { fg = palette.identifier_strong, bold = true })
  set("DBClientTable", { fg = palette.identifier })
  set("DBClientView", { fg = palette.identifier, italic = true })
  set("DBClientColumn", { fg = palette.text })
  set("DBClientKey", { fg = palette.key })
  set("DBClientRoutine", { fg = palette.structured })
  set("DBClientFk", { fg = palette.relation, italic = true })

  -- Connections -----------------------------------------------------------
  set("DBClientConnection", { fg = palette.identifier_strong, bold = true })
  set("DBClientConnectionActive", { fg = palette.positive, bold = true })
  set("DBClientDetected", { fg = palette.subtle })
  set("DBClientError", { fg = palette.danger, bold = true })

  set("DBClientAccessRead", { fg = palette.info })
  set("DBClientAccessSandbox", { fg = palette.temporal })
  set("DBClientTransaction", { fg = palette.caution, bold = true })

  -- Pending changes -------------------------------------------------------
  set("DBClientPending", { fg = palette.changed })
  set("DBClientPendingAdd", { fg = palette.added })
  set("DBClientPendingDelete", { fg = palette.removed })

  -- Plans -----------------------------------------------------------------
  -- A heat scale, so the eye lands on the expensive node first.
  set("DBClientPlanCheap", { fg = palette.subtle })
  set("DBClientPlanWarm", { fg = palette.caution })
  set("DBClientPlanHot", { fg = palette.danger, bold = true })
  set("DBClientPlanMisestimate", { fg = palette.danger, italic = true })

  -- Help and chrome -------------------------------------------------------
  set("DBClientHelpTitle", { fg = palette.bright, bold = true })
  set("DBClientHelpKey", { fg = palette.accent })
  set("DBClientHelpText", { fg = palette.muted })
  set("DBClientBorder", { fg = palette.rule })
  set("DBClientFloat", { bg = palette.raised })
  set("DBClientFloatTitle", { fg = palette.accent, bold = true })

  -- Severity, shared by the audit and the linter.
  set("DBClientSeverityError", { fg = palette.danger })
  set("DBClientSeverityWarn", { fg = palette.caution })
  set("DBClientSeverityHint", { fg = palette.subtle })
  set("DBClientSeverityOk", { fg = palette.positive })

  for name in pairs(CONNECTION_HUES) do
    set(
      "DBClientConn" .. name:sub(1, 1):upper() .. name:sub(2),
      { fg = palette["connection_" .. name], bold = true }
    )
  end

  return groups
end

-- ---------------------------------------------------------------------------
-- Applying
-- ---------------------------------------------------------------------------

--- The xterm-256 colour cube in Oklab, built once.
local xterm
local function xterm_table()
  if xterm then
    return xterm
  end
  xterm = {}
  local levels = { 0, 95, 135, 175, 215, 255 }
  for ri = 0, 5 do
    for gi = 0, 5 do
      for bi = 0, 5 do
        local l, a, b =
          color.to_oklab(levels[ri + 1] / 255, levels[gi + 1] / 255, levels[bi + 1] / 255)
        xterm[#xterm + 1] = { index = 16 + 36 * ri + 6 * gi + bi, l = l, a = a, b = b }
      end
    end
  end
  for step = 0, 23 do
    local value = (8 + step * 10) / 255
    local l, a, b = color.to_oklab(value, value, value)
    xterm[#xterm + 1] = { index = 232 + step, l = l, a = a, b = b }
  end
  return xterm
end

local cterm_cache = {}

--- Nearest xterm-256 index, so the palette degrades instead of disappearing on
--- a terminal without truecolor.
---
--- Matched in Oklab rather than in raw RGB, which otherwise drifts badly on the
--- greys — the cube's near-neutrals are not evenly spaced.
---@param hex string
---@return integer
function M.cterm(hex)
  if cterm_cache[hex] then
    return cterm_cache[hex]
  end

  local target_l, target_a, target_b = color.to_oklab(color.decode(hex))
  local best, best_distance = 0, math.huge
  for _, entry in ipairs(xterm_table()) do
    local distance = (entry.l - target_l) ^ 2
      + (entry.a - target_a) ^ 2
      + (entry.b - target_b) ^ 2
    if distance < best_distance then
      best, best_distance = entry.index, distance
    end
  end

  cterm_cache[hex] = best
  return best
end

--- Build the palette and define every highlight group.
---@param opts? { background?: string, foreground?: string, overrides?: table }
function M.apply(opts)
  opts = opts or {}
  local palette = M.build(opts)

  if opts.overrides and opts.overrides.palette then
    palette = vim.tbl_extend("force", palette, opts.overrides.palette)
    M.palette = palette
  end

  local groups = tokens(palette)
  if opts.overrides and opts.overrides.groups then
    groups = vim.tbl_extend("force", groups, opts.overrides.groups)
  end

  -- Both sets are always written. Neovim uses the hex when `termguicolors` is
  -- on and the cterm index when it is off, so setting both means the palette
  -- survives the user toggling it — and survives a terminal that never had it.
  for name, spec in pairs(groups) do
    local highlight = vim.tbl_extend("force", {}, spec)
    if spec.fg then
      highlight.ctermfg = M.cterm(spec.fg)
    end
    if spec.bg then
      highlight.ctermbg = M.cterm(spec.bg)
    end
    highlight.cterm = { bold = spec.bold or nil, italic = spec.italic or nil }
    vim.api.nvim_set_hl(0, name, highlight)
  end

  return palette
end

--- The generated palette, as lines, for `:DBClientPalette`.
---@return string[] lines, table[] marks
function M.describe()
  local palette = M.palette
  if vim.tbl_isempty(palette) then
    palette = M.build()
  end

  local background = M.foundation.background
  local lines = {
    ("background %s    foreground %s    %s"):format(
      background,
      M.foundation.foreground,
      M.foundation.dark and "dark" or "light"
    ),
    "",
    ("%-22s %-9s %-10s %s"):format("role", "colour", "contrast", "sample"),
  }
  local marks = {
    { line = 0, group = "DBClientHelpText" },
    { line = 2, group = "DBClientHeader" },
  }

  local names = vim.tbl_keys(palette)
  table.sort(names)

  local swatch = ("▉"):rep(8)
  for _, name in ipairs(names) do
    local hex = palette[name]
    local prefix = ("%-22s %-9s %5.2f:1    "):format(name, hex, color.contrast(hex, background))
    table.insert(lines, prefix .. swatch)

    -- Paint the sample in the colour it describes, which is the only part of
    -- this listing that answers "but what does it look like".
    local group = "DBClientSwatch" .. name
    vim.api.nvim_set_hl(0, group, { fg = hex, ctermfg = M.cterm(hex) })
    table.insert(marks, {
      line = #lines - 1,
      col = #prefix,
      end_col = #prefix + #swatch,
      group = group,
    })
  end

  return lines, marks
end

M.ROLES = ROLES
M.HUE = HUE
M.TARGET = TARGET
M.CONNECTION_HUES = CONNECTION_HUES

return M
