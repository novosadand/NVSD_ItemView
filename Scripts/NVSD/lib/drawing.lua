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

-- Evaluate REAPER fade amplitude at position t (0..1)
-- Returns amplitude: 0..1 for fade-in, 1..0 for fade-out
local function eval_fade(t, shape, dir, is_fade_out)
  local x1,y1, x2,y2, x3,y3, x4,y4 = get_fade_bez(shape, dir or 0, is_fade_out)
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
  local x1,y1, x2,y2, x3,y3, x4,y4 = get_fade_bez(shape, dir, is_fade_out)
  local lut = c.lut
  for i = 0, FADE_LUT_SIZE do
    lut[i] = cbez_y(x1,y1, x2,y2, x3,y3, x4,y4, i / FADE_LUT_SIZE)
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

-- Shape icon LUTs: each shape's characteristic curve for the right-click selector
-- Uses explicit math per shape (the Bezier system makes 0/3/4 identical at dir=0)
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
    local vol = fade_lut_lookup(lut, t)
    if not is_fade_in then vol = 1 - vol end
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
-- Returns: mouse_over_filename, gear_clicked
function drawing.draw_info_bar(draw_list, ctx, x, y, width, height, source, file_path, mouse_x, mouse_y, item, config, utils, actual_num_channels)
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

  if mouse_over_filename and reaper.ImGui_IsMouseClicked(ctx, 0) then
    reaper.Main_OnCommand(41623, 0)
    return true, false
  end

  return mouse_over_filename, gear_clicked
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
function drawing.draw_knob(draw_list, cx, cy, radius, angle, is_hovered, is_active)
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

  local label_color = 0xAAAAAAFF
  reaper.ImGui_DrawList_AddText(draw_list, cx - 12, cy - radius - 18, label_color, "Pitch")

  local st_color = 0x888888FF
  reaper.ImGui_DrawList_AddText(draw_list, cx - 5, cy + radius + 2, st_color, "st")
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

return drawing
