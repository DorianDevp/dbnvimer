--- Colour maths, so the palette is designed rather than guessed.
---
--- Hand-picked hex values look arbitrary because they are: two colours with the
--- same "brightness" by eye can differ by a factor of three in measured
--- contrast, and a palette built that way reads as noise. Everything here works
--- in Oklab, a perceptually uniform space, so that a set of colours asked for
--- at the same lightness genuinely *look* like one family — and so that the
--- contrast against the real background can be solved for rather than hoped
--- for.
---
--- Three things this makes possible:
---
---   * a neutral ramp with even perceptual steps, derived from whatever
---     background the user's colourscheme actually has;
---   * accent hues that all sit at the same apparent weight;
---   * a guarantee, checked by the tests, that every role meets its contrast
---     target on both light and dark backgrounds.

local M = {}

-- ---------------------------------------------------------------------------
-- sRGB
-- ---------------------------------------------------------------------------

--- `#rrggbb` or `0xrrggbb` to three channels in 0..1.
---@param value string|integer
---@return number, number, number
function M.decode(value)
  local number = value
  if type(value) == "string" then
    number = tonumber((value:gsub("^#", "")), 16) or 0
  end
  return
    math.floor(number / 65536) % 256 / 255,
    math.floor(number / 256) % 256 / 255,
    number % 256 / 255
end

---@param r number
---@param g number
---@param b number
---@return string
function M.encode(r, g, b)
  local function channel(value)
    return math.max(0, math.min(255, math.floor(value * 255 + 0.5)))
  end
  return ("#%02x%02x%02x"):format(channel(r), channel(g), channel(b))
end

--- Undo the sRGB transfer function. Blending or measuring colour in the encoded
--- values is the single most common way to get this wrong.
local function to_linear(value)
  if value <= 0.04045 then
    return value / 12.92
  end
  return ((value + 0.055) / 1.055) ^ 2.4
end

local function from_linear(value)
  if value <= 0.0031308 then
    return value * 12.92
  end
  return 1.055 * value ^ (1 / 2.4) - 0.055
end

-- ---------------------------------------------------------------------------
-- Oklab / Oklch
-- ---------------------------------------------------------------------------

--- sRGB to Oklab. Coefficients from Björn Ottosson's derivation.
---@param r number
---@param g number
---@param b number
---@return number lightness, number a, number b
function M.to_oklab(r, g, b)
  local lr, lg, lb = to_linear(r), to_linear(g), to_linear(b)

  local l = 0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb
  local m = 0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb
  local s = 0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb

  local l_ = l ^ (1 / 3)
  local m_ = m ^ (1 / 3)
  local s_ = s ^ (1 / 3)

  return 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
    1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
    0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
end

---@param lightness number
---@param a number
---@param b number
---@return number r, number g, number b, boolean in_gamut
function M.from_oklab(lightness, a, b)
  local l_ = lightness + 0.3963377774 * a + 0.2158037573 * b
  local m_ = lightness - 0.1055613458 * a - 0.0638541728 * b
  local s_ = lightness - 0.0894841775 * a - 1.2914855480 * b

  local l, m, s = l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_

  local lr = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
  local lg = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
  local lb = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s

  local in_gamut = lr >= -0.0001
    and lr <= 1.0001
    and lg >= -0.0001
    and lg <= 1.0001
    and lb >= -0.0001
    and lb <= 1.0001

  local function clamp(value)
    return math.max(0, math.min(1, value))
  end

  return from_linear(clamp(lr)), from_linear(clamp(lg)), from_linear(clamp(lb)), in_gamut
end

--- Oklch: lightness, chroma, hue in degrees. Easier to reason about than a/b.
---@param lightness number
---@param chroma number
---@param hue number
---@return number r, number g, number b, boolean in_gamut
function M.from_oklch(lightness, chroma, hue)
  local radians = math.rad(hue)
  return M.from_oklab(lightness, chroma * math.cos(radians), chroma * math.sin(radians))
end

---@param r number
---@param g number
---@param b number
---@return number lightness, number chroma, number hue
function M.to_oklch(r, g, b)
  local lightness, a, bb = M.to_oklab(r, g, b)
  local chroma = math.sqrt(a * a + bb * bb)
  local hue = math.deg(math.atan2 and math.atan2(bb, a) or math.atan(bb, a))
  if hue < 0 then
    hue = hue + 360
  end
  return lightness, chroma, hue
end

--- Reduce chroma until the colour fits in sRGB.
---
--- Clamping the channels instead shifts the hue, which is what makes naive
--- palettes drift: the "same" hue comes out different at different lightnesses.
---@param lightness number
---@param chroma number
---@param hue number
---@return string
function M.gamut_hex(lightness, chroma, hue)
  local low, high = 0, chroma
  local _, _, _, fits = M.from_oklch(lightness, chroma, hue)
  if fits then
    return M.encode(M.from_oklch(lightness, chroma, hue))
  end

  for _ = 1, 24 do
    local middle = (low + high) / 2
    local _, _, _, ok = M.from_oklch(lightness, middle, hue)
    if ok then
      low = middle
    else
      high = middle
    end
  end
  return M.encode(M.from_oklch(lightness, low, hue))
end

-- ---------------------------------------------------------------------------
-- Contrast
-- ---------------------------------------------------------------------------

--- WCAG relative luminance.
---@param r number
---@param g number
---@param b number
---@return number
function M.luminance(r, g, b)
  return 0.2126 * to_linear(r) + 0.7152 * to_linear(g) + 0.0722 * to_linear(b)
end

--- WCAG contrast ratio between two colours, 1..21.
---@param first string|integer
---@param second string|integer
---@return number
function M.contrast(first, second)
  local a = M.luminance(M.decode(first))
  local b = M.luminance(M.decode(second))
  local lighter, darker = math.max(a, b), math.min(a, b)
  return (lighter + 0.05) / (darker + 0.05)
end

--- Find the lightness at which a hue reaches a contrast target on `background`.
---
--- This is the part that makes the palette work on any colourscheme: rather
--- than shipping a colour and hoping, the lightness is solved for the
--- background that is actually there.
---@param opts { background: string, hue: number, chroma: number, target: number, prefer?: "lighter"|"darker" }
---@return string hex, number achieved
function M.solve_lightness(opts)
  local background = opts.background
  local background_lightness = M.to_oklab(M.decode(background))
  local prefer = opts.prefer
  if not prefer then
    prefer = background_lightness < 0.5 and "lighter" or "darker"
  end

  local low, high
  if prefer == "lighter" then
    low, high = background_lightness, 1.0
  else
    low, high = 0.0, background_lightness
  end

  local best = M.gamut_hex(prefer == "lighter" and high or low, opts.chroma, opts.hue)
  local best_contrast = M.contrast(best, background)

  -- Binary search on lightness: contrast is monotonic in each direction away
  -- from the background.
  for _ = 1, 20 do
    local middle = (low + high) / 2
    local candidate = M.gamut_hex(middle, opts.chroma, opts.hue)
    local ratio = M.contrast(candidate, background)

    if ratio >= opts.target then
      best, best_contrast = candidate, ratio
      -- Move back towards the background: the least contrast that still
      -- passes is the most harmonious.
      if prefer == "lighter" then
        high = middle
      else
        low = middle
      end
    elseif prefer == "lighter" then
      low = middle
    else
      high = middle
    end
  end

  return best, best_contrast
end

--- Perceptual distance between two colours, as Oklab ΔE.
---
--- Not the same question as contrast, and the two disagree: a warm grey and a
--- gold placed at the same contrast against the page have almost no contrast
--- with *each other* by the WCAG formula, yet nobody would confuse them.
--- Contrast answers "can this be read on that"; this answers "can these two be
--- told apart". Roughly, 0.02 is the threshold of noticing and 0.05 is obvious.
---@param first string
---@param second string
---@return number
function M.distance(first, second)
  local l1, a1, b1 = M.to_oklab(M.decode(first))
  local l2, a2, b2 = M.to_oklab(M.decode(second))
  return math.sqrt((l1 - l2) ^ 2 + (a1 - a2) ^ 2 + (b1 - b2) ^ 2)
end

--- Mix two colours in Oklab, which keeps the midpoint looking like a midpoint.
---@param first string
---@param second string
---@param amount number  0 returns `first`, 1 returns `second`
---@return string
function M.mix(first, second, amount)
  local l1, a1, b1 = M.to_oklab(M.decode(first))
  local l2, a2, b2 = M.to_oklab(M.decode(second))
  return M.encode(M.from_oklab(
    l1 + (l2 - l1) * amount,
    a1 + (a2 - a1) * amount,
    b1 + (b2 - b1) * amount
  ))
end

--- True when a background is dark enough to want light text.
---@param background string
---@return boolean
function M.is_dark(background)
  return (M.to_oklab(M.decode(background))) < 0.5
end

--- Nudge a colour's lightness while holding its hue and chroma.
---@param hex string
---@param delta number
---@return string
function M.shift(hex, delta)
  local lightness, chroma, hue = M.to_oklch(M.decode(hex))
  return M.gamut_hex(math.max(0, math.min(1, lightness + delta)), chroma, hue)
end

return M
