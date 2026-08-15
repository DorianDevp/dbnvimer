--- The palette is generated, so it can be *checked* — which is most of the
--- argument for generating it. A hand-written set of hex values can only be
--- eyeballed; this one is asserted to meet its contrast targets on every
--- background it is asked about.

local t = require("tests.init")
local color = require("dbclient.ui.color")
local theme = require("dbclient.ui.theme")

--- Backgrounds spanning the range people actually use.
local BACKGROUNDS = {
  { name = "tokyonight", background = "#1a1b26", foreground = "#c0caf5" },
  { name = "gruvbox dark", background = "#282828", foreground = "#ebdbb2" },
  { name = "pure black", background = "#000000", foreground = "#e0e0e0" },
  { name = "solarized light", background = "#fdf6e3", foreground = "#657b83" },
  { name = "pure white", background = "#ffffff", foreground = "#24292f" },
  { name = "nord", background = "#2e3440", foreground = "#d8dee9" },
}

t.describe("colour maths", {
  ["round-trips sRGB through Oklab"] = function()
    for _, hex in ipairs({ "#000000", "#ffffff", "#7aa2f7", "#f7768e", "#1a1b26", "#336699" }) do
      local r, g, b = color.decode(hex)
      local lightness, a, bb = color.to_oklab(r, g, b)
      t.eq(color.encode(color.from_oklab(lightness, a, bb)), hex, hex .. " survived the trip")
    end
  end,

  ["matches the published Oklab lightness values"] = function()
    local white, a, b = color.to_oklab(1, 1, 1)
    t.ok(math.abs(white - 1.0) < 0.001, "white is L=1, got " .. white)
    t.ok(math.abs(a) < 0.001 and math.abs(b) < 0.001, "white has no chroma")

    t.ok(math.abs(color.to_oklab(1, 0, 0) - 0.6279) < 0.001, "red is L=0.628")
    t.ok(math.abs(color.to_oklab(0, 1, 0) - 0.8664) < 0.001, "green is L=0.866")
    t.ok(math.abs(color.to_oklab(0, 0, 1) - 0.4520) < 0.001, "blue is L=0.452")
  end,

  ["computes WCAG contrast against known pairs"] = function()
    t.ok(math.abs(color.contrast("#000000", "#ffffff") - 21) < 0.01, "black on white is 21:1")
    t.ok(math.abs(color.contrast("#ffffff", "#ffffff") - 1) < 0.001, "white on white is 1:1")
    -- #767676 is the canonical smallest grey that still passes AA on white.
    local grey = color.contrast("#767676", "#ffffff")
    t.ok(grey >= 4.5 and grey < 4.6, "#767676 on white is just over 4.5:1, got " .. grey)
  end,

  ["holds the hue when a colour leaves the gamut"] = function()
    -- Far more chroma than sRGB can hold. Clipping the channels would swing
    -- the hue; reducing chroma must not.
    local hex = color.gamut_hex(0.6, 0.5, 145)
    local _, chroma, hue = color.to_oklch(color.decode(hex))
    t.ok(chroma < 0.5, "chroma was reduced to fit, got " .. chroma)
    t.ok(math.abs(hue - 145) < 2, "hue held at 145, got " .. hue)
  end,

  ["solves for a contrast target on any background"] = function()
    for _, background in ipairs({ "#1a1b26", "#ffffff", "#282c34", "#fdf6e3", "#000000" }) do
      for _, target in ipairs({ 3.0, 4.5, 7.0 }) do
        local hex, achieved = color.solve_lightness({
          background = background,
          hue = 245,
          chroma = 0.10,
          target = target,
        })
        t.ok(
          achieved >= target - 0.01,
          ("%s on %s reached %.2f, wanted %.1f"):format(hex, background, achieved, target)
        )
      end
    end
  end,

  ["mixes through the perceptual midpoint"] = function()
    local lightness = color.to_oklab(color.decode(color.mix("#000000", "#ffffff", 0.5)))
    t.ok(math.abs(lightness - 0.5) < 0.01, "the midpoint is L=0.5, got " .. lightness)
    t.eq(color.mix("#123456", "#abcdef", 0), "#123456", "0 returns the first colour")
    t.eq(color.mix("#123456", "#abcdef", 1), "#abcdef", "1 returns the second")
  end,

  ["detects light and dark backgrounds"] = function()
    t.ok(color.is_dark("#1a1b26"), "tokyonight is dark")
    t.ok(color.is_dark("#000000"), "black is dark")
    t.falsy(color.is_dark("#ffffff"), "white is light")
    t.falsy(color.is_dark("#fdf6e3"), "solarized light is light")
  end,
})

t.describe("generated palette", {
  ["meets every role's contrast target on every background"] = function()
    for _, scheme in ipairs(BACKGROUNDS) do
      local palette = theme.build(scheme)
      for name, role in pairs(theme.ROLES) do
        local ratio = color.contrast(palette[name], scheme.background)
        t.ok(
          ratio >= role.target - 0.05,
          ("%s: %s is %.2f:1, needs %.1f"):format(scheme.name, name, ratio, role.target)
        )
      end
    end
  end,

  ["keeps quiet text quiet and loud text loud"] = function()
    for _, scheme in ipairs(BACKGROUNDS) do
      local palette = theme.build(scheme)
      local subtle = color.contrast(palette.subtle, scheme.background)
      local muted = color.contrast(palette.muted, scheme.background)
      local bright = color.contrast(palette.bright, scheme.background)

      t.ok(subtle < muted, scheme.name .. ": subtle recedes further than muted")
      t.ok(muted < bright, scheme.name .. ": muted recedes further than bright")
      -- A hierarchy nobody can see is not a hierarchy.
      t.ok(muted - subtle > 0.4, scheme.name .. ": the two quiet steps are told apart")
    end
  end,

  ["keeps the row stripe felt rather than seen"] = function()
    for _, scheme in ipairs(BACKGROUNDS) do
      local palette = theme.build(scheme)
      local ratio = color.contrast(palette.stripe, scheme.background)
      t.ok(ratio > 1.0, scheme.name .. ": the stripe differs from the page")
      t.ok(ratio < 1.25, scheme.name .. ": the stripe is not a band, got " .. ratio)
    end
  end,

  ["lifts a float off the page without opening a second room"] = function()
    for _, scheme in ipairs(BACKGROUNDS) do
      local palette = theme.build(scheme)
      local ratio = color.contrast(palette.raised, scheme.background)
      t.ok(ratio > 1.02 and ratio < 1.4, scheme.name .. ": raised is a lift, got " .. ratio)
    end
  end,

  ["keeps chrome at the edge of visibility"] = function()
    for _, scheme in ipairs(BACKGROUNDS) do
      local palette = theme.build(scheme)
      local rule = color.contrast(palette.rule, scheme.background)
      t.ok(rule >= 1.85, scheme.name .. ": a rule is still visible, got " .. rule)
      t.ok(
        rule < color.contrast(palette.subtle, scheme.background),
        scheme.name .. ": a rule is quieter than the quietest text"
      )
    end
  end,

  ["gives every connection colour a usable value"] = function()
    for _, scheme in ipairs(BACKGROUNDS) do
      local palette = theme.build(scheme)
      for name in pairs(theme.CONNECTION_HUES) do
        local hex = palette["connection_" .. name]
        t.ok(hex ~= nil, scheme.name .. ": " .. name .. " exists")
        t.ok(
          color.contrast(hex, scheme.background) >= 2.9,
          ("%s: connection %s is readable"):format(scheme.name, name)
        )
      end
    end
  end,

  ["tells the severity colours apart"] = function()
    for _, scheme in ipairs(BACKGROUNDS) do
      local palette = theme.build(scheme)
      local seen = {}
      for _, name in ipairs({ "danger", "caution", "positive", "info" }) do
        t.falsy(seen[palette[name]], scheme.name .. ": " .. name .. " is its own colour")
        seen[palette[name]] = true
      end
    end
  end,

  ["separates roles that appear side by side"] = function()
    -- Roles are allowed to share a colour when they mean the same thing in two
    -- places. These pairs turn up in the same view, so they may not.
    local PAIRS = {
      { "key", "caution", "a key marker and a warning share a table listing" },
      { "key", "numeric", "a key column and a numeric column share a grid" },
      { "numeric", "caution", "a numeric cell and a truncation mark share a grid" },
      { "numeric", "muted", "a number and the metadata around it share a grid" },
      { "identifier", "relation", "a table name and its foreign key share a line" },
      { "boolean", "structured", "two value classes share a grid" },
      { "temporal", "numeric", "two value classes share a grid" },
      { "subtle", "muted", "two levels of quiet share a panel" },
    }

    for _, scheme in ipairs(BACKGROUNDS) do
      local palette = theme.build(scheme)
      for _, entry in ipairs(PAIRS) do
        local first, second = palette[entry[1]], palette[entry[2]]
        t.ok(
          first ~= second,
          ("%s: %s and %s are the same colour — %s"):format(
            scheme.name,
            entry[1],
            entry[2],
            entry[3]
          )
        )
        -- Not merely different: different enough to see. Measured as Oklab
        -- distance, not as contrast — two colours placed at the same contrast
        -- against the page necessarily have almost none with each other, which
        -- says nothing about whether they look alike.
        local distance = color.distance(first, second)
        t.ok(
          distance > 0.045,
          ("%s: %s (%s) and %s (%s) differ by only %.3f — %s"):format(
            scheme.name,
            entry[1],
            first,
            entry[2],
            second,
            distance,
            entry[3]
          )
        )
      end
    end
  end,

  ["degrades to a 256-colour index"] = function()
    t.eq(theme.cterm("#000000"), 16, "black maps to the cube's corner")
    t.eq(theme.cterm("#ffffff"), 231, "white maps to the opposite corner")
    local index = theme.cterm("#808080")
    t.ok(index >= 232 and index <= 255, "mid grey lands on the grey ramp, got " .. index)
  end,
})

t.describe("theme tokens", {
  ["defines a group for everything the UI references"] = function()
    theme.apply({ background = "#1a1b26", foreground = "#c0caf5" })

    for _, name in ipairs({
      "DBClientHeader",
      "DBClientHeaderRule",
      "DBClientSeparator",
      "DBClientStripe",
      "DBClientNumber",
      "DBClientBool",
      "DBClientTemporal",
      "DBClientJson",
      "DBClientBinary",
      "DBClientNull",
      "DBClientTruncated",
      "DBClientSchema",
      "DBClientTable",
      "DBClientView",
      "DBClientColumn",
      "DBClientKey",
      "DBClientRoutine",
      "DBClientFk",
      "DBClientConnection",
      "DBClientConnectionActive",
      "DBClientDetected",
      "DBClientError",
      "DBClientAccessRead",
      "DBClientAccessSandbox",
      "DBClientTransaction",
      "DBClientPending",
      "DBClientPendingAdd",
      "DBClientPendingDelete",
      "DBClientPlanCheap",
      "DBClientPlanWarm",
      "DBClientPlanHot",
      "DBClientPlanMisestimate",
      "DBClientHelpTitle",
      "DBClientHelpKey",
      "DBClientHelpText",
      "DBClientBorder",
      "DBClientFloat",
      "DBClientFloatTitle",
      "DBClientSeverityError",
      "DBClientSeverityWarn",
      "DBClientSeverityHint",
      "DBClientSeverityOk",
      "DBClientConnBlue",
      "DBClientConnPurple",
      "DBClientConnOrange",
    }) do
      local highlight = vim.api.nvim_get_hl(0, { name = name })
      t.ok(highlight and next(highlight) ~= nil, name .. " is defined")
    end
  end,

  ["honours a palette override"] = function()
    theme.apply({
      background = "#1a1b26",
      foreground = "#c0caf5",
      overrides = { palette = { accent = "#ff00ff" } },
    })
    local highlight = vim.api.nvim_get_hl(0, { name = "DBClientHelpKey" })
    t.eq(("#%06x"):format(highlight.fg), "#ff00ff", "the override reached the token")
    theme.apply({ background = "#1a1b26", foreground = "#c0caf5" })
  end,

  ["honours a group override"] = function()
    theme.apply({
      background = "#1a1b26",
      foreground = "#c0caf5",
      overrides = { groups = { DBClientHeader = { fg = "#00ff00", underline = true } } },
    })
    local highlight = vim.api.nvim_get_hl(0, { name = "DBClientHeader" })
    t.eq(("#%06x"):format(highlight.fg), "#00ff00", "the group override won")
    t.ok(highlight.underline, "and kept its other attributes")
    theme.apply({ background = "#1a1b26", foreground = "#c0caf5" })
  end,

  ["describes itself with a contrast column"] = function()
    theme.apply({ background = "#1a1b26", foreground = "#c0caf5" })
    local lines = theme.describe()
    t.ok(#lines > 20, "every role is listed")
    t.matches(lines[1], "#1a1b26", "the foundation is stated")
    t.matches(lines[1], "dark", "and so is which way round it is")

    local found = false
    for _, line in ipairs(lines) do
      if line:match("^accent%s") then
        t.matches(line, "%d%.%d%d:1", "accent reports its contrast")
        found = true
      end
    end
    t.ok(found, "accent appears in the listing")
  end,
})
