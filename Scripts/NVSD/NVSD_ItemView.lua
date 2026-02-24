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

-- Wire up cross-module dependencies
settings_ui.set_drawing(drawing)

-- Initialize settings
config.settings = settings
settings.load()
state.apply_defaults(settings)
config.refresh_colors()

-- Convert REAPER native color (0x00BBGGRR on Windows) to ImGui (0xRRGGBBAA)
local function reaper_color_to_imgui(native_color)
  local r = native_color % 256
  local g = math.floor(native_color / 256) % 256
  local b = math.floor(native_color / 65536) % 256
  return r * 0x1000000 + g * 0x10000 + b * 0x100 + 0xFF
end

-- One-time check: recommend JS_ReaScriptAPI if missing
if not reaper.JS_Mouse_SetPosition then
  local dismissed = reaper.GetExtState("NVSD_ItemView", "js_ext_dismissed")
  if dismissed ~= "1" then
    local msg = "NVSD ItemView works best with the JS_ReaScriptAPI extension.\n\n"
        .. "Without it, knob/slider dragging has limited range (cursor can hit screen edges).\n\n"
    if reaper.ReaPack_BrowsePackages then
      msg = msg .. "Click OK to open ReaPack and install it, or Cancel to skip."
      local ret = reaper.ShowMessageBox(msg, "NVSD ItemView - Optional Extension", 1)
      if ret == 1 then
        reaper.ReaPack_BrowsePackages("js_ReaScriptAPI")
      end
    else
      msg = msg .. "Install via ReaPack: Extensions > ReaPack > Browse Packages > search \"js_ReaScriptAPI\"\n"
          .. "Or download from: github.com/juliansader/ReaExtensions"
      reaper.ShowMessageBox(msg, "NVSD ItemView - Optional Extension", 0)
    end
    reaper.SetExtState("NVSD_ItemView", "js_ext_dismissed", "1", true)
  end
end

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
local lib_files = {"config", "state", "utils", "drawing", "controls", "settings", "settings_ui", "fade_curves"}
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
  -- Try action first (only for types with known action IDs)
  local action_ids = { Volume = 40693, Pitch = 40714, Pan = 40694 }
  local action_id = action_ids[env_name]
  if action_id then
    reaper.SetMediaItemSelected(item, true)
    reaper.SetActiveTake(take)
    reaper.Main_OnCommand(action_id, 0)
    env = reaper.GetTakeEnvelopeByName(take, env_name)
    if env then return env end
  end
  -- Fallback: inject envelope via item state chunk
  local chunk_tag = ({ Volume = "VOLENV2", Pitch = "PITCHENV", Pan = "PANENV2" })[env_name]
  if not chunk_tag then return nil end
  local _, chunk = reaper.GetItemStateChunk(item, "", false)
  if chunk:find("<" .. chunk_tag) then return reaper.GetTakeEnvelopeByName(take, env_name) end
  local env_chunk = "<" .. chunk_tag .. "\nACT 1 -1\nVIS 1 1 1\nLANEHEIGHT 0 0\nARM 0\nDEFSHAPE 0 -1 -1\nPT 0 0 0\n>\n"
  -- Find the active take's GUID and inject envelope inside that take section
  local take_guid = reaper.BR_GetMediaItemTakeGUID(take)
  if take_guid then
    local guid_str = "{" .. take_guid .. "}"
    local take_pos = chunk:find(guid_str, 1, true)
    if take_pos then
      -- Find the next ">" that closes this take section (after all nested blocks)
      -- Walk forward from take_pos to find the take's closing ">"
      local depth = 0
      local insert_pos = nil
      for i = take_pos, #chunk do
        local c = chunk:sub(i, i)
        if c == "<" then depth = depth + 1
        elseif c == ">" then
          if depth > 0 then depth = depth - 1
          else insert_pos = i; break end
        end
      end
      if insert_pos then
        chunk = chunk:sub(1, insert_pos - 1) .. env_chunk .. chunk:sub(insert_pos)
        reaper.SetItemStateChunk(item, chunk, false)
        reaper.UpdateItemInProject(item)
        reaper.UpdateArrange()
        return reaper.GetTakeEnvelopeByName(take, env_name)
      end
    end
  end
  -- Last resort: insert before item's closing >
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
  -- Check heartbeat: if the running instance hasn't checked in for 3+ seconds, it crashed
  local heartbeat = tonumber(reaper.GetExtState("NVSD_ItemView", "heartbeat")) or 0
  if reaper.time_precise() - heartbeat < 3 then
    reaper.SetExtState("NVSD_ItemView", "close_requested", "1", false)
    return
  end
  -- Stale instance detected, take over
end
local window_visible = true  -- visibility state for docker switching
reaper.SetExtState("NVSD_ItemView", "running", "1", false)
reaper.SetExtState("NVSD_ItemView", "heartbeat", tostring(reaper.time_precise()), false)
reaper.SetExtState("NVSD_ItemView", "visible", "1", false)
reaper.DeleteExtState("NVSD_ItemView", "close_requested", false)
if toggle_cmd_id > 0 then
  reaper.SetToggleCommandState(toggle_section_id, toggle_cmd_id, 1)
  reaper.RefreshToolbar2(toggle_section_id, toggle_cmd_id)
end
reaper.atexit(function()
  reaper.SetExtState("NVSD_ItemView", "running", "0", false)
  reaper.SetExtState("NVSD_ItemView", "visible", "0", false)
  reaper.DeleteExtState("NVSD_ItemView", "close_requested", false)
  reaper.DeleteExtState("NVSD_ItemView", "heartbeat", false)
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
      state.reset_all_drags()
      state.undo_block_open = nil
      state.was_mouse_down = false
      state.invalidate_view_peaks()
      drawing.clear_icon_cache()
      settings_ui.clear_icon_cache()
      -- Stop audio preview on dialog recovery
      state.stop_preview()
      state.preview_start_requested = false
    end
    reaper.defer(loop)
    return
  end

  -- Everything below is wrapped in pcall to catch Lua-level errors.
  local open = true
  local needs_reload = false

  local ok, err = pcall(function()

  -- Update heartbeat so stale-instance detection works
  reaper.SetExtState("NVSD_ItemView", "heartbeat", tostring(reaper.time_precise()), false)

  -- Publish visibility for docker switching
  reaper.SetExtState("NVSD_ItemView", "visible", window_visible and "1" or "0", false)

  -- Handle show/hide requests from DockerSwitch
  if reaper.GetExtState("NVSD_ItemView", "show_requested") == "1" then
    reaper.DeleteExtState("NVSD_ItemView", "show_requested", false)
    window_visible = true
  end
  if reaper.GetExtState("NVSD_ItemView", "hide_requested") == "1" then
    reaper.DeleteExtState("NVSD_ItemView", "hide_requested", false)
    window_visible = false
  end

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
    state.reset_all_drags()
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
    state.stop_preview()
    open = false  -- signal outer loop() to stop deferring
    return
  end

  -- Skip rendering when hidden (docker switch)
  if not window_visible then
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

    -- Raw VKey rising-edge detection for Ctrl/Cmd+C (macOS: REAPER may consume
    -- Cmd+C before ImGui sees it, so ImGui_IsKeyPressed(Key_C) never fires).
    -- VK_CONTROL (0x11) maps to Cmd on macOS SWELL, Ctrl on Windows.
    local vkey_copy_pressed = false
    if state.has_js_extension then
      local vks = reaper.JS_VKeys_GetState(-1)
      local combo_now = vks:byte(0x44) ~= 0 and vks:byte(0x12) ~= 0  -- VK_C + VK_CONTROL
      vkey_copy_pressed = combo_now and not state._copy_combo_prev
      state._copy_combo_prev = combo_now
    end

    -- Skip all keyboard shortcuts when a popup modal is open (e.g. toolbar edit, icon picker, settings)
    -- IsPopupOpen checks the popup stack from the previous frame, so it works before widgets are drawn
    local text_input_active = reaper.ImGui_IsPopupOpen(ctx, "Edit Toolbar Button##tb_edit")
                           or reaper.ImGui_IsPopupOpen(ctx, "Choose Icon##tb_icon_pick")
                           or reaper.ImGui_IsPopupOpen(ctx, "Choose Icon Direct##tb_icon_direct")
                           or settings_ui.is_open()

    -- When a popup modal is open, suppress waveform mouse interaction so popup gets full input
    if text_input_active then reaper_is_active = false end

    -- Auto-focus window when hovered with Ctrl held (enables scroll-to-zoom without clicking first)
    -- Skip when a popup modal is open (SetWindowFocus would steal focus from the popup)
    local is_hovered = reaper.ImGui_IsWindowHovered(ctx, reaper.ImGui_HoveredFlags_ChildWindows())
    if reaper_is_active and is_hovered and ctrl_held and not text_input_active
        and not reaper.ImGui_IsWindowFocused(ctx) then
      reaper.ImGui_SetWindowFocus(ctx)
    end

    -- Audio preview (configurable shortcut, default Ctrl+Space)
    if reaper_is_active and not text_input_active and settings.check_shortcut(ctx, "audio_preview") and reaper.CF_CreatePreview then
      state.preview_start_requested = true  -- processed in item context where source is available

    -- Preview from start marker (configurable, default Enter)
    elseif reaper_is_active and not text_input_active and not settings.listening and settings.check_shortcut(ctx, "preview_from_start") then
      state.preview_from_start_requested = true  -- processed in item context where ext_start is available

    -- Forward Space to REAPER transport (so playback works without clicking back to timeline)
    -- Plain Space while preview is playing: stop preview instead of toggling transport
    elseif reaper_is_active and not text_input_active and not settings.listening and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Space()) then
      if state.preview_active then
        state.stop_preview()
      else
        reaper.Main_OnCommand(40044, 0)  -- Transport: Play/Stop
      end
    end

    -- Forward undo/redo to REAPER (universal, not configurable)
    if reaper_is_active and not text_input_active and not settings.listening and ctrl_held then
      if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Z()) and not shift_held
          and #state.wf_zoom_history > 0 then
        -- Undo waveform zoom first (before passing to REAPER)
        local n = #state.wf_zoom_history
        state.waveform_zoom = state.wf_zoom_history[n]
        state.wf_zoom_history[n] = nil
      elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Z()) and not shift_held
          and settings.toolbar_can_undo() then
        settings.toolbar_undo()
      elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Y())
          and settings.toolbar_can_redo() then
        settings.toolbar_redo()
      elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Z()) then
        reaper.Main_OnCommand(shift_held and 40030 or 40029, 0)  -- Shift: Redo, else Undo
      elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Y()) then
        reaper.Main_OnCommand(40030, 0)  -- Redo
      end
    end

    -- Flush waveform zoom scroll gesture to undo history after 0.6s of no scrolling
    if state.wf_zoom_scroll_anchor
        and reaper.time_precise() - state.wf_zoom_scroll_time > 0.6 then
      if state.wf_zoom_scroll_anchor ~= state.waveform_zoom then
        table.insert(state.wf_zoom_history, state.wf_zoom_scroll_anchor)
      end
      state.wf_zoom_scroll_anchor = nil
    end

    -- Zoom shortcuts
    if reaper_is_active and not text_input_active and settings.check_shortcut(ctx, "zoom_in") then
      state.zoom_level = math.min(500.0, state.zoom_level * 1.5)
      state.zoom_toggle_active = false
    elseif reaper_is_active and not text_input_active and settings.check_shortcut(ctx, "zoom_out") then
      state.zoom_level = math.max(1.0, state.zoom_level / 1.5)
      state.zoom_toggle_active = false
    elseif reaper_is_active and not text_input_active and settings.check_shortcut(ctx, "reset_zoom") then
      state.zoom_level = 1.0
      state.pan_offset = 0
      state.zoom_toggle_active = false
    elseif reaper_is_active and not text_input_active and settings.check_shortcut(ctx, "unzoom_all") then
      state.zoom_level = 1.0
      state.pan_offset = 0
      state.zoom_toggle_active = false
    end

    -- Toggle envelope snap (configurable shortcut, default Ctrl+4)
    if reaper_is_active and not text_input_active and settings.check_shortcut(ctx, "toggle_snap") then
      state.env_snap_enabled = not state.env_snap_enabled
    end

    -- Envelope lock (configurable shortcut, default L)
    if reaper_is_active and not text_input_active and settings.check_shortcut(ctx, "envelope_lock") then
      state.envelope_lock = not state.envelope_lock
    end

    -- Show/hide envelope shortcuts
    if reaper_is_active and not text_input_active and settings.check_shortcut(ctx, "show_volume_env") then
      state.envelope_type = "Volume"; state.envelopes_visible = true
    end
    if reaper_is_active and not text_input_active and settings.check_shortcut(ctx, "show_pitch_env") then
      state.envelope_type = "Pitch"; state.envelopes_visible = true; state.pitch_view_offset = 0
    end
    if reaper_is_active and not text_input_active and settings.check_shortcut(ctx, "show_pan_env") then
      state.envelope_type = "Pan"; state.envelopes_visible = true
    end
    if reaper_is_active and not text_input_active and settings.check_shortcut(ctx, "hide_envelopes") then
      state.envelopes_visible = false
    end

    -- Toggle WAV cue markers (configurable shortcut, default T)
    if reaper_is_active and not text_input_active and settings.check_shortcut(ctx, "toggle_cue_markers") then
      state.show_cue_markers = not state.show_cue_markers
    end

    -- Toggle ghost markers (configurable shortcut, default G)
    if reaper_is_active and not text_input_active and settings.check_shortcut(ctx, "toggle_ghost_markers") then
      state.show_ghost_markers = not state.show_ghost_markers
    end

    -- Open settings (configurable shortcut, default S)
    if reaper_is_active and not text_input_active and settings.check_shortcut(ctx, "open_settings") then
      if not settings_ui.is_open() then settings_ui.open(settings) end
    end

    -- Escape: clear node selection first, then region selection, then close
    if not text_input_active and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
      if #state.env_selected_nodes > 0 then
        state.env_selected_nodes = {}
      elseif state.region_selected then
        state.region_selected = false
      else
        open = false
      end
    end

    -- Delete / Backspace: remove selected envelope nodes (Backspace for Mac compatibility)
    if not text_input_active
        and (reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Delete())
          or reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Backspace()))
        and #state.env_selected_nodes > 0 and state.envelopes_visible then
      local env_n = state.env_selection_env_name
      local sel_item = state.env_selection_item
      if env_n and sel_item then
        local sel_take = reaper.GetActiveTake(sel_item)
        if sel_take then
          local env = reaper.GetTakeEnvelopeByName(sel_take, env_n)
          if env then
            reaper.Undo_BeginBlock()
            local sel_env_offset_value = state.env_selection_env_offset or 0
            local indices_to_delete = {}
            local count = reaper.CountEnvelopePoints(env)
            for pi = 0, count - 1 do
              local ret, pt_time, pt_value = reaper.GetEnvelopePoint(env, pi)
              if ret then
                local pt_src = pt_time + sel_env_offset_value
                for _, sel in ipairs(state.env_selected_nodes) do
                  if math.abs(pt_src - sel.src_time) < 0.0001
                      and math.abs(pt_value - sel.value) < 0.0001 then
                    table.insert(indices_to_delete, pi)
                    break
                  end
                end
              end
            end
            table.sort(indices_to_delete, function(a, b) return a > b end)
            for _, idx in ipairs(indices_to_delete) do
              reaper.DeleteEnvelopePointEx(env, -1, idx)
            end
            reaper.Envelope_SortPoints(env)
            reaper.UpdateArrange()
            reaper.Undo_EndBlock("NVSD_ItemView: Delete envelope points", -1)
            state.env_selected_nodes = {}
          end
        end
      end
    end

    -- Refresh colors only when settings change
    if settings.colors_dirty then
      config.refresh_colors()
      settings.colors_dirty = false
    end

    -- Draw settings UI if open
    settings_ui.draw(ctx, settings)
    if settings_ui.defaults_changed then
      state.apply_defaults(settings)
      settings_ui.defaults_changed = false
    end

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
          env_multi_node = "NVSD_ItemView: Move envelope points",
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
        -- Save current item's waveform zoom, load new item's zoom
        if state.last_selected_item then
          state.wf_zoom_per_item[state.last_selected_item] = state.waveform_zoom
        end
        state.waveform_zoom = state.wf_zoom_per_item[selected_item] or 1.0
        state.wf_zoom_history = {}
        state.wf_zoom_scroll_anchor = nil
        -- Switched to a different item: clear sticky, preview, region, auto-switch envelopes
        state.sticky_item = nil
        state.sticky_item_valid = false
        state.sticky_validation_counter = 0
        state.stop_preview()
        state.preview_cursor_pos = nil
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
            state.envelopes_visible = settings.current.defaults.auto_show_envelopes
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

    -- Execute deferred toolbar action (before item resolution so pointers stay fresh)
    if state._tb_pending_cmd then
      state._tb_id = tonumber(state._tb_pending_cmd) or reaper.NamedCommandLookup(state._tb_pending_cmd)
      if state._tb_id and state._tb_id > 0 then
        reaper.Main_OnCommand(state._tb_id, 0)
      end
      state._tb_pending_cmd = nil
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
      state.warp_markers_take = nil
      state.transients_source = nil
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
      if take and not text_input_active then
        -- Toggle WARP (preserve pitch) - keyboard shortcut mirrors button behavior
        if settings.check_shortcut(ctx, "toggle_warp") then
          if not state.warp_saved_markers_map then state.warp_saved_markers_map = {} end
          if not state.warp_mode then
            -- Turning ON
            local take_guid = reaper.BR_GetMediaItemTakeGUID(take)
            local saved = take_guid and state.warp_saved_markers_map[take_guid]
            if saved and #saved > 0 then
              state.warp_restore_popup_open = true
              state.warp_restore_take = take
              state.warp_restore_guid = take_guid
            else
              reaper.Undo_BeginBlock()
              utils.enable_warp(take)
              reaper.UpdateArrange()
              reaper.Undo_EndBlock("NVSD_ItemView: Toggle WARP", -1)
            end
          else
            -- Turning OFF
            reaper.Undo_BeginBlock()
            utils.disable_warp(take, state)
            reaper.UpdateArrange()
            reaper.Undo_EndBlock("NVSD_ItemView: Toggle WARP", -1)
          end
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
          utils.reverse_item(item, state)
        end

        -- Clear pitch/speed (Shift+C)
        if settings.check_shortcut(ctx, "clear") then
          reaper.Undo_BeginBlock()
          local cur_pr = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
          local cur_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
          local orig_len = cur_len * cur_pr
          reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", 0)
          reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", 1.0)
          reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 0)
          reaper.SetMediaItemInfo_Value(item, "D_LENGTH", orig_len)
          utils.clamp_fades_to_length(item, orig_len)
          reaper.UpdateArrange()
          reaper.Undo_EndBlock("NVSD_ItemView: Clear pitch/speed", -1)
        end

        -- Open in external editor (or Item Properties if no editor configured)
        if settings.check_shortcut(ctx, "open_editor") then
          utils.open_editor(item, controls.has_external_editor)
        end
        -- Show in Media Explorer (Ctrl+F)
        if settings.check_shortcut(ctx, "show_in_explorer") then
          local src = reaper.GetMediaItemTake_Source(take)
          if src then
            -- Walk to root source
            while true do
              local parent = reaper.GetMediaSourceParent(src)
              if not parent then break end
              src = parent
            end
            local fp = reaper.GetMediaSourceFileName(src, "")
            if fp and fp ~= "" and reaper.OpenMediaExplorer then
              reaper.OpenMediaExplorer(fp, false)
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

          -- During warp marker drag: freeze item properties to prevent REAPER's
          -- internal recalculations from shifting the view frame-to-frame
          if state.dragging_warp_marker and state.warp_drag_activated
              and state.warp_drag_start_item_position then
            item_position = state.warp_drag_start_item_position
            item_length = state.warp_drag_start_item_length
            start_offset = state.warp_drag_start_start_offset
          end

          if source_length <= 0 then
            source_length = item_length
          end
          if source_length <= 0 then source_length = 0.001 end  -- Prevent division by zero

          -- Guard against REAPER's GetMediaSourceLength returning inflated values
          -- for looped/section sources.  The real file length never changes for a
          -- given source object, but the API can sporadically return a larger value
          -- (typically matching the looped item length).  Cache the value per source
          -- and only accept increases that look like genuine source changes (not
          -- the inflated looped-item-length glitch).
          local take_playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
          if take_playrate == 0 then take_playrate = 1 end
          if source ~= state._src_len_source then
            state._src_len_cache = nil
            state._src_len_source = source
          end
          if state._src_len_cache then
            if source_length < state._src_len_cache - 0.001 then
              -- API returned a smaller value: always accept (could be correcting
              -- an inflated initial read, or source genuinely changed).
              state._src_len_cache = source_length
            elseif source_length > state._src_len_cache + 0.001 then
              -- API returned a larger value: accept unless it suspiciously matches
              -- the looped item length (the known REAPER API glitch).
              local looped_length = item_length * take_playrate
              if math.abs(source_length - looped_length) > 0.01 then
                state._src_len_cache = source_length
              end
            end
            source_length = state._src_len_cache
          else
            state._src_len_cache = source_length
          end

          -- Cache WAV cue markers (re-enumerate when source changes)
          if source ~= state.cached_cue_source then
            state.cached_cue_source = source
            state.cached_cue_markers = {}
            if reaper.CF_EnumMediaSourceCues then
              local idx = 0
              while true do
                local next_idx, time, end_time, is_region, name = reaper.CF_EnumMediaSourceCues(source, idx)
                if not next_idx or next_idx == 0 then break end
                state.cached_cue_markers[#state.cached_cue_markers + 1] = {
                  time = time,
                  name = name or "",
                  is_region = is_region,
                  end_time = end_time,
                }
                idx = next_idx
              end
              table.sort(state.cached_cue_markers, function(a, b) return a.time < b.time end)
            end
            -- Set cue marker visibility from user's default
            if #state.cached_cue_markers > 0 then
              state.show_cue_markers = settings.current.defaults.show_cue_markers
            else
              state.show_cue_markers = false
            end
          end

          -- Cache ghost marker regions (other selected items sharing same root source)
          if state.show_ghost_markers then
            local sel_count = reaper.CountSelectedMediaItems(0)
            local sel_first = sel_count > 0 and reaper.GetSelectedMediaItem(0, 0) or nil
            local sel_last = sel_count > 0 and reaper.GetSelectedMediaItem(0, sel_count - 1) or nil
            local proj_state = reaper.GetProjectStateChangeCount(0)
            if sel_count ~= state.ghost_marker_sel_count
                or sel_first ~= state.ghost_marker_sel_first
                or sel_last ~= state.ghost_marker_sel_last
                or item ~= state.ghost_marker_item
                or proj_state ~= state.ghost_marker_proj_state then
              state.ghost_marker_sel_count = sel_count
              state.ghost_marker_sel_first = sel_first
              state.ghost_marker_sel_last = sel_last
              state.ghost_marker_item = item
              state.ghost_marker_proj_state = proj_state
              state.ghost_marker_regions = {}
              if sel_count >= 2 then
                local my_path = reaper.GetMediaSourceFileName(source, "")
                if my_path and my_path ~= "" then
                  for si = 0, sel_count - 1 do
                    local other_item = reaper.GetSelectedMediaItem(0, si)
                    if other_item ~= item then
                      local other_take = reaper.GetActiveTake(other_item)
                      if other_take and not reaper.TakeIsMIDI(other_take) then
                        local other_src = reaper.GetMediaItemTake_Source(other_take)
                        if other_src then
                          -- Walk to root source, accumulating section offset
                          local other_sect_offset = 0
                          local other_parent = reaper.GetMediaSourceParent(other_src)
                          while other_parent do
                            local retval, sect_offs = reaper.PCM_Source_GetSectionInfo(other_src)
                            if retval then other_sect_offset = other_sect_offset + (sect_offs or 0) end
                            other_src = other_parent
                            other_parent = reaper.GetMediaSourceParent(other_src)
                          end
                          local other_path = reaper.GetMediaSourceFileName(other_src, "")
                          if other_path == my_path then
                            local other_startoffs = reaper.GetMediaItemTakeInfo_Value(other_take, "D_STARTOFFS")
                            local other_playrate = reaper.GetMediaItemTakeInfo_Value(other_take, "D_PLAYRATE")
                            if other_playrate == 0 then other_playrate = 1 end
                            local other_length = reaper.GetMediaItemInfo_Value(other_item, "D_LENGTH")
                            local src_start = other_sect_offset + other_startoffs
                            local src_end = src_start + other_length * other_playrate
                            -- Handle reversed items
                            if src_start > src_end then src_start, src_end = src_end, src_start end
                            state.ghost_marker_regions[#state.ghost_marker_regions + 1] = {
                              src_start = src_start, src_end = src_end
                            }
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end

          -- Early warp_mode sync: read B_PPITCH before marker caching so stale state
          -- from a previously selected item doesn't trigger auto-add on the wrong item.
          -- controls.draw_button_panel also sets this (with auto-enable logic), but runs later.
          local current_ppitch = reaper.GetMediaItemTakeInfo_Value(take, "B_PPITCH")
          state.warp_mode = current_ppitch == 1

          -- Cache stretch markers and transients (only when WARP mode is active)
          if state.warp_mode then
            -- During start marker drag or alt+drag (slide both), keep original markers/map frozen.
            -- REAPER markers are shifted each frame for arrange view,
            -- but view coordinates stay in original pos-time system.
            state._freeze_warp = ((state.dragging_start or state.drag_alt_latched)
                and state.marker_drag_activated
                and state.drag_start_warp_markers)
                or (state.slope_dragging and state.slope_drag_activated)
            if not state._freeze_warp then
              -- Always refresh markers (cheap read) so external changes are picked up
              state.warp_markers = utils.get_stretch_markers(take)
              state.warp_markers_take = take

              -- Auto-add start marker at position 0 if no markers exist
              -- srcpos must match start_offset so the audio mapping is preserved
              if #state.warp_markers == 0 then
                reaper.SetTakeStretchMarker(take, -1, 0, start_offset)
                reaper.UpdateArrange()
                state.warp_markers = utils.get_stretch_markers(take)
              end
            end

            -- Cache transient detection (runs once per item, reset on item change)
            if not state.transients_computed then
              state.transients = utils.detect_transients(source, 0.3, 0.05)
              state.transients_original = {}
              for i, t in ipairs(state.transients) do state.transients_original[i] = t end
              state.transients_source = source
              state.transients_computed = true
            end

            if not state._freeze_warp then
              -- Build warp map (sorted by pos) and compute hash for cache invalidation
              state.warp_map = utils.build_warp_map(state.warp_markers)
              local warp_hash = 0
              for _, sm in ipairs(state.warp_markers) do
                warp_hash = warp_hash + sm.pos * 10000 + sm.srcpos + (sm.slope or 0) * 100
              end
              state.warp_hash = warp_hash
            end
          else
            state.warp_map = nil
          end

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
          local layout = settings.current.layout
          local envelope_bar_height = config.ENVELOPE_BAR_HEIGHT
          local warp_bar_height = (state.warp_mode and layout.show_warp) and config.WARP_BAR_HEIGHT or 0
          state.is_loop_src = item and reaper.GetMediaItemInfo_Value(item, "B_LOOPSRC") == 1
          state.toolbar_buttons = settings.current.toolbar_buttons or {}
          state.info_bar_height = #state.toolbar_buttons > 0
              and config.INFO_BAR_HEIGHT_TOOLBAR
              or config.INFO_BAR_HEIGHT_BASE
          -- Get item/track color for strip (stored in state to avoid local variable pressure)
          state.strip_color = nil
          state.strip_h = 0
          if item then
            state.strip_color = reaper.GetDisplayedMediaItemColor(item)
            if state.strip_color ~= 0 then
              state.strip_color = reaper_color_to_imgui(state.strip_color)
              state.strip_h = config.COLOR_STRIP_HEIGHT
            else
              state.strip_color = nil
            end
          end

          local waveform_height = math.max(50, avail_h - (config.WAVEFORM_MARGIN_V * 2) - state.info_bar_height - config.RULER_HEIGHT - warp_bar_height - config.TIME_RULER_HEIGHT - envelope_bar_height - state.strip_h)
          local panel_height = state.strip_h + state.info_bar_height + config.RULER_HEIGHT + warp_bar_height + waveform_height + config.TIME_RULER_HEIGHT + envelope_bar_height

          local two_col_panel = panel_height < 270
          local effective_panel_width = two_col_panel
              and (config.LEFT_PANEL_WIDTH * 2)
              or config.LEFT_PANEL_WIDTH
          if not layout.show_controls then effective_panel_width = 0 end

          -- FX column mode: when vertical space is too tight, FX gets its own column
          local left_col_has_content = layout.show_warp or layout.show_buttons or layout.show_fx
          local effective_left_col = left_col_has_content and config.LEFT_COLUMN_WIDTH or 0
          local effective_fx_col = (layout.show_fx and state.needs_fx_col) and config.LEFT_COLUMN_WIDTH or 0
          local total_left_width = effective_left_col + effective_fx_col + effective_panel_width
          local pitch_gutter = state.envelopes_visible and config.PITCH_LABEL_WIDTH or 0
          local waveform_width = math.max(100, avail_w - (config.WAVEFORM_MARGIN_H * 2) - total_left_width - pitch_gutter)

          local cursor_x, cursor_y = reaper.ImGui_GetCursorScreenPos(ctx)

          -- Draw color strip at top of window
          if state.strip_color then
            reaper.ImGui_DrawList_AddRectFilled(reaper.ImGui_GetWindowDrawList(ctx),
              cursor_x, cursor_y, cursor_x + avail_w, cursor_y + state.strip_h, state.strip_color)
          end

          local left_col_x = cursor_x + config.WINDOW_PADDING
          local left_col_y = cursor_y + state.strip_h + config.WAVEFORM_MARGIN_V
          local panel_x = left_col_x + effective_left_col + effective_fx_col
          local panel_y = cursor_y + state.strip_h + config.WAVEFORM_MARGIN_V
          local wave_x = cursor_x + total_left_width + config.WAVEFORM_MARGIN_H + pitch_gutter
          local info_bar_y = cursor_y + state.strip_h + config.WAVEFORM_MARGIN_V
          local ruler_y = info_bar_y + state.info_bar_height
          local warp_bar_y = ruler_y + config.RULER_HEIGHT
          local wave_y = warp_bar_y + warp_bar_height
          local time_ruler_y = wave_y + waveform_height
          local envelope_bar_y = time_ruler_y + config.TIME_RULER_HEIGHT

          -- Reserve the full area
          local total_height = state.strip_h + config.WAVEFORM_MARGIN_V + state.info_bar_height + config.RULER_HEIGHT + warp_bar_height + waveform_height + config.TIME_RULER_HEIGHT + envelope_bar_height + config.WAVEFORM_MARGIN_V
          reaper.ImGui_InvisibleButton(ctx, "waveform_area", avail_w, math.max(avail_h, total_height))

          local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
          drawing.set_frame_time(reaper.time_precise())

          -- Warp bar hit test (needed early for drawing-phase hover detection)
          local mouse_in_warp_bar = reaper_is_active
              and mouse_x >= wave_x and mouse_x <= wave_x + waveform_width
              and mouse_y >= warp_bar_y and mouse_y <= warp_bar_y + warp_bar_height
          local source_item_length = item_length * playrate

          -- Detect looped item: requires loop ON.  Non-looped items extended
          -- past source boundary just show silence, not wrapped audio.
          local is_looped_item = source_length > 0 and state.is_loop_src and (
              source_item_length > source_length
              or start_offset + source_item_length > source_length + 0.01
          )

          -- Warped view: when WARP mode is active, switch to item-time (pos) coordinates
          local is_warped_view = state.warp_mode and state.warp_map ~= nil

          -- Reset unwrap tracking when item changes
          if state.unwrap_tracked_item ~= item then
            state.unwrapped_start_offset = nil
            state.prev_raw_start_offset = nil
            state.unwrap_tracked_item = item
            state.post_drag_ext_start = nil
            state.post_drag_ext_end = nil
            state.post_drag_start_offset = nil
            state.env_selected_nodes = {}
          end

          if (state.dragging_start or state.dragging_end) and state.marker_drag_activated and not is_warped_view then
            -- During active drag: drag state is the authority for unwrapped offset
            -- (warp mode drag_current is in pos-time, not source-time)
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
              if state.post_drag_ext_start ~= nil then
                state.post_drag_ext_start = state.post_drag_ext_start + delta
                state.post_drag_ext_end = state.post_drag_ext_end + delta
              end
            end
            state.prev_raw_start_offset = start_offset
          else
            -- Not looped: reset tracking (but preserve if post-drag ext is set,
            -- since snapping to source boundary can make source_item_length == source_length
            -- even though the item was just extended past the boundary)
            if state.post_drag_ext_start == nil then
              state.unwrapped_start_offset = nil
              state.prev_raw_start_offset = nil
            end
          end

          state.is_looped_view = is_looped_item

          -- Expire keep-view flag (set by Ctrl+U to prevent reset on warp transition)
          if state._warp_keep_view then
            state._warp_keep_view = state._warp_keep_view - 1
            if state._warp_keep_view <= 0 then state._warp_keep_view = nil end
          end
          -- Reset zoom/pan on mode transition to avoid jarring jumps
          if is_warped_view ~= (state.was_warped_view or false) then
            if state._warp_keep_view then
              -- Ctrl+U triggered this transition; preserve current zoom/pan
              state._warp_keep_view = nil
            else
              state.zoom_level = 1
              state.pan_offset = 0
            end
            state.was_warped_view = is_warped_view
            state.invalidate_view_peaks()
            drawing.invalidate_wf_cache()
          end

          -- Extended view range (source-time or pos-time when warped)
          local ext_start, ext_end, ext_length
          if state.dragging_warp_marker and state.warp_drag_activated
              and state.warp_drag_start_ext_start then
            -- During warp marker drag: freeze ext to prevent view jitter
            ext_start = state.warp_drag_start_ext_start
            ext_end = state.warp_drag_start_ext_end
            ext_length = ext_end - ext_start
          elseif state.slope_dragging and state.slope_drag_activated
              and state.slope_drag_start_ext_start then
            -- During slope handle drag: freeze ext to prevent view shift
            ext_start = state.slope_drag_start_ext_start
            ext_end = state.slope_drag_start_ext_end
            ext_length = ext_end - ext_start
          elseif is_warped_view then
            -- In warped view (pos-time), show full source extent mapped through
            -- the warp map. This matches non-warp behavior where ext is based on
            -- source_length (stable) rather than item_length (changes with markers).
            -- Without this, dragging markers changes ext_length, causing the view
            -- to auto-zoom to fit the marker region.
            local src_start_pos = utils.warp_src_to_pos(state.warp_map, 0, playrate)
            local src_end_pos = utils.warp_src_to_pos(state.warp_map, source_length, playrate)
            if (state.dragging_start or state.dragging_end) and state.drag_current_start then
              ext_start = math.min(src_start_pos, 0, state.drag_current_start)
              ext_end = math.max(src_end_pos, item_length, state.drag_current_end)
            else
              ext_start = math.min(src_start_pos, 0)
              ext_end = math.max(src_end_pos, item_length)
            end
            ext_length = ext_end - ext_start
          elseif (state.dragging_start or state.dragging_end) then
            -- During drag (including pre-activation): compute ext from drag state
            -- Always include [0, source_length] so dragging a marker inward doesn't shrink the view
            local ds = state.drag_current_start
            local de = state.drag_current_end
            if ds < 0 or de > source_length then
              ext_start = math.min(ds, 0)
              ext_end = math.max(de, source_length)
              ext_length = ext_end - ext_start
            else
              ext_start = 0
              ext_end = source_length
              ext_length = source_length
            end
          elseif state.post_drag_ext_start ~= nil then
            -- After drag release: use saved ext for seamless transition
            local pds = state.post_drag_ext_start
            local pde = state.post_drag_ext_end
            -- Validate: post-drag ext should match current item length (within tolerance)
            -- Also check start_offset for alt-drag/slide undo detection (slide doesn't change length)
            local expected_length = pde - pds
            local offset_changed = state.post_drag_start_offset ~= nil
                and math.abs(start_offset - state.post_drag_start_offset) > 0.001
            if not offset_changed and math.abs(source_item_length - expected_length) < 0.001 then
              if pds < 0 or pde > source_length then
                ext_start = math.min(pds, 0)
                ext_end = math.max(pde, source_length)
                ext_length = ext_end - ext_start
              else
                ext_start = 0; ext_end = source_length; ext_length = source_length
              end
            else
              -- Item changed externally (undo, REAPER edit): discard saved ext
              state.post_drag_ext_start = nil
              state.post_drag_ext_end = nil
              state.post_drag_start_offset = nil
              if is_looped_item then
                ext_start = state.unwrapped_start_offset
                ext_end = state.unwrapped_start_offset + source_item_length
                ext_length = source_item_length
              else
                -- Wrap accumulated D_STARTOFFS for non-looped display
                local so = start_offset
                if source_length > 0 and state.is_loop_src and so >= source_length then so = so % source_length end
                ext_start = math.min(so, 0)
                ext_end = math.max(so + source_item_length, source_length)
                ext_length = ext_end - ext_start
              end
            end
          elseif is_looped_item then
            ext_start = state.unwrapped_start_offset
            ext_end = state.unwrapped_start_offset + source_item_length
            ext_length = source_item_length
          else
            -- Wrap accumulated D_STARTOFFS for non-looped display
            local so = start_offset
            if source_length > 0 and state.is_loop_src and so >= source_length then so = so % source_length end
            ext_start = math.min(so, 0)
            ext_end = math.max(so + source_item_length, source_length)
            ext_length = ext_end - ext_start
          end

          -- One-shot view anchor: when markers are added/quantized/cleared,
          -- the handler saves the current ext center. On the next frame,
          -- compensate pan_offset so the view stays visually stable.
          if state._warp_view_anchor then
            local current_center = (ext_start + ext_end) / 2
            local delta = state._warp_view_anchor - current_center
            if math.abs(delta) > 0.0001 then
              state.pan_offset = state.pan_offset + delta
            end
            state._warp_view_anchor = nil
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
          local we_are_dragging = state.any_drag_active()
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
            state.prev_ext_start = nil
            state.prev_ext_end = nil
            -- Reset pitch scroll
            state.pitch_view_offset = 0
            state.zoom_toggle_active = false
            -- Reset warp/transient state
            state.warp_markers = {}
            state.warp_markers_take = nil
            state.warp_marker_hovered_idx = -1
            state.warp_marker_selected_idx = -1
            state.transients = {}
            state.transients_source = nil
            state.transients_computed = false
            state.transient_hovered_idx = -1
          end

          -- Detect external ext changes (undo, REAPER edits) and reset pan_offset
          -- Skip in warped mode: ext changes with warp markers, that's normal
          if not is_warped_view and not (state.dragging_start or state.dragging_end) and state.prev_ext_start ~= nil then
            if math.abs(ext_start - state.prev_ext_start) > 0.001 or math.abs(ext_end - state.prev_ext_end) > 0.001 then
              state.pan_offset = 0
            end
          end
          state.prev_ext_start = ext_start
          state.prev_ext_end = ext_end

          -- Zoom (Z): toggle. New selection/markers zooms in, same target or no selection restores.
          if reaper_is_active and settings.check_shortcut(ctx, "zoom_to_markers") then
            local target_start, target_end
            if state.region_selected then
              local sel_s = math.min(state.selection_start_time, state.selection_end_time)
              local sel_e = math.max(state.selection_start_time, state.selection_end_time)
              if sel_e - sel_s > 0 then
                target_start = sel_s
                target_end = sel_e
              end
            end
            if not target_start and source_item_length > 0 then
              -- Use unwrapped coordinates to match ext_start/ext_end coordinate space
              if state.post_drag_ext_start ~= nil then
                target_start = state.post_drag_ext_start
                target_end = state.post_drag_ext_end
              elseif state.unwrapped_start_offset ~= nil then
                target_start = state.unwrapped_start_offset
                target_end = state.unwrapped_start_offset + source_item_length
              else
                local so = start_offset
                if source_length > 0 and state.is_loop_src and so >= source_length then so = so % source_length end
                target_start = so
                target_end = so + source_item_length
              end
            end

            if target_start then
              -- Check if this is the same target we already zoomed to
              local same_target = state.zoom_toggle_active
                and state.zoom_target_start and state.zoom_target_end
                and math.abs(target_start - state.zoom_target_start) < 0.001
                and math.abs(target_end - state.zoom_target_end) < 0.001

              if same_target then
                -- Same target: restore
                state.zoom_level = state.zoom_before_toggle or 1.0
                state.pan_offset = state.pan_before_toggle or 0
                state.zoom_toggle_active = false
                state.zoom_target_start = nil
                state.zoom_target_end = nil
              else
                -- New target: zoom in (save state only on first zoom)
                if not state.zoom_toggle_active then
                  state.zoom_before_toggle = state.zoom_level
                  state.pan_before_toggle = state.pan_offset
                end
                local target_len = target_end - target_start
                state.zoom_level = math.min(500.0, ext_length / target_len)
                local target_center = (target_start + target_end) / 2
                state.pan_offset = target_center - (ext_start + ext_end) / 2
                state.zoom_toggle_active = true
                state.zoom_target_start = target_start
                state.zoom_target_end = target_end
              end
            end
          end

          -- Crop markers to selection (C key)
          if reaper_is_active and settings.check_shortcut(ctx, "crop_to_selection") and state.region_selected then
            local sel_s = math.min(state.selection_start_time, state.selection_end_time)
            local sel_e = math.max(state.selection_start_time, state.selection_end_time)
            if sel_e - sel_s > 0.001 then
              reaper.Undo_BeginBlock()
              local new_source_length = sel_e - sel_s
              local new_item_length = new_source_length / playrate
              local new_take_offset = sel_s - section_offset
              -- Wrap for REAPER only when loop is on (non-looped items allow negative D_STARTOFFS)
              if source_length > 0 and state.is_loop_src then
                new_take_offset = new_take_offset % source_length
              end

              -- Fade adjustment
              local fi, fo = fade_in_len, fade_out_len
              if fi + fo > new_item_length then
                fo = math.max(0, new_item_length - fi)
                if fo == 0 then fi = math.min(fi, new_item_length) end
              end

              -- Remap envelope points to new take coordinate space
              -- Uses modular arithmetic to correctly handle source boundary crossings
              if not state.envelope_lock then
                local env_names = { "Volume", "Pitch", "Pan" }
                for _, ename in ipairs(env_names) do
                  local e = reaper.GetTakeEnvelopeByName(take, ename)
                  if e then
                    local np = reaper.CountEnvelopePoints(e)
                    local remapped = {}
                    for ei = 0, np - 1 do
                      local ret, pt_time, pt_val, pt_shape, pt_tension, pt_sel = reaper.GetEnvelopePoint(e, ei)
                      if ret then
                        local new_pt_time
                        if source_length > 0 and state.is_loop_src then
                          -- Source audio position of this point (wrapping around source)
                          local src_time = (take_offset + pt_time) % source_length
                          -- New take time relative to new D_STARTOFFS
                          new_pt_time = (src_time - new_take_offset) % source_length
                        else
                          new_pt_time = pt_time - (new_take_offset - take_offset)
                        end
                        -- Keep only points within the new item bounds
                        if new_pt_time >= -0.001 and new_pt_time <= new_item_length + 0.001 then
                          new_pt_time = math.max(0, math.min(new_item_length, new_pt_time))
                          remapped[#remapped + 1] = { time = new_pt_time, val = pt_val, shape = pt_shape, tension = pt_tension, sel = pt_sel }
                        end
                      end
                    end
                    -- Delete all existing points and re-insert remapped ones
                    for ei = np - 1, 0, -1 do
                      reaper.DeleteEnvelopePointEx(e, -1, ei)
                    end
                    for _, p in ipairs(remapped) do
                      reaper.InsertEnvelopePoint(e, p.time, p.val, p.shape, p.tension, p.sel, true)
                    end
                    reaper.Envelope_SortPoints(e)
                  end
                end
              end

              reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", new_take_offset)
              reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_item_length)
              reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", fi)
              reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", fo)
              reaper.UpdateArrange()
              reaper.Undo_EndBlock("NVSD_ItemView: Crop to selection", -1)
              -- Clear selection and reset view state for clean reinitialization
              state.region_selected = false
              state.unwrapped_start_offset = nil
              state.prev_raw_start_offset = nil
              state.post_drag_ext_start = nil
              state.post_drag_ext_end = nil
              state.post_drag_start_offset = nil
              state.zoom_level = 1.0
              state.pan_offset = 0
              state.zoom_toggle_active = false
            end
          end

          -- Add markers at all transients + quantize all to grid (Ctrl+U)
          if reaper_is_active and settings.check_shortcut(ctx, "quantize_transients") then
            if take then
              -- Save view anchor and keep-view flag for mode transition
              state._warp_view_anchor = (ext_start + ext_end) / 2
              state._warp_keep_view = 3  -- frames to wait for mode transition
              reaper.Undo_BeginBlock()
              local n = 0
              if #state.transients > 0 then
                n = utils.add_markers_at_transients(take, state.transients, nil, nil,
                    is_warped_view and state.warp_map or nil, playrate)
              end
              local q = utils.quantize_warp_markers(take)
              reaper.UpdateItemInProject(item)
              reaper.UpdateArrange()
              reaper.Undo_EndBlock("NVSD_ItemView: Quantize warp markers (+" .. n .. " new, " .. q .. " snapped)", -1)
              state.warp_markers = utils.get_stretch_markers(take)
            end
          end

          -- Insert warp marker(s) at cursor or selection edges (Ctrl+I)
          if reaper_is_active and settings.check_shortcut(ctx, "insert_warp_marker") then
            if take and state.warp_mode then
              if is_warped_view then
                state._warp_view_anchor = (ext_start + ext_end) / 2
              end
              local inserted = 0
              reaper.Undo_BeginBlock()
              if state.region_selected then
                if utils.insert_warp_marker_at(take, state.region_sel_start, is_warped_view, state.warp_map, playrate, source_length) then inserted = inserted + 1 end
                if utils.insert_warp_marker_at(take, state.region_sel_end, is_warped_view, state.warp_map, playrate, source_length) then inserted = inserted + 1 end
              elseif state.preview_cursor_pos then
                if utils.insert_warp_marker_at(take, state.preview_cursor_pos, is_warped_view, state.warp_map, playrate, source_length) then inserted = inserted + 1 end
              end
              if inserted > 0 then
                reaper.UpdateItemInProject(item)
                reaper.UpdateArrange()
              end
              reaper.Undo_EndBlock("NVSD_ItemView: Insert " .. inserted .. " warp marker(s)", -1)
              state.warp_markers = utils.get_stretch_markers(take)
            end
          end

          -- Insert transient(s) at cursor or selection edges (Ctrl+Shift+I)
          if reaper_is_active and settings.check_shortcut(ctx, "add_transient") then
            if take and state.warp_mode then
              local positions = {}
              if state.region_selected then
                positions[1] = state.region_sel_start
                positions[2] = state.region_sel_end
              elseif state.preview_cursor_pos then
                positions[1] = state.preview_cursor_pos
              end
              for _, pos in ipairs(positions) do
                local srcpos = is_warped_view
                  and utils.warp_pos_to_src(state.warp_map, pos, playrate)
                  or pos
                local dup = false
                for _, t in ipairs(state.transients) do
                  if math.abs(t - srcpos) < 0.005 then dup = true; break end
                end
                if not dup and srcpos >= 0 and srcpos <= source_length then
                  local ins = false
                  for i, t in ipairs(state.transients) do
                    if srcpos < t then
                      table.insert(state.transients, i, srcpos)
                      ins = true
                      break
                    end
                  end
                  if not ins then state.transients[#state.transients + 1] = srcpos end
                end
              end
            end
          end

          -- Compute view bounds.
          -- During active marker drag, pin to frozen coordinates so the view
          -- doesn't jump as ext grows/shifts with the drag.
          local range_center = (ext_start + ext_end) / 2
          local view_length, view_start, view_end
          if (state.dragging_start or state.dragging_end) and state.marker_drag_activated
              and state.drag_start_view_length then
            view_length = state.drag_start_view_length
            view_start = state.drag_start_view_start
            view_end = view_start + view_length
          elseif state.dragging_warp_marker and state.warp_drag_activated then
            view_length = state.warp_drag_start_view_length
            view_start = state.warp_drag_start_view_start
            view_end = view_start + view_length
          elseif state.slope_dragging and state.slope_drag_activated
              and state.slope_drag_start_view_length then
            view_length = state.slope_drag_start_view_length
            view_start = state.slope_drag_start_view_start
            view_end = view_start + view_length
          else
            view_length = ext_length / state.zoom_level
            local view_center = range_center + state.pan_offset
            view_start = view_center - view_length / 2
            view_end = view_start + view_length
            if view_start < ext_start then view_start = ext_start; view_end = ext_start + view_length end
            if view_end > ext_end then view_end = ext_end; view_start = ext_end - view_length end
            if view_start < ext_start then view_start = ext_start end
            view_length = view_end - view_start
          end
          if view_length <= 0 then view_length = 0.001 end

          -- Per-view peak loading: load exactly screen-width peaks for the visible range.
          -- PCM_Source_GetPeaks uses pre-indexed .reapeaks files → <1ms regardless of file size.
          local pixel_step = user_dragging_in_reaper and 2 or 1
          local num_view_samples = math.max(1, math.floor(waveform_width / pixel_step))

          -- Single source of truth: does the ext range extend past source boundaries?
          -- Replaces the old is_extended_drag / is_post_drag_looped / is_looped_item checks
          -- for peak loading, overlay skip, envelope bounds, etc.
          local is_extended_view = not is_warped_view and (
              ext_start < -0.0001 or ext_end > source_length + 0.0001
              -- Safety net: when Loop is OFF and item extends past source, always use
              -- clipped peaks even if ext bounds haven't caught up yet (race with REAPER)
              or (not state.is_loop_src and source_length > 0 and (
                  start_offset < -0.0001
                  or start_offset + source_item_length > source_length + 0.0001
                  or view_start + view_length > source_length + 0.0001)))

          local need_reload = state.view_peaks == nil
              or source ~= state.view_source
              or is_reversed ~= state.view_reversed
              or view_start ~= state.view_start
              or view_length ~= state.view_length
              or num_view_samples ~= state.view_num_samples
              or (is_warped_view and state.view_warp_hash ~= state.warp_hash)
              or (is_warped_view ~= (state.view_warped or false))
              or (state.is_loop_src ~= state.view_loop_src)

          if need_reload and view_length > 0 then
            local peaks_result, num_ch
            if is_warped_view then
              peaks_result, num_ch = utils.get_peaks_for_range_warped(
                  source, view_start, view_length, num_view_samples, state.warp_map, playrate,
                  state.is_loop_src and source_length or nil, source_length)
            elseif is_extended_view and not is_reversed and state.is_loop_src then
              peaks_result, num_ch = utils.get_peaks_for_range_looped(source, view_start, view_length, num_view_samples, source_length)
            elseif is_extended_view and not is_reversed then
              -- Non-looped: clip waveform at source boundary, silence beyond
              peaks_result, num_ch = utils.get_peaks_for_range_clipped(source, view_start, view_length, num_view_samples, source_length)
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
              state.view_warp_hash = state.warp_hash
              state.view_warped = is_warped_view
              state.view_loop_src = state.is_loop_src
              -- Bust waveform draw cache since peak data changed
              drawing.invalidate_wf_cache()
            end
          end

          -- Draw waveform
          local draw_list = reaper.ImGui_GetWindowDrawList(ctx)

          local view_offset, view_item_length
          if is_warped_view and (state.dragging_start or state.dragging_end) and state.drag_current_start then
            -- During drag in warped view: drag_current is already in pos-time
            view_offset = state.drag_current_start
            view_item_length = state.drag_current_end - state.drag_current_start
          elseif is_warped_view then
            -- In warped view, the item fills [0, item_length] in pos-space
            view_offset = 0
            view_item_length = item_length
          elseif (state.dragging_start or state.dragging_end) and state.drag_current_start ~= nil then
            view_offset = state.drag_current_start
            view_item_length = state.drag_current_end - state.drag_current_start
          elseif state.post_drag_ext_start ~= nil then
            view_offset = state.post_drag_ext_start
            view_item_length = state.post_drag_ext_end - state.post_drag_ext_start
          elseif is_looped_item then
            view_offset = state.unwrapped_start_offset or start_offset
            view_item_length = source_item_length
          else
            local so = start_offset
            if source_length > 0 and state.is_loop_src and so >= source_length then so = so % source_length end
            view_offset = so
            view_item_length = source_item_length
          end

          -- Grid line params (shared by grid lines and ruler)
          -- In warped view: use offset=0, playrate=1 so grid lines are at pos-time positions
          -- (project_to_source_time with offset=0, playrate=1 gives pos_t = proj_t - item_position)
          local grid_offset, grid_playrate, grid_view_start
          if is_warped_view then
            grid_offset = 0
            grid_playrate = 1
            grid_view_start = view_start
          else
            grid_offset = (state.dragging_start or state.dragging_end) and state.drag_current_start or view_offset
            grid_playrate = (state.dragging_start or state.dragging_end) and state.drag_start_playrate or playrate
            grid_view_start = (state.dragging_start or state.dragging_end) and state.drag_start_view_start or view_start
          end

          -- Waveform background, then grid lines, then waveform on top
          reaper.ImGui_DrawList_AddRectFilled(draw_list, wave_x, wave_y, wave_x + waveform_width, wave_y + waveform_height, config.COLOR_WAVEFORM_BG)
          drawing.draw_grid_lines(draw_list, wave_x, wave_y, waveform_width, waveform_height,
            grid_view_start, view_length, item_position, grid_offset, grid_playrate, config, utils)

          -- In warped view: pass ext_end as source_length so draw_waveform doesn't
          -- flag active pixels as looped, and is_reversed=false since warping handles everything
          local wf_source_len = is_warped_view and ext_end or source_length
          local wf_reversed = is_warped_view and false or is_reversed
          -- Compute warp-mapped source boundaries for dashed boundary lines
          if is_warped_view then
            if (state.dragging_start or state.dragging_end)
                and state.drag_start_src_pos_start then
              state.wf_bounds_start = state.drag_start_src_pos_start
              state.wf_bounds_end = state.drag_start_src_pos_end
            elseif state.dragging_warp_marker and state.warp_drag_activated
                and state.warp_drag_start_wf_bounds_start then
              state.wf_bounds_start = state.warp_drag_start_wf_bounds_start
              state.wf_bounds_end = state.warp_drag_start_wf_bounds_end
            else
              state.wf_bounds_start = utils.warp_src_to_pos(state.warp_map, 0, playrate)
              state.wf_bounds_end = utils.warp_src_to_pos(state.warp_map, source_length, playrate)
            end
          else
            state.wf_bounds_start = nil
            state.wf_bounds_end = nil
          end
          config.waveform_zoom = state.waveform_zoom
          if settings.current.layout.shaped_waveform then
            state.modulation = {
              fade_in_len = fade_in_len,
              fade_in_shape = fade_in_shape,
              fade_in_dir = fade_in_dir,
              fade_out_len = fade_out_len,
              fade_out_shape = fade_out_shape,
              fade_out_dir = fade_out_dir,
              vol_env = take and reaper.GetTakeEnvelopeByName(take, "Volume"),
              pan_env = take and reaper.GetTakeEnvelopeByName(take, "Pan"),
              pan_value = take and reaper.GetMediaItemTakeInfo_Value(take, "D_PAN") or 0,
              playrate = playrate,
            }
          else
            state.modulation = nil
          end
          local start_px, end_px = drawing.draw_waveform(draw_list, wave_x, wave_y,
            waveform_width, waveform_height,
            state.view_peaks, view_offset, view_item_length, wf_source_len, view_start, view_length, ruler_y, item_vol, wf_reversed, state.view_num_channels, config, pixel_step, state.wf_bounds_start, state.wf_bounds_end, state.is_loop_src, state.modulation)

          -- Unified coordinate conversion (used by all subsequent code)
          local function time_to_px(t)
            return wave_x + ((t - view_start) / view_length) * waveform_width
          end

          local function px_to_time(px)
            return view_start + ((px - wave_x) / waveform_width) * view_length
          end

          -- Draw file info bar at the top (file_path already fetched above for caching)
          -- toolbar_clicked_idx is stored on state inside draw_info_bar to avoid local limit
          local _, gear_clicked, tab_clicked = drawing.draw_info_bar(draw_list, ctx, wave_x, info_bar_y, waveform_width, state.info_bar_height, source, file_path, mouse_x, mouse_y, item, config, utils, state.view_num_channels, state, settings, state.toolbar_buttons)

          -- Open settings when gear is clicked
          if gear_clicked then
            settings_ui.open(settings)
          end

          -- Defer toolbar action to next frame (executing mid-draw can invalidate take)
          if state.toolbar_clicked then
            if state.toolbar_buttons[state.toolbar_clicked] then
              state._tb_pending_cmd = state.toolbar_buttons[state.toolbar_clicked].cmd
            end
            state.toolbar_clicked = nil
          end

          -- Zoom widget drag handling (vertical: up = more, down = less)
          if state.wf_zoom_dragging then
            if reaper.ImGui_IsMouseDown(ctx, 0) then
              local dy = state.wf_zoom_drag_start_y - mouse_y  -- negative Y = up = more zoom
              local log_start = math.log(state.wf_zoom_drag_start_val)
              local log_delta = dy * 0.02  -- sensitivity: ~50px per decade
              local new_zoom = math.exp(log_start + log_delta)
              state.waveform_zoom = math.max(0.1, math.min(20, new_zoom))
            else
              -- Drag released: push pre-drag value to undo history
              if state.wf_zoom_drag_start_val ~= state.waveform_zoom then
                table.insert(state.wf_zoom_history, state.wf_zoom_drag_start_val)
              end
              state.wf_zoom_dragging = false
            end
          end

          -- (Envelopes tab is always available, no auto-switch needed)

          -- Right-click menu (deferred: fade handle right-click checked after hover detection)
          -- Exclude info bar area (handled by toolbar context menu)
          local right_clicked = reaper_is_active and reaper.ImGui_IsMouseClicked(ctx, 1)
          local in_info_bar = right_clicked and mouse_y >= info_bar_y and mouse_y <= info_bar_y + state.info_bar_height
                              and mouse_x >= wave_x and mouse_x <= wave_x + waveform_width
          local right_click_in_window = right_clicked and not in_info_bar
                              and mouse_x >= cursor_x and mouse_x <= cursor_x + avail_w
                              and mouse_y >= cursor_y and mouse_y <= cursor_y + avail_h

          -- Calculate ACTUAL current marker positions
          local render_start, render_end
          if is_warped_view and (state.dragging_start or state.dragging_end) and state.drag_current_start then
            -- During drag in warped view: drag_current is already in pos-time
            render_start = state.drag_current_start
            render_end = state.drag_current_end
          elseif is_warped_view then
            -- In warped view, item fills [0, item_length] in pos-space
            render_start = 0
            render_end = item_length
          elseif state.dragging_start or state.dragging_end then
            render_start = state.drag_current_start
            render_end = state.drag_current_end
            -- No clamping: markers can go past source boundaries during drag
          elseif state.post_drag_ext_start ~= nil then
            render_start = state.post_drag_ext_start
            render_end = state.post_drag_ext_end
          elseif is_looped_item then
            -- Markers at item boundaries in virtual time
            render_start = ext_start
            render_end = ext_end
          else
            -- Wrap accumulated D_STARTOFFS for non-looped display
            local so = start_offset
            if source_length > 0 and state.is_loop_src and so >= source_length then so = so % source_length end
            render_start = so
            render_end = so + source_item_length
          end
          local actual_start_px = time_to_px(render_start) - wave_x
          local actual_end_px = time_to_px(render_end) - wave_x
          start_px = actual_start_px
          end_px = actual_end_px

          -- Draw loop boundary lines on waveform (before ruler so lines are under)
          if state.is_loop_src then
            drawing.draw_loop_boundaries(draw_list, wave_x, wave_y, waveform_width, waveform_height,
              source_length, view_start, view_length, time_to_px, config)
          end

          -- Draw ruler (ticks and labels, on top of waveform)
          drawing.draw_ruler_and_grid(draw_list, wave_x, ruler_y, wave_y, waveform_width, config.RULER_HEIGHT, waveform_height,
            grid_view_start, view_length, item_position, grid_offset, grid_playrate, config, utils)

          -- Draw warp bar (only when WARP mode is active and warp section visible)
          state.warp_marker_hovered_idx = -1
          state.transient_hovered_idx = -1
          if state.warp_mode and layout.show_warp then
            drawing.draw_warp_bar(draw_list, wave_x, warp_bar_y, waveform_width, warp_bar_height, config)

            -- Hover detection for stretch markers in warp bar
            if mouse_in_warp_bar and not state.any_drag_active() then
              local best_dist = config.WARP_MARKER_HIT_RADIUS
              for i, sm in ipairs(state.warp_markers) do
                local sm_px = is_warped_view and time_to_px(sm.pos) or time_to_px(sm.srcpos)
                local dist = math.abs(mouse_x - sm_px)
                if dist < best_dist then
                  best_dist = dist
                  state.warp_marker_hovered_idx = i
                end
              end
            end

            -- Draw transients (skip those that have a stretch marker nearby)
            if state.transients_computed then
              local best_dist = config.WARP_MARKER_HIT_RADIUS
              local px_per_sec = view_length > 0 and (waveform_width / view_length) or 0
              local transient_zoomed = px_per_sec > 500
              for i, t in ipairs(state.transients) do
                -- Map transient source-time to display coordinate
                local t_display = is_warped_view and utils.warp_src_to_pos(state.warp_map, t, playrate) or t
                if t_display >= view_start and t_display <= view_start + view_length then
                  local has_sm = false
                  for _, sm in ipairs(state.warp_markers) do
                    if math.abs(sm.srcpos - t) < 0.005 then has_sm = true; break end
                  end
                  if not has_sm then
                    local t_px = time_to_px(t_display)
                    if t_px >= wave_x - 2 and t_px <= wave_x + waveform_width + 2 then
                      if mouse_in_warp_bar and not state.any_drag_active() and state.warp_marker_hovered_idx == -1 then
                        local dist = math.abs(mouse_x - t_px)
                        if dist < best_dist then
                          best_dist = dist
                          state.transient_hovered_idx = i
                        end
                      end
                      drawing.draw_transient(draw_list, t_px, warp_bar_y, warp_bar_height,
                          state.transient_hovered_idx == i, config, transient_zoomed)
                    end
                  end
                end
              end
            end

            -- Ghost preview on transient hover (gray house-shaped marker)
            -- Ctrl+hover: show 3 ghosts (clicked + nearest neighbors)
            if state.transient_hovered_idx > 0 then
              local ghost_indices = {state.transient_hovered_idx}
              if ctrl_held then
                local idx = state.transient_hovered_idx
                if idx > 1 then ghost_indices[#ghost_indices + 1] = idx - 1 end
                if idx < #state.transients then ghost_indices[#ghost_indices + 1] = idx + 1 end
              end
              for _, gi in ipairs(ghost_indices) do
                local t = state.transients[gi]
                if t then
                  local ghost_display = is_warped_view and utils.warp_src_to_pos(state.warp_map, t, playrate) or t
                  local ghost_px = time_to_px(ghost_display)
                  drawing.draw_warp_marker(draw_list, ghost_px, warp_bar_y, warp_bar_height,
                      wave_y, waveform_height, false, false, false,
                      config.COLOR_WARP_MARKER_GHOST, config)
                end
              end
            end

            -- Draw stretch markers (house-shaped markers + vertical lines)
            -- Visible everywhere (including beyond regular markers) so user sees them in extended view
            for i, sm in ipairs(state.warp_markers) do
              local sm_px = is_warped_view and time_to_px(sm.pos) or time_to_px(sm.srcpos)
              if sm_px >= wave_x - 10 and sm_px <= wave_x + waveform_width + 10 then
                local hovered = (state.warp_marker_hovered_idx == i)
                local dragging = (state.dragging_warp_marker and state.warp_drag_idx == sm.idx)
                local selected = (sm.idx == state.warp_marker_selected_idx)
                drawing.draw_warp_marker(draw_list, sm_px, warp_bar_y, warp_bar_height,
                    wave_y, waveform_height, hovered, dragging, selected, nil, config)
              end
            end

          end

          -- Draw overlays on inactive regions (warped mode: dim outside item bounds)
          if is_warped_view then
            local COLOR_UNUSED_SOURCE = 0x00000038
            local view_left = wave_x
            local view_right = wave_x + waveform_width
            local item_start_px = time_to_px(view_offset)
            local item_end_px = time_to_px(view_offset + view_item_length)
            -- Dim before item start
            if item_start_px > view_left then
              local right = math.min(item_start_px, view_right)
              if right > view_left then
                reaper.ImGui_DrawList_AddRectFilled(draw_list, view_left, ruler_y, right, wave_y + waveform_height, COLOR_UNUSED_SOURCE)
              end
            end
            -- Dim after item end
            if item_end_px < view_right then
              local left = math.max(item_end_px, view_left)
              if view_right > left then
                reaper.ImGui_DrawList_AddRectFilled(draw_list, left, ruler_y, view_right, wave_y + waveform_height, COLOR_UNUSED_SOURCE)
              end
            end
          elseif is_extended_view then
            -- Extended view overlay: dim outside item bounds + silence regions
            do
              local COLOR_UNUSED = 0x00000038   -- outside item (context)
              local COLOR_SILENCE = 0x00000020  -- inside item but no audio
              local view_left = wave_x
              local view_right = wave_x + waveform_width
              local item_start_px = time_to_px(view_offset)
              local item_end_px = time_to_px(view_offset + view_item_length)
              -- Dim before item start
              if item_start_px > view_left then
                local right = math.min(item_start_px, view_right)
                if right > view_left then
                  reaper.ImGui_DrawList_AddRectFilled(draw_list, view_left, ruler_y, right, wave_y + waveform_height, COLOR_UNUSED)
                end
              end
              -- Dim after item end
              if item_end_px < view_right then
                local left = math.max(item_end_px, view_left)
                if view_right > left then
                  reaper.ImGui_DrawList_AddRectFilled(draw_list, left, ruler_y, view_right, wave_y + waveform_height, COLOR_UNUSED)
                end
              end
              -- For non-looped items, dim silence regions within item bounds
              if not state.is_loop_src then
                local source_start_px = time_to_px(0)
                local source_end_px = time_to_px(source_length)
                -- Silence before source start (item starts before audio)
                if view_offset < 0 then
                  local sil_left = math.max(item_start_px, view_left)
                  local sil_right = math.min(source_start_px, item_end_px, view_right)
                  if sil_right > sil_left then
                    reaper.ImGui_DrawList_AddRectFilled(draw_list, sil_left, wave_y, sil_right, wave_y + waveform_height, COLOR_SILENCE)
                  end
                end
                -- Silence after source end (item extends past audio)
                if view_offset + view_item_length > source_length then
                  local sil_left = math.max(source_end_px, item_start_px, view_left)
                  local sil_right = math.min(item_end_px, view_right)
                  if sil_right > sil_left then
                    reaper.ImGui_DrawList_AddRectFilled(draw_list, sil_left, wave_y, sil_right, wave_y + waveform_height, COLOR_SILENCE)
                  end
                end
              end
            end
          else
            local COLOR_UNUSED_SOURCE = 0x00000038
            local COLOR_OUTSIDE_SOURCE = 0x00000058

            local source_start_px = time_to_px(0)
            local source_end_px = time_to_px(source_length)
            local view_left = wave_x
            local view_right = wave_x + waveform_width

            -- Calculate active regions considering loops
            -- Item plays from view_offset to view_offset + view_item_length
            local item_start = view_offset
            local item_end = view_offset + view_item_length

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
            mouse_x, mouse_y, config, state, settings)

          -- Helper: find nearest source boundary if within threshold
          -- Always active: full threshold when snap on, weaker (40%) when snap off
          local function snap_to_source_boundary(t, src_len, threshold_time)
            local effective_threshold = state.env_snap_enabled and threshold_time or (threshold_time * 0.4)
            local nearest_boundary = math.floor(t / src_len + 0.5) * src_len
            if math.abs(t - nearest_boundary) <= effective_threshold then
              return nearest_boundary
            end
            return t
          end

          -- Helper: snap source time to finest visible grid subdivision
          -- snap_offset: override start_offset for snapping (use drag_start_offset during marker drags)
          local function snap_to_grid_if_enabled(source_t, snap_offset, item_pos_override, pos_time_mode)
            if not state.env_snap_enabled then return source_t end

            local offset = snap_offset or start_offset
            local pos = item_pos_override or item_position
            local project_t
            if pos_time_mode then
              project_t = pos + source_t  -- pos-time: already in arrange seconds
            else
              project_t = utils.source_to_project_time(source_t, pos, offset, playrate)
            end

            -- Compute finest visible grid subdivision (same logic as grid display)
            local bpm, bpi = reaper.GetProjectTimeSignature2(0, project_t)
            local beats_per_bar = math.floor(bpi)
            if beats_per_bar < 1 then beats_per_bar = 4 end
            local avg_bar_duration = 60 / bpm * beats_per_bar
            local px_per_bar = (avg_bar_duration / view_length) * waveform_width
            local px_per_beat = px_per_bar / beats_per_bar

            local finest_sub = 1
            while (px_per_beat / (finest_sub * 2)) >= 42 do
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
            if pos_time_mode then
              return snapped_project_t - pos
            else
              return utils.project_to_source_time(snapped_project_t, pos, offset, playrate)
            end
          end

          -- Helper: snap with both grid and source boundary, pick closest to raw position
          local function snap_best(raw_t, src_len, threshold_time, snap_offset, item_pos_override)
            local grid_t = snap_to_grid_if_enabled(raw_t, snap_offset, item_pos_override)
            local boundary_t = snap_to_source_boundary(raw_t, src_len, threshold_time)
            -- If both snapped to different targets, pick the one closer to raw
            if grid_t ~= raw_t and boundary_t ~= raw_t then
              if math.abs(raw_t - grid_t) <= math.abs(raw_t - boundary_t) then
                return grid_t
              else
                return boundary_t
              end
            end
            -- Only one snapped, or neither
            if boundary_t ~= raw_t then return boundary_t end
            return grid_t
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
            local env_max_raw = is_pitch and 48.0 or (is_pan and 1.0 or reaper.ScaleToEnvelopeMode(env_scaling, 2.0))
            local env_min_raw = is_pitch and -48.0 or (is_pan and -1.0 or 0)
            if env then
              env_scaling = reaper.GetEnvelopeScalingMode(env)
              if not is_centered then
                env_max_raw = reaper.ScaleToEnvelopeMode(env_scaling, 2.0)
              end
              num_env_points = reaper.CountEnvelopePoints(env)
              -- Envelope points are shifted in realtime during drag, so always use live offset
              -- During drag: use live drag position; otherwise: use unwrapped offset if available
              -- (covers both looped items and items dragged past source boundary)
              local env_time_offset
              if state.dragging_start or state.dragging_end then
                env_time_offset = state.drag_current_start or start_offset
              elseif state.unwrapped_start_offset ~= nil then
                env_time_offset = state.unwrapped_start_offset
              else
                env_time_offset = view_offset
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
            local env_anchor_end = (is_warped_view and state.is_loop_src or is_looped_item) and ext_end or source_length
            local env_anchor_start = (is_warped_view and state.is_loop_src or is_looped_item) and ext_start or nil
            local pitch_view_min = is_pitch and (-24 + state.pitch_view_offset) or nil
            local pitch_view_max = is_pitch and (24 + state.pitch_view_offset) or nil
            drawing.draw_envelope_overlay(draw_list, ctx, env_points, num_env_points,
              wave_x, wave_y, waveform_width, waveform_height,
              time_to_px, view_start, view_length,
              mouse_x, mouse_y, config, state, env_anchor_end,
              env_scaling, env_max_raw, env_min_raw, state.envelope_type,
              snap_to_grid_if_enabled, env_colors, env_anchor_start,
              pitch_view_min, pitch_view_max)

            -- Suppress envelope segment hover when fade body or marker takes priority (alt+hover)
            if alt_held and (mouse_in_fade_in_body or mouse_in_fade_out_body
                or (mouse_in_marker_area and (near_start or near_end))) then
              state.envelope_hovered_segment = -1
            end

          end

          -- Draw original source boundary markers in ruler
          -- (reuse wf_bounds computed earlier for draw_waveform; nil in non-warp mode → defaults to 0/source_length)
          local COLOR_SOURCE_MARKER = 0xFFAA44FF

          local orig_start_px = time_to_px(state.wf_bounds_start or 0)
          if orig_start_px >= wave_x - 2 and orig_start_px <= wave_x + waveform_width + 2 then
            reaper.ImGui_DrawList_AddLine(draw_list, orig_start_px, ruler_y, orig_start_px, ruler_y + config.RULER_HEIGHT, COLOR_SOURCE_MARKER, 2)
            local bracket_len = 4
            reaper.ImGui_DrawList_AddLine(draw_list, orig_start_px, ruler_y + 1, orig_start_px + bracket_len, ruler_y + 1, COLOR_SOURCE_MARKER, 2)
            reaper.ImGui_DrawList_AddLine(draw_list, orig_start_px, ruler_y + config.RULER_HEIGHT - 1, orig_start_px + bracket_len, ruler_y + config.RULER_HEIGHT - 1, COLOR_SOURCE_MARKER, 2)
          end

          local orig_end_px = time_to_px(state.wf_bounds_end or source_length)
          if orig_end_px >= wave_x - 2 and orig_end_px <= wave_x + waveform_width + 2 then
            reaper.ImGui_DrawList_AddLine(draw_list, orig_end_px, ruler_y, orig_end_px, ruler_y + config.RULER_HEIGHT, COLOR_SOURCE_MARKER, 2)
            local bracket_len = 4
            reaper.ImGui_DrawList_AddLine(draw_list, orig_end_px - bracket_len, ruler_y + 1, orig_end_px, ruler_y + 1, COLOR_SOURCE_MARKER, 2)
            reaper.ImGui_DrawList_AddLine(draw_list, orig_end_px - bracket_len, ruler_y + config.RULER_HEIGHT - 1, orig_end_px, ruler_y + config.RULER_HEIGHT - 1, COLOR_SOURCE_MARKER, 2)
          end

          -- Draw REAPER timeline selection overlay
          local sel_ok, sel_start, sel_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
          if sel_start and sel_end and sel_start ~= sel_end then
            local sel_source_start = utils.project_to_source_time(sel_start, item_position, view_offset, playrate)
            local sel_source_end = utils.project_to_source_time(sel_end, item_position, view_offset, playrate)

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

          -- Left column: buttons + FX (scoped to free register slots)
          if left_col_has_content then
          do
            local bg = config.COLOR_WAVEFORM_BG
            reaper.ImGui_DrawList_AddRectFilled(draw_list, left_col_x, left_col_y,
              left_col_x + config.LEFT_COLUMN_WIDTH - 2, left_col_y + panel_height, bg)

            -- Column 2 position (only when previous frame detected overflow)
            local c2x = (layout.show_fx and state.needs_fx_col) and (left_col_x + config.LEFT_COLUMN_WIDTH) or nil
            if c2x then
              reaper.ImGui_DrawList_AddRectFilled(draw_list, c2x, left_col_y,
                c2x + config.LEFT_COLUMN_WIDTH - 2, left_col_y + panel_height, bg)
            end

            -- Draw buttons (may overflow to col 2)
            local c1b, c2b = controls.draw_button_panel(ctx, draw_list, mouse_x, mouse_y,
              left_col_x, left_col_y, item, take, config, state, utils, drawing, settings,
              panel_height, c2x)

            -- Update state for next frame: need FX column if buttons + FX don't fit in col 1
            state.needs_fx_col = layout.show_fx and (left_col_y + panel_height - 14 - c1b) < 50

            -- Draw FX in column 2 (if active) or below buttons in column 1
            if layout.show_fx then
            if c2x then
              local fy = c2b and (c2b + 6) or (left_col_y + 10)
              local tb = controls.draw_fx_toolbar(ctx, draw_list, mouse_x, mouse_y,
                c2x + 8, fy, config.LEFT_COLUMN_WIDTH - 16, take, config, state, drawing)
              local at = tb + 4
              controls.draw_fx_list(ctx, draw_list, mouse_x, mouse_y,
                c2x + 4, at, config.LEFT_COLUMN_WIDTH - 10,
                (left_col_y + panel_height - 4) - at, take, config, state, drawing)
            else
              local tb = controls.draw_fx_toolbar(ctx, draw_list, mouse_x, mouse_y,
                left_col_x + 8, c1b + 6, config.LEFT_COLUMN_WIDTH - 16,
                take, config, state, drawing)
              local at = tb + 4
              controls.draw_fx_list(ctx, draw_list, mouse_x, mouse_y,
                left_col_x + 4, at, config.LEFT_COLUMN_WIDTH - 10,
                (left_col_y + panel_height - 4) - at, take, config, state, drawing)
            end

            controls.draw_fx_context_menu(ctx, state)
            end -- if layout.show_fx
          end
          else
            state.needs_fx_col = false
          end -- if left_col_has_content

          if layout.show_controls then
          local COLOR_PANEL_BG = config.COLOR_INFO_BAR_BG
          reaper.ImGui_DrawList_AddRectFilled(draw_list, panel_x, panel_y,
              panel_x + effective_panel_width - 4, panel_y + panel_height, COLOR_PANEL_BG)

          if two_col_panel then
            -- Two-column mode: gain on left, knobs on right
            local div_x = panel_x + config.LEFT_PANEL_WIDTH - 2
            reaper.ImGui_DrawList_AddLine(draw_list, div_x, panel_y + 4, div_x,
                panel_y + panel_height - 4, config.COLOR_CENTERLINE, 1)

            -- Left column: gain slider (full height)
            controls.draw_gain_slider(ctx, draw_list, mouse_x, mouse_y,
                panel_x, panel_y, panel_y + panel_height,
                item, item_vol, config, state, utils, drawing)

            -- Right column: pan (top 45%) + pitch+boxes (bottom 55%)
            local knobs_x = panel_x + config.LEFT_PANEL_WIDTH
            local knob_split = panel_y + panel_height * 0.45

            controls.draw_pan_knob(ctx, draw_list, mouse_x, mouse_y,
                knobs_x, panel_y, knob_split,
                item, take, config, state, utils, drawing, settings)

            local take_pitch, knob_cx, knob_cy = controls.draw_pitch_knob(
                ctx, draw_list, mouse_x, mouse_y,
                knobs_x, knob_split, panel_y + panel_height,
                take, config, state, utils, drawing, settings)

            controls.draw_semitones_cents_boxes(ctx, draw_list, mouse_x, mouse_y,
                knobs_x, knob_cy, take, take_pitch, config, state, utils, drawing)
          else
            -- Single column: knobs get fixed minimum space, gain gets the rest
            local pan_height = 70
            local pitch_height = 96
            local panel_split1 = panel_y + panel_height - pan_height - pitch_height
            local panel_split2 = panel_split1 + pan_height

            controls.draw_gain_slider(ctx, draw_list, mouse_x, mouse_y,
                panel_x, panel_y, panel_split1,
                item, item_vol, config, state, utils, drawing)

            controls.draw_pan_knob(ctx, draw_list, mouse_x, mouse_y,
                panel_x, panel_split1, panel_split2,
                item, take, config, state, utils, drawing, settings)

            local take_pitch, knob_cx, knob_cy = controls.draw_pitch_knob(
                ctx, draw_list, mouse_x, mouse_y,
                panel_x, panel_split2, panel_y + panel_height,
                take, config, state, utils, drawing, settings)

            controls.draw_semitones_cents_boxes(ctx, draw_list, mouse_x, mouse_y,
                panel_x, knob_cy, take, take_pitch, config, state, utils, drawing)
          end
          end -- if layout.show_controls

          -- Hide and lock cursor while dragging any control
          if layout.show_controls and state.is_any_control_dragging() then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_None())
            -- Accumulate delta from screen coords (works on all platforms)
            local cur_screen_x, cur_screen_y = reaper.GetMousePosition()
            state.drag_last_screen_y = state.drag_last_screen_y or cur_screen_y
            local delta = state.drag_last_screen_y - cur_screen_y
            if delta ~= 0 then
              state.drag_cumulative_delta_y = state.drag_cumulative_delta_y + delta
            end
            -- With JS extension: lock cursor in place for infinite drag range.
            -- Skip if cursor lock was already detected as broken (Mac Retina scaling,
            -- missing accessibility permissions, etc.) to avoid corrupting delta tracking.
            if state.has_js_extension and state.drag_lock_screen_x ~= 0 then
              if state.cursor_lock_works == true then
                -- Verified working: teleport cursor and track from lock position.
                reaper.JS_Mouse_SetPosition(state.drag_lock_screen_x, state.drag_lock_screen_y)
                state.drag_last_screen_y = state.drag_lock_screen_y
                -- Runtime check: if cumulative delta stays at 0 for several frames
                -- while actively dragging, the teleport is eating mouse events (macOS).
                -- The verify test passes on Mac (teleport position matches) but
                -- CGWarpMouseCursorPosition suppresses all subsequent mouse deltas.
                if state.drag_cumulative_delta_y == 0 then
                  state.cursor_lock_zero_frames = state.cursor_lock_zero_frames + 1
                  if state.cursor_lock_zero_frames > 4 then
                    state.cursor_lock_works = false
                    state.drag_last_screen_y = cur_screen_y
                  end
                else
                  state.cursor_lock_zero_frames = 0
                end
              elseif state.cursor_lock_works == nil then
                -- First drag ever: test if JS_Mouse_SetPosition actually works.
                -- Safe because get_drag_delta uses ImGui path until cursor_lock_works == true.
                reaper.JS_Mouse_SetPosition(state.drag_lock_screen_x, state.drag_lock_screen_y)
                local vx, vy = reaper.GetMousePosition()
                if math.abs(vy - state.drag_lock_screen_y) <= 2 then
                  state.cursor_lock_works = true
                  state.cursor_lock_zero_frames = 0
                  state.drag_last_screen_y = state.drag_lock_screen_y
                else
                  -- Teleport failed. Disable permanently, fall back to ImGui path.
                  state.cursor_lock_works = false
                  state.drag_last_screen_y = cur_screen_y
                end
              else
                -- cursor_lock_works == false: broken, just track screen position.
                state.drag_last_screen_y = cur_screen_y
              end
            else
              state.drag_last_screen_y = cur_screen_y
            end
          end

          -- Marker positions
          local start_marker_x = wave_x + start_px
          local end_marker_x = wave_x + end_px

          -- Mouse interaction areas (all false when REAPER isn't active, prevents stale mouse artifacts)
          local mouse_in_waveform = reaper_is_active
              and mouse_x >= wave_x and mouse_x <= wave_x + waveform_width
              and mouse_y >= wave_y and mouse_y <= wave_y + waveform_height
          -- Cache popup state before any BeginPopup/EndPopup calls change it
          state._any_popup_open = reaper.ImGui_IsPopupOpen(ctx, "", reaper.ImGui_PopupFlags_AnyPopup())
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
          local mouse_in_pitch_gutter = state.envelope_type == "Pitch" and state.envelopes_visible and reaper_is_active
              and mouse_x >= wave_x - config.PITCH_LABEL_WIDTH and mouse_x < wave_x
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
          -- Fade-in grab zone (suppress during envelope freehand draw mode)
          local env_freehand_mode = state.env_freehand_drawing or (state.envelopes_visible and ctrl_held)
          local near_fade_in = false
          if fade_in_len > 0 and reaper_is_active and not env_freehand_mode
              and not state.dragging_start and not state.dragging_end
              and not state.is_ruler_dragging and not state.is_panning then
            -- Fade exists: grab anywhere along the curve
            local fi_width = fade_in_end_x - start_marker_x
            if fi_width > 0 and mouse_x >= start_marker_x - fade_grab_sm and mouse_x <= fade_in_end_x + fade_grab_sm then
              local fi_t = math.max(0, math.min(1, (mouse_x - start_marker_x) / fi_width))
              local fi_curve_y = drawing.get_fade_curve_y(fi_t, fade_in_shape, true, fade_in_dir, fade_top_y, wave_y, waveform_height)
              near_fade_in = math.abs(mouse_y - fi_curve_y) <= fade_curve_tolerance
            end
          elseif reaper_is_active and not env_freehand_mode
              and not state.dragging_start and not state.dragging_end
              and not state.is_ruler_dragging and not state.is_panning then
            -- No fade: narrow top strip near marker for creation
            near_fade_in = mouse_y >= wave_y and mouse_y <= wave_y + fade_grab_h_create
                and mouse_x >= fade_in_end_x - fade_grab_sm
                and mouse_x <= fade_in_end_x + fade_grab_w
          end
          -- Fade-out grab zone
          local near_fade_out = false
          if fade_out_len > 0 and reaper_is_active and not env_freehand_mode
              and not state.dragging_start and not state.dragging_end
              and not state.is_ruler_dragging and not state.is_panning then
            local fo_width = end_marker_x - fade_out_start_x
            if fo_width > 0 and mouse_x >= fade_out_start_x - fade_grab_sm and mouse_x <= end_marker_x + fade_grab_sm then
              local fo_t = math.max(0, math.min(1, (mouse_x - fade_out_start_x) / fo_width))
              local fo_curve_y = drawing.get_fade_curve_y(fo_t, fade_out_shape, false, fade_out_dir, fade_top_y, wave_y, waveform_height)
              near_fade_out = math.abs(mouse_y - fo_curve_y) <= fade_curve_tolerance
            end
          elseif reaper_is_active and not env_freehand_mode
              and not state.dragging_start and not state.dragging_end
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

          -- Fade handle tooltips
          if near_fade_in and not state.dragging_fade_in then
            drawing.tooltip(ctx, "fade_in", "Drag: fade length\nAlt+drag: fade curve")
          elseif near_fade_out and not state.dragging_fade_out then
            drawing.tooltip(ctx, "fade_out", "Drag: fade length\nAlt+drag: fade curve")
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

          -- Slope handle hover detection (triangles at both ends of each slope curve)
          state.slope_hovered_segment = -1
          state.slope_hovered_endpoint = 0  -- 1=left handle, 2=right handle
          if state.warp_mode and #state.warp_markers > 1
              and mouse_in_waveform and not state.any_drag_active()
              and not (state.envelopes_visible and state.env_node_hovered_idx >= 0) then
            local HIT_FAR = 14   -- hit range in the direction the triangle points
            local HIT_NEAR = 4   -- small overlap past the marker line
            local HIT_Y = 14     -- vertical hit range from handle center
            local best_dist = math.huge
            for i = 1, #state.warp_markers - 1 do
              local sm1 = state.warp_markers[i]
              local sm2 = state.warp_markers[i + 1]
              local px1 = is_warped_view and time_to_px(sm1.pos) or time_to_px(sm1.srcpos)
              local px2 = is_warped_view and time_to_px(sm2.pos) or time_to_px(sm2.srcpos)
              local slope = sm1.slope or 0
              local rate = (sm2.pos ~= sm1.pos) and (sm2.srcpos - sm1.srcpos) / (sm2.pos - sm1.pos) or 1
              local y_left, y_right = drawing.slope_handle_positions(wave_y, waveform_height, slope, rate)
              -- Left handle (right-pointing triangle): hit zone extends RIGHT from marker
              if mouse_x >= px1 - HIT_NEAR and mouse_x <= px1 + HIT_FAR
                  and math.abs(mouse_y - y_left) <= HIT_Y then
                local d = math.abs(mouse_x - px1) + math.abs(mouse_y - y_left)
                if d < best_dist then
                  best_dist = d
                  state.slope_hovered_segment = i
                  state.slope_hovered_endpoint = 1
                end
              end
              -- Right handle (left-pointing triangle): hit zone extends LEFT from marker
              if mouse_x >= px2 - HIT_FAR and mouse_x <= px2 + HIT_NEAR
                  and math.abs(mouse_y - y_right) <= HIT_Y then
                local d = math.abs(mouse_x - px2) + math.abs(mouse_y - y_right)
                if d < best_dist then
                  best_dist = d
                  state.slope_hovered_segment = i
                  state.slope_hovered_endpoint = 2
                end
              end
            end
          end

          -- Slope handle takes priority over start/end marker grab
          if state.slope_hovered_segment > 0 then
            near_start = false
            near_end = false
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
              and not (state.warp_mode and state.slope_hovered_segment > 0)

          -- Cursor feedback (alt_held cached at top of frame)
          -- Skip cursor changes when a popup/modal is open (context menus, edit modals, etc.)
          if text_input_active or reaper.ImGui_IsPopupOpen(ctx, "", reaper.ImGui_PopupFlags_AnyPopup()) then
            -- Let ImGui handle cursor naturally for popup windows
          elseif state.dragging_warp_marker then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeEW())
          elseif mouse_in_warp_bar and state.warp_marker_hovered_idx > 0 then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
          elseif state.slope_dragging then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeNS())
          elseif state.slope_hovered_segment > 0
              and not (state.envelopes_visible and state.envelope_hovered_segment >= 0) then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeNS())
          elseif mouse_in_warp_bar and state.transient_hovered_idx > 0 then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
          -- Fade grabs use Hand cursor to distinguish from marker's ResizeEW
          elseif state.env_freehand_drawing then
            -- Freehand drawing active: show crosshair cursor
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_None())
            local cx, cy = mouse_x, mouse_y
            local cc = config.COLOR_MARKER or 0x4A90D9FF
            reaper.ImGui_DrawList_AddLine(draw_list, cx - 10, cy, cx - 3, cy, cc, 1.5)
            reaper.ImGui_DrawList_AddLine(draw_list, cx + 3, cy, cx + 10, cy, cc, 1.5)
            reaper.ImGui_DrawList_AddLine(draw_list, cx, cy - 10, cx, cy - 3, cc, 1.5)
            reaper.ImGui_DrawList_AddLine(draw_list, cx, cy + 3, cx, cy + 10, cc, 1.5)
            reaper.ImGui_DrawList_AddCircle(draw_list, cx, cy, 2, cc, 8, 1.5)
          elseif state.env_tension_dragging then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeEW())
          elseif state.dragging_fade_curve_in or state.dragging_fade_curve_out then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_None())
          elseif state.dragging_fade_in or state.dragging_fade_out then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
          elseif alt_held and reaper_is_active and (mouse_in_fade_in_body or mouse_in_fade_out_body) then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeNS())
          elseif alt_held and not ctrl_held and mouse_in_free_zone and not state.dragging_fade_in and not state.dragging_fade_out then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeAll())
          elseif near_fade_in or near_fade_out then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
          elseif (state.dragging_start or state.dragging_end) and (alt_held or state.drag_alt_latched) then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeAll())
          elseif mouse_in_marker_area and (near_start or near_end)
              and not (ctrl_held and state.envelopes_visible) then
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
          elseif state.envelopes_visible and reaper_is_active
              and state.env_node_hovered_idx >= 0
              and state.env_node_hovered_is_selected
              and not alt_held then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeAll())
          elseif state.envelopes_visible and alt_held and reaper_is_active
              and state.env_node_hovered_idx >= 0 then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_NotAllowed())
          elseif state.envelopes_visible and alt_held and reaper_is_active
              and state.envelope_hovered_segment >= 0 and state.env_node_hovered_idx < 0 then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeEW())
          elseif state.envelopes_visible and shift_held and reaper_is_active
              and state.envelope_hovered_segment >= 0 and state.env_node_hovered_idx < 0 then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
          elseif state.envelopes_visible and shift_held and reaper_is_active
              and mouse_in_waveform and state.envelope_hovered_segment < 0
              and state.env_node_hovered_idx < 0 then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
          elseif state.envelopes_visible and ctrl_held and reaper_is_active
              and mouse_in_waveform and not alt_held and not shift_held then
            -- Ctrl = freehand draw mode: show crosshair cursor
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_None())
            local cx, cy = mouse_x, mouse_y
            local cc = config.COLOR_MARKER or 0x4A90D9FF
            reaper.ImGui_DrawList_AddLine(draw_list, cx - 10, cy, cx - 3, cy, cc, 1.5)
            reaper.ImGui_DrawList_AddLine(draw_list, cx + 3, cy, cx + 10, cy, cc, 1.5)
            reaper.ImGui_DrawList_AddLine(draw_list, cx, cy - 10, cx, cy - 3, cc, 1.5)
            reaper.ImGui_DrawList_AddLine(draw_list, cx, cy + 3, cx, cy + 10, cc, 1.5)
            reaper.ImGui_DrawList_AddCircle(draw_list, cx, cy, 2, cc, 8, 1.5)
          elseif state.envelopes_visible and reaper_is_active
              and state.envelope_hovered_segment >= 0 and state.env_node_hovered_idx < 0
              and not alt_held and not shift_held then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeNS())
          elseif state.selecting_region and state.selection_drag_activated then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeEW())
          elseif mouse_in_pitch_gutter or state.pitch_gutter_dragging then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeNS())
          elseif ctrl_held and alt_held and mouse_in_waveform and not we_are_dragging then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeAll())
          end

          -- Tooltips for interactive elements (only when not actively dragging)
          if not state.any_drag_active() and not state.dragging_zone then
            -- Envelope node tooltips (most specific first)
            if state.envelopes_visible and state.env_node_hovered_idx >= 0 then
              if alt_held then
                drawing.tooltip(ctx, "env_node", "Click to delete node")
              elseif state.env_node_hovered_is_selected and #state.env_selected_nodes > 1 then
                drawing.tooltip(ctx, "env_node", "Drag to move selected nodes\nAlt+click: delete")
              else
                drawing.tooltip(ctx, "env_node", "Drag to move node\nAlt+click: delete")
              end
            -- Envelope segment tooltips
            elseif state.envelopes_visible and state.envelope_hovered_segment >= 0 then
              if ctrl_held then
                drawing.tooltip(ctx, "env_segment", "Click+drag to draw nodes")
              elseif alt_held then
                drawing.tooltip(ctx, "env_segment", "Drag to adjust curve tension")
              elseif shift_held then
                drawing.tooltip(ctx, "env_segment", "Click to add node and drag")
              else
                drawing.tooltip(ctx, "env_segment", "Drag to move segment\nShift+click: add node\nAlt+drag: adjust curve\nCtrl+drag: draw nodes")
              end
            -- Fade handle tooltips
            elseif near_fade_in then
              drawing.tooltip(ctx, "fade_in_handle", "Drag to adjust fade in\nRight-click: change shape")
            elseif near_fade_out then
              drawing.tooltip(ctx, "fade_out_handle", "Drag to adjust fade out\nRight-click: change shape")
            -- Fade body tooltips (Alt+drag for curve)
            elseif mouse_in_fade_in_body then
              if alt_held then
                drawing.tooltip(ctx, "fade_in_body", "Click to remove fade\nDrag to adjust curve")
              else
                drawing.tooltip(ctx, "fade_in_body", "Alt+click: remove fade\nAlt+drag: adjust curve")
              end
            elseif mouse_in_fade_out_body then
              if alt_held then
                drawing.tooltip(ctx, "fade_out_body", "Click to remove fade\nDrag to adjust curve")
              else
                drawing.tooltip(ctx, "fade_out_body", "Alt+click: remove fade\nAlt+drag: adjust curve")
              end
            -- Marker tooltips (skip when Ctrl+envelope = freehand draw mode)
            elseif mouse_in_marker_area and near_start
                and not (ctrl_held and state.envelopes_visible) then
              if alt_held then
                drawing.tooltip(ctx, "marker_start", "Drag to slide both markers")
              else
                drawing.tooltip(ctx, "marker_start", "Drag to adjust start\nAlt+drag: slide both")
              end
            elseif mouse_in_marker_area and near_end
                and not (ctrl_held and state.envelopes_visible) then
              if alt_held then
                drawing.tooltip(ctx, "marker_end", "Drag to slide both markers")
              else
                drawing.tooltip(ctx, "marker_end", "Drag to adjust end\nAlt+drag: slide both")
              end
            -- Warp bar tooltips
            elseif mouse_in_warp_bar and state.warp_marker_hovered_idx > 0 then
              local sm = state.warp_markers[state.warp_marker_hovered_idx]
              if sm then
                local time_str = utils.format_source_time(sm.srcpos, true)
                drawing.tooltip(ctx, "warp_marker_" .. sm.idx,
                    time_str .. "\nDrag: adjust timing\nShift+drag: slide source\nDbl-click: delete")
              end
            elseif mouse_in_warp_bar and state.transient_hovered_idx > 0 then
              local t = state.transients[state.transient_hovered_idx]
              if t then
                drawing.tooltip(ctx, "transient_" .. state.transient_hovered_idx,
                    utils.format_source_time(t, true) .. "\nDouble-click: add stretch marker")
              end
            elseif state.slope_hovered_segment > 0
                and not (state.envelopes_visible and state.envelope_hovered_segment >= 0) then
              local sm = state.warp_markers[state.slope_hovered_segment]
              if sm then
                local slope_pct = string.format("%.0f%%", (sm.slope or 0) * 100)
                drawing.tooltip(ctx, "slope_" .. state.slope_hovered_segment,
                    "Slope: " .. slope_pct .. "\nDrag vertical: adjust\nDbl-click: reset")
              end
            -- Ruler tooltip
            elseif mouse_in_ruler then
              drawing.tooltip(ctx, "ruler", "Drag vertical: zoom\nDrag horizontal: pan")
            -- Freehand drawing hint (Ctrl held in envelope area)
            elseif state.envelopes_visible and ctrl_held and mouse_in_waveform
                and state.env_node_hovered_idx < 0 then
              drawing.tooltip(ctx, "env_freehand", "Click+drag to draw envelope freehand")
            -- General envelope area hint
            elseif state.envelopes_visible and mouse_in_waveform
                and state.env_node_hovered_idx < 0
                and state.envelope_hovered_segment < 0
                and not near_start and not near_end
                and not near_fade_in and not near_fade_out then
              drawing.tooltip(ctx, "env_area", "Right-drag: rectangle select nodes\nCtrl+drag: freehand draw")
            -- General waveform tooltip (no envelopes)
            elseif not state.envelopes_visible and mouse_in_waveform
                and not near_start and not near_end
                and not near_fade_in and not near_fade_out then
              drawing.tooltip(ctx, "waveform", "Ctrl+scroll: zoom\nMiddle-drag: pan")
            end
          end

          -- Right-click: fade shape menus or unified context menu
          -- Skip if the FX context menu was opened this frame (by draw_fx_list)
          local fx_menu_opened = right_clicked and reaper.ImGui_IsPopupOpen(ctx, "fx_context_menu")
          if right_click_in_window and not fx_menu_opened then
            if near_fade_in then
              reaper.ImGui_OpenPopup(ctx, "fade_in_shape_menu")
            elseif near_fade_out then
              reaper.ImGui_OpenPopup(ctx, "fade_out_shape_menu")
            elseif not state.envelopes_visible then
              local rc_t = px_to_time(mouse_x)
              if is_warped_view then
                rc_t = snap_to_grid_if_enabled(rc_t, 0, nil)
              else
                rc_t = snap_to_grid_if_enabled(rc_t)
              end
              state.warp_right_click_time = rc_t
              state.warp_right_click_marker_idx = state.warp_marker_hovered_idx
              state.preview_cursor_pos = rc_t
              state.stop_preview()
              reaper.ImGui_OpenPopup(ctx, "context_menu")
            end
          end

          if reaper.ImGui_BeginPopup(ctx, "context_menu") then
            -- Warp entries (only when WARP mode is on)
            -- Use saved right-click state (live hover is lost once popup opens)
            if state.warp_mode then
              local rc_marker_idx = state.warp_right_click_marker_idx

              -- Delete warp marker (when hovering one)
              if rc_marker_idx > 0 then
                if reaper.ImGui_MenuItem(ctx, "Delete warp marker") then
                  local sm = state.warp_markers[rc_marker_idx]
                  if sm then
                    if sm.idx == state.warp_marker_selected_idx then
                      state.warp_marker_selected_idx = -1
                    end
                    reaper.Undo_BeginBlock()
                    reaper.DeleteTakeStretchMarkers(take, sm.idx, 1)
                    reaper.UpdateArrange()
                    reaper.UpdateItemInProject(item)
                    reaper.Undo_EndBlock("NVSD_ItemView: Delete stretch marker", -1)
                    state.warp_markers = utils.get_stretch_markers(take)
                    state.warp_marker_hovered_idx = -1
                  end
                end
              end

              -- Insert warp marker(s) at right-click position or selection edges
              if rc_marker_idx <= 0 then
                if reaper.ImGui_MenuItem(ctx, "Insert warp marker(s)",
                    settings.format_shortcut_by_name("insert_warp_marker")) then
                  if is_warped_view then
                    state._warp_view_anchor = (ext_start + ext_end) / 2
                  end
                  reaper.Undo_BeginBlock()
                  local inserted = 0
                  if state.region_selected then
                    if utils.insert_warp_marker_at(take, state.region_sel_start, is_warped_view, state.warp_map, playrate, source_length) then inserted = inserted + 1 end
                    if utils.insert_warp_marker_at(take, state.region_sel_end, is_warped_view, state.warp_map, playrate, source_length) then inserted = inserted + 1 end
                  else
                    if utils.insert_warp_marker_at(take, state.warp_right_click_time, is_warped_view, state.warp_map, playrate, source_length) then inserted = inserted + 1 end
                  end
                  if inserted > 0 then
                    reaper.UpdateItemInProject(item)
                    reaper.UpdateArrange()
                  end
                  reaper.Undo_EndBlock("NVSD_ItemView: Insert " .. inserted .. " warp marker(s)", -1)
                  state.warp_markers = utils.get_stretch_markers(take)
                end
              end

              -- Add markers at transients within selected region
              if state.region_selected and state.transients_computed and #state.transients > 0 then
                if reaper.ImGui_MenuItem(ctx, "Add warp markers at transients") then
                  if is_warped_view then
                    state._warp_view_anchor = (ext_start + ext_end) / 2
                  end
                  reaper.Undo_BeginBlock()
                  local rs, re = state.region_sel_start, state.region_sel_end
                  if is_warped_view then
                    rs = utils.warp_pos_to_src(state.warp_map, rs, playrate)
                    re = utils.warp_pos_to_src(state.warp_map, re, playrate)
                  end
                  local n = utils.add_markers_at_transients(take, state.transients, rs, re,
                      is_warped_view and state.warp_map or nil, playrate)
                  reaper.UpdateArrange()
                  reaper.UpdateItemInProject(item)
                  reaper.Undo_EndBlock("NVSD_ItemView: Add " .. n .. " stretch markers", -1)
                  state.warp_markers = utils.get_stretch_markers(take)
                end
              end

              reaper.ImGui_Separator(ctx)

              -- Quantize warp markers
              if reaper.ImGui_MenuItem(ctx, "Quantize warp markers",
                  settings.format_shortcut_by_name("quantize_transients")) then
                state._warp_view_anchor = (ext_start + ext_end) / 2
                state._warp_keep_view = 3
                reaper.Undo_BeginBlock()
                local n = 0
                if state.transients_computed and #state.transients > 0 then
                  n = utils.add_markers_at_transients(take, state.transients, nil, nil,
                      is_warped_view and state.warp_map or nil, playrate)
                end
                local q = utils.quantize_warp_markers(take)
                if n > 0 or q > 0 then
                  reaper.UpdateItemInProject(item)
                  reaper.UpdateArrange()
                end
                reaper.Undo_EndBlock("NVSD_ItemView: Quantize warp markers (+" .. n .. " new, " .. q .. " snapped)", -1)
                state.warp_markers = utils.get_stretch_markers(take)
              end

              -- Clear all warp markers
              if #state.warp_markers > 0 then
                if reaper.ImGui_MenuItem(ctx, "Clear all warp markers") then
                  state._warp_view_anchor = (ext_start + ext_end) / 2
                  state._warp_keep_view = 3
                  reaper.Undo_BeginBlock()
                  reaper.DeleteTakeStretchMarkers(take, 0, reaper.GetTakeNumStretchMarkers(take))
                  reaper.UpdateArrange()
                  reaper.UpdateItemInProject(item)
                  reaper.Undo_EndBlock("NVSD_ItemView: Clear all stretch markers", -1)
                  state.warp_markers = utils.get_stretch_markers(take)
                  state.warp_marker_selected_idx = -1
                end
              end

              reaper.ImGui_Separator(ctx)

              -- Insert transient(s) at selection edges or right-click position
              if reaper.ImGui_MenuItem(ctx, "Insert transient(s)",
                  settings.format_shortcut_by_name("add_transient")) then
                local positions = {}
                if state.region_selected then
                  positions[1] = state.region_sel_start
                  positions[2] = state.region_sel_end
                elseif state.warp_right_click_time then
                  positions[1] = state.warp_right_click_time
                end
                for _, pos in ipairs(positions) do
                  local srcpos = is_warped_view
                    and utils.warp_pos_to_src(state.warp_map, pos, playrate)
                    or pos
                  local dup = false
                  for _, t in ipairs(state.transients) do
                    if math.abs(t - srcpos) < 0.005 then dup = true; break end
                  end
                  if not dup and srcpos >= 0 and srcpos <= source_length then
                    local ins = false
                    for i, t in ipairs(state.transients) do
                      if srcpos < t then
                        table.insert(state.transients, i, srcpos)
                        ins = true
                        break
                      end
                    end
                    if not ins then state.transients[#state.transients + 1] = srcpos end
                  end
                end
              end

              -- Reset transients to original detection
              if state.transients_original then
                if reaper.ImGui_MenuItem(ctx, "Reset transients") then
                  state.transients = {}
                  for i, t in ipairs(state.transients_original) do state.transients[i] = t end
                end
              end

              reaper.ImGui_Separator(ctx)
            end
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
            state.zoom_toggle_active = false

            local new_view_length = zoom_base_view_length / state.zoom_level

            state.pan_offset = time_under_cursor - range_center + new_view_length * (0.5 - cursor_fraction)

            -- Clamp pan to keep view within bounds
            local half_view = new_view_length / 2
            local min_pan = ext_start - range_center + half_view
            local max_pan = ext_end - range_center - half_view
            if min_pan > max_pan then min_pan, max_pan = max_pan, min_pan end
            state.pan_offset = math.max(min_pan, math.min(max_pan, state.pan_offset))
          end

          -- Ctrl+mouse wheel zoom / pitch vertical scroll
          local wheel = reaper.ImGui_GetMouseWheel(ctx)
          if wheel ~= 0 and mouse_in_view then
            if ctrl_held and shift_held then
              -- Vertical waveform zoom (display-only, debounced undo)
              if not state.wf_zoom_scroll_anchor then
                state.wf_zoom_scroll_anchor = state.waveform_zoom
              end
              state.wf_zoom_scroll_time = reaper.time_precise()
              local wf_zoom_factor = 1.15
              local new_wf_zoom = wheel > 0
                and (state.waveform_zoom * wf_zoom_factor)
                or (state.waveform_zoom / wf_zoom_factor)
              state.waveform_zoom = math.max(0.1, math.min(20, new_wf_zoom))
            elseif ctrl_held then
              local zoom_factor = 1.3
              local new_zoom = wheel > 0 and (state.zoom_level * zoom_factor) or (state.zoom_level / zoom_factor)
              zoom_to_cursor(new_zoom, mouse_x)
            elseif state.envelope_type == "Pitch" and state.envelopes_visible and mouse_in_waveform then
              state.pitch_view_offset = state.pitch_view_offset + wheel * config.PITCH_SCROLL_SPEED
              state.pitch_view_offset = math.max(-24, math.min(24, state.pitch_view_offset))
            end
          end

          -- === Warp bar interactions ===
          local warp_dblclick_handled = false

          -- Double-click: delete existing marker or create at empty area
          if reaper.ImGui_IsMouseDoubleClicked(ctx, 0) and mouse_in_warp_bar
              and not state.any_drag_active() then
            warp_dblclick_handled = true
            if state.warp_marker_hovered_idx > 0 then
              -- Double-click existing marker: DELETE
              local sm = state.warp_markers[state.warp_marker_hovered_idx]
              if sm then
                if sm.idx == state.warp_marker_selected_idx then
                  state.warp_marker_selected_idx = -1
                end
                reaper.Undo_BeginBlock()
                reaper.DeleteTakeStretchMarkers(take, sm.idx, 1)
                reaper.UpdateArrange()
                reaper.UpdateItemInProject(item)
                reaper.Undo_EndBlock("NVSD_ItemView: Delete stretch marker", -1)
                state.warp_markers = utils.get_stretch_markers(take)
                state.warp_marker_hovered_idx = -1
              end
            elseif state.transient_hovered_idx > 0 then
              -- Double-click on transient ghost: CREATE marker(s) and immediately start dragging
              local ctrl = reaper.ImGui_GetKeyMods(ctx) == reaper.ImGui_Mod_Ctrl()
              local srcpos = state.transients[state.transient_hovered_idx]
              if srcpos then
                reaper.Undo_BeginBlock()
                -- Collect positions: clicked + neighbors if Ctrl held
                local positions = {srcpos}
                if ctrl and state.transients then
                  local idx = state.transient_hovered_idx
                  if idx > 1 and state.transients[idx - 1] then
                    positions[#positions + 1] = state.transients[idx - 1]
                  end
                  if idx < #state.transients and state.transients[idx + 1] then
                    positions[#positions + 1] = state.transients[idx + 1]
                  end
                end
                -- Add markers, skipping duplicates
                local sm_count = reaper.GetTakeNumStretchMarkers(take)
                local existing_sm = {}
                for i = 0, sm_count - 1 do
                  local _, _, sp = reaper.GetTakeStretchMarker(take, i)
                  existing_sm[#existing_sm + 1] = sp
                end
                for _, sp in ipairs(positions) do
                  local has = false
                  for _, e in ipairs(existing_sm) do
                    if math.abs(e - sp) < 0.005 then has = true; break end
                  end
                  if not has then
                    local p = is_warped_view and utils.warp_src_to_pos(state.warp_map, sp, playrate) or sp
                    reaper.SetTakeStretchMarker(take, -1, p, sp)
                    existing_sm[#existing_sm + 1] = sp
                  end
                end
                reaper.UpdateArrange()
                reaper.UpdateItemInProject(item)
                local desc = ctrl and "NVSD_ItemView: Add stretch markers at transient group" or "NVSD_ItemView: Add stretch marker at transient"
                reaper.Undo_EndBlock(desc, -1)
                state.warp_markers = utils.get_stretch_markers(take)
                -- Select the new marker
                for _, sm in ipairs(state.warp_markers) do
                  if math.abs(sm.srcpos - srcpos) < 0.001 then
                    state.warp_marker_selected_idx = sm.idx
                    break
                  end
                end
              end
            else
              -- Double-click empty area (no transient): CREATE at mouse position
              local click_time = px_to_time(mouse_x)
              local pos, srcpos
              if is_warped_view then
                pos = click_time
                srcpos = utils.warp_pos_to_src(state.warp_map, pos, playrate)
              else
                srcpos = click_time
                pos = srcpos
              end
              if srcpos >= 0 and srcpos <= source_length then
                reaper.Undo_BeginBlock()
                reaper.SetTakeStretchMarker(take, -1, pos, srcpos)
                reaper.UpdateArrange()
                reaper.UpdateItemInProject(item)
                reaper.Undo_EndBlock("NVSD_ItemView: Add stretch marker", -1)
                state.warp_markers = utils.get_stretch_markers(take)
                -- Select the new marker
                for _, sm in ipairs(state.warp_markers) do
                  if math.abs(sm.srcpos - srcpos) < 0.001 then
                    state.warp_marker_selected_idx = sm.idx
                    break
                  end
                end
              end
            end
          end

          -- Delete / Backspace: remove hovered stretch marker (Backspace for Mac)
          if (reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Delete())
              or reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Backspace()))
              and state.warp_marker_hovered_idx > 0 and not state.any_drag_active() then
            local sm = state.warp_markers[state.warp_marker_hovered_idx]
            if sm then
              if sm.idx == state.warp_marker_selected_idx then
                state.warp_marker_selected_idx = -1
              end
              reaper.Undo_BeginBlock()
              reaper.DeleteTakeStretchMarkers(take, sm.idx, 1)
              reaper.UpdateArrange()
              reaper.UpdateItemInProject(item)
              reaper.Undo_EndBlock("NVSD_ItemView: Delete stretch marker", -1)
              state.warp_markers = utils.get_stretch_markers(take)
              state.warp_marker_hovered_idx = -1
            end
          end

          -- Warp marker drag: initiate on click (skip if double-click was handled)
          if not warp_dblclick_handled
              and reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_warp_bar
              and state.warp_marker_hovered_idx > 0 and not state.any_drag_active() then
            local sm = state.warp_markers[state.warp_marker_hovered_idx]
            if sm then
              state.dragging_warp_marker = true
              state.warp_drag_idx = sm.idx
              state.warp_drag_start_mouse_x = mouse_x
              state.warp_drag_start_pos = sm.pos
              state.warp_drag_start_srcpos = sm.srcpos
              state.warp_drag_activated = false
              state.warp_drag_shift = shift_held  -- Shift+drag: slide source under marker
              state.warp_drag_start_view_start = view_start
              state.warp_drag_start_view_length = view_length
              state.warp_drag_start_ext_start = ext_start
              state.warp_drag_start_ext_end = ext_end
              state.warp_drag_start_wf_bounds_start = state.wf_bounds_start
              state.warp_drag_start_wf_bounds_end = state.wf_bounds_end
              state.warp_drag_start_item_position = item_position
              state.warp_drag_start_item_length = item_length
              state.warp_drag_start_start_offset = start_offset
              -- Select clicked marker
              state.warp_marker_selected_idx = sm.idx
            end
          end

          -- Transient ghost click-drag: initiate on click (create marker on drag, not click)
          if not warp_dblclick_handled
              and reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_warp_bar
              and state.transient_hovered_idx > 0 and state.warp_marker_hovered_idx <= 0
              and not state.any_drag_active() then
            state.transient_click_pending = true
            state.transient_click_srcpos = state.transients[state.transient_hovered_idx]
            state.transient_click_mouse_x = mouse_x
          end

          -- Transient ghost click-drag: threshold activation (create marker and start dragging)
          if state.transient_click_pending and reaper.ImGui_IsMouseDown(ctx, 0) then
            if math.abs(mouse_x - state.transient_click_mouse_x) >= (config.WARP_DRAG_THRESHOLD or 3) then
              local srcpos = state.transient_click_srcpos
              if srcpos then
                local pos = is_warped_view and utils.warp_src_to_pos(state.warp_map, srcpos, playrate) or srcpos
                reaper.SetTakeStretchMarker(take, -1, pos, srcpos)
                reaper.UpdateArrange()
                reaper.UpdateItemInProject(item)
                state.warp_markers = utils.get_stretch_markers(take)
                -- Find the newly created marker and enter drag mode
                for _, sm in ipairs(state.warp_markers) do
                  if math.abs(sm.srcpos - srcpos) < 0.001 then
                    state.dragging_warp_marker = true
                    state.warp_drag_idx = sm.idx
                    state.warp_drag_start_mouse_x = state.transient_click_mouse_x
                    state.warp_drag_start_pos = sm.pos
                    state.warp_drag_start_srcpos = sm.srcpos
                    state.warp_drag_activated = true  -- already past threshold
                    state.warp_drag_start_view_start = view_start
                    state.warp_drag_start_view_length = view_length
                    state.warp_drag_start_ext_start = ext_start
                    state.warp_drag_start_ext_end = ext_end
                    state.warp_drag_start_wf_bounds_start = state.wf_bounds_start
                    state.warp_drag_start_wf_bounds_end = state.wf_bounds_end
                    state.warp_drag_start_item_position = item_position
                    state.warp_drag_start_item_length = item_length
                    state.warp_drag_start_start_offset = start_offset
                    state.warp_marker_selected_idx = sm.idx
                    break
                  end
                end
              end
              state.transient_click_pending = false
            end
          end

          -- Transient ghost click-drag: cancel on release (just a click, no marker created)
          if state.transient_click_pending and reaper.ImGui_IsMouseReleased(ctx, 0) then
            state.transient_click_pending = false
          end

          -- Warp marker drag: threshold activation
          if state.dragging_warp_marker and not state.warp_drag_activated
              and reaper.ImGui_IsMouseDown(ctx, 0) then
            if math.abs(mouse_x - state.warp_drag_start_mouse_x) >= config.WARP_DRAG_THRESHOLD then
              state.warp_drag_activated = true
            end
          end

          -- Warp marker drag: execution
          -- Normal drag: move pos (timeline position), srcpos stays fixed.
          -- Shift+drag: pos stays fixed, srcpos (source mapping) slides under marker.
          if state.dragging_warp_marker and state.warp_drag_activated
              and reaper.ImGui_IsMouseDown(ctx, 0) then
            local mouse_delta_px = mouse_x - state.warp_drag_start_mouse_x
            local mouse_delta_time = (mouse_delta_px / waveform_width) * state.warp_drag_start_view_length

            if state.warp_drag_shift then
              -- Shift+drag: slide source audio under the marker.
              -- Marker pos stays fixed; srcpos changes by the delta (scaled by playrate).
              -- Dragging right = source slides right = srcpos decreases (earlier audio at this point).
              local srcpos_delta = -mouse_delta_time * playrate
              local new_srcpos = state.warp_drag_start_srcpos + srcpos_delta

              -- Constrain: don't cross adjacent markers' srcpos values.
              -- This keeps the source-time ordering consistent.
              local sm_count = reaper.GetTakeNumStretchMarkers(take)
              local prev_srcpos, next_srcpos = 0, source_length
              for si = 0, sm_count - 1 do
                if si ~= state.warp_drag_idx then
                  local _, spos, ssrc = reaper.GetTakeStretchMarker(take, si)
                  if spos < state.warp_drag_start_pos and ssrc > prev_srcpos then prev_srcpos = ssrc end
                  if spos > state.warp_drag_start_pos and ssrc < next_srcpos then next_srcpos = ssrc end
                end
              end
              new_srcpos = math.max(prev_srcpos + 0.001, math.min(next_srcpos - 0.001, new_srcpos))
              new_srcpos = math.max(0, math.min(source_length, new_srcpos))

              reaper.SetTakeStretchMarker(take, state.warp_drag_idx, state.warp_drag_start_pos, new_srcpos)
            else
              -- Normal drag: move pos, srcpos stays fixed
              local new_pos = state.warp_drag_start_pos + mouse_delta_time

              -- Snap pos to grid when snap is enabled
              new_pos = snap_to_grid_if_enabled(new_pos, 0, item_position, true)

              -- Constrain: don't cross adjacent markers
              local sm_count = reaper.GetTakeNumStretchMarkers(take)
              local prev_pos, next_pos = -math.huge, math.huge
              for si = 0, sm_count - 1 do
                if si ~= state.warp_drag_idx then
                  local _, spos = reaper.GetTakeStretchMarker(take, si)
                  if spos < state.warp_drag_start_pos and spos > prev_pos then prev_pos = spos end
                  if spos > state.warp_drag_start_pos and spos < next_pos then next_pos = spos end
                end
              end
              new_pos = math.max(prev_pos + 0.001, math.min(next_pos - 0.001, new_pos))

              reaper.SetTakeStretchMarker(take, state.warp_drag_idx, new_pos, state.warp_drag_start_srcpos)
            end
            -- Don't call UpdateArrange() during drag: it causes REAPER to recalculate
            -- item properties (D_STARTOFFS, D_POSITION) which shifts the view on the
            -- next frame, creating an oscillation feedback loop with snap.
            -- UpdateArrange is called on drag release instead.
            reaper.UpdateItemInProject(item)
            state.warp_markers = utils.get_stretch_markers(take)
          end

          -- Ruler drag zoom + pan
          if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_ruler and not we_are_dragging then
            state.is_ruler_dragging = true
            state.ruler_drag_start_y = mouse_y
            state.ruler_drag_start_zoom = state.zoom_level
            state.ruler_drag_cumulative_y = 0
            state.ruler_drag_start_pan = state.pan_offset
            state.ruler_drag_window_x = mouse_x  -- Store window-space X for zoom centering
            local screen_x, screen_y = reaper.GetMousePosition()
            state.ruler_drag_screen_x = screen_x
            state.ruler_drag_screen_y = screen_y
            state.ruler_drag_cursor_x = screen_x  -- Tracks visible cursor X position
          end

          if reaper.ImGui_IsMouseReleased(ctx, 0) then
            state.is_ruler_dragging = false
          end

          if state.is_ruler_dragging and reaper_is_active and reaper.ImGui_IsMouseDown(ctx, 0) then
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_None())
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
              local min_pan = ext_start - range_center + half_view
              local max_pan = ext_end - range_center - half_view
              if min_pan > max_pan then min_pan, max_pan = max_pan, min_pan end
              state.pan_offset = math.max(min_pan, math.min(max_pan, state.pan_offset))
            end

            -- With JS extension: lock cursor for infinite drag range
            if state.has_js_extension then
              local win_x, win_y = reaper.ImGui_GetWindowPos(ctx)
              local wave_screen_left = win_x + wave_x - cursor_x + config.WINDOW_PADDING
              local wave_screen_right = wave_screen_left + waveform_width

              local target_cursor_x = state.ruler_drag_cursor_x
              if can_pan then
                target_cursor_x = target_cursor_x + delta_x
                target_cursor_x = math.max(wave_screen_left, math.min(wave_screen_right, target_cursor_x))
                state.ruler_drag_cursor_x = target_cursor_x
              end
              reaper.JS_Mouse_SetPosition(math.floor(state.ruler_drag_cursor_x), state.ruler_drag_screen_y)
              state.ruler_drag_screen_x = math.floor(state.ruler_drag_cursor_x)
            else
              state.ruler_drag_screen_x = cur_screen_x
              state.ruler_drag_screen_y = cur_screen_y
            end
          end

          -- Middle mouse panning (also Ctrl+Alt+left-click drag)
          local middle_mouse = 2
          if reaper.ImGui_IsMouseClicked(ctx, middle_mouse) and mouse_in_waveform and not we_are_dragging then
            state.is_panning = true
            state.pan_start_mouse_x = mouse_x
            state.pan_start_offset = state.pan_offset
            state.zoom_toggle_active = false
          end
          -- Ctrl+Alt+left-click: alternative pan initiation
          if ctrl_held and alt_held and reaper.ImGui_IsMouseClicked(ctx, 0)
              and mouse_in_waveform and not we_are_dragging then
            state.is_panning = true
            state.pan_via_left_click = true
            state.pan_start_mouse_x = mouse_x
            state.pan_start_offset = state.pan_offset
            state.zoom_toggle_active = false
          end

          if reaper.ImGui_IsMouseReleased(ctx, middle_mouse) and not state.pan_via_left_click then
            state.is_panning = false
          end
          if state.pan_via_left_click and reaper.ImGui_IsMouseReleased(ctx, 0) then
            state.is_panning = false
            state.pan_via_left_click = false
          end

          if state.is_panning and reaper_is_active
              and (reaper.ImGui_IsMouseDown(ctx, middle_mouse)
                   or (state.pan_via_left_click and reaper.ImGui_IsMouseDown(ctx, 0))) then
            local mouse_delta_px = mouse_x - state.pan_start_mouse_x
            local delta_time = -(mouse_delta_px / waveform_width) * view_length
            state.pan_offset = state.pan_start_offset + delta_time
            -- Pan limits: keep view within bounds
            local half_view = view_length / 2
            local min_pan = ext_start - range_center + half_view
            local max_pan = ext_end - range_center - half_view
            if min_pan > max_pan then min_pan, max_pan = max_pan, min_pan end
            state.pan_offset = math.max(min_pan, math.min(max_pan, state.pan_offset))
          end

          -- Pitch gutter drag to scroll vertical view
          if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_pitch_gutter and not we_are_dragging then
            state.pitch_gutter_dragging = true
            state.pitch_gutter_drag_start_y = mouse_y
            state.pitch_gutter_drag_start_offset = state.pitch_view_offset
          end

          if state.pitch_gutter_dragging then
            if reaper.ImGui_IsMouseDown(ctx, 0) then
              local dy = mouse_y - state.pitch_gutter_drag_start_y
              -- Convert pixel delta to semitones: waveform_height spans 48 semitones
              local st_delta = (dy / waveform_height) * 48
              state.pitch_view_offset = state.pitch_gutter_drag_start_offset + st_delta
              state.pitch_view_offset = math.max(-24, math.min(24, state.pitch_view_offset))
            else
              state.pitch_gutter_dragging = false
            end
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
              local sx, sy = reaper.GetMousePosition()
              state.fade_curve_lock_x, state.fade_curve_lock_y = sx, sy
              state.fade_curve_last_y = sy
              if not state.undo_block_open then
                state.undo_block_open = "fade_curve_in"
              end
            elseif mouse_in_fade_out_body then
              state.dragging_fade_curve_out = true
              state.fade_curve_drag_start_value = fade_out_dir
              state.fade_curve_cumulative_y = 0
              state.fade_curve_was_dragged = false
              local sx, sy = reaper.GetMousePosition()
              state.fade_curve_lock_x, state.fade_curve_lock_y = sx, sy
              state.fade_curve_last_y = sy
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

          -- Start marker dragging (skip if fade drag already started this click, or Ctrl+envelope freehand)
          if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_marker_area
              and not state.dragging_fade_in and not state.dragging_fade_out
              and not state.is_ruler_dragging and not state.is_panning
              and not (ctrl_held and state.envelopes_visible) then
            if near_start then
              -- Compute drag_offset from post_drag_ext BEFORE clearing it (handles the case
              -- where snap_to_source_boundary made source_item_length == source_length exactly,
              -- causing is_looped_item to be false even though the item was just extended)
              local drag_offset
              if state.post_drag_ext_start ~= nil then
                drag_offset = state.post_drag_ext_start
              elseif is_looped_item then
                drag_offset = state.unwrapped_start_offset or start_offset
              else
                drag_offset = view_offset
              end
              state.post_drag_ext_start = nil
              state.post_drag_ext_end = nil
              state.dragging_start = true
              state.drag_alt_latched = alt_held
              state.marker_drag_activated = false
              state.drag_start_offset = drag_offset
              state.drag_start_length = item_length
              state.drag_start_item_position = item_position
              state.drag_start_mouse_x = mouse_x
              state.drag_start_view_length = view_length
              state.drag_start_view_start = view_start
              state.drag_start_playrate = playrate
              if is_warped_view then
                -- In warp mode, drag coordinates are in pos-time
                state.drag_current_start = 0
                state.drag_current_end = item_length
                -- Save original stretch markers for real-time shifting during drag
                state.drag_start_warp_markers = {}
                for _, sm in ipairs(state.warp_markers) do
                  state.drag_start_warp_markers[#state.drag_start_warp_markers + 1] = {
                    pos = sm.pos, srcpos = sm.srcpos
                  }
                end
                state.drag_start_warp_map = state.warp_map
                state.drag_start_src_pos_start = utils.warp_src_to_pos(state.warp_map, 0, playrate)
                state.drag_start_src_pos_end = utils.warp_src_to_pos(state.warp_map, source_length, playrate)
              else
                state.drag_current_start = drag_offset
                state.drag_current_end = drag_offset + source_item_length
                -- Save stretch markers for shifting during non-warp alt-drag
                local sm_count = reaper.GetTakeNumStretchMarkers(take)
                if sm_count > 0 then
                  state.drag_start_stretch_markers = {}
                  for si = 0, sm_count - 1 do
                    local _, pos, srcpos = reaper.GetTakeStretchMarker(take, si)
                    state.drag_start_stretch_markers[#state.drag_start_stretch_markers + 1] = {
                      pos = pos, srcpos = srcpos
                    }
                  end
                else
                  state.drag_start_stretch_markers = nil
                end
              end
              state.drag_start_fade_in = fade_in_len
              state.drag_start_fade_out = fade_out_len
            elseif near_end then
              local drag_offset
              if state.post_drag_ext_start ~= nil then
                drag_offset = state.post_drag_ext_start
              elseif is_looped_item then
                drag_offset = state.unwrapped_start_offset or start_offset
              else
                drag_offset = view_offset
              end
              state.post_drag_ext_start = nil
              state.post_drag_ext_end = nil
              state.dragging_end = true
              state.drag_alt_latched = alt_held
              state.marker_drag_activated = false
              state.drag_start_offset = drag_offset
              state.drag_start_length = item_length
              state.drag_start_item_position = item_position
              state.drag_start_mouse_x = mouse_x
              state.drag_start_view_length = view_length
              state.drag_start_view_start = view_start
              state.drag_start_playrate = playrate
              if is_warped_view then
                -- In warp mode, drag coordinates are in pos-time
                state.drag_current_start = 0
                state.drag_current_end = item_length
                state.drag_start_src_pos_start = utils.warp_src_to_pos(state.warp_map, 0, playrate)
                state.drag_start_src_pos_end = utils.warp_src_to_pos(state.warp_map, source_length, playrate)
                -- Save markers/map for alt+drag (slide both) in warp mode
                if alt_held then
                  state.drag_start_warp_markers = {}
                  for _, sm in ipairs(state.warp_markers) do
                    state.drag_start_warp_markers[#state.drag_start_warp_markers + 1] = {
                      pos = sm.pos, srcpos = sm.srcpos
                    }
                  end
                  state.drag_start_warp_map = state.warp_map
                end
              else
                state.drag_current_start = drag_offset
                state.drag_current_end = drag_offset + source_item_length
              end
              state.drag_start_fade_in = fade_in_len
              state.drag_start_fade_out = fade_out_len
            end
          end

          -- Alt+click in free zone: initiate zone drag (slides both markers, disabled when looped)
          -- Envelope segment/node hover takes priority (tension drag, delete)
          if reaper.ImGui_IsMouseClicked(ctx, 0) and alt_held and not ctrl_held and mouse_in_free_zone
              and not is_looped_item
              and not state.dragging_start and not state.dragging_end
              and not state.dragging_fade_in and not state.dragging_fade_out
              and not state.dragging_fade_curve_in and not state.dragging_fade_curve_out
              and not state.is_ruler_dragging and not state.is_panning
              and not (state.envelopes_visible and (state.envelope_hovered_segment >= 0 or state.env_node_hovered_idx >= 0)) then
            state.post_drag_ext_start = nil
            state.post_drag_ext_end = nil
            state.dragging_zone = true
            state.dragging_start = true  -- reuse marker drag machinery
            state.drag_alt_latched = true
            state.marker_drag_activated = false
            state.drag_start_offset = view_offset
            state.drag_start_length = item_length
            state.drag_start_item_position = item_position
            state.drag_start_mouse_x = mouse_x
            state.drag_start_view_length = view_length
            state.drag_start_view_start = view_start
            state.drag_start_playrate = playrate
            if is_warped_view then
              state.drag_current_start = 0
              state.drag_current_end = item_length
              state.drag_start_src_pos_start = utils.warp_src_to_pos(state.warp_map, 0, playrate)
              state.drag_start_src_pos_end = utils.warp_src_to_pos(state.warp_map, source_length, playrate)
              -- Save original stretch markers for srcpos shifting during slide
              state.drag_start_warp_markers = {}
              for _, sm in ipairs(state.warp_markers) do
                state.drag_start_warp_markers[#state.drag_start_warp_markers + 1] = {
                  pos = sm.pos, srcpos = sm.srcpos
                }
              end
              state.drag_start_warp_map = state.warp_map
            else
              state.drag_current_start = view_offset
              state.drag_current_end = view_offset + source_item_length
              -- Save stretch markers for shifting during non-warp alt-drag
              local sm_count = reaper.GetTakeNumStretchMarkers(take)
              if sm_count > 0 then
                state.drag_start_stretch_markers = {}
                for si = 0, sm_count - 1 do
                  local _, pos, srcpos = reaper.GetTakeStretchMarker(take, si)
                  state.drag_start_stretch_markers[#state.drag_start_stretch_markers + 1] = {
                    pos = pos, srcpos = srcpos
                  }
                end
              else
                state.drag_start_stretch_markers = nil
              end
            end
            state.drag_start_fade_in = fade_in_len
            state.drag_start_fade_out = fade_out_len
            if not state.undo_block_open then
              state.undo_block_open = "slide_both"
            end
          end

          -- Slope handle drag: click on hovered slope handle (no modifier)
          -- Dragging up/down changes slope (rate distribution within the segment)
          if reaper.ImGui_IsMouseClicked(ctx, 0) and state.slope_hovered_segment > 0
              and not state.any_drag_active()
              and not (state.envelopes_visible and state.envelope_hovered_segment >= 0)
              and not near_start and not near_end
              and not near_fade_in and not near_fade_out then
            local seg = state.slope_hovered_segment
            local endpoint = state.slope_hovered_endpoint  -- 1=left, 2=right
            local sm1 = state.warp_markers[seg]
            local sm2 = state.warp_markers[seg + 1]
            if sm1 and sm2 then
              -- The marker to move: left endpoint = left marker, right = right marker
              local sm = (endpoint == 1) and sm1 or sm2
              if reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
                -- Double-click: reset slope to 0
                reaper.SetTakeStretchMarkerSlope(take, sm1.idx, 0)
                local _, mpos, msrcpos = reaper.GetTakeStretchMarker(take, sm1.idx)
                reaper.SetTakeStretchMarker(take, sm1.idx, mpos, msrcpos)
                reaper.UpdateItemInProject(item)
                reaper.UpdateArrange()
                state.warp_markers = utils.get_stretch_markers(take)
                reaper.Undo_OnStateChangeEx("NVSD_ItemView: Reset stretch marker slope", -1, -1)
              else
                local cur_slope = sm1.slope or 0
                local cur_rate = (sm2.pos ~= sm1.pos) and (sm2.srcpos - sm1.srcpos) / (sm2.pos - sm1.pos) or 1
                local y_left, y_right = drawing.slope_handle_positions(wave_y, waveform_height, cur_slope, cur_rate)
                state.slope_dragging = true
                state.slope_drag_segment = seg
                state.slope_drag_endpoint = endpoint
                state.slope_drag_start_mouse_y = mouse_y
                -- M1 (left) always stays fixed, M2 (right) always moves
                state.slope_drag_start_pos = sm1.pos
                state.slope_drag_start_srcpos = sm1.srcpos
                state.slope_drag_time_per_px = view_length / waveform_width
                state.slope_drag_start_handle_y = (endpoint == 1) and y_left or y_right
                state.slope_drag_anchor_local_rate = (endpoint == 1)
                    and math.max(0.001, cur_rate * (1 + cur_slope))
                    or  math.max(0.001, cur_rate * (1 - cur_slope))
                state.slope_drag_partner_idx = sm2.idx
                state.slope_drag_partner_pos = sm2.pos
                state.slope_drag_partner_srcpos = sm2.srcpos
                state.slope_drag_slope_idx = sm1.idx
                state.slope_drag_start_slope = cur_slope
                -- Save all marker positions for cascading during drag (keyed by srcpos string)
                state.slope_drag_orig_markers = {}
                local sm_total = reaper.GetTakeNumStretchMarkers(take)
                for si = 0, sm_total - 1 do
                  local _, mpos, msrcpos = reaper.GetTakeStretchMarker(take, si)
                  state.slope_drag_orig_markers[#state.slope_drag_orig_markers + 1] = {pos = mpos, srcpos = msrcpos}
                end
                -- Save view state for freeze during drag
                state.slope_drag_start_view_start = view_start
                state.slope_drag_start_view_length = view_length
                state.slope_drag_start_ext_start = ext_start
                state.slope_drag_start_ext_end = ext_end
                state.slope_drag_start_wave_y = wave_y
                state.slope_drag_start_waveform_height = waveform_height
                state.slope_drag_activated = false
              end
            end
          end

          -- Region selection: click+drag in waveform (sample & envelope tabs)
          if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_waveform
              and not state._any_popup_open
              and not (state.envelopes_visible
                  and (state.env_node_hovered_idx >= 0
                       or state.envelope_hovered_segment >= 0
                       or ctrl_held))
              and not state.dragging_start and not state.dragging_end
              and not state.dragging_fade_in and not state.dragging_fade_out
              and not state.dragging_fade_curve_in and not state.dragging_fade_curve_out
              and not near_start and not near_end
              and not near_fade_in and not near_fade_out
              and not (state.slope_hovered_segment > 0)
              and not alt_held and not shift_held then
            state.selecting_region = true
            state.selection_drag_activated = false
            state.selection_start_mouse_x = mouse_x
            state.selection_start_time = px_to_time(mouse_x)
            state.selection_end_time = state.selection_start_time
            -- Don't clear region_selected here; only replace when new drag finalizes
            state.env_selected_nodes = {}
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
              local clamp_min = is_extended_view and ext_start or 0
              local clamp_max = is_extended_view and ext_end or source_length
              s = math.max(clamp_min, math.min(clamp_max, s))
              e = math.max(clamp_min, math.min(clamp_max, e))
              if e - s > 0 then
                state.region_selected = true
                state.region_sel_start = s
                state.region_sel_end = e
                state.region_sel_item = item
              end
            else
              -- Click without drag threshold: clear selection, set preview cursor
              -- Skip if mouse is over a cue marker label (double-click handled there)
              if not state.cue_label_hovered then
                state.region_selected = false
                local click_t = px_to_time(mouse_x)
                if is_warped_view then
                  click_t = snap_to_grid_if_enabled(click_t, 0, nil)
                else
                  click_t = snap_to_grid_if_enabled(click_t)
                end
                state.preview_cursor_pos = click_t
                if state.preview_active then
                  state.stop_preview()
                  state.preview_start_requested = true
                end
              end
            end
          end

          -- Ctrl+C / Cmd+C: copy selected region to REAPER clipboard
          -- Uses both ImGui key detection and raw VKey fallback (macOS compatibility)
          if (vkey_copy_pressed or (ctrl_held and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_C())))
              and state.region_selected and state.region_sel_item == item then
            local sel_s = state.region_sel_start
            local sel_e = state.region_sel_end
            local new_length = (sel_e - sel_s) / playrate
            local new_startoffs = sel_s - section_offset
            -- Wrap for REAPER only when loop is on (non-looped items allow negative D_STARTOFFS)
            if source_length > 0 and state.is_loop_src then
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

            -- Shift envelope points to match the new D_STARTOFFS (preserve full envelope)
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

                  -- Clear all original points and write shifted ones (no trimming)
                  for i = np - 1, 0, -1 do
                    reaper.DeleteEnvelopePointEx(e, -1, i)
                  end
                  for _, p in ipairs(pts) do
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
            -- Clear node selection when envelope type changes
            if state.env_selection_env_name and state.env_selection_env_name ~= env_name then
              state.env_selected_nodes = {}
              state.env_selection_env_name = nil
            end
            local is_pitch = (env_name == "Pitch")
            local is_pan = (env_name == "Pan")
            local is_centered = is_pitch or is_pan
            -- Envelope coordinate helpers: use live drag offset during drag, unwrapped when available
            local env_offset
            if state.dragging_start or state.dragging_end then
              env_offset = state.drag_current_start or start_offset
            elseif state.unwrapped_start_offset ~= nil then
              env_offset = state.unwrapped_start_offset
            else
              env_offset = view_offset
            end
            local env_time_min = is_extended_view and ext_start or 0
            local env_time_max = is_extended_view and ext_end or source_length
            local env_max_raw = is_pitch and 48.0 or (is_pan and 1.0 or reaper.ScaleToEnvelopeMode(is_centered and 0 or 1, 2.0))
            local env_min_raw = is_pitch and -48.0 or (is_pan and -1.0 or 0)

            -- View window for pitch (scrollable) - maps mouse Y to the visible 48-semitone window
            local view_min = is_pitch and (-24 + state.pitch_view_offset) or env_min_raw
            local view_max = is_pitch and (24 + state.pitch_view_offset) or env_max_raw

            -- Helper: convert mouse Y to envelope raw value
            local function mouse_y_to_raw(my)
              local raw = view_min + (view_max - view_min) * (1 - (my - wave_y) / waveform_height)
              raw = math.max(env_min_raw, math.min(env_max_raw, raw))  -- clamp to full range, not view
              -- Pitch: snap to whole semitones (if snap enabled)
              if is_pitch and state.env_snap_enabled then raw = math.floor(raw + 0.5) end
              return raw
            end

            -- Auto-scroll pitch view when mouse approaches waveform edges during drag
            local function pitch_auto_scroll(my)
              if not is_pitch then return end
              local edge = config.PITCH_AUTO_SCROLL_EDGE
              local top_edge = wave_y + edge
              local bot_edge = wave_y + waveform_height - edge
              if my < top_edge then
                local factor = math.min((top_edge - my) / edge, 1.5)
                state.pitch_view_offset = state.pitch_view_offset + config.PITCH_AUTO_SCROLL_RATE * factor
              elseif my > bot_edge then
                local factor = math.min((my - bot_edge) / edge, 1.5)
                state.pitch_view_offset = state.pitch_view_offset - config.PITCH_AUTO_SCROLL_RATE * factor
              end
              state.pitch_view_offset = math.max(-24, math.min(24, state.pitch_view_offset))
              view_min = is_pitch and (-24 + state.pitch_view_offset) or env_min_raw
              view_max = is_pitch and (24 + state.pitch_view_offset) or env_max_raw
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
              if env then
                -- Clean up default points from freshly created envelope
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
              pitch_auto_scroll(mouse_y)
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
                -- Check if hovered node is in the selection
                local is_in_selection = false
                if #state.env_selected_nodes > 0 then
                  local env = reaper.GetTakeEnvelopeByName(take, env_name)
                  if env then
                    local ret, ht, hv = reaper.GetEnvelopePoint(env, state.env_node_hovered_idx)
                    if ret then
                      local h_src = ht + env_offset
                      for _, sel in ipairs(state.env_selected_nodes) do
                        if math.abs(h_src - sel.src_time) < 0.0001 and math.abs(hv - sel.value) < 0.0001 then
                          is_in_selection = true
                          break
                        end
                      end
                    end
                  end
                end

                if is_in_selection then
                  -- Start multi-node drag
                  state.env_multi_dragging = true
                  state.env_multi_drag_start_mouse_x = mouse_x
                  state.env_multi_drag_start_mouse_y = mouse_y
                  state.env_multi_drag_activated = false
                  state.env_multi_drag_env_name = env_name
                  state.env_multi_drag_env_offset = env_offset
                  state.env_multi_drag_start_positions = {}
                  local env = reaper.GetTakeEnvelopeByName(take, env_name)
                  if env then
                    local count = reaper.CountEnvelopePoints(env)
                    for pi = 0, count - 1 do
                      local ret, pt_time, pt_value = reaper.GetEnvelopePoint(env, pi)
                      if ret then
                        local pt_src = pt_time + env_offset
                        for _, sel in ipairs(state.env_selected_nodes) do
                          if math.abs(pt_src - sel.src_time) < 0.0001 and math.abs(pt_value - sel.value) < 0.0001 then
                            table.insert(state.env_multi_drag_start_positions, {idx = pi, take_time = pt_time, value = pt_value})
                            break
                          end
                        end
                      end
                    end
                  end
                  if not state.undo_block_open then
                    state.undo_block_open = "env_multi_node"
                  end
                else
                  -- Clear selection, start normal single-node drag
                  state.env_selected_nodes = {}
                  local env = reaper.GetTakeEnvelopeByName(take, env_name)
                  if env then
                    local retval, pt_time, pt_value, pt_shape, pt_tension = reaper.GetEnvelopePoint(env, state.env_node_hovered_idx)
                    if retval then
                      state.dragging_env_node = true
                      state.env_drag_node_idx = state.env_node_hovered_idx
                      state.env_drag_start_mouse_x = mouse_x
                      state.env_drag_start_mouse_y = mouse_y
                      state.env_drag_start_time = pt_time
                      state.env_drag_start_value = pt_value
                      state.env_drag_node_shape = pt_shape
                      state.env_drag_node_tension = pt_tension
                      state.env_drag_activated = false
                      if not state.undo_block_open then
                        state.undo_block_open = "env_node"
                      end
                    end
                  end
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
                -- Use raw mouse time (not snapped hover_time) to find the correct segment
                local raw_source_time = px_to_time(mouse_x)
                local raw_take_time = raw_source_time - env_offset
                local seg_pt_idx = -1
                local np = reaper.CountEnvelopePoints(env)
                for pi = 0, np - 2 do
                  local ret1, t1 = reaper.GetEnvelopePoint(env, pi)
                  local ret2, t2 = reaper.GetEnvelopePoint(env, pi + 1)
                  if ret1 and ret2 and raw_take_time >= t1 - 0.001 and raw_take_time <= t2 + 0.001 then
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
                and not state.env_tension_dragging
                and not state.dragging_start and not state.dragging_end
                and not state.dragging_fade_curve_in and not state.dragging_fade_curve_out then
              local env = reaper.GetTakeEnvelopeByName(take, env_name)
              if env then
                -- Use raw mouse time (not snapped hover_time) to find the correct segment
                local raw_source_time = px_to_time(mouse_x)
                local raw_take_time = raw_source_time - env_offset
                local seg_pt_idx = -1
                local np = reaper.CountEnvelopePoints(env)
                for pi = 0, np - 2 do
                  local ret1, t1 = reaper.GetEnvelopePoint(env, pi)
                  local ret2, t2 = reaper.GetEnvelopePoint(env, pi + 1)
                  if ret1 and ret2 and raw_take_time >= t1 - 0.001 and raw_take_time <= t2 + 0.001 then
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
                    state.env_tension_start_mouse_x = mouse_x
                    state.env_tension_start_value = (pt_shape == 5) and pt_tension or 0
                    state.env_tension_activated = false
                    if not state.undo_block_open then
                      state.undo_block_open = "env_tension"
                    end
                  end
                end
              end
            end

            -- Click on segment (no modifier): start segment drag (move both nodes vertically)
            if reaper.ImGui_IsMouseClicked(ctx, 0) and not shift_held
                and not alt_held
                and not reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())
                and state.envelope_hovered_segment >= 0
                and state.env_node_hovered_idx < 0
                and not state.dragging_env_node
                and not state.env_tension_dragging
                and not state.env_segment_dragging then
              state.env_selected_nodes = {}
              local env = reaper.GetTakeEnvelopeByName(take, env_name)

              -- Create envelope if clicking on default line (no envelope exists yet)
              if not env then
                env = ensure_take_envelope(item, take, env_name)
                -- Clean up default points for a fresh start
                if env then
                  local del_count = reaper.CountEnvelopePoints(env)
                  for di = del_count - 1, 0, -1 do
                    reaper.DeleteEnvelopePointEx(env, -1, di)
                  end
                end
              end

              if env then
                local np = reaper.CountEnvelopePoints(env)

                -- No points (default line): create anchor points and start segment drag
                if np == 0 then
                  local actual_scaling = reaper.GetEnvelopeScalingMode(env)
                  local default_val = is_centered and 0 or reaper.ScaleToEnvelopeMode(actual_scaling, 1.0)
                  local t_start = env_time_min - env_offset
                  local t_end = env_time_max - env_offset
                  reaper.InsertEnvelopePoint(env, t_start, default_val, 0, 0, false, true)
                  reaper.InsertEnvelopePoint(env, t_end, default_val, 0, 0, false, true)
                  reaper.Envelope_SortPoints(env)
                  state.env_segment_dragging = true
                  state.env_segment_idx1 = 0
                  state.env_segment_idx2 = 1
                  state.env_segment_start_mouse_y = mouse_y
                  state.env_segment_start_val1 = default_val
                  state.env_segment_start_val2 = default_val
                  state.env_segment_activated = false
                  if not state.undo_block_open then
                    state.undo_block_open = "env_segment"
                  end
                  reaper.UpdateArrange()
                else
                  -- Use raw mouse time (not snapped hover_time) to find the correct segment
                  local raw_source_time = px_to_time(mouse_x)
                  local raw_take_time = raw_source_time - env_offset
                  local found = false

                  -- Check implicit left segment (before first REAPER point)
                  if np > 0 and not found then
                    local ret0, t0, v0 = reaper.GetEnvelopePoint(env, 0)
                    if ret0 and raw_take_time < t0 + 0.001 then
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
                      if ret1 and ret2 and raw_take_time >= t1 - 0.001 and raw_take_time <= t2 + 0.001 then
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
                    if retN and raw_take_time > tN - 0.001 then
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
            end

            -- Shift+click on segment: create node and immediately start dragging
            if reaper.ImGui_IsMouseClicked(ctx, 0) and shift_held
                and not alt_held
                and state.envelope_hovered_segment >= 0
                and state.env_node_hovered_idx < 0
                and not state.dragging_env_node
                and not state.env_tension_dragging
                and not state.env_segment_dragging then
              local env = reaper.GetTakeEnvelopeByName(take, env_name)
              local just_created = false
              if not env then
                env = ensure_take_envelope(item, take, env_name)
                just_created = env ~= nil
              end
              if env then
                if just_created then
                  local del_count = reaper.CountEnvelopePoints(env)
                  for di = del_count - 1, 0, -1 do
                    reaper.DeleteEnvelopePointEx(env, -1, di)
                  end
                end
                local snapped_src = snap_to_grid_if_enabled(state.envelope_hover_time)
                local take_time = snapped_src - env_offset
                reaper.InsertEnvelopePoint(env, take_time, state.envelope_hover_value, 0, 0, false, true)
                reaper.Envelope_SortPoints(env)
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
                if new_idx >= 0 then
                  state.dragging_env_node = true
                  state.env_drag_node_idx = new_idx
                  state.env_drag_start_mouse_x = mouse_x
                  state.env_drag_start_mouse_y = mouse_y
                  state.env_drag_start_time = take_time
                  state.env_drag_start_value = state.envelope_hover_value
                  state.env_drag_node_shape = 0
                  state.env_drag_node_tension = 0
                  state.env_drag_activated = false
                  if not state.undo_block_open then
                    state.undo_block_open = "env_node"
                  end
                end
                reaper.UpdateArrange()
              end
            end

            -- Shift+click in empty waveform space: create envelope node and start dragging
            if reaper.ImGui_IsMouseClicked(ctx, 0) and shift_held
                and not alt_held
                and mouse_in_waveform
                and state.envelope_hovered_segment < 0
                and state.env_node_hovered_idx < 0
                and not state.dragging_env_node
                and not state.env_tension_dragging
                and not state.env_segment_dragging
                and not state.dragging_start and not state.dragging_end
                and not state.dragging_fade_in and not state.dragging_fade_out then
              local env = reaper.GetTakeEnvelopeByName(take, env_name)
              if not env then
                env = ensure_take_envelope(item, take, env_name)
                if env then
                  for di = reaper.CountEnvelopePoints(env) - 1, 0, -1 do
                    reaper.DeleteEnvelopePointEx(env, -1, di)
                  end
                end
              end
              if env then
                local src_time = math.max(env_time_min, math.min(env_time_max, px_to_time(mouse_x)))
                local snapped_src = snap_to_grid_if_enabled(src_time)
                local take_time = snapped_src - env_offset
                local raw_val = mouse_y_to_raw(mouse_y)
                reaper.InsertEnvelopePoint(env, take_time, raw_val, 0, 0, false, true)
                reaper.Envelope_SortPoints(env)
                -- Find the new point's index
                local new_idx = -1
                local count = reaper.CountEnvelopePoints(env)
                for pi = 0, count - 1 do
                  local retval, pt_time, pt_value = reaper.GetEnvelopePoint(env, pi)
                  if retval and math.abs(pt_time - take_time) < 0.0001
                     and math.abs(pt_value - raw_val) < 0.0001 then
                    new_idx = pi
                    break
                  end
                end
                if new_idx >= 0 then
                  state.dragging_env_node = true
                  state.env_drag_node_idx = new_idx
                  state.env_drag_start_mouse_x = mouse_x
                  state.env_drag_start_mouse_y = mouse_y
                  state.env_drag_start_time = take_time
                  state.env_drag_start_value = raw_val
                  state.env_drag_node_shape = 0
                  state.env_drag_node_tension = 0
                  state.env_drag_activated = false
                  if not state.undo_block_open then
                    state.undo_block_open = "env_node"
                  end
                end
                reaper.UpdateArrange()
              end
            end

            -- Alt+click: delete hovered node
            if (reaper.ImGui_IsMouseClicked(ctx, 0) and alt_held)
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
                pitch_auto_scroll(mouse_y)
                local env = reaper.GetTakeEnvelopeByName(take, env_name)
                if env then
                  local new_source_time = px_to_time(mouse_x)
                  local new_raw = mouse_y_to_raw(mouse_y)
                  new_source_time = math.max(env_time_min, math.min(env_time_max, new_source_time))
                  new_source_time = snap_to_grid_if_enabled(new_source_time)
                  -- Convert source time to take time
                  local take_time = new_source_time - env_offset
                  reaper.SetEnvelopePoint(env, state.env_drag_node_idx, take_time, new_raw, state.env_drag_node_shape or 0, state.env_drag_node_tension or 0, false, true)
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
                pitch_auto_scroll(mouse_y)
                local env = reaper.GetTakeEnvelopeByName(take, env_name)
                if env then
                  -- Convert pixel delta to value delta (use view window for coordinate mapping)
                  local val_per_px = (view_max - view_min) / waveform_height
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

            -- Tension drag: update curve shape while alt+dragging on segment
            -- Uses horizontal movement only (matches REAPER native behavior)
            if state.env_tension_dragging and reaper_is_active and reaper.ImGui_IsMouseDown(ctx, 0) then
              local d = mouse_x - state.env_tension_start_mouse_x
              if not state.env_tension_activated and math.abs(d) >= 4 then
                state.env_tension_activated = true
              end
              if state.env_tension_activated then
                local env = reaper.GetTakeEnvelopeByName(take, env_name)
                if env then
                  -- 120px of movement = full tension range (-1 to +1)
                  local sensitivity = 2.0 / 120
                  local new_tension = state.env_tension_start_value + d * sensitivity
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

            -- Right-click in waveform: start rectangle selection
            if reaper.ImGui_IsMouseClicked(ctx, 1) and mouse_in_waveform
                and state.envelopes_visible
                and not state.env_rect_selecting
                and state.env_node_hovered_idx < 0 then
              state.env_rect_selecting = true
              state.env_rect_sel_start_x = mouse_x
              state.env_rect_sel_start_y = mouse_y
              state.env_rect_sel_activated = false
              state.env_rect_sel_env_name = env_name
              state.env_rect_sel_env_offset = env_offset
            end

            -- Rectangle selection tracking
            if state.env_rect_selecting and reaper.ImGui_IsMouseDown(ctx, 1) then
              local dx = mouse_x - state.env_rect_sel_start_x
              local dy = mouse_y - state.env_rect_sel_start_y
              if not state.env_rect_sel_activated and (math.abs(dx) >= 4 or math.abs(dy) >= 4) then
                state.env_rect_sel_activated = true
              end
            end

            -- Multi-node drag update (full rebuild with sweep)
            if state.env_multi_dragging and reaper_is_active and reaper.ImGui_IsMouseDown(ctx, 0) then
              local dx = mouse_x - state.env_multi_drag_start_mouse_x
              local dy = mouse_y - state.env_multi_drag_start_mouse_y
              if not state.env_multi_drag_activated and (math.abs(dx) >= 4 or math.abs(dy) >= 4) then
                state.env_multi_drag_activated = true
                -- Snapshot ALL envelope points at activation
                local m_env_name = state.env_multi_drag_env_name or env_name
                local snap_env = reaper.GetTakeEnvelopeByName(take, m_env_name)
                if snap_env then
                  state.env_multi_drag_all_points = {}
                  local snap_count = reaper.CountEnvelopePoints(snap_env)
                  for pi = 0, snap_count - 1 do
                    local ret, pt_time, pt_value, pt_shape, pt_tension, pt_selected = reaper.GetEnvelopePoint(snap_env, pi)
                    if ret then
                      -- Check if this point is one of the selected/dragged nodes
                      local is_ours = false
                      for _, pos in ipairs(state.env_multi_drag_start_positions) do
                        if math.abs(pt_time - pos.take_time) < 0.0001 and math.abs(pt_value - pos.value) < 0.0001 then
                          is_ours = true
                          break
                        end
                      end
                      table.insert(state.env_multi_drag_all_points, {
                        take_time = pt_time, value = pt_value,
                        shape = pt_shape, tension = pt_tension,
                        selected = pt_selected, is_ours = is_ours
                      })
                    end
                  end
                end
              end
              if state.env_multi_drag_activated then
                pitch_auto_scroll(mouse_y)
                local m_env_name = state.env_multi_drag_env_name or env_name
                local m_env_offset = state.env_multi_drag_env_offset or env_offset
                local env = reaper.GetTakeEnvelopeByName(take, m_env_name)
                if env and #state.env_multi_drag_all_points > 0 then
                  local start_src_t = px_to_time(state.env_multi_drag_start_mouse_x)
                  local current_src_t = px_to_time(mouse_x)
                  -- Snap: compute dt so that the reference node lands on a grid line
                  local snapped_current = snap_to_grid_if_enabled(current_src_t)
                  local dt = snapped_current - start_src_t
                  local start_raw = mouse_y_to_raw(state.env_multi_drag_start_mouse_y)
                  local current_raw = mouse_y_to_raw(mouse_y)
                  local dv = current_raw - start_raw

                  -- Compute current span of selected nodes (their footprint after drag)
                  local span_min, span_max = math.huge, -math.huge
                  for _, pt in ipairs(state.env_multi_drag_all_points) do
                    if pt.is_ours then
                      local cur_t = pt.take_time + dt
                      if cur_t < span_min then span_min = cur_t end
                      if cur_t > span_max then span_max = cur_t end
                    end
                  end

                  -- Delete all existing points
                  local del_count = reaper.CountEnvelopePoints(env)
                  for di = del_count - 1, 0, -1 do
                    reaper.DeleteEnvelopePointEx(env, -1, di)
                  end

                  -- Rebuild from snapshot
                  for _, pt in ipairs(state.env_multi_drag_all_points) do
                    if pt.is_ours then
                      -- Selected node: move by dt, dv
                      local new_t = pt.take_time + dt
                      local new_v = math.max(env_min_raw, math.min(env_max_raw, pt.value + dv))
                      reaper.InsertEnvelopePoint(env, new_t, new_v, pt.shape, pt.tension, false, true)
                    else
                      -- Non-selected: remove if inside the selected nodes' current span
                      local dominated = pt.take_time >= span_min - 0.0001
                                    and pt.take_time <= span_max + 0.0001
                      if not dominated then
                        reaper.InsertEnvelopePoint(env, pt.take_time, pt.value, pt.shape, pt.tension, false, true)
                      end
                    end
                  end
                  reaper.Envelope_SortPoints(env)

                  -- Re-find indices for selected nodes
                  local count = reaper.CountEnvelopePoints(env)
                  for _, pos in ipairs(state.env_multi_drag_start_positions) do
                    local target_time = pos.take_time + dt
                    local target_value = math.max(env_min_raw, math.min(env_max_raw, pos.value + dv))
                    for pi = 0, count - 1 do
                      local ret, pt_time, pt_value = reaper.GetEnvelopePoint(env, pi)
                      if ret and math.abs(pt_time - target_time) < 0.0001
                         and math.abs(pt_value - target_value) < 0.0001 then
                        pos.idx = pi
                        break
                      end
                    end
                  end

                  -- Update selection positions to match current node positions
                  state.env_selected_nodes = {}
                  for _, pos in ipairs(state.env_multi_drag_start_positions) do
                    local new_src = (pos.take_time + dt) + m_env_offset
                    local new_val = math.max(env_min_raw, math.min(env_max_raw, pos.value + dv))
                    table.insert(state.env_selected_nodes, {src_time = new_src, value = new_val})
                  end

                  reaper.UpdateArrange()
                end
              end
            end

            -- Rectangle selection finalization
            if reaper.ImGui_IsMouseReleased(ctx, 1) and state.env_rect_selecting then
              if state.env_rect_sel_activated then
                local rect_x1 = math.min(state.env_rect_sel_start_x, mouse_x)
                local rect_x2 = math.max(state.env_rect_sel_start_x, mouse_x)
                local rect_y1 = math.min(state.env_rect_sel_start_y, mouse_y)
                local rect_y2 = math.max(state.env_rect_sel_start_y, mouse_y)

                local sel_env_name = state.env_rect_sel_env_name or env_name
                local sel_env_offset = state.env_rect_sel_env_offset or env_offset
                local env = reaper.GetTakeEnvelopeByName(take, sel_env_name)
                if env then
                  state.env_selected_nodes = {}
                  state.env_selection_env_name = sel_env_name
                  state.env_selection_item = item
                  state.env_selection_env_offset = sel_env_offset
                  local count = reaper.CountEnvelopePoints(env)
                  for pi = 0, count - 1 do
                    local ret, pt_time, pt_value = reaper.GetEnvelopePoint(env, pi)
                    if ret then
                      local src_time = pt_time + sel_env_offset
                      local px = time_to_px(src_time)
                      local py = wave_y + waveform_height * (1 - (pt_value - view_min) / (view_max - view_min))
                      if px >= rect_x1 and px <= rect_x2 and py >= rect_y1 and py <= rect_y2 then
                        table.insert(state.env_selected_nodes, {src_time = src_time, value = pt_value})
                      end
                    end
                  end
                end
              end
              state.env_rect_selecting = false
              state.env_rect_sel_activated = false
            end
          end

          -- Slope handle drag: threshold + execution
          -- Normal: moves marker position, pins non-dragged handle (only dragged handle moves)
          -- Shift: pure slope change (both handles move in opposite directions)
          if state.slope_dragging and reaper.ImGui_IsMouseDown(ctx, 0) then
            if not state.slope_drag_activated then
              if math.abs(mouse_y - state.slope_drag_start_mouse_y) >= 4 then
                state.slope_drag_activated = true
              end
            end
            if state.slope_drag_activated then
              local mouse_delta_y = state.slope_drag_start_mouse_y - mouse_y  -- up = positive
              local band = waveform_height * 0.5
              -- Look up current REAPER indices by srcpos (indices shift when positions change)
              local slope_idx, partner_idx
              local sm_count = reaper.GetTakeNumStretchMarkers(take)
              for si = 0, sm_count - 1 do
                local _, _, srcpos = reaper.GetTakeStretchMarker(take, si)
                if math.abs(srcpos - state.slope_drag_start_srcpos) < 0.0001 then slope_idx = si end
                if math.abs(srcpos - state.slope_drag_partner_srcpos) < 0.0001 then partner_idx = si end
              end
              if slope_idx and partner_idx and shift_held then
                -- Shift+drag: pure slope change (both handles move in opposite directions)
                local slope_dir = (state.slope_drag_endpoint == 2) and 1 or -1
                local new_slope = state.slope_drag_start_slope + mouse_delta_y / band * slope_dir
                new_slope = math.max(-1, math.min(1, new_slope))
                reaper.SetTakeStretchMarkerSlope(take, slope_idx, new_slope)
                -- Re-set marker position to force REAPER to invalidate waveform cache
                local _, mpos, msrcpos = reaper.GetTakeStretchMarker(take, slope_idx)
                reaper.SetTakeStretchMarker(take, slope_idx, mpos, msrcpos)
              elseif slope_idx and partner_idx then
                -- Normal drag: map mouse Y to local rate, derive slope
                -- The dragged handle stays on its line; the partner marker moves
                -- Use frozen wave_y/waveform_height to avoid feedback oscillation
                local frozen_wy = state.slope_drag_start_wave_y
                local frozen_wh = state.slope_drag_start_waveform_height
                local scale = frozen_wh * 0.2
                local center = frozen_wy + frozen_wh / 2
                local target_y = state.slope_drag_start_handle_y - mouse_delta_y * 0.6
                -- Clamp target Y to waveform area (handle half-height = 6)
                target_y = math.max(frozen_wy + 6, math.min(frozen_wy + frozen_wh - 6, target_y))
                -- Convert Y to local rate: y = center - log(rate) * scale
                local target_lr = math.exp((center - target_y) / scale)
                target_lr = math.max(0.01, target_lr)
                local fixed_lr = state.slope_drag_anchor_local_rate
                -- Derive average rate and slope from the two local rates
                local avg_rate = (target_lr + fixed_lr) / 2
                local new_slope
                if state.slope_drag_endpoint == 1 then
                  new_slope = (fixed_lr - target_lr) / (fixed_lr + target_lr)
                else
                  new_slope = (target_lr - fixed_lr) / (fixed_lr + target_lr)
                end
                new_slope = math.max(-0.999, math.min(0.999, new_slope))
                -- Compute new M2 position: M1 stays fixed, M2 = M1 + src_d / avg_rate
                local src_d = math.abs(state.slope_drag_partner_srcpos - state.slope_drag_start_srcpos)
                local new_partner_pos = state.slope_drag_start_pos + src_d / avg_rate
                -- Clamp: M2 can't cross M1 (left boundary of this segment).
                -- Right-side markers are handled by cascade (preserves ordering).
                -- Only need to prevent M2 from going left of M1.
                new_partner_pos = math.max(state.slope_drag_start_pos + 0.001, new_partner_pos)
                -- Cascade FIRST: shift markers to the RIGHT of M2 so REAPER
                -- won't clamp M2 against its next neighbor
                local total_delta = new_partner_pos - state.slope_drag_partner_pos
                local sm_count2 = reaper.GetTakeNumStretchMarkers(take)
                if state.slope_drag_orig_markers and total_delta ~= 0 then
                  for _, orig in pairs(state.slope_drag_orig_markers) do
                    if math.abs(orig.srcpos - state.slope_drag_partner_srcpos) > 0.0001
                        and orig.pos > state.slope_drag_partner_pos then
                      for si = 0, sm_count2 - 1 do
                        local _, _, ssrcpos = reaper.GetTakeStretchMarker(take, si)
                        if math.abs(ssrcpos - orig.srcpos) < 0.0001 then
                          reaper.SetTakeStretchMarker(take, si, orig.pos + total_delta, orig.srcpos)
                          break
                        end
                      end
                    end
                  end
                end
                -- Re-lookup partner_idx after cascade (indices may have shifted)
                local partner_idx2 = partner_idx
                sm_count2 = reaper.GetTakeNumStretchMarkers(take)
                for si = 0, sm_count2 - 1 do
                  local _, _, sp = reaper.GetTakeStretchMarker(take, si)
                  if math.abs(sp - state.slope_drag_partner_srcpos) < 0.0001 then partner_idx2 = si; break end
                end
                -- Now set M2 position (neighbors already moved out of the way)
                reaper.SetTakeStretchMarker(take, partner_idx2, new_partner_pos, state.slope_drag_partner_srcpos)
                -- Set slope
                -- Re-lookup slope_idx too (cascade may have changed indices)
                local slope_idx2 = slope_idx
                for si = 0, sm_count2 - 1 do
                  local _, _, sp = reaper.GetTakeStretchMarker(take, si)
                  if math.abs(sp - state.slope_drag_start_srcpos) < 0.0001 then slope_idx2 = si; break end
                end
                reaper.SetTakeStretchMarkerSlope(take, slope_idx2, new_slope)

              end
              reaper.UpdateItemInProject(item)
              reaper.UpdateArrange()
              state.warp_markers = utils.get_stretch_markers(take)
            end
          end

          -- Set preview cursor on click in waveform (when no drag/interaction started)
          -- Skip when a popup is open (context menu click would steal cursor position)
          if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_waveform
              and not state._any_popup_open
              and not state.selecting_region
              and not state.dragging_start and not state.dragging_end
              and not state.dragging_fade_in and not state.dragging_fade_out
              and not state.dragging_fade_curve_in and not state.dragging_fade_curve_out
              and not state.dragging_env_node and not state.env_freehand_drawing
              and not near_start and not near_end
              and not near_fade_in and not near_fade_out
              and not alt_held
              and not (state.slope_hovered_segment > 0)
              and not state.slope_dragging
              and not (state.envelopes_visible and (state.env_node_hovered_idx >= 0 or state.envelope_hovered_segment >= 0 or reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl()))) then
            local click_t = px_to_time(mouse_x)
            if is_warped_view then
              click_t = snap_to_grid_if_enabled(click_t, 0, nil)
            else
              click_t = snap_to_grid_if_enabled(click_t)
            end
            state.preview_cursor_pos = click_t
            -- If preview is playing, restart from new position; otherwise just place cursor
            if state.preview_active then
              state.stop_preview()
              state.preview_start_requested = true
            end
          end

          -- Double-click: slide both markers so left marker lands at click position
          -- Note: selecting_region starts on first click, so allow double-click when selection
          -- hasn't been drag-activated yet (cancel the pending selection instead)
          if reaper.ImGui_IsMouseDoubleClicked(ctx, 0) and mouse_in_waveform
              and not state._any_popup_open
              and not (state.selecting_region and state.selection_drag_activated)
              and not state.dragging_start and not state.dragging_end
              and not state.dragging_fade_in and not state.dragging_fade_out
              and not state.dragging_fade_curve_in and not state.dragging_fade_curve_out
              and not state.dragging_env_node and not state.env_freehand_drawing
              and not near_start and not near_end
              and not near_fade_in and not near_fade_out
              and not alt_held
              and not (state.envelopes_visible and (state.env_node_hovered_idx >= 0 or state.envelope_hovered_segment >= 0 or reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl()))) then
            -- Cancel pending region selection from first click
            if state.selecting_region then
              state.selecting_region = false
            end

            if is_warped_view then
              -- Warp mode: click is in pos-time, shift stretch markers and D_STARTOFFS
              local click_t = px_to_time(mouse_x)
              local delta = click_t  -- slide amount in pos-time

              -- Clamp to source boundaries in pos-time
              local src_start_pos = utils.warp_src_to_pos(state.warp_map, 0, playrate)
              local src_end_pos = utils.warp_src_to_pos(state.warp_map, source_length, playrate)
              delta = math.max(src_start_pos, math.min(src_end_pos - item_length, delta))

              -- Compute new D_STARTOFFS from current warp map BEFORE shifting markers
              local new_srcpos = utils.warp_pos_to_src(state.warp_map, delta, playrate)
              new_srcpos = math.max(0, new_srcpos)
              local new_take_offset = new_srcpos - section_offset
              if source_length > 0 and state.is_loop_src then
                new_take_offset = new_take_offset % source_length
              end

              -- Shift stretch markers' pos by -delta (srcpos unchanged)
              local sm_count = reaper.GetTakeNumStretchMarkers(take)
              if sm_count > 0 then
                local markers = {}
                for si = 0, sm_count - 1 do
                  local _, pos, srcpos = reaper.GetTakeStretchMarker(take, si)
                  markers[#markers + 1] = {pos = pos - delta, srcpos = srcpos}
                end
                for si = sm_count - 1, 0, -1 do
                  reaper.DeleteTakeStretchMarkers(take, si)
                end
                for _, sm in ipairs(markers) do
                  reaper.SetTakeStretchMarker(take, -1, sm.pos, sm.srcpos)
                end
              end

              -- Shift envelope points so they stay audio-anchored
              if not state.envelope_lock then
                local offset_delta = new_take_offset - take_offset
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

              reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", new_take_offset)
              reaper.UpdateItemInProject(item)
              reaper.UpdateArrange()
              state.warp_markers = utils.get_stretch_markers(take)
              reaper.Undo_OnStateChangeEx("NVSD_ItemView: Move region to click position", -1, -1)

              -- Preview cursor at new left marker (pos=0 after slide)
              state.preview_cursor_pos = 0
            else
              -- Non-warp mode: click is in source-time
              local click_t = px_to_time(mouse_x)
              local region_len = source_item_length  -- length in source-time
              local new_start = click_t
              local new_end = new_start + region_len

              -- Clamp to source boundaries for looped items (same as alt+drag)
              if state.is_loop_src then
                if new_start < 0 then
                  new_start = 0
                  new_end = region_len
                end
                if new_end > source_length then
                  new_end = source_length
                  new_start = source_length - region_len
                end
              end

              local new_take_offset = new_start - section_offset

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

              -- Shift stretch markers so waveform follows
              local sm_count = reaper.GetTakeNumStretchMarkers(take)
              if sm_count > 0 then
                local srcpos_delta = new_start - start_offset
                local markers = {}
                for si = 0, sm_count - 1 do
                  local _, pos, srcpos = reaper.GetTakeStretchMarker(take, si)
                  markers[#markers + 1] = {pos = pos, srcpos = srcpos + srcpos_delta}
                end
                for si = sm_count - 1, 0, -1 do
                  reaper.DeleteTakeStretchMarkers(take, si)
                end
                for _, sm in ipairs(markers) do
                  reaper.SetTakeStretchMarker(take, -1, sm.pos, sm.srcpos)
                end
                state.warp_markers = utils.get_stretch_markers(take)
              end

              reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", new_take_offset)
              reaper.UpdateItemInProject(item)
              reaper.UpdateArrange()
              reaper.Undo_OnStateChangeEx("NVSD_ItemView: Move region to click position", -1, -1)

              -- Update preview cursor to new left marker
              state.preview_cursor_pos = new_start

              -- Reset view state so ext recalculates cleanly
              state.unwrapped_start_offset = nil
              state.prev_raw_start_offset = nil
              state.post_drag_ext_start = nil
              state.post_drag_ext_end = nil
            end
          end

          -- End dragging
          if reaper.ImGui_IsMouseReleased(ctx, 0) then
            -- Warp marker drag release
            if state.dragging_warp_marker then
              if state.warp_drag_activated then
                reaper.UpdateItemInProject(item)
                reaper.UpdateArrange()
                local undo_text = state.warp_drag_shift
                    and "NVSD_ItemView: Slide source under stretch marker"
                    or "NVSD_ItemView: Move stretch marker"
                reaper.Undo_OnStateChangeEx(undo_text, -1, -1)
              else
                -- Click without drag: move edit cursor to marker position for preview
                local marker_pos = state.warp_drag_start_pos
                local proj_time = item_position + marker_pos
                reaper.SetEditCurPos(proj_time, false, false)
                state.preview_cursor_pos = marker_pos
              end
              state.dragging_warp_marker = false
              state.warp_drag_activated = false
              state.warp_drag_shift = false
              state.warp_drag_idx = -1
              state.warp_markers = utils.get_stretch_markers(take)
            end
            -- Slope handle drag release
            if state.slope_dragging then
              if state.slope_drag_activated then
                reaper.UpdateArrange()
                reaper.Undo_OnStateChangeEx("NVSD_ItemView: Adjust stretch marker slope", -1, -1)
                -- Adjust pan_offset so view doesn't jump when ext changes
                if state.slope_drag_start_ext_start then
                  local old_center = (state.slope_drag_start_ext_start + state.slope_drag_start_ext_end) / 2
                  state.warp_markers = utils.get_stretch_markers(take)
                  state.warp_map = utils.build_warp_map(state.warp_markers)
                  local new_src_start = utils.warp_src_to_pos(state.warp_map, 0, playrate)
                  local new_src_end = utils.warp_src_to_pos(state.warp_map, source_length, playrate)
                  local new_ext_s = math.min(new_src_start, 0)
                  local new_ext_e = math.max(new_src_end, item_length)
                  local source_pos_len = source_length / playrate
                  if (new_ext_e - new_ext_s) < source_pos_len then
                    local c = (new_ext_s + new_ext_e) / 2
                    new_ext_s = math.min(new_ext_s, c - source_pos_len / 2)
                    new_ext_e = math.max(new_ext_e, c + source_pos_len / 2)
                  end
                  local new_center = (new_ext_s + new_ext_e) / 2
                  state.pan_offset = state.pan_offset + (old_center - new_center)
                end
              end
              state.slope_dragging = false
              state.slope_drag_activated = false
              state.slope_drag_segment = -1
              state.slope_drag_endpoint = 0
              state.slope_drag_partner_idx = -1
              state.slope_drag_partner_pos = 0
              state.slope_drag_partner_srcpos = 0
              state.slope_drag_slope_idx = -1
              state.slope_drag_start_slope = 0
              state.slope_drag_orig_markers = nil
              state.warp_markers = utils.get_stretch_markers(take)
            end
            if (state.dragging_start or state.dragging_end) and state.marker_drag_activated then
              -- Save drag ext for seamless transition to non-drag view
              -- In warp mode, ext is computed from warp map, no post_drag_ext needed
              if is_warped_view then
                state.post_drag_ext_start = nil
                state.post_drag_ext_end = nil
                -- Alt+drag: commit the slide by shifting all markers' pos (not srcpos).
                -- Same as moving start marker (pos shifts by -delta) then end marker back.
                if state.drag_alt_latched and state._alt_drag_pos_delta
                    and state.drag_start_warp_markers then
                  local pos_delta = state._alt_drag_pos_delta
                  if math.abs(pos_delta) > 0.000001 then
                    local sm_count = reaper.GetTakeNumStretchMarkers(take)
                    for si = sm_count - 1, 0, -1 do
                      reaper.DeleteTakeStretchMarkers(take, si)
                    end
                    for _, sm in ipairs(state.drag_start_warp_markers) do
                      reaper.SetTakeStretchMarker(take, -1, sm.pos - pos_delta, sm.srcpos)
                    end
                  end
                end
                state._alt_drag_pos_delta = nil
                -- Mark item dirty for undo
                if state.dragging_start or state.drag_alt_latched then
                  reaper.UpdateItemInProject(item)
                end
                -- Clean up saved warp state
                state.drag_start_warp_markers = nil
                state.drag_start_warp_map = nil
                state.drag_start_src_pos_start = nil
                state.drag_start_src_pos_end = nil
              else
                state.post_drag_ext_start = state.drag_current_start
                state.post_drag_ext_end = state.drag_current_end
                -- Mark item dirty if stretch markers were shifted
                if state.drag_start_stretch_markers then
                  reaper.UpdateItemInProject(item)
                end
                state.drag_start_stretch_markers = nil
              end
              state.post_drag_start_offset = start_offset  -- for undo detection

              -- Envelope points are now shifted in realtime during drag, no batch shift needed
              local old_item_length = state.drag_start_length * state.drag_start_playrate
              local new_item_length = source_item_length
              local old_item_end = state.drag_start_offset + old_item_length

              local old_left = math.min(0, state.drag_start_offset)
              local old_right = math.max(source_length, old_item_end)
              local old_range_center = (old_left + old_right) / 2
              local old_base = old_right - old_left

              -- Use drag_current values (unwrapped coordinates) instead of REAPER's wrapped start_offset
              local new_left = math.min(0, state.drag_current_start)
              local new_right = math.max(source_length, state.drag_current_end)
              local new_range_center = (new_left + new_right) / 2
              local new_base = new_right - new_left

              local old_view_length = old_base / state.zoom_level
              local new_view_length = new_base / state.zoom_level

              -- Skip pan adjustment in warped mode (ext is computed from warp mapping, not drag state)
              if not is_warped_view then
                state.pan_offset = state.pan_offset + (old_range_center - new_range_center) + (new_view_length - old_view_length) / 2
              end
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
              if state.preview_active then
                state.stop_preview()
                state.preview_start_requested = true
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
            state.drag_virtual_x = 0
            state.drag_last_mouse_x = 0
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
            -- Multi-node drag release
            if state.env_multi_dragging then
              state.env_multi_dragging = false
              state.env_multi_drag_activated = false
              state.env_multi_drag_start_positions = {}
              state.env_multi_drag_all_points = {}
            end
            state.env_segment_dragging = false
            state.env_segment_activated = false
            state.env_segment_idx1 = -1
            state.env_segment_idx2 = -1
            state.env_rect_selecting = false
            state.env_rect_sel_activated = false
            state.slope_dragging = false
            state.slope_drag_activated = false
          end

          -- Mouse button quick marker/fade positioning (configurable shortcuts)
          if mouse_in_waveform or mouse_in_marker_area then
            local set_start = settings.check_shortcut(ctx, "set_start_marker")
            local set_end = settings.check_shortcut(ctx, "set_end_marker")
            -- Ctrl+click / Ctrl+Shift+click: move start/end marker (when envelopes not visible)
            if not state.envelopes_visible and reaper.ImGui_IsMouseClicked(ctx, 0)
                and not state.is_panning and not we_are_dragging then
              if ctrl_held and not alt_held and not shift_held then
                set_start = true
              elseif ctrl_held and shift_held and not alt_held then
                set_end = true
              end
            end
            local set_fi = settings.check_shortcut(ctx, "set_fade_in")
            local set_fo = settings.check_shortcut(ctx, "set_fade_out")

            if set_fi or set_fo then
              local click_time = px_to_time(mouse_x)
              reaper.Undo_BeginBlock()

              if set_fi then
                -- Fade-in ends at click position
                local new_fi = (click_time - view_offset) / playrate
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

              elseif set_fo then
                -- Fade-out starts at click position
                local current_end = view_offset + source_item_length
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

            elseif set_start or set_end then
              local click_time = px_to_time(mouse_x)

              reaper.Undo_BeginBlock()

              if is_warped_view then
                -- Warp mode: click_time is in pos-time
                if set_start then
                  local delta = click_time  -- pos-time offset from current start
                  delta = math.min(delta, item_length - 0.01)
                  -- Shift stretch markers by -delta, remove those before pos=0
                  local sm_count = reaper.GetTakeNumStretchMarkers(take)
                  -- Save markers first (modifying in-place causes index issues)
                  local saved = {}
                  for si = 0, sm_count - 1 do
                    local _, pos, srcpos = reaper.GetTakeStretchMarker(take, si)
                    saved[#saved + 1] = { pos = pos, srcpos = srcpos }
                  end
                  -- Clear all
                  for si = sm_count - 1, 0, -1 do
                    reaper.DeleteTakeStretchMarkers(take, si)
                  end
                  -- Re-add shifted (keep all markers, even outside item edges)
                  for _, sm in ipairs(saved) do
                    reaper.SetTakeStretchMarker(take, -1, sm.pos - delta, sm.srcpos)
                  end
                  -- Compute new D_STARTOFFS
                  local new_srcpos = utils.warp_pos_to_src(state.warp_map, delta, playrate)
                  new_srcpos = math.max(0, new_srcpos)
                  local new_take_offset = new_srcpos - section_offset
                  if source_length > 0 and state.is_loop_src then new_take_offset = new_take_offset % source_length end
                  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", new_take_offset)
                  -- Adjust D_POSITION so the right edge stays fixed
                  reaper.SetMediaItemInfo_Value(item, "D_POSITION", item_position + delta)
                  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", math.max(0.01, item_length - delta))
                  reaper.UpdateItemInProject(item)
                  reaper.UpdateArrange()
                  reaper.Undo_EndBlock("NVSD_ItemView: Set start marker", -1)

                elseif set_end then
                  -- In warp mode, click_time is pos-time = item-time, set D_LENGTH directly
                  local new_end = math.max(0.01, click_time)
                  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_end)
                  reaper.UpdateArrange()
                  reaper.Undo_EndBlock("NVSD_ItemView: Set end marker", -1)
                end

              else
                -- Non-warp mode (original logic)
                -- Use unwrapped offset when available (px_to_time returns unwrapped/extended coords)
                local effective_start = state.unwrapped_start_offset ~= nil and state.unwrapped_start_offset or view_offset
                local current_end = effective_start + source_item_length

                if set_start then
                  local new_start = click_time
                  new_start = math.min(new_start, current_end - 0.01)
                  local new_source_length = current_end - new_start
                  local new_item_length = new_source_length / playrate
                  local new_take_offset = new_start - section_offset
                  -- Wrap for REAPER only when loop is on (non-looped items allow negative D_STARTOFFS)
                  if source_length > 0 and state.is_loop_src then
                    new_take_offset = new_take_offset % source_length
                  end

                  -- Fade adjustment: preserve fade-in, shrink fade-out first
                  local fi, fo = fade_in_len, fade_out_len
                  if fi + fo > new_item_length then
                    fo = math.max(0, new_item_length - fi)
                    if fo == 0 then fi = math.min(fi, new_item_length) end
                  end

                  -- Keep item left edge fixed, only adjust where sound starts (matches drag behavior)
                  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", new_take_offset)
                  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_item_length)
                  reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", fi)
                  reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", fo)
                  -- Shift envelope points so they stay audio-anchored
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
                  reaper.Undo_EndBlock("NVSD_ItemView: Set start marker", -1)

                elseif set_end then
                  local new_end = click_time
                  new_end = math.max(new_end, effective_start + 0.01)
                  local new_source_length = new_end - effective_start
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

                -- Reset unwrapped offset so next frame reinitializes from new item dimensions
                state.unwrapped_start_offset = nil
                state.prev_raw_start_offset = nil
                state.post_drag_ext_start = nil
                state.post_drag_ext_end = nil
              end
            end

          local snap_threshold_time = (config.SNAP_THRESHOLD_PX / waveform_width) * view_length

          -- Marker drag threshold: don't move markers until mouse exceeds threshold
          if (state.dragging_start or state.dragging_end) and not state.marker_drag_activated
              and reaper_is_active and reaper.ImGui_IsMouseDown(ctx, 0) then
            if math.abs(mouse_x - state.drag_start_mouse_x) >= state.marker_drag_threshold then
              state.marker_drag_activated = true
              state.drag_virtual_x = mouse_x
              state.drag_last_mouse_x = mouse_x
            end
          end

          -- Ctrl fine-tune: virtual position advances at 25% speed, cursor warps to match
          local drag_mouse_x = mouse_x
          if (state.dragging_start or state.dragging_end) and state.marker_drag_activated
              and reaper_is_active and reaper.ImGui_IsMouseDown(ctx, 0) then
            local raw_delta = mouse_x - state.drag_last_mouse_x
            local scale = ctrl_held and 0.25 or 1.0
            state.drag_virtual_x = state.drag_virtual_x + raw_delta * scale
            drag_mouse_x = state.drag_virtual_x

            if state.has_js_extension then
              local warp_offset = mouse_x - state.drag_virtual_x
              if math.abs(warp_offset) > 0.5 then
                local screen_x, screen_y = reaper.GetMousePosition()
                reaper.JS_Mouse_SetPosition(math.floor(screen_x - warp_offset + 0.5), screen_y)
              end
              state.drag_last_mouse_x = state.drag_virtual_x
            else
              state.drag_last_mouse_x = mouse_x
            end
          end

          -- Safety: abort drag if take was deleted or changed externally (undo, take switch)
          if (state.dragging_start or state.dragging_end) and state.marker_drag_activated and not take then
            state.reset_all_drags()
            state.marker_drag_activated = false
            state.drag_alt_latched = false
            if state.undo_block_open then
              reaper.Undo_EndBlock("NVSD_ItemView: Error recovery", -1)
              state.undo_block_open = nil
            end
          end

          -- Alt+drag: slide both markers (alt latched at drag start, releasing alt mid-drag keeps sliding)
          if (state.dragging_start or state.dragging_end) and state.marker_drag_activated and state.drag_alt_latched and reaper_is_active and reaper.ImGui_IsMouseDown(ctx, 0) then
            local mouse_delta_px = drag_mouse_x - state.drag_start_mouse_x
            local mouse_delta_time = (mouse_delta_px / waveform_width) * state.drag_start_view_length

            if is_warped_view and state.drag_start_warp_markers then
              -- In warp mode: slide both markers through the warped waveform.
              -- Equivalent to moving start then end by the same delta:
              --   start drag shifts markers' pos by -delta, changes D_STARTOFFS, D_LENGTH unchanged
              -- Warp_map frozen in ItemView (waveform stays still, markers move via drag_current).
              -- Markers shifted in REAPER each frame for real-time arrange view updates.
              -- Clamp to source boundaries (brackets): left marker >= left bracket, right marker <= right bracket
              local clamped_delta = mouse_delta_time
              if state.drag_start_src_pos_start then
                local min_delta = state.drag_start_src_pos_start  -- left bracket (pos-time, typically <= 0)
                local max_delta = state.drag_start_src_pos_end - state.drag_start_length  -- right bracket minus item length
                clamped_delta = math.max(min_delta, math.min(max_delta, clamped_delta))
              end
              state.drag_current_start = clamped_delta
              state.drag_current_end = state.drag_start_length + clamped_delta
              state._alt_drag_pos_delta = clamped_delta
              -- Shift markers' pos in REAPER for real-time arrange view
              local sm_count = reaper.GetTakeNumStretchMarkers(take)
              for si = sm_count - 1, 0, -1 do
                reaper.DeleteTakeStretchMarkers(take, si)
              end
              for _, sm in ipairs(state.drag_start_warp_markers) do
                reaper.SetTakeStretchMarker(take, -1, sm.pos - clamped_delta, sm.srcpos)
              end
              -- Update D_STARTOFFS
              local orig_map = state.drag_start_warp_map or state.warp_map
              local new_srcpos = utils.warp_pos_to_src(orig_map, clamped_delta, state.drag_start_playrate)
              new_srcpos = math.max(0, new_srcpos)
              local new_take_offset = new_srcpos - section_offset
              if source_length > 0 and state.is_loop_src then new_take_offset = new_take_offset % source_length end
              reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", new_take_offset)
              reaper.UpdateArrange()
            else
              local original_source_length = state.drag_start_length * state.drag_start_playrate

              local raw_start = state.drag_start_offset + mouse_delta_time
              local raw_end = raw_start + original_source_length

              local new_start

              if state.is_loop_src then
                -- Looped: snap to source boundaries + grid, clamp within source
                if state.dragging_start then
                  new_start = snap_best(raw_start, source_length, snap_threshold_time, state.drag_start_offset, state.drag_start_item_position)
                else
                  local snapped_end = snap_best(raw_end, source_length, snap_threshold_time, state.drag_start_offset, state.drag_start_item_position)
                  new_start = snapped_end - original_source_length
                end
              else
                -- Non-looped: grid snap only, no source boundary snap or clamping
                if state.dragging_start then
                  new_start = snap_to_grid_if_enabled(raw_start, state.drag_start_offset, state.drag_start_item_position)
                else
                  local snapped_end = snap_to_grid_if_enabled(raw_end, state.drag_start_offset, state.drag_start_item_position)
                  new_start = snapped_end - original_source_length
                end
              end

              local new_end = new_start + original_source_length

              -- Clamp to source boundaries (keep item length constant) -- only for looped items
              if state.is_loop_src then
                if new_start < 0 then
                  new_start = 0
                  new_end = original_source_length
                end
                if new_end > source_length then
                  new_end = source_length
                  new_start = source_length - original_source_length
                end
              end

              local new_take_offset = new_start - section_offset

              state.drag_current_start = new_start
              state.drag_current_end = new_end

              reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", new_take_offset)
              -- Shift stretch markers so the waveform in arrange view follows the slide
              if state.drag_start_stretch_markers then
                local srcpos_delta = new_start - state.drag_start_offset
                local sm_count = reaper.GetTakeNumStretchMarkers(take)
                for si = sm_count - 1, 0, -1 do
                  reaper.DeleteTakeStretchMarkers(take, si)
                end
                for _, sm in ipairs(state.drag_start_stretch_markers) do
                  reaper.SetTakeStretchMarker(take, -1, sm.pos, sm.srcpos + srcpos_delta)
                end
              end
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
            end

          -- Dragging start marker
          elseif state.dragging_start and state.marker_drag_activated and not state.dragging_zone
              and reaper_is_active and reaper.ImGui_IsMouseDown(ctx, 0) then
            -- Use frozen view coordinates for stable drag sensitivity (prevents feedback loop
            -- where the view re-scales each frame and amplifies small mouse movements)
            local frozen_vl = state.drag_start_view_length
            -- Auto-scroll when mouse exceeds waveform edges during drag
            if mouse_x < wave_x then
              local overflow_px = wave_x - mouse_x
              local speed = math.min(overflow_px / 40, 4)
              state.drag_start_view_start = state.drag_start_view_start - frozen_vl * 0.015 * speed
            elseif mouse_x > wave_x + waveform_width then
              local overflow_px = mouse_x - (wave_x + waveform_width)
              local speed = math.min(overflow_px / 40, 4)
              state.drag_start_view_start = state.drag_start_view_start + frozen_vl * 0.015 * speed
            end
            local frozen_vs = state.drag_start_view_start
            local new_start
            if drag_mouse_x < wave_x then
              new_start = frozen_vs
            elseif drag_mouse_x > wave_x + waveform_width then
              new_start = frozen_vs + frozen_vl
            else
              new_start = frozen_vs + ((drag_mouse_x - wave_x) / waveform_width) * frozen_vl
            end

            if is_warped_view and state.drag_start_warp_markers then
              -- In warp mode: shift stretch markers in real time.
              -- Allow extending left past source start (like non-warp mode).
              new_start = math.min(new_start, state.drag_start_length - 0.01)
              -- Snap to grid in pos-time
              new_start = snap_to_grid_if_enabled(new_start, 0, state.drag_start_item_position, true)
              new_start = math.min(new_start, state.drag_start_length - 0.01)
              local delta = new_start
              -- Clear all existing stretch markers
              local sm_count = reaper.GetTakeNumStretchMarkers(take)
              for si = sm_count - 1, 0, -1 do
                reaper.DeleteTakeStretchMarkers(take, si)
              end
              -- Re-add shifted markers from saved originals (keep all, even outside item edges)
              for _, sm in ipairs(state.drag_start_warp_markers) do
                reaper.SetTakeStretchMarker(take, -1, sm.pos - delta, sm.srcpos)
              end
              -- Compute new D_STARTOFFS from original warp map
              local new_srcpos = utils.warp_pos_to_src(state.drag_start_warp_map, delta, state.drag_start_playrate)
              new_srcpos = math.max(0, new_srcpos)
              local new_take_offset = new_srcpos - section_offset
              if source_length > 0 and state.is_loop_src then new_take_offset = new_take_offset % source_length end
              reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", new_take_offset)
              local new_length = math.max(0.01, state.drag_start_length - delta)
              -- Adjust D_POSITION so the right edge stays fixed (item extends/contracts from left)
              reaper.SetMediaItemInfo_Value(item, "D_POSITION", state.drag_start_item_position + delta)
              reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_length)
              -- Update drag_current in the ORIGINAL pos-time coordinate system
              -- (warp_map is frozen, so coordinates must be relative to original)
              state.drag_current_start = new_start  -- negative when extending left
              state.drag_current_end = state.drag_start_length  -- original item length (unchanged)
              reaper.UpdateArrange()
            else
              local original_source_end = state.drag_start_offset + (state.drag_start_length * state.drag_start_playrate)
              new_start = snap_best(new_start, source_length, snap_threshold_time, state.drag_start_offset, state.drag_start_item_position)
              new_start = math.min(new_start, original_source_end - 0.01)
              local new_source_length = original_source_end - new_start
              local new_item_length = new_source_length / state.drag_start_playrate
              local new_take_offset = new_start - section_offset
              -- Wrap for REAPER only when loop is on (non-looped items allow negative D_STARTOFFS)
              if source_length > 0 and state.is_loop_src then
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

              -- Keep item left edge fixed, only adjust where sound starts within the item
              local source_delta = new_start - state.drag_start_offset
              local pos_delta = source_delta / state.drag_start_playrate
              reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", new_take_offset)
              reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_item_length)
              reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", fi)
              reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", fo)
              -- Shift stretch markers to match the new start offset
              if state.drag_start_stretch_markers then
                local sm_count = reaper.GetTakeNumStretchMarkers(take)
                for si = sm_count - 1, 0, -1 do
                  reaper.DeleteTakeStretchMarkers(take, si)
                end
                for _, sm in ipairs(state.drag_start_stretch_markers) do
                  local new_sm_pos = sm.pos - pos_delta
                  if new_sm_pos >= 0 and new_sm_pos <= new_item_length then
                    reaper.SetTakeStretchMarker(take, -1, new_sm_pos, sm.srcpos)
                  end
                end
              end
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
            end

          -- Dragging end marker
          elseif state.dragging_end and state.marker_drag_activated and reaper_is_active and reaper.ImGui_IsMouseDown(ctx, 0) then
            -- Use frozen view coordinates for stable drag sensitivity
            local frozen_vl = state.drag_start_view_length
            -- Auto-scroll when mouse exceeds waveform edges during drag
            if mouse_x < wave_x then
              local overflow_px = wave_x - mouse_x
              local speed = math.min(overflow_px / 40, 4)
              state.drag_start_view_start = state.drag_start_view_start - frozen_vl * 0.015 * speed
            elseif mouse_x > wave_x + waveform_width then
              local overflow_px = mouse_x - (wave_x + waveform_width)
              local speed = math.min(overflow_px / 40, 4)
              state.drag_start_view_start = state.drag_start_view_start + frozen_vl * 0.015 * speed
            end
            local frozen_vs = state.drag_start_view_start
            local new_end
            if drag_mouse_x < wave_x then
              new_end = frozen_vs
            elseif drag_mouse_x > wave_x + waveform_width then
              new_end = frozen_vs + frozen_vl
            else
              new_end = frozen_vs + ((drag_mouse_x - wave_x) / waveform_width) * frozen_vl
            end

            if is_warped_view then
              -- In warp mode: new_end is already in pos-time, set D_LENGTH directly
              new_end = math.max(0.01, new_end)
              -- Snap to grid in pos-time
              new_end = math.max(0.01, snap_to_grid_if_enabled(new_end, 0, item_position, true))
              state.drag_current_start = 0  -- start stays at pos=0
              state.drag_current_end = new_end
              reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_end)
              reaper.UpdateArrange()
            else
              new_end = snap_best(new_end, source_length, snap_threshold_time, state.drag_start_offset, state.drag_start_item_position)
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
            reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_None())
            -- Accumulate delta from screen coords (works on all platforms)
            if state.fade_curve_lock_x then
              local cur_x, cur_y = reaper.GetMousePosition()
              state.fade_curve_last_y = state.fade_curve_last_y or cur_y
              local delta = state.fade_curve_last_y - cur_y
              if delta ~= 0 then
                state.fade_curve_cumulative_y = state.fade_curve_cumulative_y + delta
                if not state.fade_curve_was_dragged and math.abs(state.fade_curve_cumulative_y) >= 3 then
                  state.fade_curve_was_dragged = true
                end
              end
              -- With JS extension: lock cursor for infinite range
              if state.has_js_extension then
                state.fade_curve_last_y = state.fade_curve_lock_y
                reaper.JS_Mouse_SetPosition(state.fade_curve_lock_x, state.fade_curve_lock_y)
              else
                state.fade_curve_last_y = cur_y
              end
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

          -- Alt-hover zone highlight (free zone or marker = both slide both markers)
          -- Skip when Ctrl+Alt held (that's pan mode, not slide mode)
          if alt_held and not ctrl_held and not we_are_dragging
              and (mouse_in_free_zone or (mouse_in_marker_area and (near_start or near_end))) then
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
          -- Clip to waveform area so fades don't bleed when zoomed in
          if fade_in_len > 0 or fade_out_len > 0 then
            reaper.ImGui_DrawList_PushClipRect(draw_list, wave_x, wave_y, wave_x + waveform_width, wave_y + waveform_height, true)
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
            reaper.ImGui_DrawList_PopClipRect(draw_list)
          end

          -- Slope curves and handles at warp markers (warp mode only)
          if state.warp_mode and #state.warp_markers > 1 then
            -- Clip to waveform area so curves/handles don't bleed outside
            reaper.ImGui_DrawList_PushClipRect(draw_list, wave_x, wave_y, wave_x + waveform_width, wave_y + waveform_height, true)
            for i = 1, #state.warp_markers - 1 do
              local sm1 = state.warp_markers[i]
              local sm2 = state.warp_markers[i + 1]
              local px1 = is_warped_view and time_to_px(sm1.pos) or time_to_px(sm1.srcpos)
              local px2 = is_warped_view and time_to_px(sm2.pos) or time_to_px(sm2.srcpos)
              local slope = sm1.slope or 0
              local hover_state = 0
              if state.slope_dragging and state.slope_drag_segment == i then
                hover_state = 2
              elseif state.slope_hovered_segment == i then
                hover_state = 1
              end
              local rate = (sm2.pos ~= sm1.pos) and (sm2.srcpos - sm1.srcpos) / (sm2.pos - sm1.pos) or 1
              local seg_px = px2 - px1
              -- Draw slope curve between markers
              drawing.draw_slope_curve(draw_list, px1, px2, wave_y, waveform_height, slope, hover_state, rate)
              -- Draw triangle handles and rate labels (skip if segment too narrow)
              if seg_px >= 8 then
                local y_left, y_right = drawing.slope_handle_positions(wave_y, waveform_height, slope, rate)
                local rate_left = rate * (1 - slope)
                local rate_right = rate * (1 + slope)
                drawing.draw_slope_handle(draw_list, px1, y_left, 1, rate_left, hover_state)
                drawing.draw_slope_handle(draw_list, px2, y_right, -1, rate_right, hover_state)
                -- Rate labels (only if segment wide enough to avoid overlap)
                if seg_px > 80 then
                  local lbl_col = 0xFFFFFF70
                  local lbl_cy = wave_y + waveform_height / 2 - 6
                  local lbl_l = string.format("%.2fx", rate_left)
                  reaper.ImGui_DrawList_AddText(draw_list, px1 + 10, lbl_cy, lbl_col, lbl_l)
                  local lbl_r = string.format("%.2fx", rate_right)
                  local rw = reaper.ImGui_CalcTextSize(ctx, lbl_r)
                  reaper.ImGui_DrawList_AddText(draw_list, px2 - 10 - rw, lbl_cy, lbl_col, lbl_r)
                end
              end
            end
            reaper.ImGui_DrawList_PopClipRect(draw_list)
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

          -- Draw ghost markers (other items' regions, behind everything else)
          if state.show_ghost_markers and state.ghost_marker_regions and #state.ghost_marker_regions > 0 then
            local ghost_display = {}
            for _, r in ipairs(state.ghost_marker_regions) do
              if is_warped_view then
                local ds = utils.warp_src_to_pos(state.warp_map, r.src_start - section_offset, playrate)
                local de = utils.warp_src_to_pos(state.warp_map, r.src_end - section_offset, playrate)
                ghost_display[#ghost_display + 1] = {start_t = ds, end_t = de}
              else
                ghost_display[#ghost_display + 1] = {start_t = r.src_start, end_t = r.src_end}
              end
            end
            drawing.draw_ghost_markers(draw_list, ghost_display, wave_x, wave_y, waveform_width, waveform_height, view_start, view_length, config)
          end

          -- Draw WAV cue markers (behind start/end markers)
          if state.show_cue_markers and state.cached_cue_markers and #state.cached_cue_markers > 0 then
            drawing.draw_cue_markers(ctx, draw_list, state.cached_cue_markers, wave_x, wave_y, waveform_width, waveform_height, view_start, view_length, source_length, is_extended_view, config, mouse_x, mouse_y, state, item)
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
            local playhead_display
            if is_warped_view then
              playhead_display = play_pos - item_position  -- item-time (pos-space)
            else
              playhead_display = utils.project_to_source_time(play_pos, item_position, view_offset, playrate)
            end
            local playhead_px = time_to_px(playhead_display)
            if playhead_px >= wave_x and playhead_px <= wave_x + waveform_width then
              drawing.draw_playhead(draw_list, playhead_px, wave_y, waveform_height, config)
            end
          end

          -- Preview from start marker (Enter): jump cursor to left marker and start/restart preview
          if state.preview_from_start_requested then
            state.preview_from_start_requested = false
            state.preview_cursor_pos = ext_start
            state.stop_preview()
            state.preview_start_requested = true
          end

          -- Audio preview: handle Ctrl+Space toggle
          if state.preview_start_requested then
            state.preview_start_requested = false
            if state.preview_active then
              -- Stop preview
              if state.preview_via_transport then
                -- Stop REAPER transport (action 1016 = Transport: Stop)
                reaper.Main_OnCommand(1016, 0)
                state.preview_via_transport = false
              elseif state.preview_handle then
                reaper.CF_Preview_Stop(state.preview_handle)
                state.preview_handle = nil
              end
              state.preview_active = false
            else
              -- Start preview from cursor position (or item start if no cursor set)
              local pos = state.preview_cursor_pos or view_offset

              if is_warped_view then
                -- Warp mode: use REAPER transport so stretch markers are audible.
                -- Move edit cursor to the marker's project-time position and play.
                local proj_time = item_position + (pos or 0)
                reaper.SetEditCurPos(proj_time, false, false)
                -- Start transport (action 1007 = Transport: Play)
                reaper.Main_OnCommand(1007, 0)
                state.preview_active = true
                state.preview_item = item
                state.preview_via_transport = true
                state.preview_virtual_start = pos
                state.preview_start_realtime = reaper.time_precise()
              else
                -- Non-warp: use CF_Preview for isolated source playback
                -- In warped view, cursor pos is in item-time; convert to source-time
                if state.warp_map then
                  pos = utils.warp_pos_to_src(state.warp_map, pos, playrate)
                end
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
                  -- Match take's playrate and pitch so preview sounds like actual playback
                  if playrate ~= 1 then
                    reaper.CF_Preview_SetValue(handle, "D_PLAYRATE", playrate)
                  end
                  local take_pitch = reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH")
                  if take_pitch ~= 0 then
                    reaper.CF_Preview_SetValue(handle, "D_PITCH", take_pitch)
                  end
                  -- Loop when playing in a looped/extended item so preview crosses source boundaries
                  local needs_loop = is_extended_view
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
          end

          -- Audio preview: poll position and auto-stop at end
          if state.preview_active and state.preview_via_transport then
            -- Transport-based preview (warp mode): track REAPER's play state
            local play_state = reaper.GetPlayState()
            if play_state == 0 then
              -- Transport stopped externally (user pressed stop, reached end, etc.)
              state.preview_active = false
              state.preview_via_transport = false
            elseif item ~= state.preview_item then
              state.stop_preview()
            end
          elseif state.preview_active and state.preview_handle then
            -- CF_Preview-based preview (non-warp mode)
            if item ~= state.preview_item then
              state.stop_preview()
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
                local stop_pos = is_extended_view and ext_end or source_length
                if virtual_pos >= stop_pos then
                  state.stop_preview()
                end
              else
                -- Handle became invalid (preview ended)
                pcall(reaper.CF_Preview_Stop, state.preview_handle)
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

    -- Toolbar right-click context menu + edit popups (must be at top-level, not inside item block)
    drawing.draw_toolbar_popups(ctx, state, settings, config)

    reaper.ImGui_End(ctx)
  end

  reaper.ImGui_PopStyleVar(ctx)

  end) -- pcall

  -- Handle reload outside pcall (dofile replaces the running script)
  if needs_reload then
    -- Stop audio preview before reload
    state.stop_preview()
    -- Clear running state so the reloaded script doesn't think another instance is active
    reaper.DeleteExtState("NVSD_ItemView", "running", false)
    reaper.DeleteExtState("NVSD_ItemView", "heartbeat", false)
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
    drawing.clear_icon_cache()
    settings_ui.clear_icon_cache()
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
    state.env_rect_selecting = false
    state.env_rect_sel_activated = false
    state.env_multi_dragging = false
    state.env_multi_drag_activated = false
    state.env_multi_drag_start_positions = {}
    state.env_multi_drag_all_points = {}
    state.env_selected_nodes = {}
    -- Restore stretch markers if a warp-mode drag was interrupted mid-frame
    if state.drag_start_warp_markers and state.remembered_item then
      local ri = state.remembered_item
      if reaper.ValidatePtr(ri, "MediaItem*") then
        local rt = reaper.GetActiveTake(ri)
        if rt then
          local sm_count = reaper.GetTakeNumStretchMarkers(rt)
          for si = sm_count - 1, 0, -1 do
            reaper.DeleteTakeStretchMarkers(rt, si)
          end
          for _, sm in ipairs(state.drag_start_warp_markers) do
            reaper.SetTakeStretchMarker(rt, -1, sm.pos, sm.srcpos)
          end
        end
      end
      state.drag_start_warp_markers = nil
    end
    if state.undo_block_open then
      reaper.Undo_EndBlock("NVSD_ItemView: Error recovery", -1)
    end
    state.undo_block_open = nil
    state.sticky_item = nil
    state.sticky_item_valid = false
    -- Stop audio preview on error
    state.stop_preview()
  end

  if open then
    reaper.defer(loop)
  else
    -- Stop audio preview on script close
    state.stop_preview()
  end
end

reaper.defer(loop)
