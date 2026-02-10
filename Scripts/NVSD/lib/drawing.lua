-- NVSD_ItemView - Drawing Module
-- Waveform, ruler, overlays, markers, info bar

local drawing = {}

-- Linear passthrough (matches REAPER's native waveform display - no compression)
local function power_curve(value)
  return value
end

-- Fade system: exact cubic Bezier curves from REAPER (SWS/BR_Util.cpp, courtesy of Cockos)
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

-- Cached fade LUT for per-pixel rendering (avoids Newton's per pixel)
local FADE_LUT_SIZE = 256
local fade_lut_cache = {
  fi = { shape = -1, dir = -999, lut = {} },
  fo = { shape = -1, dir = -999, lut = {} },
}

local function get_fade_lut(shape, dir, is_fade_out)
  local c = fade_lut_cache[is_fade_out and "fo" or "fi"]
  if c.shape == shape and c.dir == dir then return c.lut end
  local lut = c.lut
  if math.abs(dir) < 0.001 and shape >= 0 and shape <= 6 then
    -- dir=0: use exact mathematical curves (matches REAPER's canonical shapes)
    local fn = shape_icon_fns[shape]
    if is_fade_out then
      for i = 0, FADE_LUT_SIZE do lut[i] = fn(1 - i / FADE_LUT_SIZE) end
    else
      for i = 0, FADE_LUT_SIZE do lut[i] = fn(i / FADE_LUT_SIZE) end
    end
  else
    -- dir!=0: use Bezier interpolation system for curvature-adjusted curves
    local x1,y1, x2,y2, x3,y3, x4,y4 = get_fade_bez(shape, dir, is_fade_out)
    for i = 0, FADE_LUT_SIZE do
      lut[i] = cbez_y(x1,y1, x2,y2, x3,y3, x4,y4, i / FADE_LUT_SIZE)
    end
  end
  c.shape = shape; c.dir = dir
  return lut
end

local function fade_lut_lookup(lut, t)
  if t <= 0 then return lut[0] end
  if t >= 1 then return lut[FADE_LUT_SIZE] end
  local idx = t * FADE_LUT_SIZE
  local i = math.floor(idx)
  return lut[i] + (lut[i + 1] - lut[i]) * (idx - i)
end

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

-- Compute the curve Y position at a given t (0..1) within the fade region.
-- Returns the pixel Y where the curve line sits.
function drawing.get_fade_curve_y(t, fade_shape, is_fade_in, fade_dir, fade_top_y, wave_y, wave_height)
  local vol = eval_fade(t, fade_shape, fade_dir or 0, not is_fade_in)
  local curve_range = wave_y + wave_height - fade_top_y
  return fade_top_y + curve_range * (1 - vol)
end

-- Draw curve-shaped darkening overlay above the fade curve, with curve line on top
-- fade_top_y: top of fade curve region
-- is_hovered: when true, curve line is drawn brighter and thicker
-- fade_dir: curvature bend from D_FADEINDIR/D_FADEOUTDIR (-1 to 1), default 0
function drawing.draw_fade_overlay(draw_list, fade_start_px, fade_end_px,
                                    fade_top_y, wave_y, wave_height,
                                    fade_shape, is_fade_in, is_hovered, fade_dir)
  local width = fade_end_px - fade_start_px
  if width < 2 then return end

  local is_fade_out = not is_fade_in
  local lut = get_fade_lut(fade_shape, fade_dir or 0, is_fade_out)
  local tint_alpha = is_hovered and 0x40 or 0x30
  local DL_AddLine = reaper.ImGui_DrawList_AddLine
  local DL_PathLineTo = reaper.ImGui_DrawList_PathLineTo
  local DL_PathStroke = reaper.ImGui_DrawList_PathStroke

  -- Curve spans from fade_top_y (vol=0, fully attenuated) to wave_y+wave_height (vol=1, full volume)
  local curve_range = wave_y + wave_height - fade_top_y

  -- Darken only above the curve (the attenuated region)
  local step = 2  -- 2px columns for performance
  local width_floor = math.floor(width)
  for px = 0, width_floor, step do
    local t = px / width
    if t > 1 then t = 1 end
    local vol = fade_lut_lookup(lut, t)
    local curve_y = fade_top_y + curve_range * (1 - vol)
    if curve_y > fade_top_y then
      DL_AddLine(draw_list, fade_start_px + px, fade_top_y, fade_start_px + px, curve_y, tint_alpha, step)
    end
  end
  -- Final column at t=1
  do
    local vol = lut[FADE_LUT_SIZE]
    local curve_y = fade_top_y + curve_range * (1 - vol)
    if curve_y > fade_top_y then
      DL_AddLine(draw_list, fade_start_px + width_floor, fade_top_y, fade_start_px + width_floor, curve_y, tint_alpha, step)
    end
  end

  -- Draw curve line on top (brighter when hovered)
  if DL_PathLineTo and width > 4 then
    local line_step = math.max(1, math.floor(width / 200))
    for px = 0, width_floor, line_step do
      local t = px / width
      if t > 1 then t = 1 end
      DL_PathLineTo(draw_list, fade_start_px + px, fade_top_y + curve_range * (1 - fade_lut_lookup(lut, t)))
    end
    -- Always include the final point at t=1
    DL_PathLineTo(draw_list, fade_end_px, fade_top_y + curve_range * (1 - lut[FADE_LUT_SIZE]))
    local line_color = is_hovered and 0xFFFFFFCC or 0xFFFFFF80
    local line_width = is_hovered and 2.0 or 1.5
    DL_PathStroke(draw_list, line_color, 0, line_width)
  end
end

-- Draw fade handle (square extending from fade boundary, width may be clipped)
function drawing.draw_fade_handle(draw_list, x, y, is_hovered, is_dragging, is_fade_in, config, extent)
  local size = config.FADE_HANDLE_SIZE
  extent = extent or (size * 2)
  if extent < 2 then return end  -- too small to draw
  local fill = (is_hovered or is_dragging) and 0xAAAAAAAA or 0x88888880
  local border = (is_hovered or is_dragging) and 0xCCCCCCFF or 0x999999AA

  local x1, x2
  if is_fade_in then
    x1 = x
    x2 = x + extent
  else
    x1 = x - extent
    x2 = x
  end

  reaper.ImGui_DrawList_AddRectFilled(draw_list, x1, y - size, x2, y + size, fill)
  reaper.ImGui_DrawList_AddRect(draw_list, x1, y - size, x2, y + size, border, 0, 0, 1)
end

-- Draw fade hint: small curved triangle in the upper corner of a marker.
-- Fade-in (at start marker): |)  shape in top-right corner
-- Fade-out (at end marker):  (|  shape in top-left corner (mirrored)
function drawing.draw_fade_hint(draw_list, marker_x, top_y, is_fade_in)
  local size = 26
  local y0 = top_y + 1  -- +1 to stay below ruler border
  local x1, y1, x2, y2, x3, y3

  if is_fade_in then
    -- |/ triangle at start marker
    x1, y1 = marker_x, y0            -- top-left
    x2, y2 = marker_x, y0 + size     -- bottom-left
    x3, y3 = marker_x + size, y0     -- top-right
  else
    -- \| triangle at end marker (mirrored)
    x1, y1 = marker_x, y0            -- top-right
    x2, y2 = marker_x, y0 + size     -- bottom-right
    x3, y3 = marker_x - size, y0     -- top-left
  end

  -- Filled triangle + outline for smooth anti-aliased edges
  reaper.ImGui_DrawList_AddTriangleFilled(draw_list, x1, y1, x2, y2, x3, y3, 0xFFFFFF30)
  reaper.ImGui_DrawList_AddTriangle(draw_list, x1, y1, x2, y2, x3, y3, 0xFFFFFF50, 1.0)
end

-- Draw fade shape icon (curve line only, no fill or border)
function drawing.draw_fade_shape_icon(draw_list, x, y, w, h, shape, is_fade_in)
  local DL_PathLineTo = reaper.ImGui_DrawList_PathLineTo
  local DL_PathStroke = reaper.ImGui_DrawList_PathStroke
  if not DL_PathLineTo then return end

  local lut = shape_icon_luts[shape] or shape_icon_luts[0]
  local steps = 40
  for i = 0, steps do
    local t = i / steps
    -- Fade-out: time-reverse (read LUT backwards) to match actual rendering
    local vol = is_fade_in and fade_lut_lookup(lut, t) or fade_lut_lookup(lut, 1 - t)
    DL_PathLineTo(draw_list, x + t * w, y + h - vol * h)
  end
  DL_PathStroke(draw_list, 0xCCCCCCFF, 0, 2.0)
end

-- Waveform computation cache (avoids recomputing Phase 1+2 when inputs unchanged)
local wf_cache = { valid = false }

-- Info bar metadata cache (avoids per-frame REAPER API calls)
local info_cache = { source = false }

-- Invalidate waveform computation cache (call when item changes, peaks reload, etc.)
function drawing.invalidate_wf_cache()
  wf_cache.valid = false
end

-- Color helpers (module-level to avoid per-call closure creation)
local function color_with_alpha(color, alpha)
  return ((color >> 8) << 8) | alpha
end
local function darken_color(color, factor)
  local r = ((color >> 24) & 0xFF) * factor
  local g = ((color >> 16) & 0xFF) * factor
  local b = ((color >> 8) & 0xFF) * factor
  local a = color & 0xFF
  return (math.floor(r) << 24) | (math.floor(g) << 16) | (math.floor(b) << 8) | a
end

-- Draw dashed vertical line
function drawing.draw_dashed_line(draw_list, x, y1, y2, color, dash_length, gap_length, line_width)
  dash_length = dash_length or 5
  gap_length = gap_length or 3
  line_width = line_width or 1
  local y = y1
  while y < y2 do
    local dash_end = math.min(y + dash_length, y2)
    reaper.ImGui_DrawList_AddLine(draw_list, x, y, x, dash_end, color, line_width)
    y = y + dash_length + gap_length
  end
end

-- Draw ruler bar with bar numbers
-- Compute shared grid geometry (used by both grid lines and ruler)
local function compute_grid_params(x, width, view_start, view_length, item_position, start_offset, playrate, config, utils)
  local function time_to_px(t)
    return x + ((t - view_start) / view_length) * width
  end

  local view_end = view_start + view_length
  local project_start = utils.source_to_project_time(view_start, item_position, start_offset, playrate)
  local project_end = utils.source_to_project_time(view_end, item_position, start_offset, playrate)

  local bpm, bpi = reaper.GetProjectTimeSignature2(0, project_start)
  local beats_per_bar = math.floor(bpi)
  if beats_per_bar < 1 then beats_per_bar = 4 end

  local _, start_measures = reaper.TimeMap2_timeToBeats(0, project_start)
  local first_bar = math.floor(start_measures)

  local min_bar_spacing = 80
  local avg_bar_duration = 60 / bpm * beats_per_bar
  local px_per_bar = (avg_bar_duration / view_length) * width
  local bar_skip = math.max(1, math.ceil(min_bar_spacing / px_per_bar))
  if bar_skip > 1 then
    local power = math.ceil(math.log(bar_skip) / math.log(2))
    bar_skip = 2 ^ power
  end

  local px_per_beat = px_per_bar / beats_per_bar

  -- Sub-beat subdivision depth (powers of 2: 2=eighths, 4=sixteenths, 8=32nds, etc.)
  local finest_sub = 1
  while (px_per_beat / (finest_sub * 2)) >= 8 do
    finest_sub = finest_sub * 2
  end
  local quarter_step = finest_sub >= 4 and (finest_sub / 4) or nil

  -- Dim a color's RGB channels by a factor (preserves alpha)
  local function dim_color(color, factor)
    local a = color % 256
    local b = math.floor(color / 256) % 256
    local g = math.floor(color / 65536) % 256
    local r = math.floor(color / 16777216) % 256
    r = math.floor(r * factor)
    g = math.floor(g * factor)
    b = math.floor(b * factor)
    return r * 16777216 + g * 65536 + b * 256 + a
  end

  return {
    time_to_px = time_to_px,
    view_start = view_start, view_end = view_end,
    project_start = project_start, project_end = project_end,
    beats_per_bar = beats_per_bar, first_bar = first_bar,
    bar_skip = bar_skip, px_per_beat = px_per_beat,
    finest_sub = finest_sub, quarter_step = quarter_step,
    sub_grid_color = dim_color(config.COLOR_GRID_BEAT, 0.7),
    sub_label_color = dim_color(0x555555FF, 0.75),
    -- Ruler tick colors: derive from RULER_TICK so they're visible on ruler bg
    beat_tick_color = config.COLOR_RULER_TICK,
    sub_tick_color = dim_color(config.COLOR_RULER_TICK, 0.7),
    dim_color = dim_color,
  }
end

-- Draw vertical grid lines through the waveform area (call BEFORE waveform)
function drawing.draw_grid_lines(draw_list, x, wave_y, width, wave_height,
                                  view_start, view_length, item_position, start_offset, playrate, config, utils)
  local g = compute_grid_params(x, width, view_start, view_length, item_position, start_offset, playrate, config, utils)
  local show_beat_grid = g.px_per_beat >= 20

  local bar = g.first_bar
  local iterations = 0
  while iterations < 1000 do
    iterations = iterations + 1
    local bar_project_time = reaper.TimeMap2_beatsToTime(0, 0, bar)
    if bar_project_time > g.project_end then break end

    local bar_source_time = utils.project_to_source_time(bar_project_time, item_position, start_offset, playrate)
    if bar_source_time >= g.view_start and bar_source_time <= g.view_end then
      local bar_px = g.time_to_px(bar_source_time)
      reaper.ImGui_DrawList_AddLine(draw_list, bar_px, wave_y, bar_px, wave_y + wave_height, config.COLOR_GRID_BAR, 1)
    end

    -- Beat grid lines
    if show_beat_grid then
      for beat = 1, g.beats_per_bar - 1 do
        local beat_project_time = reaper.TimeMap2_beatsToTime(0, beat, bar)
        if beat_project_time > g.project_end then break end
        local beat_source_time = utils.project_to_source_time(beat_project_time, item_position, start_offset, playrate)
        if beat_source_time >= g.view_start and beat_source_time <= g.view_end then
          reaper.ImGui_DrawList_AddLine(draw_list, g.time_to_px(beat_source_time), wave_y, g.time_to_px(beat_source_time), wave_y + wave_height, config.COLOR_GRID_BEAT, 1)
        end
      end
    end

    -- Sub-beat grid lines
    if g.finest_sub >= 2 then
      for beat = 0, g.beats_per_bar - 1 do
        for sub = 1, g.finest_sub - 1 do
          local sub_project_time = reaper.TimeMap2_beatsToTime(0, beat + (sub / g.finest_sub), bar)
          if sub_project_time > g.project_end then break end
          local sub_source_time = utils.project_to_source_time(sub_project_time, item_position, start_offset, playrate)
          if sub_source_time >= g.view_start and sub_source_time <= g.view_end then
            local is_quarter = g.quarter_step and (sub % g.quarter_step == 0)
            local grid_col = is_quarter and config.COLOR_GRID_BEAT or g.sub_grid_color
            reaper.ImGui_DrawList_AddLine(draw_list, g.time_to_px(sub_source_time), wave_y, g.time_to_px(sub_source_time), wave_y + wave_height, grid_col, 1)
          end
        end
      end
    end

    bar = bar + 1
  end
end

-- Draw ruler with ticks and labels (call AFTER waveform)
function drawing.draw_ruler_and_grid(draw_list, x, ruler_y, wave_y, width, ruler_height, wave_height,
                                      view_start, view_length, item_position, start_offset, playrate, config, utils)
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x, ruler_y, x + width, ruler_y + ruler_height, config.COLOR_RULER_BG)

  local g = compute_grid_params(x, width, view_start, view_length, item_position, start_offset, playrate, config, utils)
  local show_beat_labels = g.px_per_beat >= 70
  local show_beat_ticks = g.px_per_beat >= 28
  -- Sub-beat ruler ticks: only at quarter-beat positions, need decent spacing
  local show_sub_ticks = g.quarter_step and (g.px_per_beat / 4) >= 35
  -- Sub-beat labels: only when really zoomed in (each quarter-beat has plenty of room)
  local show_sub_labels = g.quarter_step and (g.px_per_beat / 4) >= 90
  local beat_label_color = 0x555555FF

  local bar = g.first_bar
  local iterations = 0
  while iterations < 1000 do
    iterations = iterations + 1
    local bar_project_time = reaper.TimeMap2_beatsToTime(0, 0, bar)
    if bar_project_time > g.project_end then break end

    local bar_source_time = utils.project_to_source_time(bar_project_time, item_position, start_offset, playrate)

    if bar_source_time >= g.view_start and bar_source_time <= g.view_end then
      local bar_px = g.time_to_px(bar_source_time)
      local bar_num = bar + 1
      if bar_num % g.bar_skip == 1 or g.bar_skip == 1 then
        reaper.ImGui_DrawList_AddLine(draw_list, bar_px, ruler_y, bar_px, ruler_y + ruler_height, config.COLOR_RULER_TICK, 1)
        reaper.ImGui_DrawList_AddText(draw_list, bar_px + 3, ruler_y + 3, config.COLOR_RULER_TEXT, tostring(bar_num))
      else
        reaper.ImGui_DrawList_AddLine(draw_list, bar_px, ruler_y + ruler_height - 4, bar_px, ruler_y + ruler_height, config.COLOR_RULER_TICK, 1)
      end
    end

    -- Beat ticks and labels in ruler
    if show_beat_ticks then
      for beat = 1, g.beats_per_bar - 1 do
        local beat_project_time = reaper.TimeMap2_beatsToTime(0, beat, bar)
        if beat_project_time > g.project_end then break end
        local beat_source_time = utils.project_to_source_time(beat_project_time, item_position, start_offset, playrate)
        if beat_source_time >= g.view_start and beat_source_time <= g.view_end then
          local beat_px = g.time_to_px(beat_source_time)
          local tick_top = ruler_y + ruler_height - math.floor(ruler_height * 0.5)
          reaper.ImGui_DrawList_AddLine(draw_list, beat_px, tick_top, beat_px, ruler_y + ruler_height, g.beat_tick_color, 1)
          if show_beat_labels and (g.bar_skip == 1 or ((bar + 1) % g.bar_skip == 1)) then
            reaper.ImGui_DrawList_AddText(draw_list, beat_px + 3, ruler_y + 3, beat_label_color, (bar + 1) .. "." .. (beat + 1))
          end
        end
      end
    end

    -- Sub-beat ticks and labels in ruler (only quarter-beat positions, not every fine subdivision)
    if g.quarter_step and (show_sub_ticks or show_sub_labels) then
      local bar_has_labels = g.bar_skip == 1 or ((bar + 1) % g.bar_skip == 1)
      for beat = 0, g.beats_per_bar - 1 do
        for q = 1, 3 do
          local beat_frac = beat + (q / 4)
          local sub_project_time = reaper.TimeMap2_beatsToTime(0, beat_frac, bar)
          if sub_project_time > g.project_end then break end
          local sub_source_time = utils.project_to_source_time(sub_project_time, item_position, start_offset, playrate)
          if sub_source_time >= g.view_start and sub_source_time <= g.view_end then
            local sub_px = g.time_to_px(sub_source_time)

            if show_sub_ticks then
              local tick_h = math.floor(ruler_height * 0.3)
              reaper.ImGui_DrawList_AddLine(draw_list, sub_px, ruler_y + ruler_height - tick_h, sub_px, ruler_y + ruler_height, g.sub_tick_color, 1)
            end

            if show_sub_labels and bar_has_labels then
              reaper.ImGui_DrawList_AddText(draw_list, sub_px + 3, ruler_y + 3, g.sub_label_color, (bar + 1) .. "." .. (beat + 1) .. "." .. (q + 1))
            end
          end
        end
      end
    end

    bar = bar + 1
  end

  reaper.ImGui_DrawList_AddLine(draw_list, x, ruler_y + ruler_height, x + width, ruler_y + ruler_height, config.COLOR_GRID_BAR, 1)
end

-- Draw bottom time ruler showing source time
function drawing.draw_time_ruler(draw_list, x, y, width, height, view_start, view_length, config, utils)
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + width, y + height, config.COLOR_RULER_BG)
  reaper.ImGui_DrawList_AddLine(draw_list, x, y, x + width, y, config.COLOR_GRID_BAR, 1)

  local function time_to_px(t)
    return x + ((t - view_start) / view_length) * width
  end

  local view_end = view_start + view_length
  local target_label_spacing_px = 80
  local seconds_per_pixel = view_length / width
  local target_interval = seconds_per_pixel * target_label_spacing_px

  local nice_intervals = {0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600}
  local interval = nice_intervals[#nice_intervals]
  for _, ni in ipairs(nice_intervals) do
    if ni >= target_interval then
      interval = ni
      break
    end
  end

  local show_ms = interval < 1
  local first_tick = math.floor(view_start / interval) * interval

  local tick = first_tick
  local max_iterations = 200
  local iterations = 0

  while tick <= view_end and iterations < max_iterations do
    iterations = iterations + 1
    local tick_px = time_to_px(tick)

    if tick_px >= x and tick_px <= x + width then
      local tick_height = 6
      reaper.ImGui_DrawList_AddLine(draw_list, tick_px, y, tick_px, y + tick_height, config.COLOR_RULER_TICK, 1)
      local label = utils.format_source_time(tick, show_ms)
      reaper.ImGui_DrawList_AddText(draw_list, tick_px + 3, y + 3, config.COLOR_RULER_TEXT, label)
    end

    tick = tick + interval
  end
end

-- Draw file info bar at the top
-- Returns: mouse_over_filename, gear_clicked, tab_clicked
function drawing.draw_info_bar(draw_list, ctx, x, y, width, height, source, file_path, mouse_x, mouse_y, item, config, utils, actual_num_channels, state)
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + width, y + height, config.COLOR_INFO_BAR_BG)
  reaper.ImGui_DrawList_AddLine(draw_list, x, y + height, x + width, y + height, 0x333333FF, 1)

  -- Gear icon (settings) on the right
  local gear_size = 12
  local gear_padding = 4
  local gear_x = x + width - gear_size - gear_padding
  local gear_y = y + (height - gear_size) / 2
  local gear_cx = gear_x + gear_size / 2
  local gear_cy = gear_y + gear_size / 2

  local mouse_in_gear = mouse_x >= gear_x - 2 and mouse_x <= gear_x + gear_size + 2
                        and mouse_y >= gear_y - 2 and mouse_y <= gear_y + gear_size + 2

  local gear_color = mouse_in_gear and 0xCCCCCCFF or 0x888888FF

  -- Draw gear icon (simple cog shape)
  local outer_r = gear_size / 2
  local inner_r = outer_r * 0.5
  local teeth = 6

  -- Outer circle with teeth
  reaper.ImGui_DrawList_AddCircleFilled(draw_list, gear_cx, gear_cy, outer_r * 0.75, gear_color, 16)

  -- Draw teeth
  for i = 0, teeth - 1 do
    local angle = (i / teeth) * math.pi * 2
    local tooth_x = gear_cx + math.cos(angle) * outer_r * 0.95
    local tooth_y = gear_cy + math.sin(angle) * outer_r * 0.95
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, tooth_x, tooth_y, outer_r * 0.25, gear_color, 8)
  end

  -- Inner hole
  reaper.ImGui_DrawList_AddCircleFilled(draw_list, gear_cx, gear_cy, inner_r * 0.6, config.COLOR_INFO_BAR_BG, 12)

  local gear_clicked = mouse_in_gear and reaper.ImGui_IsMouseClicked(ctx, 0)

  -- Tab buttons (centered in bar)
  local tab_height = height - 6
  local tab_y = y + 3
  local tab_padding_h = 10
  local tab_gap = 2

  local tabs = { "Sample", "Envelopes" }

  -- Measure total width of all tabs, then center the group
  local tab_widths = {}
  local total_tab_width = 0
  for i = 1, #tabs do
    local tw = reaper.ImGui_CalcTextSize(ctx, tabs[i])
    tab_widths[i] = tw + tab_padding_h * 2
    total_tab_width = total_tab_width + tab_widths[i]
  end
  total_tab_width = total_tab_width + tab_gap * (#tabs - 1)

  local tab_rects = {}
  local cursor_left = x + (width - total_tab_width) / 2
  for i = 1, #tabs do
    local label = tabs[i]
    local key = label:lower()
    local tx1 = cursor_left
    local tx2 = cursor_left + tab_widths[i]
    tab_rects[i] = { x1 = tx1, x2 = tx2, label = label, key = key }
    cursor_left = tx2 + tab_gap
  end

  -- Draw tabs
  local active_tab = state and state.active_view_tab or "sample"
  local tab_clicked = nil

  for _, tab in ipairs(tab_rects) do
    local is_active = tab.key == active_tab
    local mouse_in_tab = mouse_x >= tab.x1 and mouse_x <= tab.x2
                         and mouse_y >= tab_y and mouse_y <= tab_y + tab_height

    -- Rectangle background: highlighted for active, subtle for hover
    if is_active then
      reaper.ImGui_DrawList_AddRectFilled(draw_list, tab.x1, tab_y, tab.x2, tab_y + tab_height, 0x444444FF)
      reaper.ImGui_DrawList_AddRect(draw_list, tab.x1, tab_y, tab.x2, tab_y + tab_height, 0x666666FF, 0, 0, 1)
    elseif mouse_in_tab then
      reaper.ImGui_DrawList_AddRectFilled(draw_list, tab.x1, tab_y, tab.x2, tab_y + tab_height, 0x333333FF)
    end

    local text_color
    if is_active then
      text_color = config.COLOR_BTN_TEXT
    elseif mouse_in_tab then
      text_color = 0xAAAAAAFF
    else
      text_color = 0x888888FF
    end

    local tw = reaper.ImGui_CalcTextSize(ctx, tab.label)
    local text_x = tab.x1 + (tab.x2 - tab.x1 - tw) / 2
    local text_y = tab_y + (tab_height - 13) / 2
    reaper.ImGui_DrawList_AddText(draw_list, text_x, text_y, text_color, tab.label)

    if mouse_in_tab and reaper.ImGui_IsMouseClicked(ctx, 0) then
      tab_clicked = tab.key
    end
  end

  if tab_clicked and state then
    state.active_view_tab = tab_clicked
  end

  -- Right boundary for filename text (don't overlap tabs)
  local text_max_x = (#tab_rects > 0) and (tab_rects[1].x1 - 8) or (gear_x - 8)

  -- Mute toggle
  local mute_size = 10
  local mute_x = x + 4
  local mute_y = y + (height - mute_size) / 2

  local is_muted = item and reaper.GetMediaItemInfo_Value(item, "B_MUTE") == 1

  local mouse_in_mute = mouse_x >= mute_x and mouse_x <= mute_x + mute_size
                        and mouse_y >= mute_y and mouse_y <= mute_y + mute_size

  local border_color = mouse_in_mute and 0x8AD98AFF or config.COLOR_WAVEFORM
  reaper.ImGui_DrawList_AddRect(draw_list, mute_x, mute_y, mute_x + mute_size, mute_y + mute_size, border_color, 0, 0, 1)

  if not is_muted then
    local fill_color = mouse_in_mute and 0x6ABF6AFF or config.COLOR_WAVEFORM
    reaper.ImGui_DrawList_AddRectFilled(draw_list, mute_x + 1, mute_y + 1, mute_x + mute_size - 1, mute_y + mute_size - 1, fill_color)
  end

  if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_mute then
    if item then
      reaper.Undo_BeginBlock()
      local new_mute = is_muted and 0 or 1
      reaper.SetMediaItemInfo_Value(item, "B_MUTE", new_mute)
      reaper.UpdateArrange()
      reaper.Undo_EndBlock("NVSD_ItemView: Toggle mute", -1)
    end
  end

  -- Waveform icon
  local icon_x = mute_x + mute_size + 6
  local icon_center_y = y + height / 2
  local icon_max_h = height * 0.6

  local bar_widths = {2, 2, 2, 2, 2}
  local bar_heights = {0.3, 0.7, 1.0, 0.6, 0.4}
  local bar_gap = 1
  local current_x = icon_x

  for i = 1, #bar_heights do
    local bar_h = icon_max_h * bar_heights[i]
    local bar_y1 = icon_center_y - bar_h / 2
    local bar_y2 = icon_center_y + bar_h / 2
    reaper.ImGui_DrawList_AddRectFilled(draw_list, current_x, bar_y1, current_x + bar_widths[i], bar_y2, config.COLOR_INFO_BAR_ICON)
    current_x = current_x + bar_widths[i] + bar_gap
  end

  local text_x = current_x + 4
  local text_y = y + 3

  -- Cache metadata per source (avoids REAPER API calls every frame)
  local file_name, sample_rate, num_channels, bit_depth
  if info_cache.source == source and info_cache.file_path == file_path then
    file_name = info_cache.file_name
    sample_rate = info_cache.sample_rate
    num_channels = info_cache.num_channels
    bit_depth = info_cache.bit_depth
  else
    file_name = utils.get_file_name(file_path)
    sample_rate = source and reaper.GetMediaSourceSampleRate(source) or 0
    num_channels = (actual_num_channels and actual_num_channels > 0) and actual_num_channels or (source and reaper.GetMediaSourceNumChannels(source) or 0)
    bit_depth = utils.get_wav_bit_depth(file_path)
    info_cache.source = source
    info_cache.file_path = file_path
    info_cache.file_name = file_name
    info_cache.sample_rate = sample_rate
    info_cache.num_channels = num_channels
    info_cache.bit_depth = bit_depth
  end

  local meta_parts = {}

  if sample_rate > 0 then
    local sr_khz = sample_rate / 1000
    if sr_khz == math.floor(sr_khz) then
      table.insert(meta_parts, string.format("%d kHz", sr_khz))
    else
      table.insert(meta_parts, string.format("%.1f kHz", sr_khz))
    end
  end

  if bit_depth then
    table.insert(meta_parts, string.format("%d-bit", bit_depth))
  end

  if num_channels > 0 then
    if num_channels == 1 then
      table.insert(meta_parts, "Mono")
    elseif num_channels == 2 then
      table.insert(meta_parts, "Stereo")
    elseif num_channels == 6 then
      table.insert(meta_parts, "5.1ch")
    elseif num_channels == 8 then
      table.insert(meta_parts, "7.1ch")
    else
      table.insert(meta_parts, string.format("%d Ch", num_channels))
    end
  end

  local meta_text = table.concat(meta_parts, " · ")

  local file_name_width = reaper.ImGui_CalcTextSize(ctx, file_name)
  local file_name_end_x = text_x + file_name_width

  local mouse_over_filename = file_name ~= "" and
    mouse_x >= text_x and mouse_x <= file_name_end_x and
    mouse_y >= y and mouse_y <= y + height

  -- Clip filename + metadata so they don't overlap tabs
  reaper.ImGui_DrawList_PushClipRect(draw_list, text_x, y, text_max_x, y + height, true)

  if file_name ~= "" then
    local name_color = mouse_over_filename and 0xDDDDFFFF or config.COLOR_INFO_BAR_TEXT
    reaper.ImGui_DrawList_AddText(draw_list, text_x, text_y, name_color, file_name)

    if mouse_over_filename then
      local underline_y = text_y + 14
      reaper.ImGui_DrawList_AddLine(draw_list, text_x, underline_y, file_name_end_x, underline_y, name_color, 1)
    end
  end

  if file_name ~= "" and meta_text ~= "" then
    local separator = " · "
    reaper.ImGui_DrawList_AddText(draw_list, file_name_end_x, text_y, config.COLOR_INFO_BAR_TEXT, separator .. meta_text)
  elseif meta_text ~= "" then
    reaper.ImGui_DrawList_AddText(draw_list, text_x, text_y, config.COLOR_INFO_BAR_TEXT, meta_text)
  end

  reaper.ImGui_DrawList_PopClipRect(draw_list)

  if mouse_over_filename and reaper.ImGui_IsMouseClicked(ctx, 0) then
    reaper.Main_OnCommand(41623, 0)
    return true, false, nil
  end

  return mouse_over_filename, gear_clicked, tab_clicked
end

-- Draw waveform with per-view peaks (1:1 peak-to-pixel mapping)
-- peaks: per-view peaks from get_peaks_for_range (each peak maps to one pixel column)
-- view_start/view_length: pre-computed visible time range
-- pixel_step: 1 for full resolution, 2 for half (during REAPER interaction)
function drawing.draw_waveform(draw_list, x, y, width, height, peaks, start_offset, source_item_length, source_length, view_start, view_length, ruler_y, visual_gain, is_reversed, num_channels, config, pixel_step)
  if not peaks or peaks.count == 0 or source_length <= 0 then return 0, 0 end

  visual_gain = visual_gain or 1.0
  is_reversed = is_reversed or false
  num_channels = num_channels or 1
  pixel_step = pixel_step or 1

  local item_end = start_offset + source_item_length
  local view_end = view_start + view_length

  -- NOTE: Waveform BG is drawn by the caller before draw_grid_lines, so grid lines appear between bg and waveform

  if num_channels < 1 then num_channels = 1 end
  local channel_height = height / num_channels

  for ch = 1, num_channels do
    local ch_y = y + (ch - 1) * channel_height
    local center_y = ch_y + channel_height / 2
    reaper.ImGui_DrawList_AddLine(draw_list, x, center_y, x + width, center_y, config.COLOR_CENTERLINE, 1)
    if ch < num_channels then
      local sep_y = ch_y + channel_height
      reaper.ImGui_DrawList_AddLine(draw_list, x, sep_y, x + width, sep_y, 0x333333FF, 1)
    end
  end

  local function time_to_px(t)
    return x + ((t - view_start) / view_length) * width
  end

  local half_height = channel_height / 2 * 0.85

  local num_samples = math.floor(width / pixel_step)
  if num_samples < 1 then return 0, 0 end
  local time_per_pixel = view_length / num_samples

  -- Per-view peaks: direct access (no LOD needed — peaks are already at screen resolution)
  local num_peaks = peaks.count
  local peak_ch = peaks.channels
  local peak_mins = peaks.mins
  local peak_maxs = peaks.maxs

  -- Cache draw functions locally (reduces Lua→C lookup overhead per call)
  local DL_QuadFilled = reaper.ImGui_DrawList_AddQuadFilled
  local DL_AddLine = reaper.ImGui_DrawList_AddLine
  local DL_PathLineTo = reaper.ImGui_DrawList_PathLineTo
  local DL_PathStroke = reaper.ImGui_DrawList_PathStroke
  local has_path = DL_PathLineTo ~= nil

  -- Derive waveform colors from config (with alpha for fill)
  local OUTLINE_ACTIVE = config.COLOR_WAVEFORM
  local FILL_ACTIVE = color_with_alpha(darken_color(config.COLOR_WAVEFORM, 0.85), 0xCC)
  local OUTLINE_INACTIVE = config.COLOR_WAVEFORM_INACTIVE
  local FILL_INACTIVE = color_with_alpha(darken_color(config.COLOR_WAVEFORM_INACTIVE, 0.7), 0xCC)
  local OUTLINE_LOOPED = darken_color(config.COLOR_WAVEFORM, 0.75)
  local FILL_LOOPED = color_with_alpha(darken_color(config.COLOR_WAVEFORM, 0.6), 0xCC)

  -- Variables for Phase 1+2 output (declared here so cache can populate them)
  local col_tops, col_bots, col_colors, segments, n_segs
  local is_waveform_mode

  -- Check waveform computation cache (skip Phase 1+2 if inputs unchanged)
  if wf_cache.valid
      and wf_cache.view_start == view_start
      and wf_cache.view_length == view_length
      and wf_cache.start_offset == start_offset
      and wf_cache.item_end == item_end
      and wf_cache.source_length == source_length
      and wf_cache.visual_gain == visual_gain
      and wf_cache.is_reversed == is_reversed
      and wf_cache.num_channels == num_channels
      and wf_cache.num_samples == num_samples
      and wf_cache.width == width
      and wf_cache.height == height
      and wf_cache.x == x
      and wf_cache.y == y then
    -- Cache hit: reuse Phase 1+2 results
    col_tops = wf_cache.col_tops
    col_bots = wf_cache.col_bots
    col_colors = wf_cache.col_colors
    segments = wf_cache.segments
    n_segs = wf_cache.n_segs
    is_waveform_mode = wf_cache.is_waveform_mode
  else
    -- Cache miss: compute Phase 1+2
    is_waveform_mode = peaks.output_mode == 1

    -- Phase 1: 1:1 peak-to-pixel mapping (peaks loaded for visible range)
    -- Reuse tables from previous cache if available, else create new
    col_tops = wf_cache.col_tops or {}   -- col_tops[ch][i] = top_y for pixel i
    col_bots = wf_cache.col_bots or {}   -- col_bots[ch][i] = bot_y for pixel i
    col_colors = wf_cache.col_colors or {} -- col_colors[i] = 1(active) / 2(inactive) / 3(looped)
    for ch = 1, num_channels do
      col_tops[ch] = col_tops[ch] or {}
      col_bots[ch] = col_bots[ch] or {}
    end

    for i = 0, num_samples - 1 do
      local t = view_start + i * time_per_pixel

      -- 1:1 peak index (reversed items: iterate peaks backwards)
      local peak_i = is_reversed and (num_peaks - 1 - i) or i
      if peak_i < 0 then peak_i = 0 end
      if peak_i >= num_peaks then peak_i = num_peaks - 1 end

      -- Color type
      local in_active = t >= start_offset and t <= item_end
      if in_active then
        col_colors[i] = (t < 0 or t >= source_length) and 3 or 1
      else
        col_colors[i] = 2
      end

      -- Y positions per channel (direct peak read, no range scanning)
      for ch = 1, num_channels do
        local flat_idx = peak_i * peak_ch + ch
        local center_y = y + (ch - 1) * channel_height + channel_height * 0.5

        if is_waveform_mode then
          -- Waveform mode: single sample value, draw symmetric around center
          local v = peak_maxs[flat_idx] or 0
          local raw = v * visual_gain
          if raw > 1 then raw = 1 elseif raw < -1 then raw = -1 end
          local extent = power_curve(math.abs(raw)) * half_height
          col_tops[ch][i] = center_y - extent
          col_bots[ch][i] = center_y + extent
        else
          -- Peaks mode: symmetric display using max(|min|, |max|)
          -- Some sources return broken min values (zero, positive, or near-zero).
          -- Always draw symmetric around center — matches standard DAW clip views.
          local v_min = peak_mins[flat_idx] or 0
          local v_max = peak_maxs[flat_idx] or 0
          local v_abs = math.abs(v_min)
          local v_abs_max = math.abs(v_max)
          if v_abs_max > v_abs then v_abs = v_abs_max end
          local raw = v_abs * visual_gain
          if raw > 1 then raw = 1 end
          local scaled = power_curve(raw)
          local top_y = center_y - scaled * half_height
          local bot_y = center_y + scaled * half_height
          if bot_y - top_y < 1 then
            top_y = center_y - 0.5
            bot_y = center_y + 0.5
          end
          col_tops[ch][i] = top_y
          col_bots[ch][i] = bot_y
        end
      end
    end

    -- Phase 2: Build color segments (runs of same color type)
    segments = {}
    n_segs = 0
    local seg_start = 0
    local seg_color = col_colors[0]
    for i = 1, num_samples - 1 do
      if col_colors[i] ~= seg_color then
        n_segs = n_segs + 1
        segments[n_segs] = {seg_start, i - 1, seg_color}
        seg_start = i
        seg_color = col_colors[i]
      end
    end
    n_segs = n_segs + 1
    segments[n_segs] = {seg_start, num_samples - 1, seg_color}

    -- Store in cache for next frame
    wf_cache.valid = true
    wf_cache.view_start = view_start
    wf_cache.view_length = view_length
    wf_cache.start_offset = start_offset
    wf_cache.item_end = item_end
    wf_cache.source_length = source_length
    wf_cache.visual_gain = visual_gain
    wf_cache.is_reversed = is_reversed
    wf_cache.num_channels = num_channels
    wf_cache.num_samples = num_samples
    wf_cache.width = width
    wf_cache.height = height
    wf_cache.x = x
    wf_cache.y = y
    wf_cache.col_tops = col_tops
    wf_cache.col_bots = col_bots
    wf_cache.col_colors = col_colors
    wf_cache.segments = segments
    wf_cache.n_segs = n_segs
    wf_cache.is_waveform_mode = is_waveform_mode
  end

  -- Phase 3: Render (always runs — ImGui immediate mode requires redrawing every frame)
  local fill_lut = {[1] = FILL_ACTIVE, [2] = FILL_INACTIVE, [3] = FILL_LOOPED}
  local outline_lut = {[1] = OUTLINE_ACTIVE, [2] = OUTLINE_INACTIVE, [3] = OUTLINE_LOOPED}
  for si = 1, n_segs do
    local s_start = segments[si][1]
    local s_stop = segments[si][2]
    local fill_color = fill_lut[segments[si][3]]
    local outline_color = outline_lut[segments[si][3]]

    for ch = 1, num_channels do
      local tops = col_tops[ch]
      local bots = col_bots[ch]

      -- Fill: vertical bars from top to bottom per pixel column
      for i = s_start, s_stop do
        local px = x + i * pixel_step
        DL_AddLine(draw_list, px, tops[i], px, bots[i], fill_color, pixel_step)
      end

      -- Outlines: batched via path API (reduces GPU draw commands)
      local draw_from = (s_start == 0) and 1 or s_start
      if has_path and s_stop > s_start then
        -- Top outline
        for i = s_start, s_stop do
          DL_PathLineTo(draw_list, x + i * pixel_step, tops[i])
        end
        DL_PathStroke(draw_list, outline_color, 0, 1)
        -- Bottom outline
        for i = s_start, s_stop do
          DL_PathLineTo(draw_list, x + i * pixel_step, bots[i])
        end
        DL_PathStroke(draw_list, outline_color, 0, 1)
      else
        -- Fallback: individual lines
        for i = draw_from, s_stop do
          local px_prev = x + (i - 1) * pixel_step
          local px_curr = x + i * pixel_step
          DL_AddLine(draw_list, px_prev, tops[i - 1], px_curr, tops[i], outline_color, 1)
          DL_AddLine(draw_list, px_prev, bots[i - 1], px_curr, bots[i], outline_color, 1)
        end
      end
    end
  end

  -- Draw loop boundary markers
  local COLOR_BOUNDS = 0x888888FF
  local bounds_top = ruler_y or y
  local bounds_line_width = 1
  local original_line_width = 3

  local orig_start_px = time_to_px(0)
  local orig_end_px = time_to_px(source_length)

  if orig_start_px >= x and orig_start_px <= x + width then
    drawing.draw_dashed_line(draw_list, orig_start_px, bounds_top, y + height, COLOR_BOUNDS, nil, nil, original_line_width)
  end
  if orig_end_px >= x and orig_end_px <= x + width then
    drawing.draw_dashed_line(draw_list, orig_end_px, bounds_top, y + height, COLOR_BOUNDS, nil, nil, original_line_width)
  end

  local boundary = -source_length
  while boundary >= view_start do
    local boundary_px = time_to_px(boundary)
    if boundary_px >= x and boundary_px <= x + width then
      drawing.draw_dashed_line(draw_list, boundary_px, bounds_top, y + height, COLOR_BOUNDS, nil, nil, bounds_line_width)
    end
    boundary = boundary - source_length
  end

  boundary = source_length * 2
  while boundary <= view_end do
    local boundary_px = time_to_px(boundary)
    if boundary_px >= x and boundary_px <= x + width then
      drawing.draw_dashed_line(draw_list, boundary_px, bounds_top, y + height, COLOR_BOUNDS, nil, nil, bounds_line_width)
    end
    boundary = boundary + source_length
  end

  -- Draw border around active region (clamped to source bounds for looped items)
  local clamped_start = math.max(0, math.min(source_length, start_offset))
  local clamped_end = math.max(0, math.min(source_length, item_end))
  local start_px = time_to_px(clamped_start) - x
  local end_px = time_to_px(clamped_end) - x

  if end_px > start_px then
    reaper.ImGui_DrawList_AddRect(draw_list,
      x + math.max(0, start_px), y + 2,
      x + math.min(width, end_px), y + height - 2,
      config.COLOR_BORDER, 0, 0, 2)
  end

  return start_px, end_px
end

-- Draw draggable marker
function drawing.draw_marker(draw_list, x, y, height, is_start, is_hovered, is_dragging, config)
  local color = (is_hovered or is_dragging) and config.COLOR_MARKER_HOVER or config.COLOR_MARKER

  reaper.ImGui_DrawList_AddLine(draw_list, x, y, x, y + height, color, 3)

  local handle_size = 7
  -- Anchor triangles at the outer edge of the 3px line (not the center)
  local bx = is_start and (x + 1) or (x - 1)
  local dir = is_start and 1 or -1

  -- Top triangle
  reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
    bx, y, bx + dir * handle_size, y + handle_size / 2, bx, y + handle_size, color)
  -- Bottom triangle
  reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
    bx, y + height - handle_size, bx + dir * handle_size, y + height - handle_size / 2, bx, y + height, color)
end

-- Draw playhead (vertical line with triangle indicator at top)
function drawing.draw_playhead(draw_list, x, y, height, config)
  reaper.ImGui_DrawList_AddLine(draw_list, x, y, x, y + height, config.COLOR_PLAYHEAD, 2)
  local tri_size = 6
  reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
    x - tri_size, y, x + tri_size, y, x, y + tri_size, config.COLOR_PLAYHEAD)
end

-- Draw preview cursor (static position marker where user clicked)
function drawing.draw_preview_cursor(draw_list, x, y, height)
  local color = 0xFFFFFF88  -- white, semi-transparent
  reaper.ImGui_DrawList_AddLine(draw_list, x, y, x, y + height, color, 1)
  -- Small downward triangle at top
  local tri_size = 4
  reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
    x - tri_size, y, x + tri_size, y, x, y + tri_size, color)
end

-- Draw preview playhead (moving position during CF_Preview playback)
function drawing.draw_preview_playhead(draw_list, x, y, height)
  local color = 0x4A90D9FF  -- accent blue
  reaper.ImGui_DrawList_AddLine(draw_list, x, y, x, y + height, color, 1.5)
end

-- Draw a knob
function drawing.draw_knob(draw_list, cx, cy, radius, angle, is_hovered, is_active, label, unit_text)
  local COLOR_KNOB_BG = 0x303030FF
  local COLOR_KNOB_BORDER = is_active and 0x6AB0F9FF or (is_hovered and 0x888888FF or 0x555555FF)
  local COLOR_KNOB_POINTER = 0xFFFFFFFF
  local COLOR_KNOB_ARC_BG = 0x404040FF
  local COLOR_KNOB_ARC = 0x4A90D9FF

  local num_segments = 32
  reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy, radius, COLOR_KNOB_BG, num_segments)
  reaper.ImGui_DrawList_AddCircle(draw_list, cx, cy, radius, COLOR_KNOB_BORDER, num_segments, 2)

  local arc_radius = radius + 4
  local min_angle = 2 * math.pi / 3
  local center_angle = -math.pi / 2

  local arc_segments = 30
  for i = 0, arc_segments - 1 do
    local sweep = 5 * math.pi / 3
    local a1 = min_angle + sweep * (i / arc_segments)
    local a2 = min_angle + sweep * ((i + 1) / arc_segments)
    local x1 = cx + math.cos(a1) * arc_radius
    local y1 = cy + math.sin(a1) * arc_radius
    local x2 = cx + math.cos(a2) * arc_radius
    local y2 = cy + math.sin(a2) * arc_radius
    reaper.ImGui_DrawList_AddLine(draw_list, x1, y1, x2, y2, COLOR_KNOB_ARC_BG, 3)
  end

  if math.abs(angle - center_angle) > 0.01 then
    local arc_start, arc_end
    if angle > center_angle then
      arc_start = center_angle
      arc_end = angle
      for i = 0, arc_segments - 1 do
        local a1 = arc_start + (arc_end - arc_start) * (i / arc_segments)
        local a2 = arc_start + (arc_end - arc_start) * ((i + 1) / arc_segments)
        local x1 = cx + math.cos(a1) * arc_radius
        local y1 = cy + math.sin(a1) * arc_radius
        local x2 = cx + math.cos(a2) * arc_radius
        local y2 = cy + math.sin(a2) * arc_radius
        reaper.ImGui_DrawList_AddLine(draw_list, x1, y1, x2, y2, COLOR_KNOB_ARC, 3)
      end
    else
      arc_start = angle
      arc_end = center_angle
      for i = 0, arc_segments - 1 do
        local a1 = arc_start + (arc_end - arc_start) * (i / arc_segments)
        local a2 = arc_start + (arc_end - arc_start) * ((i + 1) / arc_segments)
        local x1 = cx + math.cos(a1) * arc_radius
        local y1 = cy + math.sin(a1) * arc_radius
        local x2 = cx + math.cos(a2) * arc_radius
        local y2 = cy + math.sin(a2) * arc_radius
        reaper.ImGui_DrawList_AddLine(draw_list, x1, y1, x2, y2, COLOR_KNOB_ARC, 3)
      end
    end
  end

  local pointer_inner = radius * 0.3
  local pointer_outer = radius * 0.85
  local px1 = cx + math.cos(angle) * pointer_inner
  local py1 = cy + math.sin(angle) * pointer_inner
  local px2 = cx + math.cos(angle) * pointer_outer
  local py2 = cy + math.sin(angle) * pointer_outer
  reaper.ImGui_DrawList_AddLine(draw_list, px1, py1, px2, py2, COLOR_KNOB_POINTER, 2)

  if label then
    local lw = #label * 6
    reaper.ImGui_DrawList_AddText(draw_list, cx - lw / 2, cy - radius - 18, 0xAAAAAAFF, label)
  end
  if unit_text then
    reaper.ImGui_DrawList_AddText(draw_list, cx - 5, cy + radius + 2, 0x888888FF, unit_text)
  end
end

-- Draw a filled rectangle with beveled (chamfered) corners using ImGui path API
-- Gives the TCP-style look (flat-cut corners, not rounded)
function drawing.draw_beveled_rect(draw_list, x1, y1, x2, y2, fill_color, border_color, bevel)
  bevel = bevel or 4
  local DL_PathLineTo = reaper.ImGui_DrawList_PathLineTo
  local DL_PathFillConvex = reaper.ImGui_DrawList_PathFillConvex
  local DL_PathStroke = reaper.ImGui_DrawList_PathStroke

  if not DL_PathLineTo then
    -- Fallback: plain rectangle
    reaper.ImGui_DrawList_AddRectFilled(draw_list, x1, y1, x2, y2, fill_color)
    if border_color then
      reaper.ImGui_DrawList_AddRect(draw_list, x1, y1, x2, y2, border_color)
    end
    return
  end

  -- Clamp bevel to half the smallest dimension
  local max_bevel = math.min((x2 - x1) / 2, (y2 - y1) / 2)
  if bevel > max_bevel then bevel = max_bevel end

  local function trace_path()
    DL_PathLineTo(draw_list, x1 + bevel, y1)          -- top-left after bevel
    DL_PathLineTo(draw_list, x2 - bevel, y1)          -- top-right before bevel
    DL_PathLineTo(draw_list, x2, y1 + bevel)           -- top-right after bevel
    DL_PathLineTo(draw_list, x2, y2 - bevel)           -- bottom-right before bevel
    DL_PathLineTo(draw_list, x2 - bevel, y2)          -- bottom-right after bevel
    DL_PathLineTo(draw_list, x1 + bevel, y2)          -- bottom-left before bevel
    DL_PathLineTo(draw_list, x1, y2 - bevel)           -- bottom-left after bevel
    DL_PathLineTo(draw_list, x1, y1 + bevel)           -- top-left before bevel
  end

  -- Fill
  trace_path()
  DL_PathFillConvex(draw_list, fill_color)

  -- Border
  if border_color then
    trace_path()
    DL_PathStroke(draw_list, border_color, 1, 1)  -- closed=1, thickness=1
  end
end

-- Draw a TV-style standby/power icon (IEC 5009): circle with gap at top, vertical line through gap
function drawing.draw_power_icon(draw_list, cx, cy, radius, color)
  local DL_PathLineTo = reaper.ImGui_DrawList_PathLineTo
  local DL_PathStroke = reaper.ImGui_DrawList_PathStroke
  local DL_AddLine = reaper.ImGui_DrawList_AddLine

  if not DL_PathLineTo then return end

  -- Arc: 270 degrees, gap at top (from ~45deg past top to ~315deg past top)
  -- Start at angle -60deg from top (i.e. -PI/2 - PI/3) going clockwise to +60deg from top
  local gap_half = math.pi / 3  -- 60 degree gap on each side of top
  local start_angle = -math.pi / 2 + gap_half
  local end_angle = -math.pi / 2 + 2 * math.pi - gap_half
  local segments = 20
  for i = 0, segments do
    local a = start_angle + (end_angle - start_angle) * (i / segments)
    DL_PathLineTo(draw_list, cx + math.cos(a) * radius, cy + math.sin(a) * radius)
  end
  DL_PathStroke(draw_list, color, 0, 1.5)

  -- Vertical line through the gap (from top of circle down to center)
  DL_AddLine(draw_list, cx, cy - radius, cx, cy, color, 1.5)
end

-- Draw envelope editor bottom bar with type dropdown
function drawing.draw_envelope_bar(draw_list, ctx, x, y, width, height,
                                     mouse_x, mouse_y, config, state)
  -- Background (always visible)
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + width, y + height, config.COLOR_RULER_BG)
  reaper.ImGui_DrawList_AddLine(draw_list, x, y, x + width, y, config.COLOR_GRID_BAR, 1)

  -- Dropdown button only when on Envelopes tab
  if state.active_view_tab ~= "envelopes" then return end

  local btn_w = 100
  local btn_h = height - 4
  local btn_x = x + 4
  local btn_y = y + 2
  local label = state.envelope_type

  local mouse_in_btn = mouse_x >= btn_x and mouse_x <= btn_x + btn_w
                        and mouse_y >= btn_y and mouse_y <= btn_y + btn_h

  local btn_bg = mouse_in_btn and 0x505050FF or 0x353535FF
  reaper.ImGui_DrawList_AddRectFilled(draw_list, btn_x, btn_y, btn_x + btn_w, btn_y + btn_h, btn_bg, 2)
  reaper.ImGui_DrawList_AddText(draw_list, btn_x + 4, btn_y + 1, 0xCCCCCCFF, label)

  -- Triangle arrow pointing UP (menu opens upward)
  local arrow_color = 0xAAAAAAFF
  reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
    btn_x + btn_w - 10, btn_y + btn_h - 4,
    btn_x + btn_w - 4, btn_y + btn_h - 4,
    btn_x + btn_w - 7, btn_y + 4,
    arrow_color)

  -- Toggle dropdown on click
  if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_btn then
    state.envelope_dropdown_open = not state.envelope_dropdown_open
  end

end

-- Draw envelope dropdown menu (called AFTER overlay so it renders on top)
function drawing.draw_envelope_dropdown(draw_list, ctx, x, y, height,
                                         mouse_x, mouse_y, config, state)
  if not state.envelope_dropdown_open then return end

  local btn_w = 100
  local btn_x = x + 4
  local btn_y = y + 2

  local items = { "Volume", "Pitch", "Pan" }
  local menu_item_height = 16
  local menu_height = #items * menu_item_height + 4
  local menu_y = btn_y - menu_height - 1
  local menu_x = btn_x

  drawing.draw_beveled_rect(draw_list, menu_x, menu_y, menu_x + btn_w, menu_y + menu_height,
    0x2A2A2AFF, 0x555555FF, 3)

  for i, item_name in ipairs(items) do
    local item_y = menu_y + 2 + (i - 1) * menu_item_height
    local mouse_in_item = mouse_x >= menu_x and mouse_x <= menu_x + btn_w
                          and mouse_y >= item_y and mouse_y <= item_y + menu_item_height

    if mouse_in_item then
      reaper.ImGui_DrawList_AddRectFilled(draw_list, menu_x + 1, item_y, menu_x + btn_w - 1, item_y + menu_item_height, 0x4A4A4AFF)
    end

    local text_color = (item_name == state.envelope_type) and 0x4A90D9FF or 0xCCCCCCFF
    reaper.ImGui_DrawList_AddText(draw_list, menu_x + 4, item_y + 2, text_color, item_name)

    if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_item then
      state.envelope_type = item_name
      state.envelope_dropdown_open = false
    end
  end

  -- Close on click outside
  local mouse_in_btn = mouse_x >= btn_x and mouse_x <= btn_x + btn_w
                        and mouse_y >= btn_y and mouse_y <= btn_y + (height - 4)
  if reaper.ImGui_IsMouseClicked(ctx, 0) and not mouse_in_btn then
    local mouse_in_menu = mouse_x >= menu_x and mouse_x <= menu_x + btn_w
                          and mouse_y >= menu_y and mouse_y <= menu_y + menu_height
    if not mouse_in_menu then
      state.envelope_dropdown_open = false
    end
  end
end

-- Draw envelope overlay: line, fill, nodes, tooltips over waveform
function drawing.draw_envelope_overlay(draw_list, ctx, env_points, num_points,
                                        wave_x, wave_y, waveform_width, waveform_height,
                                        time_to_px, view_start, view_length,
                                        mouse_x, mouse_y, config, state, source_length,
                                        env_scaling, env_max_raw, env_min_raw, env_type,
                                        snap_time_fn, env_colors)
  local DL_AddLine = reaper.ImGui_DrawList_AddLine
  local DL_PathLineTo = reaper.ImGui_DrawList_PathLineTo
  local DL_PathStroke = reaper.ImGui_DrawList_PathStroke
  local DL_AddCircleFilled = reaper.ImGui_DrawList_AddCircleFilled
  local DL_AddCircle = reaper.ImGui_DrawList_AddCircle
  local DL_AddRectFilled = reaper.ImGui_DrawList_AddRectFilled
  local DL_AddText = reaper.ImGui_DrawList_AddText
  local has_path = DL_PathLineTo ~= nil

  -- Derive type flags from env_type string
  local is_pitch = (env_type == "Pitch")
  local is_pan = (env_type == "Pan")
  local is_centered = is_pitch or is_pan

  -- Fall back to Volume colors if env_colors not provided
  env_colors = env_colors or config.ENV_COLORS.Volume

  env_min_raw = env_min_raw or 0
  local env_range = env_max_raw - env_min_raw

  -- Coordinate mapping: raw envelope values to pixels
  -- Volume: 0 (bottom) to max_raw (top)
  -- Pitch: -24 (bottom) to +24 (top), 0 at center
  local function value_to_y(raw)
    return wave_y + waveform_height * (1 - (raw - env_min_raw) / env_range)
  end

  local function y_to_value(py)
    local raw = env_min_raw + env_range * (1 - (py - wave_y) / waveform_height)
    if raw < env_min_raw then raw = env_min_raw end
    if raw > env_max_raw then raw = env_max_raw end
    return raw
  end

  -- Helper: format raw value for tooltips
  local function raw_to_label(raw)
    if is_pitch then
      -- Pitch: show semitones
      if math.abs(raw) < 0.05 then return "0 st" end
      return string.format("%+.1f st", raw)
    elseif is_pan then
      -- Pan: show L/C/R percentage
      if math.abs(raw) < 0.005 then return "Center" end
      local pct = math.abs(raw) * 100
      return string.format("%.0f%%%s", pct, raw < 0 and "L" or "R")
    else
      -- Volume: show dB
      local linear = reaper.ScaleFromEnvelopeMode(env_scaling, raw)
      if linear <= 0 then return "-inf dB" end
      local db = 20 * math.log(linear, 10)
      if math.abs(db) < 0.05 then return "0.0 dB" end
      return string.format("%+.1f dB", db)
    end
  end

  -- Shape interpolation: apply envelope point shape to a linear fraction
  local function apply_shape(frac, shape, tension)
    if shape == 0 then return frac end -- Linear
    if shape == 1 then return 0 end -- Square (step: stays at start value)
    if shape == 2 then return 3 * frac * frac - 2 * frac * frac * frac end -- Slow start/end
    if shape == 3 then return 1 - (1 - frac) * (1 - frac) end -- Fast start
    if shape == 4 then return frac * frac end -- Fast end
    if shape == 5 then -- Bezier (tension-controlled)
      if math.abs(tension) < 0.001 then return frac end
      if frac <= 0 then return 0 end
      if frac >= 1 then return 1 end
      -- Symmetric power curve with bounded exponent (matches REAPER's visual)
      -- exp(|t|*2.7) maps tension ±1 to power ~15, pronounced curves
      local power = math.exp(math.abs(tension) * 2.7)
      if tension > 0 then
        return frac ^ power
      else
        return 1 - (1 - frac) ^ power
      end
    end
    return frac
  end

  -- Default raw value for implicit anchors
  -- Volume: 0 dB (fader unity). Pitch: 0 semitones. Pan: center (0)
  local default_raw = is_centered and 0 or reaper.ScaleToEnvelopeMode(env_scaling, 1.0)

  -- Build effective point list (sorted by time) with implicit anchors
  -- env_points contain RAW values (not normalized)
  local pts = {}
  local has_start = false
  local has_end = false

  for i = 1, num_points do
    local p = env_points[i]
    pts[#pts + 1] = { time = p.time, value = p.value, implicit = false, idx = i - 1,
                       shape = p.shape or 0, tension = p.tension or 0 }
    if math.abs(p.time) < 0.001 then has_start = true end
    if math.abs(p.time - source_length) < 0.001 then has_end = true end
  end

  if not has_start then
    local start_val = (#pts > 0) and pts[1].value or default_raw
    table.insert(pts, 1, { time = 0, value = start_val, implicit = true, idx = -1, shape = 0, tension = 0 })
  end
  if not has_end then
    local end_val = (#pts > 0) and pts[#pts].value or default_raw
    pts[#pts + 1] = { time = source_length, value = end_val, implicit = true, idx = -1, shape = 0, tension = 0 }
  end

  -- Sort by time
  table.sort(pts, function(a, b) return a.time < b.time end)

  local n_pts = #pts

  -- Helper: interpolate raw value at a given time (respects shape/tension)
  local function interp_value(t)
    if n_pts == 0 then return default_raw end
    if t <= pts[1].time then return pts[1].value end
    if t >= pts[n_pts].time then return pts[n_pts].value end
    for i = 1, n_pts - 1 do
      if t >= pts[i].time and t <= pts[i + 1].time then
        local seg_len = pts[i + 1].time - pts[i].time
        if seg_len < 0.0001 then return pts[i].value end
        local frac = (t - pts[i].time) / seg_len
        local curved_frac = apply_shape(frac, pts[i].shape, pts[i].tension)
        return pts[i].value + curved_frac * (pts[i + 1].value - pts[i].value)
      end
    end
    return default_raw
  end

  -- 0. Pitch/Pan: draw grid lines + left label column
  if is_pitch then
    local gutter_w = config.PITCH_LABEL_WIDTH
    local gutter_x = wave_x - gutter_w

    -- Label column background
    DL_AddRectFilled(draw_list, gutter_x, wave_y, wave_x, wave_y + waveform_height, config.COLOR_WAVEFORM_BG)
    -- Separator line between label column and waveform
    DL_AddLine(draw_list, wave_x, wave_y, wave_x, wave_y + waveform_height, config.COLOR_ENV_GRID, 1)

    -- Determine label interval so they don't overlap (need ~12px vertical spacing)
    local px_per_st = waveform_height / env_range
    local label_interval = math.max(1, math.ceil(12 / px_per_st))

    for st = math.ceil(env_min_raw), math.floor(env_max_raw) do
      local ly = value_to_y(st)
      if ly >= wave_y and ly <= wave_y + waveform_height then
        -- Grid line across waveform
        local color
        if st == 0 then
          color = config.COLOR_ENV_GRID_CENTER
        elseif st % 12 == 0 then
          color = config.COLOR_ENV_GRID_OCTAVE
        else
          color = config.COLOR_ENV_GRID
        end
        DL_AddLine(draw_list, wave_x, ly, wave_x + waveform_width, ly, color, 1)

        -- Label in gutter (at adaptive interval, always show 0)
        if st == 0 or st % label_interval == 0 then
          local label = st == 0 and "0" or string.format("%+d", st)
          local tw = reaper.ImGui_CalcTextSize(ctx, label)
          local label_color
          if st == 0 then label_color = config.COLOR_ENV_GRID_CENTER
          elseif st % 12 == 0 then label_color = config.COLOR_ENV_GRID_LABEL
          else label_color = config.COLOR_ENV_GRID end
          -- Right-align in gutter
          DL_AddText(draw_list, gutter_x + gutter_w - tw - 3, ly - 6, label_color, label)
          -- Tick mark connecting label to grid line
          DL_AddLine(draw_list, wave_x - 3, ly, wave_x, ly, color, 1)
        end
      end
    end
  elseif is_pan then
    local gutter_w = config.PITCH_LABEL_WIDTH
    local gutter_x = wave_x - gutter_w

    -- Label column background + separator
    DL_AddRectFilled(draw_list, gutter_x, wave_y, wave_x, wave_y + waveform_height, config.COLOR_WAVEFORM_BG)
    DL_AddLine(draw_list, wave_x, wave_y, wave_x, wave_y + waveform_height, config.COLOR_ENV_GRID, 1)

    -- Pan labels: 100L, 50L, C, 50R, 100R (adaptive based on height)
    local pan_marks = { {-1, "100L"}, {-0.5, "50L"}, {0, "C"}, {0.5, "50R"}, {1, "100R"} }
    -- If height is small, only show 100L, C, 100R
    if waveform_height < 120 then
      pan_marks = { {-1, "100L"}, {0, "C"}, {1, "100R"} }
    end

    for _, mark in ipairs(pan_marks) do
      local raw_val, label = mark[1], mark[2]
      local ly = value_to_y(raw_val)
      if ly >= wave_y and ly <= wave_y + waveform_height then
        local color
        if raw_val == 0 then
          color = config.COLOR_ENV_GRID_CENTER
        elseif math.abs(raw_val) == 0.5 then
          color = config.COLOR_ENV_GRID_OCTAVE
        else
          color = config.COLOR_ENV_GRID
        end
        DL_AddLine(draw_list, wave_x, ly, wave_x + waveform_width, ly, color, 1)

        local tw = reaper.ImGui_CalcTextSize(ctx, label)
        local label_color = (raw_val == 0) and config.COLOR_ENV_GRID_CENTER or config.COLOR_ENV_GRID_LABEL
        DL_AddText(draw_list, gutter_x + gutter_w - tw - 3, ly - 6, label_color, label)
        DL_AddLine(draw_list, wave_x - 3, ly, wave_x, ly, color, 1)
      end
    end
  end

  -- 1. Fill area (column-by-column, 2px step)
  local view_end = view_start + view_length
  local step = 2
  local center_y = is_centered and value_to_y(0) or (wave_y + waveform_height)
  for px = 0, waveform_width, step do
    local t = view_start + (px / waveform_width) * view_length
    local v = interp_value(t)
    local env_y = value_to_y(v)
    -- Volume: fill from envelope down to bottom. Pitch: fill from envelope to center (0 st)
    local fill_top = math.min(env_y, center_y)
    local fill_bot = math.max(env_y, center_y)
    if fill_bot - fill_top >= 1 then
      DL_AddLine(draw_list, wave_x + px, fill_top, wave_x + px, fill_bot, env_colors.fill, step)
    end
  end

  -- 2. Envelope line
  local no_user_nodes = (num_points == 0)

  if no_user_nodes then
    -- Dashed horizontal line at default value
    local dash_y = value_to_y(default_raw)
    local px = 0
    while px < waveform_width do
      local dash_end = math.min(px + config.ENV_DASH_LENGTH, waveform_width)
      DL_AddLine(draw_list, wave_x + px, dash_y, wave_x + dash_end, dash_y,
        env_colors.line_dash, config.ENV_LINE_THICKNESS)
      px = px + config.ENV_DASH_LENGTH + config.ENV_DASH_GAP
    end
  elseif has_path then
    -- Solid line via PathLineTo
    local line_step = math.max(1, math.floor(waveform_width / 400))
    for px = 0, waveform_width, line_step do
      local t = view_start + (px / waveform_width) * view_length
      local v = interp_value(t)
      DL_PathLineTo(draw_list, wave_x + px, value_to_y(v))
    end
    -- Final point
    local v_end = interp_value(view_end)
    DL_PathLineTo(draw_list, wave_x + waveform_width, value_to_y(v_end))
    DL_PathStroke(draw_list, env_colors.line, 0, config.ENV_LINE_THICKNESS)
  end

  -- 3. Segment hover detection: find closest line segment to mouse
  state.envelope_hovered_segment = -1
  state.env_node_hovered_idx = -1

  local mouse_in_waveform = mouse_x >= wave_x and mouse_x <= wave_x + waveform_width
                            and mouse_y >= wave_y and mouse_y <= wave_y + waveform_height

  if mouse_in_waveform and not state.dragging_env_node then
    -- Check if mouse is near an existing node first
    local closest_node_dist = config.ENV_NODE_HIT_RADIUS + 1
    for i = 1, n_pts do
      if not pts[i].implicit then
        local node_px = time_to_px(pts[i].time)
        local node_py = value_to_y(pts[i].value)
        local dx = mouse_x - node_px
        local dy = mouse_y - node_py
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist < closest_node_dist then
          closest_node_dist = dist
          state.env_node_hovered_idx = pts[i].idx
        end
      end
    end

    -- If not hovering a node, check segment proximity
    if state.env_node_hovered_idx < 0 then
      local mouse_t = view_start + ((mouse_x - wave_x) / waveform_width) * view_length
      local line_y = value_to_y(interp_value(mouse_t))
      local dist_to_line = math.abs(mouse_y - line_y)
      local threshold = no_user_nodes and 20 or 12

      if dist_to_line <= threshold then
        -- Find which segment
        for i = 1, n_pts - 1 do
          if mouse_t >= pts[i].time and mouse_t <= pts[i + 1].time then
            state.envelope_hovered_segment = i - 1
            -- Snap hover time to grid if snap function provided
            local snapped_t = (snap_time_fn and state.env_snap_enabled) and snap_time_fn(mouse_t) or mouse_t
            state.envelope_hover_x = time_to_px(snapped_t)
            local hover_raw = interp_value(snapped_t)
            -- Pitch: snap hover preview to nearest semitone
            if is_pitch and state.env_snap_enabled then hover_raw = math.floor(hover_raw + 0.5) end
            state.envelope_hover_y = value_to_y(hover_raw)
            state.envelope_hover_value = hover_raw
            state.envelope_hover_time = snapped_t
            break
          end
        end
      end
    end
  end

  -- 3b. Highlight hovered segment
  if state.envelope_hovered_segment >= 0 and has_path and not state.dragging_env_node then
    local seg_idx = state.envelope_hovered_segment + 1  -- convert 0-based to 1-based pts index
    if seg_idx >= 1 and seg_idx < n_pts then
      local view_end_t = view_start + view_length
      local t_start = math.max(pts[seg_idx].time, view_start)
      local t_end = math.min(pts[seg_idx + 1].time, view_end_t)
      if t_end > t_start then
        local px_start = math.max(0, (t_start - view_start) / view_length * waveform_width)
        local px_end = math.min(waveform_width, (t_end - view_start) / view_length * waveform_width)
        local line_step = math.max(1, math.floor(waveform_width / 400))
        for px = px_start, px_end, line_step do
          local t = view_start + (px / waveform_width) * view_length
          DL_PathLineTo(draw_list, wave_x + px, value_to_y(interp_value(t)))
        end
        DL_PathLineTo(draw_list, wave_x + px_end, value_to_y(interp_value(view_start + (px_end / waveform_width) * view_length)))
        DL_PathStroke(draw_list, env_colors.line_hover, 0, config.ENV_LINE_THICKNESS + 1)
      end
    end
  end

  -- 4. Draw node circles
  for i = 1, n_pts do
    if not pts[i].implicit then
      local node_px = time_to_px(pts[i].time)
      local node_py = value_to_y(pts[i].value)
      if node_px >= wave_x - config.ENV_NODE_RADIUS and node_px <= wave_x + waveform_width + config.ENV_NODE_RADIUS then
        local is_hovered = (pts[i].idx == state.env_node_hovered_idx)
        local fill = is_hovered and env_colors.node_hover or config.COLOR_ENV_NODE
        DL_AddCircleFilled(draw_list, node_px, node_py, config.ENV_NODE_RADIUS, fill, 16)
        DL_AddCircle(draw_list, node_px, node_py, config.ENV_NODE_RADIUS, env_colors.node_border, 16, 1.5)
      end
    end
  end

  -- 5. Preview circle + tooltip on segment hover (hidden during tension drag and alt-hover)
  local alt_held = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Alt())
  if state.envelope_hovered_segment >= 0 and state.env_node_hovered_idx < 0
      and not state.dragging_env_node and not state.env_tension_dragging and not alt_held then
    DL_AddCircleFilled(draw_list, state.envelope_hover_x, state.envelope_hover_y,
      config.ENV_NODE_RADIUS, env_colors.preview, 16)

    -- Tooltip
    local tip_text = raw_to_label(state.envelope_hover_value)
    local tip_w = reaper.ImGui_CalcTextSize(ctx, tip_text) + 8
    local tip_h = 16
    local tip_x = state.envelope_hover_x + 10
    local tip_y = state.envelope_hover_y - tip_h - 4
    -- Keep tooltip within waveform bounds
    if tip_x + tip_w > wave_x + waveform_width then
      tip_x = state.envelope_hover_x - tip_w - 10
    end
    if tip_y < wave_y then tip_y = wave_y + 2 end

    DL_AddRectFilled(draw_list, tip_x, tip_y, tip_x + tip_w, tip_y + tip_h, config.COLOR_ENV_TOOLTIP_BG, 3)
    DL_AddText(draw_list, tip_x + 4, tip_y + 1, config.COLOR_ENV_TOOLTIP_TEXT, tip_text)
  end

  -- 6. Drag tooltip (while dragging a node)
  if state.dragging_env_node and state.env_drag_activated then
    local drag_idx = state.env_drag_node_idx
    -- Find the dragged point in pts
    for i = 1, n_pts do
      if pts[i].idx == drag_idx and not pts[i].implicit then
        local node_px = time_to_px(pts[i].time)
        local node_py = value_to_y(pts[i].value)
        local tip_text = raw_to_label(pts[i].value)
        local tip_w = reaper.ImGui_CalcTextSize(ctx, tip_text) + 8
        local tip_h = 16
        local tip_x = node_px + 10
        local tip_y = node_py - tip_h - 4
        if tip_x + tip_w > wave_x + waveform_width then
          tip_x = node_px - tip_w - 10
        end
        if tip_y < wave_y then tip_y = wave_y + 2 end

        DL_AddRectFilled(draw_list, tip_x, tip_y, tip_x + tip_w, tip_y + tip_h, config.COLOR_ENV_TOOLTIP_BG, 3)
        DL_AddText(draw_list, tip_x + 4, tip_y + 1, config.COLOR_ENV_TOOLTIP_TEXT, tip_text)
        break
      end
    end
  end
end

return drawing
