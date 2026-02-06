-- NVSD_ItemView - State Module
-- All state variables and drag control system

local state = {}

-- Per-view peak loading: always loads exactly screen-width peaks for the visible range.
-- No cache needed — PCM_Source_GetPeaks reads pre-indexed .reapeaks files in <1ms.
state.view_peaks = nil        -- Current per-view peaks from get_peaks_for_range
state.view_num_channels = 1   -- Channels in current peaks
state.view_source = nil       -- Source pointer for which peaks are loaded
state.view_start = -1         -- View start time of loaded peaks
state.view_length = -1        -- View length of loaded peaks
state.view_reversed = false   -- Whether peaks were loaded for reversed display
state.view_num_samples = 0    -- Number of peaks loaded (≈ screen width)
state.pending_cache_invalidation = 0  -- Frames to wait before forcing peak reload (for reverse)

-- Marker dragging
state.dragging_start = false
state.dragging_end = false
state.undo_block_open = nil
state.drag_start_offset = 0
state.drag_start_length = 0
state.drag_start_mouse_x = 0
state.drag_start_view_length = 0
state.drag_start_playrate = 1
state.drag_current_start = 0
state.drag_current_end = 0
state.drag_start_view_start = 0

-- Panning state
state.is_panning = false
state.pan_start_mouse_x = 0
state.pan_offset = 0
state.pan_start_offset = 0
state.last_panned_item = nil

-- Zoom state
state.zoom_level = 1.0
state.is_ruler_dragging = false
state.ruler_drag_start_y = 0
state.ruler_drag_start_zoom = 1.0
state.ruler_drag_screen_x = 0
state.ruler_drag_screen_y = 0
state.ruler_drag_cumulative_y = 0
state.ruler_drag_start_pan = 0
state.ruler_drag_cursor_x = 0  -- Tracks visible cursor X during drag
state.ruler_drag_window_x = 0  -- Window-space X for zoom centering
state.last_zoomed_item = nil

-- Mouse tracking
state.was_mouse_down = false

-- Sticky item state
state.sticky_item = nil
state.last_selected_item = nil
state.sticky_validation_counter = 0
state.sticky_item_valid = false
state.last_item_count = -1  -- Track item count for sticky validation optimization

-- Cursor lock state
state.drag_lock_screen_x = 0
state.drag_lock_screen_y = 0
state.drag_cumulative_delta_y = 0
state.drag_last_screen_y = 0  -- Track last frame's Y position for delta calculation
state.has_js_extension = reaper.JS_Mouse_SetPosition ~= nil

-- Warp mode state
state.warp_mode = false
state.warp_dropdown_open = false

-- Unified drag control state
state.drag_controls = {
  gain = { active = false, start_y = 0, start_value = 0, shift_held = false },
  pitch = { active = false, start_y = 0, start_value = 0, shift_held = false },
  semitones = { active = false, start_y = 0, start_value = 0 },
  cents = { active = false, start_y = 0, start_value = 0 },
}

-- Start a drag operation
function state.start_drag(name, mouse_y, value, track_shift)
  local ctrl = state.drag_controls[name]
  ctrl.active = true
  ctrl.start_y = mouse_y
  ctrl.start_value = value
  if track_shift then
    ctrl.shift_held = false
  end
  if state.has_js_extension then
    local screen_x, screen_y = reaper.GetMousePosition()
    state.drag_lock_screen_x, state.drag_lock_screen_y = screen_x, screen_y
    state.drag_last_screen_y = screen_y
    state.drag_cumulative_delta_y = 0
  end
  if not state.undo_block_open then
    state.undo_block_open = name
  end
end

-- End a drag operation
function state.end_drag(name)
  state.drag_controls[name].active = false
end

-- Check if a drag is active
function state.is_dragging(name)
  return state.drag_controls[name].active
end

-- Check if any control drag is active
function state.is_any_control_dragging()
  return state.drag_controls.gain.active or state.drag_controls.pitch.active
      or state.drag_controls.semitones.active or state.drag_controls.cents.active
end

-- Get drag delta (in pixels), handling shift modifier for fine control
function state.get_drag_delta(ctx, name, mouse_y, current_value, fine_sensitivity)
  local ctrl = state.drag_controls[name]
  if not ctrl.active then return 0 end

  local sensitivity = 1.0
  if fine_sensitivity then
    local shift_now = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift())
    if shift_now ~= ctrl.shift_held then
      ctrl.start_y = mouse_y
      ctrl.start_value = current_value
      ctrl.shift_held = shift_now
      if state.has_js_extension then state.drag_cumulative_delta_y = 0 end
    end
    sensitivity = ctrl.shift_held and fine_sensitivity or 1.0
  end

  local delta_y = state.has_js_extension and state.drag_cumulative_delta_y or (ctrl.start_y - mouse_y)
  return delta_y * sensitivity
end

-- Force peak reload next frame (e.g., after reverse changes the source)
function state.invalidate_view_peaks()
  state.view_peaks = nil
  state.view_source = nil
  state.view_start = -1
  state.view_length = -1
  state.view_num_samples = 0
end

return state
