-- NVSD_ItemView - Fade Curves Module
-- Pure math: Bezier fade curves from REAPER (SWS/BR_Util.cpp, courtesy of Cockos)
-- No REAPER API dependencies.

local fade_curves = {}

-- Bezier control points for 7 fade shapes
-- Each b-array = {cx1, cy1, cx2, cy2} for cubic Bezier from (0,0) to (1,1)
local B = {
  b0  = {0.5, 0.5, 0.5, 0.5},         -- Linear
  b1  = {0.25, 0.5, 0.625, 1.0},       -- Fast start
  b2  = {0.375, 0.0, 0.75, 0.5},       -- Slow start
  b3  = {0.25, 1.0, 0.5, 1.0},         -- Fast start steep
  b4  = {0.5, 0.0, 0.75, 0.0},         -- Slow start steep
  b5  = {0.375, 0.0, 0.625, 1.0},      -- S-curve
  b6  = {0.875, 0.0, 0.125, 1.0},      -- S-curve steep
  b7  = {0.25, 0.375, 0.625, 1.0},     -- (unused in shapes 0-6)
  b4i = {0.0, 1.0, 0.125, 1.0},        -- Inverted b4
  b50 = {0.25, 0.25, 0.25, 1.0},       -- Shape 5 negative dir extreme
  b51 = {0.75, 0.0, 0.75, 0.75},       -- Shape 5 positive dir extreme
  b60 = {0.375, 0.25, 0.0, 1.0},       -- Shape 6 negative dir extreme
  b61 = {1.0, 0.0, 0.625, 0.75},       -- Shape 6 positive dir extreme
}
fade_curves.B = B

-- Evaluate cubic Bezier Y at position t (finds Bezier parameter via Newton's method)
local function cbez_y(bx1, by1, bx2, by2, bx3, by3, bx4, by4, t)
  if t <= 0 then return by1 end
  if t >= 1 then return by4 end
  local u = t
  for _ = 1, 8 do
    local mu = 1 - u
    local ex = mu*mu*mu*bx1 + 3*mu*mu*u*bx2 + 3*mu*u*u*bx3 + u*u*u*bx4
    local dx = 3*mu*mu*(bx2-bx1) + 6*mu*u*(bx3-bx2) + 3*u*u*(bx4-bx3)
    if math.abs(dx) < 1e-10 then break end
    u = u - (ex - t) / dx
    if u < 0 then u = 0 elseif u > 1 then u = 1 end
  end
  local mu = 1 - u
  return mu*mu*mu*by1 + 3*mu*mu*u*by2 + 3*mu*u*u*by3 + u*u*u*by4
end
fade_curves.cbez_y = cbez_y

-- Compute REAPER fade Bezier control points: exact port of GetMediaItemFadeBezParms
-- Returns bx1..4, by1..4 (the 4 Bezier control point coordinates)
local function get_fade_bez(shape, dir, is_fade_out)
  shape = shape or 0
  dir = dir or 0
  local x1, y1, x4, y4
  if not is_fade_out then
    x1, y1, x4, y4 = 0, 0, 1, 1
  else
    x1, y1, x4, y4 = 0, 1, 1, 0
  end
  if shape < 0 or shape > 6 then shape = 0; dir = 0 end
  if is_fade_out then dir = -dir end

  local x2, y2, x3, y3
  if dir < 0 then
    local w0, w1 = -dir, 1 + dir
    local ba, bb
    if     shape == 1 then ba, bb = B.b4i, B.b1
    elseif shape == 2 then ba, bb = B.b1,  B.b0
    elseif shape == 5 then ba, bb = B.b50, B.b5
    elseif shape == 6 then ba, bb = B.b60, B.b6
    else                   ba, bb = B.b3,  B.b0 end
    x2 = w0*ba[1] + w1*bb[1]; y2 = w0*ba[2] + w1*bb[2]
    x3 = w0*ba[3] + w1*bb[3]; y3 = w0*ba[4] + w1*bb[4]
  elseif dir > 0 then
    local w0, w1 = 1 - dir, dir
    local ba, bb
    if     shape == 1 then ba, bb = B.b1, B.b4
    elseif shape == 2 then ba, bb = B.b0, B.b2
    elseif shape == 5 then ba, bb = B.b5, B.b51
    elseif shape == 6 then ba, bb = B.b6, B.b61
    else                   ba, bb = B.b0, B.b4 end
    x2 = w0*ba[1] + w1*bb[1]; y2 = w0*ba[2] + w1*bb[2]
    x3 = w0*ba[3] + w1*bb[3]; y3 = w0*ba[4] + w1*bb[4]
  else
    local b
    if     shape == 1 then b = B.b1
    elseif shape == 5 then b = B.b5
    elseif shape == 6 then b = B.b6
    else                   b = B.b0 end
    x2, y2, x3, y3 = b[1], b[2], b[3], b[4]
  end

  if is_fade_out then
    local ox2, ox3 = x2, x3
    x2 = 1 - ox3; x3 = 1 - ox2
    y2, y3 = y3, y2
  end
  return x1, y1, x2, y2, x3, y3, x4, y4
end
fade_curves.get_fade_bez = get_fade_bez

-- Canonical fade shape curves: exact math per shape
-- (the Bezier system makes shapes 0/2/3/4 identical (linear) at dir=0)
local shape_icon_fns = {
  [0] = function(x) return x end,                                       -- Linear
  [1] = function(x) return 1 - (1-x)*(1-x) end,                        -- Fast start
  [2] = function(x) return x*x end,                                     -- Slow start
  [3] = function(x) return 1 - (1-x)^4 end,                             -- Fast start steep
  [4] = function(x) return x^4 end,                                      -- Slow start steep
  [5] = function(x) return (1 - math.cos(math.pi * x)) * 0.5 end,      -- S-curve
  [6] = function(x)                                                       -- S-curve steep
    if x < 0.5 then return 8*x*x*x*x else local t=1-x; return 1-8*t*t*t*t end
  end,
}
fade_curves.shape_icon_fns = shape_icon_fns

-- Evaluate REAPER fade amplitude at position t (0..1)
-- Returns amplitude: 0..1 for fade-in, 1..0 for fade-out
-- When dir=0, uses exact mathematical curves (the Bezier system renders
-- shapes 2/3/4 as linear at dir=0, but REAPER uses their canonical curves)
local function eval_fade(t, shape, dir, is_fade_out)
  dir = dir or 0
  if math.abs(dir) < 0.001 and shape >= 0 and shape <= 6 then
    local fn = shape_icon_fns[shape]
    if is_fade_out then return fn(1 - t) end
    return fn(t)
  end
  local x1,y1, x2,y2, x3,y3, x4,y4 = get_fade_bez(shape, dir, is_fade_out)
  return cbez_y(x1,y1, x2,y2, x3,y3, x4,y4, t)
end
fade_curves.eval_fade = eval_fade

-- Cached fade LUT for per-pixel rendering (avoids Newton's per pixel)
local FADE_LUT_SIZE = 256
fade_curves.FADE_LUT_SIZE = FADE_LUT_SIZE

local fade_lut_cache = {
  fi = { shape = -1, dir = -999, lut = {} },
  fo = { shape = -1, dir = -999, lut = {} },
}

local function get_fade_lut(shape, dir, is_fade_out)
  local c = fade_lut_cache[is_fade_out and "fo" or "fi"]
  if c.shape == shape and c.dir == dir then return c.lut end
  local lut = c.lut
  if math.abs(dir) < 0.001 and shape >= 0 and shape <= 6 then
    local fn = shape_icon_fns[shape]
    if is_fade_out then
      for i = 0, FADE_LUT_SIZE do lut[i] = fn(1 - i / FADE_LUT_SIZE) end
    else
      for i = 0, FADE_LUT_SIZE do lut[i] = fn(i / FADE_LUT_SIZE) end
    end
  else
    local x1,y1, x2,y2, x3,y3, x4,y4 = get_fade_bez(shape, dir, is_fade_out)
    for i = 0, FADE_LUT_SIZE do
      lut[i] = cbez_y(x1,y1, x2,y2, x3,y3, x4,y4, i / FADE_LUT_SIZE)
    end
  end
  c.shape = shape; c.dir = dir
  return lut
end
fade_curves.get_fade_lut = get_fade_lut

local function fade_lut_lookup(lut, t)
  if t <= 0 then return lut[0] end
  if t >= 1 then return lut[FADE_LUT_SIZE] end
  local idx = t * FADE_LUT_SIZE
  local i = math.floor(idx)
  return lut[i] + (lut[i + 1] - lut[i]) * (idx - i)
end
fade_curves.fade_lut_lookup = fade_lut_lookup

-- Shape icon LUTs (pre-computed from shape_icon_fns for icon rendering)
local shape_icon_luts = {}
for s = 0, 6 do
  local lut = {}
  local fn = shape_icon_fns[s]
  for i = 0, FADE_LUT_SIZE do
    lut[i] = fn(i / FADE_LUT_SIZE)
  end
  shape_icon_luts[s] = lut
end
fade_curves.shape_icon_luts = shape_icon_luts

return fade_curves
