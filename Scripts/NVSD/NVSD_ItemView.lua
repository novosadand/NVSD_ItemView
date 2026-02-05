-- @description NVSD ItemView - Ableton-style Clip View
-- @author NVSD
-- @version 1.0.0
-- @changelog
--   Initial release
-- @about
--   Ableton-style clip view for REAPER audio items.
--   See full source waveform, drag markers to control playback region.
--   Built-in gain, pitch, WARP, reverse, and 8 color themes.
-- @provides
--   [nomain] lib/*.lua
--   [nomain] NVSD_ItemView_Settings.lua
-- @link https://github.com/novosadand/NVSD_ItemView
-- @donation https://novosadand.gumroad.com
--
-- Requires: ReaImGui extension

-- Get script directory for loading modules
local script_path = debug.getinfo(1, "S").source:match("@(.+)")
local script_dir = script_path:match("(.+)[/\\]")

-- Load modules
local config = dofile(script_dir .. "/lib/config.lua")
local state = dofile(script_dir .. "/lib/state.lua")
local utils = dofile(script_dir .. "/lib/utils.lua")
local drawing = dofile(script_dir .. "/lib/drawing.lua")
local controls = dofile(script_dir .. "/lib/controls.lua")
local settings = dofile(script_dir .. "/lib/settings.lua")
local settings_ui = dofile(script_dir .. "/lib/settings_ui.lua")

-- Initialize settings
config.settings = settings
settings.load()
config.refresh_colors()

-- Auto-reload: Detect file changes and restart script
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

-- Create ImGui context
local ctx = reaper.ImGui_CreateContext("NVSD_ItemView")

-- Check for file changes (call periodically)
local function check_for_changes()
  if not script_path then return false end
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
    ctx = nil
    dofile(script_path)
    return
  end

  -- Window flags
  local window_flags = reaper.ImGui_WindowFlags_NoCollapse()
                     + reaper.ImGui_WindowFlags_NoScrollWithMouse()

  -- Add window padding
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), config.WINDOW_PADDING, config.WINDOW_PADDING)

  local visible, open = reaper.ImGui_Begin(ctx, "NVSD_ItemView", true, window_flags)

  if visible then
    -- Auto-focus window when hovered with Ctrl held (enables scroll-to-zoom without clicking first)
    local is_hovered = reaper.ImGui_IsWindowHovered(ctx, reaper.ImGui_HoveredFlags_ChildWindows())
    local ctrl_held = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())
    if is_hovered and ctrl_held and not reaper.ImGui_IsWindowFocused(ctx) then
      reaper.ImGui_SetWindowFocus(ctx)
    end

    -- Forward Space to REAPER transport (so playback works without clicking back to timeline)
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Space()) then
      reaper.Main_OnCommand(40044, 0)  -- Transport: Play/Stop
    end

    -- Handle undo/redo shortcuts (from settings)
    if settings.check_shortcut(ctx, "undo") then
      reaper.Main_OnCommand(40029, 0)
    elseif settings.check_shortcut(ctx, "redo") then
      reaper.Main_OnCommand(40030, 0)
    end

    -- Also support Ctrl+Shift+Z as alternate redo
    local ctrl = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())
    local shift = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift())
    local z_key = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Z())
    if ctrl and shift and z_key then
      reaper.Main_OnCommand(40030, 0)
    end

    -- Zoom shortcuts
    if settings.check_shortcut(ctx, "zoom_in") then
      state.zoom_level = math.min(500.0, state.zoom_level * 1.5)
    elseif settings.check_shortcut(ctx, "zoom_out") then
      state.zoom_level = math.max(1.0, state.zoom_level / 1.5)
    elseif settings.check_shortcut(ctx, "reset_zoom") then
      state.zoom_level = 1.0
      state.pan_offset = 0
    end

    -- Refresh colors only when settings change
    if settings.colors_dirty then
      config.refresh_colors()
      settings.colors_dirty = false
    end

    -- Draw settings UI if open
    settings_ui.draw(ctx, settings)

    -- Create undo point on mouse release if we were dragging
    if reaper.ImGui_IsMouseReleased(ctx, 0) and state.undo_block_open then
      local undo_messages = {
        marker_start = "NVSD_ItemView: Adjust item start",
        marker_end = "NVSD_ItemView: Adjust item end",
        pitch = "NVSD_ItemView: Adjust pitch",
        gain = "NVSD_ItemView: Adjust item volume",
        semitones = "NVSD_ItemView: Adjust semitones",
        cents = "NVSD_ItemView: Adjust cents",
      }
      local msg = undo_messages[state.undo_block_open] or "NVSD_ItemView: Edit"
      reaper.Undo_OnStateChangeEx(msg, -1, -1)
      state.undo_block_open = nil
    end

    -- Get selected item
    local selected_item = reaper.GetSelectedMediaItem(0, 0)

    -- Clear sticky when selection changes
    if selected_item ~= state.last_selected_item then
      state.sticky_item = nil
      state.sticky_item_valid = false
      state.sticky_validation_counter = 0
    end
    state.last_selected_item = selected_item

    local item = nil

    -- Track mouse button state for edge-drag detection
    local mouse_is_down = false
    if reaper.JS_Mouse_GetState then
      local mouse_state = reaper.JS_Mouse_GetState(1)
      mouse_is_down = (mouse_state & 1) ~= 0
    end

    -- Detect mouse button press/release (transitions)
    local mouse_just_pressed = mouse_is_down and not state.was_mouse_down
    local mouse_just_released = not mouse_is_down and state.was_mouse_down
    state.was_mouse_down = mouse_is_down

    -- Cooldown after mouse release: prevents I/O during the brief gap between
    -- click release and the next interaction (avoids blocking during rapid clicks/drags)
    if mouse_just_released then
      state.load_cooldown = 5  -- ~83ms at 60fps — enough to clear any rapid re-click
    end
    if state.load_cooldown > 0 then
      state.load_cooldown = state.load_cooldown - 1
    end

    -- Priority 1: On mouse press, check if over an item and make it sticky
    -- Only update sticky on initial click, not while dragging (prevents jumping to other items)
    if mouse_just_pressed then
      local mouse_screen_x, mouse_screen_y = reaper.GetMousePosition()
      local item_under_mouse, take_under_mouse = reaper.GetItemFromPoint(mouse_screen_x, mouse_screen_y, false)
      if item_under_mouse then
        state.sticky_item = item_under_mouse
        state.sticky_item_valid = true
        state.sticky_validation_counter = 0
      end
    end

    -- While mouse is held, use the sticky item (don't change it)
    if mouse_is_down and state.sticky_item then
      item = state.sticky_item
    end

    -- Priority 2: Use sticky item if valid (throttled validation: every 10 frames)
    if not item and state.sticky_item then
      state.sticky_validation_counter = state.sticky_validation_counter + 1
      if state.sticky_validation_counter >= 10 then
        state.sticky_validation_counter = 0
        -- Full validation scan
        local still_valid = false
        local num_items = reaper.CountMediaItems(0)
        for i = 0, num_items - 1 do
          if reaper.GetMediaItem(0, i) == state.sticky_item then
            still_valid = true
            break
          end
        end
        state.sticky_item_valid = still_valid
        if not still_valid then
          state.sticky_item = nil
        end
      end

      if state.sticky_item_valid then
        item = state.sticky_item
      end
    end

    -- Priority 3: Use selected item
    if not item then
      item = selected_item
    end

    -- Clear zoom/pan state when no item is shown (so next item shows full view)
    if not item then
      state.last_panned_item = nil
      state.last_zoomed_item = nil
    end

    -- Check if we have cached peaks for this item's source file
    -- If cached, we can show instantly even during mouse-down
    local item_file_path = nil
    local has_cached_file = false
    if item then
      local take = reaper.GetActiveTake(item)
      if take and not reaper.TakeIsMIDI(take) then
        local source = reaper.GetMediaItemTake_Source(take)
        if source then
          -- Get root source
          local parent = reaper.GetMediaSourceParent(source)
          while parent do
            source = parent
            parent = reaper.GetMediaSourceParent(source)
          end
          item_file_path = reaper.GetMediaSourceFileName(source, "")
          has_cached_file = item_file_path and state.get_cached_peaks(item_file_path) ~= nil
        end
      end
    end

    -- Skip processing while mouse is down on uncached item
    -- But allow instant display if we have cached peaks for this file
    if item and mouse_is_down and item ~= state.cached_item and not has_cached_file then
      item = nil  -- Defer until mouse release (only for uncached files)
    end

    if item then
      local take = reaper.GetActiveTake(item)

      -- Item-specific shortcuts (work on any item with an active take)
      if take then
        -- Toggle WARP (preserve pitch)
        if settings.check_shortcut(ctx, "toggle_warp") then
          reaper.Undo_BeginBlock()
          local preserve_pitch = reaper.GetMediaItemTakeInfo_Value(take, "B_PPITCH")
          local new_value = preserve_pitch == 1 and 0 or 1
          reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", new_value)
          reaper.UpdateArrange()
          reaper.Undo_EndBlock("NVSD_ItemView: Toggle WARP", -1)
        end

        -- Toggle Mute
        if settings.check_shortcut(ctx, "toggle_mute") then
          reaper.Undo_BeginBlock()
          local is_muted = reaper.GetMediaItemInfo_Value(item, "B_MUTE")
          local new_mute = is_muted == 1 and 0 or 1
          reaper.SetMediaItemInfo_Value(item, "B_MUTE", new_mute)
          reaper.UpdateArrange()
          reaper.Undo_EndBlock("NVSD_ItemView: Toggle mute", -1)
        end

        -- Reverse
        if settings.check_shortcut(ctx, "reverse") then
          reaper.Undo_BeginBlock()
          reaper.SelectAllMediaItems(0, false)
          reaper.SetMediaItemSelected(item, true)
          reaper.Main_OnCommand(41051, 0)
          reaper.UpdateArrange()
          reaper.Undo_EndBlock("NVSD_ItemView: Reverse", -1)
          state.pending_cache_invalidation = 3
        end

        -- Clear (reset pitch/speed)
        if settings.check_shortcut(ctx, "clear") then
          reaper.Undo_BeginBlock()
          local current_playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
          local current_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
          local original_length = current_length * current_playrate
          reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", 0)
          reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", 1.0)
          reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 0)
          reaper.SetMediaItemInfo_Value(item, "D_LENGTH", original_length)
          reaper.UpdateArrange()
          reaper.Undo_EndBlock("NVSD_ItemView: Clear pitch/speed", -1)
        end

        -- Open in external editor
        if settings.check_shortcut(ctx, "open_editor") then
          reaper.Undo_BeginBlock()
          reaper.SelectAllMediaItems(0, false)
          reaper.SetMediaItemSelected(item, true)
          reaper.Main_OnCommand(40109, 0)
          reaper.Undo_EndBlock("NVSD_ItemView: Open in External Editor", -1)
        end
      end

      if take and not reaper.TakeIsMIDI(take) then
        local take_source = reaper.GetMediaItemTake_Source(take)

        -- Get the root source and calculate total offset through section sources
        local source = take_source
        local section_offset = 0

        if source then
          local parent = reaper.GetMediaSourceParent(source)
          while parent do
            local retval, sect_offs, sect_len, is_reversed = reaper.PCM_Source_GetSectionInfo(source)
            if retval then
              section_offset = section_offset + (sect_offs or 0)
            end
            source = parent
            parent = reaper.GetMediaSourceParent(source)
          end
        end

        if source then
          local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
          local item_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
          local take_offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
          local source_length = reaper.GetMediaSourceLength(source)

          local start_offset = section_offset + take_offset

          if source_length <= 0 then
            source_length = item_length
          end

          local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
          if playrate == 0 then playrate = 1 end  -- Guard against division by zero
          local item_vol = reaper.GetMediaItemInfo_Value(item, "D_VOL")

          -- Get available space for waveform
          local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
          local total_left_width = config.LEFT_COLUMN_WIDTH + config.LEFT_PANEL_WIDTH
          local waveform_width = math.max(100, avail_w - (config.WAVEFORM_MARGIN_H * 2) - total_left_width)
          local waveform_height = math.max(50, avail_h - (config.WAVEFORM_MARGIN_V * 2) - config.INFO_BAR_HEIGHT - config.RULER_HEIGHT - config.TIME_RULER_HEIGHT)

          local cursor_x, cursor_y = reaper.ImGui_GetCursorScreenPos(ctx)
          local left_col_x = cursor_x + config.WINDOW_PADDING
          local left_col_y = cursor_y + config.WAVEFORM_MARGIN_V
          local panel_x = left_col_x + config.LEFT_COLUMN_WIDTH
          local panel_y = cursor_y + config.WAVEFORM_MARGIN_V
          local panel_height = config.INFO_BAR_HEIGHT + config.RULER_HEIGHT + waveform_height + config.TIME_RULER_HEIGHT
          local wave_x = cursor_x + total_left_width + config.WAVEFORM_MARGIN_H
          local info_bar_y = cursor_y + config.WAVEFORM_MARGIN_V
          local ruler_y = info_bar_y + config.INFO_BAR_HEIGHT
          local wave_y = ruler_y + config.RULER_HEIGHT
          local time_ruler_y = wave_y + waveform_height

          -- Reserve the full area
          local total_height = config.WAVEFORM_MARGIN_V + config.INFO_BAR_HEIGHT + config.RULER_HEIGHT + waveform_height + config.TIME_RULER_HEIGHT + config.WAVEFORM_MARGIN_V
          reaper.ImGui_InvisibleButton(ctx, "waveform_area", avail_w, math.max(avail_h, total_height))

          local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
          local source_item_length = item_length * playrate

          -- Check if take is reversed
          local is_reversed = false
          if reaper.BR_GetMediaSourceProperties and take then
            local retval, section, start_pos, length, fade, reverse = reaper.BR_GetMediaSourceProperties(take)
            if retval then is_reversed = reverse end
          end

          -- Peaks caching - very high resolution for deep zoom, LOD handles zoomed-out
          -- Need ~5000 peaks/sec for crisp display at max zoom (500x)
          local min_for_transients = math.floor(source_length * 5000)  -- 5000 peaks/sec
          local min_for_display = math.floor(waveform_width * 50)
          local desired_samples = math.max(20000, math.min(800000, math.max(min_for_transients, min_for_display)))

          -- Handle deferred cache invalidation
          if state.pending_cache_invalidation > 0 then
            state.pending_cache_invalidation = state.pending_cache_invalidation - 1
            if state.pending_cache_invalidation == 0 then
              state.invalidate_cache()
            end
          end

          -- Check if we need to refresh the cache
          local source_changed = source ~= state.cached_source or source_length ~= state.cached_source_length
          local item_changed = item ~= state.cached_item
          local reversed_changed = is_reversed ~= state.cached_reversed

          -- Check if user is dragging in REAPER (mouse button held outside our control)
          -- Use JS_Mouse_GetState (system-wide) instead of ImGui_IsMouseDown (ImGui window only)
          local we_are_dragging = state.dragging_start or state.dragging_end or state.is_panning
                                  or state.is_ruler_dragging or state.is_any_control_dragging()
          local user_dragging_in_reaper = mouse_is_down and not we_are_dragging

          -- Get file path for caching
          local file_path = reaper.GetMediaSourceFileName(source, "")

          -- Check multi-file cache first
          local file_cache_entry = file_path and state.get_cached_peaks(file_path)

          -- Deferred loading: Don't load peaks while user is dragging in REAPER
          -- This keeps REAPER responsive during edge drags, etc.
          if item_changed or source_changed or reversed_changed then
            state.cached_item = item
            state.cached_source = source
            state.cached_source_length = source_length
            state.cached_reversed = is_reversed
            state.target_samples = desired_samples

            -- Check if we have this file in cache
            if file_cache_entry and not is_reversed then
              -- Use cached peaks instantly!
              state.cached_peaks = file_cache_entry.peaks
              state.cached_lod = file_cache_entry.lod
              state.cached_num_channels = file_cache_entry.num_channels
              state.cached_num_samples = file_cache_entry.num_samples
              state.peaks_error = nil
              state.loading_stage = 2
            else
              -- Need to load
              state.loading_stage = 0
              state.cached_peaks = nil
              state.cached_lod = nil
            end
          end

          -- Progressive peak loading (3 stages across frames to prevent blocking)
          -- Stage 0→1: Fast preview (~4K samples, <5ms) for instant waveform display
          -- Stage 1→2: Full resolution peaks (spreads I/O to next frame)
          -- Stage 2+:  Build LOD for fast zoom-out rendering (next frame after that)
          if not user_dragging_in_reaper and state.load_cooldown == 0 then
            if state.loading_stage == 0 and state.cached_peaks == nil then
              -- Stage 1: Fast preview for instant display
              local preview_count = math.min(desired_samples, math.max(math.floor(waveform_width * 2), 4000))
              local peaks_result, num_ch_or_error = utils.get_peaks(source, preview_count)
              if peaks_result then
                state.cached_peaks = peaks_result
                state.cached_num_channels = num_ch_or_error
                state.cached_num_samples = preview_count
                state.cached_lod = nil
                state.peaks_error = nil
                -- Skip to stage 2 if preview already covers full resolution
                state.loading_stage = preview_count >= desired_samples and 2 or 1
              else
                state.peaks_error = num_ch_or_error
              end

            elseif state.loading_stage == 1 then
              -- Stage 2: Full resolution peaks
              local peaks_result, num_ch_or_error = utils.get_peaks(source, desired_samples)
              if peaks_result then
                state.cached_peaks = peaks_result
                state.cached_num_channels = num_ch_or_error
                state.cached_num_samples = desired_samples
                state.cached_lod = nil  -- LOD built next frame
                state.loading_stage = 2
                -- Store in file cache (LOD added next frame)
                if file_path and not is_reversed then
                  state.set_cached_peaks(file_path, peaks_result, nil, num_ch_or_error, source_length, desired_samples)
                end
              end

            elseif state.loading_stage == 2 and not state.cached_lod and state.cached_peaks then
              -- Stage 3: Build LOD for fast zoom-out rendering
              state.cached_lod = utils.build_lod_peaks(state.cached_peaks, state.cached_num_channels)
              state.peaks_error = nil
              -- Update file cache with LOD
              if file_path and not is_reversed then
                local entry = state.get_cached_peaks(file_path)
                if entry then
                  entry.lod = state.cached_lod
                end
              end

            elseif state.loading_stage == 2 and state.cached_lod and desired_samples ~= state.cached_num_samples then
              -- Resolution changed (window resize): reload
              local peaks_result, num_ch_or_error = utils.get_peaks(source, desired_samples)
              if peaks_result then
                state.cached_peaks = peaks_result
                state.cached_num_channels = num_ch_or_error
                state.cached_num_samples = desired_samples
                state.cached_lod = utils.build_lod_peaks(peaks_result, num_ch_or_error)
              end
            end
          end

          -- Reset zoom and pan when item changes - show full source
          if item ~= state.last_zoomed_item or item ~= state.last_panned_item then
            state.zoom_level = 1.0
            state.pan_offset = 0
            state.last_panned_item = item
            state.last_zoomed_item = item
          end

          -- Draw waveform
          local draw_list = reaper.ImGui_GetWindowDrawList(ctx)

          local view_offset, view_item_length
          if state.dragging_start or state.dragging_end then
            view_offset = state.drag_start_offset
            view_item_length = state.drag_start_length * state.drag_start_playrate
          else
            view_offset = start_offset
            view_item_length = source_item_length
          end

          local start_px, end_px, view_start, view_length = drawing.draw_waveform(draw_list, wave_x, wave_y,
            waveform_width, waveform_height,
            state.cached_peaks, view_offset, view_item_length, source_length, state.pan_offset, state.zoom_level, ruler_y, item_vol, is_reversed, state.cached_num_channels, config, state.cached_lod)

          -- Unified coordinate conversion (used by all subsequent code)
          local function time_to_px(t)
            return wave_x + ((t - view_start) / view_length) * waveform_width
          end

          local function px_to_time(px)
            return view_start + ((px - wave_x) / waveform_width) * view_length
          end

          -- Draw file info bar at the top
          local file_path = reaper.GetMediaSourceFileName(source, "")
          local _, gear_clicked = drawing.draw_info_bar(draw_list, ctx, wave_x, info_bar_y, waveform_width, config.INFO_BAR_HEIGHT, source, file_path, mouse_x, mouse_y, item, config, utils)

          -- Open settings when gear is clicked
          if gear_clicked then
            settings_ui.open(settings)
          end

          -- Right-click menu
          if reaper.ImGui_IsMouseClicked(ctx, 1) then
            local in_window = mouse_x >= cursor_x and mouse_x <= cursor_x + avail_w
                              and mouse_y >= cursor_y and mouse_y <= cursor_y + avail_h
            if in_window then
              reaper.ImGui_OpenPopup(ctx, "context_menu")
            end
          end

          if reaper.ImGui_BeginPopup(ctx, "context_menu") then
            if reaper.ImGui_MenuItem(ctx, "Settings...") then
              settings_ui.open(settings)
            end
            reaper.ImGui_EndPopup(ctx)
          end

          -- Calculate ACTUAL current marker positions
          local render_start, render_end
          if state.dragging_start or state.dragging_end then
            render_start = state.drag_current_start
            render_end = state.drag_current_end
          else
            render_start = start_offset
            render_end = start_offset + source_item_length
          end
          -- Clamp markers to source bounds (for looped items, show full source)
          render_start = math.max(0, math.min(source_length, render_start))
          render_end = math.max(0, math.min(source_length, render_end))
          local actual_start_px = time_to_px(render_start) - wave_x
          local actual_end_px = time_to_px(render_end) - wave_x
          start_px = actual_start_px
          end_px = actual_end_px

          -- Draw ruler and grid lines
          local grid_offset = (state.dragging_start or state.dragging_end) and state.drag_start_offset or start_offset
          local grid_playrate = (state.dragging_start or state.dragging_end) and state.drag_start_playrate or playrate
          local grid_view_start = (state.dragging_start or state.dragging_end) and state.drag_start_view_start or view_start
          drawing.draw_ruler_and_grid(draw_list, wave_x, ruler_y, wave_y, waveform_width, config.RULER_HEIGHT, waveform_height,
            grid_view_start, view_length, item_position, grid_offset, grid_playrate, config, utils)

          -- Draw overlays on inactive regions
          local COLOR_UNUSED_SOURCE = 0x00000038
          local COLOR_OUTSIDE_SOURCE = 0x00000058

          local source_start_px = time_to_px(0)
          local source_end_px = time_to_px(source_length)
          local view_left = wave_x
          local view_right = wave_x + waveform_width

          -- Calculate active regions considering loops
          -- Item plays from start_offset to start_offset + source_item_length
          local item_start = start_offset
          local item_end = start_offset + source_item_length

          -- Check if item loops (extends past source_length)
          local is_looping = item_end > source_length
          local loop_end = 0  -- How far into source the loop extends from beginning

          if is_looping then
            -- Calculate how much of the beginning is covered by the loop
            local overflow = item_end - source_length
            if overflow >= source_length then
              -- Multiple full loops - entire source is active
              loop_end = source_length
            else
              loop_end = overflow
            end
          end

          -- Also check for negative start (looping from before source start)
          local loop_from_end = 0
          if item_start < 0 then
            local underflow = -item_start
            if underflow >= source_length then
              loop_from_end = source_length
            else
              loop_from_end = underflow
            end
          end

          -- Draw outside source overlay (before source start)
          if source_start_px > view_left then
            local left = view_left
            local right = math.min(source_start_px, view_right)
            if right > left then
              reaper.ImGui_DrawList_AddRectFilled(draw_list, left, ruler_y, right, wave_y + waveform_height, COLOR_OUTSIDE_SOURCE)
            end
          end

          -- Draw outside source overlay (after source end)
          if source_end_px < view_right then
            local left = math.max(source_end_px, view_left)
            local right = view_right
            if right > left then
              reaper.ImGui_DrawList_AddRectFilled(draw_list, left, ruler_y, right, wave_y + waveform_height, COLOR_OUTSIDE_SOURCE)
            end
          end

          -- Draw inactive regions within source bounds
          -- Check beginning of source (0 to main_start or loop_end)
          local main_start_clamped = math.max(0, item_start)
          if loop_end > 0 then
            -- Source loops - check if there's a gap between loop_end and main_start
            if loop_end < main_start_clamped then
              local gap_start_px = time_to_px(loop_end)
              local gap_end_px = time_to_px(main_start_clamped)
              local left = math.max(gap_start_px, view_left)
              local right = math.min(gap_end_px, view_right)
              if right > left then
                reaper.ImGui_DrawList_AddRectFilled(draw_list, left, ruler_y, right, wave_y + waveform_height, COLOR_UNUSED_SOURCE)
              end
            end
          else
            -- No loop from end - unused from source start to item start
            if main_start_clamped > 0 then
              local left = math.max(source_start_px, view_left)
              local right = math.min(time_to_px(main_start_clamped), view_right)
              if right > left then
                reaper.ImGui_DrawList_AddRectFilled(draw_list, left, ruler_y, right, wave_y + waveform_height, COLOR_UNUSED_SOURCE)
              end
            end
          end

          -- Check end of source (main_end to source_length or loop_from_end start)
          local main_end_clamped = math.min(source_length, item_end)
          if loop_from_end > 0 then
            -- Source loops from beginning - check if there's a gap
            local loop_start_time = source_length - loop_from_end
            if main_end_clamped < loop_start_time then
              local gap_start_px = time_to_px(main_end_clamped)
              local gap_end_px = time_to_px(loop_start_time)
              local left = math.max(gap_start_px, view_left)
              local right = math.min(gap_end_px, view_right)
              if right > left then
                reaper.ImGui_DrawList_AddRectFilled(draw_list, left, ruler_y, right, wave_y + waveform_height, COLOR_UNUSED_SOURCE)
              end
            end
          else
            -- No loop from start - unused from item end to source end
            if main_end_clamped < source_length then
              local left = math.max(time_to_px(main_end_clamped), view_left)
              local right = math.min(source_end_px, view_right)
              if right > left then
                reaper.ImGui_DrawList_AddRectFilled(draw_list, left, ruler_y, right, wave_y + waveform_height, COLOR_UNUSED_SOURCE)
              end
            end
          end

          -- Draw bottom time ruler
          drawing.draw_time_ruler(draw_list, wave_x, time_ruler_y, waveform_width, config.TIME_RULER_HEIGHT, view_start, view_length, config, utils)

          -- Draw original source boundary markers in ruler
          local COLOR_SOURCE_MARKER = 0xFFAA44FF

          local orig_start_px = time_to_px(0)
          if orig_start_px >= wave_x - 2 and orig_start_px <= wave_x + waveform_width + 2 then
            reaper.ImGui_DrawList_AddLine(draw_list, orig_start_px, ruler_y, orig_start_px, ruler_y + config.RULER_HEIGHT, COLOR_SOURCE_MARKER, 2)
            local bracket_len = 4
            reaper.ImGui_DrawList_AddLine(draw_list, orig_start_px, ruler_y + 1, orig_start_px + bracket_len, ruler_y + 1, COLOR_SOURCE_MARKER, 2)
            reaper.ImGui_DrawList_AddLine(draw_list, orig_start_px, ruler_y + config.RULER_HEIGHT - 1, orig_start_px + bracket_len, ruler_y + config.RULER_HEIGHT - 1, COLOR_SOURCE_MARKER, 2)
          end

          local orig_end_px = time_to_px(source_length)
          if orig_end_px >= wave_x - 2 and orig_end_px <= wave_x + waveform_width + 2 then
            reaper.ImGui_DrawList_AddLine(draw_list, orig_end_px, ruler_y, orig_end_px, ruler_y + config.RULER_HEIGHT, COLOR_SOURCE_MARKER, 2)
            local bracket_len = 4
            reaper.ImGui_DrawList_AddLine(draw_list, orig_end_px - bracket_len, ruler_y + 1, orig_end_px, ruler_y + 1, COLOR_SOURCE_MARKER, 2)
            reaper.ImGui_DrawList_AddLine(draw_list, orig_end_px - bracket_len, ruler_y + config.RULER_HEIGHT - 1, orig_end_px, ruler_y + config.RULER_HEIGHT - 1, COLOR_SOURCE_MARKER, 2)
          end

          -- Draw REAPER timeline selection overlay
          local sel_ok, sel_start, sel_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
          if sel_start and sel_end and sel_start ~= sel_end then
            local sel_source_start = utils.project_to_source_time(sel_start, item_position, start_offset, playrate)
            local sel_source_end = utils.project_to_source_time(sel_end, item_position, start_offset, playrate)

            local sel_px_start = time_to_px(sel_source_start)
            local sel_px_end = time_to_px(sel_source_end)

            local vis_start = math.max(wave_x, sel_px_start)
            local vis_end = math.min(wave_x + waveform_width, sel_px_end)

            if vis_end > vis_start then
              local COLOR_SELECTION = 0x4A90D933
              reaper.ImGui_DrawList_AddRectFilled(draw_list, vis_start, wave_y, vis_end, wave_y + waveform_height, COLOR_SELECTION)
            end

            local arrow_size = 6
            local COLOR_SELECTION_ARROW = 0x888888FF

            if sel_px_start >= wave_x - arrow_size and sel_px_start <= wave_x + waveform_width + arrow_size then
              reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
                sel_px_start, ruler_y + config.RULER_HEIGHT - arrow_size * 2,
                sel_px_start, ruler_y + config.RULER_HEIGHT,
                sel_px_start + arrow_size, ruler_y + config.RULER_HEIGHT - arrow_size,
                COLOR_SELECTION_ARROW)
            end

            if sel_px_end >= wave_x - arrow_size and sel_px_end <= wave_x + waveform_width + arrow_size then
              reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
                sel_px_end, ruler_y + config.RULER_HEIGHT - arrow_size * 2,
                sel_px_end, ruler_y + config.RULER_HEIGHT,
                sel_px_end - arrow_size, ruler_y + config.RULER_HEIGHT - arrow_size,
                COLOR_SELECTION_ARROW)
            end
          end

          -- Left panel controls
          local COLOR_LEFT_COL_BG = 0x1A1A1AFF
          reaper.ImGui_DrawList_AddRectFilled(draw_list, left_col_x, left_col_y, left_col_x + config.LEFT_COLUMN_WIDTH - 2, left_col_y + panel_height, COLOR_LEFT_COL_BG)

          controls.draw_button_panel(ctx, draw_list, mouse_x, mouse_y, left_col_x, left_col_y, item, take, config, state, utils, drawing)

          local COLOR_PANEL_BG = 0x202020FF
          reaper.ImGui_DrawList_AddRectFilled(draw_list, panel_x, panel_y, panel_x + config.LEFT_PANEL_WIDTH - 4, panel_y + panel_height, COLOR_PANEL_BG)
          local panel_split = panel_y + panel_height * 0.55

          controls.draw_gain_slider(ctx, draw_list, mouse_x, mouse_y, panel_x, panel_y, panel_split, item, item_vol, config, state, utils)

          local take_pitch, knob_cx, knob_cy = controls.draw_pitch_knob(ctx, draw_list, mouse_x, mouse_y, panel_x, panel_split, panel_y + panel_height, take, config, state, utils, drawing)

          controls.draw_semitones_cents_boxes(ctx, draw_list, mouse_x, mouse_y, panel_x, knob_cy, take, take_pitch, config, state, utils)

          -- Hide and lock cursor while dragging any control
          if state.is_any_control_dragging() then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_None())
            if state.has_js_extension then
              local cur_screen_x, cur_screen_y = reaper.GetMousePosition()
              -- Initialize last_screen_y if not set (defensive)
              state.drag_last_screen_y = state.drag_last_screen_y or cur_screen_y
              -- Calculate delta from last frame's position (not lock position)
              -- This avoids issues with cursor teleport timing
              local delta = state.drag_last_screen_y - cur_screen_y
              if delta ~= 0 then
                state.drag_cumulative_delta_y = state.drag_cumulative_delta_y + delta
              end
              -- Update last position and teleport cursor back to lock position
              state.drag_last_screen_y = state.drag_lock_screen_y
              reaper.JS_Mouse_SetPosition(state.drag_lock_screen_x, state.drag_lock_screen_y)
            end
          end

          -- Marker positions
          local start_marker_x = wave_x + start_px
          local end_marker_x = wave_x + end_px

          -- Mouse interaction areas
          local mouse_in_waveform = mouse_x >= wave_x and mouse_x <= wave_x + waveform_width
                                    and mouse_y >= wave_y and mouse_y <= wave_y + waveform_height
          local mouse_in_ruler = mouse_x >= wave_x and mouse_x <= wave_x + waveform_width
                                 and mouse_y >= ruler_y and mouse_y <= ruler_y + config.RULER_HEIGHT
          local mouse_in_time_ruler = mouse_x >= wave_x and mouse_x <= wave_x + waveform_width
                                 and mouse_y >= time_ruler_y and mouse_y <= time_ruler_y + config.TIME_RULER_HEIGHT
          local mouse_in_view = mouse_x >= wave_x and mouse_x <= wave_x + waveform_width
                                and mouse_y >= ruler_y and mouse_y <= time_ruler_y + config.TIME_RULER_HEIGHT
          local mouse_in_marker_area = mouse_x >= wave_x - config.MARKER_WIDTH and mouse_x <= wave_x + waveform_width + config.MARKER_WIDTH
                                    and mouse_y >= wave_y and mouse_y <= wave_y + waveform_height

          local near_start = utils.is_near_marker(mouse_x, start_marker_x, config.MARKER_WIDTH)
          local near_end = utils.is_near_marker(mouse_x, end_marker_x, config.MARKER_WIDTH)

          -- Cursor feedback
          local alt_held = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Alt())
          if (state.dragging_start or state.dragging_end) and alt_held then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeAll())
          elseif mouse_in_marker_area and (near_start or near_end) then
            if alt_held then
              reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeAll())
            else
              reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeEW())
            end
          elseif mouse_in_ruler or state.is_ruler_dragging then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeEW())
          elseif state.is_panning then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeAll())
          end

          -- Zoom helpers - constrained to source bounds (0 to source_length)
          local zoom_base_view_length = source_length
          local range_center = source_length / 2

          -- Min zoom = 1.0 (shows full source), max zoom = 500
          local min_zoom = 1.0

          local function zoom_to_cursor(new_zoom, cursor_x)
            local cursor_fraction = (cursor_x - wave_x) / waveform_width
            cursor_fraction = math.max(0, math.min(1, cursor_fraction))

            local time_under_cursor = view_start + cursor_fraction * view_length

            state.zoom_level = math.max(min_zoom, math.min(500.0, new_zoom))

            local new_view_length = zoom_base_view_length / state.zoom_level

            state.pan_offset = time_under_cursor - range_center + new_view_length * (0.5 - cursor_fraction)

            -- Clamp pan to keep view within source bounds (0 to source_length)
            local half_view = new_view_length / 2
            local min_pan = -range_center + half_view  -- view_start = 0
            local max_pan = source_length - range_center - half_view  -- view_end = source_length
            if min_pan > max_pan then min_pan, max_pan = max_pan, min_pan end
            state.pan_offset = math.max(min_pan, math.min(max_pan, state.pan_offset))
          end

          -- Ctrl+mouse wheel zoom
          local wheel = reaper.ImGui_GetMouseWheel(ctx)
          if wheel ~= 0 and mouse_in_view then
            local ctrl_down = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())
            if ctrl_down then
              local zoom_factor = 1.35
              local new_zoom = wheel > 0 and (state.zoom_level * zoom_factor) or (state.zoom_level / zoom_factor)
              zoom_to_cursor(new_zoom, mouse_x)
            end
          end

          -- Ruler drag zoom + pan
          if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_ruler then
            state.is_ruler_dragging = true
            state.ruler_drag_start_y = mouse_y
            state.ruler_drag_start_zoom = state.zoom_level
            state.ruler_drag_cumulative_y = 0
            state.ruler_drag_start_pan = state.pan_offset
            state.ruler_drag_window_x = mouse_x  -- Store window-space X for zoom centering
            if state.has_js_extension then
              local screen_x, screen_y = reaper.GetMousePosition()
              state.ruler_drag_screen_x = screen_x
              state.ruler_drag_screen_y = screen_y
              state.ruler_drag_cursor_x = screen_x  -- Tracks visible cursor X position
            end
          end

          if reaper.ImGui_IsMouseReleased(ctx, 0) then
            state.is_ruler_dragging = false
          end

          if state.is_ruler_dragging and reaper.ImGui_IsMouseDown(ctx, 0) then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_None())
            if state.has_js_extension then
              local cur_screen_x, cur_screen_y = reaper.GetMousePosition()
              local delta_x = cur_screen_x - state.ruler_drag_screen_x
              local delta_y = cur_screen_y - state.ruler_drag_screen_y

              -- Accumulate Y for zoom
              state.ruler_drag_cumulative_y = state.ruler_drag_cumulative_y + delta_y

              -- Apply zoom centered on initial cursor position
              local zoom_sensitivity = 0.008
              local zoom_multiplier = 1.0 + (state.ruler_drag_cumulative_y * zoom_sensitivity)
              local new_zoom = math.max(1.0, state.ruler_drag_start_zoom * zoom_multiplier)
              zoom_to_cursor(new_zoom, state.ruler_drag_window_x)

              -- Check if we can pan (zoomed in)
              local can_pan = state.zoom_level > 1.0

              -- Apply additional pan from X movement
              if can_pan and delta_x ~= 0 then
                local new_view_length = zoom_base_view_length / state.zoom_level
                local pan_sensitivity = new_view_length / waveform_width  -- Time per pixel at current zoom
                state.pan_offset = state.pan_offset - (delta_x * pan_sensitivity)

                -- Clamp pan to valid range
                local half_view = new_view_length / 2
                local min_pan = -range_center + half_view
                local max_pan = source_length - range_center - half_view
                if min_pan > max_pan then min_pan, max_pan = max_pan, min_pan end
                state.pan_offset = math.max(min_pan, math.min(max_pan, state.pan_offset))
              end

              -- Calculate cursor X position in screen coords
              local win_x, win_y = reaper.ImGui_GetWindowPos(ctx)
              local wave_screen_left = win_x + wave_x - cursor_x + config.WINDOW_PADDING
              local wave_screen_right = wave_screen_left + waveform_width

              local target_cursor_x = state.ruler_drag_cursor_x
              if can_pan then
                -- Move cursor X with mouse, but clamp to waveform bounds
                target_cursor_x = target_cursor_x + delta_x
                target_cursor_x = math.max(wave_screen_left, math.min(wave_screen_right, target_cursor_x))
                state.ruler_drag_cursor_x = target_cursor_x
              end
              -- If can't pan, cursor X stays locked at ruler_drag_cursor_x

              -- Set cursor position: X can move (within bounds), Y is locked
              reaper.JS_Mouse_SetPosition(math.floor(state.ruler_drag_cursor_x), state.ruler_drag_screen_y)

              -- Update reference X for next frame's delta calculation
              state.ruler_drag_screen_x = math.floor(state.ruler_drag_cursor_x)
            else
              local delta_y = mouse_y - state.ruler_drag_start_y
              local zoom_sensitivity = 0.008
              local zoom_multiplier = 1.0 + (delta_y * zoom_sensitivity)
              local new_zoom = state.ruler_drag_start_zoom * zoom_multiplier
              zoom_to_cursor(new_zoom, mouse_x)
            end
          end

          -- Middle mouse panning
          local middle_mouse = 2
          if reaper.ImGui_IsMouseClicked(ctx, middle_mouse) and mouse_in_waveform then
            state.is_panning = true
            state.pan_start_mouse_x = mouse_x
            state.pan_start_offset = state.pan_offset
          end

          if reaper.ImGui_IsMouseReleased(ctx, middle_mouse) then
            state.is_panning = false
          end

          if state.is_panning and reaper.ImGui_IsMouseDown(ctx, middle_mouse) then
            local mouse_delta_px = mouse_x - state.pan_start_mouse_x
            local delta_time = -(mouse_delta_px / waveform_width) * view_length
            state.pan_offset = state.pan_start_offset + delta_time
            -- Pan limits: keep view within source bounds (0 to source_length)
            local half_view = view_length / 2
            local min_pan = -range_center + half_view
            local max_pan = source_length - range_center - half_view
            if min_pan > max_pan then min_pan, max_pan = max_pan, min_pan end
            state.pan_offset = math.max(min_pan, math.min(max_pan, state.pan_offset))
          end

          -- Start dragging
          if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_marker_area then
            if near_start then
              state.dragging_start = true
              state.drag_start_offset = start_offset
              state.drag_start_length = item_length
              state.drag_start_mouse_x = mouse_x
              state.drag_start_view_length = view_length
              state.drag_start_view_start = view_start
              state.drag_start_playrate = playrate
              state.drag_current_start = start_offset
              state.drag_current_end = start_offset + source_item_length
              if not state.undo_block_open then
                state.undo_block_open = "marker_start"
              end
            elseif near_end then
              state.dragging_end = true
              state.drag_start_offset = start_offset
              state.drag_start_length = item_length
              state.drag_start_mouse_x = mouse_x
              state.drag_start_view_length = view_length
              state.drag_start_view_start = view_start
              state.drag_start_playrate = playrate
              state.drag_current_start = start_offset
              state.drag_current_end = start_offset + source_item_length
              if not state.undo_block_open then
                state.undo_block_open = "marker_end"
              end
            end
          end

          -- End dragging
          if reaper.ImGui_IsMouseReleased(ctx, 0) then
            if state.dragging_start or state.dragging_end then
              local old_item_length = state.drag_start_length * state.drag_start_playrate
              local new_item_length = source_item_length
              local old_item_end = state.drag_start_offset + old_item_length
              local new_item_end = start_offset + new_item_length

              local old_left = math.min(0, state.drag_start_offset)
              local old_right = math.max(source_length, old_item_end)
              local old_range_center = (old_left + old_right) / 2
              local old_base = old_right - old_left

              local new_left = math.min(0, start_offset)
              local new_right = math.max(source_length, new_item_end)
              local new_range_center = (new_left + new_right) / 2
              local new_base = new_right - new_left

              local old_view_length = old_base / state.zoom_level
              local new_view_length = new_base / state.zoom_level

              state.pan_offset = state.pan_offset + (old_range_center - new_range_center) + (new_view_length - old_view_length) / 2
            end
            state.dragging_start = false
            state.dragging_end = false
          end

          -- Mouse button 4/5 quick marker positioning
          if mouse_in_waveform or mouse_in_marker_area then
            local clicked_mouse4 = reaper.ImGui_IsMouseClicked(ctx, 4)
            local clicked_mouse5 = reaper.ImGui_IsMouseClicked(ctx, 3)

            if clicked_mouse4 or clicked_mouse5 then
              local click_time = px_to_time(mouse_x)
              local current_end = start_offset + source_item_length

              reaper.Undo_BeginBlock()

              if clicked_mouse4 then
                local new_start = click_time
                new_start = math.min(new_start, current_end - 0.01)
                local new_source_length = current_end - new_start
                local new_item_length = new_source_length / playrate
                local new_take_offset = new_start - section_offset

                reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", new_take_offset)
                reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_item_length)
                reaper.UpdateArrange()
                reaper.Undo_EndBlock("NVSD_ItemView: Set start marker", -1)

              elseif clicked_mouse5 then
                local new_end = click_time
                new_end = math.max(new_end, start_offset + 0.01)
                local new_source_length = new_end - start_offset
                local new_item_length = new_source_length / playrate

                reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_item_length)
                reaper.UpdateArrange()
                reaper.Undo_EndBlock("NVSD_ItemView: Set end marker", -1)
              end
            end
          end

          -- Helper: snap time to nearest source boundary
          local function snap_to_source_boundary(t, src_len, threshold_time)
            local nearest_boundary = math.floor(t / src_len + 0.5) * src_len
            if math.abs(t - nearest_boundary) <= threshold_time then
              return nearest_boundary
            end
            return t
          end

          -- Helper: snap source time to REAPER grid
          local function snap_to_grid_if_enabled(source_t)
            local snap_enabled = reaper.GetToggleCommandState(1157) == 1
            if not snap_enabled then return source_t end

            local project_t = utils.source_to_project_time(source_t, item_position, start_offset, playrate)
            local snapped_project_t = reaper.SnapToGrid(0, project_t)
            return utils.project_to_source_time(snapped_project_t, item_position, start_offset, playrate)
          end

          local snap_threshold_time = (config.SNAP_THRESHOLD_PX / waveform_width) * view_length

          local alt_held = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Alt())

          -- Alt+drag: slide both markers
          if (state.dragging_start or state.dragging_end) and alt_held and reaper.ImGui_IsMouseDown(ctx, 0) then
            local mouse_delta_px = mouse_x - state.drag_start_mouse_x
            local mouse_delta_time = (mouse_delta_px / waveform_width) * state.drag_start_view_length

            local original_source_length = state.drag_start_length * state.drag_start_playrate

            local raw_start = state.drag_start_offset + mouse_delta_time
            local raw_end = raw_start + original_source_length

            local new_start
            local snapped_to_boundary = false

            if state.dragging_start then
              local start_snapped = snap_to_source_boundary(raw_start, source_length, snap_threshold_time)
              if start_snapped ~= raw_start then
                new_start = start_snapped
                snapped_to_boundary = true
              else
                new_start = snap_to_grid_if_enabled(raw_start)
              end
            else
              local end_snapped = snap_to_source_boundary(raw_end, source_length, snap_threshold_time)
              if end_snapped ~= raw_end then
                new_start = end_snapped - original_source_length
                snapped_to_boundary = true
              else
                new_start = snap_to_grid_if_enabled(raw_start)
              end
            end

            local new_end = new_start + original_source_length

            -- Clamp to source boundaries (keep item length constant)
            if new_start < 0 then
              new_start = 0
              new_end = original_source_length
            end
            if new_end > source_length then
              new_end = source_length
              new_start = source_length - original_source_length
            end

            local new_take_offset = new_start - section_offset

            state.drag_current_start = new_start
            state.drag_current_end = new_end

            reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", new_take_offset)
            reaper.UpdateArrange()

          -- Dragging start marker
          elseif state.dragging_start and reaper.ImGui_IsMouseDown(ctx, 0) then
            local original_source_end = state.drag_start_offset + (state.drag_start_length * state.drag_start_playrate)
            local new_start
            if mouse_x >= wave_x and mouse_x <= wave_x + waveform_width then
              new_start = px_to_time(mouse_x)
            else
              local edge_time = mouse_x < wave_x and view_start or view_start + view_length
              local overflow_px = mouse_x < wave_x and (wave_x - mouse_x) or (mouse_x - wave_x - waveform_width)
              local overflow_time = (overflow_px / waveform_width) * source_length
              new_start = mouse_x < wave_x and (edge_time - overflow_time) or (edge_time + overflow_time)
            end
            new_start = snap_to_grid_if_enabled(new_start)
            new_start = snap_to_source_boundary(new_start, source_length, snap_threshold_time)
            new_start = math.min(new_start, original_source_end - 0.01)
            local new_source_length = original_source_end - new_start
            local new_item_length = new_source_length / state.drag_start_playrate
            local new_take_offset = new_start - section_offset

            state.drag_current_start = new_start
            state.drag_current_end = original_source_end

            reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", new_take_offset)
            reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_item_length)
            reaper.UpdateArrange()

          -- Dragging end marker
          elseif state.dragging_end and reaper.ImGui_IsMouseDown(ctx, 0) then
            local new_end
            if mouse_x >= wave_x and mouse_x <= wave_x + waveform_width then
              new_end = px_to_time(mouse_x)
            else
              local edge_time = mouse_x < wave_x and view_start or view_start + view_length
              local overflow_px = mouse_x < wave_x and (wave_x - mouse_x) or (mouse_x - wave_x - waveform_width)
              local overflow_time = (overflow_px / waveform_width) * source_length
              new_end = mouse_x < wave_x and (edge_time - overflow_time) or (edge_time + overflow_time)
            end
            new_end = snap_to_grid_if_enabled(new_end)
            new_end = snap_to_source_boundary(new_end, source_length, snap_threshold_time)
            local new_source_length = new_end - state.drag_start_offset
            local new_item_length = new_source_length / state.drag_start_playrate
            new_item_length = math.max(0.01, new_item_length)

            state.drag_current_start = state.drag_start_offset
            state.drag_current_end = new_end

            reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_item_length)
            reaper.UpdateArrange()
          end

          -- Draw markers on top
          if start_marker_x >= wave_x - config.MARKER_WIDTH and start_marker_x <= wave_x + waveform_width + config.MARKER_WIDTH then
            drawing.draw_marker(draw_list, start_marker_x, wave_y, waveform_height, true, near_start, state.dragging_start, config)
          end
          if end_marker_x >= wave_x - config.MARKER_WIDTH and end_marker_x <= wave_x + waveform_width + config.MARKER_WIDTH then
            drawing.draw_marker(draw_list, end_marker_x, wave_y, waveform_height, false, near_end, state.dragging_end, config)
          end

          -- Draw playhead on top of everything
          local play_state = reaper.GetPlayState()
          if play_state & 5 ~= 0 then -- playing (1) or recording (4+1)
            local play_pos = reaper.GetPlayPosition()
            local playhead_source = utils.project_to_source_time(play_pos, item_position, start_offset, playrate)
            local playhead_px = time_to_px(playhead_source)
            if playhead_px >= wave_x and playhead_px <= wave_x + waveform_width then
              drawing.draw_playhead(draw_list, playhead_px, wave_y, waveform_height, config)
            end
          end

        else
          reaper.ImGui_Text(ctx, "No audio source found")
        end
      else
        reaper.ImGui_Text(ctx, take and reaper.TakeIsMIDI(take) and "MIDI items not supported" or "No valid take")
      end
    else
      local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
      local text = "No item selected."
      local text_w = reaper.ImGui_CalcTextSize(ctx, text)
      local text_h = 13
      local center_x = (avail_w - text_w) / 2
      local center_y = (avail_h - text_h) / 2
      reaper.ImGui_SetCursorPos(ctx, center_x, center_y)
      reaper.ImGui_TextColored(ctx, 0x888888FF, text)
    end

    reaper.ImGui_End(ctx)
  end

  reaper.ImGui_PopStyleVar(ctx)

  if open then
    reaper.defer(loop)
  end
end

reaper.defer(loop)
