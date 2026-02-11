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
state.dragging_zone = false          -- alt+drag in free waveform zone (slides both markers)
state.drag_alt_latched = false       -- true when alt was held at drag start (sticky slide-both)
state.marker_drag_activated = false  -- true once mouse moves beyond threshold
state.marker_drag_threshold = 4     -- px of movement before drag activates
state.undo_block_open = nil
state.drag_start_offset = 0
state.drag_start_length = 0
state.drag_start_mouse_x = 0
state.drag_start_view_length = 0
state.drag_start_playrate = 1
state.drag_current_start = 0
state.drag_current_end = 0
state.drag_start_view_start = 0

-- Fade handle state
state.fade_in_hovered = false
state.fade_out_hovered = false
state.dragging_fade_in = false
state.dragging_fade_out = false
state.fade_drag_start_mouse_x = 0
state.fade_drag_start_value = 0     -- original fade length (seconds) at drag start
state.fade_drag_start_other = 0     -- the OTHER fade's length at drag start (for push)
state.fade_drag_start_view_length = 0
state.dragging_fade_curve_in = false   -- alt+drag curvature for fade-in
state.dragging_fade_curve_out = false  -- alt+drag curvature for fade-out
state.fade_curve_drag_start_value = 0  -- original D_FADEINDIR/D_FADEOUTDIR at drag start
state.fade_curve_cumulative_y = 0     -- accumulated Y delta (cursor-locked)
state.fade_curve_was_dragged = false  -- true once cumulative Y exceeds threshold (prevents false remove)
state.fade_drag_start_auto = 0       -- auto-crossfade length at drag start
state.fade_drag_start_auto_other = 0 -- other fade's auto-crossfade length at drag start
state.fade_drag_xfade_item = nil     -- adjacent crossfade item
state.fade_drag_xfade_length = 0     -- adjacent item's D_LENGTH at drag start
state.fade_drag_xfade_max_ext = 0    -- max extension in project time (source limit)
state.fade_drag_xfade_pos = 0        -- adjacent item's D_POSITION at drag start
state.fade_drag_xfade_startoffs = 0  -- adjacent item's take D_STARTOFFS at drag start
state.fade_drag_xfade_playrate = 1   -- adjacent item's playrate
state.fade_drag_xfade_fade_auto = 0  -- adjacent item's matching auto fade at drag start
state.fade_drag_xfade_env_shift = 0  -- total envelope time shift applied (source time)
state.fade_curve_lock_x = nil         -- screen X lock position
state.fade_curve_lock_y = nil         -- screen Y lock position
state.fade_curve_last_y = nil         -- last frame screen Y for delta

-- FX drag-and-drop reorder state
state.fx_dragging = false
state.fx_drag_src_idx = -1        -- 0-based REAPER FX index being dragged
state.fx_drag_start_y = 0         -- mouse Y at drag start
state.fx_drag_threshold = 4       -- px of movement before drag activates
state.fx_drag_activated = false   -- true once threshold exceeded (prevents accidental drags)
state.fx_drag_mouse_y = 0         -- current mouse Y during drag
state.fx_scroll_offset = 0        -- FX list scroll offset in pixels

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

-- Looped item wrap tracking
state.prev_raw_start_offset = nil  -- Previous frame's raw start_offset (for wrap detection)
state.unwrapped_start_offset = nil -- Accumulated unwrapped start_offset
state.is_looped_view = false       -- Whether the view is currently in looped/extended mode

-- Mouse tracking
state.was_mouse_down = false

-- Sticky item state
state.sticky_item = nil
state.last_selected_item = nil
state.remembered_item = nil  -- Last displayed item (persists when REAPER selection goes to nil)
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
state.envelope_lock = false  -- Lock envelopes in place when dragging markers

-- Envelope overlay visibility (true = show envelope overlay on waveform)
state.envelopes_visible = true

-- Envelope editor state
state.envelope_type = "Volume"           -- "Volume" or "Pitch"
state.envelope_dropdown_open = false
state.envelope_hovered_segment = -1      -- line segment index mouse is near (-1 = none)
state.envelope_hover_x = 0              -- pixel X of hover preview
state.envelope_hover_y = 0              -- pixel Y of hover preview
state.envelope_hover_value = 0          -- value 0..1 at hover position
state.envelope_hover_time = 0           -- source time at hover position
state.dragging_env_node = false
state.env_drag_node_idx = -1            -- 0-based REAPER envelope point index
state.env_drag_start_mouse_x = 0
state.env_drag_start_mouse_y = 0
state.env_drag_start_time = 0
state.env_drag_start_value = 0
state.env_drag_activated = false        -- true once mouse exceeds 4px threshold
state.env_node_hovered_idx = -1         -- index of hovered existing node
state.env_freehand_drawing = false      -- ctrl+drag freehand envelope painting
state.env_freehand_last_x = 0          -- last mouse X to detect movement
state.env_freehand_last_take_time = 0  -- last inserted take time (for overwrite range)
state.env_tension_dragging = false     -- alt+drag to adjust segment tension
state.env_tension_point_idx = -1       -- REAPER envelope point index whose tension we're editing
state.env_tension_start_mouse_y = 0
state.env_tension_start_value = 0      -- starting tension before drag
state.env_tension_activated = false    -- true once mouse exceeds threshold
state.env_tension_descending = false   -- true if segment goes downward (v1 > v2)
state.env_tension_lock_x = nil        -- cursor lock X for tension drag
state.env_tension_lock_y = nil        -- cursor lock Y for tension drag
state.env_tension_last_y = nil        -- last frame Y for delta calc
state.env_tension_cumulative_y = 0    -- accumulated Y delta (cursor-locked)
state.env_snap_enabled = true         -- pitch snap to semitones (Ctrl+4 toggle)
state.env_segment_dragging = false    -- shift+drag to move segment (both nodes) vertically
state.env_segment_idx1 = -1           -- REAPER point index of segment start node
state.env_segment_idx2 = -1           -- REAPER point index of segment end node
state.env_segment_start_mouse_y = 0   -- mouse Y at drag start
state.env_segment_start_val1 = 0      -- value of start node at drag start
state.env_segment_start_val2 = 0      -- value of end node at drag start
state.env_segment_activated = false   -- true once mouse exceeds threshold

-- Audio preview state (CF_Preview API from SWS extension)
state.preview_cursor_pos = nil       -- source time (seconds) where preview starts
state.preview_handle = nil           -- CF_Preview handle (userdata)
state.preview_active = false         -- currently playing preview
state.preview_item = nil             -- item being previewed (for validation)

-- Region selection state (click+drag in waveform to select a portion)
state.selecting_region = false           -- true during active selection drag
state.selection_drag_activated = false   -- true once mouse moves past threshold
state.selection_start_time = 0           -- source time of selection start edge
state.selection_end_time = 0             -- source time of selection end edge
state.selection_start_mouse_x = 0        -- mouse X at click (for threshold check)
state.region_selected = false            -- true when a completed selection exists
state.region_sel_start = 0               -- finalized selection start (source time)
state.region_sel_end = 0                 -- finalized selection end (source time)
state.region_sel_item = nil              -- item the selection belongs to

-- Unified drag control state
state.drag_controls = {
  gain = { active = false, start_y = 0, start_value = 0, fine_held = false },
  pan = { active = false, start_y = 0, start_value = 0, fine_held = false },
  pitch = { active = false, start_y = 0, start_value = 0, fine_held = false },
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
    ctrl.fine_held = false
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
  return state.drag_controls.gain.active or state.drag_controls.pan.active
      or state.drag_controls.pitch.active
      or state.drag_controls.semitones.active or state.drag_controls.cents.active
end

-- Get drag delta (in pixels), handling shift modifier for fine control
function state.get_drag_delta(ctx, name, mouse_y, current_value, fine_sensitivity)
  local ctrl = state.drag_controls[name]
  if not ctrl.active then return 0 end

  local sensitivity = 1.0
  if fine_sensitivity then
    local ctrl_now = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())
    if ctrl_now ~= ctrl.fine_held then
      ctrl.start_y = mouse_y
      ctrl.start_value = current_value
      ctrl.fine_held = ctrl_now
      if state.has_js_extension then state.drag_cumulative_delta_y = 0 end
    end
    sensitivity = ctrl.fine_held and fine_sensitivity or 1.0
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
