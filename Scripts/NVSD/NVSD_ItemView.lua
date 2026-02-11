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
  local action_ids = { Volume = 40693, Pitch = 40714, Pan = 40694 }
  local action_id = action_ids[env_name] or 40693
  reaper.Main_OnCommand(action_id, 0)
  env = reaper.GetTakeEnvelopeByName(take, env_name)
  if env then return env end
  -- Fallback: inject envelope via item state chunk
  local chunk_tag = ({ Volume = "VOLENV2", Pitch = "PITCHENV", Pan = "PANENV2" })[env_name]
  if not chunk_tag then return nil end
  local _, chunk = reaper.GetItemStateChunk(item, "", false)
  if chunk:find("<" .. chunk_tag) then return reaper.GetTakeEnvelopeByName(take, env_name) end
  local env_chunk = "<" .. chunk_tag .. "\nACT 1 -1\nVIS 1 1 1\nLANEHEIGHT 0 0\nARM 0\nDEFSHAPE 0 -1 -1\nPT 0 0 0\n>\n"
  -- Find the item's closing > (last > in chunk) and insert before it
  local last_close = chunk:match(".*()>")
  if last_close then
    chunk = chunk:sub(1, last_close - 1) .. env_chunk .. chunk:sub(last_close)
    reaper.SetItemStateChunk(item, chunk, false)
    reaper.UpdateItemInProject(item)
    reaper.UpdateArrange()
    return reaper.GetTakeEnvelopeByName(take, env_name)
  end
  return nil
end

-- Check for ReaImGui
if not reaper.ImGui_CreateContext then
  reaper.MB("This script requires the ReaImGui extension.\nInstall it via ReaPack: Extensions > ReaPack > Browse packages > ReaImGui", "Missing Dependency", 0)
  return
end

-- Toggle action support: if script is already running, signal it to close and exit
local _, _, toggle_section_id, toggle_cmd_id = reaper.get_action_context()
if reaper.GetExtState("NVSD_ItemView", "running") == "1" then
  reaper.SetExtState("NVSD_ItemView", "close_requested", "1", false)
  return
end
reaper.SetExtState("NVSD_ItemView", "running", "1", false)
reaper.DeleteExtState("NVSD_ItemView", "close_requested", false)
if toggle_cmd_id > 0 then
  reaper.SetToggleCommandState(toggle_section_id, toggle_cmd_id, 1)
  reaper.RefreshToolbar2(toggle_section_id, toggle_cmd_id)
end
reaper.atexit(function()
  reaper.SetExtState("NVSD_ItemView", "running", "0", false)
  reaper.DeleteExtState("NVSD_ItemView", "close_requested", false)
  if toggle_cmd_id > 0 then
    reaper.SetToggleCommandState(toggle_section_id, toggle_cmd_id, 0)
    reaper.RefreshToolbar2(toggle_section_id, toggle_cmd_id)
  end
end)

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

  -- Toggle close: another instance signaled us to close
  if reaper.GetExtState("NVSD_ItemView", "close_requested") == "1" then
    reaper.DeleteExtState("NVSD_ItemView", "close_requested", false)
    if state.preview_active and state.preview_handle and reaper.CF_Preview_Stop then
      reaper.CF_Preview_Stop(state.preview_handle)
    end
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

    -- Escape: clear region selection first, close window if nothing to clear
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
      if state.region_selected then
        state.region_selected = false
      else
        open = false
      end
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
      -- Zone drags handle undo after envelope shift in the release block below
      if not state.dragging_zone then
        local undo_messages = {
          marker_start = "NVSD_ItemView: Adjust item start",
          marker_end = "NVSD_ItemView: Adjust item end",
          pitch = "NVSD_ItemView: Adjust pitch",
          pan = "NVSD_ItemView: Adjust pan",
          gain = "NVSD_ItemView: Adjust item volume",
          semitones = "NVSD_ItemView: Adjust semitones",
          cents = "NVSD_ItemView: Adjust cents",
          fade_in = "NVSD_ItemView: Adjust fade in",
          fade_out = "NVSD_ItemView: Adjust fade out",
          env_node = "NVSD_ItemView: Move envelope point",
          env_freehand = "NVSD_ItemView: Draw envelope freehand",
          env_tension = "NVSD_ItemView: Adjust envelope curve",
          env_segment = "NVSD_ItemView: Move envelope segment",
          slide_both = "NVSD_ItemView: Slide item",
        }
        local msg = undo_messages[state.undo_block_open] or "NVSD_ItemView: Edit"
        reaper.Undo_OnStateChangeEx(msg, -1, -1)
      end
      state.undo_block_open = nil
    end

    -- Get selected item
    local selected_item = reaper.GetSelectedMediaItem(0, 0)

    -- Clear sticky when selection changes to a DIFFERENT item (not when deselecting to nil).
    -- Skip when REAPER is unfocused to prevent spurious resets.
    if reaper_is_active and selected_item ~= state.last_selected_item then
      if selected_item then
        -- Switched to a different item: clear sticky, preview, region, auto-switch envelopes
        state.sticky_item = nil
        state.sticky_item_valid = false
        state.sticky_validation_counter = 0
        if state.preview_active and state.preview_handle then
          reaper.CF_Preview_Stop(state.preview_handle)
        end
        state.preview_cursor_pos = nil
        state.preview_handle = nil
        state.preview_active = false
        state.preview_item = nil
        state.region_selected = false
        state.selecting_region = false
        -- Auto-switch to Envelopes tab if the new item has active take envelopes
        local sel_take = reaper.GetActiveTake(selected_item)
        if sel_take then
          local vol_env = reaper.GetTakeEnvelopeByName(sel_take, "Volume")
          local pitch_env = reaper.GetTakeEnvelopeByName(sel_take, "Pitch")
          local pan_env = reaper.GetTakeEnvelopeByName(sel_take, "Pan")
          if vol_env or pitch_env or pan_env then
            state.envelopes_visible = true
            if pitch_env and not vol_env and not pan_env then
              state.envelope_type = "Pitch"
            elseif pan_env and not vol_env and not pitch_env then
              state.envelope_type = "Pan"
            else
              state.envelope_type = "Volume"
            end
          else
            state.envelopes_visible = false
          end
        end
      end
      -- When deselecting (selected_item == nil), do NOT clear sticky/state.
      -- The remembered_item will keep the script showing the last item.
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

    -- Priority 4: Use remembered item (last displayed item, persists through deselect)
    if not item and state.remembered_item then
      if reaper.ValidatePtr(state.remembered_item, "MediaItem*") then
        item = state.remembered_item
      else
        state.remembered_item = nil
      end
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
      state.remembered_item = nil
    end

    -- Remember the current item so it persists through deselection
    if item then
      state.remembered_item = item
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

        -- Open in external editor (or Item Properties if no editor configured)
        if settings.check_shortcut(ctx, "open_editor") then
          local saved_items = {}
          for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
            saved_items[#saved_items + 1] = reaper.GetSelectedMediaItem(0, i)
          end
          reaper.SelectAllMediaItems(0, false)
          reaper.SetMediaItemSelected(item, true)
          if controls.has_external_editor() then
            reaper.Undo_BeginBlock()
            reaper.Main_OnCommand(40109, 0)  -- Open items in external editor
            reaper.Undo_EndBlock("NVSD_ItemView: Open in External Editor", -1)
          else
            reaper.Main_OnCommand(40009, 0)  -- Item properties dialog
          end
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

          -- Fade values: when auto-crossfade is active, use auto (reflects actual overlap);
          -- otherwise use manual. This avoids stale manual values inflating the display.
          local fade_in_len_manual = reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN")
          local fade_in_len_auto = reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN_AUTO")
          local fade_out_len_manual = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN")
          local fade_out_len_auto = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN_AUTO")
          local fade_in_len = fade_in_len_auto > 0 and fade_in_len_auto or fade_in_len_manual
          local fade_out_len = fade_out_len_auto > 0 and fade_out_len_auto or fade_out_len_manual
          local fade_in_shape = math.floor(reaper.GetMediaItemInfo_Value(item, "C_FADEINSHAPE") + 0.5)
          local fade_out_shape = math.floor(reaper.GetMediaItemInfo_Value(item, "C_FADEOUTSHAPE") + 0.5)
          local fade_in_dir = reaper.GetMediaItemInfo_Value(item, "D_FADEINDIR")
          local fade_out_dir = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTDIR")

          -- Handle auto-crossfade shapes: REAPER returns shape >= 7 for crossfade-customized fades.
          -- The actual shape is in the item state chunk's FADEIN/FADEOUT first field (integer part).
          if fade_in_shape > 6 or fade_out_shape > 6 then
            local _, chunk = reaper.GetItemStateChunk(item, "", false)
            if fade_in_shape > 6 then
              local fi_first = chunk:match("FADEIN ([%d%.%-]+)")
              if fi_first then
                fade_in_shape = math.floor(tonumber(fi_first))
                if fade_in_shape < 0 or fade_in_shape > 6 then fade_in_shape = 0 end
              end
            end
            if fade_out_shape > 6 then
              local fo_first = chunk:match("FADEOUT ([%d%.%-]+)")
              if fo_first then
                fade_out_shape = math.floor(tonumber(fo_first))
                if fade_out_shape < 0 or fade_out_shape > 6 then fade_out_shape = 0 end
              end
            end
          end

          -- Get available space for waveform
          local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
          local envelope_bar_height = config.ENVELOPE_BAR_HEIGHT
          local waveform_height = math.max(50, avail_h - (config.WAVEFORM_MARGIN_V * 2) - config.INFO_BAR_HEIGHT - config.RULER_HEIGHT - config.TIME_RULER_HEIGHT - envelope_bar_height)
          local panel_height = config.INFO_BAR_HEIGHT + config.RULER_HEIGHT + waveform_height + config.TIME_RULER_HEIGHT + envelope_bar_height

          local two_col_panel = panel_height < 270
          local effective_panel_width = two_col_panel
              and (config.LEFT_PANEL_WIDTH * 2)
              or config.LEFT_PANEL_WIDTH

          local total_left_width = config.LEFT_COLUMN_WIDTH + effective_panel_width
          local pitch_gutter = (state.envelopes_visible and (state.envelope_type == "Pitch" or state.envelope_type == "Pan")) and config.PITCH_LABEL_WIDTH or 0
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

          -- Detect looped item and track start_offset wrapping
          local is_looped_item = source_item_length > source_length and source_length > 0

          -- Reset unwrap tracking when item changes
          if state.unwrap_tracked_item ~= item then
            state.unwrapped_start_offset = nil
            state.prev_raw_start_offset = nil
            state.unwrap_tracked_item = item
          end

          if (state.dragging_start or state.dragging_end) and state.marker_drag_activated then
            -- During active drag: drag state is the authority for unwrapped offset
            state.unwrapped_start_offset = state.drag_current_start
            state.prev_raw_start_offset = start_offset
          elseif is_looped_item then
            -- Initialize or re-validate wrap tracking
            local needs_init = state.unwrapped_start_offset == nil
            -- Sanity check: if existing unwrapped range doesn't include [0, source_length], re-init
            if not needs_init and source_length > 0 then
              local uw_end = state.unwrapped_start_offset + source_item_length
              if state.unwrapped_start_offset > source_length * 0.5 or uw_end < source_length * 0.5 then
                needs_init = true
              end
            end
            if needs_init then
              -- REAPER stores D_STARTOFFS wrapped to [0, source_length). We need to
              -- unwrap it so the view range [unwrapped, unwrapped + item_length] includes
              -- the full original source [0, source_length]. Normalize to (-source_length, 0]
              -- so the original source is always visible in the view.
              local initial = start_offset
              if source_length > 0 then
                initial = start_offset % source_length
                if initial > 1e-9 then initial = initial - source_length end
              end
              state.unwrapped_start_offset = initial
              state.prev_raw_start_offset = start_offset
            end

            -- Detect wraps: if start_offset jumped by ~source_length, it wrapped
            if state.prev_raw_start_offset ~= nil then
              local delta = start_offset - state.prev_raw_start_offset
              if delta > source_length * 0.5 then
                -- Wrapped upward (extending left past 0): actual change was negative
                delta = delta - source_length
              elseif delta < -source_length * 0.5 then
                -- Wrapped downward: actual change was positive
                delta = delta + source_length
              end
              state.unwrapped_start_offset = state.unwrapped_start_offset + delta
            end
            state.prev_raw_start_offset = start_offset
          else
            -- Not looped: reset tracking
            state.unwrapped_start_offset = nil
            state.prev_raw_start_offset = nil
          end

          state.is_looped_view = is_looped_item

          -- Extended view range (virtual source time coordinates)
          local ext_start, ext_end, ext_length
          if (state.dragging_start or state.dragging_end) and state.marker_drag_activated then
            -- During active drag: compute ext from drag state for real-time view updates
            local ds = state.drag_current_start
            local de = state.drag_current_end
            if ds < 0 or de > source_length then
              ext_start = ds
              ext_end = de
              ext_length = de - ds
            else
              ext_start = 0
              ext_end = source_length
              ext_length = source_length
            end
          elseif is_looped_item then
            ext_start = state.unwrapped_start_offset
            ext_end = state.unwrapped_start_offset + source_item_length
            ext_length = source_item_length
          else
            ext_start = 0
            ext_end = source_length
            ext_length = source_length
          end

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
                                  or state.selecting_region
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
            -- Reset wrap tracking for new item
            state.unwrapped_start_offset = nil
            state.prev_raw_start_offset = nil
          end

          -- Compute view bounds
          local view_length = ext_length / state.zoom_level
          local range_center = (ext_start + ext_end) / 2
          local view_center = range_center + state.pan_offset
          local view_start = view_center - view_length / 2
          local view_end = view_start + view_length
          if view_start < ext_start then view_start = ext_start; view_end = ext_start + view_length end
          if view_end > ext_end then view_end = ext_end; view_start = ext_end - view_length end
          if view_start < ext_start then view_start = ext_start end
          view_length = view_end - view_start
          if view_length <= 0 then view_length = 0.001 end

          -- Per-view peak loading: load exactly screen-width peaks for the visible range.
          -- PCM_Source_GetPeaks uses pre-indexed .reapeaks files → <1ms regardless of file size.
          local pixel_step = user_dragging_in_reaper and 2 or 1
          local num_view_samples = math.max(1, math.floor(waveform_width / pixel_step))

          local is_extended_drag = (state.dragging_start or state.dragging_end)
              and state.marker_drag_activated
              and (state.drag_current_start < 0 or state.drag_current_end > source_length)

          local need_reload = state.view_peaks == nil
              or source ~= state.view_source
              or is_reversed ~= state.view_reversed
              or view_start ~= state.view_start
              or view_length ~= state.view_length
              or num_view_samples ~= state.view_num_samples

          if need_reload and view_length > 0 then
            local peaks_result, num_ch
            if (is_looped_item or is_extended_drag) and not is_reversed then
              peaks_result, num_ch = utils.get_peaks_for_range_looped(source, view_start, view_length, num_view_samples, source_length)
            else
              -- For reversed display, load peaks from the mirrored source range
              local peak_start = is_reversed and math.max(0, source_length - view_start - view_length) or view_start
              peaks_result, num_ch = utils.get_peaks_for_range(source, peak_start, view_length, num_view_samples)
            end
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
          if (state.dragging_start or state.dragging_end) and state.drag_current_start ~= nil then
            view_offset = state.drag_current_start
            view_item_length = state.drag_current_end - state.drag_current_start
          elseif is_looped_item then
            view_offset = state.unwrapped_start_offset or start_offset
            view_item_length = source_item_length
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
            -- No clamping: markers can go past source boundaries during drag
          elseif is_looped_item then
            -- Markers at item boundaries in virtual time
            render_start = ext_start
            render_end = ext_end
          else
            render_start = start_offset
            render_end = start_offset + source_item_length
            -- Clamp markers to source bounds; for looped items, wrap end to show
            -- where audio actually is in the source (modulo source_length)
            render_start = math.max(0, math.min(source_length, render_start))
            if render_end > source_length and source_length > 0 then
              local wrapped = render_end % source_length
              if wrapped >= render_start then
                render_end = wrapped
              end
            end
            render_end = math.max(0, math.min(source_length, render_end))
          end
          local actual_start_px = time_to_px(render_start) - wave_x
          local actual_end_px = time_to_px(render_end) - wave_x
          start_px = actual_start_px
          end_px = actual_end_px

          -- Draw ruler (ticks and labels, on top of waveform)
          drawing.draw_ruler_and_grid(draw_list, wave_x, ruler_y, wave_y, waveform_width, config.RULER_HEIGHT, waveform_height,
            grid_view_start, view_length, item_position, grid_offset, grid_playrate, config, utils)

          -- Draw overlays on inactive regions (skip in looped/extending mode - entire view is item content)
          if not is_looped_item and not is_extended_drag then
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

          -- Selection now persists across sample/envelope tabs

          -- Draw envelope overlay when envelopes tab is active
          if state.envelopes_visible then
            -- Read envelope points from REAPER (raw values for fader-scaled display)
            local env_name = state.envelope_type  -- "Volume", "Pitch", or "Pan"
            local is_pitch = (env_name == "Pitch")
            local is_pan = (env_name == "Pan")
            local is_centered = is_pitch or is_pan
            local env = take and reaper.GetTakeEnvelopeByName(take, env_name)
            local env_points = {}
            local num_env_points = 0
            -- Default scaling: Volume=fader(1), Pitch/Pan=linear(0)
            local env_scaling = is_centered and 0 or 1
            local env_max_raw = is_pitch and 24.0 or (is_pan and 1.0 or reaper.ScaleToEnvelopeMode(env_scaling, 2.0))
            local env_min_raw = is_pitch and -24.0 or (is_pan and -1.0 or 0)
            if env then
              env_scaling = reaper.GetEnvelopeScalingMode(env)
              if not is_centered then
                env_max_raw = reaper.ScaleToEnvelopeMode(env_scaling, 2.0)
              end
              num_env_points = reaper.CountEnvelopePoints(env)
              -- Envelope points are shifted in realtime during drag, so always use live offset
              -- During drag: use live drag position; looped: use unwrapped offset; else: REAPER offset
              local env_time_offset
              if state.dragging_start or state.dragging_end then
                env_time_offset = state.drag_current_start or start_offset
              elseif is_looped_item then
                env_time_offset = state.unwrapped_start_offset or start_offset
              else
                env_time_offset = start_offset
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
            local env_colors = config.ENV_COLORS[state.envelope_type] or config.ENV_COLORS.Volume
            local env_anchor_end = is_looped_item and ext_end or source_length
            local env_anchor_start = is_looped_item and ext_start or nil
            drawing.draw_envelope_overlay(draw_list, ctx, env_points, num_env_points,
              wave_x, wave_y, waveform_width, waveform_height,
              time_to_px, view_start, view_length,
              mouse_x, mouse_y, config, state, env_anchor_end,
              env_scaling, env_max_raw, env_min_raw, state.envelope_type,
              snap_to_grid_if_enabled, env_colors, env_anchor_start)

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
          reaper.ImGui_DrawList_AddRectFilled(draw_list, panel_x, panel_y,
              panel_x + effective_panel_width - 4, panel_y + panel_height, COLOR_PANEL_BG)

          if two_col_panel then
            -- Two-column mode: gain on left, knobs on right
            local div_x = panel_x + config.LEFT_PANEL_WIDTH - 2
            reaper.ImGui_DrawList_AddLine(draw_list, div_x, panel_y + 4, div_x,
                panel_y + panel_height - 4, 0x333333FF, 1)

            -- Left column: gain slider (full height)
            controls.draw_gain_slider(ctx, draw_list, mouse_x, mouse_y,
                panel_x, panel_y, panel_y + panel_height,
                item, item_vol, config, state, utils)

            -- Right column: pan (top 45%) + pitch+boxes (bottom 55%)
            local knobs_x = panel_x + config.LEFT_PANEL_WIDTH
            local knob_split = panel_y + panel_height * 0.45

            controls.draw_pan_knob(ctx, draw_list, mouse_x, mouse_y,
                knobs_x, panel_y, knob_split,
                item, take, config, state, utils, drawing)

            local take_pitch, knob_cx, knob_cy = controls.draw_pitch_knob(
                ctx, draw_list, mouse_x, mouse_y,
                knobs_x, knob_split, panel_y + panel_height,
                take, config, state, utils, drawing)

            controls.draw_semitones_cents_boxes(ctx, draw_list, mouse_x, mouse_y,
                knobs_x, knob_cy, take, take_pitch, config, state, utils)
          else
            -- Single column: knobs get fixed minimum space, gain gets the rest
            local pan_height = 70
            local pitch_height = 85
            local panel_split1 = panel_y + panel_height - pan_height - pitch_height
            local panel_split2 = panel_split1 + pan_height

            controls.draw_gain_slider(ctx, draw_list, mouse_x, mouse_y,
                panel_x, panel_y, panel_split1,
                item, item_vol, config, state, utils)

            controls.draw_pan_knob(ctx, draw_list, mouse_x, mouse_y,
                panel_x, panel_split1, panel_split2,
                item, take, config, state, utils, drawing)

            local take_pitch, knob_cx, knob_cy = controls.draw_pitch_knob(
                ctx, draw_list, mouse_x, mouse_y,
                panel_x, panel_split2, panel_y + panel_height,
                take, config, state, utils, drawing)

            controls.draw_semitones_cents_boxes(ctx, draw_list, mouse_x, mouse_y,
                panel_x, knob_cy, take, take_pitch, config, state, utils)
          end

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

          -- Free zone: waveform area between markers, no interactive element hovered
          local mouse_in_free_zone = mouse_in_waveform
              and mouse_x > start_marker_x + config.MARKER_WIDTH / 2
              and mouse_x < end_marker_x - config.MARKER_WIDTH / 2
              and not near_start and not near_end
              and not near_fade_in and not near_fade_out
              and not mouse_in_fade_in_body and not mouse_in_fade_out_body
              and not (state.envelopes_visible and state.env_node_hovered_idx >= 0)
              and not (state.envelopes_visible and state.envelope_hovered_segment >= 0)

          -- Cursor feedback (alt_held cached at top of frame)
          -- Fade grabs use Hand cursor to distinguish from marker's ResizeEW
          if state.dragging_fade_curve_in or state.dragging_fade_curve_out or state.env_tension_dragging then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_None())
          elseif state.dragging_fade_in or state.dragging_fade_out then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
          elseif alt_held and reaper_is_active and (mouse_in_fade_in_body or mouse_in_fade_out_body) then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeNS())
          elseif alt_held and mouse_in_free_zone and not state.dragging_fade_in and not state.dragging_fade_out then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeAll())
          elseif near_fade_in or near_fade_out then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
          elseif (state.dragging_start or state.dragging_end) and (alt_held or state.drag_alt_latched) then
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
          elseif state.env_segment_dragging then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeNS())
          elseif state.envelopes_visible and alt_held and reaper_is_active
              and state.env_node_hovered_idx >= 0 then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_NotAllowed())
          elseif state.envelopes_visible and alt_held and reaper_is_active
              and state.envelope_hovered_segment >= 0 and state.env_node_hovered_idx < 0 then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeNS())
          elseif state.envelopes_visible and shift_held and reaper_is_active
              and state.envelope_hovered_segment >= 0 and state.env_node_hovered_idx < 0 then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeNS())
          elseif state.envelopes_visible and mouse_in_waveform
              and reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl()) then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
          elseif state.selecting_region and state.selection_drag_activated then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeEW())
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

          -- Zoom helpers
          local zoom_base_view_length = ext_length

          -- Min zoom = 1.0 (shows full source), max zoom = 500
          local min_zoom = 1.0

          local function zoom_to_cursor(new_zoom, cursor_x)
            local cursor_fraction = (cursor_x - wave_x) / waveform_width
            cursor_fraction = math.max(0, math.min(1, cursor_fraction))

            local time_under_cursor = view_start + cursor_fraction * view_length

            state.zoom_level = math.max(min_zoom, math.min(500.0, new_zoom))

            local new_view_length = zoom_base_view_length / state.zoom_level

            state.pan_offset = time_under_cursor - range_center + new_view_length * (0.5 - cursor_fraction)

            -- Clamp pan to keep view within bounds
            local half_view = new_view_length / 2
            local min_pan = -range_center + half_view
            local max_pan = ext_end - range_center - half_view
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
                local max_pan = ext_end - range_center - half_view
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
            -- Pan limits: keep view within bounds
            local half_view = view_length / 2
            local min_pan = -range_center + half_view
            local max_pan = ext_end - range_center - half_view
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
              state.fade_drag_start_auto = fade_in_len_auto
              state.fade_drag_start_auto_other = fade_out_len_auto
              -- Find adjacent left item for crossfade extension
              state.fade_drag_xfade_item = nil
              if fade_in_len_auto > 0 then
                local track = reaper.GetMediaItem_Track(item)
                local num_items = reaper.CountTrackMediaItems(track)
                for i = 0, num_items - 1 do
                  local other = reaper.GetTrackMediaItem(track, i)
                  if other ~= item then
                    local other_pos = reaper.GetMediaItemInfo_Value(other, "D_POSITION")
                    local other_len = reaper.GetMediaItemInfo_Value(other, "D_LENGTH")
                    local other_end = other_pos + other_len
                    if other_end > item_position and other_pos < item_position then
                      local other_take = reaper.GetActiveTake(other)
                      if other_take then
                        local other_source = reaper.GetMediaItemTake_Source(other_take)
                        local other_source_len = reaper.GetMediaSourceLength(other_source)
                        local other_startoffs = reaper.GetMediaItemTakeInfo_Value(other_take, "D_STARTOFFS")
                        local other_playrate = reaper.GetMediaItemTakeInfo_Value(other_take, "D_PLAYRATE")
                        local source_used = other_startoffs + other_len * other_playrate
                        state.fade_drag_xfade_item = other
                        state.fade_drag_xfade_length = other_len
                        state.fade_drag_xfade_max_ext = math.max(0, (other_source_len - source_used) / other_playrate)
                        state.fade_drag_xfade_pos = other_pos
                        state.fade_drag_xfade_startoffs = other_startoffs
                        state.fade_drag_xfade_playrate = other_playrate
                        state.fade_drag_xfade_fade_auto = reaper.GetMediaItemInfo_Value(other, "D_FADEOUTLEN_AUTO")
                      end
                      break
                    end
                  end
                end
              end
              state.fade_drag_xfade_env_shift = 0
              if not state.undo_block_open then
                state.undo_block_open = "fade_in"
              end
            elseif near_fade_out then
              state.dragging_fade_out = true
              state.fade_drag_start_mouse_x = mouse_x
              state.fade_drag_start_value = fade_out_len
              state.fade_drag_start_other = fade_in_len
              state.fade_drag_start_view_length = view_length
              state.fade_drag_start_auto = fade_out_len_auto
              state.fade_drag_start_auto_other = fade_in_len_auto
              -- Find adjacent right item for crossfade extension
              state.fade_drag_xfade_item = nil
              if fade_out_len_auto > 0 then
                local track = reaper.GetMediaItem_Track(item)
                local item_end_pos = item_position + item_length
                local num_items = reaper.CountTrackMediaItems(track)
                for i = 0, num_items - 1 do
                  local other = reaper.GetTrackMediaItem(track, i)
                  if other ~= item then
                    local other_pos = reaper.GetMediaItemInfo_Value(other, "D_POSITION")
                    if other_pos >= item_position and other_pos < item_end_pos then
                      local other_take = reaper.GetActiveTake(other)
                      if other_take then
                        local other_len = reaper.GetMediaItemInfo_Value(other, "D_LENGTH")
                        local other_startoffs = reaper.GetMediaItemTakeInfo_Value(other_take, "D_STARTOFFS")
                        local other_playrate = reaper.GetMediaItemTakeInfo_Value(other_take, "D_PLAYRATE")
                        state.fade_drag_xfade_item = other
                        state.fade_drag_xfade_length = other_len
                        state.fade_drag_xfade_max_ext = math.max(0, other_startoffs / other_playrate)
                        state.fade_drag_xfade_pos = other_pos
                        state.fade_drag_xfade_startoffs = other_startoffs
                        state.fade_drag_xfade_playrate = other_playrate
                        state.fade_drag_xfade_fade_auto = reaper.GetMediaItemInfo_Value(other, "D_FADEINLEN_AUTO")
                      end
                      break
                    end
                  end
                end
              end
              state.fade_drag_xfade_env_shift = 0
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
              state.drag_alt_latched = alt_held
              state.marker_drag_activated = false
              local drag_offset = is_looped_item and state.unwrapped_start_offset or start_offset
              state.drag_start_offset = drag_offset
              state.drag_start_length = item_length
              state.drag_start_mouse_x = mouse_x
              state.drag_start_view_length = view_length
              state.drag_start_view_start = view_start
              state.drag_start_playrate = playrate
              state.drag_current_start = drag_offset
              state.drag_current_end = drag_offset + source_item_length
              state.drag_start_fade_in = fade_in_len
              state.drag_start_fade_out = fade_out_len
            elseif near_end then
              state.dragging_end = true
              state.drag_alt_latched = alt_held
              state.marker_drag_activated = false
              local drag_offset = is_looped_item and state.unwrapped_start_offset or start_offset
              state.drag_start_offset = drag_offset
              state.drag_start_length = item_length
              state.drag_start_mouse_x = mouse_x
              state.drag_start_view_length = view_length
              state.drag_start_view_start = view_start
              state.drag_start_playrate = playrate
              state.drag_current_start = drag_offset
              state.drag_current_end = drag_offset + source_item_length
              state.drag_start_fade_in = fade_in_len
              state.drag_start_fade_out = fade_out_len
            end
          end

          -- Alt+click in free zone: initiate zone drag (slides both markers, disabled when looped)
          if reaper.ImGui_IsMouseClicked(ctx, 0) and alt_held and mouse_in_free_zone
              and not is_looped_item
              and not state.dragging_start and not state.dragging_end
              and not state.dragging_fade_in and not state.dragging_fade_out
              and not state.dragging_fade_curve_in and not state.dragging_fade_curve_out
              and not state.is_ruler_dragging and not state.is_panning then
            state.dragging_zone = true
            state.dragging_start = true  -- reuse marker drag machinery
            state.drag_alt_latched = true
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
            if not state.undo_block_open then
              state.undo_block_open = "slide_both"
            end
          end

          -- Region selection: click+drag in waveform (sample & envelope tabs)
          if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_waveform
              and not (state.envelopes_visible
                  and (state.env_node_hovered_idx >= 0
                       or state.envelope_hovered_segment >= 0
                       or ctrl_held))
              and not state.dragging_start and not state.dragging_end
              and not state.dragging_fade_in and not state.dragging_fade_out
              and not state.dragging_fade_curve_in and not state.dragging_fade_curve_out
              and not near_start and not near_end
              and not near_fade_in and not near_fade_out
              and not alt_held and not shift_held then
            state.selecting_region = true
            state.selection_drag_activated = false
            state.selection_start_mouse_x = mouse_x
            state.selection_start_time = px_to_time(mouse_x)
            state.selection_end_time = state.selection_start_time
            -- Clear any existing finalized selection
            state.region_selected = false
          end

          -- Update region selection during drag
          if state.selecting_region and reaper.ImGui_IsMouseDown(ctx, 0) then
            if not state.selection_drag_activated then
              if math.abs(mouse_x - state.selection_start_mouse_x) >= state.marker_drag_threshold then
                state.selection_drag_activated = true
                -- Snap start time to grid when drag activates
                state.selection_start_time = snap_to_grid_if_enabled(state.selection_start_time)
              end
            end
            if state.selection_drag_activated then
              local raw_time = px_to_time(mouse_x)
              -- Clamp to visible view bounds (allows selecting in looped regions)
              raw_time = math.max(view_start, math.min(view_start + view_length, raw_time))
              state.selection_end_time = snap_to_grid_if_enabled(raw_time)
            end
          end

          -- Finalize selection on mouse release
          if reaper.ImGui_IsMouseReleased(ctx, 0) and state.selecting_region then
            state.selecting_region = false
            if state.selection_drag_activated then
              -- Normalize so start <= end
              local s = math.min(state.selection_start_time, state.selection_end_time)
              local e = math.max(state.selection_start_time, state.selection_end_time)
              -- Clamp to item extent (allows looped regions)
              local clamp_min = (is_looped_item or is_extended_drag) and ext_start or 0
              local clamp_max = (is_looped_item or is_extended_drag) and ext_end or source_length
              s = math.max(clamp_min, math.min(clamp_max, s))
              e = math.max(clamp_min, math.min(clamp_max, e))
              if e - s > 0.001 then  -- minimum 1ms selection
                state.region_selected = true
                state.region_sel_start = s
                state.region_sel_end = e
                state.region_sel_item = item
              end
            else
              -- Click without drag threshold: set preview cursor (existing behavior)
              state.preview_cursor_pos = px_to_time(mouse_x)
              if state.preview_active and state.preview_handle then
                reaper.CF_Preview_Stop(state.preview_handle)
                state.preview_handle = nil
                state.preview_active = false
              end
            end
          end

          -- Ctrl+C: copy selected region to REAPER clipboard
          if ctrl_held and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_C())
              and state.region_selected and state.region_sel_item == item then
            local sel_s = state.region_sel_start
            local sel_e = state.region_sel_end
            local new_length = (sel_e - sel_s) / playrate
            local new_startoffs = sel_s - section_offset
            -- Wrap D_STARTOFFS for looped/extended selections
            if source_length > 0 then
              new_startoffs = new_startoffs % source_length
            end

            reaper.PreventUIRefresh(1)

            -- Clone item via state chunk (preserves source reference, take properties)
            local _, chunk = reaper.GetItemStateChunk(item, "", false)
            local track = reaper.GetMediaItemTrack(item)
            local temp_item = reaper.AddMediaItemToTrack(track)
            reaper.SetItemStateChunk(temp_item, chunk, false)

            -- Adjust temp item properties via API
            local temp_take = reaper.GetActiveTake(temp_item)
            reaper.SetMediaItemTakeInfo_Value(temp_take, "D_STARTOFFS", new_startoffs)
            reaper.SetMediaItemInfo_Value(temp_item, "D_LENGTH", new_length)
            -- Clear fades on the copy
            reaper.SetMediaItemInfo_Value(temp_item, "D_FADEINLEN", 0)
            reaper.SetMediaItemInfo_Value(temp_item, "D_FADEOUTLEN", 0)
            reaper.SetMediaItemInfo_Value(temp_item, "D_FADEINLEN_AUTO", 0)
            reaper.SetMediaItemInfo_Value(temp_item, "D_FADEOUTLEN_AUTO", 0)
            reaper.UpdateItemInProject(temp_item)

            -- Adjust envelope points to match the selected region
            local env_delta = new_startoffs - take_offset  -- how much D_STARTOFFS moved
            local env_names = { "Volume", "Pitch", "Pan" }
            for _, ename in ipairs(env_names) do
              local e = temp_take and reaper.GetTakeEnvelopeByName(temp_take, ename)
              if e then
                local np = reaper.CountEnvelopePoints(e)
                if np > 0 then
                  -- Read all points, shifted to new time base
                  local pts = {}
                  for i = 0, np - 1 do
                    local ret, pt_time, pt_val, pt_shape, pt_tension, pt_sel =
                        reaper.GetEnvelopePoint(e, i)
                    if ret then
                      pts[#pts + 1] = {
                        time = pt_time - env_delta,
                        value = pt_val, shape = pt_shape,
                        tension = pt_tension, selected = pt_sel
                      }
                    end
                  end

                  -- Interpolate value at a given time from the shifted points list
                  local function interp_at(t)
                    for j = 1, #pts - 1 do
                      if pts[j].time <= t and pts[j + 1].time >= t then
                        local t0, t1 = pts[j].time, pts[j + 1].time
                        local v0, v1 = pts[j].value, pts[j + 1].value
                        if t1 - t0 < 0.000001 then return v0 end
                        local frac = (t - t0) / (t1 - t0)
                        return v0 + (v1 - v0) * frac
                      end
                    end
                    if #pts > 0 and t <= pts[1].time then return pts[1].value end
                    if #pts > 0 and t >= pts[#pts].time then return pts[#pts].value end
                    return 0
                  end

                  -- Build filtered list: only points inside [0, new_length]
                  local new_pts = {}
                  local has_start = false
                  local has_end = false

                  for _, p in ipairs(pts) do
                    if p.time >= 0 and p.time <= new_length then
                      if math.abs(p.time) < 0.0001 then has_start = true end
                      if math.abs(p.time - new_length) < 0.0001 then has_end = true end
                      new_pts[#new_pts + 1] = p
                    end
                  end

                  -- Add boundary points if needed (interpolated from original)
                  if not has_start then
                    local v = interp_at(0)
                    table.insert(new_pts, 1, {
                      time = 0, value = v, shape = 0, tension = 0, selected = false
                    })
                  end
                  if not has_end then
                    local v = interp_at(new_length)
                    new_pts[#new_pts + 1] = {
                      time = new_length, value = v, shape = 0, tension = 0, selected = false
                    }
                  end

                  -- Clear all original points and write the new ones
                  reaper.DeleteEnvelopePointRange(e, -1, new_length + 1)
                  for _, p in ipairs(new_pts) do
                    reaper.InsertEnvelopePoint(e, p.time, p.value, p.shape,
                        p.tension, p.selected, true)
                  end
                  reaper.Envelope_SortPoints(e)
                end
              end
            end

            -- Select only the temp item
            reaper.SetMediaItemSelected(item, false)
            reaper.SetMediaItemSelected(temp_item, true)

            -- Copy to REAPER clipboard
            reaper.Main_OnCommand(40698, 0)  -- Edit: Copy items

            -- Clean up: delete temp item, restore original selection
            reaper.DeleteTrackMediaItem(track, temp_item)
            reaper.SetMediaItemSelected(item, true)
            reaper.UpdateArrange()

            reaper.PreventUIRefresh(-1)
          end

          -- Envelope node interaction (create/drag/delete)
          if state.envelopes_visible and take then
            local env_name = state.envelope_type  -- "Volume", "Pitch", or "Pan"
            local is_pitch = (env_name == "Pitch")
            local is_pan = (env_name == "Pan")
            local is_centered = is_pitch or is_pan
            -- Envelope coordinate helpers: use live drag offset during drag, unwrapped for looped
            local env_offset
            if state.dragging_start or state.dragging_end then
              env_offset = state.drag_current_start or start_offset
            elseif is_looped_item then
              env_offset = state.unwrapped_start_offset or start_offset
            else
              env_offset = start_offset
            end
            local env_time_min = (is_looped_item or is_extended_drag) and ext_start or 0
            local env_time_max = (is_looped_item or is_extended_drag) and ext_end or source_length
            local env_max_raw = is_pitch and 24.0 or (is_pan and 1.0 or reaper.ScaleToEnvelopeMode(is_centered and 0 or 1, 2.0))
            local env_min_raw = is_pitch and -24.0 or (is_pan and -1.0 or 0)

            -- Helper: convert mouse Y to envelope raw value
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
                src_time = math.max(env_time_min, math.min(env_time_max, src_time))
                local take_time = src_time - env_offset
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
                  src_time = math.max(env_time_min, math.min(env_time_max, src_time))
                  local take_time = src_time - env_offset
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
                and not alt_held and not shift_held
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
                  local take_time = snapped_src - env_offset
                  reaper.InsertEnvelopePoint(env, take_time, state.envelope_hover_value, 0, 0, false, true)
                  reaper.Envelope_SortPoints(env)
                  -- Find the index of the point we just inserted (match time AND value for same-time nodes)
                  local new_idx = -1
                  local count = reaper.CountEnvelopePoints(env)
                  for pi = 0, count - 1 do
                    local retval, pt_time, pt_value = reaper.GetEnvelopePoint(env, pi)
                    if retval and math.abs(pt_time - take_time) < 0.0001
                       and math.abs(pt_value - state.envelope_hover_value) < 0.0001 then
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
                local hover_take_time = state.envelope_hover_time - env_offset
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
                local hover_take_time = state.envelope_hover_time - env_offset
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

            -- Shift+click on segment (not node): start segment drag (move both nodes vertically)
            if reaper.ImGui_IsMouseClicked(ctx, 0) and shift_held
                and not alt_held
                and state.envelope_hovered_segment >= 0
                and state.env_node_hovered_idx < 0
                and not state.dragging_env_node
                and not state.env_tension_dragging
                and not state.env_segment_dragging then
              local env = reaper.GetTakeEnvelopeByName(take, env_name)
              if env then
                local np = reaper.CountEnvelopePoints(env)
                local hover_take_time = state.envelope_hover_time - env_offset
                local found = false

                -- Check implicit left segment (before first REAPER point)
                if np > 0 and not found then
                  local ret0, t0, v0 = reaper.GetEnvelopePoint(env, 0)
                  if ret0 and hover_take_time < t0 + 0.001 then
                    state.env_segment_dragging = true
                    state.env_segment_idx1 = -1  -- implicit anchor
                    state.env_segment_idx2 = 0
                    state.env_segment_start_mouse_y = mouse_y
                    state.env_segment_start_val1 = v0  -- implicit has same value
                    state.env_segment_start_val2 = v0
                    state.env_segment_activated = false
                    if not state.undo_block_open then
                      state.undo_block_open = "env_segment"
                    end
                    found = true
                  end
                end

                -- Check segments between consecutive REAPER points
                if not found then
                  for pi = 0, np - 2 do
                    local ret1, t1, v1 = reaper.GetEnvelopePoint(env, pi)
                    local ret2, t2, v2 = reaper.GetEnvelopePoint(env, pi + 1)
                    if ret1 and ret2 and hover_take_time >= t1 - 0.001 and hover_take_time <= t2 + 0.001 then
                      state.env_segment_dragging = true
                      state.env_segment_idx1 = pi
                      state.env_segment_idx2 = pi + 1
                      state.env_segment_start_mouse_y = mouse_y
                      state.env_segment_start_val1 = v1
                      state.env_segment_start_val2 = v2
                      state.env_segment_activated = false
                      if not state.undo_block_open then
                        state.undo_block_open = "env_segment"
                      end
                      found = true
                      break
                    end
                  end
                end

                -- Check implicit right segment (after last REAPER point)
                if np > 0 and not found then
                  local retN, tN, vN = reaper.GetEnvelopePoint(env, np - 1)
                  if retN and hover_take_time > tN - 0.001 then
                    state.env_segment_dragging = true
                    state.env_segment_idx1 = np - 1
                    state.env_segment_idx2 = -1  -- implicit anchor
                    state.env_segment_start_mouse_y = mouse_y
                    state.env_segment_start_val1 = vN
                    state.env_segment_start_val2 = vN  -- implicit has same value
                    state.env_segment_activated = false
                    if not state.undo_block_open then
                      state.undo_block_open = "env_segment"
                    end
                  end
                end
              end
            end

            -- Alt+click or right-click: delete hovered node
            if ((reaper.ImGui_IsMouseClicked(ctx, 1)) or (reaper.ImGui_IsMouseClicked(ctx, 0) and alt_held))
                and state.env_node_hovered_idx >= 0
                and not state.dragging_env_node
                and not state.env_tension_dragging
                and not state.env_segment_dragging then
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
                  new_source_time = math.max(env_time_min, math.min(env_time_max, new_source_time))
                  new_source_time = snap_to_grid_if_enabled(new_source_time)
                  -- Convert source time to take time
                  local take_time = new_source_time - env_offset
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

            -- Segment drag: move both nodes vertically while shift+dragging
            if state.env_segment_dragging and reaper_is_active and reaper.ImGui_IsMouseDown(ctx, 0) then
              local dy = mouse_y - state.env_segment_start_mouse_y
              if not state.env_segment_activated and math.abs(dy) >= 4 then
                state.env_segment_activated = true
              end
              if state.env_segment_activated then
                local env = reaper.GetTakeEnvelopeByName(take, env_name)
                if env then
                  -- Convert pixel delta to value delta
                  local val_per_px = (env_max_raw - env_min_raw) / waveform_height
                  local delta_val = -dy * val_per_px  -- negative because Y increases downward

                  -- Clamp: only consider real nodes (idx >= 0) for range limiting
                  if state.env_segment_idx1 >= 0 then
                    local nv1 = state.env_segment_start_val1 + delta_val
                    if nv1 > env_max_raw then delta_val = delta_val - (nv1 - env_max_raw)
                    elseif nv1 < env_min_raw then delta_val = delta_val - (nv1 - env_min_raw) end
                  end
                  if state.env_segment_idx2 >= 0 then
                    local nv2 = state.env_segment_start_val2 + delta_val
                    if nv2 > env_max_raw then delta_val = delta_val - (nv2 - env_max_raw)
                    elseif nv2 < env_min_raw then delta_val = delta_val - (nv2 - env_min_raw) end
                  end

                  local new_val1 = math.max(env_min_raw, math.min(env_max_raw, state.env_segment_start_val1 + delta_val))
                  local new_val2 = math.max(env_min_raw, math.min(env_max_raw, state.env_segment_start_val2 + delta_val))

                  -- Pitch: snap to semitones if enabled
                  if is_pitch and state.env_snap_enabled then
                    new_val1 = math.floor(new_val1 + 0.5)
                    new_val2 = math.floor(new_val2 + 0.5)
                  end

                  if state.env_segment_idx1 >= 0 then
                    local ret1, t1, _, s1, tn1, sel1 = reaper.GetEnvelopePoint(env, state.env_segment_idx1)
                    if ret1 then
                      reaper.SetEnvelopePoint(env, state.env_segment_idx1, t1, new_val1, s1, tn1, sel1, true)
                    end
                  end
                  if state.env_segment_idx2 >= 0 then
                    local ret2, t2, _, s2, tn2, sel2 = reaper.GetEnvelopePoint(env, state.env_segment_idx2)
                    if ret2 then
                      reaper.SetEnvelopePoint(env, state.env_segment_idx2, t2, new_val2, s2, tn2, sel2, true)
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
              and not state.selecting_region
              and not state.dragging_start and not state.dragging_end
              and not state.dragging_fade_in and not state.dragging_fade_out
              and not state.dragging_fade_curve_in and not state.dragging_fade_curve_out
              and not state.dragging_env_node and not state.env_freehand_drawing
              and not near_start and not near_end
              and not near_fade_in and not near_fade_out
              and not alt_held
              and not (state.envelopes_visible and (state.env_node_hovered_idx >= 0 or state.envelope_hovered_segment >= 0 or reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl()))) then
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
              -- Envelope points are now shifted in realtime during drag, no batch shift needed
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
              local undo_msg
              if state.dragging_zone then
                undo_msg = "NVSD_ItemView: Slide item"
              else
                undo_msg = state.dragging_start and "NVSD_ItemView: Adjust item start" or "NVSD_ItemView: Adjust item end"
              end
              reaper.Undo_OnStateChangeEx(undo_msg, -1, -1)
            elseif (state.dragging_start or state.dragging_end) and not state.marker_drag_activated
                and not state.dragging_zone then
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
              reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN_AUTO", 0)
              reaper.SetMediaItemInfo_Value(item, "D_FADEINDIR", 0)
              reaper.UpdateArrange()
              reaper.Undo_EndBlock("NVSD_ItemView: Remove fade in", -1)
            elseif state.dragging_fade_curve_out and not state.fade_curve_was_dragged then
              reaper.Undo_BeginBlock()
              reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", 0)
              reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN_AUTO", 0)
              reaper.SetMediaItemInfo_Value(item, "D_FADEOUTDIR", 0)
              reaper.UpdateArrange()
              reaper.Undo_EndBlock("NVSD_ItemView: Remove fade out", -1)
            end
            state.dragging_start = false
            state.dragging_end = false
            state.dragging_zone = false
            state.drag_alt_latched = false
            state.marker_drag_activated = false
            state.dragging_fade_in = false
            state.dragging_fade_out = false
            state.fade_drag_xfade_item = nil
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
            state.env_segment_dragging = false
            state.env_segment_activated = false
            state.env_segment_idx1 = -1
            state.env_segment_idx2 = -1
          end

          -- Mouse button 4/5 quick marker positioning
          if mouse_in_waveform or mouse_in_marker_area then
            local clicked_mouse4 = reaper.ImGui_IsMouseClicked(ctx, 4)
            local clicked_mouse5 = reaper.ImGui_IsMouseClicked(ctx, 3)

            if clicked_mouse4 or clicked_mouse5 then
              local click_time = px_to_time(mouse_x)

              if shift_held then
                -- Set fade length so fade boundary lands at click position
                reaper.Undo_BeginBlock()

                if clicked_mouse4 then
                  -- Fade-in ends at click position
                  local new_fi = (click_time - start_offset) / playrate
                  new_fi = math.max(0, math.min(item_length, new_fi))
                  local fo = fade_out_len
                  if new_fi + fo > item_length then
                    fo = math.max(0, item_length - new_fi)
                  end
                  reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", new_fi)
                  reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN_AUTO", 0)
                  reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", fo)
                  reaper.UpdateArrange()
                  reaper.Undo_EndBlock("NVSD_ItemView: Set fade-in position", -1)

                elseif clicked_mouse5 then
                  -- Fade-out starts at click position
                  local current_end = start_offset + source_item_length
                  local new_fo = (current_end - click_time) / playrate
                  new_fo = math.max(0, math.min(item_length, new_fo))
                  local fi = fade_in_len
                  if fi + new_fo > item_length then
                    fi = math.max(0, item_length - new_fo)
                  end
                  reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", new_fo)
                  reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN_AUTO", 0)
                  reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", fi)
                  reaper.UpdateArrange()
                  reaper.Undo_EndBlock("NVSD_ItemView: Set fade-out position", -1)
                end

              else
                -- Existing marker positioning logic
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
                  -- Shift envelope points so they stay audio-anchored
                  if not state.envelope_lock then
                    local offset_delta = new_take_offset - take_offset
                    if math.abs(offset_delta) > 0.000001 then
                      local env_names = { "Volume", "Pitch", "Pan" }
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
                    end
                  end
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
          end

          local snap_threshold_time = (config.SNAP_THRESHOLD_PX / waveform_width) * view_length

          -- Marker drag threshold: don't move markers until mouse exceeds threshold
          if (state.dragging_start or state.dragging_end) and not state.marker_drag_activated
              and reaper_is_active and reaper.ImGui_IsMouseDown(ctx, 0) then
            if math.abs(mouse_x - state.drag_start_mouse_x) >= state.marker_drag_threshold then
              state.marker_drag_activated = true
            end
          end

          -- Alt+drag: slide both markers (alt latched at drag start, releasing alt mid-drag keeps sliding)
          if (state.dragging_start or state.dragging_end) and state.marker_drag_activated and state.drag_alt_latched and reaper_is_active and reaper.ImGui_IsMouseDown(ctx, 0) then
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
            -- Shift envelope points in realtime so they stay audio-anchored in arrange view
            if not state.envelope_lock then
              local offset_delta = new_take_offset - take_offset
              if math.abs(offset_delta) > 0.000001 then
                local env_names = { "Volume", "Pitch", "Pan" }
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
              end
            end
            reaper.UpdateArrange()

          -- Dragging start marker
          elseif state.dragging_start and state.marker_drag_activated and not state.dragging_zone
              and reaper_is_active and reaper.ImGui_IsMouseDown(ctx, 0) then
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
            -- Wrap for REAPER when extending past source boundaries
            if source_length > 0 then
              new_take_offset = new_take_offset % source_length
            end

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
            -- Shift envelope points in realtime so they stay audio-anchored in arrange view
            if not state.envelope_lock then
              local offset_delta = new_take_offset - take_offset
              -- Unwrap delta when crossing source boundary to avoid huge jumps
              if source_length > 0 then
                if offset_delta > source_length * 0.5 then
                  offset_delta = offset_delta - source_length
                elseif offset_delta < -source_length * 0.5 then
                  offset_delta = offset_delta + source_length
                end
              end
              if math.abs(offset_delta) > 0.000001 then
                local env_names = { "Volume", "Pitch", "Pan" }
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
              end
            end
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
            -- Crossfade resize: extend or contract adjacent item to match fade size
            local xfade_item = state.fade_drag_xfade_item
            if xfade_item and reaper.ValidatePtr(xfade_item, "MediaItem*") and state.fade_drag_start_auto > 0 then
              -- extension > 0 = grow crossfade, < 0 = shrink crossfade
              local extension = fi - state.fade_drag_start_auto
              extension = math.min(extension, state.fade_drag_xfade_max_ext)
              fi = state.fade_drag_start_auto + extension
              -- Adjust left item's length (no position/startoffs change, so envelopes stay put)
              reaper.SetMediaItemInfo_Value(xfade_item, "D_LENGTH", state.fade_drag_xfade_length + extension)
              reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN_AUTO", fi)
              if state.fade_drag_xfade_fade_auto > 0 then
                reaper.SetMediaItemInfo_Value(xfade_item, "D_FADEOUTLEN_AUTO", fi)
              end
            elseif state.fade_drag_start_auto > 0 then
              reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN_AUTO", math.min(fi, state.fade_drag_start_auto))
            end
            -- Push fade-out: cap at remaining space, but never grow past its initial value
            local fo = math.min(state.fade_drag_start_other, math.max(0, item_length - fi))
            reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", fi)
            reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", fo)
            if state.fade_drag_start_auto_other > 0 and fo < state.fade_drag_start_auto_other then
              reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN_AUTO", fo)
            end
            reaper.UpdateArrange()
          elseif state.dragging_fade_out and reaper_is_active and reaper.ImGui_IsMouseDown(ctx, 0) then
            local delta_px = state.fade_drag_start_mouse_x - mouse_x  -- reversed: drag left = more fade
            local delta_time = (delta_px / waveform_width) * state.fade_drag_start_view_length
            local fo = math.max(0, state.fade_drag_start_value + delta_time / playrate)
            fo = math.min(fo, item_length)
            -- Crossfade resize: extend or contract adjacent item to match fade size
            local xfade_item = state.fade_drag_xfade_item
            if xfade_item and reaper.ValidatePtr(xfade_item, "MediaItem*") and state.fade_drag_start_auto > 0 then
              -- extension > 0 = grow crossfade, < 0 = shrink crossfade
              local extension = fo - state.fade_drag_start_auto
              extension = math.min(extension, state.fade_drag_xfade_max_ext)
              fo = state.fade_drag_start_auto + extension
              -- Adjust right item: move position and startoffs to keep audio aligned
              reaper.SetMediaItemInfo_Value(xfade_item, "D_POSITION", state.fade_drag_xfade_pos - extension)
              reaper.SetMediaItemInfo_Value(xfade_item, "D_LENGTH", state.fade_drag_xfade_length + extension)
              local adj_take = reaper.GetActiveTake(xfade_item)
              if adj_take then
                reaper.SetMediaItemTakeInfo_Value(adj_take, "D_STARTOFFS",
                  state.fade_drag_xfade_startoffs - extension * state.fade_drag_xfade_playrate)
              end
              reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN_AUTO", fo)
              if state.fade_drag_xfade_fade_auto > 0 then
                reaper.SetMediaItemInfo_Value(xfade_item, "D_FADEINLEN_AUTO", fo)
              end
              -- Shift adjacent item's envelopes to stay audio-anchored (compensate D_STARTOFFS change)
              local target_shift = extension * state.fade_drag_xfade_playrate
              local delta_shift = target_shift - state.fade_drag_xfade_env_shift
              if math.abs(delta_shift) > 0.000001 then
                if adj_take then
                  local env_names = { "Volume", "Pitch", "Pan" }
                  for _, ename in ipairs(env_names) do
                    local e = reaper.GetTakeEnvelopeByName(adj_take, ename)
                    if e then
                      local np = reaper.CountEnvelopePoints(e)
                      for ei = 0, np - 1 do
                        local ret, pt_time, pt_val, pt_shape, pt_tension, pt_sel = reaper.GetEnvelopePoint(e, ei)
                        if ret then
                          reaper.SetEnvelopePoint(e, ei, pt_time + delta_shift, pt_val, pt_shape, pt_tension, pt_sel, true)
                        end
                      end
                      reaper.Envelope_SortPoints(e)
                    end
                  end
                end
                state.fade_drag_xfade_env_shift = target_shift
              end
            elseif state.fade_drag_start_auto > 0 then
              reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN_AUTO", math.min(fo, state.fade_drag_start_auto))
            end
            -- Push fade-in: cap at remaining space, but never grow past its initial value
            local fi = math.min(state.fade_drag_start_other, math.max(0, item_length - fo))
            reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", fo)
            reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", fi)
            if state.fade_drag_start_auto_other > 0 and fi < state.fade_drag_start_auto_other then
              reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN_AUTO", fi)
            end
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
              fade_in_dir = new_dir  -- update local for immediate draw
            else
              new_dir = state.fade_curve_drag_start_value + state.fade_curve_cumulative_y * sensitivity
              new_dir = math.max(-1, math.min(1, new_dir))
              state.fade_curve_cumulative_y = (new_dir - state.fade_curve_drag_start_value) / sensitivity
              reaper.SetMediaItemInfo_Value(item, "D_FADEOUTDIR", new_dir)
              fade_out_dir = new_dir  -- update local for immediate draw
            end
            reaper.UpdateArrange()
          end

          -- Alt-hover free zone highlight
          if alt_held and mouse_in_free_zone and not we_are_dragging then
            reaper.ImGui_DrawList_AddRectFilled(draw_list,
              start_marker_x, wave_y, end_marker_x, wave_y + waveform_height, 0xFFFFFF08)
          end

          -- Draw region selection overlay
          if (state.selecting_region and state.selection_drag_activated) or state.region_selected then
            local sel_s, sel_e
            if state.selecting_region then
              sel_s = math.min(state.selection_start_time, state.selection_end_time)
              sel_e = math.max(state.selection_start_time, state.selection_end_time)
            else
              sel_s = state.region_sel_start
              sel_e = state.region_sel_end
            end
            local sel_px_start = math.max(wave_x, time_to_px(sel_s))
            local sel_px_end = math.min(wave_x + waveform_width, time_to_px(sel_e))
            if sel_px_end > sel_px_start then
              -- Filled overlay
              reaper.ImGui_DrawList_AddRectFilled(draw_list,
                sel_px_start, wave_y, sel_px_end, wave_y + waveform_height,
                config.COLOR_SELECTION)
              -- Edge lines
              reaper.ImGui_DrawList_AddLine(draw_list,
                sel_px_start, wave_y, sel_px_start, wave_y + waveform_height,
                config.COLOR_SELECTION_EDGE, 1)
              reaper.ImGui_DrawList_AddLine(draw_list,
                sel_px_end, wave_y, sel_px_end, wave_y + waveform_height,
                config.COLOR_SELECTION_EDGE, 1)
            end
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
              -- Wrap to source coordinates for looped/extended items
              local source_pos = pos
              if source_length > 0 then
                source_pos = pos % source_length
                if source_pos < 0 then source_pos = source_pos + source_length end
              end
              local handle = reaper.CF_CreatePreview(source)
              if handle then
                reaper.CF_Preview_SetValue(handle, "D_POSITION", source_pos)
                reaper.CF_Preview_SetValue(handle, "D_VOLUME", item_vol)
                -- Loop when playing in a looped/extended item so preview crosses source boundaries
                local needs_loop = is_looped_item or is_extended_drag
                reaper.CF_Preview_SetValue(handle, "B_LOOP", needs_loop and 1 or 0)
                local track = reaper.GetMediaItemTrack(item)
                if track then
                  reaper.CF_Preview_SetOutputTrack(handle, 0, track)
                end
                reaper.CF_Preview_Play(handle)
                state.preview_handle = handle
                state.preview_active = true
                state.preview_item = item
                -- Track virtual position for looped playhead drawing
                state.preview_virtual_start = pos
                state.preview_start_realtime = reaper.time_precise()
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
                -- Compute virtual playhead position (supports looped items)
                local virtual_pos
                if state.preview_virtual_start and state.preview_start_realtime then
                  local elapsed = reaper.time_precise() - state.preview_start_realtime
                  virtual_pos = state.preview_virtual_start + elapsed
                else
                  virtual_pos = pos
                end
                -- Draw moving preview playhead
                local preview_px = time_to_px(virtual_pos)
                if preview_px >= wave_x and preview_px <= wave_x + waveform_width then
                  drawing.draw_preview_playhead(draw_list, preview_px, wave_y, waveform_height)
                end
                -- Auto-stop: past item extent for looped, past source end for normal
                local stop_pos = (is_looped_item or is_extended_drag) and ext_end or source_length
                if virtual_pos >= stop_pos then
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
          drawing.draw_envelope_dropdown(draw_list, ctx, wave_x, envelope_bar_y,
            config.ENVELOPE_BAR_HEIGHT, mouse_x, mouse_y, config, state)

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
    state.env_segment_dragging = false
    state.env_segment_activated = false
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
