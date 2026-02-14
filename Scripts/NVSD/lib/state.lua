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
state.post_drag_ext_start = nil    -- Saved ext_start from drag (persists after release)
state.post_drag_ext_end = nil      -- Saved ext_end from drag (persists after release)
state.prev_ext_start = nil         -- Previous frame's ext_start (for external change detection)
state.prev_ext_end = nil           -- Previous frame's ext_end (for external change detection)

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

-- Stretch markers (cached per-frame when needed)
state.warp_markers = {}
state.warp_markers_take = nil
state.warp_marker_hovered_idx = -1
state.warp_marker_selected_idx = -1

-- Right-click saved state (mouse pos and hover lost once popup opens)
state.warp_right_click_time = 0
state.warp_right_click_marker_idx = -1

-- Stretch marker drag
state.dragging_warp_marker = false
state.warp_drag_idx = -1
state.warp_drag_start_mouse_x = 0
state.warp_drag_start_pos = 0
state.warp_drag_start_srcpos = 0
state.warp_drag_activated = false
state.warp_drag_start_view_start = 0
state.warp_drag_start_view_length = 0
-- Slope handle hover/drag (moves marker position via vertical drag)
state.slope_hovered_segment = -1        -- warp_markers index of left marker of hovered segment
state.slope_hovered_endpoint = 0        -- 1=left handle, 2=right handle
state.slope_dragging = false
state.slope_drag_marker_idx = -1        -- REAPER stretch marker index of the marker being moved
state.slope_drag_segment = -1           -- warp_markers array index of left marker of segment
state.slope_drag_endpoint = 0           -- 1=left handle, 2=right handle being dragged
state.slope_drag_start_mouse_y = 0
state.slope_drag_start_pos = 0          -- pos of the moved marker at drag start
state.slope_drag_start_srcpos = 0       -- srcpos of the moved marker at drag start
state.slope_drag_time_per_px = 0        -- view scale for converting vertical px to time delta
state.slope_drag_anchor_y = 0           -- Y of the non-dragged handle (stays pinned in normal drag)
state.slope_drag_partner_pos = 0        -- pos of the marker NOT being moved
state.slope_drag_partner_srcpos = 0     -- srcpos of the marker NOT being moved
state.slope_drag_slope_idx = -1         -- REAPER marker index that owns the slope (left marker)
state.slope_drag_start_slope = 0        -- original slope before drag (for shift+drag mode)
state.slope_drag_activated = false

-- Transient detection
state.transients = {}
state.transients_source = nil
state.transients_computed = false
state.transient_hovered_idx = -1

-- Envelope overlay visibility (true = show envelope overlay on waveform)
state.envelopes_visible = true

-- Pitch vertical scroll state
state.pitch_view_offset = 0              -- semitones offset from center (0 = default, + = shift up, - = shift down)
state.pitch_gutter_dragging = false      -- dragging the pitch label column to scroll
state.pitch_gutter_drag_start_y = 0      -- mouse Y at drag start
state.pitch_gutter_drag_start_offset = 0 -- pitch_view_offset at drag start

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
state.env_tension_start_mouse_x = 0   -- mouse X at drag start
state.env_tension_start_value = 0      -- starting tension before drag
state.env_tension_activated = false    -- true once mouse exceeds threshold
state.env_snap_enabled = true         -- pitch snap to semitones (Ctrl+4 toggle)
state.env_segment_dragging = false    -- shift+drag to move segment (both nodes) vertically
state.env_segment_idx1 = -1           -- REAPER point index of segment start node
state.env_segment_idx2 = -1           -- REAPER point index of segment end node
state.env_segment_start_mouse_y = 0   -- mouse Y at drag start
state.env_segment_start_val1 = 0      -- value of start node at drag start
state.env_segment_start_val2 = 0      -- value of end node at drag start
state.env_segment_activated = false   -- true once mouse exceeds threshold

-- Node selection (right-click rectangle)
state.env_selected_nodes = {}          -- list of {src_time, value} pairs identifying selected points
state.env_selection_env_name = nil     -- envelope name the selection applies to
state.env_selection_item = nil         -- item the selection belongs to
state.env_selection_env_offset = nil   -- env_offset at selection time (for delete handler)

-- Right-click rectangle selection
state.env_rect_selecting = false       -- right-click drag in progress
state.env_rect_sel_start_x = 0        -- screen px at drag start
state.env_rect_sel_start_y = 0        -- screen py at drag start
state.env_rect_sel_activated = false   -- passed 4px movement threshold
state.env_rect_sel_env_name = nil      -- saved for scoping
state.env_rect_sel_env_offset = nil    -- saved for scoping

-- Multi-node drag
state.env_multi_dragging = false       -- dragging selected nodes as group
state.env_multi_drag_start_mouse_x = 0
state.env_multi_drag_start_mouse_y = 0
state.env_multi_drag_activated = false
state.env_multi_drag_start_positions = {}  -- snapshot of {idx, take_time, value} at drag start
state.env_multi_drag_env_name = nil        -- saved for scoping
state.env_multi_drag_env_offset = nil      -- saved for scoping
state.env_multi_drag_all_points = {}       -- full envelope snapshot for sweep rebuild
state.env_node_hovered_is_selected = false -- true when hovered node is in selection

-- WAV cue marker state
state.show_cue_markers = false       -- Toggle visibility of embedded WAV cue markers
state.cached_cue_markers = nil       -- Cached cue marker data: {{time=, name=}, ...} or empty table
state.cached_cue_source = nil        -- Source pointer for which cue markers were loaded

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
  -- Always init screen-space tracking (works cross-platform without JS extension)
  local screen_x, screen_y = reaper.GetMousePosition()
  state.drag_lock_screen_x, state.drag_lock_screen_y = screen_x, screen_y
  state.drag_last_screen_y = screen_y
  state.drag_cumulative_delta_y = 0
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
      state.drag_cumulative_delta_y = 0
    end
    sensitivity = ctrl.fine_held and fine_sensitivity or 1.0
  end

  -- Always use cumulative delta from screen coords (works on all platforms)
  return state.drag_cumulative_delta_y * sensitivity
end

-- Reset all drag and interaction flags (used on dialog recovery / focus loss)
function state.reset_all_drags()
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
  state.env_freehand_drawing = false
  state.env_tension_dragging = false
  state.env_segment_dragging = false
  state.env_rect_selecting = false
  state.env_rect_sel_activated = false
  state.env_multi_dragging = false
  state.env_multi_drag_activated = false
  state.env_multi_drag_start_positions = {}
  state.env_multi_drag_all_points = {}
  state.dragging_warp_marker = false
  state.warp_drag_activated = false
  state.slope_dragging = false
  state.slope_drag_activated = false
  state.slope_drag_marker_idx = -1
  state.slope_drag_segment = -1
  state.slope_drag_endpoint = 0
  state.slope_drag_anchor_y = 0
  state.slope_drag_partner_pos = 0
  state.slope_drag_partner_srcpos = 0
  state.slope_drag_slope_idx = -1
  state.slope_drag_start_slope = 0
  state.slope_hovered_segment = -1
  state.slope_hovered_endpoint = 0
end

-- Stop any active audio preview (CF_Preview or REAPER transport)
function state.stop_preview()
  if not state.preview_active then return end
  if state.preview_via_transport then
    reaper.Main_OnCommand(1016, 0) -- Transport: Stop
    state.preview_via_transport = false
  elseif state.preview_handle then
    reaper.CF_Preview_Stop(state.preview_handle)
    state.preview_handle = nil
  end
  state.preview_active = false
end

-- Check if any interactive drag is active (markers, fades, envelopes, panning, etc.)
function state.any_drag_active()
  return state.dragging_start or state.dragging_end
      or state.dragging_fade_in or state.dragging_fade_out
      or state.dragging_fade_curve_in or state.dragging_fade_curve_out
      or state.dragging_env_node or state.env_freehand_drawing
      or state.env_tension_dragging or state.env_segment_dragging
      or state.env_multi_dragging or state.selecting_region
      or state.is_panning or state.is_ruler_dragging
      or state.fx_dragging or state.env_rect_selecting
      or state.pitch_gutter_dragging
      or state.dragging_warp_marker
      or state.slope_dragging
      or state.is_any_control_dragging()
end

-- Force peak reload next frame (e.g., after reverse changes the source)
function state.invalidate_view_peaks()
  state.view_peaks = nil
  state.view_source = nil
  state.view_start = -1
  state.view_length = -1
  state.view_num_samples = 0
  state.view_warp_hash = nil
  state.view_warped = nil
end

return state
