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
local RULER_HEIGHT = 20  -- Height of the bar number ruler
local SNAP_THRESHOLD_PX = 10  -- Pixels within which markers snap to source boundaries

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

-- Get peaks data from audio source
local function get_peaks(source, num_samples)
  if not source then return nil, "no source" end

  local source_length = reaper.GetMediaSourceLength(source)
  local sample_rate = reaper.GetMediaSourceSampleRate(source)
  local num_channels = reaper.GetMediaSourceNumChannels(source)

  if source_length <= 0 then return nil, "source_length <= 0" end
  if sample_rate <= 0 then return nil, "sample_rate <= 0" end
  if num_channels <= 0 then return nil, "num_channels <= 0" end

  -- Calculate peakrate: peaks per second we want
  local peakrate = num_samples / source_length

  -- Buffer: need 2 values (min/max) per channel per sample
  local buf_size = num_samples * num_channels * 2
  local buf = reaper.new_array(buf_size)

  local ret = reaper.PCM_Source_GetPeaks(source, peakrate, 0, num_channels, num_samples, 0, buf)

  if ret == 0 then return nil, "GetPeaks returned 0" end

  local peaks = {}
  -- Extract actual sample count from return value (lower 20 bits)
  local actual_samples = math.min(ret & 0xFFFFF, num_samples)

  -- REAPER buffer format: channel-interleaved within two blocks
  -- Block 1 (maximums): [L0, R0, L1, R1, ...] at indices 1 to actual_samples*num_channels
  -- Block 2 (minimums): [L0, R0, L1, R1, ...] at indices actual_samples*num_channels+1 to end
  local min_block_offset = actual_samples * num_channels

  for i = 1, actual_samples do
    local max_val, min_val

    if num_channels == 1 then
      -- Mono: simple indexing
      max_val = buf[i] or 0
      min_val = buf[min_block_offset + i] or 0
    else
      -- Stereo/multichannel: interleaved within each block
      local base_idx = (i - 1) * num_channels + 1
      local l_max = buf[base_idx] or 0
      local r_max = buf[base_idx + 1] or 0
      local l_min = buf[min_block_offset + base_idx] or 0
      local r_min = buf[min_block_offset + base_idx + 1] or 0

      -- Combine channels: max of maxes, min of mins
      max_val = math.max(l_max, r_max)
      min_val = math.min(l_min, r_min)
    end

    peaks[i] = {min = min_val, max = max_val}
  end

  return peaks, nil
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

-- Draw waveform with looping support
-- source_item_length is the amount of source audio covered by the item (accounts for playrate)
-- pan_offset shifts the view left/right (positive = view shifted right, seeing earlier content)
-- zoom_lvl: 1.0 = fit to view, >1 = zoomed in
-- ruler_y: top of ruler bar (for extending source boundary lines through ruler)
local function draw_waveform(draw_list, x, y, width, height, peaks, start_offset, source_item_length, source_length, pan_offset_time, zoom_lvl, ruler_y)
  if not peaks or #peaks == 0 or source_length <= 0 then return 0, 0, 0, source_length end

  pan_offset_time = pan_offset_time or 0
  zoom_lvl = zoom_lvl or 1.0

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

  -- Helper: get peak at a time position (with looping)
  local function get_peak_at_time(t)
    -- Wrap time to source range (0 to source_length)
    local wrapped = t % source_length
    if wrapped < 0 then wrapped = wrapped + source_length end

    -- Find corresponding peak
    local peak_idx = math.floor((wrapped / source_length) * #peaks) + 1
    peak_idx = math.max(1, math.min(peak_idx, #peaks))
    return peaks[peak_idx]
  end

  -- Draw waveform using filled quads for smoother appearance
  local num_samples = math.floor(width)
  local half_height = height / 2 * 0.85

  -- Draw in segments based on active/inactive/looped state
  local prev_px, prev_top, prev_bot, prev_color = nil, nil, nil, nil

  for i = 0, num_samples - 1 do
    local px = x + i
    local t = view_start + (i / num_samples) * view_length
    local peak = get_peak_at_time(t)

    local top_y = center_y - (peak.max * half_height)
    local bot_y = center_y - (peak.min * half_height)

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

          -- Get available space for waveform
          local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
          local waveform_width = math.max(100, avail_w - (WAVEFORM_MARGIN_H * 2))
          -- Reserve space for ruler above waveform, ensure minimum height
          local waveform_height = math.max(50, avail_h - (WAVEFORM_MARGIN_V * 2) - RULER_HEIGHT)

          local cursor_x, cursor_y = reaper.ImGui_GetCursorScreenPos(ctx)
          local wave_x = cursor_x + WAVEFORM_MARGIN_H
          local ruler_y = cursor_y + WAVEFORM_MARGIN_V
          local wave_y = ruler_y + RULER_HEIGHT

          -- Reserve the full area with InvisibleButton to prevent window dragging
          local total_height = WAVEFORM_MARGIN_V + RULER_HEIGHT + waveform_height + WAVEFORM_MARGIN_V
          reaper.ImGui_InvisibleButton(ctx, "waveform_area", avail_w, math.max(avail_h, total_height))

          -- Update peaks cache (refresh when item, source, size, zoom, or source length changes)
          -- Scale samples with zoom level for better resolution when zoomed in
          -- Cap at 8000 samples max to maintain performance
          local base_samples = math.max(100, math.floor(waveform_width))
          local desired_samples = math.min(8000, math.floor(base_samples * zoom_level))
          if item ~= cached_item or source ~= cached_source or desired_samples ~= cached_num_samples or source_length ~= cached_source_length then
            cached_item = item
            cached_source = source
            cached_num_samples = desired_samples
            cached_source_length = source_length
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
          -- source_item_length = how much source audio the item covers (accounts for playrate)
          local source_item_length = item_length * playrate
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
            cached_peaks, view_offset, view_item_length, source_length, pan_offset, zoom_level, ruler_y)

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
          -- During drag, use original offset/playrate so cursor doesn't move visually
          local cursor_pos = reaper.GetCursorPosition()  -- Project time in seconds
          local cursor_offset = (dragging_start or dragging_end) and drag_start_offset or start_offset
          local cursor_playrate = (dragging_start or dragging_end) and drag_start_playrate or playrate
          local cursor_source_time = project_to_source_time(cursor_pos, item_position, cursor_offset, cursor_playrate)
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

          -- Marker positions
          local start_marker_x = wave_x + start_px
          local end_marker_x = wave_x + end_px

          -- Mouse interaction
          local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
          -- Waveform area (for general clicks)
          local mouse_in_waveform = mouse_x >= wave_x and mouse_x <= wave_x + waveform_width
                                    and mouse_y >= wave_y and mouse_y <= wave_y + waveform_height
          -- Ruler area (for zoom drag)
          local mouse_in_ruler = mouse_x >= wave_x and mouse_x <= wave_x + waveform_width
                                 and mouse_y >= ruler_y and mouse_y <= ruler_y + RULER_HEIGHT
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

          -- Helper for zoom-to-cursor: calculate time under mouse and adjust pan to keep it fixed
          local base_view_length = math.max(source_length, source_item_length)
          local item_center = start_offset + source_item_length / 2

          -- Calculate minimum zoom to show both markers with padding
          -- Markers are at start_offset and start_offset + source_item_length
          local left_marker = start_offset
          local right_marker = start_offset + source_item_length
          local marker_span = right_marker - left_marker
          -- Add 20% padding on each side so markers aren't at edges
          local padded_span = marker_span * 1.4
          -- Minimum zoom = base_view_length / padded_span (lower zoom = see more)
          local min_zoom = base_view_length / padded_span
          -- Ensure min_zoom doesn't go below a reasonable floor (0.1)
          min_zoom = math.max(0.1, min_zoom)

          local function zoom_to_cursor(new_zoom, cursor_x)
            -- Calculate cursor position as fraction of waveform width
            local cursor_fraction = (cursor_x - wave_x) / waveform_width
            cursor_fraction = math.max(0, math.min(1, cursor_fraction))

            -- Calculate time under cursor before zoom
            local time_under_cursor = view_start + cursor_fraction * view_length

            -- Apply new zoom (use dynamic min_zoom instead of hardcoded 1.0)
            local old_zoom = zoom_level
            zoom_level = math.max(min_zoom, math.min(20.0, new_zoom))

            -- Calculate new view length
            local new_view_length = base_view_length / zoom_level

            -- Calculate pan offset needed to keep time_under_cursor at cursor_fraction
            pan_offset = time_under_cursor - item_center + new_view_length * (0.5 - cursor_fraction)

            -- Clamp pan to reasonable bounds (allow more pan when zoomed out)
            local max_pan = math.max(source_item_length, new_view_length)
            pan_offset = math.max(-max_pan, math.min(max_pan, pan_offset))
          end

          -- Ctrl+mouse wheel zoom (zoom to cursor)
          local wheel = reaper.ImGui_GetMouseWheel(ctx)
          if wheel ~= 0 and (mouse_in_waveform or mouse_in_ruler) then
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

              if dragging_start then
                reaper.Undo_EndBlock("NVSD_ItemView: Adjust item start", -1)
              else
                reaper.Undo_EndBlock("NVSD_ItemView: Adjust item end", -1)
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

          -- Dragging start marker: move start, keep end fixed (in source time)
          if dragging_start and reaper.ImGui_IsMouseDown(ctx, 0) then
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
          end

          -- Dragging end marker: keep start fixed, change length
          if dragging_end and reaper.ImGui_IsMouseDown(ctx, 0) then
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
