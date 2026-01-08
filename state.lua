-- NVSD_ItemView - State Module
-- All state variables and drag control system

local state = {}

-- Peak caching
state.cached_peaks = nil
state.cached_source = nil
state.cached_item = nil
state.cached_num_samples = 0
state.cached_source_length = 0
state.cached_reversed = false
state.cached_num_channels = 1
state.peaks_error = nil
state.pending_cache_invalidation = 0

-- Progressive loading state
state.loading_stage = 0  -- 0=idle, 1=preview loaded, 2=full loaded
state.target_samples = 0  -- Final resolution we want

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
state.ruler_drag_screen_y = 0
state.ruler_drag_cumulative_y = 0
state.last_zoomed_item = nil

-- Sticky item state
state.sticky_item = nil
state.last_selected_item = nil

-- Cursor lock state
state.drag_lock_screen_x = 0
state.drag_lock_screen_y = 0
state.drag_cumulative_delta_y = 0
state.drag_last_screen_y = 0  -- Track last frame's Y position for delta calculation
state.drag_window_to_screen_y = 0
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

-- Invalidate all caches (e.g., after reverse)
function state.invalidate_cache()
  state.cached_peaks = nil
  state.cached_source = nil
  state.cached_source_length = 0
  state.cached_item = nil
  state.cached_num_samples = 0
  state.loading_stage = 0
  state.target_samples = 0
end

return state
