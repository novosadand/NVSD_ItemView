-- NVSD_ItemView - Drawing Module
-- Waveform, ruler, overlays, markers, info bar

local drawing = {}

-- Tooltip system: tracks hover time per element ID, shows tooltip after delay
local tooltip_hover_id = nil
local tooltip_hover_time = 0
local tooltip_last_frame = 0
local TOOLTIP_DELAY = 0.5
local frame_time = 0  -- Cached time for current frame (set once per frame)

-- Call once per frame from main loop to cache the current time
function drawing.set_frame_time(t)
  frame_time = t
end

function drawing.tooltip(ctx, id, text)
  local now = frame_time > 0 and frame_time or reaper.time_precise()
  -- Reset if different element or gap since last frame (>50ms = missed a frame)
  if tooltip_hover_id ~= id or (now - tooltip_last_frame) > 0.05 then
    tooltip_hover_id = id
    tooltip_hover_time = now
  end
  tooltip_last_frame = now
  if now - tooltip_hover_time >= TOOLTIP_DELAY then
    reaper.ImGui_SetTooltip(ctx, text)
  end
end

-- Toolbar icon image cache: {filename -> {img=ImGui_Image, uv_u1=number} or false}
local toolbar_icon_cache = {}
local toolbar_icons_dir = nil  -- resolved lazily

-- Action search state (transient UI state for the edit modal)
local action_cache = nil
local action_search_text = ""
local action_search_results = {}
local action_search_sel_idx = 0
local action_search_confirmed = ""  -- name of last confirmed selection (shown in field)
local edit_show_validation = false  -- true after Save clicked with missing fields

-- Icon picker state (shared between drawing.lua and settings_ui.lua callers)
local icon_picker_state = {
  filter_text = "",
  hovered_name = "",
}

function drawing.reset_icon_picker_state()
  icon_picker_state.filter_text = ""
  icon_picker_state.hovered_name = ""
  icon_picker_state.focus_filter = true
end

-- Get toolbar icon + UV u1 for first state of horizontal sprite sheet
-- REAPER toolbar icons are HORIZONTAL strips: width=N*height (typically 90x30 = 3 states)
-- States left-to-right: Normal | Hover | Active
-- Returns img, uv_u1 (or nil, nil)
local function get_toolbar_icon(ctx, filename)
  if not filename or filename == "" then return nil, nil end
  local cached = toolbar_icon_cache[filename]
  if cached == false then return nil, nil end  -- previously failed
  if cached then return cached.img, cached.uv_u1 end
  -- Resolve icons directory once
  if not toolbar_icons_dir then
    toolbar_icons_dir = reaper.GetResourcePath() .. "/Data/toolbar_icons/"
  end
  local ok, img = pcall(reaper.ImGui_CreateImage, toolbar_icons_dir .. filename)
  if ok and img then
    pcall(reaper.ImGui_Attach, ctx, img)
    -- Validate image loaded successfully by checking dimensions
    local ok2, w, h = pcall(reaper.ImGui_Image_GetSize, img)
    if not ok2 or not w or not h or w <= 0 or h <= 0 then
      -- Image object exists but pixels failed to load - unusable
      toolbar_icon_cache[filename] = false
      return nil, nil
    end
    -- Calculate UV u1 from actual dimensions (horizontal sprite strip)
    local states = math.max(1, math.floor(w / h))
    local uv_u1 = 1 / states
    toolbar_icon_cache[filename] = {img = img, uv_u1 = uv_u1}
    return img, uv_u1
  end
  toolbar_icon_cache[filename] = false
  return nil, nil
end

-- Build/return cached list of all REAPER actions (Main section)
local function get_action_cache()
  if action_cache then return action_cache end
  action_cache = {}
  local has_shortcuts = reaper.GetActionShortcutDesc ~= nil
  local idx = 0
  while true do
    local retval, name = reaper.kbd_enumerateActions(0, idx)  -- 0 = Main section
    if retval == 0 then break end
    local cmd_str
    local named = reaper.ReverseNamedCommandLookup and reaper.ReverseNamedCommandLookup(retval) or ""
    if named and named ~= "" then
      cmd_str = "_" .. named
    else
      cmd_str = tostring(retval)
    end
    if name and name ~= "" then
      local shortcut = ""
      if has_shortcuts then
        local ok, rv, desc = pcall(reaper.GetActionShortcutDesc, 0, retval, 0, "")
        if ok and rv and desc and desc ~= "" then shortcut = desc end
      end
      action_cache[#action_cache + 1] = {name = name, cmd = cmd_str, shortcut = shortcut}
    end
    idx = idx + 1
  end
  table.sort(action_cache, function(a, b) return a.name:lower() < b.name:lower() end)
  return action_cache
end

-- Linear passthrough (matches REAPER's native waveform display - no compression)
local function power_curve(value)
  return value
end

-- Load fade curves module (pure math, no REAPER dependency)
local lib_path = debug.getinfo(1, "S").source:match("@(.+)[/\\]") .. "/"
local fade_curves = dofile(lib_path .. "fade_curves.lua")

-- Import fade curve functions as locals for performance (same names as before extraction)
local B = fade_curves.B
local cbez_y = fade_curves.cbez_y
local get_fade_bez = fade_curves.get_fade_bez
local shape_icon_fns = fade_curves.shape_icon_fns
local eval_fade = fade_curves.eval_fade
local FADE_LUT_SIZE = fade_curves.FADE_LUT_SIZE
local get_fade_lut = fade_curves.get_fade_lut
local fade_lut_lookup = fade_curves.fade_lut_lookup
local shape_icon_luts = fade_curves.shape_icon_luts

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

-- Clear toolbar icon cache (call when ImGui context is recreated)
function drawing.clear_icon_cache()
  toolbar_icon_cache = {}
  toolbar_icons_dir = nil
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
  local first_bar = math.floor(start_measures) - 1

  local min_spacing = 42  -- minimum px between grid lines at any level
  local avg_bar_duration = 60 / bpm * beats_per_bar
  local px_per_bar = (avg_bar_duration / view_length) * width
  local bar_skip = math.max(1, math.ceil(min_spacing / px_per_bar))
  if bar_skip > 1 then
    local power = math.ceil(math.log(bar_skip) / math.log(2))
    bar_skip = 2 ^ power
  end

  local px_per_beat = px_per_bar / beats_per_bar

  -- Sub-beat subdivision depth (powers of 2: 2=eighths, 4=sixteenths, 8=32nds, etc.)
  -- Each level only appears when its lines are at least min_spacing px apart
  local finest_sub = 1
  while (px_per_beat / (finest_sub * 2)) >= min_spacing do
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
    bar_skip = bar_skip, px_per_beat = px_per_beat, px_per_bar = px_per_bar,
    finest_sub = finest_sub, quarter_step = quarter_step,
    inter_bar_color = dim_color(config.COLOR_GRID_BAR, 0.78),
    sub_grid_color = dim_color(config.COLOR_GRID_BAR, 0.65),
    sub_label_color = dim_color(0x555555FF, 0.75),
    -- Ruler tick colors: derive from RULER_TICK so they're visible on ruler bg
    beat_tick_color = config.COLOR_RULER_TICK,
    inter_tick_color = dim_color(config.COLOR_RULER_TICK, 0.78),
    sub_tick_color = dim_color(config.COLOR_RULER_TICK, 0.7),
    dim_color = dim_color,
  }
end

-- Per-frame grid params cache (avoids computing twice per frame for grid+ruler)
local grid_cache = { x = -1, width = -1, view_start = -1, view_length = -1,
                     start_offset = -1, item_position = -1, playrate = -1, result = nil }

local function get_grid_params(x, width, view_start, view_length, item_position, start_offset, playrate, config, utils)
  if grid_cache.x == x and grid_cache.width == width
      and grid_cache.view_start == view_start and grid_cache.view_length == view_length
      and grid_cache.start_offset == start_offset and grid_cache.item_position == item_position
      and grid_cache.playrate == playrate then
    return grid_cache.result
  end
  local g = compute_grid_params(x, width, view_start, view_length, item_position, start_offset, playrate, config, utils)
  grid_cache.x = x; grid_cache.width = width
  grid_cache.view_start = view_start; grid_cache.view_length = view_length
  grid_cache.start_offset = start_offset; grid_cache.item_position = item_position
  grid_cache.playrate = playrate
  grid_cache.result = g
  return g
end

-- Draw vertical grid lines through the waveform area (call BEFORE waveform)
function drawing.draw_grid_lines(draw_list, x, wave_y, width, wave_height,
                                  view_start, view_length, item_position, start_offset, playrate, config, utils)
  local g = get_grid_params(x, width, view_start, view_length, item_position, start_offset, playrate, config, utils)
  local show_beats = g.px_per_beat >= 42
  local DL_AddLine = reaper.ImGui_DrawList_AddLine
  local p2s = utils.project_to_source_time

  -- Bar lines with adaptive skipping
  local draw_skip = (g.bar_skip >= 2) and (g.bar_skip / 2) or g.bar_skip
  local bar = g.first_bar - (g.first_bar % draw_skip)
  local iterations = 0
  while iterations < 1000 do
    iterations = iterations + 1
    local bar_project_time = reaper.TimeMap2_beatsToTime(0, 0, bar)
    if bar_project_time > g.project_end then break end

    local bar_source_time = p2s(bar_project_time, item_position, start_offset, playrate)
    if bar_source_time >= g.view_start and bar_source_time <= g.view_end then
      local bar_px = g.time_to_px(bar_source_time)
      local is_major = (g.bar_skip < 2) or (bar % g.bar_skip == 0)
      local bar_color = is_major and config.COLOR_GRID_BAR or g.inter_bar_color
      DL_AddLine(draw_list, bar_px, wave_y, bar_px, wave_y + wave_height, bar_color, 1)
    end

    -- Beat grid lines (show when beats are spaced enough, regardless of bar_skip)
    if show_beats then
      for beat = 1, g.beats_per_bar - 1 do
        local beat_project_time = reaper.TimeMap2_beatsToTime(0, beat, bar)
        if beat_project_time > g.project_end then break end
        local beat_source_time = p2s(beat_project_time, item_position, start_offset, playrate)
        if beat_source_time >= g.view_start and beat_source_time <= g.view_end then
          local beat_px = g.time_to_px(beat_source_time)
          DL_AddLine(draw_list, beat_px, wave_y, beat_px, wave_y + wave_height, config.COLOR_GRID_BEAT, 1)
        end
      end
    end

    -- Sub-beat grid lines (each subdivision level gated by its own spacing)
    if g.finest_sub >= 2 then
      for beat = 0, g.beats_per_bar - 1 do
        for sub = 1, g.finest_sub - 1 do
          -- Skip lines that are already drawn as beat lines
          if sub % g.finest_sub ~= 0 then
            local sub_project_time = reaper.TimeMap2_beatsToTime(0, beat + (sub / g.finest_sub), bar)
            if sub_project_time > g.project_end then break end
            local sub_source_time = p2s(sub_project_time, item_position, start_offset, playrate)
            if sub_source_time >= g.view_start and sub_source_time <= g.view_end then
              local is_quarter = g.quarter_step and (sub % g.quarter_step == 0)
              local grid_col = is_quarter and config.COLOR_GRID_BEAT or g.sub_grid_color
              DL_AddLine(draw_list, g.time_to_px(sub_source_time), wave_y, g.time_to_px(sub_source_time), wave_y + wave_height, grid_col, 1)
            end
          end
        end
      end
    end

    bar = bar + draw_skip
  end
end

-- Draw ruler with ticks and labels (call AFTER waveform)
function drawing.draw_ruler_and_grid(draw_list, x, ruler_y, wave_y, width, ruler_height, wave_height,
                                      view_start, view_length, item_position, start_offset, playrate, config, utils)
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x, ruler_y, x + width, ruler_y + ruler_height, config.COLOR_RULER_BG)

  local g = get_grid_params(x, width, view_start, view_length, item_position, start_offset, playrate, config, utils)
  local show_beat_labels = g.px_per_beat >= 70
  local show_beat_ticks = g.px_per_beat >= 42
  -- Sub-beat ruler ticks: only at quarter-beat positions, need decent spacing
  local show_sub_ticks = g.quarter_step and (g.px_per_beat / 4) >= 40
  -- Sub-beat labels: only when really zoomed in (each quarter-beat has plenty of room)
  local show_sub_labels = g.quarter_step and (g.px_per_beat / 4) >= 90
  local beat_label_color = 0x555555FF
  local DL_AddLine = reaper.ImGui_DrawList_AddLine
  local DL_AddText = reaper.ImGui_DrawList_AddText
  local p2s = utils.project_to_source_time

  -- Label skip: ensure bar labels have enough room (text needs ~80px minimum)
  local label_skip = g.bar_skip
  local px_per_label = g.px_per_bar * label_skip
  while px_per_label < 80 do
    label_skip = label_skip * 2
    px_per_label = g.px_per_bar * label_skip
  end

  -- Intermediate bar ticks (half of label_skip)
  local tick_skip = (label_skip >= 2) and (label_skip / 2) or label_skip
  local inter_px = g.px_per_bar * tick_skip
  local show_inter_ticks = inter_px >= 20
  local show_inter_labels = inter_px >= 50  -- text only when enough room

  local inter_label_color = g.dim_color(config.COLOR_RULER_TEXT, 0.75)
  local bar = g.first_bar - (g.first_bar % tick_skip)
  local iterations = 0
  while iterations < 1000 do
    iterations = iterations + 1
    local bar_project_time = reaper.TimeMap2_beatsToTime(0, 0, bar)
    if bar_project_time > g.project_end then break end

    local bar_source_time = p2s(bar_project_time, item_position, start_offset, playrate)

    if bar_source_time >= g.view_start and bar_source_time <= g.view_end then
      local bar_px = g.time_to_px(bar_source_time)
      local is_label_bar = (bar % label_skip == 0)
      if is_label_bar then
        DL_AddLine(draw_list, bar_px, ruler_y, bar_px, ruler_y + ruler_height, config.COLOR_RULER_TICK, 1)
        DL_AddText(draw_list, bar_px + 3, ruler_y + 3, config.COLOR_RULER_TEXT, tostring(bar + 1))
      elseif show_inter_ticks then
        DL_AddLine(draw_list, bar_px, ruler_y, bar_px, ruler_y + ruler_height, g.inter_tick_color, 1)
        if show_inter_labels then
          DL_AddText(draw_list, bar_px + 3, ruler_y + 3, inter_label_color, tostring(bar + 1))
        end
      end
    end

    -- Beat ticks and labels in ruler
    if show_beat_ticks then
      for beat = 1, g.beats_per_bar - 1 do
        local beat_project_time = reaper.TimeMap2_beatsToTime(0, beat, bar)
        if beat_project_time > g.project_end then break end
        local beat_source_time = p2s(beat_project_time, item_position, start_offset, playrate)
        if beat_source_time >= g.view_start and beat_source_time <= g.view_end then
          local beat_px = g.time_to_px(beat_source_time)
          local tick_top = ruler_y + ruler_height - math.floor(ruler_height * 0.5)
          DL_AddLine(draw_list, beat_px, tick_top, beat_px, ruler_y + ruler_height, g.beat_tick_color, 1)
          if show_beat_labels then
            DL_AddText(draw_list, beat_px + 3, ruler_y + 3, beat_label_color, (bar + 1) .. "." .. (beat + 1))
          end
        end
      end
    end

    -- Sub-beat ticks and labels in ruler
    if g.quarter_step and (show_sub_ticks or show_sub_labels) then
      for beat = 0, g.beats_per_bar - 1 do
        for q = 1, 3 do
          local beat_frac = beat + (q / 4)
          local sub_project_time = reaper.TimeMap2_beatsToTime(0, beat_frac, bar)
          if sub_project_time > g.project_end then break end
          local sub_source_time = p2s(sub_project_time, item_position, start_offset, playrate)
          if sub_source_time >= g.view_start and sub_source_time <= g.view_end then
            local sub_px = g.time_to_px(sub_source_time)

            if show_sub_ticks then
              local tick_h = math.floor(ruler_height * 0.3)
              DL_AddLine(draw_list, sub_px, ruler_y + ruler_height - tick_h, sub_px, ruler_y + ruler_height, g.sub_tick_color, 1)
            end

            if show_sub_labels then
              DL_AddText(draw_list, sub_px + 3, ruler_y + 3, g.sub_label_color, (bar + 1) .. "." .. (beat + 1) .. "." .. (q + 1))
            end
          end
        end
      end
    end

    bar = bar + tick_skip
  end

  DL_AddLine(draw_list, x, ruler_y + ruler_height, x + width, ruler_y + ruler_height, config.COLOR_GRID_BAR, 1)
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
-- Toolbar click stored on state.toolbar_clicked (avoids local limit in caller)
function drawing.draw_info_bar(draw_list, ctx, x, y, width, height, source, file_path, mouse_x, mouse_y, item, config, utils, actual_num_channels, state, settings, toolbar_buttons)
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + width, y + height, config.COLOR_INFO_BAR_BG)
  reaper.ImGui_DrawList_AddLine(draw_list, x, y + height, x + width, y + height, config.COLOR_CENTERLINE, 1)

  -- Settings button (gear icon) on the right
  -- Scale up to match toolbar buttons when they exist
  local has_toolbar = toolbar_buttons and #toolbar_buttons > 0
  local gear_btn_h = has_toolbar and 30 or 14
  local gear_btn_w = has_toolbar and 30 or (gear_btn_h + 4)
  local gear_btn_x = x + width - gear_btn_w - 3
  local gear_btn_y = y + math.floor((height - gear_btn_h) / 2)
  local gear_cx = gear_btn_x + gear_btn_w / 2
  local gear_cy = gear_btn_y + gear_btn_h / 2

  local mouse_in_gear = mouse_x >= gear_btn_x and mouse_x <= gear_btn_x + gear_btn_w
                        and mouse_y >= gear_btn_y and mouse_y <= gear_btn_y + gear_btn_h

  -- Button background
  local gear_btn_bg = mouse_in_gear and config.COLOR_BTN_HOVER or config.COLOR_GRID_BAR
  reaper.ImGui_DrawList_AddRectFilled(draw_list, gear_btn_x, gear_btn_y,
      gear_btn_x + gear_btn_w, gear_btn_y + gear_btn_h, gear_btn_bg, 3)

  -- Draw gear icon (scale radius with button size)
  local gear_color = mouse_in_gear and config.COLOR_BTN_TEXT or config.COLOR_INFO_BAR_TEXT
  local outer_r = has_toolbar and 10 or 5
  local teeth = 6

  reaper.ImGui_DrawList_AddCircleFilled(draw_list, gear_cx, gear_cy, outer_r * 0.72, gear_color, 16)
  for i = 0, teeth - 1 do
    local angle = (i / teeth) * math.pi * 2
    local tooth_x = gear_cx + math.cos(angle) * outer_r * 0.92
    local tooth_y = gear_cy + math.sin(angle) * outer_r * 0.92
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, tooth_x, tooth_y, outer_r * 0.28, gear_color, 8)
  end
  local inner_r = has_toolbar and 3.6 or 1.8
  reaper.ImGui_DrawList_AddCircleFilled(draw_list, gear_cx, gear_cy, inner_r, config.COLOR_INFO_BAR_BG, 10)

  if mouse_in_gear then
    local gear_tip = "Settings"
    if settings then
      local sc = settings.current.shortcuts.open_settings
      if sc and sc.key ~= "" then
        gear_tip = gear_tip .. " (" .. settings.format_shortcut(sc) .. ")"
      end
    end
    drawing.tooltip(ctx, "gear_icon", gear_tip)
  end

  local gear_clicked = mouse_in_gear and reaper.ImGui_IsMouseClicked(ctx, 0)

  -- CUE button (left of gear, only when cue markers exist)
  local has_cues = state and state.cached_cue_markers and #state.cached_cue_markers > 0
  local cue_btn_x, cue_btn_w
  if has_cues then
    local cue_label = "CUE"
    local cue_btn_h = has_toolbar and 30 or 14
    cue_btn_w = reaper.ImGui_CalcTextSize(ctx, cue_label) + (has_toolbar and 16 or 8)
    cue_btn_x = gear_btn_x - cue_btn_w - 4
    local cue_btn_y = y + math.floor((height - cue_btn_h) / 2)

    local mouse_in_cue = mouse_x >= cue_btn_x and mouse_x <= cue_btn_x + cue_btn_w
                          and mouse_y >= cue_btn_y and mouse_y <= cue_btn_y + cue_btn_h

    local cue_active = state.show_cue_markers
    local cue_bg
    if cue_active then
      cue_bg = mouse_in_cue and config.COLOR_BTN_HOVER or config.COLOR_BTN_ON
    else
      cue_bg = mouse_in_cue and config.COLOR_BTN_HOVER or config.COLOR_GRID_BAR
    end
    reaper.ImGui_DrawList_AddRectFilled(draw_list, cue_btn_x, cue_btn_y, cue_btn_x + cue_btn_w, cue_btn_y + cue_btn_h, cue_bg, 3)
    local cue_text_w = reaper.ImGui_CalcTextSize(ctx, cue_label)
    local cue_text_x = cue_btn_x + (cue_btn_w - cue_text_w) / 2
    local cue_text_y = cue_btn_y + (cue_btn_h - 12) / 2
    local cue_text_color = cue_active and config.COLOR_BTN_TEXT or config.COLOR_INFO_BAR_TEXT
    reaper.ImGui_DrawList_AddText(draw_list, cue_text_x, cue_text_y, cue_text_color, cue_label)

    if mouse_in_cue then
      local cue_tip = "Toggle WAV cue markers (" .. #state.cached_cue_markers .. " found)"
      if settings then
        local sc = settings.current.shortcuts.toggle_cue_markers
        if sc and sc.key ~= "" then
          cue_tip = cue_tip .. " (" .. settings.format_shortcut(sc) .. ")"
        end
      end
      drawing.tooltip(ctx, "cue_btn", cue_tip)
    end

    if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_cue then
      state.show_cue_markers = not state.show_cue_markers
    end
  end

  -- Waveform zoom indicator widget (left of CUE or gear)
  local zoom_anchor_x = (has_cues and cue_btn_x or gear_btn_x) - 4
  local zoom_val = config.waveform_zoom or 1
  local zoom_btn_h = has_toolbar and 30 or 14
  local zoom_btn_w = has_toolbar and 50 or 44
  local zoom_btn_x = zoom_anchor_x - zoom_btn_w
  local zoom_btn_y = y + math.floor((height - zoom_btn_h) / 2)

  local mouse_in_zoom = state and mouse_x >= zoom_btn_x and mouse_x <= zoom_btn_x + zoom_btn_w
                        and mouse_y >= zoom_btn_y and mouse_y <= zoom_btn_y + zoom_btn_h

  -- Background
  local zoom_bg = (mouse_in_zoom and not (state and state.wf_zoom_dragging)) and config.COLOR_BTN_HOVER or config.COLOR_GRID_BAR
  reaper.ImGui_DrawList_AddRectFilled(draw_list, zoom_btn_x, zoom_btn_y,
      zoom_btn_x + zoom_btn_w, zoom_btn_y + zoom_btn_h, zoom_bg, 3)

  -- Fill bar (logarithmic: 0.05x..1000x, 1.0x at ~30%)
  local log_min = math.log(0.1)
  local log_max = math.log(20)
  local fill_pct = (math.log(zoom_val) - log_min) / (log_max - log_min)
  if fill_pct < 0 then fill_pct = 0 elseif fill_pct > 1 then fill_pct = 1 end
  local fill_w = fill_pct * (zoom_btn_w - 2)
  if fill_w > 0 then
    local fill_color = color_with_alpha(config.COLOR_WAVEFORM, 0x99)
    reaper.ImGui_DrawList_AddRectFilled(draw_list, zoom_btn_x + 1, zoom_btn_y + 1,
        zoom_btn_x + 1 + fill_w, zoom_btn_y + zoom_btn_h - 1, fill_color, 2)
  end

  -- Text label
  local zoom_label
  if zoom_val >= 100 then
    zoom_label = string.format("%.0fx", zoom_val)
  elseif zoom_val >= 10 then
    zoom_label = string.format("%.1fx", zoom_val)
  else
    zoom_label = string.format("%.2fx", zoom_val)
  end
  local zoom_text_w, zoom_text_h = reaper.ImGui_CalcTextSize(ctx, zoom_label)
  local zoom_text_x = zoom_btn_x + math.floor((zoom_btn_w - zoom_text_w) / 2)
  local zoom_text_y = zoom_btn_y + math.floor((zoom_btn_h - zoom_text_h) / 2)
  local zoom_text_color = mouse_in_zoom and config.COLOR_BTN_TEXT or 0xDDDDDDFF
  reaper.ImGui_DrawList_AddText(draw_list, zoom_text_x, zoom_text_y, zoom_text_color, zoom_label)

  -- Tooltip
  if mouse_in_zoom and state and not state.wf_zoom_dragging then
    local tip = "Waveform zoom (Ctrl+Shift+Wheel)\nDrag up/down to adjust, double-click to reset"
    if #state.wf_zoom_history > 0 then
      tip = tip .. "\nRight-click to undo"
    end
    drawing.tooltip(ctx, "wf_zoom", tip)
  end

  -- Interaction: double-click resets, right-click undoes, click starts vertical drag
  if state and mouse_in_zoom then
    if reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
      table.insert(state.wf_zoom_history, state.waveform_zoom)
      state.waveform_zoom = 1.0
      state.wf_zoom_dragging = false
    elseif reaper.ImGui_IsMouseClicked(ctx, 1) then
      -- Undo: pop previous zoom from history
      local n = #state.wf_zoom_history
      if n > 0 then
        state.waveform_zoom = state.wf_zoom_history[n]
        state.wf_zoom_history[n] = nil
      end
    elseif reaper.ImGui_IsMouseClicked(ctx, 0) and not reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
      state.wf_zoom_dragging = true
      state.wf_zoom_drag_start_y = mouse_y
      state.wf_zoom_drag_start_val = state.waveform_zoom
    end
  end

  -- Custom toolbar buttons (centered horizontally in the info bar)
  -- Clicked index stored on state.toolbar_clicked to avoid local limit in caller
  if state then state.toolbar_clicked = nil end
  local toolbar_left_edge = x  -- will be updated if buttons are drawn
  local toolbar_right_edge = zoom_btn_x - 6

  if toolbar_buttons and #toolbar_buttons > 0 then
    local tb_btn_h = 30
    local tb_btn_y = y + math.floor((height - tb_btn_h) / 2)
    local gap = config.TOOLBAR_BTN_GAP

    -- First pass: measure total width and store per-button metrics
    local total_w = 0
    local btn_metrics = {}  -- {x, w} per button (filled in pass 2)
    local sep_w = 20  -- separator: 1.5px line + ~9px padding each side
    for i = 1, #toolbar_buttons do
      local btn = toolbar_buttons[i]
      if btn.type == "separator" then
        total_w = total_w + sep_w
      else
        local has_icon = btn.icon and btn.icon ~= "" and (get_toolbar_icon(ctx, btn.icon)) or false
        if has_icon then
          total_w = total_w + tb_btn_h  -- square for icon buttons
        else
          total_w = total_w + reaper.ImGui_CalcTextSize(ctx, btn.label) + 12
        end
      end
      if i < #toolbar_buttons then total_w = total_w + gap end
    end

    -- Center in the full bar width
    local tb_x = x + math.floor((width - total_w) / 2)

    -- Second pass: draw buttons left-to-right from centered position
    for i = 1, #toolbar_buttons do
      local btn = toolbar_buttons[i]

      if btn.type == "separator" then
        -- Draw vertical separator line
        local btn_w = sep_w
        btn_metrics[i] = {x = tb_x, w = btn_w}
        local is_dragging = state.tb_drag_active and state.tb_drag_idx == i
        local sep_col = is_dragging and 0x66666659 or 0x777777FF
        local sep_x = tb_x + math.floor(btn_w / 2)
        local sep_pad = 5
        reaper.ImGui_DrawList_AddLine(draw_list, sep_x, tb_btn_y + sep_pad, sep_x, tb_btn_y + tb_btn_h - sep_pad, sep_col, 1.5)

        -- Hit area for drag/right-click (wider than visual for easier interaction)
        local hit_pad = 4
        local mouse_in = mouse_x >= tb_x - hit_pad and mouse_x <= tb_x + btn_w + hit_pad
                         and mouse_y >= tb_btn_y and mouse_y <= tb_btn_y + tb_btn_h

        if mouse_in and reaper.ImGui_IsMouseClicked(ctx, 0) then
          state.tb_drag_idx = i
          state.tb_drag_start_x = mouse_x
          state.tb_drag_active = false
        end

        if mouse_in and reaper.ImGui_IsMouseClicked(ctx, 1) then
          state.tb_ctx_idx = i
          state.tb_ctx_open = true
          state.tb_ctx_x = mouse_x
          state.tb_ctx_y = mouse_y
          state.tb_bar_y = y
        end

        if i == 1 then toolbar_left_edge = tb_x end
        tb_x = tb_x + btn_w + gap
      else
        -- Regular button
        local icon_img, icon_uv_u1
        if btn.icon and btn.icon ~= "" then
          icon_img, icon_uv_u1 = get_toolbar_icon(ctx, btn.icon)
        end
        local btn_w
        if icon_img then
          btn_w = tb_btn_h  -- square
        else
          btn_w = reaper.ImGui_CalcTextSize(ctx, btn.label) + 12
        end
        btn_metrics[i] = {x = tb_x, w = btn_w}

        local is_dragging = state.tb_drag_active and state.tb_drag_idx == i
        local mouse_in = mouse_x >= tb_x and mouse_x <= tb_x + btn_w
                         and mouse_y >= tb_btn_y and mouse_y <= tb_btn_y + tb_btn_h

        -- Draw button (dimmed if being dragged)
        if icon_img then
          if mouse_in and not state.tb_drag_active then
            reaper.ImGui_DrawList_AddRectFilled(draw_list, tb_x, tb_btn_y, tb_x + btn_w, tb_btn_y + tb_btn_h, 0xFFFFFF20, 3)
          end
          local tint = is_dragging and 0xFFFFFF59 or 0xFFFFFFFF
          local draw_ok = pcall(reaper.ImGui_DrawList_AddImage, draw_list, icon_img, tb_x, tb_btn_y, tb_x + btn_w, tb_btn_y + tb_btn_h, 0, 0, icon_uv_u1, 1, tint)
          if not draw_ok then
            toolbar_icon_cache[btn.icon] = false
            icon_img = nil
          end
        end
        if not icon_img then
          local bg = (mouse_in and not state.tb_drag_active) and config.COLOR_BTN_HOVER or config.COLOR_GRID_BAR
          if is_dragging then bg = 0x40404059 end
          reaper.ImGui_DrawList_AddRectFilled(draw_list, tb_x, tb_btn_y, tb_x + btn_w, tb_btn_y + tb_btn_h, bg, 3)
          local btn_text_w = reaper.ImGui_CalcTextSize(ctx, btn.label)
          local text_color = mouse_in and config.COLOR_BTN_TEXT or config.COLOR_INFO_BAR_TEXT
          if is_dragging then text_color = 0xBBBBBB59 end
          reaper.ImGui_DrawList_AddText(draw_list, tb_x + (btn_w - btn_text_w) / 2,
              tb_btn_y + (tb_btn_h - 12) / 2, text_color, btn.label)
        end

        if mouse_in and not state.tb_drag_active and not reaper.ImGui_IsPopupOpen(ctx, "", reaper.ImGui_PopupFlags_AnyPopup()) then
          drawing.tooltip(ctx, "tb_" .. i, btn.label)
        end

        if mouse_in and reaper.ImGui_IsMouseClicked(ctx, 0) then
          state.tb_drag_idx = i
          state.tb_drag_start_x = mouse_x
          state.tb_drag_active = false
        end

        if mouse_in and reaper.ImGui_IsMouseClicked(ctx, 1) then
          state.tb_ctx_idx = i
          state.tb_ctx_open = true
          state.tb_ctx_x = mouse_x
          state.tb_ctx_y = mouse_y
          state.tb_bar_y = y
        end

        if i == 1 then toolbar_left_edge = tb_x end
        tb_x = tb_x + btn_w + gap
      end
    end
    -- Track right edge for text clipping
    toolbar_right_edge = tb_x - gap

    -- Drag-and-drop reorder logic
    local drag_threshold = 4
    if state.tb_drag_idx and reaper.ImGui_IsMouseDown(ctx, 0) then
      local dx = math.abs(mouse_x - (state.tb_drag_start_x or mouse_x))
      if not state.tb_drag_active and dx >= drag_threshold then
        state.tb_drag_active = true
      end
      if state.tb_drag_active then
        -- Find drop target: which slot is the mouse closest to?
        local drop_idx = nil
        for i = 1, #btn_metrics do
          local m = btn_metrics[i]
          local center = m.x + m.w / 2
          if mouse_x < center then
            drop_idx = i
            break
          end
        end
        if not drop_idx then drop_idx = #toolbar_buttons + 1 end
        state.tb_drop_idx = drop_idx

        -- Draw insertion indicator line
        local line_x
        if drop_idx <= #btn_metrics then
          line_x = btn_metrics[drop_idx].x - math.floor(gap / 2)
        else
          local last = btn_metrics[#btn_metrics]
          line_x = last.x + last.w + math.floor(gap / 2)
        end
        reaper.ImGui_DrawList_AddLine(draw_list, line_x, tb_btn_y - 2, line_x, tb_btn_y + tb_btn_h + 2, 0xFFFFFFCC, 2)
      end
    elseif state.tb_drag_idx then
      -- Mouse released
      if state.tb_drag_active and state.tb_drop_idx then
        local from = state.tb_drag_idx
        local to = state.tb_drop_idx
        -- Adjust target: if dropping after the source, account for removal shift
        if to > from then to = to - 1 end
        if to ~= from and to >= 1 and to <= #toolbar_buttons then
          settings.move_toolbar_button(from, to)
        end
      elseif not state.tb_drag_active then
        -- Was a click, not a drag: trigger the action (skip separators)
        local clicked_btn = toolbar_buttons[state.tb_drag_idx]
        if clicked_btn and clicked_btn.type ~= "separator" then
          state.toolbar_clicked = state.tb_drag_idx
        end
      end
      state.tb_drag_idx = nil
      state.tb_drag_start_x = nil
      state.tb_drag_active = false
      state.tb_drop_idx = nil
    end
  end

  -- Ghost "+" button to add new toolbar button
  -- Always visible (faint when idle, highlighted on hover), works with or without existing buttons
  if state then
    local has_buttons = toolbar_buttons and #toolbar_buttons > 0
    local add_btn_size = has_buttons and 30 or math.min(20, height - 4)
    local add_btn_y = y + math.floor((height - add_btn_size) / 2)
    local add_btn_x
    if has_buttons then
      -- Position after the last toolbar button (toolbar_right_edge + gap)
      add_btn_x = toolbar_right_edge + (config.TOOLBAR_BTN_GAP or 4)
    else
      -- No buttons: center in the bar
      add_btn_x = x + math.floor((width - add_btn_size) / 2)
    end

    local add_mouse_in = mouse_x >= add_btn_x and mouse_x <= add_btn_x + add_btn_size
                         and mouse_y >= add_btn_y and mouse_y <= add_btn_y + add_btn_size
                         and not (state.tb_drag_active)
                         and not reaper.ImGui_IsPopupOpen(ctx, "", reaper.ImGui_PopupFlags_AnyPopup())

    -- When buttons exist: only draw on hover. When empty: always show faintly.
    local draw_add = add_mouse_in or not has_buttons
    if draw_add then
      local box_col = add_mouse_in and 0xAAAAAAFF or 0x44444480
      local plus_col = add_mouse_in and 0xCCCCCCFF or 0x55555580
      reaper.ImGui_DrawList_AddRect(draw_list, add_btn_x, add_btn_y,
        add_btn_x + add_btn_size, add_btn_y + add_btn_size, box_col, 4)
      local plus_cx = add_btn_x + add_btn_size / 2
      local plus_cy = add_btn_y + add_btn_size / 2
      reaper.ImGui_DrawList_AddLine(draw_list, plus_cx - 5, plus_cy, plus_cx + 5, plus_cy, plus_col, 1.5)
      reaper.ImGui_DrawList_AddLine(draw_list, plus_cx, plus_cy - 5, plus_cx, plus_cy + 5, plus_col, 1.5)
    end

    if add_mouse_in then
      drawing.tooltip(ctx, "tb_add", "Add button")
      if reaper.ImGui_IsMouseClicked(ctx, 0) then
        state.tb_edit_idx = nil
        state.tb_edit_insert_after = toolbar_buttons and #toolbar_buttons or 0
        state.tb_edit_label = ""
        state.tb_edit_cmd = ""
        state.tb_edit_icon = nil
        state.tb_edit_auto_label = nil
        state.tb_edit_open = true
        action_search_text = ""
        action_search_results = {}
        action_search_sel_idx = 0
        action_search_confirmed = ""
      end
    end

    -- Extend right edge to include the "+" button
    toolbar_right_edge = math.max(toolbar_right_edge, add_btn_x + add_btn_size)
  end

  -- Right boundary for filename text (don't overlap toolbar or right-side buttons)
  local text_max_x = (toolbar_buttons and #toolbar_buttons > 0)
    and (toolbar_left_edge - 8)
    or (toolbar_right_edge - 2)

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

  if mouse_in_mute then
    local mute_tip = "Toggle mute"
    if settings then
      local mute_shortcut = settings.current.shortcuts.toggle_mute
      if mute_shortcut and mute_shortcut.key ~= "" then
        mute_tip = mute_tip .. " (" .. settings.format_shortcut(mute_shortcut) .. ")"
      end
    end
    drawing.tooltip(ctx, "mute_btn", mute_tip)
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

  -- Waveform icon (fixed size, vertically centered)
  local icon_x = mute_x + mute_size + 6
  local icon_center_y = y + height / 2
  local icon_max_h = 10

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
  local text_h = reaper.ImGui_GetTextLineHeight(ctx)
  local text_y = y + math.floor((height - text_h) / 2)

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
      local underline_y = text_y + text_h + 1
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

  if mouse_over_filename then
    drawing.tooltip(ctx, "filename", "Click to show in Media Explorer")
  end

  if mouse_over_filename and reaper.ImGui_IsMouseClicked(ctx, 0) and file_path and file_path ~= "" then
    -- Navigate REAPER's Media Explorer to the file
    if reaper.OpenMediaExplorer then
      reaper.OpenMediaExplorer(file_path, false)
    end
    return true, false, nil
  end

  -- Right-click on info bar background → "Add" context menu
  -- (only if not already handled by a button, gear, cue, mute, or filename)
  if state and not state.tb_ctx_open and reaper.ImGui_IsMouseClicked(ctx, 1) then
    local in_bar = mouse_x >= x and mouse_x <= x + width
                   and mouse_y >= y and mouse_y <= y + height
    if in_bar and not mouse_in_gear and not mouse_over_filename and not mouse_in_mute and not mouse_in_zoom then
      state.tb_ctx_idx = nil  -- nil = empty area
      state.tb_ctx_open = true
      state.tb_ctx_x = mouse_x
      state.tb_ctx_y = mouse_y
      state.tb_bar_y = y
    end
  end

  return mouse_over_filename, gear_clicked, tab_clicked
end

-- Toolbar icon cache for context menu icon picker (reuses get_toolbar_icon above)

-- Shared icon picker content: filter, live hover display, keywords, scrollable icon grid
-- Signature: draw_icon_picker_content(ctx, icons, child_id, get_icon_fn)
--   get_icon_fn(ctx, filename) -> img, uv_u1  (icon loader, differs per call site)
-- Returns: filename string if icon picked, "" if "Text Only" picked, false if closed, nil if nothing
function drawing.draw_icon_picker_content(ctx, icons, child_id, get_icon_fn)
  local picked = nil
  local content_w = reaper.ImGui_GetContentRegionAvail(ctx)
  local label_color = 0xBBBBBBFF

  -- Title row: centered "Select toolbar icon" + X close button top-right
  local close_label = "X"
  local row_h = 24
  local close_w = reaper.ImGui_CalcTextSize(ctx, close_label) + 16
  local save_cx = reaper.ImGui_GetCursorPosX(ctx)
  local save_cy = reaper.ImGui_GetCursorPosY(ctx)

  -- X button (right-aligned, vertically centered in row)
  reaper.ImGui_SetCursorPos(ctx, save_cx + content_w - close_w, save_cy)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x00000000)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x88333CFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0xAA4444FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x999999FF)
  if reaper.ImGui_Button(ctx, close_label .. "##icon_close_" .. child_id, close_w, row_h) then
    picked = false
  end
  if reaper.ImGui_IsItemHovered(ctx) then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFFFFFFF)
    reaper.ImGui_PopStyleColor(ctx)  -- consumed by hover check scope
  end
  reaper.ImGui_PopStyleColor(ctx, 4)

  -- Title (centered, vertically centered in row)
  local title = "Select toolbar icon"
  local title_w = reaper.ImGui_CalcTextSize(ctx, title)
  local text_h = reaper.ImGui_GetTextLineHeight(ctx)
  reaper.ImGui_SetCursorPos(ctx, save_cx + (content_w - title_w) / 2,
    save_cy + math.floor((row_h - text_h) / 2))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFFFFFFF)
  reaper.ImGui_Text(ctx, title)
  reaper.ImGui_PopStyleColor(ctx)

  -- Move past the row
  reaper.ImGui_SetCursorPosY(ctx, save_cy + row_h + 2)

  reaper.ImGui_Spacing(ctx)
  local hdl = reaper.ImGui_GetWindowDrawList(ctx)
  local hsx, hsy = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_DrawList_AddLine(hdl, hsx, hsy, hsx + content_w, hsy, 0x444444FF, 1)
  reaper.ImGui_Dummy(ctx, 0, 4)

  -- Shared button width for Clear / Keywords (use wider label)
  local clear_label = "Clear"
  local kw_label = "Keywords"
  local clear_text_w = reaper.ImGui_CalcTextSize(ctx, clear_label)
  local kw_text_w = reaper.ImGui_CalcTextSize(ctx, kw_label)
  local btn_w = math.max(clear_text_w, kw_text_w) + 16

  -- Compute shared label width so both input fields align
  local filter_label = "Filter:"
  local current_label = "Current:"
  local filter_label_w = reaper.ImGui_CalcTextSize(ctx, filter_label)
  local current_label_w = reaper.ImGui_CalcTextSize(ctx, current_label)
  local label_w = math.max(filter_label_w, current_label_w)
  local spacing = 24  -- gaps between label, input, button

  -- Filter row: label + InputText + "Clear" button
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), label_color)
  reaper.ImGui_Text(ctx, filter_label)
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_SameLine(ctx, 0, label_w - filter_label_w + 8)

  local input_w = content_w - label_w - btn_w - spacing
  reaper.ImGui_SetNextItemWidth(ctx, input_w)
  if icon_picker_state.focus_filter then
    reaper.ImGui_SetKeyboardFocusHere(ctx)
    icon_picker_state.focus_filter = false
  end
  local _, new_filter = reaper.ImGui_InputText(ctx, "##icon_filter_" .. child_id, icon_picker_state.filter_text)
  icon_picker_state.filter_text = new_filter

  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x404040FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x505050FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x606060FF)
  if reaper.ImGui_Button(ctx, clear_label .. "##icon_clear_" .. child_id, btn_w) then
    icon_picker_state.filter_text = ""
  end
  reaper.ImGui_PopStyleColor(ctx, 3)

  -- Build filtered icon list
  local filtered = {}
  local filter_lower = icon_picker_state.filter_text:lower()
  local filter_words = {}
  for w in filter_lower:gmatch("%S+") do
    filter_words[#filter_words + 1] = w
  end
  if #filter_words == 0 then
    filtered = icons
  else
    for _, filename in ipairs(icons) do
      local name_lower = filename:lower()
      local match = true
      for _, w in ipairs(filter_words) do
        if not name_lower:find(w, 1, true) then
          match = false
          break
        end
      end
      if match then
        filtered[#filtered + 1] = filename
      end
    end
  end

  -- Current row: label + hovered name display + "Keywords" button
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), label_color)
  reaper.ImGui_Text(ctx, current_label)
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_SameLine(ctx, 0, label_w - current_label_w + 8)

  local display_w = content_w - label_w - btn_w - spacing
  reaper.ImGui_SetNextItemWidth(ctx, display_w)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0x1A1A1AFF)
  reaper.ImGui_InputText(ctx, "##icon_current_" .. child_id, icon_picker_state.hovered_name,
    reaper.ImGui_InputTextFlags_ReadOnly())
  reaper.ImGui_PopStyleColor(ctx)

  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x404040FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x505050FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x606060FF)
  if reaper.ImGui_Button(ctx, kw_label .. "##icon_kw_" .. child_id, btn_w) then
    reaper.ImGui_OpenPopup(ctx, "##icon_keywords_" .. child_id)
  end
  reaper.ImGui_PopStyleColor(ctx, 3)

  -- Keywords popup
  if reaper.ImGui_BeginPopup(ctx, "##icon_keywords_" .. child_id) then
    -- Extract keywords from filtered icons
    local kw_counts = {}
    local kw_order = {}
    -- Words already in filter (to exclude)
    local filter_set = {}
    for _, w in ipairs(filter_words) do filter_set[w] = true end

    for _, filename in ipairs(filtered) do
      local base = filename:lower():gsub("%.png$", "")
      for seg in base:gmatch("[^_]+") do
        if #seg > 1 and not filter_set[seg] then
          if not kw_counts[seg] then
            kw_counts[seg] = 0
            kw_order[#kw_order + 1] = seg
          end
          kw_counts[seg] = kw_counts[seg] + 1
        end
      end
    end

    -- Sort by count descending
    table.sort(kw_order, function(a, b) return kw_counts[a] > kw_counts[b] end)

    if #kw_order == 0 then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x888888FF)
      reaper.ImGui_Text(ctx, "No keywords available")
      reaper.ImGui_PopStyleColor(ctx)
    else
      for _, kw in ipairs(kw_order) do
        -- Capitalize first letter for display
        local display = kw:sub(1,1):upper() .. kw:sub(2)
        if reaper.ImGui_MenuItem(ctx, display .. " (" .. kw_counts[kw] .. ")") then
          -- Append keyword to filter
          if icon_picker_state.filter_text == "" then
            icon_picker_state.filter_text = kw
          else
            icon_picker_state.filter_text = icon_picker_state.filter_text .. " " .. kw
          end
        end
      end
    end
    reaper.ImGui_EndPopup(ctx)
  end

  reaper.ImGui_Spacing(ctx)
  local hsx2, hsy2 = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_DrawList_AddLine(hdl, hsx2, hsy2, hsx2 + content_w, hsy2, 0x444444FF, 1)
  reaper.ImGui_Dummy(ctx, 0, 4)

  -- "Text Only" button (centered)
  local text_only_label = "Text Only (no icon)"
  local text_only_w = reaper.ImGui_CalcTextSize(ctx, text_only_label) + 24
  reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + (content_w - text_only_w) / 2)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x404040FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x505050FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x606060FF)
  if reaper.ImGui_Button(ctx, text_only_label .. "##" .. child_id, text_only_w, 28) then
    picked = ""
  end
  reaper.ImGui_PopStyleColor(ctx, 3)

  reaper.ImGui_Dummy(ctx, 0, 2)
  local hsx3, hsy3 = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_DrawList_AddLine(hdl, hsx3, hsy3, hsx3 + content_w, hsy3, 0x444444FF, 1)
  reaper.ImGui_Dummy(ctx, 0, 4)

  -- Icon count
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x888888FF)
  reaper.ImGui_Text(ctx, #filtered .. " icons matching")
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_Spacing(ctx)

  -- Icon grid inside scrollable child
  local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
  local _, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  local scrollbar_w = 14
  local grid_w = avail_w - scrollbar_w
  local cell_size = 42
  local cell_gap = 3
  local cols = math.max(1, math.floor((grid_w + cell_gap) / (cell_size + cell_gap)))

  if reaper.ImGui_BeginChild(ctx, child_id, avail_w, avail_h - 4) then
    local grid_dl = reaper.ImGui_GetWindowDrawList(ctx)
    for i, filename in ipairs(filtered) do
      if (i - 1) % cols ~= 0 then
        reaper.ImGui_SameLine(ctx, 0, cell_gap)
      end

      local img, uv_u1 = get_icon_fn(ctx, filename)
      local gx, gy = reaper.ImGui_GetCursorScreenPos(ctx)
      reaper.ImGui_PushID(ctx, i)
      reaper.ImGui_InvisibleButton(ctx, "##ic", cell_size, cell_size)
      local hovered = reaper.ImGui_IsItemHovered(ctx)
      local clicked = reaper.ImGui_IsItemClicked(ctx, 0)

      local bg = hovered and 0x555555FF or 0x333333FF
      reaper.ImGui_DrawList_AddRectFilled(grid_dl, gx, gy, gx + cell_size, gy + cell_size, bg, 4)
      if img then
        local pad = 4
        local img_ok = pcall(reaper.ImGui_DrawList_AddImage, grid_dl, img, gx + pad, gy + pad, gx + cell_size - pad, gy + cell_size - pad, 0, 0, uv_u1 or 1/3, 1, 0xFFFFFFFF)
        if not img_ok then
          -- Mark as failed in the loader's cache (caller responsibility)
        end
      end

      if hovered then
        -- Update live display with icon name (strip .png)
        local display_name = filename:gsub("%.png$", "")
        icon_picker_state.hovered_name = display_name
      end

      if clicked then
        picked = filename
      end

      reaper.ImGui_PopID(ctx)
    end
    reaper.ImGui_EndChild(ctx)
  end

  return picked
end

-- Draw toolbar context menu + edit popup
-- Call this once per frame from main script, after draw_info_bar
function drawing.draw_toolbar_popups(ctx, state, settings, config)
  if not state then return end

  -- Trigger context menu popup
  if state.tb_ctx_open then
    reaper.ImGui_OpenPopup(ctx, "##tb_ctx")
    state.tb_ctx_open = false
  end

  -- Render context menu
  if reaper.ImGui_BeginPopup(ctx, "##tb_ctx") then
    local idx = state.tb_ctx_idx
    local btns = settings.current.toolbar_buttons or {}

    if idx and idx >= 1 and idx <= #btns then
      local btn = btns[idx]

      if btn.type == "separator" then
        -- Right-clicked on a separator
        if reaper.ImGui_MenuItem(ctx, "Remove Separator") then
          settings.remove_toolbar_button(idx)
        end
        reaper.ImGui_Separator(ctx)
      else
        -- Right-clicked on a button
        if reaper.ImGui_MenuItem(ctx, "Edit...") then
          state.tb_edit_idx = idx
          state.tb_edit_label = btn.label
          state.tb_edit_cmd = btn.cmd
          state.tb_edit_icon = btn.icon
          state.tb_edit_auto_label = nil
          state.tb_edit_open = true
          local action_name = ""
          if btn.cmd and btn.cmd ~= "" then
            local cache = get_action_cache()
            for _, entry in ipairs(cache) do
              if entry.cmd == btn.cmd then
                action_name = entry.name
                break
              end
            end
          end
          action_search_text = action_name
          action_search_results = {}
          action_search_sel_idx = 0
          action_search_confirmed = action_name
        end

        reaper.ImGui_Separator(ctx)

        if reaper.ImGui_MenuItem(ctx, "Remove button") then
          settings.remove_toolbar_button(idx)
        end

        reaper.ImGui_Separator(ctx)
      end
    end

    -- Always show "Add" options at the bottom
    -- idx is the right-clicked item (or nil for empty area): insert after it
    if reaper.ImGui_MenuItem(ctx, "Add Button...") then
      state.tb_edit_idx = nil
      state.tb_edit_insert_after = idx  -- insert after right-clicked item
      state.tb_edit_label = ""
      state.tb_edit_cmd = ""
      state.tb_edit_icon = nil
      state.tb_edit_auto_label = nil
      state.tb_edit_open = true
      action_search_text = ""
      action_search_results = {}
      action_search_sel_idx = 0
      action_search_confirmed = ""
    end

    if reaper.ImGui_MenuItem(ctx, "Add Separator") then
      settings.add_toolbar_separator(idx)
    end

    reaper.ImGui_EndPopup(ctx)
  end

  -- Trigger edit modal
  if state.tb_edit_open then
    reaper.ImGui_OpenPopup(ctx, "Edit Toolbar Button##tb_edit")
    state.tb_edit_open = false
    state.tb_edit_focus_label = true
  end

  -- Render edit modal (centered on screen)
  local vp_w, vp_h = reaper.ImGui_Viewport_GetSize(reaper.ImGui_GetMainViewport(ctx))
  reaper.ImGui_SetNextWindowPos(ctx, vp_w / 2, vp_h / 2, reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
  reaper.ImGui_SetNextWindowSize(ctx, 800, 0, reaper.ImGui_Cond_Appearing())
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 20, 16)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 8)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 8, 8)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(), 0x2A2A2AFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), 0x555555FF)
  -- Only block Nav while action dropdown is visible so Tab still works between inputs
  local dropdown_showing = #action_search_results > 0
      and action_search_text ~= ""
      and action_search_confirmed == ""
  local edit_flags = reaper.ImGui_WindowFlags_NoTitleBar()
                   + reaper.ImGui_WindowFlags_AlwaysAutoResize()
                   + (dropdown_showing and reaper.ImGui_WindowFlags_NoNav() or 0)
  if reaper.ImGui_BeginPopupModal(ctx, "Edit Toolbar Button##tb_edit", nil, edit_flags) then
    -- Capture keyboard so REAPER doesn't intercept Ctrl+V etc.
    reaper.ImGui_SetNextFrameWantCaptureKeyboard(ctx, true)

    -- Centered title
    local edit_title = state.tb_edit_idx and "Edit Toolbar Button" or "Add Toolbar Button"
    local title_w = reaper.ImGui_CalcTextSize(ctx, edit_title)
    local content_w = reaper.ImGui_GetContentRegionAvail(ctx)
    reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + (content_w - title_w) / 2)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFFFFFFF)
    reaper.ImGui_Text(ctx, edit_title)
    reaper.ImGui_PopStyleColor(ctx)

    reaper.ImGui_Spacing(ctx)
    local edl = reaper.ImGui_GetWindowDrawList(ctx)
    local esx, esy = reaper.ImGui_GetCursorScreenPos(ctx)
    reaper.ImGui_DrawList_AddLine(edl, esx, esy, esx + content_w, esy, 0x444444FF, 1)
    reaper.ImGui_Dummy(ctx, 0, 4)

    local label_empty = (state.tb_edit_label or "") == ""
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xBBBBBBFF)
    reaper.ImGui_Text(ctx, "Label")
    reaper.ImGui_PopStyleColor(ctx)
    if edit_show_validation and label_empty then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), 0xFF4444FF)
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 1)
    end
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    if state.tb_edit_focus_label then
      reaper.ImGui_SetKeyboardFocusHere(ctx)
      state.tb_edit_focus_label = false
    end
    local _, new_label = reaper.ImGui_InputText(ctx, "##tb_ed_label", state.tb_edit_label or "")
    if edit_show_validation and label_empty then
      reaper.ImGui_PopStyleVar(ctx)
      reaper.ImGui_PopStyleColor(ctx)
    end
    state.tb_edit_label = new_label

    -- Action search autocomplete
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xBBBBBBFF)
    reaper.ImGui_Text(ctx, "Search Actions")
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    -- Note: no SetKeyboardFocusHere here. InputText keeps focus naturally while
    -- the user types, and removing the per-frame focus lock lets clicks on the
    -- dropdown Selectable items register immediately.
    -- AutoSelectAll: clicking into field selects all text, so typing replaces it
    local search_flags = reaper.ImGui_InputTextFlags_AutoSelectAll()
    local _, new_search = reaper.ImGui_InputText(ctx, "##tb_ed_search", action_search_text, search_flags)
    local search_focused = reaper.ImGui_IsItemActive(ctx)
    -- Detect Enter on the search field: InputText deactivates on Enter, so check both
    local search_deactivated = reaper.ImGui_IsItemDeactivated(ctx)
    local enter_pressed = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter())
        or reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_KeypadEnter())
    local search_enter = search_deactivated and enter_pressed

    -- Filter results on text change
    if new_search ~= action_search_text then
      action_search_text = new_search
      action_search_sel_idx = 0
      action_search_results = {}
      -- User changed text from confirmed selection, clear confirmed state
      if action_search_confirmed ~= "" and new_search ~= action_search_confirmed then
        action_search_confirmed = ""
      end
      if new_search ~= "" then
        -- Split query into words for multi-word matching (like REAPER's filter)
        local words = {}
        for w in new_search:lower():gmatch("%S+") do
          words[#words + 1] = w
        end
        local cache = get_action_cache()
        local count = 0
        for _, entry in ipairs(cache) do
          local lower_name = entry.name:lower()
          local match = true
          for _, w in ipairs(words) do
            if not lower_name:find(w, 1, true) then
              match = false
              break
            end
          end
          if match then
            count = count + 1
            action_search_results[count] = entry
            if count >= 50 then break end
          end
        end
      end
    end

    -- Keyboard navigation (Up/Down while dropdown is showing)
    local confirmed_entry = nil
    local kb_navigated = false
    local dropdown_active = #action_search_results > 0 and action_search_confirmed == ""
    if dropdown_active then
      if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_DownArrow()) then
        action_search_sel_idx = math.min(action_search_sel_idx + 1, #action_search_results)
        kb_navigated = true
      elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_UpArrow()) then
        action_search_sel_idx = math.max(action_search_sel_idx - 1, 0)
        kb_navigated = true
      end
    end
    -- Enter confirmation (detected via InputText deactivation + Enter key)
    if search_enter and action_search_sel_idx > 0
        and action_search_sel_idx <= #action_search_results then
      confirmed_entry = action_search_results[action_search_sel_idx]
    end

    -- Dropdown results table (Shortcut | Description | Command ID)
    -- Hide dropdown when showing a confirmed selection (user hasn't started re-searching)
    local show_dropdown = #action_search_results > 0 and action_search_text ~= ""
        and action_search_confirmed == ""
    if show_dropdown then
      local dropdown_h = math.min(math.max(#action_search_results * 22 + 30, 120), 300)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0x1E1E1EFF)
      if reaper.ImGui_BeginChild(ctx, "##action_results", -1, dropdown_h,
          reaper.ImGui_ChildFlags_Borders()) then
        local tbl_flags = reaper.ImGui_TableFlags_RowBg()
                        + reaper.ImGui_TableFlags_ScrollY()
                        + reaper.ImGui_TableFlags_BordersInnerV()
        if reaper.ImGui_BeginTable(ctx, "##action_tbl", 3, tbl_flags) then
          reaper.ImGui_TableSetupColumn(ctx, "Shortcut",
            reaper.ImGui_TableColumnFlags_WidthFixed(), 130)
          reaper.ImGui_TableSetupColumn(ctx, "Description",
            reaper.ImGui_TableColumnFlags_WidthStretch())
          reaper.ImGui_TableSetupColumn(ctx, "Command ID",
            reaper.ImGui_TableColumnFlags_WidthFixed(), 160)
          reaper.ImGui_TableSetupScrollFreeze(ctx, 0, 1)
          reaper.ImGui_TableHeadersRow(ctx)
          for i, entry in ipairs(action_search_results) do
            reaper.ImGui_TableNextRow(ctx)
            local is_sel = (i == action_search_sel_idx)
            -- Shortcut column (selectable spans full row)
            reaper.ImGui_TableNextColumn(ctx)
            if reaper.ImGui_Selectable(ctx, (entry.shortcut or "") .. "##asr" .. i, is_sel,
                reaper.ImGui_SelectableFlags_SpanAllColumns()) then
              confirmed_entry = entry
            end
            -- Only auto-scroll on keyboard nav (not hover) to prevent scroll fighting
            if is_sel and kb_navigated then
              reaper.ImGui_SetScrollHereY(ctx, 0.5)
            end
            -- Description column
            reaper.ImGui_TableNextColumn(ctx)
            reaper.ImGui_Text(ctx, entry.name)
            -- Command ID column
            reaper.ImGui_TableNextColumn(ctx)
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x999999FF)
            reaper.ImGui_Text(ctx, entry.cmd)
            reaper.ImGui_PopStyleColor(ctx)
          end
          reaper.ImGui_EndTable(ctx)
        end
        reaper.ImGui_EndChild(ctx)
      end
      reaper.ImGui_PopStyleColor(ctx)
    end

    -- Apply confirmed selection
    if confirmed_entry then
      state.tb_edit_cmd = confirmed_entry.cmd
      if state.tb_edit_label == "" or state.tb_edit_label == (state.tb_edit_auto_label or "") then
        state.tb_edit_label = confirmed_entry.name
        state.tb_edit_auto_label = confirmed_entry.name
      end
      -- Show selected action name in search field (click to re-search)
      action_search_text = confirmed_entry.name
      action_search_confirmed = confirmed_entry.name
      action_search_results = {}
      action_search_sel_idx = 0
    end

    local cmd_empty = (state.tb_edit_cmd or "") == ""
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xBBBBBBFF)
    reaper.ImGui_Text(ctx, "Action Command ID")
    reaper.ImGui_PopStyleColor(ctx)
    if edit_show_validation and cmd_empty then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), 0xFF4444FF)
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 1)
    end
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    local _, new_cmd = reaper.ImGui_InputText(ctx, "##tb_ed_cmd", state.tb_edit_cmd or "")
    if edit_show_validation and cmd_empty then
      reaper.ImGui_PopStyleVar(ctx)
      reaper.ImGui_PopStyleColor(ctx)
    end
    -- Auto-fill label when command ID changes and label is empty or was auto-filled
    if new_cmd ~= (state.tb_edit_cmd or "") and new_cmd ~= "" then
      local cmd_id = tonumber(new_cmd) or reaper.NamedCommandLookup(new_cmd)
      if cmd_id and cmd_id > 0 then
        local name
        if reaper.kbd_getTextFromCmd then
          name = reaper.kbd_getTextFromCmd(cmd_id, 0)  -- 0 = Main section
        elseif reaper.CF_GetCommandText then
          name = reaper.CF_GetCommandText(0, cmd_id)  -- SWS fallback
        end
        if name and name ~= "" then
          -- Auto-fill if label is empty or was previously auto-filled
          if state.tb_edit_label == "" or state.tb_edit_label == (state.tb_edit_auto_label or "") then
            state.tb_edit_label = name
            state.tb_edit_auto_label = name
          end
        end
      end
    end
    state.tb_edit_cmd = new_cmd

    reaper.ImGui_Dummy(ctx, 0, 2)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x888888FF)
    reaper.ImGui_TextWrapped(ctx, "Paste ID directly, or use Search Actions above.")
    reaper.ImGui_PopStyleColor(ctx)

    reaper.ImGui_Dummy(ctx, 0, 4)
    local esx2, esy2 = reaper.ImGui_GetCursorScreenPos(ctx)
    reaper.ImGui_DrawList_AddLine(edl, esx2, esy2, esx2 + content_w, esy2, 0x444444FF, 1)
    reaper.ImGui_Dummy(ctx, 0, 4)

    -- Icon preview (clickable to open icon picker)
    local icon_label_y = reaper.ImGui_GetCursorPosY(ctx)
    local icon_text_h = reaper.ImGui_GetTextLineHeight(ctx)
    local icon_label_offset = math.floor((30 - icon_text_h) / 2)
    reaper.ImGui_SetCursorPosY(ctx, icon_label_y + icon_label_offset)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xBBBBBBFF)
    reaper.ImGui_Text(ctx, "Icon")
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetCursorPosY(ctx, icon_label_y)
    local icon_clicked = false
    if state.tb_edit_icon and state.tb_edit_icon ~= "" then
      local icon_img, icon_uv = get_toolbar_icon(ctx, state.tb_edit_icon)
      if icon_img then
        -- Clickable icon with hover highlight
        local dl = reaper.ImGui_GetWindowDrawList(ctx)
        local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
        reaper.ImGui_InvisibleButton(ctx, "##tb_ed_icon_btn", 30, 30)
        local icon_hovered = reaper.ImGui_IsItemHovered(ctx)
        icon_clicked = reaper.ImGui_IsItemClicked(ctx, 0)
        if icon_hovered then
          reaper.ImGui_DrawList_AddRectFilled(dl, cx - 2, cy - 2, cx + 32, cy + 32, 0xFFFFFF25, 4)
        end
        local img_ok = pcall(reaper.ImGui_DrawList_AddImage, dl, icon_img, cx, cy, cx + 30, cy + 30, 0, 0, icon_uv or 1/3, 1, 0xFFFFFFFF)
        if not img_ok then toolbar_icon_cache[state.tb_edit_icon] = false end
        if icon_hovered then
          reaper.ImGui_SetTooltip(ctx, "Click to change icon")
        end
      else
        -- Image failed to load, show placeholder
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x404040FF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x505050FF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x606060FF)
        if reaper.ImGui_SmallButton(ctx, "Change...##tb_ed_icon_change") then
          icon_clicked = true
        end
        reaper.ImGui_PopStyleColor(ctx, 3)
      end
    else
      -- No icon: outlined box with "+" and "Set icon..." label (matches settings UI)
      local dl = reaper.ImGui_GetWindowDrawList(ctx)
      local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
      local text_h = reaper.ImGui_GetTextLineHeight(ctx)
      local lbl_text = "Set icon..."
      local hit_w = 30 + 6 + reaper.ImGui_CalcTextSize(ctx, lbl_text)
      reaper.ImGui_InvisibleButton(ctx, "##tb_ed_icon_none", hit_w, 30)
      local none_hovered = reaper.ImGui_IsItemHovered(ctx)
      icon_clicked = reaper.ImGui_IsItemClicked(ctx, 0)
      local box_col = none_hovered and 0xAAAAAAFF or 0x666666FF
      reaper.ImGui_DrawList_AddRect(dl, cx, cy, cx + 30, cy + 30, box_col, 4)
      local plus_col = none_hovered and 0xCCCCCCFF or 0x888888FF
      local plus_cx = cx + 15
      local plus_cy = cy + 15
      reaper.ImGui_DrawList_AddLine(dl, plus_cx - 5, plus_cy, plus_cx + 5, plus_cy, plus_col, 1.5)
      reaper.ImGui_DrawList_AddLine(dl, plus_cx, plus_cy - 5, plus_cx, plus_cy + 5, plus_col, 1.5)
      local lbl_y = cy + math.floor((30 - text_h) / 2)
      local lbl_col = none_hovered and 0xCCCCCCFF or 0x999999FF
      reaper.ImGui_DrawList_AddText(dl, cx + 36, lbl_y, lbl_col, lbl_text)
      if none_hovered then
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
      end
    end
    if icon_clicked then
      state.tb_icon_idx = state.tb_edit_idx
      state.tb_icon_open = true
      state.tb_icon_from_edit = true
      state.tb_icon_list = nil
    end

    reaper.ImGui_Dummy(ctx, 0, 4)
    local esx3, esy3 = reaper.ImGui_GetCursorScreenPos(ctx)
    reaper.ImGui_DrawList_AddLine(edl, esx3, esy3, esx3 + content_w, esy3, 0x444444FF, 1)
    reaper.ImGui_Dummy(ctx, 0, 4)

    -- Clear validation highlight once both fields are filled
    if state.tb_edit_label ~= "" and state.tb_edit_cmd ~= "" then
      edit_show_validation = false
    end

    -- Save / Cancel buttons
    local btn_w = (content_w - 8) / 2
    local can_save = state.tb_edit_label ~= "" and state.tb_edit_cmd ~= ""

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x404040FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x505050FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x606060FF)
    if reaper.ImGui_Button(ctx, "Cancel", btn_w, 30) then
      edit_show_validation = false
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_PopStyleColor(ctx, 3)

    reaper.ImGui_SameLine(ctx)

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x4A90D9FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x5AA0E9FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x3A80C9FF)
    if reaper.ImGui_Button(ctx, "Save", btn_w, 30) then
      if can_save then
        local btns2 = settings.current.toolbar_buttons
        if state.tb_edit_idx and state.tb_edit_idx >= 1 and state.tb_edit_idx <= #btns2 then
          btns2[state.tb_edit_idx].label = state.tb_edit_label
          btns2[state.tb_edit_idx].cmd = state.tb_edit_cmd
          btns2[state.tb_edit_idx].icon = state.tb_edit_icon
          settings.save_toolbar()
        else
          settings.add_toolbar_button(state.tb_edit_label, state.tb_edit_cmd, state.tb_edit_icon, state.tb_edit_insert_after)
        end
        edit_show_validation = false
        reaper.ImGui_CloseCurrentPopup(ctx)
      else
        edit_show_validation = true
      end
    end
    reaper.ImGui_PopStyleColor(ctx, 3)

    -- Icon picker popup (nested INSIDE edit modal so it doesn't close the modal)
    if state.tb_icon_open and state.tb_icon_from_edit then
      reaper.ImGui_OpenPopup(ctx, "Choose Icon##tb_icon_pick")
      state.tb_icon_open = false
      drawing.reset_icon_picker_state()
      if not state.tb_icon_list then
        state.tb_icon_list = settings.scan_toolbar_icons()
      end
    end

    -- Position icon picker to the right of the edit modal, not overlapping
    local edit_wx, edit_wy = reaper.ImGui_GetWindowPos(ctx)
    local edit_ww, _ = reaper.ImGui_GetWindowSize(ctx)
    reaper.ImGui_SetNextWindowPos(ctx, edit_wx + edit_ww + 6, edit_wy, reaper.ImGui_Cond_Appearing(), 0.0, 0.0)
    reaper.ImGui_SetNextWindowSize(ctx, 900, 800, reaper.ImGui_Cond_Appearing())
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 16, 14)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 8)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(), 0x2A2A2AFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), 0x555555FF)
    local icon_flags = reaper.ImGui_WindowFlags_NoTitleBar()
                     + reaper.ImGui_WindowFlags_NoScrollbar()
    if reaper.ImGui_BeginPopupModal(ctx, "Choose Icon##tb_icon_pick", nil, icon_flags) then
      reaper.ImGui_SetNextFrameWantCaptureKeyboard(ctx, true)
      local icons = state.tb_icon_list or {}

      local picked = drawing.draw_icon_picker_content(ctx, icons, "tb_icon_grid", get_toolbar_icon)
      if picked == false then
        reaper.ImGui_CloseCurrentPopup(ctx)
      elseif picked == "" then
        state.tb_edit_icon = nil
        reaper.ImGui_CloseCurrentPopup(ctx)
      elseif picked then
        state.tb_edit_icon = picked
        reaper.ImGui_CloseCurrentPopup(ctx)
      end

      reaper.ImGui_EndPopup(ctx)
    end
    reaper.ImGui_PopStyleColor(ctx, 2)
    reaper.ImGui_PopStyleVar(ctx, 2)

    reaper.ImGui_EndPopup(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 2)
  reaper.ImGui_PopStyleVar(ctx, 4)

  -- Icon picker for direct context menu "Change Icon..." (NOT from edit popup)
  if state.tb_icon_open and not state.tb_icon_from_edit then
    reaper.ImGui_OpenPopup(ctx, "Choose Icon Direct##tb_icon_direct")
    state.tb_icon_open = false
    drawing.reset_icon_picker_state()
    if not state.tb_icon_list then
      state.tb_icon_list = settings.scan_toolbar_icons()
    end
  end

  local direct_popup_x = state.tb_ctx_x or 0
  local direct_popup_y = (state.tb_bar_y or state.tb_ctx_y or 0) - 4
  reaper.ImGui_SetNextWindowPos(ctx, direct_popup_x, direct_popup_y, reaper.ImGui_Cond_Appearing(), 0.5, 1.0)
  reaper.ImGui_SetNextWindowSize(ctx, 620, 640, reaper.ImGui_Cond_Appearing())
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 16, 14)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 8)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(), 0x2A2A2AFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), 0x555555FF)
  local direct_icon_flags = reaper.ImGui_WindowFlags_NoTitleBar()
                          + reaper.ImGui_WindowFlags_NoScrollbar()
  if reaper.ImGui_BeginPopupModal(ctx, "Choose Icon Direct##tb_icon_direct", nil, direct_icon_flags) then
    local icons = state.tb_icon_list or {}

    local picked = drawing.draw_icon_picker_content(ctx, icons, "tb_icon_grid_d", get_toolbar_icon)
    if picked == false then
      reaper.ImGui_CloseCurrentPopup(ctx)
    elseif picked == "" then
      local btns2 = settings.current.toolbar_buttons
      if state.tb_icon_idx and btns2[state.tb_icon_idx] then
        btns2[state.tb_icon_idx].icon = nil
        settings.save_toolbar()
      end
      reaper.ImGui_CloseCurrentPopup(ctx)
    elseif picked then
      local btns2 = settings.current.toolbar_buttons
      if state.tb_icon_idx and btns2[state.tb_icon_idx] then
        btns2[state.tb_icon_idx].icon = picked
        settings.save_toolbar()
      end
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    reaper.ImGui_EndPopup(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 2)
  reaper.ImGui_PopStyleVar(ctx, 2)
end

-- Draw waveform with per-view peaks (1:1 peak-to-pixel mapping)
-- peaks: per-view peaks from get_peaks_for_range (each peak maps to one pixel column)
-- view_start/view_length: pre-computed visible time range
-- pixel_step: 1 for full resolution, 2 for half (during REAPER interaction)
function drawing.draw_waveform(draw_list, x, y, width, height, peaks, start_offset, source_item_length, source_length, view_start, view_length, ruler_y, visual_gain, is_reversed, num_channels, config, pixel_step, bounds_start, bounds_end, is_loop_src, modulation)
  if not peaks or peaks.count == 0 or source_length <= 0 then return 0, 0 end

  visual_gain = visual_gain or 1.0
  is_reversed = is_reversed or false
  num_channels = num_channels or 1
  pixel_step = pixel_step or 1

  local item_end = start_offset + source_item_length
  -- Only treat as looped when Loop is actually ON; non-looped extended items have silence past source
  local is_looped = (is_loop_src ~= false) and source_item_length > source_length
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
      and wf_cache.y == y
      and wf_cache.waveform_zoom == (config.waveform_zoom or 1)
      and wf_cache.is_loop_src == is_loop_src then
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
        col_colors[i] = (not is_looped and (t < 0 or t >= source_length)) and 3 or 1
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
          local extent = power_curve(math.abs(raw)) * half_height * (config.waveform_zoom or 1)
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
          local wf_zoom = config.waveform_zoom or 1
          local top_y = center_y - scaled * half_height * wf_zoom
          local bot_y = center_y + scaled * half_height * wf_zoom
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
    wf_cache.waveform_zoom = config.waveform_zoom or 1
    wf_cache.is_loop_src = is_loop_src
  end

  -- Shaped waveform: apply per-pixel modulation from fades, volume/pan envelopes
  local mod_tops = col_tops
  local mod_bots = col_bots

  if modulation then
    local time_per_px = view_length / num_samples
    local channel_h = height / num_channels
    local item_start = start_offset
    local item_end_t = start_offset + source_item_length
    local pr = modulation.playrate or 1

    -- Fade LUTs (internally cached, essentially free)
    local fi_len = modulation.fade_in_len * pr  -- convert project time to source time
    local fo_len = modulation.fade_out_len * pr
    local fi_lut = fi_len > 0 and get_fade_lut(
        modulation.fade_in_shape, modulation.fade_in_dir, false) or nil
    local fo_lut = fo_len > 0 and get_fade_lut(
        modulation.fade_out_shape, modulation.fade_out_dir, true) or nil

    -- Envelope handles
    local vol_env = modulation.vol_env
    local vol_scaling = vol_env and reaper.GetEnvelopeScalingMode(vol_env) or 0
    local pan_env = modulation.pan_env
    local pan_value = modulation.pan_value or 0
    local is_stereo = num_channels >= 2
    local has_pan = is_stereo and (pan_value ~= 0 or pan_env ~= nil)

    -- Only call Envelope_Evaluate when there are actual points
    local vol_env_active = vol_env and reaper.CountEnvelopePoints(vol_env) > 0
    local pan_env_active = pan_env and reaper.CountEnvelopePoints(pan_env) > 0

    mod_tops = {}
    mod_bots = {}
    for ch = 1, num_channels do
      mod_tops[ch] = {}
      mod_bots[ch] = {}
    end

    for i = 0, num_samples - 1 do
      local t = view_start + i * time_per_px
      local gain = 1.0

      -- Fades (only within item bounds)
      if t >= item_start and t <= item_end_t then
        if fi_lut and t < item_start + fi_len then
          gain = fade_lut_lookup(fi_lut, (t - item_start) / fi_len)
        end
        if fo_lut and t > item_end_t - fo_len then
          gain = gain * fade_lut_lookup(fo_lut, (t - (item_end_t - fo_len)) / fo_len)
        end
      end

      -- Volume envelope (time in project seconds from item start)
      if vol_env_active then
        local env_t = (t - item_start) / pr
        local _, val = reaper.Envelope_Evaluate(vol_env, env_t, 0, 0)
        gain = gain * reaper.ScaleFromEnvelopeMode(vol_scaling, val)
      end

      -- Pan (stereo only, balance mode: L attenuates when panned R, vice versa)
      local pan_l, pan_r
      if has_pan then
        local pan = pan_value
        if pan_env_active then
          local env_t = (t - item_start) / pr
          local _, pv = reaper.Envelope_Evaluate(pan_env, env_t, 0, 0)
          pan = pv  -- envelope overrides knob
        end
        pan_l = math.min(1, 1 - pan)
        pan_r = math.min(1, 1 + pan)
      end

      -- Scale distance from center per channel
      for ch = 1, num_channels do
        local center_y = y + (ch - 1) * channel_h + channel_h * 0.5
        local ch_gain = gain
        if has_pan then
          ch_gain = ch_gain * (ch == 1 and pan_l or pan_r)
        end
        mod_tops[ch][i] = center_y - (center_y - col_tops[ch][i]) * ch_gain
        mod_bots[ch][i] = center_y + (col_bots[ch][i] - center_y) * ch_gain
      end
    end
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
      local tops = mod_tops[ch]
      local bots = mod_bots[ch]

      -- Fill: quads connecting adjacent columns for smooth waveform shape
      if s_stop > s_start then
        for i = s_start, s_stop - 1 do
          local px1 = x + i * pixel_step
          local px2 = x + (i + 1) * pixel_step
          DL_QuadFilled(draw_list,
            px1, tops[i], px2, tops[i + 1],
            px2, bots[i + 1], px1, bots[i],
            fill_color)
        end
      else
        -- Single pixel segment: draw a vertical line
        local px = x + s_start * pixel_step
        DL_AddLine(draw_list, px, tops[s_start], px, bots[s_start], fill_color, pixel_step)
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

  -- Use custom boundary positions if provided (warp mode passes warp-mapped source positions)
  local bound_start = bounds_start or 0
  local bound_end = bounds_end or source_length

  local orig_start_px = time_to_px(bound_start)
  local orig_end_px = time_to_px(bound_end)

  if orig_start_px >= x and orig_start_px <= x + width then
    drawing.draw_dashed_line(draw_list, orig_start_px, bounds_top, y + height, COLOR_BOUNDS, nil, nil, original_line_width)
  end
  if orig_end_px >= x and orig_end_px <= x + width then
    drawing.draw_dashed_line(draw_list, orig_end_px, bounds_top, y + height, COLOR_BOUNDS, nil, nil, original_line_width)
  end

  -- Loop boundaries only apply when using default bounds (non-warp mode)
  if not bounds_start then
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

  reaper.ImGui_DrawList_AddLine(draw_list, x, y, x, y + height, color, 2)

  local handle_size = 5
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

-- Draw ghost markers (other selected items' regions as bracket pairs)
function drawing.draw_ghost_markers(draw_list, regions, wave_x, wave_y, waveform_width, waveform_height, view_start, view_length, config)
  if not regions or #regions == 0 or view_length <= 0 then return end

  local bracket_color = (config.COLOR_MARKER & 0xFFFFFF00) | 0x66
  local fill_color = (config.COLOR_MARKER & 0xFFFFFF00) | 0x18
  local tick_len = 4
  local inset = 2

  reaper.ImGui_DrawList_PushClipRect(draw_list, wave_x, wave_y,
    wave_x + waveform_width, wave_y + waveform_height, true)

  for _, r in ipairs(regions) do
    local lx = wave_x + ((r.start_t - view_start) / view_length) * waveform_width
    local rx = wave_x + ((r.end_t - view_start) / view_length) * waveform_width

    -- Skip if entirely off screen
    if rx >= wave_x and lx <= wave_x + waveform_width then
      local top = wave_y + inset
      local bot = wave_y + waveform_height - inset

      -- Subtle fill
      local fill_l = math.max(lx, wave_x)
      local fill_r = math.min(rx, wave_x + waveform_width)
      if fill_r > fill_l then
        reaper.ImGui_DrawList_AddRectFilled(draw_list, fill_l, top, fill_r, bot, fill_color)
      end

      -- Left bracket: vertical line + ticks
      if lx >= wave_x and lx <= wave_x + waveform_width then
        reaper.ImGui_DrawList_AddLine(draw_list, lx, top, lx, bot, bracket_color, 1.5)
        reaper.ImGui_DrawList_AddLine(draw_list, lx, top, lx + tick_len, top, bracket_color, 1.5)
        reaper.ImGui_DrawList_AddLine(draw_list, lx, bot, lx + tick_len, bot, bracket_color, 1.5)
      end

      -- Right bracket: vertical line + ticks
      if rx >= wave_x and rx <= wave_x + waveform_width then
        reaper.ImGui_DrawList_AddLine(draw_list, rx, top, rx, bot, bracket_color, 1.5)
        reaper.ImGui_DrawList_AddLine(draw_list, rx, top, rx - tick_len, top, bracket_color, 1.5)
        reaper.ImGui_DrawList_AddLine(draw_list, rx, bot, rx - tick_len, bot, bracket_color, 1.5)
      end
    end
  end

  reaper.ImGui_DrawList_PopClipRect(draw_list)
end

-- Draw WAV cue markers (embedded cue points from source file)
-- markers must be sorted by time. Double-click a label to select the region to the next cue point.
function drawing.draw_cue_markers(ctx, draw_list, markers, wave_x, wave_y, waveform_width, waveform_height, view_start, view_length, source_length, is_extended, config, mouse_x, mouse_y, state, item)
  if not markers or #markers == 0 or view_length <= 0 then return end

  local view_end = view_start + view_length
  local color_line = config.COLOR_CUE_MARKER
  local color_text = config.COLOR_CUE_MARKER_TEXT
  local color_bg = config.COLOR_CUE_MARKER_BG
  local DL_AddText = reaper.ImGui_DrawList_AddText
  local DL_AddRectFilled = reaper.ImGui_DrawList_AddRectFilled
  local clicked = reaper.ImGui_IsMouseClicked(ctx, 0)
  if state then state.cue_label_hovered = false end

  reaper.ImGui_DrawList_PushClipRect(draw_list, wave_x, wave_y, wave_x + waveform_width, wave_y + waveform_height, true)

  for mi, marker in ipairs(markers) do
    -- Collect all visible instances (tiled for looped/extended items)
    local positions = {}
    if is_extended and source_length > 0 then
      local base = marker.time % source_length
      local first = base + math.floor((view_start - base) / source_length) * source_length
      if first > view_start then first = first - source_length end
      for t = first, view_end, source_length do
        if t >= view_start and t <= view_end then
          positions[#positions + 1] = t
        end
      end
    else
      if marker.time >= view_start and marker.time <= view_end then
        positions[#positions + 1] = marker.time
      end
    end

    for _, t in ipairs(positions) do
      local px = wave_x + ((t - view_start) / view_length) * waveform_width
      -- Dashed vertical line
      drawing.draw_dashed_line(draw_list, px, wave_y, wave_y + waveform_height, color_line, 4, 3, 1)
      -- Label at top
      if marker.name and marker.name ~= "" then
        local text_w = reaper.ImGui_CalcTextSize(ctx, marker.name)
        local label_x = px + 3
        local label_y = wave_y + 2
        local label_r = label_x + text_w + 3
        local label_b = label_y + 13

        -- Hit test for double-click: select region from this cue to next
        -- Suppress hover when envelope freehand drawing is active
        local suppress_hover = state and (state.env_freehand_drawing
            or (state.envelopes_visible and reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())))
        local mouse_in_label = not suppress_hover
            and mouse_x >= label_x - 1 and mouse_x <= label_r
            and mouse_y >= label_y - 1 and mouse_y <= label_b
        local bg = mouse_in_label and color_with_alpha(color_bg, 0xFF) or color_bg
        local txt = mouse_in_label and 0xFFFFFFFF or color_text

        DL_AddRectFilled(draw_list, label_x - 1, label_y - 1, label_r, label_b, bg, 2)
        DL_AddText(draw_list, label_x + 1, label_y, txt, marker.name)

        if mouse_in_label then
          reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
          if state then state.cue_label_hovered = true end
        end

        if mouse_in_label and clicked and state and item then
          -- Find next cue marker's time (or source_length if last)
          local next_time = source_length
          if markers[mi + 1] then
            next_time = markers[mi + 1].time
          end
          state.selection_start_time = marker.time
          state.selection_end_time = next_time
          state.region_selected = true
          state.region_sel_start = marker.time
          state.region_sel_end = next_time
          state.region_sel_item = item
          state.selecting_region = false
          state.selection_drag_activated = false
          -- Move preview cursor to marker position
          state.preview_cursor_pos = marker.time
        end
      end
    end
  end

  reaper.ImGui_DrawList_PopClipRect(draw_list)
end

-- Draw a knob
function drawing.draw_knob(draw_list, cx, cy, radius, angle, is_hovered, is_active, label, unit_text, config)
  local COLOR_KNOB_BG = config and config.COLOR_BTN_OFF or 0x303030FF
  local COLOR_KNOB_BORDER = is_active and (config and config.COLOR_MARKER_HOVER or 0x6AB0F9FF) or (is_hovered and (config and config.COLOR_RULER_TEXT or 0x888888FF) or (config and config.COLOR_RULER_TICK or 0x555555FF))
  local COLOR_KNOB_POINTER = config and config.COLOR_BTN_TEXT or 0xFFFFFFFF
  local COLOR_KNOB_ARC_BG = config and config.COLOR_BTN_OFF or 0x404040FF
  local COLOR_KNOB_ARC = config and config.COLOR_MARKER or 0x4A90D9FF

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
    reaper.ImGui_DrawList_AddText(draw_list, cx - lw / 2, cy - radius - 18, config and config.COLOR_INFO_BAR_TEXT or 0xAAAAAAFF, label)
  end
  if unit_text then
    reaper.ImGui_DrawList_AddText(draw_list, cx - 5, cy + radius + 2, config and config.COLOR_RULER_TEXT or 0x888888FF, unit_text)
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
                                     mouse_x, mouse_y, config, state, settings)
  -- Background (always visible)
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + width, y + height, config.COLOR_RULER_BG)
  reaper.ImGui_DrawList_AddLine(draw_list, x, y, x + width, y, config.COLOR_GRID_BAR, 1)

  local btn_w = 100
  local btn_h = height - 4
  local btn_x = x + 4
  local btn_y = y + 2
  local label = state.envelopes_visible and state.envelope_type or "Hidden"

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

  if mouse_in_btn and not state.envelope_dropdown_open then
    drawing.tooltip(ctx, "env_dropdown", "Envelope type")
  end

  -- Toggle dropdown on click
  if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_btn then
    state.envelope_dropdown_open = not state.envelope_dropdown_open
  end

  -- Envelope lock button (to the right of the envelope type dropdown)
  local lock_btn_w = 22
  local lock_gap = 3
  local lock_btn_x = btn_x + btn_w + lock_gap
  local lock_btn_y = btn_y
  local lock_btn_h = btn_h
  local mouse_in_lock = mouse_x >= lock_btn_x and mouse_x <= lock_btn_x + lock_btn_w
                        and mouse_y >= lock_btn_y and mouse_y <= lock_btn_y + lock_btn_h
  local lock_active = state.envelope_lock
  local lock_bg = lock_active and config.COLOR_BTN_ON or (mouse_in_lock and 0x505050FF or 0x303030FF)
  local lock_border = lock_active and config.COLOR_BTN_ON or 0x555555FF
  reaper.ImGui_DrawList_AddRectFilled(draw_list, lock_btn_x, lock_btn_y,
      lock_btn_x + lock_btn_w, lock_btn_y + lock_btn_h, lock_bg, 2)
  reaper.ImGui_DrawList_AddRect(draw_list, lock_btn_x, lock_btn_y,
      lock_btn_x + lock_btn_w, lock_btn_y + lock_btn_h, lock_border, 2)

  -- Draw lock icon
  local lcx = lock_btn_x + lock_btn_w / 2
  local lcy = lock_btn_y + lock_btn_h / 2
  local lock_color = lock_active and 0x202020FF or 0xCCCCCCFF
  -- Lock body
  reaper.ImGui_DrawList_AddRectFilled(draw_list, lcx - 4, lcy - 1, lcx + 4, lcy + 5, lock_color, 1)
  -- Shackle
  if lock_active then
    reaper.ImGui_DrawList_AddLine(draw_list, lcx - 2, lcy - 1, lcx - 2, lcy - 4, lock_color, 1.5)
    reaper.ImGui_DrawList_AddLine(draw_list, lcx - 2, lcy - 4, lcx + 2, lcy - 4, lock_color, 1.5)
    reaper.ImGui_DrawList_AddLine(draw_list, lcx + 2, lcy - 4, lcx + 2, lcy - 1, lock_color, 1.5)
  else
    reaper.ImGui_DrawList_AddLine(draw_list, lcx - 2, lcy - 1, lcx - 2, lcy - 4, lock_color, 1.5)
    reaper.ImGui_DrawList_AddLine(draw_list, lcx - 2, lcy - 4, lcx + 2, lcy - 4, lock_color, 1.5)
    reaper.ImGui_DrawList_AddLine(draw_list, lcx + 2, lcy - 4, lcx + 2, lcy - 2, lock_color, 1.5)
  end

  if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_lock then
    state.envelope_lock = not state.envelope_lock
  end
  if mouse_in_lock then
    local lock_tip = "Lock envelopes in place"
    if settings then
      local sc = settings.current.shortcuts.envelope_lock
      if sc and sc.key ~= "" then
        lock_tip = lock_tip .. " (" .. settings.format_shortcut(sc) .. ")"
      end
    end
    drawing.tooltip(ctx, "env_lock_btn", lock_tip)
  end

  -- Envelope snap button (magnet icon, to the right of lock button)
  local snap_btn_w = 22
  local snap_gap = 3
  local snap_btn_x = lock_btn_x + lock_btn_w + snap_gap
  local snap_btn_y = btn_y
  local snap_btn_h = btn_h
  local mouse_in_snap = mouse_x >= snap_btn_x and mouse_x <= snap_btn_x + snap_btn_w
                        and mouse_y >= snap_btn_y and mouse_y <= snap_btn_y + snap_btn_h
  local snap_active = state.env_snap_enabled
  local snap_bg = snap_active and config.COLOR_BTN_ON or (mouse_in_snap and 0x505050FF or 0x303030FF)
  local snap_border = snap_active and config.COLOR_BTN_ON or 0x555555FF
  reaper.ImGui_DrawList_AddRectFilled(draw_list, snap_btn_x, snap_btn_y,
      snap_btn_x + snap_btn_w, snap_btn_y + snap_btn_h, snap_bg, 2)
  reaper.ImGui_DrawList_AddRect(draw_list, snap_btn_x, snap_btn_y,
      snap_btn_x + snap_btn_w, snap_btn_y + snap_btn_h, snap_border, 2)

  -- Draw magnet icon
  local mcx = snap_btn_x + snap_btn_w / 2
  local mcy = snap_btn_y + snap_btn_h / 2
  local mag_color = snap_active and 0x202020FF or 0xCCCCCCFF
  -- Horseshoe magnet: U-shape
  reaper.ImGui_DrawList_AddLine(draw_list, mcx - 4, mcy - 4, mcx - 4, mcy + 2, mag_color, 2)
  reaper.ImGui_DrawList_AddLine(draw_list, mcx + 4, mcy - 4, mcx + 4, mcy + 2, mag_color, 2)
  reaper.ImGui_DrawList_AddLine(draw_list, mcx - 4, mcy + 2, mcx - 1, mcy + 5, mag_color, 2)
  reaper.ImGui_DrawList_AddLine(draw_list, mcx + 4, mcy + 2, mcx + 1, mcy + 5, mag_color, 2)
  reaper.ImGui_DrawList_AddLine(draw_list, mcx - 1, mcy + 5, mcx + 1, mcy + 5, mag_color, 2)

  if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_snap then
    state.env_snap_enabled = not state.env_snap_enabled
  end
  if mouse_in_snap then
    local snap_tip = "Snap to grid"
    if settings then
      local sc = settings.current.shortcuts.toggle_snap
      if sc and sc.key ~= "" then
        snap_tip = snap_tip .. " (" .. settings.format_shortcut(sc) .. ")"
      end
    end
    drawing.tooltip(ctx, "env_snap_btn", snap_tip)
  end

  -- Ghost markers toggle button (bracket icon, to the right of snap button)
  local ghost_btn_w = 22
  local ghost_gap = 3
  local ghost_btn_x = snap_btn_x + snap_btn_w + ghost_gap
  local ghost_btn_y = btn_y
  local ghost_btn_h = btn_h
  local mouse_in_ghost = mouse_x >= ghost_btn_x and mouse_x <= ghost_btn_x + ghost_btn_w
                        and mouse_y >= ghost_btn_y and mouse_y <= ghost_btn_y + ghost_btn_h
  local ghost_active = state.show_ghost_markers
  local ghost_bg = ghost_active and config.COLOR_BTN_ON or (mouse_in_ghost and 0x505050FF or 0x303030FF)
  local ghost_border = ghost_active and config.COLOR_BTN_ON or 0x555555FF
  reaper.ImGui_DrawList_AddRectFilled(draw_list, ghost_btn_x, ghost_btn_y,
      ghost_btn_x + ghost_btn_w, ghost_btn_y + ghost_btn_h, ghost_bg, 2)
  reaper.ImGui_DrawList_AddRect(draw_list, ghost_btn_x, ghost_btn_y,
      ghost_btn_x + ghost_btn_w, ghost_btn_y + ghost_btn_h, ghost_border, 2)

  -- Draw region icon (two overlapping rounded rectangles)
  local gcx = ghost_btn_x + ghost_btn_w / 2
  local gcy = ghost_btn_y + ghost_btn_h / 2
  local icon_color = ghost_active and 0x202020FF or 0xCCCCCCFF
  local icon_dim = ghost_active and 0x20202088 or 0xCCCCCC66
  -- Back region (dimmer, offset right+down)
  reaper.ImGui_DrawList_AddRect(draw_list, gcx - 1, gcy - 3, gcx + 6, gcy + 4, icon_dim, 1, 0, 1)
  -- Front region (brighter, offset left+up)
  reaper.ImGui_DrawList_AddRectFilled(draw_list, gcx - 6, gcy - 5, gcx + 1, gcy + 2, icon_dim, 1)
  reaper.ImGui_DrawList_AddRect(draw_list, gcx - 6, gcy - 5, gcx + 1, gcy + 2, icon_color, 1, 0, 1.5)

  if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_ghost then
    state.show_ghost_markers = not state.show_ghost_markers
  end
  if mouse_in_ghost then
    local ghost_tip = "Show other items' regions"
    if settings then
      local sc = settings.current.shortcuts.toggle_ghost_markers
      if sc and sc.key ~= "" then
        ghost_tip = ghost_tip .. " (" .. settings.format_shortcut(sc) .. ")"
      end
    end
    drawing.tooltip(ctx, "ghost_markers_btn", ghost_tip)
  end

  -- Shaped waveform toggle button (waveform icon, to the right of ghost button)
  local shape_btn_w = 22
  local shape_gap = 3
  local shape_btn_x = ghost_btn_x + ghost_btn_w + shape_gap
  local shape_btn_y = btn_y
  local shape_btn_h = btn_h
  local mouse_in_shape = mouse_x >= shape_btn_x and mouse_x <= shape_btn_x + shape_btn_w
                        and mouse_y >= shape_btn_y and mouse_y <= shape_btn_y + shape_btn_h
  local shape_active = settings and settings.current.layout.shaped_waveform
  local shape_bg = shape_active and config.COLOR_BTN_ON or (mouse_in_shape and 0x505050FF or 0x303030FF)
  local shape_border = shape_active and config.COLOR_BTN_ON or 0x555555FF
  reaper.ImGui_DrawList_AddRectFilled(draw_list, shape_btn_x, shape_btn_y,
      shape_btn_x + shape_btn_w, shape_btn_y + shape_btn_h, shape_bg, 2)
  reaper.ImGui_DrawList_AddRect(draw_list, shape_btn_x, shape_btn_y,
      shape_btn_x + shape_btn_w, shape_btn_y + shape_btn_h, shape_border, 2)

  -- Draw waveform icon (sine-like curve)
  local scx = shape_btn_x + shape_btn_w / 2
  local scy = shape_btn_y + shape_btn_h / 2
  local wave_color = shape_active and 0x202020FF or 0xCCCCCCFF
  local ww = 7  -- half-width
  local wh = 4  -- amplitude
  reaper.ImGui_DrawList_AddLine(draw_list, scx - ww, scy, scx - ww * 0.5, scy - wh, wave_color, 1.5)
  reaper.ImGui_DrawList_AddLine(draw_list, scx - ww * 0.5, scy - wh, scx, scy, wave_color, 1.5)
  reaper.ImGui_DrawList_AddLine(draw_list, scx, scy, scx + ww * 0.5, scy + wh, wave_color, 1.5)
  reaper.ImGui_DrawList_AddLine(draw_list, scx + ww * 0.5, scy + wh, scx + ww, scy, wave_color, 1.5)

  if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_shape then
    if settings then
      settings.current.layout.shaped_waveform = not settings.current.layout.shaped_waveform
      settings.save()
    end
  end
  if mouse_in_shape then
    drawing.tooltip(ctx, "shaped_waveform_btn", "Shaped waveform: fades, volume and pan envelopes")
  end

end

-- Draw envelope dropdown menu (called AFTER overlay so it renders on top)
function drawing.draw_envelope_dropdown(draw_list, ctx, x, y, height,
                                         mouse_x, mouse_y, config, state)
  if not state.envelope_dropdown_open then return end

  local btn_w = 100
  local btn_x = x + 4
  local btn_y = y + 2

  local items = { "Volume", "Pitch", "Pan", "Hide" }
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

    local text_color
    if item_name == "Hide" then
      text_color = (not state.envelopes_visible) and 0x4A90D9FF or 0x999999FF
    else
      text_color = (item_name == state.envelope_type and state.envelopes_visible) and 0x4A90D9FF or 0xCCCCCCFF
    end
    reaper.ImGui_DrawList_AddText(draw_list, menu_x + 4, item_y + 2, text_color, item_name)

    if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_item then
      if item_name == "Hide" then
        state.envelopes_visible = false
      else
        if state.envelope_type ~= item_name then
          state.pitch_view_offset = 0  -- reset scroll when switching envelope type
        end
        state.envelope_type = item_name
        state.envelopes_visible = true
      end
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
                                        snap_time_fn, env_colors, anchor_start,
                                        pitch_view_min, pitch_view_max)
  local DL_AddLine = reaper.ImGui_DrawList_AddLine
  local DL_PathLineTo = reaper.ImGui_DrawList_PathLineTo
  local DL_PathStroke = reaper.ImGui_DrawList_PathStroke
  local DL_AddCircleFilled = reaper.ImGui_DrawList_AddCircleFilled
  local DL_AddCircle = reaper.ImGui_DrawList_AddCircle
  local DL_AddRectFilled = reaper.ImGui_DrawList_AddRectFilled
  local DL_AddText = reaper.ImGui_DrawList_AddText
  local has_path = DL_PathLineTo ~= nil

  -- Anchor boundaries for implicit envelope endpoints (default: 0 and source_length)
  local anchor_s = anchor_start or 0
  local anchor_e = source_length  -- source_length acts as anchor_end

  -- Derive type flags from env_type string
  local is_pitch = (env_type == "Pitch")
  local is_pan = (env_type == "Pan")
  local is_centered = is_pitch or is_pan

  -- Fall back to Volume colors if env_colors not provided
  env_colors = env_colors or config.ENV_COLORS.Volume

  env_min_raw = env_min_raw or 0

  -- For pitch with scrolling: use view window for coordinate mapping
  -- Nodes can exist in the full env_min_raw..env_max_raw range but the visible
  -- window is pitch_view_min..pitch_view_max (always 48 semitones wide)
  local view_min = pitch_view_min or env_min_raw
  local view_max = pitch_view_max or env_max_raw
  local env_range = view_max - view_min

  -- Coordinate mapping: raw envelope values to pixels
  -- Volume: 0 (bottom) to max_raw (top)
  -- Pitch: view_min (bottom) to view_max (top), scrollable
  local function value_to_y(raw)
    return wave_y + waveform_height * (1 - (raw - view_min) / env_range)
  end

  local function y_to_value(py)
    local raw = view_min + env_range * (1 - (py - wave_y) / waveform_height)
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
    if math.abs(p.time - anchor_s) < 0.001 then has_start = true end
    if math.abs(p.time - anchor_e) < 0.001 then has_end = true end
  end

  if not has_start then
    -- Interpolate anchor value: if anchor_s falls between existing points, use interpolated value
    local start_val = default_raw
    if #pts > 0 then
      if anchor_s <= pts[1].time then
        start_val = pts[1].value
      elseif anchor_s >= pts[#pts].time then
        start_val = pts[#pts].value
      else
        -- Find segment containing anchor_s and interpolate
        for i = 1, #pts - 1 do
          if anchor_s >= pts[i].time and anchor_s <= pts[i + 1].time then
            local seg_len = pts[i + 1].time - pts[i].time
            if seg_len < 0.0001 then
              start_val = pts[i + 1].value
            else
              local frac = (anchor_s - pts[i].time) / seg_len
              local curved_frac = apply_shape(frac, pts[i].shape, pts[i].tension)
              start_val = pts[i].value + curved_frac * (pts[i + 1].value - pts[i].value)
            end
            break
          end
        end
      end
    end
    table.insert(pts, 1, { time = anchor_s, value = start_val, implicit = true, idx = -1, shape = 0, tension = 0 })
  end
  if not has_end then
    local end_val = (#pts > 0) and pts[#pts].value or default_raw
    pts[#pts + 1] = { time = anchor_e, value = end_val, implicit = true, idx = -1, shape = 0, tension = 0 }
  end

  -- Sort by time, using REAPER index as tiebreaker for same-time nodes (stable order)
  table.sort(pts, function(a, b)
    if a.time ~= b.time then return a.time < b.time end
    return a.idx < b.idx
  end)

  local n_pts = #pts

  -- Helper: interpolate raw value at a given time (respects shape/tension)
  local function interp_value(t)
    if n_pts == 0 then return default_raw end
    if t <= pts[1].time then return pts[1].value end
    if t >= pts[n_pts].time then return pts[n_pts].value end
    for i = 1, n_pts - 1 do
      if t >= pts[i].time and t <= pts[i + 1].time then
        local seg_len = pts[i + 1].time - pts[i].time
        if seg_len < 0.0001 then return pts[i + 1].value end
        local frac = (t - pts[i].time) / seg_len
        local curved_frac = apply_shape(frac, pts[i].shape, pts[i].tension)
        return pts[i].value + curved_frac * (pts[i + 1].value - pts[i].value)
      end
    end
    return default_raw
  end

  -- Clip all envelope drawing to the waveform area (including gutter)
  reaper.ImGui_DrawList_PushClipRect(draw_list, wave_x - config.PITCH_LABEL_WIDTH, wave_y, wave_x + waveform_width, wave_y + waveform_height, true)

  -- 0. Draw grid lines + left label column (all envelope types)
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

    for st = math.ceil(view_min), math.floor(view_max) do
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
  else
    -- Volume: dB labels
    local gutter_w = config.PITCH_LABEL_WIDTH
    local gutter_x = wave_x - gutter_w

    DL_AddRectFilled(draw_list, gutter_x, wave_y, wave_x, wave_y + waveform_height, config.COLOR_WAVEFORM_BG)
    DL_AddLine(draw_list, wave_x, wave_y, wave_x, wave_y + waveform_height, config.COLOR_ENV_GRID, 1)

    local db_marks = { {-1e9, "-inf"}, {-60, "-60"}, {-48, "-48"}, {-36, "-36"}, {-24, "-24"}, {-18, "-18"}, {-12, "-12"}, {-6, "-6"}, {0, "0 dB"}, {6, "+6"} }
    if waveform_height < 120 then
      db_marks = { {-1e9, "-inf"}, {-48, "-48"}, {-24, "-24"}, {-12, "-12"}, {0, "0 dB"}, {6, "+6"} }
    end

    -- Volume-specific dimmer grid colors (shared constants are too bright for Volume)
    local vol_grid = 0xFFFFFF08
    local vol_grid_octave = 0xFFFFFF12
    local vol_grid_center = 0xFFFFFF28

    for _, mark in ipairs(db_marks) do
      local db_val, label = mark[1], mark[2]
      local raw
      if db_val < -900 then
        raw = 0
      else
        local linear = 10 ^ (db_val / 20)
        raw = reaper.ScaleToEnvelopeMode(env_scaling, linear)
      end
      local ly = value_to_y(raw)
      if ly >= wave_y and ly <= wave_y + waveform_height then
        local color
        if db_val == 0 then
          color = vol_grid_center
        elseif db_val == -12 or db_val == -24 or db_val == 6 then
          color = vol_grid_octave
        else
          color = vol_grid
        end
        DL_AddLine(draw_list, wave_x, ly, wave_x + waveform_width, ly, color, 1)
        local tw = reaper.ImGui_CalcTextSize(ctx, label)
        local label_color = (db_val == 0) and vol_grid_center or 0xFFFFFF44
        -- Clamp label Y to stay within waveform bounds (text is ~12px tall)
        local text_y = ly - 6
        if text_y < wave_y then text_y = wave_y end
        if text_y + 12 > wave_y + waveform_height then text_y = wave_y + waveform_height - 12 end
        DL_AddText(draw_list, gutter_x + gutter_w - tw - 3, text_y, label_color, label)
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
    -- Solid line via PathLineTo, segment-based with pixel-stepping for curves
    local line_step = math.max(1, math.floor(waveform_width / 400))
    local view_end_t = view_start + view_length

    -- Emit the starting value at the left edge
    DL_PathLineTo(draw_list, wave_x, value_to_y(interp_value(view_start)))

    -- Walk through segments, emitting exact node positions and pixel-stepping between them
    for i = 1, n_pts do
      local pt = pts[i]
      if pt.time > view_end_t then break end

      -- Emit this node's exact position (creates vertical lines for same-time nodes)
      if pt.time >= view_start then
        local npx = (pt.time - view_start) / view_length * waveform_width
        DL_PathLineTo(draw_list, wave_x + npx, value_to_y(pt.value))
      end

      -- Pixel-step through the segment to the next node (for curved shapes)
      if i < n_pts then
        local seg_len = pts[i + 1].time - pt.time
        if seg_len >= 0.0001 and (pt.shape ~= 0 or pt.tension ~= 0) then
          local t_start = math.max(pt.time, view_start)
          local t_end = math.min(pts[i + 1].time, view_end_t)
          local px_start = math.max(0, (t_start - view_start) / view_length * waveform_width)
          local px_end = math.min(waveform_width, (t_end - view_start) / view_length * waveform_width)
          for px = px_start + line_step, px_end - 1, line_step do
            local t = view_start + (px / waveform_width) * view_length
            DL_PathLineTo(draw_list, wave_x + px, value_to_y(interp_value(t)))
          end
        end
      end
    end

    -- Final point at right edge
    DL_PathLineTo(draw_list, wave_x + waveform_width, value_to_y(interp_value(view_end_t)))
    DL_PathStroke(draw_list, env_colors.line, 0, config.ENV_LINE_THICKNESS)
  end

  -- 3. Segment hover detection: find closest line segment to mouse
  local mouse_in_waveform = mouse_x >= wave_x and mouse_x <= wave_x + waveform_width
                            and mouse_y >= wave_y and mouse_y <= wave_y + waveform_height

  -- During active tension/segment drag, preserve the hovered segment for highlight
  local drag_active = state.env_tension_dragging or state.env_segment_dragging
  if not drag_active then
    state.envelope_hovered_segment = -1
  end
  state.env_node_hovered_idx = -1
  state.env_node_hovered_is_selected = false

  if mouse_in_waveform and not state.dragging_env_node and not drag_active then
    -- Check if mouse is near an existing node first
    local closest_node_dist = config.ENV_NODE_HIT_RADIUS + 1
    local best_pts_i = -1
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
          best_pts_i = i
        end
      end
    end

    -- Check if hovered node is in the selection
    if state.env_node_hovered_idx >= 0 and best_pts_i > 0 and #state.env_selected_nodes > 0 then
      for _, sel in ipairs(state.env_selected_nodes) do
        if math.abs(pts[best_pts_i].time - sel.src_time) < 0.0001
            and math.abs(pts[best_pts_i].value - sel.value) < 0.0001 then
          state.env_node_hovered_is_selected = true
          break
        end
      end
    end

    -- If not hovering a node, find segment by time containment + neighbor check at boundaries
    if state.env_node_hovered_idx < 0 then
      local mouse_t = view_start + ((mouse_x - wave_x) / waveform_width) * view_length
      local threshold = no_user_nodes and 24 or 22

      -- Helper: distance from mouse to rendered curve (respects shape/tension)
      -- Samples the actual curve at the mouse X position for accurate hit detection
      local function seg_dist(i)
        local x1 = time_to_px(pts[i].time)
        local x2 = time_to_px(pts[i + 1].time)
        local seg_px_len = x2 - x1
        if seg_px_len < 1 then
          -- Zero-width segment: use distance to midpoint
          local my = value_to_y((pts[i].value + pts[i + 1].value) / 2)
          return math.sqrt((mouse_x - x1) ^ 2 + (mouse_y - my) ^ 2)
        end
        -- Clamp mouse X into segment range, compute the curve Y at that position
        local clamped_x = math.max(x1, math.min(x2, mouse_x))
        local frac = (clamped_x - x1) / seg_px_len
        local curved_frac = apply_shape(frac, pts[i].shape, pts[i].tension)
        local curve_val = pts[i].value + curved_frac * (pts[i + 1].value - pts[i].value)
        local curve_y = value_to_y(curve_val)
        -- Distance: vertical from mouse to curve at this X, plus horizontal if outside
        local dx = 0
        if mouse_x < x1 then dx = x1 - mouse_x
        elseif mouse_x > x2 then dx = mouse_x - x2 end
        local dy = mouse_y - curve_y
        return math.sqrt(dx * dx + dy * dy)
      end

      -- Step 1: find segment containing mouse_t by strict time containment
      local primary_i = -1
      for i = 1, n_pts - 1 do
        if pts[i + 1].time - pts[i].time >= 0.0001
            and mouse_t >= pts[i].time and mouse_t <= pts[i + 1].time then
          primary_i = i
          break
        end
      end

      -- Step 2: compare with neighbors near node boundaries (handles same-time transitions)
      if primary_i > 0 then
        local best_i = primary_i
        local best_dist = seg_dist(primary_i)
        local boundary_px = 20

        -- Near left boundary? Check previous non-zero-length segment
        if math.abs(mouse_x - time_to_px(pts[primary_i].time)) < boundary_px then
          local prev = primary_i - 1
          while prev >= 1 and pts[prev + 1].time - pts[prev].time < 0.0001 do
            prev = prev - 1
          end
          if prev >= 1 then
            local d = seg_dist(prev)
            if d < best_dist then best_i = prev; best_dist = d end
          end
        end

        -- Near right boundary? Check next non-zero-length segment
        if math.abs(mouse_x - time_to_px(pts[primary_i + 1].time)) < boundary_px then
          local nxt = primary_i + 1
          while nxt < n_pts and pts[nxt + 1].time - pts[nxt].time < 0.0001 do
            nxt = nxt + 1
          end
          if nxt < n_pts then
            local d = seg_dist(nxt)
            if d < best_dist then best_i = nxt; best_dist = d end
          end
        end

        if best_dist <= threshold then
          state.envelope_hovered_segment = best_i - 1
          local seg_t = math.max(pts[best_i].time, math.min(pts[best_i + 1].time, mouse_t))
          local snapped_t = (snap_time_fn and state.env_snap_enabled) and snap_time_fn(seg_t) or seg_t
          snapped_t = math.max(pts[best_i].time, math.min(pts[best_i + 1].time, snapped_t))
          state.envelope_hover_x = time_to_px(snapped_t)
          local hover_raw = interp_value(snapped_t)
          if is_pitch and state.env_snap_enabled then hover_raw = math.floor(hover_raw + 0.5) end
          state.envelope_hover_y = value_to_y(hover_raw)
          state.envelope_hover_value = hover_raw
          state.envelope_hover_time = snapped_t
        end
      end
    end
  end

  -- 3b. Highlight hovered segment (during alt-hover for tension editing or shift-hover for segment drag)
  local alt_for_highlight = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Alt())
  local shift_for_highlight = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift())
  local show_seg_highlight = not state.dragging_env_node and not state.env_freehand_drawing
  if state.envelope_hovered_segment >= 0 and has_path and show_seg_highlight then
    local seg_idx = state.envelope_hovered_segment + 1  -- convert 0-based to 1-based pts index
    if seg_idx >= 1 and seg_idx < n_pts then
      local view_end_t = view_start + view_length
      local t_start = math.max(pts[seg_idx].time, view_start)
      local t_end = math.min(pts[seg_idx + 1].time, view_end_t)
      if t_end > t_start then
        local px_start = math.max(0, (t_start - view_start) / view_length * waveform_width)
        local px_end = math.min(waveform_width, (t_end - view_start) / view_length * waveform_width)
        -- Start point: use exact node value to avoid interp_value mismatch at same-time nodes
        local start_y = (t_start == pts[seg_idx].time)
            and value_to_y(pts[seg_idx].value)
            or value_to_y(interp_value(t_start))
        DL_PathLineTo(draw_list, wave_x + px_start, start_y)
        -- Pixel-step only for curved segments
        if pts[seg_idx].shape ~= 0 or pts[seg_idx].tension ~= 0 then
          local line_step = math.max(1, math.floor(waveform_width / 400))
          for px = px_start + line_step, px_end - 1, line_step do
            local t = view_start + (px / waveform_width) * view_length
            DL_PathLineTo(draw_list, wave_x + px, value_to_y(interp_value(t)))
          end
        end
        -- End point: use exact node value
        local end_y = (t_end == pts[seg_idx + 1].time)
            and value_to_y(pts[seg_idx + 1].value)
            or value_to_y(interp_value(t_end))
        DL_PathLineTo(draw_list, wave_x + px_end, end_y)
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
        -- Check if this node is in the selection
        local is_selected = false
        for _, sel in ipairs(state.env_selected_nodes) do
          if math.abs(pts[i].time - sel.src_time) < 0.0001
              and math.abs(pts[i].value - sel.value) < 0.0001 then
            is_selected = true
            break
          end
        end
        local fill
        if is_hovered then fill = env_colors.node_hover
        elseif is_selected then fill = config.COLOR_ENV_NODE_SELECTED
        else fill = config.COLOR_ENV_NODE end
        DL_AddCircleFilled(draw_list, node_px, node_py, config.ENV_NODE_RADIUS, fill, 16)
        DL_AddCircle(draw_list, node_px, node_py, config.ENV_NODE_RADIUS, env_colors.node_border, 16, 1.5)
      end
    end
  end

  -- 4b. Selection rectangle during right-click drag
  if state.env_rect_selecting and state.env_rect_sel_activated then
    local rx1 = math.max(wave_x, math.min(state.env_rect_sel_start_x, mouse_x))
    local ry1 = math.max(wave_y, math.min(state.env_rect_sel_start_y, mouse_y))
    local rx2 = math.min(wave_x + waveform_width, math.max(state.env_rect_sel_start_x, mouse_x))
    local ry2 = math.min(wave_y + waveform_height, math.max(state.env_rect_sel_start_y, mouse_y))
    DL_AddRectFilled(draw_list, rx1, ry1, rx2, ry2, config.COLOR_ENV_SEL_RECT_FILL)
    reaper.ImGui_DrawList_AddRect(draw_list, rx1, ry1, rx2, ry2, config.COLOR_ENV_SEL_RECT_BORDER, 0, 0, 1)
  end

  -- 5. Preview circle + tooltip on segment hover (only when shift held = create-node mode)
  local alt_held = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Alt())
  local shift_held = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift())
  if state.envelope_hovered_segment >= 0 and state.env_node_hovered_idx < 0
      and not state.dragging_env_node and not state.env_tension_dragging
      and not state.env_segment_dragging and shift_held and not alt_held then
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

  reaper.ImGui_DrawList_PopClipRect(draw_list)
end

-- Expose internals for unit testing
drawing._test = {
  B = B,
  cbez_y = cbez_y,
  get_fade_bez = get_fade_bez,
  eval_fade = eval_fade,
  FADE_LUT_SIZE = FADE_LUT_SIZE,
  get_fade_lut = get_fade_lut,
  fade_lut_lookup = fade_lut_lookup,
  shape_icon_fns = shape_icon_fns,
  compute_grid_params = compute_grid_params,
  fade_curves = fade_curves,
}

-- Draw warp bar background strip
function drawing.draw_warp_bar(draw_list, x, y, width, height, config)
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + width, y + height, config.COLOR_WARP_BAR_BG)
  reaper.ImGui_DrawList_AddLine(draw_list, x, y + height, x + width, y + height, config.COLOR_WARP_BAR_BORDER, 1)
end

-- Draw vertical loop boundary lines on the waveform
function drawing.draw_loop_boundaries(draw_list, wave_x, wave_y, waveform_width, waveform_height,
                                       source_length, view_start, view_length, time_to_px, config)
  if source_length <= 0 then return end
  local view_end = view_start + view_length
  local first_boundary = math.ceil(view_start / source_length) * source_length

  for boundary = first_boundary, view_end, source_length do
    if boundary > view_start and boundary < view_end then
      local px = time_to_px(boundary)
      if px >= wave_x and px <= wave_x + waveform_width then
        reaper.ImGui_DrawList_AddLine(draw_list, px, wave_y, px, wave_y + waveform_height, config.COLOR_LOOP_REGION, 1)
      end
    end
  end
end

-- Draw a stretch marker ("house" shape: rectangle top + downward triangle bottom + vertical line through waveform)
-- color_override: use this color instead of normal orange (for ghost preview), or nil for normal
-- is_selected: when true, draw 1px teal outline
function drawing.draw_warp_marker(draw_list, x, bar_y, bar_h, wave_y, wave_h,
                                   is_hovered, is_dragging, is_selected, color_override, config)
  local color = color_override or ((is_dragging or is_hovered) and config.COLOR_WARP_MARKER_HOVER or config.COLOR_WARP_MARKER)
  local half_w = 5
  -- Rectangle: top portion of bar
  local rect_top = bar_y + 1
  local rect_h = math.floor(bar_h * 0.4)
  local rect_bot = rect_top + rect_h
  -- Triangle: from rectangle bottom, pointing down to near bar bottom
  local tri_bot = bar_y + bar_h - 2
  -- Fill rectangle
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x - half_w, rect_top, x + half_w, rect_bot, color)
  -- Fill triangle
  reaper.ImGui_DrawList_AddTriangleFilled(draw_list, x - half_w, rect_bot, x + half_w, rect_bot, x, tri_bot, color)
  -- Selected outline (1px teal stroke around both rect and triangle)
  if is_selected then
    local sel_color = config.COLOR_WARP_MARKER_SELECTED
    reaper.ImGui_DrawList_AddRect(draw_list, x - half_w, rect_top, x + half_w, rect_bot, sel_color, 0, 0, 1)
    reaper.ImGui_DrawList_AddTriangle(draw_list, x - half_w, rect_bot, x + half_w, rect_bot, x, tri_bot, sel_color, 1)
  end
  -- Vertical line through waveform
  local line_color = color_override
      and config.COLOR_WARP_MARKER_LINE_GHOST
      or (is_hovered and config.COLOR_WARP_MARKER_LINE_HOVER or config.COLOR_WARP_MARKER_LINE)
  reaper.ImGui_DrawList_AddLine(draw_list, x, bar_y + bar_h, x, wave_y + wave_h, line_color, 1)
end

-- Draw a transient tick. When zoomed out: small line from bottom of warp bar.
-- When zoomed in: small downward-pointing triangle from top of warp bar (Ableton style).
function drawing.draw_transient(draw_list, x, bar_y, bar_h, is_hovered, config, zoomed)
  local color = is_hovered and config.COLOR_TRANSIENT_HOVER or config.COLOR_TRANSIENT
  if zoomed then
    -- Downward-pointing triangle at bottom of warp bar
    local tri_w = 3
    local tri_h = math.min(5, bar_h - 2)
    local bottom = bar_y + bar_h
    reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
        x - tri_w, bottom - tri_h, x + tri_w, bottom - tri_h, x, bottom, color)
  else
    -- Small line from bottom
    local tick_h = math.min(4, bar_h - 4)
    local bottom = bar_y + bar_h - 1
    reaper.ImGui_DrawList_AddLine(draw_list, x, bottom - tick_h, x, bottom, color, 1)
  end
end

-- Draw rate text between adjacent stretch markers
function drawing.draw_warp_rate(draw_list, x1, x2, bar_y, rate, config)
  local gap = x2 - x1
  if gap < 40 then return end
  local text = string.format("%.2fx", rate)
  local text_w = 40  -- approximate
  local cx = (x1 + x2) / 2 - text_w / 2
  local color
  if rate > 1.005 then
    color = 0x5090E0BB   -- blue (faster)
  elseif rate < 0.995 then
    color = 0xE07050BB   -- red-orange (slower)
  else
    color = 0xAAAAAABB   -- grey (1.00x)
  end
  reaper.ImGui_DrawList_AddText(draw_list, cx, bar_y + 1, color, text)
end

-- Draw slope line between two stretch markers in the waveform area
-- Always a straight line from left handle Y to right handle Y
function drawing.draw_slope_curve(draw_list, x1, x2, wave_y, wave_h, slope, hover_state, rate)
  local gap = x2 - x1
  if gap < 8 then return end
  local DL_PathLineTo = reaper.ImGui_DrawList_PathLineTo
  local DL_PathStroke = reaper.ImGui_DrawList_PathStroke
  if not DL_PathLineTo then return end

  local alpha
  if hover_state == 2 then alpha = 0xFF
  elseif hover_state == 1 then alpha = 0xDD
  elseif math.abs(slope) < 0.001 then alpha = 0x40
  else alpha = 0x90 end

  local color = 0xE8A02000 + alpha
  local thickness = (hover_state >= 1) and 2.0 or 1.5

  local y_left, y_right = drawing.slope_handle_positions(wave_y, wave_h, slope, rate)
  DL_PathLineTo(draw_list, x1, y_left)
  DL_PathLineTo(draw_list, x2, y_right)
  DL_PathStroke(draw_list, color, 0, thickness)
end

-- Compute the Y positions of slope handle endpoints (matching the curve endpoints)
-- Uses log-based mapping: Y = center - log(local_rate) * scale
-- Returns y_left, y_right clamped to waveform bounds
function drawing.slope_handle_positions(wave_y, wave_h, slope, rate)
  local scale = wave_h * 0.2
  local center = wave_y + wave_h / 2
  rate = (rate and rate > 0) and rate or 1
  local rate_left = math.max(0.001, rate * (1 - slope))
  local rate_right = math.max(0.001, rate * (1 + slope))
  local y_left = center - math.log(rate_left) * scale
  local y_right = center - math.log(rate_right) * scale
  -- Clamp to waveform bounds (same as REAPER item edges)
  y_left = math.max(wave_y, math.min(wave_y + wave_h, y_left))
  y_right = math.max(wave_y, math.min(wave_y + wave_h, y_right))
  return y_left, y_right
end

-- Get color for slope handle based on local playback rate at that endpoint
-- Red = stretched (rate < 1, audio slowed down), Blue = compressed (rate > 1, audio sped up), Grey = neutral
function drawing.slope_handle_color(local_rate, hover_state)
  local alpha
  if hover_state == 2 then alpha = 0xFF
  elseif hover_state == 1 then alpha = 0xDD
  else alpha = 0xBB end

  if local_rate > 1.005 then
    return 0x3070D000 + alpha   -- blue (compressed/faster)
  elseif local_rate < 0.995 then
    return 0xD0503000 + alpha   -- red-orange (stretched/slower)
  else
    return 0x90909000 + alpha   -- grey (neutral, rate = 1.00x)
  end
end

-- Draw slope handle triangle on a warp marker vertical line
-- dir: 1 = pointing right (left endpoint), -1 = pointing left (right endpoint)
-- The flat edge sits flush against the marker's vertical line,
-- the tip points inward toward the slope curve connecting two markers
function drawing.draw_slope_handle(draw_list, x, y, dir, local_rate, hover_state)
  local w = 9    -- width (how far the tip extends from the marker line)
  local hh = 6   -- half-height

  local color = drawing.slope_handle_color(local_rate, hover_state)

  -- Flat edge on the marker line, tip pointing inward toward the slope
  local tip_x = x + dir * w
  reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
    x, y - hh, x, y + hh, tip_x, y, color)
  if hover_state >= 1 then
    reaper.ImGui_DrawList_AddTriangle(draw_list,
      x, y - hh, x, y + hh, tip_x, y, 0xFFFFFF60, 1.0)
  end
end

return drawing
