-- NVSD_ItemView.lua
-- Ableton-style clip view for REAPER audio items
-- Requires: ReaImGui extension

-- Auto-reload: Detect file changes and restart script
local script_path = debug.getinfo(1, "S").source:match("@(.+)")

local function get_file_size(path)
  if not path then return 0 end
  local f = io.open(path, "rb")
  if f then
    local size = f:seek("end")
    f:close()
    return size
  end
  return 0
end

local initial_file_size = get_file_size(script_path)
local reload_check_counter = 0
local should_reload = false

-- Check for ReaImGui
if not reaper.ImGui_CreateContext then
  reaper.MB("This script requires the ReaImGui extension.\nInstall it via ReaPack: Extensions > ReaPack > Browse packages > ReaImGui", "Missing Dependency", 0)
  return
end

-- Configuration
local MARKER_WIDTH = 12
local WINDOW_PADDING = 8  -- Padding inside window
local WAVEFORM_MARGIN_H = 20  -- Horizontal margin for easier marker access
local WAVEFORM_MARGIN_V = 8  -- Vertical margin (smaller for docked windows)
local RULER_HEIGHT = 20  -- Height of the bar number ruler (top)
local TIME_RULER_HEIGHT = 18  -- Height of the source time ruler (bottom)
local SNAP_THRESHOLD_PX = 25  -- Pixels within which markers snap to source boundaries
local LEFT_PANEL_WIDTH = 60  -- Width of the left control panel (volume/pitch)
local LEFT_COLUMN_WIDTH = 44  -- Width of the far-left column (warp button etc)
local GAIN_SLIDER_WIDTH = 16  -- Width of the gain slider track

-- Colors (0xRRGGBBAA format)
local COLOR_WAVEFORM = 0x5A9F5AFF        -- Green waveform
local COLOR_WAVEFORM_INACTIVE = 0x3A3A3AFF  -- Gray for inactive parts
local COLOR_WAVEFORM_BG = 0x1A1A1AFF     -- Dark background
local COLOR_CENTERLINE = 0x2A2A2AFF      -- Center line
local COLOR_MARKER = 0x4A90D9FF          -- Blue markers
local COLOR_MARKER_HOVER = 0x6AB0F9FF    -- Lighter blue on hover
local COLOR_BORDER = 0x4A7A4AFF          -- Border around active region
local COLOR_RULER_BG = 0x252525FF        -- Ruler background
local COLOR_RULER_TEXT = 0xAAAAAAFF      -- Ruler text
local COLOR_GRID_BAR = 0x555555FF        -- Bar lines
local COLOR_GRID_BEAT = 0x333333FF       -- Beat lines
local COLOR_PLAYHEAD = 0x00CC00FF        -- Playhead (green, like REAPER default)

-- State
local ctx = reaper.ImGui_CreateContext("NVSD_ItemView")

local cached_peaks = nil
local cached_source = nil
local cached_item = nil
local cached_num_samples = 0
local cached_source_length = 0
local peaks_error = nil


local dragging_start = false
local dragging_end = false
local drag_start_offset = 0  -- Store original offset when drag starts
local drag_start_length = 0  -- Store original length when drag starts
local drag_start_mouse_x = 0  -- Store mouse X when drag starts
local drag_start_view_length = 0  -- Store view length for 1:1 mouse movement
local drag_start_playrate = 1  -- Store playrate when drag starts
local drag_current_start = 0  -- Current start position during drag (for stable rendering)
local drag_current_end = 0    -- Current end position during drag (for stable rendering)
local drag_start_view_start = 0  -- Store view_start when drag starts (for stable grid)

-- Panning state
local is_panning = false
local pan_start_mouse_x = 0
local pan_offset = 0  -- Current pan offset in source time units
local pan_start_offset = 0  -- Pan offset when pan started
local last_panned_item = nil  -- Reset pan when item changes

-- Zoom state
local zoom_level = 1.0  -- 1.0 = fit to view, >1 = zoomed in
local is_ruler_dragging = false
local ruler_drag_start_y = 0
local ruler_drag_start_zoom = 1.0
local last_zoomed_item = nil  -- Reset zoom when item changes

-- Sticky item state (persists after edge-drag until another item is selected)
local sticky_item = nil
local last_selected_item = nil  -- Track selection changes to clear sticky

-- Gain slider state
local is_dragging_gain = false
local gain_drag_start_y = 0
local gain_drag_start_value = 0
local gain_shift_was_held = false  -- Track shift state for smooth fine-adjust transition

-- Pitch knob state
local is_dragging_pitch = false
local pitch_drag_start_y = 0
local pitch_drag_start_value = 0
local pitch_shift_was_held = false  -- Track shift state for smooth fine-adjust transition
local PITCH_KNOB_RADIUS = 16  -- Knob radius in pixels
local PITCH_MIN = -48  -- Minimum semitones
local PITCH_MAX = 48   -- Maximum semitones

-- Semitones/cents box drag state
local is_dragging_semitones = false
local is_dragging_cents = false
local semitones_drag_start_y = 0
local cents_drag_start_y = 0
local semitones_drag_start_value = 0
local cents_drag_start_value = 0

-- Cursor lock state (for hiding and locking cursor during drag)
local drag_lock_screen_x = 0
local drag_lock_screen_y = 0
local drag_cumulative_delta_y = 0  -- Accumulated Y delta for locked cursor dragging
local drag_window_to_screen_y = 0  -- Offset to convert window Y to screen Y
local has_js_extension = reaper.JS_Mouse_SetPosition ~= nil

-- Warp mode state (true = pitch shift preserves length, false = playrate changes length)
local warp_mode = false

-- Convert semitones to playrate (for non-warp mode)
local function semitones_to_playrate(semitones)
  return 2 ^ (semitones / 12)
end

-- Convert playrate to semitones (for non-warp mode)
local function playrate_to_semitones(playrate)
  if playrate <= 0 then return 0 end
  return 12 * math.log(playrate) / math.log(2)
end

-- Set pitch on take based on warp mode
local function set_take_pitch(take, semitones)
  if not take then return end
  if warp_mode then
    reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", semitones)
  else
    -- Get current playrate and item length before changing
    local item = reaper.GetMediaItemTake_Item(take)
    local old_playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    local old_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

    -- Calculate new playrate
    local new_playrate = semitones_to_playrate(semitones)
    reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", new_playrate)

    -- Adjust item length to keep same source content playing
    -- new_length = old_length * (old_playrate / new_playrate)
    if new_playrate > 0 then
      local new_length = old_length * (old_playrate / new_playrate)
      reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_length)
    end
  end
end

-- Get peaks data from audio source for a specific time range
-- This allows fetching high-resolution peaks for just the visible portion
local function get_peaks_for_range(source, start_time, duration, num_samples)
  if not source then return nil, "no source" end

  local source_length = reaper.GetMediaSourceLength(source)
  local sample_rate = reaper.GetMediaSourceSampleRate(source)
  local num_channels = reaper.GetMediaSourceNumChannels(source)

  if source_length <= 0 then return nil, "source_length <= 0" end
  if sample_rate <= 0 then return nil, "sample_rate <= 0" end
  if num_channels <= 0 then return nil, "num_channels <= 0" end
  if duration <= 0 then return nil, "duration <= 0" end

  -- Calculate peakrate: peaks per second for the requested duration
  local peakrate = num_samples / duration

  -- Buffer: need 2 values (min/max) per channel per sample
  local buf_size = num_samples * num_channels * 2
  local buf = reaper.new_array(buf_size)

  -- Clamp start_time to valid range for the API call
  local api_start = math.max(0, start_time)

  local ret = reaper.PCM_Source_GetPeaks(source, peakrate, api_start, num_channels, num_samples, 0, buf)

  if ret == 0 then return nil, "GetPeaks returned 0" end

  local peaks = {}
  -- Extract actual sample count from return value (lower 20 bits)
  local actual_samples = math.min(ret & 0xFFFFF, num_samples)

  -- REAPER buffer format: channel-interleaved within two blocks
  local min_block_offset = actual_samples * num_channels

  for i = 1, actual_samples do
    local max_val, min_val

    if num_channels == 1 then
      max_val = buf[i] or 0
      min_val = buf[min_block_offset + i] or 0
    else
      local base_idx = (i - 1) * num_channels + 1
      local l_max = buf[base_idx] or 0
      local r_max = buf[base_idx + 1] or 0
      local l_min = buf[min_block_offset + base_idx] or 0
      local r_min = buf[min_block_offset + base_idx + 1] or 0

      max_val = math.max(l_max, r_max)
      min_val = math.min(l_min, r_min)
    end

    peaks[i] = {min = min_val, max = max_val}
  end

  return peaks, nil
end

-- Legacy function for compatibility - fetches peaks for entire source
local function get_peaks(source, num_samples)
  if not source then return nil, "no source" end
  local source_length = reaper.GetMediaSourceLength(source)
  return get_peaks_for_range(source, 0, source_length, num_samples)
end

-- Draw dashed vertical line
local function draw_dashed_line(draw_list, x, y1, y2, color, dash_length, gap_length, line_width)
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

-- Convert source time to project time
local function source_to_project_time(source_t, item_position, start_offset, playrate)
  return item_position + (source_t - start_offset) / playrate
end

-- Convert project time to source time
local function project_to_source_time(project_t, item_position, start_offset, playrate)
  return start_offset + (project_t - item_position) * playrate
end

-- Convert linear gain to dB (with -infinity handling)
local function gain_to_db(gain)
  if gain <= 0 then return -math.huge end
  return 20 * math.log(gain) / math.log(10)
end

-- Convert dB to linear gain
local function db_to_gain(db)
  if db <= -150 then return 0 end  -- Treat very low dB as silence
  return 10 ^ (db / 20)
end

-- Convert slider position (0-1) to dB
-- Position 0.5 = 0dB, 1.0 = +24dB, 0.0 = -infinity
-- Uses exponential curve below 0dB for finer control near unity
local function slider_to_db(pos)
  if pos >= 0.5 then
    -- Upper half: linear 0dB to +24dB
    return (pos - 0.5) * 2 * 24
  else
    -- Lower half: exponential curve to -infinity
    -- At pos=0.5: dB=0, at pos=0: dB=-infinity
    if pos <= 0 then return -math.huge end
    -- Map 0-0.5 to a logarithmic curve
    -- Using: dB = 40 * log10(pos * 2) gives good feel
    -- At 0.5: 40*log10(1) = 0dB
    -- At 0.25: 40*log10(0.5) ≈ -12dB
    -- At 0.1: 40*log10(0.2) ≈ -28dB
    -- At 0.01: 40*log10(0.02) ≈ -68dB
    return 40 * math.log(pos * 2) / math.log(10)
  end
end

-- Convert dB to slider position (0-1)
local function db_to_slider(db)
  if db >= 0 then
    -- Upper half: +0dB to +24dB maps to 0.5-1.0
    return 0.5 + (db / 24) * 0.5
  else
    -- Lower half: -infinity to 0dB maps to 0-0.5
    if db <= -150 then return 0 end
    -- Inverse of: dB = 40 * log10(pos * 2)
    -- pos = 10^(dB/40) / 2
    return (10 ^ (db / 40)) / 2
  end
end

-- Format dB value for display
local function format_db(db)
  if db <= -60 then return "-∞" end
  if db >= 0 then
    return string.format("+%.1f", db)
  else
    return string.format("%.1f", db)
  end
end

-- Format pitch value for display (semitones)
local function format_pitch(semitones)
  if semitones >= 0 then
    return string.format("+%d", math.floor(semitones + 0.5))
  else
    return string.format("%d", math.floor(semitones + 0.5))
  end
end

-- Convert pitch (-48 to +48) to knob angle (radians)
-- 12 o'clock (up) = -π/2 in screen coords
-- 7 o'clock (min) = 120° = 2π/3
-- 5 o'clock (max) = 60° = π/3
-- Range is 300 degrees through 12 o'clock
local function pitch_to_angle(pitch)
  -- Normalize pitch to -1 to +1
  local normalized = pitch / PITCH_MAX
  -- Map to "clock angle" where 0 = 12 o'clock, positive = clockwise
  -- 7 o'clock = -150° from 12, 5 o'clock = +150° from 12
  local clock_angle = normalized * (5 * math.pi / 6)  -- -150° to +150°
  -- Convert to screen coordinates (subtract 90° = π/2)
  return clock_angle - math.pi / 2
end

-- Draw a knob
local function draw_knob(draw_list, cx, cy, radius, angle, is_hovered, is_active)
  local COLOR_KNOB_BG = 0x303030FF
  local COLOR_KNOB_BORDER = is_active and 0x6AB0F9FF or (is_hovered and 0x888888FF or 0x555555FF)
  local COLOR_KNOB_POINTER = 0xFFFFFFFF
  local COLOR_KNOB_ARC_BG = 0x404040FF
  local COLOR_KNOB_ARC = 0x4A90D9FF

  -- Draw background circle
  local num_segments = 32
  reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy, radius, COLOR_KNOB_BG, num_segments)
  reaper.ImGui_DrawList_AddCircle(draw_list, cx, cy, radius, COLOR_KNOB_BORDER, num_segments, 2)

  -- Arc angles: 7 o'clock to 5 o'clock through 12
  -- In screen coords: 7 o'clock = 2π/3 (120°), 5 o'clock = π/3 (60°)
  -- Going counter-clockwise from 7 to 5 through 12
  local arc_radius = radius + 4
  local min_angle = 2 * math.pi / 3  -- 7 o'clock (120°)
  local max_angle = math.pi / 3      -- 5 o'clock (60°)
  local center_angle = -math.pi / 2  -- 12 o'clock (-90°)

  -- Draw arc background as series of lines (from 7 o'clock clockwise to 5 o'clock through 12)
  local arc_segments = 30
  for i = 0, arc_segments - 1 do
    -- Go from min_angle (7 o'clock) clockwise through 9, 12, 3 to max_angle (5 o'clock)
    -- Total sweep: 300 degrees clockwise = 5π/3 radians
    local sweep = 5 * math.pi / 3
    local a1 = min_angle + sweep * (i / arc_segments)
    local a2 = min_angle + sweep * ((i + 1) / arc_segments)
    local x1 = cx + math.cos(a1) * arc_radius
    local y1 = cy + math.sin(a1) * arc_radius
    local x2 = cx + math.cos(a2) * arc_radius
    local y2 = cy + math.sin(a2) * arc_radius
    reaper.ImGui_DrawList_AddLine(draw_list, x1, y1, x2, y2, COLOR_KNOB_ARC_BG, 3)
  end

  -- Draw active arc (from center/12 o'clock to current position)
  -- Determine direction and range
  if math.abs(angle - center_angle) > 0.01 then
    local arc_start, arc_end
    if angle > center_angle then
      -- Positive pitch: arc goes from center clockwise to angle
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
      -- Negative pitch: arc goes from angle to center (counter-clockwise from center)
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

  -- Draw pointer line
  local pointer_inner = radius * 0.3
  local pointer_outer = radius * 0.85
  local px1 = cx + math.cos(angle) * pointer_inner
  local py1 = cy + math.sin(angle) * pointer_inner
  local px2 = cx + math.cos(angle) * pointer_outer
  local py2 = cy + math.sin(angle) * pointer_outer
  reaper.ImGui_DrawList_AddLine(draw_list, px1, py1, px2, py2, COLOR_KNOB_POINTER, 2)

  -- Draw "Pitch" label above knob
  local label_color = 0xAAAAAAFF
  reaper.ImGui_DrawList_AddText(draw_list, cx - 12, cy - radius - 18, label_color, "Pitch")

  -- Draw "st" label at bottom (in the arc gap)
  local st_color = 0x888888FF
  reaper.ImGui_DrawList_AddText(draw_list, cx - 5, cy + radius + 2, st_color, "st")
end

-- Convert pitch float to semitones and cents display values
local function pitch_to_semitones_cents(pitch)
  -- Use truncation toward zero for semitones
  local semitones
  if pitch >= 0 then
    semitones = math.floor(pitch)
  else
    semitones = math.ceil(pitch)
  end
  local cents = math.floor((pitch - semitones) * 100 + 0.5)
  -- Handle rounding edge case
  if cents >= 100 then
    cents = 0
    semitones = semitones + 1
  elseif cents <= -100 then
    cents = 0
    semitones = semitones - 1
  end
  return semitones, cents
end

-- Convert semitones and cents back to pitch float
local function semitones_cents_to_pitch(semitones, cents)
  return semitones + cents / 100
end

-- Draw ruler bar with bar numbers and grid lines
local function draw_ruler_and_grid(draw_list, x, ruler_y, wave_y, width, ruler_height, wave_height,
                                    view_start, view_length, item_position, start_offset, playrate)
  -- Draw ruler background
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x, ruler_y, x + width, ruler_y + ruler_height, COLOR_RULER_BG)

  -- Helper: convert source time to pixel
  local function time_to_px(t)
    return x + ((t - view_start) / view_length) * width
  end

  -- Get project time range visible in the view
  local view_end = view_start + view_length
  local project_start = source_to_project_time(view_start, item_position, start_offset, playrate)
  local project_end = source_to_project_time(view_end, item_position, start_offset, playrate)

  -- Get time signature info at project start
  local bpm, bpi = reaper.GetProjectTimeSignature2(0, project_start)
  local beats_per_bar = math.floor(bpi)
  if beats_per_bar < 1 then beats_per_bar = 4 end

  -- Find first bar before or at project_start
  local _, start_measures = reaper.TimeMap2_timeToBeats(0, project_start)
  local first_bar = math.floor(start_measures)

  -- Calculate minimum pixel spacing to avoid cluttering
  local min_bar_spacing = 30
  local min_beat_spacing = 10

  -- Draw bars and beats
  local bar = first_bar
  local max_iterations = 1000  -- Safety limit
  local iterations = 0

  while iterations < max_iterations do
    iterations = iterations + 1

    -- Get time at start of this bar (bar is 0-based measure index)
    local bar_project_time = reaper.TimeMap2_beatsToTime(0, 0, bar)

    if bar_project_time > project_end then break end

    -- Convert to source time
    local bar_source_time = project_to_source_time(bar_project_time, item_position, start_offset, playrate)

    -- Only draw if within view
    if bar_source_time >= view_start and bar_source_time <= view_end then
      local bar_px = time_to_px(bar_source_time)

      -- Draw bar line on waveform
      reaper.ImGui_DrawList_AddLine(draw_list, bar_px, wave_y, bar_px, wave_y + wave_height, COLOR_GRID_BAR, 1)

      -- Draw bar line on ruler
      reaper.ImGui_DrawList_AddLine(draw_list, bar_px, ruler_y, bar_px, ruler_y + ruler_height, COLOR_GRID_BAR, 1)

      -- Draw bar number (1-based display)
      local bar_num = bar + 1
      reaper.ImGui_DrawList_AddText(draw_list, bar_px + 3, ruler_y + 3, COLOR_RULER_TEXT, tostring(bar_num))

      -- Draw beat subdivisions if there's enough space
      local next_bar_time = reaper.TimeMap2_beatsToTime(0, 0, bar + 1)
      local next_bar_source = project_to_source_time(next_bar_time, item_position, start_offset, playrate)
      local bar_width_px = time_to_px(next_bar_source) - bar_px

      if bar_width_px / beats_per_bar >= min_beat_spacing then
        -- Get tempo at this bar for accurate beat timing
        local bar_bpm = reaper.GetProjectTimeSignature2(0, bar_project_time)
        local beat_duration = 60 / bar_bpm

        for beat = 1, beats_per_bar - 1 do
          local beat_project_time = bar_project_time + beat * beat_duration
          if beat_project_time > project_end then break end

          local beat_source_time = project_to_source_time(beat_project_time, item_position, start_offset, playrate)
          if beat_source_time >= view_start and beat_source_time <= view_end then
            local beat_px = time_to_px(beat_source_time)
            reaper.ImGui_DrawList_AddLine(draw_list, beat_px, wave_y, beat_px, wave_y + wave_height, COLOR_GRID_BEAT, 1)
          end
        end
      end
    end

    bar = bar + 1
  end

  -- Draw ruler bottom border
  reaper.ImGui_DrawList_AddLine(draw_list, x, ruler_y + ruler_height, x + width, ruler_y + ruler_height, COLOR_GRID_BAR, 1)
end

-- Format source time as mins:secs or mins:secs:ms depending on show_ms flag
local function format_source_time(seconds, show_ms)
  local negative = seconds < 0
  local abs_secs = math.abs(seconds)
  local mins = math.floor(abs_secs / 60)
  local secs = abs_secs - mins * 60

  local sign = negative and "-" or ""

  if show_ms then
    local whole_secs = math.floor(secs)
    local ms = math.floor((secs - whole_secs) * 1000)
    return string.format("%s%d:%02d:%03d", sign, mins, whole_secs, ms)
  else
    return string.format("%s%d:%02d", sign, mins, math.floor(secs))
  end
end

-- Draw bottom time ruler showing source time (0 = start of original sample)
local function draw_time_ruler(draw_list, x, y, width, height, view_start, view_length)
  -- Draw ruler background
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + width, y + height, COLOR_RULER_BG)

  -- Draw top border
  reaper.ImGui_DrawList_AddLine(draw_list, x, y, x + width, y, COLOR_GRID_BAR, 1)

  -- Helper: convert source time to pixel
  local function time_to_px(t)
    return x + ((t - view_start) / view_length) * width
  end

  -- Calculate view range
  local view_end = view_start + view_length

  -- Determine appropriate time interval based on visible time per pixel
  -- We want labels roughly every 60-100 pixels
  local target_label_spacing_px = 80
  local seconds_per_pixel = view_length / width
  local target_interval = seconds_per_pixel * target_label_spacing_px

  -- Snap to nice intervals: 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600...
  local nice_intervals = {0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600}
  local interval = nice_intervals[#nice_intervals]
  for _, ni in ipairs(nice_intervals) do
    if ni >= target_interval then
      interval = ni
      break
    end
  end

  -- Determine if we should show milliseconds (when interval is less than 1 second)
  local show_ms = interval < 1

  -- Find first tick before or at view_start
  local first_tick = math.floor(view_start / interval) * interval

  -- Draw ticks and labels
  local tick = first_tick
  local max_iterations = 200  -- Safety limit
  local iterations = 0

  while tick <= view_end and iterations < max_iterations do
    iterations = iterations + 1

    local tick_px = time_to_px(tick)

    -- Only draw if within view
    if tick_px >= x and tick_px <= x + width then
      -- Draw tick mark
      local tick_height = 5
      reaper.ImGui_DrawList_AddLine(draw_list, tick_px, y, tick_px, y + tick_height, COLOR_GRID_BAR, 1)

      -- Draw time label
      local label = format_source_time(tick, show_ms)
      reaper.ImGui_DrawList_AddText(draw_list, tick_px + 3, y + 3, COLOR_RULER_TEXT, label)
    end

    tick = tick + interval
  end
end

-- Draw waveform with looping support
-- source_item_length is the amount of source audio covered by the item (accounts for playrate)
-- pan_offset shifts the view left/right (positive = view shifted right, seeing earlier content)
-- zoom_lvl: 1.0 = fit to view, >1 = zoomed in
-- ruler_y: top of ruler bar (for extending source boundary lines through ruler)
-- visual_gain: multiplier for waveform height (1.0 = normal, matches item volume)
local function draw_waveform(draw_list, x, y, width, height, peaks, start_offset, source_item_length, source_length, pan_offset_time, zoom_lvl, ruler_y, visual_gain)
  if not peaks or #peaks == 0 or source_length <= 0 then return 0, 0, 0, source_length end

  pan_offset_time = pan_offset_time or 0
  zoom_lvl = zoom_lvl or 1.0
  visual_gain = visual_gain or 1.0

  -- Base view size = max(source_length, source_item_length) to ensure we can see everything at zoom 1.0
  local base_view_length = math.max(source_length, source_item_length)
  -- Apply zoom: higher zoom = smaller view_length = more zoomed in
  local view_length = base_view_length / zoom_lvl

  -- Center the view on the item, then apply pan offset
  local item_center = start_offset + source_item_length / 2
  local view_start = item_center - view_length / 2 + pan_offset_time
  local view_end = view_start + view_length

  -- Item bounds in source time
  local item_end = start_offset + source_item_length

  -- Background
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + width, y + height, COLOR_WAVEFORM_BG)

  -- Center line
  local center_y = y + height / 2
  reaper.ImGui_DrawList_AddLine(draw_list, x, center_y, x + width, center_y, COLOR_CENTERLINE, 1)

  -- Helper: convert time position to pixel
  local function time_to_px(t)
    return x + ((t - view_start) / view_length) * width
  end

  local half_height = height / 2 * 0.85

  -- Helper: get peak at a time position (with looping)
  -- Peaks cover full source (0 to source_length), so we map time directly
  local function get_peak_at_time(t)
    -- Wrap time to source range (0 to source_length) for looping
    local wrapped = t % source_length
    if wrapped < 0 then wrapped = wrapped + source_length end

    -- Map wrapped time to peak index (peaks cover 0 to source_length)
    local peak_idx = math.floor((wrapped / source_length) * #peaks) + 1
    peak_idx = math.max(1, math.min(peak_idx, #peaks))
    return peaks[peak_idx]
  end

  -- Draw waveform using filled quads for smoother appearance
  local num_samples = math.floor(width)

  -- Draw in segments based on active/inactive/looped state
  local prev_px, prev_top, prev_bot, prev_color = nil, nil, nil, nil

  for i = 0, num_samples - 1 do
    local px = x + i
    local t = view_start + (i / num_samples) * view_length
    local peak = get_peak_at_time(t)

    -- Apply visual gain to peak values (clamped to prevent overflow)
    local scaled_max = math.max(-1, math.min(1, peak.max * visual_gain))
    local scaled_min = math.max(-1, math.min(1, peak.min * visual_gain))

    local top_y = center_y - (scaled_max * half_height)
    local bot_y = center_y - (scaled_min * half_height)

    -- Ensure minimum height for visibility
    if bot_y - top_y < 2 then
      top_y = center_y - 1
      bot_y = center_y + 1
    end

    -- Check if in active region (item bounds)
    local in_active = t >= start_offset and t <= item_end
    -- Check if in looped region (outside source bounds)
    local is_looped = t < 0 or t >= source_length

    local fill_color, outline_color
    if in_active then
      if is_looped then
        fill_color = 0x3A7A3ACC    -- Dimmer green for looped, semi-transparent
        outline_color = 0x4A8F4AFF
      else
        fill_color = 0x4A9F4ACC    -- Main green, semi-transparent
        outline_color = 0x5ABF5AFF
      end
    else
      fill_color = 0x2A2A2ACC      -- Gray for inactive
      outline_color = 0x3A3A3AFF
    end

    -- Draw filled quad connecting to previous sample for smooth fill
    if prev_px then
      reaper.ImGui_DrawList_AddQuadFilled(draw_list,
        prev_px, prev_top,
        px, top_y,
        px, bot_y,
        prev_px, prev_bot,
        fill_color)
    end

    -- Draw outline on top and bottom edges
    if prev_px then
      reaper.ImGui_DrawList_AddLine(draw_list, prev_px, prev_top, px, top_y, outline_color, 1)
      reaper.ImGui_DrawList_AddLine(draw_list, prev_px, prev_bot, px, bot_y, outline_color, 1)
    end

    prev_px, prev_top, prev_bot, prev_color = px, top_y, bot_y, fill_color
  end

  -- Draw loop boundary markers (dashed lines at every source_length interval)
  local COLOR_BOUNDS = 0x888888FF  -- Gray dashed lines for all boundaries
  local bounds_top = ruler_y or y  -- Extend through ruler if ruler_y provided
  local bounds_line_width = 2  -- Width for loop boundaries
  local original_line_width = 3  -- Wider for original source edges

  -- Draw original source boundaries (at 0 and source_length) with dashed lines
  local orig_start_px = time_to_px(0)
  local orig_end_px = time_to_px(source_length)

  if orig_start_px >= x and orig_start_px <= x + width then
    draw_dashed_line(draw_list, orig_start_px, bounds_top, y + height, COLOR_BOUNDS, nil, nil, original_line_width)
  end
  if orig_end_px >= x and orig_end_px <= x + width then
    draw_dashed_line(draw_list, orig_end_px, bounds_top, y + height, COLOR_BOUNDS, nil, nil, original_line_width)
  end

  -- Draw loop boundaries going left (negative direction, skip 0 as it's already drawn)
  local boundary = -source_length
  while boundary >= view_start do
    local boundary_px = time_to_px(boundary)
    if boundary_px >= x and boundary_px <= x + width then
      draw_dashed_line(draw_list, boundary_px, bounds_top, y + height, COLOR_BOUNDS, nil, nil, bounds_line_width)
    end
    boundary = boundary - source_length
  end

  -- Draw loop boundaries going right (positive direction, skip source_length as it's already drawn)
  boundary = source_length * 2
  while boundary <= view_end do
    local boundary_px = time_to_px(boundary)
    if boundary_px >= x and boundary_px <= x + width then
      draw_dashed_line(draw_list, boundary_px, bounds_top, y + height, COLOR_BOUNDS, nil, nil, bounds_line_width)
    end
    boundary = boundary + source_length
  end

  -- Draw border around active region
  local start_px = time_to_px(start_offset) - x
  local end_px = time_to_px(item_end) - x

  if end_px > start_px then
    reaper.ImGui_DrawList_AddRect(draw_list,
      x + math.max(0, start_px), y + 2,
      x + math.min(width, end_px), y + height - 2,
      COLOR_BORDER, 0, 0, 2)
  end

  return start_px, end_px, view_start, view_length
end

-- Draw draggable marker
local function draw_marker(draw_list, x, y, height, is_start, is_hovered, is_dragging)
  local color = (is_hovered or is_dragging) and COLOR_MARKER_HOVER or COLOR_MARKER

  -- Vertical line
  reaper.ImGui_DrawList_AddLine(draw_list, x, y, x, y + height, color, 3)

  -- Handle triangles at top and bottom
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

-- Check if mouse is near marker
local function is_near_marker(mouse_x, marker_x, threshold)
  return math.abs(mouse_x - marker_x) < threshold
end

-- Check for file changes (call periodically)
local function check_for_changes()
  if not script_path then return false end

  -- Only check every 60 frames to reduce overhead
  reload_check_counter = reload_check_counter + 1
  if reload_check_counter < 60 then return false end
  reload_check_counter = 0

  local current_size = get_file_size(script_path)
  if current_size ~= 0 and current_size ~= initial_file_size then
    return true
  end
  return false
end

-- ========== HELPER FUNCTIONS FOR LEFT PANEL CONTROLS ==========
-- These are extracted from loop() to reduce local variable count (Lua limit: 200)

-- Draw WARP/REV/EDIT buttons in the left column
local function draw_button_panel(ctx, draw_list, mouse_x, mouse_y, left_col_x, left_col_y, item, take)
  local warp_btn_width = 36
  local warp_btn_height = 16
  local warp_btn_x = left_col_x + (LEFT_COLUMN_WIDTH - warp_btn_width) / 2 - 1
  local warp_btn_y = left_col_y + 4

  local COLOR_WARP_ON = 0x4A90D9FF
  local COLOR_WARP_OFF = 0x404040FF
  local COLOR_WARP_HOVER = 0x5AA0E9FF
  local COLOR_WARP_TEXT = 0xFFFFFFFF

  local mouse_in_warp = mouse_x >= warp_btn_x and mouse_x <= warp_btn_x + warp_btn_width
                        and mouse_y >= warp_btn_y and mouse_y <= warp_btn_y + warp_btn_height

  local warp_bg_color
  if warp_mode then
    warp_bg_color = mouse_in_warp and COLOR_WARP_HOVER or COLOR_WARP_ON
  else
    warp_bg_color = mouse_in_warp and 0x505050FF or COLOR_WARP_OFF
  end
  reaper.ImGui_DrawList_AddRectFilled(draw_list, warp_btn_x, warp_btn_y, warp_btn_x + warp_btn_width, warp_btn_y + warp_btn_height, warp_bg_color, 3)
  reaper.ImGui_DrawList_AddText(draw_list, warp_btn_x + 4, warp_btn_y + 2, COLOR_WARP_TEXT, "WARP")

  if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_warp then
    warp_mode = not warp_mode
    if take then
      reaper.Undo_BeginBlock()
      local current_playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
      local current_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      if warp_mode then
        local pitch_from_rate = playrate_to_semitones(current_playrate)
        reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", pitch_from_rate)
        local original_length = current_length * current_playrate
        reaper.SetMediaItemInfo_Value(item, "D_LENGTH", original_length)
        reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", 1.0)
      else
        local current_pitch = reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH")
        local rate_from_pitch = semitones_to_playrate(current_pitch)
        reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", rate_from_pitch)
        local new_length = current_length / rate_from_pitch
        reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_length)
        reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", 0)
      end
      reaper.UpdateArrange()
      reaper.Undo_EndBlock("NVSD_ItemView: Toggle WARP mode", -1)
    end
  end

  -- REVERSE button
  local rev_btn_width = 30
  local rev_btn_height = 16
  local rev_btn_x = left_col_x + (LEFT_COLUMN_WIDTH - rev_btn_width) / 2 - 1
  local rev_btn_y = warp_btn_y + warp_btn_height + 4

  local is_reversed = false
  local has_sws = reaper.BR_GetMediaSourceProperties ~= nil
  if has_sws and take then
    local retval, section, start_pos, length, fade, reverse = reaper.BR_GetMediaSourceProperties(take)
    if retval then is_reversed = reverse end
  end

  local mouse_in_rev = mouse_x >= rev_btn_x and mouse_x <= rev_btn_x + rev_btn_width
                       and mouse_y >= rev_btn_y and mouse_y <= rev_btn_y + rev_btn_height

  local rev_bg_color
  if is_reversed then
    rev_bg_color = mouse_in_rev and COLOR_WARP_HOVER or COLOR_WARP_ON
  else
    rev_bg_color = mouse_in_rev and 0x505050FF or COLOR_WARP_OFF
  end
  reaper.ImGui_DrawList_AddRectFilled(draw_list, rev_btn_x, rev_btn_y, rev_btn_x + rev_btn_width, rev_btn_y + rev_btn_height, rev_bg_color, 3)
  reaper.ImGui_DrawList_AddText(draw_list, rev_btn_x + 4, rev_btn_y + 2, COLOR_WARP_TEXT, "REV")

  if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_rev then
    if item then
      reaper.Undo_BeginBlock()
      reaper.SelectAllMediaItems(0, false)
      reaper.SetMediaItemSelected(item, true)
      reaper.Main_OnCommand(41051, 0)
      reaper.UpdateArrange()
      reaper.Undo_EndBlock("NVSD_ItemView: Toggle Reverse", -1)
      cached_peaks = nil
    end
  end

  -- EDIT button
  local edit_btn_width = 32
  local edit_btn_height = 16
  local edit_btn_x = left_col_x + (LEFT_COLUMN_WIDTH - edit_btn_width) / 2 - 1
  local edit_btn_y = rev_btn_y + rev_btn_height + 4

  local mouse_in_edit = mouse_x >= edit_btn_x and mouse_x <= edit_btn_x + edit_btn_width
                        and mouse_y >= edit_btn_y and mouse_y <= edit_btn_y + edit_btn_height

  local edit_bg_color = mouse_in_edit and 0x505050FF or COLOR_WARP_OFF
  reaper.ImGui_DrawList_AddRectFilled(draw_list, edit_btn_x, edit_btn_y, edit_btn_x + edit_btn_width, edit_btn_y + edit_btn_height, edit_bg_color, 3)
  reaper.ImGui_DrawList_AddText(draw_list, edit_btn_x + 4, edit_btn_y + 2, COLOR_WARP_TEXT, "EDIT")

  if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_edit then
    if item then
      reaper.Undo_BeginBlock()
      reaper.SelectAllMediaItems(0, false)
      reaper.SetMediaItemSelected(item, true)
      reaper.Main_OnCommand(40109, 0)
      reaper.Undo_EndBlock("NVSD_ItemView: Open in External Editor", -1)
    end
  end
end

-- Draw gain slider with tick marks
local function draw_gain_slider(ctx, draw_list, mouse_x, mouse_y, panel_x, panel_y, panel_split, item, item_vol)
  local item_db = gain_to_db(item_vol)
  local slider_pos = db_to_slider(item_db)

  local slider_x = panel_x + (LEFT_PANEL_WIDTH - GAIN_SLIDER_WIDTH) / 2 - 2
  local slider_top = panel_y + 20
  local slider_bottom = panel_split - 20
  local slider_height = slider_bottom - slider_top

  local COLOR_SLIDER_TRACK = 0x404040FF
  local COLOR_SLIDER_FILL = 0x4A90D9FF
  local COLOR_SLIDER_HANDLE = 0xAAAAAAFF
  local COLOR_SLIDER_HANDLE_HOVER = 0xFFFFFFFF
  local COLOR_ZERO_LINE = 0x666666FF
  local COLOR_TICK = 0x555555FF
  local COLOR_TICK_MAJOR = 0x666666FF
  local COLOR_LABEL = 0x888888FF

  reaper.ImGui_DrawList_AddRectFilled(draw_list, slider_x, slider_top, slider_x + GAIN_SLIDER_WIDTH, slider_bottom, COLOR_SLIDER_TRACK, 3)

  -- Tick marks
  local tick_left = slider_x - 3
  local tick_right = slider_x + GAIN_SLIDER_WIDTH + 3
  local tick_marks = {
    {db = 24, major = true}, {db = 18, major = false}, {db = 12, major = true},
    {db = 6, major = false}, {db = 0, major = true}, {db = -6, major = false},
    {db = -12, major = true}, {db = -18, major = false}, {db = -24, major = true},
    {db = -36, major = false}, {db = -48, major = true},
  }

  for _, tick in ipairs(tick_marks) do
    local tick_pos = db_to_slider(tick.db)
    local tick_y = slider_bottom - tick_pos * slider_height
    if tick_y >= slider_top and tick_y <= slider_bottom then
      local color = tick.major and COLOR_TICK_MAJOR or COLOR_TICK
      local left = tick.major and tick_left or (slider_x - 1)
      local right = tick.major and tick_right or (slider_x + GAIN_SLIDER_WIDTH + 1)
      reaper.ImGui_DrawList_AddLine(draw_list, left, tick_y, right, tick_y, color, 1)
    end
  end

  -- 0dB line and labels
  local zero_y = slider_bottom - 0.5 * slider_height
  reaper.ImGui_DrawList_AddLine(draw_list, tick_left, zero_y, tick_right, zero_y, COLOR_ZERO_LINE, 1)
  reaper.ImGui_DrawList_AddText(draw_list, slider_x - 1, slider_top - 14, COLOR_LABEL, "24")
  reaper.ImGui_DrawList_AddText(draw_list, slider_x - 1, slider_bottom + 3, COLOR_LABEL, "-\226\136\158")

  -- Fill from 0dB to current
  local handle_y = slider_bottom - slider_pos * slider_height
  if slider_pos > 0.5 then
    reaper.ImGui_DrawList_AddRectFilled(draw_list, slider_x + 2, handle_y, slider_x + GAIN_SLIDER_WIDTH - 2, zero_y, COLOR_SLIDER_FILL, 2)
  elseif slider_pos < 0.5 then
    reaper.ImGui_DrawList_AddRectFilled(draw_list, slider_x + 2, zero_y, slider_x + GAIN_SLIDER_WIDTH - 2, handle_y, COLOR_SLIDER_FILL, 2)
  end

  -- Handle
  local handle_height = 8
  local mouse_in_slider = mouse_x >= slider_x - 5 and mouse_x <= slider_x + GAIN_SLIDER_WIDTH + 5
                          and mouse_y >= slider_top - handle_height and mouse_y <= slider_bottom + handle_height
  local handle_color = (mouse_in_slider or is_dragging_gain) and COLOR_SLIDER_HANDLE_HOVER or COLOR_SLIDER_HANDLE
  reaper.ImGui_DrawList_AddRectFilled(draw_list, slider_x - 2, handle_y - handle_height/2, slider_x + GAIN_SLIDER_WIDTH + 2, handle_y + handle_height/2, handle_color, 3)

  -- Interaction
  local double_clicked = reaper.ImGui_IsMouseDoubleClicked(ctx, 0) and mouse_in_slider
  if double_clicked then
    reaper.Undo_BeginBlock()
    reaper.SetMediaItemInfo_Value(item, "D_VOL", 1.0)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("NVSD_ItemView: Reset item volume to 0dB", -1)
    is_dragging_gain = false
  elseif reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_slider then
    is_dragging_gain = true
    gain_drag_start_y = mouse_y
    gain_drag_start_value = slider_pos
    gain_shift_was_held = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift())
    if has_js_extension then
      local screen_x, screen_y = reaper.GetMousePosition()
      drag_lock_screen_x, drag_lock_screen_y = screen_x, screen_y
      drag_cumulative_delta_y = 0
      drag_window_to_screen_y = screen_y - mouse_y
    end
    reaper.Undo_BeginBlock()
  end

  if reaper.ImGui_IsMouseReleased(ctx, 0) and is_dragging_gain then
    is_dragging_gain = false
    if has_js_extension then
      local final_handle_y = slider_bottom - slider_pos * slider_height
      local screen_handle_y = final_handle_y + drag_window_to_screen_y
      reaper.JS_Mouse_SetPosition(drag_lock_screen_x, math.floor(screen_handle_y))
    end
    reaper.Undo_EndBlock("NVSD_ItemView: Adjust item volume", -1)
  end

  if is_dragging_gain and reaper.ImGui_IsMouseDown(ctx, 0) then
    local shift_held = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift())
    if shift_held ~= gain_shift_was_held then
      gain_drag_start_y = mouse_y
      gain_drag_start_value = slider_pos
      gain_shift_was_held = shift_held
      if has_js_extension then drag_cumulative_delta_y = 0 end
    end
    local sensitivity = shift_held and 0.15 or 1.0
    local delta_y = has_js_extension and drag_cumulative_delta_y or (gain_drag_start_y - mouse_y)
    local delta_pos = (delta_y / slider_height) * sensitivity
    local new_pos = math.max(0, math.min(1, gain_drag_start_value + delta_pos))
    local new_db = slider_to_db(new_pos)
    local new_gain = db_to_gain(new_db)
    reaper.SetMediaItemInfo_Value(item, "D_VOL", new_gain)
    reaper.UpdateArrange()
  end

  -- Labels
  reaper.ImGui_DrawList_AddText(draw_list, panel_x + 8, panel_y + 4, 0xAAAAAAFF, "Vol")
  reaper.ImGui_DrawList_AddText(draw_list, panel_x + 6, slider_bottom + 4, 0xAAAAAAFF, format_db(item_db))

  return slider_pos, slider_height, slider_bottom
end

-- Draw pitch knob
local function draw_pitch_knob(ctx, draw_list, mouse_x, mouse_y, panel_x, panel_split, panel_bottom, take)
  local take_pitch = 0
  if take then
    if warp_mode then
      take_pitch = reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH")
    else
      local take_playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
      take_pitch = playrate_to_semitones(take_playrate)
    end
  end

  local knob_cx = panel_x + LEFT_PANEL_WIDTH / 2 - 2
  local knob_cy = panel_split + (panel_bottom - panel_split) / 2
  local knob_angle = pitch_to_angle(take_pitch)

  local knob_dx = mouse_x - knob_cx
  local knob_dy = mouse_y - knob_cy
  local knob_dist = math.sqrt(knob_dx * knob_dx + knob_dy * knob_dy)
  local mouse_in_knob = knob_dist <= PITCH_KNOB_RADIUS + 8

  draw_knob(draw_list, knob_cx, knob_cy, PITCH_KNOB_RADIUS, knob_angle, mouse_in_knob, is_dragging_pitch)

  local pitch_double_clicked = reaper.ImGui_IsMouseDoubleClicked(ctx, 0) and mouse_in_knob
  if pitch_double_clicked then
    if take then
      reaper.Undo_BeginBlock()
      set_take_pitch(take, 0)
      reaper.UpdateArrange()
      reaper.Undo_EndBlock("NVSD_ItemView: Reset pitch to 0", -1)
    end
    is_dragging_pitch = false
  elseif reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_knob then
    is_dragging_pitch = true
    pitch_drag_start_y = mouse_y
    pitch_drag_start_value = take_pitch
    pitch_shift_was_held = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift())
    if has_js_extension then
      local screen_x, screen_y = reaper.GetMousePosition()
      drag_lock_screen_x, drag_lock_screen_y = screen_x, screen_y
      drag_cumulative_delta_y = 0
    end
    reaper.Undo_BeginBlock()
  end

  if reaper.ImGui_IsMouseReleased(ctx, 0) and is_dragging_pitch then
    is_dragging_pitch = false
    reaper.Undo_EndBlock("NVSD_ItemView: Adjust pitch", -1)
  end

  if is_dragging_pitch and reaper.ImGui_IsMouseDown(ctx, 0) then
    local shift_held = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift())
    if shift_held ~= pitch_shift_was_held then
      pitch_drag_start_y = mouse_y
      pitch_drag_start_value = take_pitch
      pitch_shift_was_held = shift_held
      if has_js_extension then drag_cumulative_delta_y = 0 end
    end
    local sensitivity = shift_held and 0.2 or 1.0
    local delta_y = has_js_extension and drag_cumulative_delta_y or (pitch_drag_start_y - mouse_y)
    local delta_semitones = math.floor((delta_y / 10) * sensitivity + 0.5)
    local start_semitones = math.floor(pitch_drag_start_value + 0.5)
    local new_pitch = math.max(PITCH_MIN, math.min(PITCH_MAX, start_semitones + delta_semitones))
    if take then
      set_take_pitch(take, new_pitch)
      reaper.UpdateArrange()
    end
  end

  return take_pitch, knob_cx, knob_cy
end

-- Draw semitones/cents boxes
local function draw_semitones_cents_boxes(ctx, draw_list, mouse_x, mouse_y, panel_x, knob_cy, take, take_pitch)
  local display_semitones, display_cents = pitch_to_semitones_cents(take_pitch)

  local box_width = 22
  local box_height = 16
  local box_y = knob_cy + PITCH_KNOB_RADIUS + 18
  local box_gap = 1
  local boxes_total_width = box_width * 2 + box_gap
  local box_left_x = panel_x + (LEFT_PANEL_WIDTH - boxes_total_width) / 2 - 2
  local box_right_x = box_left_x + box_width + box_gap

  local COLOR_BOX_BG = 0x252525FF
  local COLOR_BOX_BORDER = 0x444444FF
  local COLOR_BOX_HOVER = 0x555555FF
  local COLOR_BOX_TEXT = 0xCCCCCCFF

  local mouse_in_semitones_box = mouse_x >= box_left_x and mouse_x <= box_left_x + box_width
                                 and mouse_y >= box_y and mouse_y <= box_y + box_height
  local mouse_in_cents_box = mouse_x >= box_right_x and mouse_x <= box_right_x + box_width
                             and mouse_y >= box_y and mouse_y <= box_y + box_height

  -- Semitones box
  local semitones_border = (mouse_in_semitones_box or is_dragging_semitones) and COLOR_BOX_HOVER or COLOR_BOX_BORDER
  reaper.ImGui_DrawList_AddRectFilled(draw_list, box_left_x, box_y, box_left_x + box_width, box_y + box_height, COLOR_BOX_BG)
  reaper.ImGui_DrawList_AddRect(draw_list, box_left_x, box_y, box_left_x + box_width, box_y + box_height, semitones_border)
  local semitones_text = tostring(display_semitones)
  reaper.ImGui_DrawList_AddText(draw_list, box_left_x + box_width / 2 - (#semitones_text * 3), box_y + 2, COLOR_BOX_TEXT, semitones_text)

  -- Cents box
  local cents_border = (mouse_in_cents_box or is_dragging_cents) and COLOR_BOX_HOVER or COLOR_BOX_BORDER
  reaper.ImGui_DrawList_AddRectFilled(draw_list, box_right_x, box_y, box_right_x + box_width, box_y + box_height, COLOR_BOX_BG)
  reaper.ImGui_DrawList_AddRect(draw_list, box_right_x, box_y, box_right_x + box_width, box_y + box_height, cents_border)
  local cents_text = tostring(display_cents)
  reaper.ImGui_DrawList_AddText(draw_list, box_right_x + box_width / 2 - (#cents_text * 3), box_y + 2, COLOR_BOX_TEXT, cents_text)

  -- Semitones interaction
  local semitones_double_clicked = reaper.ImGui_IsMouseDoubleClicked(ctx, 0) and mouse_in_semitones_box
  if semitones_double_clicked then
    if take then
      reaper.Undo_BeginBlock()
      local new_pitch = math.max(PITCH_MIN, math.min(PITCH_MAX, semitones_cents_to_pitch(0, display_cents)))
      set_take_pitch(take, new_pitch)
      reaper.UpdateArrange()
      reaper.Undo_EndBlock("NVSD_ItemView: Reset semitones to 0", -1)
    end
    is_dragging_semitones = false
  elseif reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_semitones_box then
    is_dragging_semitones = true
    semitones_drag_start_y = mouse_y
    semitones_drag_start_value = display_semitones
    if has_js_extension then
      local screen_x, screen_y = reaper.GetMousePosition()
      drag_lock_screen_x, drag_lock_screen_y = screen_x, screen_y
      drag_cumulative_delta_y = 0
    end
    reaper.Undo_BeginBlock()
  end

  if reaper.ImGui_IsMouseReleased(ctx, 0) and is_dragging_semitones then
    is_dragging_semitones = false
    reaper.Undo_EndBlock("NVSD_ItemView: Adjust semitones", -1)
  end

  if is_dragging_semitones and reaper.ImGui_IsMouseDown(ctx, 0) then
    local delta_y = has_js_extension and drag_cumulative_delta_y or (semitones_drag_start_y - mouse_y)
    local delta_semitones = math.floor(delta_y / 10 + 0.5)
    local new_pitch = math.max(PITCH_MIN, math.min(PITCH_MAX, semitones_cents_to_pitch(semitones_drag_start_value + delta_semitones, display_cents)))
    if take then
      set_take_pitch(take, new_pitch)
      reaper.UpdateArrange()
    end
  end

  -- Cents interaction
  local cents_double_clicked = reaper.ImGui_IsMouseDoubleClicked(ctx, 0) and mouse_in_cents_box
  if cents_double_clicked then
    if take then
      reaper.Undo_BeginBlock()
      local new_pitch = math.max(PITCH_MIN, math.min(PITCH_MAX, semitones_cents_to_pitch(display_semitones, 0)))
      set_take_pitch(take, new_pitch)
      reaper.UpdateArrange()
      reaper.Undo_EndBlock("NVSD_ItemView: Reset cents to 0", -1)
    end
    is_dragging_cents = false
  elseif reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_cents_box then
    is_dragging_cents = true
    cents_drag_start_y = mouse_y
    cents_drag_start_value = display_cents
    if has_js_extension then
      local screen_x, screen_y = reaper.GetMousePosition()
      drag_lock_screen_x, drag_lock_screen_y = screen_x, screen_y
      drag_cumulative_delta_y = 0
    end
    reaper.Undo_BeginBlock()
  end

  if reaper.ImGui_IsMouseReleased(ctx, 0) and is_dragging_cents then
    is_dragging_cents = false
    reaper.Undo_EndBlock("NVSD_ItemView: Adjust cents", -1)
  end

  if is_dragging_cents and reaper.ImGui_IsMouseDown(ctx, 0) then
    local delta_y = has_js_extension and drag_cumulative_delta_y or (cents_drag_start_y - mouse_y)
    local delta_cents = math.floor(delta_y / 2 + 0.5)
    local new_pitch = math.max(PITCH_MIN, math.min(PITCH_MAX, semitones_cents_to_pitch(display_semitones, cents_drag_start_value + delta_cents)))
    if take then
      set_take_pitch(take, new_pitch)
      reaper.UpdateArrange()
    end
  end
end

-- Main GUI function
local function loop()
  -- Auto-reload check
  if check_for_changes() then
    should_reload = true
  end

  -- If reload pending, clean up and restart script
  if should_reload then
    -- Context will be garbage collected; just stop using it
    ctx = nil
    dofile(script_path)
    return  -- Don't continue old loop
  end

  -- Window flags
  local window_flags = reaper.ImGui_WindowFlags_NoCollapse()
                     + reaper.ImGui_WindowFlags_NoScrollWithMouse()  -- Don't consume wheel events

  -- Add window padding
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), WINDOW_PADDING, WINDOW_PADDING)

  local visible, open = reaper.ImGui_Begin(ctx, "NVSD_ItemView", true, window_flags)

  if visible then
    -- Handle undo/redo shortcuts (Ctrl+Z, Ctrl+Y/Ctrl+Shift+Z)
    local ctrl = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())
    local shift = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift())
    local z_key = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Z())
    local y_key = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Y())

    if ctrl and z_key and not shift then
      reaper.Main_OnCommand(40029, 0)  -- Edit: Undo
    elseif ctrl and (y_key or (z_key and shift)) then
      reaper.Main_OnCommand(40030, 0)  -- Edit: Redo
    end

    -- Get selected item
    local selected_item = reaper.GetSelectedMediaItem(0, 0)

    -- Clear sticky when selection changes to a new item
    if selected_item and selected_item ~= last_selected_item then
      sticky_item = nil
    end
    last_selected_item = selected_item

    local item = nil

    -- Priority 1: If mouse button is held over an item, use that and make it sticky
    -- Requires SWS/JS extension for JS_Mouse_GetState
    if reaper.JS_Mouse_GetState then
      local mouse_state = reaper.JS_Mouse_GetState(1)  -- 1 = left mouse button
      if mouse_state == 1 then
        local mouse_screen_x, mouse_screen_y = reaper.GetMousePosition()
        local item_under_mouse, take_under_mouse = reaper.GetItemFromPoint(mouse_screen_x, mouse_screen_y, false)
        if item_under_mouse then
          item = item_under_mouse
          sticky_item = item  -- Remember this item
        end
      end
    end

    -- Priority 2: Use sticky item if valid (overrides selection)
    if not item and sticky_item then
      -- Validate sticky item still exists in project
      local still_valid = false
      local num_items = reaper.CountMediaItems(0)
      for i = 0, num_items - 1 do
        if reaper.GetMediaItem(0, i) == sticky_item then
          still_valid = true
          break
        end
      end

      if still_valid then
        item = sticky_item
      else
        sticky_item = nil  -- Item was deleted
      end
    end

    -- Priority 3: Use selected item
    if not item then
      item = selected_item
    end

    if item then
      local take = reaper.GetActiveTake(item)

      if take and not reaper.TakeIsMIDI(take) then
        local take_source = reaper.GetMediaItemTake_Source(take)

        -- Get the root source and calculate total offset through section sources
        local source = take_source
        local section_offset = 0

        if source then
          -- Traverse up to root source, accumulating section offsets
          local parent = reaper.GetMediaSourceParent(source)
          while parent do
            -- Get this section's offset within its parent
            local sect_offs, sect_len, is_reversed = reaper.PCM_Source_GetSectionInfo(source)
            section_offset = section_offset + (sect_offs or 0)
            source = parent
            parent = reaper.GetMediaSourceParent(source)
          end
        end

        if source then
          local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
          local item_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
          local take_offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
          local source_length = reaper.GetMediaSourceLength(source)

          -- Total offset = section offset + take offset
          local start_offset = section_offset + take_offset

          if source_length <= 0 then
            source_length = item_length
          end

          -- Get playrate
          local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")

          -- Get item volume (for visual waveform scaling)
          local item_vol = reaper.GetMediaItemInfo_Value(item, "D_VOL")

          -- Get available space for waveform
          local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
          -- Account for both left columns in waveform width
          local total_left_width = LEFT_COLUMN_WIDTH + LEFT_PANEL_WIDTH
          local waveform_width = math.max(100, avail_w - (WAVEFORM_MARGIN_H * 2) - total_left_width)
          -- Reserve space for top ruler and bottom time ruler, ensure minimum height
          local waveform_height = math.max(50, avail_h - (WAVEFORM_MARGIN_V * 2) - RULER_HEIGHT - TIME_RULER_HEIGHT)

          local cursor_x, cursor_y = reaper.ImGui_GetCursorScreenPos(ctx)
          -- Far-left column position (WARP button etc)
          local left_col_x = cursor_x + WINDOW_PADDING
          local left_col_y = cursor_y + WAVEFORM_MARGIN_V
          -- Left panel position (volume/pitch)
          local panel_x = left_col_x + LEFT_COLUMN_WIDTH
          local panel_y = cursor_y + WAVEFORM_MARGIN_V
          local panel_height = RULER_HEIGHT + waveform_height + TIME_RULER_HEIGHT
          -- Waveform starts after both left panels
          local wave_x = cursor_x + total_left_width + WAVEFORM_MARGIN_H
          local ruler_y = cursor_y + WAVEFORM_MARGIN_V
          local wave_y = ruler_y + RULER_HEIGHT
          local time_ruler_y = wave_y + waveform_height  -- Bottom time ruler

          -- Reserve the full area with InvisibleButton to prevent window dragging
          local total_height = WAVEFORM_MARGIN_V + RULER_HEIGHT + waveform_height + TIME_RULER_HEIGHT + WAVEFORM_MARGIN_V
          reaper.ImGui_InvisibleButton(ctx, "waveform_area", avail_w, math.max(avail_h, total_height))

          -- Get mouse position early (needed by multiple sections)
          local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)

          -- Calculate source_item_length early (needed below)
          local source_item_length = item_length * playrate

          -- Peaks caching: fetch for full source, scale with zoom for better resolution
          -- Formula: at zoom Z, we view (source_length/Z) seconds in waveform_width pixels
          -- To get 1 peak per pixel: num_peaks = waveform_width * zoom_level
          -- But peaks cover full source, so scale by source ratio
          local base_view = math.max(source_length, source_item_length)
          local pixels_per_source = (waveform_width * zoom_level) / base_view * source_length
          local desired_samples = math.max(200, math.min(50000, math.floor(pixels_per_source)))

          -- Check if we need to refresh the cache
          local source_changed = source ~= cached_source or source_length ~= cached_source_length
          local item_changed = item ~= cached_item
          local samples_changed = desired_samples ~= cached_num_samples

          if item_changed or source_changed or samples_changed then
            cached_item = item
            cached_source = source
            cached_source_length = source_length
            cached_num_samples = desired_samples
            -- Fetch peaks for FULL source (0 to source_length) - required for looping to work
            cached_peaks, peaks_error = get_peaks(source, desired_samples)
          end

          -- Reset pan and zoom when item changes
          if item ~= last_panned_item then
            pan_offset = 0
            last_panned_item = item
          end
          if item ~= last_zoomed_item then
            zoom_level = 1.0
            last_zoomed_item = item
          end

          -- Draw waveform
          local draw_list = reaper.ImGui_GetWindowDrawList(ctx)

          -- During drag, use original values for VIEW centering to keep view stable
          -- but we'll calculate actual marker positions separately
          local view_offset, view_item_length
          if dragging_start or dragging_end then
            view_offset = drag_start_offset
            view_item_length = drag_start_length * drag_start_playrate
          else
            view_offset = start_offset
            view_item_length = source_item_length
          end

          local start_px, end_px, view_start, view_length = draw_waveform(draw_list, wave_x, wave_y,
            waveform_width, waveform_height,
            cached_peaks, view_offset, view_item_length, source_length, pan_offset, zoom_level, ruler_y, item_vol)

          -- Calculate ACTUAL current marker positions
          -- During drag, use tracked drag positions for stable rendering (no REAPER round-trip jitter)
          local function time_to_px_actual(t)
            return wave_x + ((t - view_start) / view_length) * waveform_width
          end
          local render_start, render_end
          if dragging_start or dragging_end then
            render_start = drag_current_start
            render_end = drag_current_end
          else
            render_start = start_offset
            render_end = start_offset + source_item_length
          end
          local actual_start_px = time_to_px_actual(render_start) - wave_x
          local actual_end_px = time_to_px_actual(render_end) - wave_x
          -- Use actual positions for overlays and marker drawing
          start_px = actual_start_px
          end_px = actual_end_px

          -- Draw ruler and grid lines
          -- Use original values during drag to keep grid stable
          local grid_offset = (dragging_start or dragging_end) and drag_start_offset or start_offset
          local grid_playrate = (dragging_start or dragging_end) and drag_start_playrate or playrate
          local grid_view_start = (dragging_start or dragging_end) and drag_start_view_start or view_start
          draw_ruler_and_grid(draw_list, wave_x, ruler_y, wave_y, waveform_width, RULER_HEIGHT, waveform_height,
            grid_view_start, view_length, item_position, grid_offset, grid_playrate)

          -- Draw overlays on inactive regions (outside item markers)
          -- Two levels: light for unused source, dark for looped/outside source
          local COLOR_UNUSED_SOURCE = 0x00000066    -- Light overlay (within source but outside markers)
          local COLOR_OUTSIDE_SOURCE = 0x000000AA   -- Dark overlay (outside original source bounds)

          local start_marker_px = wave_x + start_px
          local end_marker_px = wave_x + end_px

          -- Helper to convert source time to pixel
          local function time_to_overlay_px(t)
            return wave_x + ((t - view_start) / view_length) * waveform_width
          end

          -- Source boundary positions in pixels
          local source_start_px = time_to_overlay_px(0)
          local source_end_px = time_to_overlay_px(source_length)

          -- Clamp to view bounds
          local view_left = wave_x
          local view_right = wave_x + waveform_width

          -- Draw overlays from left to right, handling each zone:
          -- Zone A: before source start (dark) - looped content
          -- Zone B: source start to left marker (light) - unused source
          -- Zone C: left marker to right marker (no overlay) - active
          -- Zone D: right marker to source end (light) - unused source
          -- Zone E: after source end (dark) - looped content

          -- Zone A: before source start (dark overlay)
          if source_start_px > view_left then
            local left = view_left
            local right = math.min(source_start_px, math.min(start_marker_px, view_right))
            if right > left then
              reaper.ImGui_DrawList_AddRectFilled(draw_list, left, ruler_y, right, wave_y + waveform_height, COLOR_OUTSIDE_SOURCE)
            end
          end

          -- Zone B: source start to left marker (light overlay) - only if marker is after source start
          if start_marker_px > source_start_px then
            local left = math.max(source_start_px, view_left)
            local right = math.min(start_marker_px, view_right)
            if right > left then
              reaper.ImGui_DrawList_AddRectFilled(draw_list, left, ruler_y, right, wave_y + waveform_height, COLOR_UNUSED_SOURCE)
            end
          end

          -- Zone B2: if left marker is before source start, dark overlay from view_left to marker
          if start_marker_px < source_start_px and start_marker_px > view_left then
            local left = view_left
            local right = math.min(start_marker_px, view_right)
            if right > left then
              reaper.ImGui_DrawList_AddRectFilled(draw_list, left, ruler_y, right, wave_y + waveform_height, COLOR_OUTSIDE_SOURCE)
            end
          end

          -- Zone D: right marker to source end (light overlay) - only if marker is before source end
          if end_marker_px < source_end_px then
            local left = math.max(end_marker_px, view_left)
            local right = math.min(source_end_px, view_right)
            if right > left then
              reaper.ImGui_DrawList_AddRectFilled(draw_list, left, ruler_y, right, wave_y + waveform_height, COLOR_UNUSED_SOURCE)
            end
          end

          -- Zone E: after source end (dark overlay)
          if source_end_px < view_right then
            local left = math.max(source_end_px, math.max(end_marker_px, view_left))
            local right = view_right
            if right > left then
              reaper.ImGui_DrawList_AddRectFilled(draw_list, left, ruler_y, right, wave_y + waveform_height, COLOR_OUTSIDE_SOURCE)
            end
          end

          -- Zone E2: if right marker is after source end, dark overlay from marker to view_right
          if end_marker_px > source_end_px and end_marker_px < view_right then
            local left = math.max(end_marker_px, view_left)
            local right = view_right
            if right > left then
              reaper.ImGui_DrawList_AddRectFilled(draw_list, left, ruler_y, right, wave_y + waveform_height, COLOR_OUTSIDE_SOURCE)
            end
          end

          -- Draw bottom time ruler (source time)
          draw_time_ruler(draw_list, wave_x, time_ruler_y, waveform_width, TIME_RULER_HEIGHT, view_start, view_length)

          -- Draw original source boundary markers in ruler
          local tri_size = 10
          local COLOR_SOURCE_MARKER = 0xFFAA44FF  -- Bright orange

          -- Helper to convert source time to pixel
          local function source_time_to_px(t)
            return wave_x + ((t - view_start) / view_length) * waveform_width
          end

          -- Original source start (at time 0)
          local orig_start_px = source_time_to_px(0)
          if orig_start_px >= wave_x - tri_size and orig_start_px <= wave_x + waveform_width + tri_size then
            -- Triangle pointing right
            reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
              orig_start_px, ruler_y,
              orig_start_px, ruler_y + tri_size * 2,
              orig_start_px + tri_size, ruler_y + tri_size,
              COLOR_SOURCE_MARKER)
          end

          -- Original source end (at source_length)
          local orig_end_px = source_time_to_px(source_length)
          if orig_end_px >= wave_x - tri_size and orig_end_px <= wave_x + waveform_width + tri_size then
            -- Triangle pointing left
            reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
              orig_end_px, ruler_y,
              orig_end_px, ruler_y + tri_size * 2,
              orig_end_px - tri_size, ruler_y + tri_size,
              COLOR_SOURCE_MARKER)
          end

          -- Helper: convert pixel to time in current view
          local function px_to_time(px)
            return view_start + ((px - wave_x) / waveform_width) * view_length
          end

          -- Helper: convert time to pixel in current view
          local function time_to_px(t)
            return wave_x + ((t - view_start) / view_length) * waveform_width
          end

          -- Draw playhead (edit cursor)
          -- Always use actual current values so playhead tracks correctly during alt+drag
          local cursor_pos = reaper.GetCursorPosition()  -- Project time in seconds
          local cursor_source_time = project_to_source_time(cursor_pos, item_position, start_offset, playrate)
          local cursor_px = time_to_px(cursor_source_time)

          -- Only draw if within visible area
          if cursor_px >= wave_x and cursor_px <= wave_x + waveform_width then
            -- Vertical line through waveform
            reaper.ImGui_DrawList_AddLine(draw_list, cursor_px, wave_y, cursor_px, wave_y + waveform_height, COLOR_PLAYHEAD, 2)

            -- Triangle at top of ruler (pointing down)
            local tri_size = 8
            reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
              cursor_px - tri_size, ruler_y,
              cursor_px + tri_size, ruler_y,
              cursor_px, ruler_y + tri_size,
              COLOR_PLAYHEAD)
          end

          -- Draw REAPER timeline selection overlay
          local sel_ok, sel_start, sel_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
          if sel_start and sel_end and sel_start ~= sel_end then  -- Only draw if there's a selection
            -- Convert project time selection to source time (use actual current values)
            local sel_source_start = project_to_source_time(sel_start, item_position, start_offset, playrate)
            local sel_source_end = project_to_source_time(sel_end, item_position, start_offset, playrate)

            -- Convert to pixels
            local sel_px_start = time_to_px(sel_source_start)
            local sel_px_end = time_to_px(sel_source_end)

            -- Clamp to visible area
            local vis_start = math.max(wave_x, sel_px_start)
            local vis_end = math.min(wave_x + waveform_width, sel_px_end)

            -- Draw overlay if visible
            if vis_end > vis_start then
              local COLOR_SELECTION = 0x4A90D933  -- Light blue, very transparent
              -- Draw over waveform area
              reaper.ImGui_DrawList_AddRectFilled(draw_list, vis_start, wave_y, vis_end, wave_y + waveform_height, COLOR_SELECTION)
            end

            -- Draw arrows on ruler at selection edges
            local arrow_size = 6
            local COLOR_SELECTION_ARROW = 0x888888FF  -- Grey arrows

            -- Left edge arrow (pointing right, indicating start)
            if sel_px_start >= wave_x - arrow_size and sel_px_start <= wave_x + waveform_width + arrow_size then
              reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
                sel_px_start, ruler_y + RULER_HEIGHT - arrow_size * 2,
                sel_px_start, ruler_y + RULER_HEIGHT,
                sel_px_start + arrow_size, ruler_y + RULER_HEIGHT - arrow_size,
                COLOR_SELECTION_ARROW)
            end

            -- Right edge arrow (pointing left, indicating end)
            if sel_px_end >= wave_x - arrow_size and sel_px_end <= wave_x + waveform_width + arrow_size then
              reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
                sel_px_end, ruler_y + RULER_HEIGHT - arrow_size * 2,
                sel_px_end, ruler_y + RULER_HEIGHT,
                sel_px_end - arrow_size, ruler_y + RULER_HEIGHT - arrow_size,
                COLOR_SELECTION_ARROW)
            end
          end

          -- ========== LEFT PANEL CONTROLS (using extracted helper functions) ==========
          local COLOR_LEFT_COL_BG = 0x1A1A1AFF
          reaper.ImGui_DrawList_AddRectFilled(draw_list, left_col_x, left_col_y, left_col_x + LEFT_COLUMN_WIDTH - 2, left_col_y + panel_height, COLOR_LEFT_COL_BG)

          -- Draw buttons (WARP/REV/EDIT)
          draw_button_panel(ctx, draw_list, mouse_x, mouse_y, left_col_x, left_col_y, item, take)

          -- Panel background and split calculation
          local COLOR_PANEL_BG = 0x202020FF
          reaper.ImGui_DrawList_AddRectFilled(draw_list, panel_x, panel_y, panel_x + LEFT_PANEL_WIDTH - 4, panel_y + panel_height, COLOR_PANEL_BG)
          local panel_split = panel_y + panel_height * 0.55

          -- Draw gain slider
          draw_gain_slider(ctx, draw_list, mouse_x, mouse_y, panel_x, panel_y, panel_split, item, item_vol)

          -- Draw pitch knob
          local take_pitch, knob_cx, knob_cy = draw_pitch_knob(ctx, draw_list, mouse_x, mouse_y, panel_x, panel_split, panel_y + panel_height, take)

          -- Draw semitones/cents boxes
          draw_semitones_cents_boxes(ctx, draw_list, mouse_x, mouse_y, panel_x, knob_cy, take, take_pitch)

          -- Hide and lock cursor while dragging any control
          if is_dragging_gain or is_dragging_pitch or is_dragging_semitones or is_dragging_cents then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_None())
            if has_js_extension then
              local cur_screen_x, cur_screen_y = reaper.GetMousePosition()
              drag_cumulative_delta_y = drag_cumulative_delta_y + (drag_lock_screen_y - cur_screen_y)
              reaper.JS_Mouse_SetPosition(drag_lock_screen_x, drag_lock_screen_y)
            end
          end

          -- ========== END LEFT PANEL ==========

          -- Marker positions
          local start_marker_x = wave_x + start_px
          local end_marker_x = wave_x + end_px

          -- Mouse interaction
          -- Waveform area (for general clicks)
          local mouse_in_waveform = mouse_x >= wave_x and mouse_x <= wave_x + waveform_width
                                    and mouse_y >= wave_y and mouse_y <= wave_y + waveform_height
          -- Ruler area (for zoom drag)
          local mouse_in_ruler = mouse_x >= wave_x and mouse_x <= wave_x + waveform_width
                                 and mouse_y >= ruler_y and mouse_y <= ruler_y + RULER_HEIGHT
          -- Time ruler area (bottom)
          local mouse_in_time_ruler = mouse_x >= wave_x and mouse_x <= wave_x + waveform_width
                                 and mouse_y >= time_ruler_y and mouse_y <= time_ruler_y + TIME_RULER_HEIGHT
          -- Full waveform view (waveform + both rulers) - for ctrl+wheel zoom
          local mouse_in_view = mouse_x >= wave_x and mouse_x <= wave_x + waveform_width
                                and mouse_y >= ruler_y and mouse_y <= time_ruler_y + TIME_RULER_HEIGHT
          -- Extended area for marker interaction (includes marker width on both sides)
          local mouse_in_marker_area = mouse_x >= wave_x - MARKER_WIDTH and mouse_x <= wave_x + waveform_width + MARKER_WIDTH
                                    and mouse_y >= wave_y and mouse_y <= wave_y + waveform_height

          local near_start = is_near_marker(mouse_x, start_marker_x, MARKER_WIDTH)
          local near_end = is_near_marker(mouse_x, end_marker_x, MARKER_WIDTH)

          -- Cursor feedback
          -- Note: ImGui has limited cursors - no magnifying glass or open/closed hand variants
          if mouse_in_marker_area and (near_start or near_end) then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeEW())
          elseif mouse_in_ruler or is_ruler_dragging then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeEW())  -- Horizontal resize for zoom
          elseif is_panning then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeAll())  -- Grabbing/move cursor
          end

          -- Helper for zoom-to-cursor: use same values as draw_waveform for consistency
          -- (view_offset and view_item_length are drag_start values during drag, actual values otherwise)
          local zoom_base_view_length = math.max(source_length, view_item_length)
          local zoom_item_center = view_offset + view_item_length / 2

          -- Calculate minimum zoom to show both markers AND source boundaries with padding
          -- Markers are at start_offset and start_offset + source_item_length
          -- Source boundaries are at 0 and source_length
          local left_marker = start_offset
          local right_marker = start_offset + source_item_length
          -- Include source boundaries in the span we need to see
          local visible_left = math.min(0, left_marker)
          local visible_right = math.max(source_length, right_marker)
          local visible_span = visible_right - visible_left
          -- Add 20% padding on each side so boundaries aren't at edges
          local padded_span = visible_span * 1.4
          -- Minimum zoom = zoom_base_view_length / padded_span (lower zoom = see more)
          -- No fixed floor - always allow zooming out enough to see everything
          local min_zoom = zoom_base_view_length / padded_span
          -- Only apply a very small floor to prevent division issues
          min_zoom = math.max(0.01, min_zoom)

          local function zoom_to_cursor(new_zoom, cursor_x)
            -- Calculate cursor position as fraction of waveform width
            local cursor_fraction = (cursor_x - wave_x) / waveform_width
            cursor_fraction = math.max(0, math.min(1, cursor_fraction))

            -- Calculate time under cursor before zoom
            local time_under_cursor = view_start + cursor_fraction * view_length

            -- Apply new zoom (use dynamic min_zoom instead of hardcoded 1.0)
            local old_zoom = zoom_level
            -- Max zoom 500 - high enough for detail, fast enough for smooth operation
            zoom_level = math.max(min_zoom, math.min(500.0, new_zoom))

            -- Calculate new view length
            local new_view_length = zoom_base_view_length / zoom_level

            -- Calculate pan offset needed to keep time_under_cursor at cursor_fraction
            pan_offset = time_under_cursor - zoom_item_center + new_view_length * (0.5 - cursor_fraction)

            -- Clamp pan to ensure markers and source boundaries are visible
            -- view_start = item_center - half_view + pan_offset
            -- view_end = item_center + half_view + pan_offset
            local half_view = new_view_length / 2
            local padding = visible_span * 0.1

            -- If view is large enough to show everything, clamp pan to keep it visible
            if new_view_length >= visible_span then
              -- To show visible_left - padding: pan_offset >= visible_left - padding - zoom_item_center + half_view
              -- To show visible_right + padding: pan_offset <= visible_right + padding - zoom_item_center - half_view
              local min_pan = visible_left - padding - zoom_item_center + half_view
              local max_pan = visible_right + padding - zoom_item_center - half_view
              -- Swap if needed (when view is much larger than content)
              if min_pan > max_pan then min_pan, max_pan = max_pan, min_pan end
              pan_offset = math.max(min_pan, math.min(max_pan, pan_offset))
            end
          end

          -- Ctrl+mouse wheel zoom (zoom to cursor)
          local wheel = reaper.ImGui_GetMouseWheel(ctx)
          if wheel ~= 0 and mouse_in_view then
            local ctrl_down = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())
            if ctrl_down then
              local zoom_factor = 1.35  -- 35% per wheel notch (faster zoom)
              local new_zoom = wheel > 0 and (zoom_level * zoom_factor) or (zoom_level / zoom_factor)
              zoom_to_cursor(new_zoom, mouse_x)
            end
          end

          -- Ruler drag zoom (zoom to cursor x position)
          if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_ruler then
            is_ruler_dragging = true
            ruler_drag_start_y = mouse_y
            ruler_drag_start_zoom = zoom_level
          end

          if reaper.ImGui_IsMouseReleased(ctx, 0) then
            is_ruler_dragging = false
          end

          if is_ruler_dragging and reaper.ImGui_IsMouseDown(ctx, 0) then
            -- Drag up = zoom in, drag down = zoom out
            local delta_y = ruler_drag_start_y - mouse_y  -- Positive when dragging up
            local zoom_sensitivity = 0.03  -- Zoom change per pixel (3x faster)
            local zoom_multiplier = 1.0 + (delta_y * zoom_sensitivity)
            local new_zoom = ruler_drag_start_zoom * zoom_multiplier
            zoom_to_cursor(new_zoom, mouse_x)
          end

          -- Middle mouse panning
          local middle_mouse = 2  -- Middle mouse button index
          if reaper.ImGui_IsMouseClicked(ctx, middle_mouse) and mouse_in_waveform then
            is_panning = true
            pan_start_mouse_x = mouse_x
            pan_start_offset = pan_offset
          end

          if reaper.ImGui_IsMouseReleased(ctx, middle_mouse) then
            is_panning = false
          end

          if is_panning and reaper.ImGui_IsMouseDown(ctx, middle_mouse) then
            -- Calculate mouse movement in pixels, convert to time
            local mouse_delta_px = mouse_x - pan_start_mouse_x
            -- Dragging right = content moves right = view shifts left = negative offset change
            local delta_time = -(mouse_delta_px / waveform_width) * view_length
            pan_offset = pan_start_offset + delta_time
            -- Clamp pan to max half the item length in either direction
            local max_pan = source_item_length / 2
            pan_offset = math.max(-max_pan, math.min(max_pan, pan_offset))
          end

          -- Start dragging - store original values and begin undo block
          if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_marker_area then
            if near_start then
              dragging_start = true
              drag_start_offset = start_offset
              drag_start_length = item_length
              drag_start_mouse_x = mouse_x
              drag_start_view_length = view_length
              drag_start_view_start = view_start
              drag_start_playrate = playrate
              drag_current_start = start_offset
              drag_current_end = start_offset + source_item_length
              reaper.Undo_BeginBlock()
            elseif near_end then
              dragging_end = true
              drag_start_offset = start_offset
              drag_start_length = item_length
              drag_start_mouse_x = mouse_x
              drag_start_view_length = view_length
              drag_start_view_start = view_start
              drag_start_playrate = playrate
              drag_current_start = start_offset
              drag_current_end = start_offset + source_item_length
              reaper.Undo_BeginBlock()
            end
          end

          -- End dragging - close undo block and adjust pan to keep view stable
          if reaper.ImGui_IsMouseReleased(ctx, 0) then
            if dragging_start or dragging_end then
              -- Adjust pan_offset to keep view_start in same position after drag ends
              -- view_start = item_center - view_length/2 + pan_offset
              -- We need to compensate for changes in both item_center and view_length
              local old_item_length = drag_start_length * drag_start_playrate
              local new_item_length = source_item_length

              local old_center = drag_start_offset + old_item_length / 2
              local new_center = start_offset + new_item_length / 2

              local old_base = math.max(source_length, old_item_length)
              local new_base = math.max(source_length, new_item_length)
              local old_view_length = old_base / zoom_level
              local new_view_length = new_base / zoom_level

              -- Adjustment: keep view_start constant
              pan_offset = pan_offset + (old_center - new_center) + (new_view_length - old_view_length) / 2

              -- Determine undo message based on what changed
              local length_changed = math.abs(old_item_length - new_item_length) > 0.001
              if length_changed then
                if dragging_start then
                  reaper.Undo_EndBlock("NVSD_ItemView: Adjust item start", -1)
                else
                  reaper.Undo_EndBlock("NVSD_ItemView: Adjust item end", -1)
                end
              else
                reaper.Undo_EndBlock("NVSD_ItemView: Slide source position", -1)
              end
            end
            dragging_start = false
            dragging_end = false
          end

          -- Helper: snap time to nearest source boundary if within threshold
          local function snap_to_source_boundary(t, src_len, threshold_time)
            -- Find nearest multiple of source_length
            local nearest_boundary = math.floor(t / src_len + 0.5) * src_len
            if math.abs(t - nearest_boundary) <= threshold_time then
              return nearest_boundary
            end
            return t
          end

          -- Helper: snap source time to REAPER grid (if snapping enabled)
          local function snap_to_grid_if_enabled(source_t)
            -- Check if REAPER snap is enabled (action 1157)
            local snap_enabled = reaper.GetToggleCommandState(1157) == 1
            if not snap_enabled then return source_t end

            -- Convert source time to project time
            local project_t = source_to_project_time(source_t, item_position, start_offset, playrate)
            -- Snap to grid in project time
            local snapped_project_t = reaper.SnapToGrid(0, project_t)
            -- Convert back to source time
            return project_to_source_time(snapped_project_t, item_position, start_offset, playrate)
          end

          -- Calculate snap threshold in time units
          local snap_threshold_time = (SNAP_THRESHOLD_PX / waveform_width) * view_length

          -- Check if Alt is held (for sliding both markers together)
          local alt_held = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Alt())

          -- Alt+drag: slide both markers (change which part of source is used, keep item length/position same)
          if (dragging_start or dragging_end) and alt_held and reaper.ImGui_IsMouseDown(ctx, 0) then
            -- Calculate mouse delta in time units
            local mouse_delta_px = mouse_x - drag_start_mouse_x
            local mouse_delta_time = (mouse_delta_px / waveform_width) * drag_start_view_length

            -- Item length stays the same
            local original_source_length = drag_start_length * drag_start_playrate

            -- Calculate raw new positions
            local raw_start = drag_start_offset + mouse_delta_time
            local raw_end = raw_start + original_source_length

            -- Only snap the marker that was actually grabbed
            local new_start
            local snapped_to_boundary = false

            if dragging_start then
              -- Grabbed start marker - only snap start to boundary
              local start_snapped = snap_to_source_boundary(raw_start, source_length, snap_threshold_time)
              if start_snapped ~= raw_start then
                new_start = start_snapped
                snapped_to_boundary = true
              else
                new_start = snap_to_grid_if_enabled(raw_start)
              end
            else
              -- Grabbed end marker - only snap end to boundary
              local end_snapped = snap_to_source_boundary(raw_end, source_length, snap_threshold_time)
              if end_snapped ~= raw_end then
                -- Adjust start so end lands on boundary
                new_start = end_snapped - original_source_length
                snapped_to_boundary = true
              else
                new_start = snap_to_grid_if_enabled(raw_start)
              end
            end

            local new_end = new_start + original_source_length

            -- Convert to take-relative offset
            local new_take_offset = new_start - section_offset

            -- Update drag current positions for stable rendering
            drag_current_start = new_start
            drag_current_end = new_end

            reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", new_take_offset)
            -- D_LENGTH stays the same - no change needed
            reaper.UpdateArrange()

          -- Dragging start marker: move start, keep end fixed (in source time)
          elseif dragging_start and reaper.ImGui_IsMouseDown(ctx, 0) then
            -- original_end is in source time (accounts for playrate at drag start)
            local original_source_end = drag_start_offset + (drag_start_length * drag_start_playrate)
            local new_start
            if mouse_x >= wave_x and mouse_x <= wave_x + waveform_width then
              -- Inside waveform: direct 1:1 mapping
              new_start = px_to_time(mouse_x)
            else
              -- Outside waveform: extend at controlled rate (1 source_length per waveform_width)
              local edge_time = mouse_x < wave_x and view_start or view_start + view_length
              local overflow_px = mouse_x < wave_x and (wave_x - mouse_x) or (mouse_x - wave_x - waveform_width)
              local overflow_time = (overflow_px / waveform_width) * source_length
              new_start = mouse_x < wave_x and (edge_time - overflow_time) or (edge_time + overflow_time)
            end
            -- Snap to REAPER grid (if enabled), then to source boundaries
            new_start = snap_to_grid_if_enabled(new_start)
            new_start = snap_to_source_boundary(new_start, source_length, snap_threshold_time)
            -- Only clamp: can't go past end (need at least 0.01s source length)
            new_start = math.min(new_start, original_source_end - 0.01)
            -- new_source_length is in source time, convert to item time by dividing by playrate
            local new_source_length = original_source_end - new_start
            local new_item_length = new_source_length / drag_start_playrate
            -- Convert to take-relative offset (can be negative for pre-source looping)
            local new_take_offset = new_start - section_offset

            -- Update drag current positions for stable rendering
            drag_current_start = new_start
            drag_current_end = original_source_end

            reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", new_take_offset)
            reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_item_length)
            reaper.UpdateArrange()

          -- Dragging end marker: keep start fixed, change length
          elseif dragging_end and reaper.ImGui_IsMouseDown(ctx, 0) then
            local new_end
            if mouse_x >= wave_x and mouse_x <= wave_x + waveform_width then
              -- Inside waveform: direct 1:1 mapping
              new_end = px_to_time(mouse_x)
            else
              -- Outside waveform: extend at controlled rate (1 source_length per waveform_width)
              local edge_time = mouse_x < wave_x and view_start or view_start + view_length
              local overflow_px = mouse_x < wave_x and (wave_x - mouse_x) or (mouse_x - wave_x - waveform_width)
              local overflow_time = (overflow_px / waveform_width) * source_length
              new_end = mouse_x < wave_x and (edge_time - overflow_time) or (edge_time + overflow_time)
            end
            -- Snap to REAPER grid (if enabled), then to source boundaries
            new_end = snap_to_grid_if_enabled(new_end)
            new_end = snap_to_source_boundary(new_end, source_length, snap_threshold_time)
            -- new_source_length is in source time, convert to item time (use drag_start_offset for consistency)
            local new_source_length = new_end - drag_start_offset
            local new_item_length = new_source_length / drag_start_playrate
            -- Only clamp: need at least 0.01s item length (no upper bound - allows looping)
            new_item_length = math.max(0.01, new_item_length)

            -- Update drag current positions for stable rendering
            drag_current_start = drag_start_offset
            drag_current_end = new_end

            reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_item_length)
            reaper.UpdateArrange()
          end

          -- Draw markers on top (draw if visible in view)
          if start_marker_x >= wave_x - MARKER_WIDTH and start_marker_x <= wave_x + waveform_width + MARKER_WIDTH then
            draw_marker(draw_list, start_marker_x, wave_y, waveform_height, true, near_start, dragging_start)
          end
          if end_marker_x >= wave_x - MARKER_WIDTH and end_marker_x <= wave_x + waveform_width + MARKER_WIDTH then
            draw_marker(draw_list, end_marker_x, wave_y, waveform_height, false, near_end, dragging_end)
          end

        else
          reaper.ImGui_Text(ctx, "No audio source found")
        end
      else
        reaper.ImGui_Text(ctx, take and reaper.TakeIsMIDI(take) and "MIDI items not supported" or "No valid take")
      end
    else
      reaper.ImGui_Text(ctx, "Select an audio item to view")
    end

    reaper.ImGui_End(ctx)
  end

  reaper.ImGui_PopStyleVar(ctx)

  if open then
    reaper.defer(loop)
  end
end

reaper.defer(loop)
