-- NVSD_ItemView - Drawing Module
-- Waveform, ruler, overlays, markers, info bar

local drawing = {}

-- Power curve LUT: maps [0..1024] → value^0.7 for fast waveform scaling
local power_lut = {}
for i = 0, 1024 do
  power_lut[i] = (i / 1024) ^ 0.7
end

-- Fast power curve using LUT: returns sign(value) * |value|^0.7
local function power_curve(value)
  if value >= 0 then
    local idx = value * 1024
    if idx > 1024 then idx = 1024 end
    return power_lut[math.floor(idx)]
  else
    local idx = -value * 1024
    if idx > 1024 then idx = 1024 end
    return -power_lut[math.floor(idx)]
  end
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
function drawing.draw_ruler_and_grid(draw_list, x, ruler_y, wave_y, width, ruler_height, wave_height,
                                      view_start, view_length, item_position, start_offset, playrate, config, utils)
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x, ruler_y, x + width, ruler_y + ruler_height, config.COLOR_RULER_BG)

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

  local bar = first_bar
  local max_iterations = 1000
  local iterations = 0

  -- Calculate bar skip interval based on density
  -- Aim for at least 40px between bar labels
  local min_bar_spacing = 40
  local avg_bar_duration = 60 / bpm * beats_per_bar  -- seconds per bar
  local px_per_bar = (avg_bar_duration / view_length) * width
  local bar_skip = math.max(1, math.ceil(min_bar_spacing / px_per_bar))

  -- Align to nice intervals (1, 2, 4, 8, 16, etc.)
  if bar_skip > 1 then
    local power = math.ceil(math.log(bar_skip) / math.log(2))
    bar_skip = 2 ^ power
  end

  while iterations < max_iterations do
    iterations = iterations + 1
    local bar_project_time = reaper.TimeMap2_beatsToTime(0, 0, bar)
    if bar_project_time > project_end then break end

    local bar_source_time = utils.project_to_source_time(bar_project_time, item_position, start_offset, playrate)

    if bar_source_time >= view_start and bar_source_time <= view_end then
      local bar_px = time_to_px(bar_source_time)
      -- Only draw label for every Nth bar when zoomed out
      local bar_num = bar + 1
      if bar_num % bar_skip == 1 or bar_skip == 1 then
        reaper.ImGui_DrawList_AddLine(draw_list, bar_px, ruler_y, bar_px, ruler_y + ruler_height, config.COLOR_RULER_TICK, 1)
        reaper.ImGui_DrawList_AddText(draw_list, bar_px + 3, ruler_y + 3, config.COLOR_RULER_TEXT, tostring(bar_num))
      else
        -- Draw shorter tick for skipped bars
        reaper.ImGui_DrawList_AddLine(draw_list, bar_px, ruler_y + ruler_height - 4, bar_px, ruler_y + ruler_height, config.COLOR_RULER_TICK, 1)
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
function drawing.draw_info_bar(draw_list, ctx, x, y, width, height, source, file_path, mouse_x, mouse_y, item, config, utils)
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

  local file_name = utils.get_file_name(file_path)
  local sample_rate = source and reaper.GetMediaSourceSampleRate(source) or 0
  local num_channels = source and reaper.GetMediaSourceNumChannels(source) or 0
  local bit_depth = utils.get_wav_bit_depth(file_path)

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
    else
      table.insert(meta_parts, string.format("%d Ch", num_channels))
    end
  end

  local meta_text = table.concat(meta_parts, " · ")

  local file_name_width
  if reaper.ImGui_CalcTextSize then
    file_name_width = reaper.ImGui_CalcTextSize(ctx, file_name)
  else
    file_name_width = #file_name * 6
  end
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

-- Draw waveform with looping support
function drawing.draw_waveform(draw_list, x, y, width, height, peaks, start_offset, source_item_length, source_length, pan_offset_time, zoom_lvl, ruler_y, visual_gain, is_reversed, num_channels, config, lod)
  if not peaks or peaks.count == 0 or source_length <= 0 then return 0, 0, 0, source_length end

  pan_offset_time = pan_offset_time or 0
  zoom_lvl = zoom_lvl or 1.0
  visual_gain = visual_gain or 1.0
  is_reversed = is_reversed or false
  num_channels = num_channels or 1

  local item_end = start_offset + source_item_length

  -- View bounds: always within original source (0 to source_length)
  local view_length = source_length / zoom_lvl
  local view_center = source_length / 2 + pan_offset_time
  local view_start = view_center - view_length / 2
  local view_end = view_start + view_length

  -- Clamp view to source bounds
  if view_start < 0 then
    view_start = 0
    view_end = view_length
  end
  if view_end > source_length then
    view_end = source_length
    view_start = source_length - view_length
  end
  if view_start < 0 then view_start = 0 end  -- In case view_length > source_length

  reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + width, y + height, config.COLOR_WAVEFORM_BG)

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

  local num_samples = math.floor(width)
  local time_per_pixel = view_length / num_samples

  -- Select appropriate LOD level based on how many peaks would cover each pixel
  local peaks_per_pixel = (peaks.count / source_length) * time_per_pixel
  local active_peaks, lod_scale = peaks, 1
  if lod and peaks_per_pixel > 2 then
    -- Use coarser LOD when zoomed out (many peaks per pixel)
    local level = 1
    if peaks_per_pixel > 128 and lod[5] then level = 5
    elseif peaks_per_pixel > 32 and lod[4] then level = 4
    elseif peaks_per_pixel > 8 and lod[3] then level = 3
    elseif peaks_per_pixel > 2 and lod[2] then level = 2
    end
    if lod[level] then
      active_peaks = lod[level]
      lod_scale = 4 ^ (level - 1)
    end
  end

  local num_peaks = active_peaks.count
  local active_ch = active_peaks.channels
  local active_mins = active_peaks.mins
  local active_maxs = active_peaks.maxs
  local peaks_per_second = num_peaks / source_length

  -- Cache draw functions locally (reduces Lua→C lookup overhead per call)
  local DL_QuadFilled = reaper.ImGui_DrawList_AddQuadFilled
  local DL_AddLine = reaper.ImGui_DrawList_AddLine
  local DL_PathLineTo = reaper.ImGui_DrawList_PathLineTo
  local DL_PathStroke = reaper.ImGui_DrawList_PathStroke
  local has_path = DL_PathLineTo ~= nil
  local math_floor = math.floor

  -- Derive waveform colors from config (with alpha for fill)
  local function color_with_alpha(color, alpha)
    return ((color >> 8) << 8) | alpha
  end
  local function darken_color(color, factor)
    local r = ((color >> 24) & 0xFF) * factor
    local g = ((color >> 16) & 0xFF) * factor
    local b = ((color >> 8) & 0xFF) * factor
    local a = color & 0xFF
    return (math_floor(r) << 24) | (math_floor(g) << 16) | (math_floor(b) << 8) | a
  end

  local OUTLINE_ACTIVE = config.COLOR_WAVEFORM
  local FILL_ACTIVE = color_with_alpha(darken_color(config.COLOR_WAVEFORM, 0.85), 0xCC)
  local OUTLINE_INACTIVE = config.COLOR_WAVEFORM_INACTIVE
  local FILL_INACTIVE = color_with_alpha(darken_color(config.COLOR_WAVEFORM_INACTIVE, 0.7), 0xCC)
  local OUTLINE_LOOPED = darken_color(config.COLOR_WAVEFORM, 0.75)
  local FILL_LOOPED = color_with_alpha(darken_color(config.COLOR_WAVEFORM, 0.6), 0xCC)

  -- Phase 1: Pre-compute all column data (separates math from drawing)
  local col_tops = {}   -- col_tops[ch][i] = top_y for pixel i
  local col_bots = {}   -- col_bots[ch][i] = bot_y for pixel i
  local col_colors = {} -- col_colors[i] = 1(active) / 2(inactive) / 3(looped)
  for ch = 1, num_channels do
    col_tops[ch] = {}
    col_bots[ch] = {}
  end

  local peak_mins = {}
  local peak_maxs = {}
  for ch = 1, num_channels do
    peak_mins[ch] = 0
    peak_maxs[ch] = 0
  end

  local last_idx_start, last_idx_end = -1, -1

  for i = 0, num_samples - 1 do
    local t = view_start + i * time_per_pixel
    local t_next = t + time_per_pixel

    -- Inline peak index calculation
    local wrapped_start = t % source_length
    if wrapped_start < 0 then wrapped_start = wrapped_start + source_length end
    if is_reversed then wrapped_start = source_length - wrapped_start end
    local idx_start = math_floor(wrapped_start * peaks_per_second) + 1
    if idx_start < 1 then idx_start = 1 elseif idx_start > num_peaks then idx_start = num_peaks end

    local wrapped_end = t_next % source_length
    if wrapped_end < 0 then wrapped_end = wrapped_end + source_length end
    if is_reversed then wrapped_end = source_length - wrapped_end end
    local idx_end = math_floor(wrapped_end * peaks_per_second) + 1
    if idx_end < 1 then idx_end = 1 elseif idx_end > num_peaks then idx_end = num_peaks end

    if idx_end < idx_start then idx_start, idx_end = idx_end, idx_start end

    -- Only recalculate if range changed
    if idx_start ~= last_idx_start or idx_end ~= last_idx_end then
      last_idx_start, last_idx_end = idx_start, idx_end
      for ch = 1, num_channels do
        local ch_min, ch_max = 1, -1
        for idx = idx_start, idx_end do
          local flat_idx = (idx - 1) * active_ch + ch
          local v_min = active_mins[flat_idx]
          local v_max = active_maxs[flat_idx]
          if v_min and v_min < ch_min then ch_min = v_min end
          if v_max and v_max > ch_max then ch_max = v_max end
        end
        peak_mins[ch] = ch_min
        peak_maxs[ch] = ch_max
      end
    end

    -- Color type
    local in_active = t >= start_offset and t <= item_end
    if in_active then
      col_colors[i] = (t < 0 or t >= source_length) and 3 or 1
    else
      col_colors[i] = 2
    end

    -- Y positions per channel
    for ch = 1, num_channels do
      local center_y = y + (ch - 1) * channel_height + channel_height * 0.5
      local raw_max = peak_maxs[ch] * visual_gain
      local raw_min = peak_mins[ch] * visual_gain
      if raw_max > 1 then raw_max = 1 elseif raw_max < -1 then raw_max = -1 end
      if raw_min > 1 then raw_min = 1 elseif raw_min < -1 then raw_min = -1 end
      local scaled_max = power_curve(raw_max)
      local scaled_min = power_curve(raw_min)
      local top_y = center_y - (scaled_max * half_height)
      local bot_y = center_y - (scaled_min * half_height)
      if bot_y - top_y < 1 then
        top_y = center_y - 0.5
        bot_y = center_y + 0.5
      end
      col_tops[ch][i] = top_y
      col_bots[ch][i] = bot_y
    end
  end

  -- Phase 2: Build color segments (runs of same color type)
  local segments = {}
  local n_segs = 0
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

  local fill_lut = {[1] = FILL_ACTIVE, [2] = FILL_INACTIVE, [3] = FILL_LOOPED}
  local outline_lut = {[1] = OUTLINE_ACTIVE, [2] = OUTLINE_INACTIVE, [3] = OUTLINE_LOOPED}

  -- Phase 3: Render each segment with batched outlines
  for si = 1, n_segs do
    local s_start = segments[si][1]
    local s_stop = segments[si][2]
    local fill_color = fill_lut[segments[si][3]]
    local outline_color = outline_lut[segments[si][3]]

    -- First fill pixel needs predecessor (pixel before segment start)
    local fill_from = (s_start == 0) and 1 or s_start

    for ch = 1, num_channels do
      local tops = col_tops[ch]
      local bots = col_bots[ch]

      -- Fill: per-pixel quads connecting adjacent columns
      for i = fill_from, s_stop do
        local px = x + i
        DL_QuadFilled(draw_list,
          px - 1, tops[i - 1],
          px, tops[i],
          px, bots[i],
          px - 1, bots[i - 1],
          fill_color)
      end

      -- Outlines: batched via path API (reduces GPU draw commands)
      if has_path and s_stop > s_start then
        -- Top outline
        for i = s_start, s_stop do
          DL_PathLineTo(draw_list, x + i, tops[i])
        end
        DL_PathStroke(draw_list, outline_color, 0, 1)
        -- Bottom outline
        for i = s_start, s_stop do
          DL_PathLineTo(draw_list, x + i, bots[i])
        end
        DL_PathStroke(draw_list, outline_color, 0, 1)
      else
        -- Fallback: individual lines
        for i = fill_from, s_stop do
          local px = x + i
          DL_AddLine(draw_list, px - 1, tops[i - 1], px, tops[i], outline_color, 1)
          DL_AddLine(draw_list, px - 1, bots[i - 1], px, bots[i], outline_color, 1)
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

  return start_px, end_px, view_start, view_length
end

-- Draw draggable marker
function drawing.draw_marker(draw_list, x, y, height, is_start, is_hovered, is_dragging, config)
  local color = (is_hovered or is_dragging) and config.COLOR_MARKER_HOVER or config.COLOR_MARKER

  reaper.ImGui_DrawList_AddLine(draw_list, x, y, x, y + height, color, 3)

  local handle_size = 10

  if is_start then
    reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
      x, y, x + handle_size, y + handle_size / 2, x, y + handle_size, color)
    reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
      x, y + height - handle_size, x + handle_size, y + height - handle_size / 2, x, y + height, color)
  else
    reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
      x, y, x - handle_size, y + handle_size / 2, x, y + handle_size, color)
    reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
      x, y + height - handle_size, x - handle_size, y + height - handle_size / 2, x, y + height, color)
  end
end

-- Draw playhead (vertical line with triangle indicator at top)
function drawing.draw_playhead(draw_list, x, y, height, config)
  reaper.ImGui_DrawList_AddLine(draw_list, x, y, x, y + height, config.COLOR_PLAYHEAD, 2)
  local tri_size = 6
  reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
    x - tri_size, y, x + tri_size, y, x, y + tri_size, config.COLOR_PLAYHEAD)
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

return drawing
