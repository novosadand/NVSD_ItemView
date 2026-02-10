-- @description NVSD ItemView - Ableton-style clip view for REAPER items
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
local lib_files = {"config", "state", "utils", "drawing", "controls", "settings", "settings_ui"}
local initial_lib_sizes = {}
for _, name in ipairs(lib_files) do
  initial_lib_sizes[name] = get_file_size(script_dir .. "/lib/" .. name .. ".lua")
end
local reload_check_counter = 0
local should_reload = false

-- Create a take envelope via state chunk if action-based creation fails
local function ensure_take_envelope(item, take, env_name)
  local env = reaper.GetTakeEnvelopeByName(take, env_name)
  if env then return env end
  -- Try action first
  reaper.SetMediaItemSelected(item, true)
  reaper.SetActiveTake(take)
  local action_id = (env_name == "Volume") and 40693 or 40714
  reaper.Main_OnCommand(action_id, 0)
  env = reaper.GetTakeEnvelopeByName(take, env_name)
  if env then return env end
  -- Fallback: inject envelope via item state chunk
  local chunk_tag = ({ Volume = "VOLENV2", Pitch = "PITCHENV", Pan = "PANENV2" })[env_name]
  if not chunk_tag then return nil end
  local _, chunk = reaper.GetItemStateChunk(item, "", false)
  -- Debug: write first 500 chars of chunk
  local dbg = io.open(script_dir .. "/env_chunk_debug.txt", "w")
  if dbg then
    dbg:write("=== CHUNK DEBUG ===\n")
    dbg:write("chunk_tag: " .. chunk_tag .. "\n")
    dbg:write("chunk_length: " .. #chunk .. "\n")
    dbg:write("has_tag: " .. tostring(chunk:find("<" .. chunk_tag) ~= nil) .. "\n")
    dbg:write("--- chunk (first 1500 chars) ---\n")
    dbg:write(chunk:sub(1, 1500) .. "\n")
    dbg:close()
  end
  if chunk:find("<" .. chunk_tag) then return reaper.GetTakeEnvelopeByName(take, env_name) end
  local env_chunk = "<" .. chunk_tag .. "\nACT 1 -1\nVIS 1 1 1\nLANEHEIGHT 0 0\nARM 0\nDEFSHAPE 0 -1 -1\nPT 0 0 0\n>\n"
  -- Find the item's closing > (last > in chunk) and insert before it
  local last_close = chunk:match(".*()>")
  if last_close then
    chunk = chunk:sub(1, last_close - 1) .. env_chunk .. chunk:sub(last_close)
    local ok = reaper.SetItemStateChunk(item, chunk, false)
    reaper.UpdateItemInProject(item)
    reaper.UpdateArrange()
    env = reaper.GetTakeEnvelopeByName(take, env_name)
    -- Debug result
    local dbg2 = io.open(script_dir .. "/env_chunk_debug.txt", "a")
    if dbg2 then
      dbg2:write("\n=== AFTER CHUNK SET ===\n")
      dbg2:write("SetItemStateChunk returned: " .. tostring(ok) .. "\n")
      dbg2:write("env after: " .. tostring(env ~= nil) .. "\n")
      local ne = reaper.CountTakeEnvelopes(take)
      dbg2:write("take_envelopes after: " .. tostring(ne) .. "\n")
      dbg2:write("--- new chunk (first 800) ---\n")
      local _, newchunk = reaper.GetItemStateChunk(item, "", false)
      dbg2:write(newchunk:sub(1, 800) .. "\n")
      dbg2:close()
    end
    return env
  end
  return nil
end

-- Check for ReaImGui
if not reaper.ImGui_CreateContext then
  reaper.MB("This script requires the ReaImGui extension.\nInstall it via ReaPack: Extensions > ReaPack > Browse packages > ReaImGui", "Missing Dependency", 0)
  return
end

-- Create ImGui context
local ctx = reaper.ImGui_CreateContext("NVSD_ItemView")
-- Attach a font to keep context alive across deferred frames (prevents GC on macOS)
if reaper.ImGui_CreateFont and reaper.ImGui_Attach then
  local font = reaper.ImGui_CreateFont('sans-serif', 13)
  reaper.ImGui_Attach(ctx, font)
end

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
  for _, name in ipairs(lib_files) do
    local current = get_file_size(script_dir .. "/lib/" .. name .. ".lua")
    if current ~= 0 and current ~= initial_lib_sizes[name] then
      return true
    end
  end
  return false
end

-- Dialog cooldown: skip frames after a dialog closes so REAPER's state can settle
local dialog_cooldown = 0

-- Main GUI function
local function loop()
  -- Skip frame entirely if a modal dialog is open (autosave, save-as, preferences, etc.)
  -- Modal dialogs take over REAPER's message loop; ImGui calls during this can crash at the C level.
  -- Also skip for a cooldown period after the dialog closes to let REAPER's state settle.
  -- Detect modal dialogs by checking if REAPER's main window is disabled.
  -- When any modal dialog is active (autosave, save-as, preferences, render, etc.)
  -- Windows disables the owner window. This is the most reliable detection method
  -- because it doesn't depend on identifying specific dialog windows.
  local main = reaper.GetMainHwnd()
  if main and reaper.JS_Window_GetLong then
    local style = reaper.JS_Window_GetLong(main, "STYLE")
    if style then
      local WS_DISABLED = 0x08000000
      if (style & WS_DISABLED) ~= 0 then
        dialog_cooldown = 30  -- ~0.5s at 60fps after dialog closes
        reaper.defer(loop)
        return
      end
    end
  end

  if dialog_cooldown > 0 then
    dialog_cooldown = dialog_cooldown - 1
    -- Reset stale state that may have been invalidated by the dialog
    if dialog_cooldown == 0 then
      -- Recreate context (it becomes invalid when no ImGui frames run during dialog)
      ctx = reaper.ImGui_CreateContext("NVSD_ItemView")
      if reaper.ImGui_CreateFont and reaper.ImGui_Attach then
        local font = reaper.ImGui_CreateFont('sans-serif', 13)
        reaper.ImGui_Attach(ctx, font)
      end
      state.sticky_item = nil
      state.sticky_item_valid = false
      state.dragging_start = false
      state.dragging_end = false
      state.dragging_fade_in = false
      state.dragging_fade_out = false
      state.dragging_fade_curve_in = false
      state.dragging_fade_curve_out = false
      state.is_panning = false
      state.is_ruler_dragging = false
      state.fx_dragging = false
      state.fx_drag_activated = false
      state.undo_block_open = nil
      state.was_mouse_down = false
      state.invalidate_view_peaks()
      -- Stop audio preview on dialog recovery
      if state.preview_active and state.preview_handle and reaper.CF_Preview_Stop then
        reaper.CF_Preview_Stop(state.preview_handle)
      end
      state.preview_handle = nil
      state.preview_active = false
      state.preview_start_requested = false
    end
    reaper.defer(loop)
    return
  end

  -- Everything below is wrapped in pcall to catch Lua-level errors.
  local open = true
  local needs_reload = false

  local ok, err = pcall(function()

  -- Track mouse state early (needed to gate expensive operations)
  -- Only track when REAPER is the active application (not Firefox, etc.)
  local mouse_is_down = false
  local reaper_is_active = true
  if reaper.JS_Window_GetForeground then
    local fg = reaper.JS_Window_GetForeground()
    local main = reaper.GetMainHwnd()
    if fg and main then
      if fg ~= main then
        local parent = reaper.JS_Window_GetParent(fg)
        if parent ~= main then
          reaper_is_active = false
        end
      end
    else
      -- fg or main is nil during transition - treat as inactive
      reaper_is_active = false
    end
  end
  if reaper_is_active and reaper.JS_Mouse_GetState then
    local mouse_state = reaper.JS_Mouse_GetState(1)
    mouse_is_down = (mouse_state & 1) ~= 0
  end

  -- Abort all drags/panning when REAPER loses focus to prevent stale ImGui mouse
  -- state from corrupting positions (ImGui_IsMouseDown/GetMousePos can return
  -- stale values on the transition frame)
  if not reaper_is_active then
    state.dragging_start = false
    state.dragging_end = false
    state.dragging_fade_in = false
    state.dragging_fade_out = false
    state.dragging_fade_curve_in = false
    state.dragging_fade_curve_out = false
    state.is_panning = false
    state.is_ruler_dragging = false
    state.fx_dragging = false
    state.fx_drag_activated = false
  end

  -- Auto-reload check (skip during mouse-down to avoid disk I/O lag)
  if not mouse_is_down and check_for_changes() then
    should_reload = true
  end

  if should_reload then
    needs_reload = true
    return
  end

  -- Window flags
  local window_flags = reaper.ImGui_WindowFlags_NoCollapse()
                     + reaper.ImGui_WindowFlags_NoScrollWithMouse()

  -- Add window padding
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), config.WINDOW_PADDING, config.WINDOW_PADDING)

  local visible
  visible, open = reaper.ImGui_Begin(ctx, "NVSD_ItemView", true, window_flags)

  if visible then
    -- Cache modifier key state once per frame (avoids repeated Lua→C bridge calls)
    local ctrl_held = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())
    local shift_held = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift())
    local alt_held = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Alt())

    -- Auto-focus window when hovered with Ctrl held (enables scroll-to-zoom without clicking first)
    local is_hovered = reaper.ImGui_IsWindowHovered(ctx, reaper.ImGui_HoveredFlags_ChildWindows())
    if reaper_is_active and is_hovered and ctrl_held and not reaper.ImGui_IsWindowFocused(ctx) then
      reaper.ImGui_SetWindowFocus(ctx)
    end

    -- Forward Space to REAPER transport (so playback works without clicking back to timeline)
    -- Ctrl+Space: toggle audio preview
    -- Plain Space while preview is playing: stop preview instead of toggling transport
    if reaper_is_active and not settings.listening and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Space()) then
      if ctrl_held and reaper.CF_CreatePreview then
        state.preview_start_requested = true  -- processed in item context where source is available
      elseif state.preview_active and state.preview_handle then
        reaper.CF_Preview_Stop(state.preview_handle)
        state.preview_handle = nil
        state.preview_active = false
      else
        reaper.Main_OnCommand(40044, 0)  -- Transport: Play/Stop
      end
    end

    -- Forward undo/redo to REAPER (universal, not configurable)
    if reaper_is_active and not settings.listening and ctrl_held then
      if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Z()) then
        reaper.Main_OnCommand(shift_held and 40030 or 40029, 0)  -- Shift: Redo, else Undo
      elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Y()) then
        reaper.Main_OnCommand(40030, 0)  -- Redo
      end
    end

    -- Zoom shortcuts
    if reaper_is_active and settings.check_shortcut(ctx, "zoom_in") then
      state.zoom_level = math.min(500.0, state.zoom_level * 1.5)
    elseif reaper_is_active and settings.check_shortcut(ctx, "zoom_out") then
      state.zoom_level = math.max(1.0, state.zoom_level / 1.5)
    elseif reaper_is_active and settings.check_shortcut(ctx, "reset_zoom") then
      state.zoom_level = 1.0
      state.pan_offset = 0
    end

    -- Ctrl+4: toggle envelope snap (pitch semitones)
    if reaper_is_active and ctrl_held and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_4()) then
      state.env_snap_enabled = not state.env_snap_enabled
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
        fade_in = "NVSD_ItemView: Adjust fade in",
        fade_out = "NVSD_ItemView: Adjust fade out",
        env_node = "NVSD_ItemView: Move envelope point",
        env_freehand = "NVSD_ItemView: Draw envelope freehand",
        env_tension = "NVSD_ItemView: Adjust envelope curve",
      }
      local msg = undo_messages[state.undo_block_open] or "NVSD_ItemView: Edit"
      reaper.Undo_OnStateChangeEx(msg, -1, -1)
      state.undo_block_open = nil
    end

    -- Get selected item
    local selected_item = reaper.GetSelectedMediaItem(0, 0)

    -- Clear sticky when selection changes (skip when REAPER is unfocused to prevent spurious resets)
    if reaper_is_active and selected_item ~= state.last_selected_item then
      state.sticky_item = nil
      state.sticky_item_valid = false
      state.sticky_validation_counter = 0
      -- Clear preview on item change
      if state.preview_active and state.preview_handle then
        reaper.CF_Preview_Stop(state.preview_handle)
      end
      state.preview_cursor_pos = nil
      state.preview_handle = nil
      state.preview_active = false
      state.preview_item = nil
      -- Auto-switch to Envelopes tab if the new item has active take envelopes
      if selected_item then
        local sel_take = reaper.GetActiveTake(selected_item)
        if sel_take then
          local vol_env = reaper.GetTakeEnvelopeByName(sel_take, "Volume")
          local pitch_env = reaper.GetTakeEnvelopeByName(sel_take, "Pitch")
          if vol_env or pitch_env then
            state.active_view_tab = "envelopes"
            -- Prefer Pitch if only Pitch exists, otherwise default to Volume
            if pitch_env and not vol_env then
              state.envelope_type = "Pitch"
            else
              state.envelope_type = "Volume"
            end
          end
        end
      end
    end
    if reaper_is_active then
      state.last_selected_item = selected_item
    end

    local item = nil

    -- Detect mouse button press/release (transitions)
    local mouse_just_pressed = mouse_is_down and not state.was_mouse_down
    local mouse_just_released = not mouse_is_down and state.was_mouse_down
    state.was_mouse_down = mouse_is_down

    -- Priority 1: On mouse press, check if over an item and make it sticky
    -- Only update sticky on initial click, not while dragging (prevents jumping to other items)
    if mouse_just_pressed then
      local mouse_screen_x, mouse_screen_y = reaper.GetMousePosition()
      local item_under_mouse, take_under_mouse = reaper.GetItemFromPoint(mouse_screen_x, mouse_screen_y, false)
      if item_under_mouse and reaper.ValidatePtr(item_under_mouse, "MediaItem*") then
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
      -- Skip expensive validation scan while mouse is held (avoid blocking REAPER)
      if not mouse_is_down then
        state.sticky_validation_counter = state.sticky_validation_counter + 1
        if state.sticky_validation_counter >= 10 then
          state.sticky_validation_counter = 0
          local num_items = reaper.CountMediaItems(0)
          -- Only do full scan when item count changed (deletion/addition)
          if num_items ~= state.last_item_count then
            state.last_item_count = num_items
            local still_valid = false
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
    -- Guard with reaper_is_active to prevent spurious clearing on alt-tab
    if reaper_is_active and not item then
      state.last_panned_item = nil
      state.last_zoomed_item = nil
    end

    -- Validate item pointer (may go stale during autosave, project load, or undo)
    -- Skip when REAPER is unfocused to prevent spurious invalidation
    if reaper_is_active and item and not reaper.ValidatePtr(item, "MediaItem*") then
      item = nil
      state.sticky_item = nil
      state.sticky_item_valid = false
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
          local saved_items = {}
          for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
            saved_items[#saved_items + 1] = reaper.GetSelectedMediaItem(0, i)
          end
          reaper.Undo_BeginBlock()
          reaper.SelectAllMediaItems(0, false)
          reaper.SetMediaItemSelected(item, true)
          reaper.Main_OnCommand(41051, 0)
          reaper.UpdateArrange()
          reaper.Undo_EndBlock("NVSD_ItemView: Reverse", -1)
          reaper.SelectAllMediaItems(0, false)
          for _, sel_item in ipairs(saved_items) do
            if reaper.ValidatePtr(sel_item, "MediaItem*") then
              reaper.SetMediaItemSelected(sel_item, true)
            end
          end
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
          local saved_items = {}
          for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
            saved_items[#saved_items + 1] = reaper.GetSelectedMediaItem(0, i)
          end
          reaper.Undo_BeginBlock()
          reaper.SelectAllMediaItems(0, false)
          reaper.SetMediaItemSelected(item, true)
          reaper.Main_OnCommand(40109, 0)
          reaper.Undo_EndBlock("NVSD_ItemView: Open in External Editor", -1)
          reaper.SelectAllMediaItems(0, false)
          for _, sel_item in ipairs(saved_items) do
            if reaper.ValidatePtr(sel_item, "MediaItem*") then
              reaper.SetMediaItemSelected(sel_item, true)
            end
          end
        end
      end

      if take and reaper.ValidatePtr(take, "MediaItem_Take*") and not reaper.TakeIsMIDI(take) then
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

        if source and reaper.ValidatePtr(source, "PCM_source*") then
          local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
          local item_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
          local take_offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
          local source_length = reaper.GetMediaSourceLength(source)

          local start_offset = section_offset + take_offset

          if source_length <= 0 then
            source_length = item_length
          end
          if source_length <= 0 then source_length = 0.001 end  -- Prevent division by zero

          local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
          if playrate == 0 then playrate = 1 end  -- Guard against division by zero
          local item_vol = reaper.GetMediaItemInfo_Value(item, "D_VOL")

          -- Fade values (use effective length: max of manual and auto-crossfade)
          local fade_in_len = math.max(
            reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN"),
            reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN_AUTO"))
          local fade_out_len = math.max(
            reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN"),
            reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN_AUTO"))
          local fade_in_shape = math.floor(reaper.GetMediaItemInfo_Value(item, "C_FADEINSHAPE") + 0.5)
          local fade_out_shape = math.floor(reaper.GetMediaItemInfo_Value(item, "C_FADEOUTSHAPE") + 0.5)
          local fade_in_dir = reaper.GetMediaItemInfo_Value(item, "D_FADEINDIR")
          local fade_out_dir = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTDIR")

          -- Get available space for waveform
          local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
          local envelope_bar_height = config.ENVELOPE_BAR_HEIGHT
          local waveform_height = math.max(50, avail_h - (config.WAVEFORM_MARGIN_V * 2) - config.INFO_BAR_HEIGHT - config.RULER_HEIGHT - config.TIME_RULER_HEIGHT - envelope_bar_height)
          local panel_height = config.INFO_BAR_HEIGHT + config.RULER_HEIGHT + waveform_height + config.TIME_RULER_HEIGHT + envelope_bar_height

          local total_left_width = config.LEFT_COLUMN_WIDTH + config.LEFT_PANEL_WIDTH
          local pitch_gutter = (state.active_view_tab == "envelopes" and state.envelope_type == "Pitch") and config.PITCH_LABEL_WIDTH or 0
          local waveform_width = math.max(100, avail_w - (config.WAVEFORM_MARGIN_H * 2) - total_left_width - pitch_gutter)

          local cursor_x, cursor_y = reaper.ImGui_GetCursorScreenPos(ctx)
          local left_col_x = cursor_x + config.WINDOW_PADDING
          local left_col_y = cursor_y + config.WAVEFORM_MARGIN_V
          local panel_x = left_col_x + config.LEFT_COLUMN_WIDTH
          local panel_y = cursor_y + config.WAVEFORM_MARGIN_V
          local wave_x = cursor_x + total_left_width + config.WAVEFORM_MARGIN_H + pitch_gutter
          local info_bar_y = cursor_y + config.WAVEFORM_MARGIN_V
          local ruler_y = info_bar_y + config.INFO_BAR_HEIGHT
          local wave_y = ruler_y + config.RULER_HEIGHT
          local time_ruler_y = wave_y + waveform_height
          local envelope_bar_y = time_ruler_y + config.TIME_RULER_HEIGHT

          -- Reserve the full area
          local total_height = config.WAVEFORM_MARGIN_V + config.INFO_BAR_HEIGHT + config.RULER_HEIGHT + waveform_height + config.TIME_RULER_HEIGHT + envelope_bar_height + config.WAVEFORM_MARGIN_V
          reaper.ImGui_InvisibleButton(ctx, "waveform_area", avail_w, math.max(avail_h, total_height))

          local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
          local source_item_length = item_length * playrate

          -- Check if take is reversed
          local is_reversed = false
          if reaper.BR_GetMediaSourceProperties and take then
            local retval, section, start_pos, length, fade, reverse = reaper.BR_GetMediaSourceProperties(take)
            if retval then is_reversed = reverse end
          end

          -- Handle deferred cache invalidation (reverse needs a frame for REAPER to apply)
          if state.pending_cache_invalidation > 0 then
            state.pending_cache_invalidation = state.pending_cache_invalidation - 1
            if state.pending_cache_invalidation == 0 then
              state.invalidate_view_peaks()
              drawing.invalidate_wf_cache()
            end
          end

          -- Check if user is dragging in REAPER (mouse button held outside our control)
          local we_are_dragging = state.dragging_start or state.dragging_end or state.is_panning
                                  or state.is_ruler_dragging or state.is_any_control_dragging()
                                  or state.dragging_fade_in or state.dragging_fade_out
                                  or state.dragging_fade_curve_in or state.dragging_fade_curve_out
                                  or state.fx_dragging or state.dragging_env_node
                                  or state.env_freehand_drawing or state.env_tension_dragging
          local user_dragging_in_reaper = mouse_is_down and not we_are_dragging

          -- Get file path (used by info bar)
          local file_path = reaper.GetMediaSourceFileName(source, "")

          -- Reset zoom and pan when item changes - show full source
          -- Skip when REAPER is unfocused to prevent view jumping on alt-tab
          if reaper_is_active and (item ~= state.last_zoomed_item or item ~= state.last_panned_item) then
            state.zoom_level = 1.0
            state.pan_offset = 0
            state.last_panned_item = item
            state.last_zoomed_item = item
          end

          -- Compute view bounds
          local view_length = source_length / state.zoom_level
          local view_center = source_length / 2 + state.pan_offset
          local view_start = view_center - view_length / 2
          local view_end = view_start + view_length
          if view_start < 0 then view_start = 0; view_end = view_length end
          if view_end > source_length then view_end = source_length; view_start = source_length - view_length end
          if view_start < 0 then view_start = 0 end
          view_length = view_end - view_start
          if view_length <= 0 then view_length = 0.001 end

          -- Per-view peak loading: load exactly screen-width peaks for the visible range.
          -- PCM_Source_GetPeaks uses pre-indexed .reapeaks files → <1ms regardless of file size.
          local pixel_step = user_dragging_in_reaper and 2 or 1
          local num_view_samples = math.max(1, math.floor(waveform_width / pixel_step))

          local need_reload = state.view_peaks == nil
              or source ~= state.view_source
              or is_reversed ~= state.view_reversed
              or view_start ~= state.view_start
              or view_length ~= state.view_length
              or num_view_samples ~= state.view_num_samples

          if need_reload and view_length > 0 then
            -- For reversed display, load peaks from the mirrored source range
            local peak_start = is_reversed and math.max(0, source_length - view_start - view_length) or view_start
            local peaks_result, num_ch = utils.get_peaks_for_range(source, peak_start, view_length, num_view_samples)
            if peaks_result then
              state.view_peaks = peaks_result
              state.view_num_channels = num_ch
              state.view_source = source
              state.view_start = view_start
              state.view_length = view_length
              state.view_reversed = is_reversed
              state.view_num_samples = num_view_samples
            end
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

          -- Grid line params (shared by grid lines and ruler)
          local grid_offset = (state.dragging_start or state.dragging_end) and state.drag_start_offset or start_offset
          local grid_playrate = (state.dragging_start or state.dragging_end) and state.drag_start_playrate or playrate
          local grid_view_start = (state.dragging_start or state.dragging_end) and state.drag_start_view_start or view_start

          -- Waveform background, then grid lines, then waveform on top
          reaper.ImGui_DrawList_AddRectFilled(draw_list, wave_x, wave_y, wave_x + waveform_width, wave_y + waveform_height, config.COLOR_WAVEFORM_BG)
          drawing.draw_grid_lines(draw_list, wave_x, wave_y, waveform_width, waveform_height,
            grid_view_start, view_length, item_position, grid_offset, grid_playrate, config, utils)

          local start_px, end_px = drawing.draw_waveform(draw_list, wave_x, wave_y,
            waveform_width, waveform_height,
            state.view_peaks, view_offset, view_item_length, source_length, view_start, view_length, ruler_y, item_vol, is_reversed, state.view_num_channels, config, pixel_step)

          -- Unified coordinate conversion (used by all subsequent code)
          local function time_to_px(t)
            return wave_x + ((t - view_start) / view_length) * waveform_width
          end

          local function px_to_time(px)
            return view_start + ((px - wave_x) / waveform_width) * view_length
          end

          -- Draw file info bar at the top (file_path already fetched above for caching)
          local _, gear_clicked, tab_clicked = drawing.draw_info_bar(draw_list, ctx, wave_x, info_bar_y, waveform_width, config.INFO_BAR_HEIGHT, source, file_path, mouse_x, mouse_y, item, config, utils, state.view_num_channels, state)

          -- Open settings when gear is clicked
          if gear_clicked then
            settings_ui.open(settings)
          end

          -- (Envelopes tab is always available, no auto-switch needed)

          -- Right-click menu (deferred: fade handle right-click checked after hover detection)
          local right_clicked = reaper_is_active and reaper.ImGui_IsMouseClicked(ctx, 1)
          local right_click_in_window = right_clicked and mouse_x >= cursor_x and mouse_x <= cursor_x + avail_w
                              and mouse_y >= cursor_y and mouse_y <= cursor_y + avail_h

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

          -- Draw ruler (ticks and labels, on top of waveform)
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

          -- Draw bottom bar (always visible, dropdown only on envelopes tab)
          drawing.draw_envelope_bar(draw_list, ctx, wave_x, envelope_bar_y,
            waveform_width, config.ENVELOPE_BAR_HEIGHT,
            mouse_x, mouse_y, config, state)

          -- Helper: snap time to nearest source boundary
          local function snap_to_source_boundary(t, src_len, threshold_time)
            if not state.env_snap_enabled then return t end
            local nearest_boundary = math.floor(t / src_len + 0.5) * src_len
            if math.abs(t - nearest_boundary) <= threshold_time then
              return nearest_boundary
            end
            return t
          end

          -- Helper: snap source time to finest visible grid subdivision
          -- snap_offset: override start_offset for snapping (use drag_start_offset during marker drags)
          local function snap_to_grid_if_enabled(source_t, snap_offset)
            if not state.env_snap_enabled then return source_t end
            local snap_enabled = reaper.GetToggleCommandState(1157) == 1
            if not snap_enabled then return source_t end

            local offset = snap_offset or start_offset
            local project_t = utils.source_to_project_time(source_t, item_position, offset, playrate)

            -- Compute finest visible grid subdivision (same logic as grid display)
            local bpm, bpi = reaper.GetProjectTimeSignature2(0, project_t)
            local beats_per_bar = math.floor(bpi)
            if beats_per_bar < 1 then beats_per_bar = 4 end
            local avg_bar_duration = 60 / bpm * beats_per_bar
            local px_per_bar = (avg_bar_duration / view_length) * waveform_width
            local px_per_beat = px_per_bar / beats_per_bar

            local finest_sub = 1
            while (px_per_beat / (finest_sub * 2)) >= 24 do
              finest_sub = finest_sub * 2
            end

            -- Snap in beat space: get beat position, round to nearest subdivision
            local snap_unit = 1 / finest_sub
            local beat_in_measure, measure = reaper.TimeMap2_timeToBeats(0, project_t)
            local snapped_beat = math.floor(beat_in_measure / snap_unit + 0.5) * snap_unit
            local snapped_measure = measure
            if snapped_beat >= beats_per_bar then
              snapped_beat = snapped_beat - beats_per_bar
              snapped_measure = measure + 1
            end

            local snapped_project_t = reaper.TimeMap2_beatsToTime(0, snapped_beat, snapped_measure)
            return utils.project_to_source_time(snapped_project_t, item_position, offset, playrate)
          end

          -- Draw envelope overlay when envelopes tab is active
          if state.active_view_tab == "envelopes" then
            -- Read envelope points from REAPER (raw values for fader-scaled display)
            local env_name = state.envelope_type == "Pitch" and "Pitch" or "Volume"
            local is_pitch = (state.envelope_type == "Pitch")
            local env = take and reaper.GetTakeEnvelopeByName(take, env_name)
            local env_points = {}
            local num_env_points = 0
            -- Default scaling: Volume=fader(1), Pitch=linear(0)
            local env_scaling = is_pitch and 0 or 1
            local env_max_raw = is_pitch and 24.0 or reaper.ScaleToEnvelopeMode(env_scaling, 2.0)
            local env_min_raw = is_pitch and -24.0 or 0
            if env then
              env_scaling = reaper.GetEnvelopeScalingMode(env)
              if not is_pitch then
                env_max_raw = reaper.ScaleToEnvelopeMode(env_scaling, 2.0)
              end
              num_env_points = reaper.CountEnvelopePoints(env)
              -- During any marker drag, freeze envelope to original offset
              -- so the envelope stays anchored to the same audio content visually.
              local env_time_offset = start_offset
              if (state.dragging_start or state.dragging_end) and state.marker_drag_activated then
                env_time_offset = state.drag_start_offset
              end
              for i = 0, num_env_points - 1 do
                local retval, ept_time, ept_value, ept_shape, ept_tension, ept_selected = reaper.GetEnvelopePoint(env, i)
                if retval then
                  -- Take envelope times are relative to item start (D_STARTOFFS).
                  -- Convert to source time by adding offset.
                  env_points[#env_points + 1] = { time = ept_time + env_time_offset, value = ept_value,
                                                   shape = ept_shape, tension = ept_tension, selected = ept_selected }
                end
              end
              num_env_points = #env_points
            end

            -- Draw envelope overlay on waveform
            drawing.draw_envelope_overlay(draw_list, ctx, env_points, num_env_points,
              wave_x, wave_y, waveform_width, waveform_height,
              time_to_px, view_start, view_length,
              mouse_x, mouse_y, config, state, source_length,
              env_scaling, env_max_raw, env_min_raw, is_pitch,
              snap_to_grid_if_enabled)

          end

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

          local buttons_bottom = controls.draw_button_panel(ctx, draw_list, mouse_x, mouse_y, left_col_x, left_col_y, item, take, config, state, utils, drawing)

          -- Draw FX toolbar and scrollable FX list below buttons
          local fx_toolbar_bottom = controls.draw_fx_toolbar(ctx, draw_list, mouse_x, mouse_y,
            left_col_x + 8, buttons_bottom + 6, config.LEFT_COLUMN_WIDTH - 16,
            take, config, state, drawing)
          local fx_area_top = fx_toolbar_bottom + 4
          local fx_area_height = (left_col_y + panel_height - 4) - fx_area_top
          controls.draw_fx_list(ctx, draw_list, mouse_x, mouse_y,
            left_col_x + 4, fx_area_top, config.LEFT_COLUMN_WIDTH - 10, fx_area_height,
            take, config, state, drawing)

          -- FX right-click context menu
          controls.draw_fx_context_menu(ctx, state)

          local COLOR_PANEL_BG = 0x202020FF
          reaper.ImGui_DrawList_AddRectFilled(draw_list, panel_x, panel_y, panel_x + config.LEFT_PANEL_WIDTH - 4, panel_y + panel_height, COLOR_PANEL_BG)
          local panel_split = panel_y + panel_height * 0.55

          controls.draw_gain_slider(ctx, draw_list, mouse_x, mouse_y, panel_x, panel_y, panel_split, item, item_vol, config, state, utils)

          local take_pitch, knob_cx, knob_cy = controls.draw_pitch_knob(ctx, draw_list, mouse_x, mouse_y, panel_x, panel_split, panel_y + panel_height, take, config, state, utils, drawing)

          controls.draw_semitones_cents_boxes(ctx, draw_list, mouse_x, mouse_y, panel_x, knob_cy, take, take_pitch, config, state, utils)

          -- Hide and lock cursor while dragging any control
          if state.is_any_control_dragging() then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_None())
            if state.has_js_extension and state.drag_lock_screen_x ~= 0 and state.drag_lock_screen_y ~= 0 then
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

          -- Mouse interaction areas (all false when REAPER isn't active, prevents stale mouse artifacts)
          local mouse_in_waveform = reaper_is_active
              and mouse_x >= wave_x and mouse_x <= wave_x + waveform_width
              and mouse_y >= wave_y and mouse_y <= wave_y + waveform_height
          local mouse_in_ruler = reaper_is_active
              and mouse_x >= wave_x and mouse_x <= wave_x + waveform_width
              and mouse_y >= ruler_y and mouse_y <= ruler_y + config.RULER_HEIGHT
          local mouse_in_time_ruler = reaper_is_active
              and mouse_x >= wave_x and mouse_x <= wave_x + waveform_width
              and mouse_y >= time_ruler_y and mouse_y <= time_ruler_y + config.TIME_RULER_HEIGHT
          local view_bottom = time_ruler_y + config.TIME_RULER_HEIGHT + envelope_bar_height
          local mouse_in_view = reaper_is_active
              and mouse_x >= wave_x and mouse_x <= wave_x + waveform_width
              and mouse_y >= ruler_y and mouse_y <= view_bottom
          -- Skip hover detection when REAPER isn't the active window (prevents stale mouse positions)
          local mouse_in_marker_area = reaper_is_active
              and mouse_x >= wave_x - config.MARKER_WIDTH and mouse_x <= wave_x + waveform_width + config.MARKER_WIDTH
              and mouse_y >= wave_y and mouse_y <= wave_y + waveform_height

          local near_start = reaper_is_active and utils.is_near_marker(mouse_x, start_marker_x, config.MARKER_WIDTH)
          local near_end = reaper_is_active and utils.is_near_marker(mouse_x, end_marker_x, config.MARKER_WIDTH)

          -- Fade handle positions (in source time, then to px)
          local fade_in_source_len = fade_in_len * playrate
          local fade_out_source_len = fade_out_len * playrate
          local fade_in_end_x = time_to_px(render_start + fade_in_source_len)
          local fade_out_start_x = time_to_px(render_end - fade_out_source_len)

          -- Fade grab zones
          -- When no fade exists: narrow top strip (20px) near marker boundary to create fades.
          -- When a fade exists: grabbable anywhere along the curve (±tolerance from curve Y at mouse X).
          local fade_grab_w = 22  -- horizontal extent for no-fade creation zone
          local fade_grab_sm = 4  -- small extent on opposite side
          local fade_grab_h_create = 20  -- top-only zone for creating new fades
          local fade_curve_tolerance = 20  -- px above/below curve for grab zone
          local fade_top_y = wave_y + 2  -- same as used for rendering
          -- Fade-in grab zone
          local near_fade_in = false
          if fade_in_len > 0 and reaper_is_active
              and not state.dragging_start and not state.dragging_end
              and not state.is_ruler_dragging and not state.is_panning then
            -- Fade exists: grab anywhere along the curve
            local fi_width = fade_in_end_x - start_marker_x
            if fi_width > 0 and mouse_x >= start_marker_x - fade_grab_sm and mouse_x <= fade_in_end_x + fade_grab_sm then
              local fi_t = math.max(0, math.min(1, (mouse_x - start_marker_x) / fi_width))
              local fi_curve_y = drawing.get_fade_curve_y(fi_t, fade_in_shape, true, fade_in_dir, fade_top_y, wave_y, waveform_height)
              near_fade_in = math.abs(mouse_y - fi_curve_y) <= fade_curve_tolerance
            end
          elseif reaper_is_active and not state.dragging_start and not state.dragging_end
              and not state.is_ruler_dragging and not state.is_panning then
            -- No fade: narrow top strip near marker for creation
            near_fade_in = mouse_y >= wave_y and mouse_y <= wave_y + fade_grab_h_create
                and mouse_x >= fade_in_end_x - fade_grab_sm
                and mouse_x <= fade_in_end_x + fade_grab_w
          end
          -- Fade-out grab zone
          local near_fade_out = false
          if fade_out_len > 0 and reaper_is_active
              and not state.dragging_start and not state.dragging_end
              and not state.is_ruler_dragging and not state.is_panning then
            local fo_width = end_marker_x - fade_out_start_x
            if fo_width > 0 and mouse_x >= fade_out_start_x - fade_grab_sm and mouse_x <= end_marker_x + fade_grab_sm then
              local fo_t = math.max(0, math.min(1, (mouse_x - fade_out_start_x) / fo_width))
              local fo_curve_y = drawing.get_fade_curve_y(fo_t, fade_out_shape, false, fade_out_dir, fade_top_y, wave_y, waveform_height)
              near_fade_out = math.abs(mouse_y - fo_curve_y) <= fade_curve_tolerance
            end
          elseif reaper_is_active and not state.dragging_start and not state.dragging_end
              and not state.is_ruler_dragging and not state.is_panning then
            near_fade_out = mouse_y >= wave_y and mouse_y <= wave_y + fade_grab_h_create
                and mouse_x >= fade_out_start_x - fade_grab_w
                and mouse_x <= fade_out_start_x + fade_grab_sm
          end
          -- Disambiguate when both zones overlap (fades close or touching)
          if near_fade_in and near_fade_out then
            if fade_in_len == 0 and fade_out_len > 0 then
              -- Fade-in doesn't exist, fade-out does.
              -- Top 8px at marker corner = create fade-in, rest = adjust fade-out
              if mouse_y <= wave_y + 8 and math.abs(mouse_x - start_marker_x) <= fade_grab_sm + 2 then
                near_fade_out = false
              else
                near_fade_in = false
              end
            elseif fade_out_len == 0 and fade_in_len > 0 then
              -- Fade-out doesn't exist, fade-in does.
              -- Top 8px at marker corner = create fade-out, rest = adjust fade-in
              if mouse_y <= wave_y + 8 and math.abs(mouse_x - end_marker_x) <= fade_grab_sm + 2 then
                near_fade_in = false
              else
                near_fade_out = false
              end
            else
              -- Both exist or both don't: closest boundary wins
              local dist_fi = math.abs(mouse_x - fade_in_end_x)
              local dist_fo = math.abs(mouse_x - fade_out_start_x)
              if dist_fi <= dist_fo then
                near_fade_out = false
              else
                near_fade_in = false
              end
            end
          end
          -- Only update hover state when REAPER is active (preserves visual state on alt-tab)
          if reaper_is_active then
            state.fade_in_hovered = near_fade_in
            state.fade_out_hovered = near_fade_out
          end

          -- Fade body hover detection (near the curve line, for alt+drag curvature and cursor)
          local mouse_in_fade_in_body = false
          if fade_in_len > 0 and reaper_is_active
              and mouse_x >= start_marker_x and mouse_x <= fade_in_end_x then
            local fi_width = fade_in_end_x - start_marker_x
            if fi_width > 0 then
              local fi_t = math.max(0, math.min(1, (mouse_x - start_marker_x) / fi_width))
              local fi_curve_y = drawing.get_fade_curve_y(fi_t, fade_in_shape, true, fade_in_dir, fade_top_y, wave_y, waveform_height)
              mouse_in_fade_in_body = math.abs(mouse_y - fi_curve_y) <= fade_curve_tolerance
            end
          end
          local mouse_in_fade_out_body = false
          if fade_out_len > 0 and reaper_is_active
              and mouse_x >= fade_out_start_x and mouse_x <= end_marker_x then
            local fo_width = end_marker_x - fade_out_start_x
            if fo_width > 0 then
              local fo_t = math.max(0, math.min(1, (mouse_x - fade_out_start_x) / fo_width))
              local fo_curve_y = drawing.get_fade_curve_y(fo_t, fade_out_shape, false, fade_out_dir, fade_top_y, wave_y, waveform_height)
              mouse_in_fade_out_body = math.abs(mouse_y - fo_curve_y) <= fade_curve_tolerance
            end
          end

          -- Cursor feedback (alt_held cached at top of frame)
          -- Fade grabs use Hand cursor to distinguish from marker's ResizeEW
          if state.dragging_fade_curve_in or state.dragging_fade_curve_out or state.env_tension_dragging then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_None())
          elseif state.dragging_fade_in or state.dragging_fade_out then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
          elseif alt_held and reaper_is_active and (mouse_in_fade_in_body or mouse_in_fade_out_body) then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeNS())
          elseif near_fade_in or near_fade_out then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
          elseif (state.dragging_start or state.dragging_end) and alt_held then
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
          elseif state.active_view_tab == "envelopes" and alt_held and reaper_is_active
              and state.env_node_hovered_idx >= 0 then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_NotAllowed())
          elseif state.active_view_tab == "envelopes" and alt_held and reaper_is_active
              and state.envelope_hovered_segment >= 0 and state.env_node_hovered_idx < 0 then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeNS())
          elseif state.active_view_tab == "envelopes" and mouse_in_waveform
              and reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl()) then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
          end

          -- Right-click: fade shape menus or generic context menu
          -- Skip if the FX context menu was opened this frame (by draw_fx_list)
          local fx_menu_opened = right_clicked and reaper.ImGui_IsPopupOpen(ctx, "fx_context_menu")
          if right_click_in_window and not fx_menu_opened then
            if near_fade_in then
              reaper.ImGui_OpenPopup(ctx, "fade_in_shape_menu")
            elseif near_fade_out then
              reaper.ImGui_OpenPopup(ctx, "fade_out_shape_menu")
            else
              reaper.ImGui_OpenPopup(ctx, "context_menu")
            end
          end

          if reaper.ImGui_BeginPopup(ctx, "context_menu") then
            if reaper.ImGui_MenuItem(ctx, "Settings...") then
              settings_ui.open(settings)
            end
            reaper.ImGui_EndPopup(ctx)
          end

          local icon_w, icon_h = 60, 20
          local icon_pad = 4
          local icon_item_w = icon_w + icon_pad * 2
          local icon_item_h = icon_h + icon_pad * 2

          if reaper.ImGui_BeginPopup(ctx, "fade_in_shape_menu") then
            local popup_dl = reaper.ImGui_GetWindowDrawList(ctx)
            for i = 0, 6 do
              local selected = (fade_in_shape == i)
              local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
              if reaper.ImGui_Selectable(ctx, "##fadein" .. i, selected, 0, icon_item_w, icon_item_h) then
                reaper.Undo_BeginBlock()
                local cur_dir = reaper.GetMediaItemInfo_Value(item, "D_FADEINDIR")
                reaper.SetMediaItemInfo_Value(item, "C_FADEINSHAPE", i)
                reaper.SetMediaItemInfo_Value(item, "D_FADEINDIR", cur_dir)
                reaper.UpdateArrange()
                reaper.Undo_EndBlock("NVSD_ItemView: Change fade in shape", 4)
              end
              drawing.draw_fade_shape_icon(popup_dl, cx + icon_pad, cy + icon_pad, icon_w, icon_h, i, true)
            end
            reaper.ImGui_EndPopup(ctx)
          end

          if reaper.ImGui_BeginPopup(ctx, "fade_out_shape_menu") then
            local popup_dl = reaper.ImGui_GetWindowDrawList(ctx)
            for i = 0, 6 do
              local selected = (fade_out_shape == i)
              local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
              if reaper.ImGui_Selectable(ctx, "##fadeout" .. i, selected, 0, icon_item_w, icon_item_h) then
                reaper.Undo_BeginBlock()
                local cur_dir = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTDIR")
                reaper.SetMediaItemInfo_Value(item, "C_FADEOUTSHAPE", i)
                reaper.SetMediaItemInfo_Value(item, "D_FADEOUTDIR", cur_dir)
                reaper.UpdateArrange()
                reaper.Undo_EndBlock("NVSD_ItemView: Change fade out shape", 4)
              end
              drawing.draw_fade_shape_icon(popup_dl, cx + icon_pad, cy + icon_pad, icon_w, icon_h, i, false)
            end
            reaper.ImGui_EndPopup(ctx)
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
            if ctrl_held then
              local zoom_factor = 1.15
              local new_zoom = wheel > 0 and (state.zoom_level * zoom_factor) or (state.zoom_level / zoom_factor)
              zoom_to_cursor(new_zoom, mouse_x)
            end
          end

          -- Ruler drag zoom + pan
          if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_ruler and not we_are_dragging then
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

          if state.is_ruler_dragging and reaper_is_active and reaper.ImGui_IsMouseDown(ctx, 0) then
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
          if reaper.ImGui_IsMouseClicked(ctx, middle_mouse) and mouse_in_waveform and not we_are_dragging then
            state.is_panning = true
            state.pan_start_mouse_x = mouse_x
            state.pan_start_offset = state.pan_offset
          end

          if reaper.ImGui_IsMouseReleased(ctx, middle_mouse) then
            state.is_panning = false
          end

          if state.is_panning and reaper_is_active and reaper.ImGui_IsMouseDown(ctx, middle_mouse) then
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

          -- Start fade curvature drag (alt+click inside fade body)
          if reaper.ImGui_IsMouseClicked(ctx, 0) and alt_held
              and not state.dragging_start and not state.dragging_end
              and not state.dragging_fade_in and not state.dragging_fade_out
              and not state.is_ruler_dragging and not state.is_panning then
            if mouse_in_fade_in_body then
              state.dragging_fade_curve_in = true
              state.fade_curve_drag_start_value = fade_in_dir
              state.fade_curve_cumulative_y = 0
              state.fade_curve_was_dragged = false
              if state.has_js_extension then
                local sx, sy = reaper.GetMousePosition()
                state.fade_curve_lock_x, state.fade_curve_lock_y = sx, sy
                state.fade_curve_last_y = sy
              end
              if not state.undo_block_open then
                state.undo_block_open = "fade_curve_in"
              end
            elseif mouse_in_fade_out_body then
              state.dragging_fade_curve_out = true
              state.fade_curve_drag_start_value = fade_out_dir
              state.fade_curve_cumulative_y = 0
              state.fade_curve_was_dragged = false
              if state.has_js_extension then
                local sx, sy = reaper.GetMousePosition()
                state.fade_curve_lock_x, state.fade_curve_lock_y = sx, sy
                state.fade_curve_last_y = sy
              end
              if not state.undo_block_open then
                state.undo_block_open = "fade_curve_out"
              end
            end
          end

          -- Start fade handle dragging (upper waveform area: fade handles win over markers)
          if reaper.ImGui_IsMouseClicked(ctx, 0) and not alt_held
              and not state.dragging_start and not state.dragging_end
              and not state.dragging_fade_curve_in and not state.dragging_fade_curve_out
              and not state.is_ruler_dragging and not state.is_panning then
            if near_fade_in then
              state.dragging_fade_in = true
              state.fade_drag_start_mouse_x = mouse_x
              state.fade_drag_start_value = fade_in_len
              state.fade_drag_start_other = fade_out_len
              state.fade_drag_start_view_length = view_length
              if not state.undo_block_open then
                state.undo_block_open = "fade_in"
              end
            elseif near_fade_out then
              state.dragging_fade_out = true
              state.fade_drag_start_mouse_x = mouse_x
              state.fade_drag_start_value = fade_out_len
              state.fade_drag_start_other = fade_in_len
              state.fade_drag_start_view_length = view_length
              if not state.undo_block_open then
                state.undo_block_open = "fade_out"
              end
            end
          end

          -- Start marker dragging (skip if fade drag already started this click)
          if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_marker_area
              and not state.dragging_fade_in and not state.dragging_fade_out
              and not state.is_ruler_dragging and not state.is_panning then
            if near_start then
              state.dragging_start = true
              state.marker_drag_activated = false
              state.drag_start_offset = start_offset
              state.drag_start_length = item_length
              state.drag_start_mouse_x = mouse_x
              state.drag_start_view_length = view_length
              state.drag_start_view_start = view_start
              state.drag_start_playrate = playrate
              state.drag_current_start = start_offset
              state.drag_current_end = start_offset + source_item_length
              state.drag_start_fade_in = fade_in_len
              state.drag_start_fade_out = fade_out_len
            elseif near_end then
              state.dragging_end = true
              state.marker_drag_activated = false
              state.drag_start_offset = start_offset
              state.drag_start_length = item_length
              state.drag_start_mouse_x = mouse_x
              state.drag_start_view_length = view_length
              state.drag_start_view_start = view_start
              state.drag_start_playrate = playrate
              state.drag_current_start = start_offset
              state.drag_current_end = start_offset + source_item_length
              state.drag_start_fade_in = fade_in_len
              state.drag_start_fade_out = fade_out_len
            end
          end

          -- Envelope node interaction (create/drag/delete)
          if state.active_view_tab == "envelopes" and take then
            local env_name = state.envelope_type == "Pitch" and "Pitch" or "Volume"
            local is_pitch = (state.envelope_type == "Pitch")
            local env_max_raw = is_pitch and 24.0 or reaper.ScaleToEnvelopeMode(is_pitch and 0 or 1, 2.0)
            local env_min_raw = is_pitch and -24.0 or 0

            -- Helper: convert mouse Y to envelope raw value (works for both Volume and Pitch)
            local function mouse_y_to_raw(my)
              local raw = env_min_raw + (env_max_raw - env_min_raw) * (1 - (my - wave_y) / waveform_height)
              raw = math.max(env_min_raw, math.min(env_max_raw, raw))
              -- Pitch: snap to whole semitones (if snap enabled)
              if is_pitch and state.env_snap_enabled then raw = math.floor(raw + 0.5) end
              return raw
            end

            -- Ctrl+left-click: start freehand envelope drawing
            if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_waveform
                and reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())
                and not state.dragging_start and not state.dragging_end
                and not state.dragging_fade_in and not state.dragging_fade_out
                and not state.dragging_env_node
                and not state.is_ruler_dragging and not state.is_panning then
              -- Create or get envelope
              local env = ensure_take_envelope(item, take, env_name)
              if env and env_name == "Volume" then
                -- Check if this was freshly created (only default points)
                local np = reaper.CountEnvelopePoints(env)
                if np <= 1 then
                  for di = np - 1, 0, -1 do
                    reaper.DeleteEnvelopePointEx(env, -1, di)
                  end
                end
              end
              if env then
                state.env_freehand_drawing = true
                state.env_freehand_last_x = mouse_x
                if not state.undo_block_open then
                  state.undo_block_open = "env_freehand"
                end
                -- Insert first point
                local src_time = px_to_time(mouse_x)
                local raw_val = mouse_y_to_raw(mouse_y)
                src_time = math.max(0, math.min(source_length, src_time))
                local take_time = src_time - start_offset
                reaper.InsertEnvelopePoint(env, take_time, raw_val, 0, 0, false, true)
                reaper.Envelope_SortPoints(env)
                state.env_freehand_last_take_time = take_time
              end
            end

            -- Freehand drawing: insert points while Ctrl+dragging
            if state.env_freehand_drawing and reaper.ImGui_IsMouseDown(ctx, 0) then
              if math.abs(mouse_x - state.env_freehand_last_x) >= 1 then
                local env = reaper.GetTakeEnvelopeByName(take, env_name)
                if env then
                  local src_time = px_to_time(mouse_x)
                  local raw_val = mouse_y_to_raw(mouse_y)
                  src_time = math.max(0, math.min(source_length, src_time))
                  local take_time = src_time - start_offset
                  -- Delete existing points in swept range (overwrite mode)
                  -- Protect our last inserted point, delete everything else up through current pos
                  local prev_t = state.env_freehand_last_take_time
                  if take_time >= prev_t then
                    -- Sweeping right: delete from just past our last point to just past current
                    reaper.DeleteEnvelopePointRangeEx(env, -1, prev_t + 0.00001, take_time + 0.00001)
                  else
                    -- Sweeping left: delete from just before current to just before our last point
                    reaper.DeleteEnvelopePointRangeEx(env, -1, take_time - 0.00001, prev_t - 0.00001)
                  end
                  reaper.InsertEnvelopePoint(env, take_time, raw_val, 0, 0, false, true)
                  reaper.Envelope_SortPoints(env)
                  state.env_freehand_last_x = mouse_x
                  state.env_freehand_last_take_time = take_time
                end
              end
            end

            -- Left-click: create node on segment or start dragging existing node
            if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_waveform
                and not reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())
                and not alt_held
                and not state.dragging_start and not state.dragging_end
                and not state.dragging_fade_in and not state.dragging_fade_out
                and not state.dragging_fade_curve_in and not state.dragging_fade_curve_out
                and not near_start and not near_end
                and not near_fade_in and not near_fade_out
                and not state.is_ruler_dragging and not state.is_panning then

              if state.env_node_hovered_idx >= 0 then
                -- Start dragging existing node
                local env = reaper.GetTakeEnvelopeByName(take, env_name)
                if env then
                  local retval, pt_time, pt_value = reaper.GetEnvelopePoint(env, state.env_node_hovered_idx)
                  if retval then
                    state.dragging_env_node = true
                    state.env_drag_node_idx = state.env_node_hovered_idx
                    state.env_drag_start_mouse_x = mouse_x
                    state.env_drag_start_mouse_y = mouse_y
                    state.env_drag_start_time = pt_time
                    state.env_drag_start_value = pt_value
                    state.env_drag_activated = false
                    if not state.undo_block_open then
                      state.undo_block_open = "env_node"
                    end
                  end
                end

              elseif state.envelope_hovered_segment >= 0 then
                -- Create new node on segment and immediately start dragging it
                local env = reaper.GetTakeEnvelopeByName(take, env_name)
                local just_created = false
                if not env then
                  env = ensure_take_envelope(item, take, env_name)
                  just_created = env ~= nil
                end
                if env then
                  -- Clear fader-scaled defaults for Volume (pitch default 0 is harmless)
                  if just_created and env_name == "Volume" then
                    local del_count = reaper.CountEnvelopePoints(env)
                    for di = del_count - 1, 0, -1 do
                      reaper.DeleteEnvelopePointEx(env, -1, di)
                    end
                  end
                  local snapped_src = snap_to_grid_if_enabled(state.envelope_hover_time)
                  local take_time = snapped_src - start_offset
                  reaper.InsertEnvelopePoint(env, take_time, state.envelope_hover_value, 0, 0, false, true)
                  reaper.Envelope_SortPoints(env)
                  -- Find the index of the point we just inserted
                  local new_idx = -1
                  local count = reaper.CountEnvelopePoints(env)
                  for pi = 0, count - 1 do
                    local retval, pt_time, pt_value = reaper.GetEnvelopePoint(env, pi)
                    if retval and math.abs(pt_time - take_time) < 0.0001 then
                      new_idx = pi
                      break
                    end
                  end
                  -- Immediately start dragging the new node
                  if new_idx >= 0 then
                    state.dragging_env_node = true
                    state.env_drag_node_idx = new_idx
                    state.env_drag_start_mouse_x = mouse_x
                    state.env_drag_start_mouse_y = mouse_y
                    state.env_drag_start_time = take_time
                    state.env_drag_start_value = state.envelope_hover_value
                    state.env_drag_activated = false
                    if not state.undo_block_open then
                      state.undo_block_open = "env_node"
                    end
                  end
                  reaper.UpdateArrange()
                end
              end
            end

            -- Alt+double-click on curved segment: reset curve to linear
            if reaper.ImGui_IsMouseDoubleClicked(ctx, 0) and alt_held
                and state.envelope_hovered_segment >= 0
                and state.env_node_hovered_idx < 0
                and not state.dragging_env_node
                and not state.env_tension_dragging then
              local env = reaper.GetTakeEnvelopeByName(take, env_name)
              if env then
                local seg_pt_idx = -1
                local np = reaper.CountEnvelopePoints(env)
                local hover_take_time = state.envelope_hover_time - start_offset
                for pi = 0, np - 2 do
                  local ret1, t1 = reaper.GetEnvelopePoint(env, pi)
                  local ret2, t2 = reaper.GetEnvelopePoint(env, pi + 1)
                  if ret1 and ret2 and hover_take_time >= t1 - 0.001 and hover_take_time <= t2 + 0.001 then
                    seg_pt_idx = pi
                    break
                  end
                end
                if seg_pt_idx >= 0 then
                  local ret, pt_time, pt_value, pt_shape, _, pt_sel = reaper.GetEnvelopePoint(env, seg_pt_idx)
                  if ret and pt_shape == 5 then
                    reaper.Undo_BeginBlock()
                    reaper.SetEnvelopePoint(env, seg_pt_idx, pt_time, pt_value, 0, 0, pt_sel, true)
                    reaper.Envelope_SortPoints(env)
                    reaper.UpdateArrange()
                    reaper.Undo_EndBlock("NVSD_ItemView: Reset envelope curve", -1)
                  end
                end
              end
            end

            -- Alt+click on segment (not node): start tension drag (skip on double-click)
            if reaper.ImGui_IsMouseClicked(ctx, 0) and alt_held
                and not reaper.ImGui_IsMouseDoubleClicked(ctx, 0)
                and state.envelope_hovered_segment >= 0
                and state.env_node_hovered_idx < 0
                and not state.dragging_env_node
                and not state.env_tension_dragging then
              -- Find which point controls this segment's shape
              -- envelope_hovered_segment is the segment index in the pts list;
              -- we need the REAPER point index of the segment's start point.
              -- The drawing code sets hovered_segment = i-1 where i is the pts index.
              -- We need the REAPER idx from the corresponding pts entry.
              local env = reaper.GetTakeEnvelopeByName(take, env_name)
              if env then
                -- Find the point whose shape controls this segment
                -- hover_time falls between two points; we need the first point's REAPER index
                local seg_pt_idx = -1
                local np = reaper.CountEnvelopePoints(env)
                local hover_take_time = state.envelope_hover_time - start_offset
                for pi = 0, np - 2 do
                  local ret1, t1 = reaper.GetEnvelopePoint(env, pi)
                  local ret2, t2 = reaper.GetEnvelopePoint(env, pi + 1)
                  if ret1 and ret2 and hover_take_time >= t1 - 0.001 and hover_take_time <= t2 + 0.001 then
                    seg_pt_idx = pi
                    break
                  end
                end
                if seg_pt_idx >= 0 then
                  local ret, _, pt_value, pt_shape, pt_tension = reaper.GetEnvelopePoint(env, seg_pt_idx)
                  local ret2, _, next_value = reaper.GetEnvelopePoint(env, seg_pt_idx + 1)
                  if ret and ret2 then
                    state.env_tension_dragging = true
                    state.env_tension_point_idx = seg_pt_idx
                    state.env_tension_start_mouse_y = mouse_y
                    state.env_tension_start_value = (pt_shape == 5) and pt_tension or 0
                    state.env_tension_descending = (next_value < pt_value)
                    state.env_tension_activated = false
                    if state.has_js_extension then
                      local sx, sy = reaper.GetMousePosition()
                      state.env_tension_lock_x = sx
                      state.env_tension_lock_y = sy
                      state.env_tension_last_y = sy
                      state.env_tension_cumulative_y = 0
                    end
                    if not state.undo_block_open then
                      state.undo_block_open = "env_tension"
                    end
                  end
                end
              end
            end

            -- Alt+click or right-click: delete hovered node
            if ((reaper.ImGui_IsMouseClicked(ctx, 1)) or (reaper.ImGui_IsMouseClicked(ctx, 0) and alt_held))
                and state.env_node_hovered_idx >= 0
                and not state.dragging_env_node
                and not state.env_tension_dragging then
              local env = reaper.GetTakeEnvelopeByName(take, env_name)
              if env then
                reaper.Undo_BeginBlock()
                reaper.DeleteEnvelopePointEx(env, -1, state.env_node_hovered_idx)
                reaper.Envelope_SortPoints(env)
                reaper.UpdateArrange()
                reaper.Undo_EndBlock("NVSD_ItemView: Delete envelope point", -1)
                state.env_node_hovered_idx = -1
              end
            end

            -- Drag threshold + update
            if state.dragging_env_node and reaper_is_active and reaper.ImGui_IsMouseDown(ctx, 0) then
              local dx = mouse_x - state.env_drag_start_mouse_x
              local dy = mouse_y - state.env_drag_start_mouse_y
              if not state.env_drag_activated and (math.abs(dx) >= 4 or math.abs(dy) >= 4) then
                state.env_drag_activated = true
              end
              if state.env_drag_activated then
                local env = reaper.GetTakeEnvelopeByName(take, env_name)
                if env then
                  local new_source_time = px_to_time(mouse_x)
                  local new_raw = mouse_y_to_raw(mouse_y)
                  new_source_time = math.max(0, math.min(source_length, new_source_time))
                  new_source_time = snap_to_grid_if_enabled(new_source_time)
                  -- Convert source time to take time
                  local take_time = new_source_time - start_offset
                  reaper.SetEnvelopePoint(env, state.env_drag_node_idx, take_time, new_raw, 0, 0, false, true)
                  reaper.Envelope_SortPoints(env)
                  -- Re-find the point after sort (index may have changed)
                  local count = reaper.CountEnvelopePoints(env)
                  for pi = 0, count - 1 do
                    local retval, pt_time, pt_value = reaper.GetEnvelopePoint(env, pi)
                    if retval and math.abs(pt_time - take_time) < 0.0001 and math.abs(pt_value - new_raw) < 0.0001 then
                      state.env_drag_node_idx = pi
                      break
                    end
                  end
                  reaper.UpdateArrange()
                end
              end
            end

            -- Tension drag: update curve shape while alt+dragging on segment (with cursor lock)
            if state.env_tension_dragging and reaper_is_active and reaper.ImGui_IsMouseDown(ctx, 0) then
              -- Cursor lock: accumulate delta via JS extension
              if state.has_js_extension and state.env_tension_lock_x then
                local cur_x, cur_y = reaper.GetMousePosition()
                state.env_tension_last_y = state.env_tension_last_y or cur_y
                local delta = cur_y - state.env_tension_last_y
                if delta ~= 0 then
                  state.env_tension_cumulative_y = state.env_tension_cumulative_y + delta
                end
                state.env_tension_last_y = state.env_tension_lock_y
                reaper.JS_Mouse_SetPosition(state.env_tension_lock_x, state.env_tension_lock_y)
              end
              local dy = state.has_js_extension and state.env_tension_cumulative_y or (mouse_y - state.env_tension_start_mouse_y)
              -- Flip direction for descending segments so drag-up always curves up visually
              if state.env_tension_descending then dy = -dy end
              if not state.env_tension_activated and math.abs(dy) >= 4 then
                state.env_tension_activated = true
              end
              if state.env_tension_activated then
                local env = reaper.GetTakeEnvelopeByName(take, env_name)
                if env then
                  -- Map drag distance to tension: full waveform height = range of 2 (-1 to +1)
                  local sensitivity = 2.0 / waveform_height
                  local new_tension = state.env_tension_start_value + dy * sensitivity
                  new_tension = math.max(-1, math.min(1, new_tension))
                  local ret, pt_time, pt_value, _, _, pt_sel = reaper.GetEnvelopePoint(env, state.env_tension_point_idx)
                  if ret then
                    reaper.SetEnvelopePoint(env, state.env_tension_point_idx, pt_time, pt_value, 5, new_tension, pt_sel, true)
                    reaper.Envelope_SortPoints(env)
                    reaper.UpdateArrange()
                  end
                end
              end
            end
          end

          -- Set preview cursor on click in waveform (when no drag/interaction started)
          if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_waveform
              and not state.dragging_start and not state.dragging_end
              and not state.dragging_fade_in and not state.dragging_fade_out
              and not state.dragging_fade_curve_in and not state.dragging_fade_curve_out
              and not state.dragging_env_node and not state.env_freehand_drawing
              and not near_start and not near_end
              and not near_fade_in and not near_fade_out
              and not alt_held
              and not (state.active_view_tab == "envelopes" and (state.env_node_hovered_idx >= 0 or state.envelope_hovered_segment >= 0 or reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl()))) then
            state.preview_cursor_pos = px_to_time(mouse_x)
            -- Stop any active preview when cursor moves
            if state.preview_active and state.preview_handle then
              reaper.CF_Preview_Stop(state.preview_handle)
              state.preview_handle = nil
              state.preview_active = false
            end
          end

          -- End dragging
          if reaper.ImGui_IsMouseReleased(ctx, 0) then
            if (state.dragging_start or state.dragging_end) and state.marker_drag_activated then
              -- After any marker drag that changed D_STARTOFFS, shift envelope points
              -- to maintain their source-audio position (envelope stays anchored to the audio).
              local offset_delta = start_offset - state.drag_start_offset
              if math.abs(offset_delta) > 0.000001 then
                local env_names = { "Volume", "Pitch" }
                for _, ename in ipairs(env_names) do
                  local e = reaper.GetTakeEnvelopeByName(take, ename)
                  if e then
                    local np = reaper.CountEnvelopePoints(e)
                    for ei = 0, np - 1 do
                      local ret, pt_time, pt_val, pt_shape, pt_tension, pt_sel = reaper.GetEnvelopePoint(e, ei)
                      if ret then
                        reaper.SetEnvelopePoint(e, ei, pt_time - offset_delta, pt_val, pt_shape, pt_tension, pt_sel, true)
                      end
                    end
                    reaper.Envelope_SortPoints(e)
                  end
                end
                reaper.UpdateArrange()
              end
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
              -- Create undo point AFTER envelope shift so both D_STARTOFFS + envelope are captured atomically
              local undo_msg = state.dragging_start and "NVSD_ItemView: Adjust item start" or "NVSD_ItemView: Adjust item end"
              reaper.Undo_OnStateChangeEx(undo_msg, -1, -1)
            elseif (state.dragging_start or state.dragging_end) and not state.marker_drag_activated then
              -- Click on marker without dragging: place preview cursor at marker position
              local marker_pos = state.dragging_start and state.drag_current_start or state.drag_current_end
              state.preview_cursor_pos = marker_pos
              if state.preview_active and state.preview_handle then
                reaper.CF_Preview_Stop(state.preview_handle)
                state.preview_handle = nil
                state.preview_active = false
              end
            end
            -- Alt+click on fade curve (no drag movement): remove the fade
            if state.dragging_fade_curve_in and not state.fade_curve_was_dragged then
              reaper.Undo_BeginBlock()
              reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", 0)
              reaper.SetMediaItemInfo_Value(item, "D_FADEINDIR", 0)
              reaper.UpdateArrange()
              reaper.Undo_EndBlock("NVSD_ItemView: Remove fade in", -1)
            elseif state.dragging_fade_curve_out and not state.fade_curve_was_dragged then
              reaper.Undo_BeginBlock()
              reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", 0)
              reaper.SetMediaItemInfo_Value(item, "D_FADEOUTDIR", 0)
              reaper.UpdateArrange()
              reaper.Undo_EndBlock("NVSD_ItemView: Remove fade out", -1)
            end
            state.dragging_start = false
            state.dragging_end = false
            state.marker_drag_activated = false
            state.dragging_fade_in = false
            state.dragging_fade_out = false
            state.dragging_fade_curve_in = false
            state.dragging_fade_curve_out = false
            state.dragging_env_node = false
            state.env_drag_activated = false
            state.env_drag_node_idx = -1
            if state.env_freehand_drawing then
              state.env_freehand_drawing = false
              reaper.UpdateArrange()
            end
            state.env_tension_dragging = false
            state.env_tension_activated = false
            state.env_tension_point_idx = -1
            state.env_tension_descending = false
            state.env_tension_lock_x = nil
            state.env_tension_lock_y = nil
            state.env_tension_last_y = nil
            state.env_tension_cumulative_y = 0
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

                -- Fade adjustment: preserve fade-in, shrink fade-out first
                local fi, fo = fade_in_len, fade_out_len
                if fi + fo > new_item_length then
                  fo = math.max(0, new_item_length - fi)
                  if fo == 0 then fi = math.min(fi, new_item_length) end
                end

                reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", new_take_offset)
                reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_item_length)
                reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", fi)
                reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", fo)
                reaper.UpdateArrange()
                reaper.Undo_EndBlock("NVSD_ItemView: Set start marker", -1)

              elseif clicked_mouse5 then
                local new_end = click_time
                new_end = math.max(new_end, start_offset + 0.01)
                local new_source_length = new_end - start_offset
                local new_item_length = new_source_length / playrate

                -- Fade adjustment: preserve fade-out, shrink fade-in first
                local fi, fo = fade_in_len, fade_out_len
                if fi + fo > new_item_length then
                  fi = math.max(0, new_item_length - fo)
                  if fi == 0 then fo = math.min(fo, new_item_length) end
                end

                reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_item_length)
                reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", fi)
                reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", fo)
                reaper.UpdateArrange()
                reaper.Undo_EndBlock("NVSD_ItemView: Set end marker", -1)
              end
            end
          end

          local snap_threshold_time = (config.SNAP_THRESHOLD_PX / waveform_width) * view_length

          -- Marker drag threshold: don't move markers until mouse exceeds threshold
          if (state.dragging_start or state.dragging_end) and not state.marker_drag_activated
              and reaper_is_active and reaper.ImGui_IsMouseDown(ctx, 0) then
            if math.abs(mouse_x - state.drag_start_mouse_x) >= state.marker_drag_threshold then
              state.marker_drag_activated = true
            end
          end

          -- Alt+drag: slide both markers
          if (state.dragging_start or state.dragging_end) and state.marker_drag_activated and alt_held and reaper_is_active and reaper.ImGui_IsMouseDown(ctx, 0) then
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
                new_start = snap_to_grid_if_enabled(raw_start, state.drag_start_offset)
              end
            else
              local end_snapped = snap_to_source_boundary(raw_end, source_length, snap_threshold_time)
              if end_snapped ~= raw_end then
                new_start = end_snapped - original_source_length
                snapped_to_boundary = true
              else
                new_start = snap_to_grid_if_enabled(raw_start, state.drag_start_offset)
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
          elseif state.dragging_start and state.marker_drag_activated and reaper_is_active and reaper.ImGui_IsMouseDown(ctx, 0) then
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
            new_start = snap_to_grid_if_enabled(new_start, state.drag_start_offset)
            new_start = snap_to_source_boundary(new_start, source_length, snap_threshold_time)
            new_start = math.min(new_start, original_source_end - 0.01)
            local new_source_length = original_source_end - new_start
            local new_item_length = new_source_length / state.drag_start_playrate
            local new_take_offset = new_start - section_offset

            state.drag_current_start = new_start
            state.drag_current_end = original_source_end

            -- Fade adjustment: preserve fade-in, shrink fade-out first
            local fi = state.drag_start_fade_in
            local fo = state.drag_start_fade_out
            if fi + fo > new_item_length then
              fo = math.max(0, new_item_length - fi)
              if fo == 0 then
                fi = math.min(fi, new_item_length)
              end
            end

            reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", new_take_offset)
            reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_item_length)
            reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", fi)
            reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", fo)
            reaper.UpdateArrange()

          -- Dragging end marker
          elseif state.dragging_end and state.marker_drag_activated and reaper_is_active and reaper.ImGui_IsMouseDown(ctx, 0) then
            local new_end
            if mouse_x >= wave_x and mouse_x <= wave_x + waveform_width then
              new_end = px_to_time(mouse_x)
            else
              local edge_time = mouse_x < wave_x and view_start or view_start + view_length
              local overflow_px = mouse_x < wave_x and (wave_x - mouse_x) or (mouse_x - wave_x - waveform_width)
              local overflow_time = (overflow_px / waveform_width) * source_length
              new_end = mouse_x < wave_x and (edge_time - overflow_time) or (edge_time + overflow_time)
            end
            new_end = snap_to_grid_if_enabled(new_end, state.drag_start_offset)
            new_end = snap_to_source_boundary(new_end, source_length, snap_threshold_time)
            new_end = math.max(state.drag_start_offset + 0.01 * state.drag_start_playrate, new_end)
            local new_source_length = new_end - state.drag_start_offset
            local new_item_length = new_source_length / state.drag_start_playrate
            new_item_length = math.max(0.01, new_item_length)

            state.drag_current_start = state.drag_start_offset
            state.drag_current_end = new_end

            -- Fade adjustment: preserve fade-out, shrink fade-in first
            local fi = state.drag_start_fade_in
            local fo = state.drag_start_fade_out
            if fi + fo > new_item_length then
              fi = math.max(0, new_item_length - fo)
              if fi == 0 then
                fo = math.min(fo, new_item_length)
              end
            end

            reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_item_length)
            reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", fi)
            reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", fo)
            reaper.UpdateArrange()
          end

          -- Fade handle drag processing (pushing the other fade when they'd overlap)
          if state.dragging_fade_in and reaper_is_active and reaper.ImGui_IsMouseDown(ctx, 0) then
            local delta_px = mouse_x - state.fade_drag_start_mouse_x
            local delta_time = (delta_px / waveform_width) * state.fade_drag_start_view_length
            local fi = math.max(0, state.fade_drag_start_value + delta_time / playrate)
            fi = math.min(fi, item_length)
            -- Push fade-out: cap at remaining space, but never grow past its initial value
            local fo = math.min(state.fade_drag_start_other, math.max(0, item_length - fi))
            reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", fi)
            reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", fo)
            reaper.UpdateArrange()
          elseif state.dragging_fade_out and reaper_is_active and reaper.ImGui_IsMouseDown(ctx, 0) then
            local delta_px = state.fade_drag_start_mouse_x - mouse_x  -- reversed: drag left = more fade
            local delta_time = (delta_px / waveform_width) * state.fade_drag_start_view_length
            local fo = math.max(0, state.fade_drag_start_value + delta_time / playrate)
            fo = math.min(fo, item_length)
            -- Push fade-in: cap at remaining space, but never grow past its initial value
            local fi = math.min(state.fade_drag_start_other, math.max(0, item_length - fo))
            reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", fi)
            reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", fo)
            reaper.UpdateArrange()
          end

          -- Fade curvature drag processing (with cursor lock)
          if (state.dragging_fade_curve_in or state.dragging_fade_curve_out)
              and reaper_is_active and reaper.ImGui_IsMouseDown(ctx, 0) then
            -- Hide cursor and accumulate delta via JS extension
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_None())
            if state.has_js_extension and state.fade_curve_lock_x then
              local cur_x, cur_y = reaper.GetMousePosition()
              state.fade_curve_last_y = state.fade_curve_last_y or cur_y
              local delta = state.fade_curve_last_y - cur_y
              if delta ~= 0 then
                state.fade_curve_cumulative_y = state.fade_curve_cumulative_y + delta
                if not state.fade_curve_was_dragged and math.abs(state.fade_curve_cumulative_y) >= 3 then
                  state.fade_curve_was_dragged = true
                end
              end
              state.fade_curve_last_y = state.fade_curve_lock_y
              reaper.JS_Mouse_SetPosition(state.fade_curve_lock_x, state.fade_curve_lock_y)
            end
            local sensitivity = 0.005
            local new_dir
            if state.dragging_fade_curve_in then
              new_dir = state.fade_curve_drag_start_value - state.fade_curve_cumulative_y * sensitivity
              new_dir = math.max(-1, math.min(1, new_dir))
              -- Clamp cumulative delta so reversing direction responds instantly
              state.fade_curve_cumulative_y = (state.fade_curve_drag_start_value - new_dir) / sensitivity
              reaper.SetMediaItemInfo_Value(item, "D_FADEINDIR", new_dir)
            else
              new_dir = state.fade_curve_drag_start_value + state.fade_curve_cumulative_y * sensitivity
              new_dir = math.max(-1, math.min(1, new_dir))
              state.fade_curve_cumulative_y = (new_dir - state.fade_curve_drag_start_value) / sensitivity
              reaper.SetMediaItemInfo_Value(item, "D_FADEOUTDIR", new_dir)
            end
            reaper.UpdateArrange()
          end

          -- Draw fade overlays (before markers, after all position vars are computed)
          -- Curves map over the actual fade region. When fades touch, curves touch.
          if fade_in_len > 0 then
            drawing.draw_fade_overlay(draw_list, start_marker_x, fade_in_end_x,
              fade_top_y, wave_y, waveform_height, fade_in_shape, true,
              state.fade_in_hovered or state.dragging_fade_in or state.dragging_fade_curve_in
              or (alt_held and mouse_in_fade_in_body), fade_in_dir)
          end
          if fade_out_len > 0 then
            drawing.draw_fade_overlay(draw_list, fade_out_start_x, end_marker_x,
              fade_top_y, wave_y, waveform_height, fade_out_shape, false,
              state.fade_out_hovered or state.dragging_fade_out or state.dragging_fade_curve_out
              or (alt_held and mouse_in_fade_out_body), fade_out_dir)
          end

          -- Fade drag indicator: vertical line showing current fade boundary
          if state.dragging_fade_in and fade_in_len > 0 then
            local line_x = fade_in_end_x
            if line_x >= wave_x and line_x <= wave_x + waveform_width then
              reaper.ImGui_DrawList_AddLine(draw_list, line_x, wave_y, line_x, wave_y + waveform_height, 0xFFFFFF60, 1)
            end
          end
          if state.dragging_fade_out and fade_out_len > 0 then
            local line_x = fade_out_start_x
            if line_x >= wave_x and line_x <= wave_x + waveform_width then
              reaper.ImGui_DrawList_AddLine(draw_list, line_x, wave_y, line_x, wave_y + waveform_height, 0xFFFFFF60, 1)
            end
          end

          -- Fade hint: small curved triangle when hovering grab zone with no fade
          if state.fade_in_hovered and fade_in_len == 0 and not state.dragging_fade_in then
            drawing.draw_fade_hint(draw_list, start_marker_x, wave_y, true)
          end
          if state.fade_out_hovered and fade_out_len == 0 and not state.dragging_fade_out then
            drawing.draw_fade_hint(draw_list, end_marker_x, wave_y, false)
          end

          -- Draw markers on top
          if start_marker_x >= wave_x - config.MARKER_WIDTH and start_marker_x <= wave_x + waveform_width + config.MARKER_WIDTH then
            drawing.draw_marker(draw_list, start_marker_x, wave_y, waveform_height, true, near_start, state.dragging_start, config)
          end
          if end_marker_x >= wave_x - config.MARKER_WIDTH and end_marker_x <= wave_x + waveform_width + config.MARKER_WIDTH then
            drawing.draw_marker(draw_list, end_marker_x, wave_y, waveform_height, false, near_end, state.dragging_end, config)
          end

          -- (No fade handle squares - REAPER-style grab from waveform corners)

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

          -- Audio preview: handle Ctrl+Space toggle
          if state.preview_start_requested then
            state.preview_start_requested = false
            if state.preview_active and state.preview_handle then
              -- Stop preview
              reaper.CF_Preview_Stop(state.preview_handle)
              state.preview_handle = nil
              state.preview_active = false
            else
              -- Start preview from cursor position (or item start if no cursor set)
              local pos = state.preview_cursor_pos or start_offset
              local handle = reaper.CF_CreatePreview(source)
              if handle then
                reaper.CF_Preview_SetValue(handle, "D_POSITION", pos)
                reaper.CF_Preview_SetValue(handle, "D_VOLUME", item_vol)
                reaper.CF_Preview_SetValue(handle, "B_LOOP", 0)
                local track = reaper.GetMediaItemTrack(item)
                if track then
                  reaper.CF_Preview_SetOutputTrack(handle, 0, track)
                end
                reaper.CF_Preview_Play(handle)
                state.preview_handle = handle
                state.preview_active = true
                state.preview_item = item
              end
            end
          end

          -- Audio preview: poll position and auto-stop at end
          if state.preview_active and state.preview_handle then
            -- Stop if item changed
            if item ~= state.preview_item then
              reaper.CF_Preview_Stop(state.preview_handle)
              state.preview_handle = nil
              state.preview_active = false
            else
              local retval, pos = reaper.CF_Preview_GetValue(state.preview_handle, "D_POSITION")
              if retval then
                -- Draw moving preview playhead
                local preview_px = time_to_px(pos)
                if preview_px >= wave_x and preview_px <= wave_x + waveform_width then
                  drawing.draw_preview_playhead(draw_list, preview_px, wave_y, waveform_height)
                end
                -- Auto-stop when past source end
                if pos >= source_length then
                  reaper.CF_Preview_Stop(state.preview_handle)
                  state.preview_handle = nil
                  state.preview_active = false
                end
              else
                -- Handle became invalid (preview ended)
                state.preview_handle = nil
                state.preview_active = false
              end
            end
          end

          -- Draw preview cursor (static position marker)
          if state.preview_cursor_pos and not state.preview_active then
            local cursor_px = time_to_px(state.preview_cursor_pos)
            if cursor_px >= wave_x and cursor_px <= wave_x + waveform_width then
              drawing.draw_preview_cursor(draw_list, cursor_px, wave_y, waveform_height)
            end
          elseif state.preview_cursor_pos and state.preview_active then
            -- Show cursor dimmer during playback
            local cursor_px = time_to_px(state.preview_cursor_pos)
            if cursor_px >= wave_x and cursor_px <= wave_x + waveform_width then
              drawing.draw_preview_cursor(draw_list, cursor_px, wave_y, waveform_height)
            end
          end

          -- Draw envelope dropdown ON TOP of everything (after playheads/cursors)
          if state.active_view_tab == "envelopes" then
            drawing.draw_envelope_dropdown(draw_list, ctx, wave_x, envelope_bar_y,
              config.ENVELOPE_BAR_HEIGHT, mouse_x, mouse_y, config, state)
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

    -- Clear preview start flag if it wasn't consumed (no item/source available)
    state.preview_start_requested = false

    reaper.ImGui_End(ctx)
  end

  reaper.ImGui_PopStyleVar(ctx)

  end) -- pcall

  -- Handle reload outside pcall (dofile replaces the running script)
  if needs_reload then
    -- Stop audio preview before reload
    if state.preview_active and state.preview_handle and reaper.CF_Preview_Stop then
      reaper.CF_Preview_Stop(state.preview_handle)
    end
    state.preview_handle = nil
    state.preview_active = false
    ctx = nil
    dofile(script_path)
    return
  end

  if not ok then
    -- Log the actual error so we can diagnose
    reaper.ShowConsoleMsg("NVSD_ItemView ERROR: " .. tostring(err) .. "\n")
    -- Recreate context to recover from corrupted ImGui stack (unmatched Begin/End, Push/Pop)
    ctx = reaper.ImGui_CreateContext("NVSD_ItemView")
    if reaper.ImGui_CreateFont and reaper.ImGui_Attach then
      local font = reaper.ImGui_CreateFont('sans-serif', 13)
      reaper.ImGui_Attach(ctx, font)
    end
    -- Reset all interaction state to prevent stuck drags after error
    state.dragging_start = false
    state.dragging_end = false
    state.dragging_fade_in = false
    state.dragging_fade_out = false
    state.dragging_fade_curve_in = false
    state.dragging_fade_curve_out = false
    state.is_panning = false
    state.is_ruler_dragging = false
    state.fx_dragging = false
    state.fx_drag_activated = false
    state.dragging_env_node = false
    state.env_drag_activated = false
    state.env_freehand_drawing = false
    state.env_drag_node_idx = -1
    state.undo_block_open = nil
    state.sticky_item = nil
    state.sticky_item_valid = false
    -- Stop audio preview on error
    if state.preview_active and state.preview_handle and reaper.CF_Preview_Stop then
      reaper.CF_Preview_Stop(state.preview_handle)
    end
    state.preview_handle = nil
    state.preview_active = false
  end

  if open then
    reaper.defer(loop)
  else
    -- Stop audio preview on script close
    if state.preview_active and state.preview_handle and reaper.CF_Preview_Stop then
      reaper.CF_Preview_Stop(state.preview_handle)
    end
  end
end

reaper.defer(loop)
