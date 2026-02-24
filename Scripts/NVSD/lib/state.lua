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
state.drag_virtual_x = 0             -- virtual mouse x for ctrl fine-tune (advances at 25% speed)
state.drag_last_mouse_x = 0         -- previous frame mouse_x for fine-tune delta

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
state.waveform_zoom = 1.0  -- Vertical waveform zoom (display-only, per session)
state.wf_zoom_per_item = {}  -- Per-item zoom memory (item pointer → zoom value)
state.wf_zoom_history = {}  -- Undo stack for zoom values
state.wf_zoom_scroll_anchor = nil     -- zoom value before current scroll gesture
state.wf_zoom_scroll_time = 0         -- timestamp of last scroll tick
state.is_loop_src = false              -- whether current item has B_LOOPSRC
state.wf_zoom_dragging = false  -- Zoom widget click-drag active
state.wf_zoom_drag_start_y = 0  -- Mouse Y at drag start
state.wf_zoom_drag_start_val = 1.0  -- Zoom value at drag start
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
state.cursor_lock_works = nil  -- nil = untested, true/false after first verify
state.cursor_lock_zero_frames = 0  -- count consecutive drag frames with zero cumulative delta
state._copy_combo_prev = false       -- rising-edge detection for VKey Ctrl+C fallback

-- Edge auto-scroll state (for Mac/no-cursor-lock fallback)
state.drag_imgui_last_y = nil        -- previous frame ImGui mouse_y
state.drag_edge_stall_frames = 0     -- consecutive frames mouse hasn't moved
state.drag_edge_direction = 0        -- last movement direction (-1 down, +1 up)
state.drag_edge_bonus = 0            -- accumulated bonus delta from edge scrolling

-- Warp mode state
state.warp_mode = false
state.warp_dropdown_open = false
state.warp_submode_dropdown_open = false
state.warp_submode_scroll_offset = 0
state.warp_submode_sb_dragging = false
state.warp_submode_sb_drag_start_y = 0
state.warp_submode_sb_drag_start_scroll = 0
state.warp_submode_flag_cache_algo = -1   -- algo ID the cache was built for
state.warp_submode_flag_cache = nil       -- parsed flag groups + lookup table
state.warp_mode_dropdown_open = false     -- mode selection dropdown (mutually exclusive modes)
state._dropdown_menu_open = false         -- any pitch dropdown menu open (blocks FX clicks)
state._resolved_default_algo = nil        -- cached resolved algo ID for "Project default" (-1)
state.envelope_lock = false  -- Lock envelopes in place when dragging markers
state.warp_map = nil             -- computed warp map from build_warp_map()
state.warp_hash = nil            -- hash for cache invalidation of warp view peaks
state.was_warped_view = false    -- previous frame's warped view state (for transition detection)
state._freeze_warp = false       -- freeze warp markers/map during marker drag
state._warp_view_anchor = nil    -- center anchor for preserving view during warp transition
state._warp_keep_view = nil      -- frames countdown to preserve zoom/pan on warp transition
state.warp_saved_markers_map = nil   -- saved markers for restore after leaving warp mode
state.warp_restore_popup_open = false -- restore confirmation popup visible
state.warp_restore_take = nil        -- take for marker restore
state.warp_restore_guid = nil        -- take GUID for marker restore

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
state.warp_drag_shift = false            -- shift+drag: slide source under marker
state.warp_drag_start_ext_start = nil    -- frozen ext_start during warp marker drag
state.warp_drag_start_ext_end = nil      -- frozen ext_end during warp marker drag
state.warp_drag_start_wf_bounds_start = nil -- frozen wf_bounds start during warp drag
state.warp_drag_start_wf_bounds_end = nil   -- frozen wf_bounds end during warp drag
state.warp_drag_start_item_position = 0  -- item position at warp drag start
state.warp_drag_start_item_length = 0    -- item length at warp drag start
state.warp_drag_start_start_offset = 0   -- start offset at warp drag start
-- Slope handle hover/drag (moves marker position via vertical drag)
state.slope_hovered_segment = -1        -- warp_markers index of left marker of hovered segment
state.slope_hovered_endpoint = 0        -- 1=left handle, 2=right handle
state.slope_dragging = false
state.slope_drag_segment = -1           -- warp_markers array index of left marker of segment
state.slope_drag_endpoint = 0           -- 1=left handle, 2=right handle being dragged
state.slope_drag_start_mouse_y = 0
state.slope_drag_start_pos = 0          -- pos of the dragged handle's marker (stays fixed)
state.slope_drag_start_srcpos = 0       -- srcpos of the dragged handle's marker
state.slope_drag_time_per_px = 0        -- view scale for converting vertical px to time delta
state.slope_drag_anchor_local_rate = 0  -- local rate at the anchor (non-dragged) handle
state.slope_drag_partner_idx = -1       -- REAPER index of the partner marker (the one that moves)
state.slope_drag_partner_pos = 0        -- original pos of partner marker
state.slope_drag_partner_srcpos = 0     -- srcpos of partner marker (unchanged during drag)
state.slope_drag_slope_idx = -1         -- REAPER marker index that owns the slope (left marker)
state.slope_drag_start_slope = 0        -- original slope before drag (for shift+drag mode)
state.slope_drag_activated = false
state.slope_drag_start_handle_y = 0     -- Y of the handle being dragged
state.slope_drag_start_view_start = 0   -- view start at slope drag begin
state.slope_drag_start_view_length = 0  -- view length at slope drag begin
state.slope_drag_start_ext_start = nil  -- ext_start at slope drag begin
state.slope_drag_start_ext_end = nil    -- ext_end at slope drag begin
state.slope_drag_start_wave_y = 0      -- wave_y frozen at drag begin
state.slope_drag_start_waveform_height = 0 -- waveform_height frozen at drag begin

-- Transient detection
state.transients = {}
state.transients_source = nil
state.transients_computed = false
state.transient_hovered_idx = -1
state.transients_original = nil          -- copy of initial detected transients for reset

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
state.env_drag_node_shape = 0           -- shape of dragged envelope point
state.env_drag_node_tension = 0         -- tension of dragged envelope point
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
state.cue_label_hovered = false      -- cue marker label is being hovered

-- Ghost marker state (other selected items' regions)
state.show_ghost_markers = true
state.ghost_marker_regions = nil       -- {{src_start, src_end}, ...}
state.ghost_marker_sel_count = 0       -- cache invalidation key
state.ghost_marker_sel_first = nil
state.ghost_marker_sel_last = nil
state.ghost_marker_item = nil
state.ghost_marker_proj_state = 0

-- Audio preview state (CF_Preview API from SWS extension)
state.preview_cursor_pos = nil       -- source time (seconds) where preview starts
state.preview_handle = nil           -- CF_Preview handle (userdata)
state.preview_active = false         -- currently playing preview
state.preview_item = nil             -- item being previewed (for validation)
state.preview_start_requested = false -- preview playback pending (processed in item context)
state.preview_via_transport = false   -- preview using REAPER transport instead of CF_Preview
state.preview_virtual_start = nil    -- virtual start position of preview (source time)
state.preview_start_realtime = nil   -- real-time clock at preview start

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

-- Marker drag extended state (warp-mode marker dragging)
state.drag_start_item_position = 0       -- item position at drag start
state.drag_start_warp_markers = nil      -- snapshot of warp markers at drag start
state.drag_start_warp_map = nil          -- snapshot of warp map at drag start
state.drag_start_src_pos_start = nil     -- warp source pos start at drag start
state.drag_start_src_pos_end = nil       -- warp source pos end at drag start
state.drag_start_stretch_markers = nil   -- REAPER stretch markers snapshot for undo
state.drag_start_fade_in = 0             -- fade-in length at drag start
state.drag_start_fade_out = 0            -- fade-out length at drag start
state._alt_drag_pos_delta = nil          -- position delta during alt+drag

-- Transient click state (click on transient to create warp marker)
state.transient_click_pending = false    -- transient click awaiting activation threshold
state.transient_click_srcpos = 0         -- srcpos of clicked transient
state.transient_click_mouse_x = 0       -- mouse X at transient click

-- Zoom toggle state (Ctrl+click zoom to selection/region)
state.zoom_toggle_active = false         -- zoom-to-selection toggle is active
state.zoom_before_toggle = nil           -- zoom level before toggle (for restore)
state.pan_before_toggle = nil            -- pan offset before toggle (for restore)
state.zoom_target_start = nil            -- target region start (source time)
state.zoom_target_end = nil              -- target region end (source time)

-- Toolbar state
state.toolbar_buttons = {}               -- toolbar button definitions from settings
state.toolbar_clicked = nil              -- index of clicked toolbar button (pending action)
state.info_bar_height = 0                -- computed info bar height (px)
state._tb_pending_cmd = nil              -- pending toolbar command string (to resolve next frame)
state._tb_id = nil                       -- resolved toolbar command ID

-- Toolbar bar drag and context menu (drawing.lua)
state.tb_drag_idx = nil                  -- index of button being dragged
state.tb_drag_start_x = nil              -- mouse X at toolbar drag start
state.tb_drag_active = false             -- toolbar button drag is active
state.tb_drop_idx = nil                  -- toolbar drop target index
state.tb_ctx_idx = nil                   -- toolbar context menu button index (nil = empty area)
state.tb_ctx_open = false                -- toolbar context menu is open
state.tb_ctx_x = 0                       -- toolbar context menu X position
state.tb_ctx_y = 0                       -- toolbar context menu Y position
state.tb_bar_y = 0                       -- toolbar bar Y position

-- Toolbar button edit state (drawing.lua)
state.tb_edit_idx = nil                  -- index of button being edited (nil = add new)
state.tb_edit_insert_after = 0           -- insert position for new button
state.tb_edit_label = ""                 -- edit form label text
state.tb_edit_cmd = ""                   -- edit form command string
state.tb_edit_icon = nil                 -- edit form icon
state.tb_edit_auto_label = nil           -- auto-generated label from action name
state.tb_edit_open = false               -- edit dialog is open
state.tb_edit_focus_label = false        -- focus label input on next frame

-- Toolbar icon picker (drawing.lua)
state.tb_icon_idx = nil                  -- icon picker button index
state.tb_icon_open = false               -- icon picker dialog is open
state.tb_icon_from_edit = false          -- icon picker opened from edit dialog
state.tb_icon_list = nil                 -- scanned toolbar icon list

-- Color strip (item color indicator at top of window)
state.strip_color = nil                  -- ImGui color for item color strip (nil = no strip)
state.strip_h = 0                        -- height of the color strip in pixels

-- Looped item unwrap tracking (extended)
state.unwrap_tracked_item = nil          -- item currently tracked for start_offset unwrap
state.post_drag_start_offset = nil       -- start_offset after drag (for undo detection)

-- Popup tracking
state._any_popup_open = false            -- any ImGui popup currently open

-- Waveform display bounds (source pos boundaries for drawing)
state.wf_bounds_start = nil              -- waveform display bounds start (pos-time)
state.wf_bounds_end = nil                -- waveform display bounds end (pos-time)

-- Panning via left click
state.pan_via_left_click = false         -- panning initiated by left click (not middle)

-- FX context menu
state.fx_context_menu_idx = -1           -- FX index for context menu
state.fx_context_menu_take = nil         -- take for FX context menu
state.fx_drag_drop_target = nil          -- FX drag drop target index

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
  -- Reset edge auto-scroll state
  state.drag_imgui_last_y = nil
  state.drag_edge_stall_frames = 0
  state.drag_edge_direction = 0
  state.drag_edge_bonus = 0
  if not state.undo_block_open then
    state.undo_block_open = name
  end
end

-- End a drag operation
function state.end_drag(name)
  state.drag_controls[name].active = false
  -- Snap cursor back to knob/slider position on release.
  -- Safe even on Mac: we don't need delta events after drag ends.
  if state.has_js_extension and state.drag_lock_screen_x ~= 0 then
    reaper.JS_Mouse_SetPosition(state.drag_lock_screen_x, state.drag_lock_screen_y)
  end
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
      state.drag_edge_bonus = 0
      state.drag_edge_stall_frames = 0
    end
    sensitivity = ctrl.fine_held and fine_sensitivity or 1.0
  end

  -- Use cumulative screen delta when cursor lock is verified working (infinite drag range).
  -- Fall back to ImGui mouse delta otherwise (untested, or broken on Mac).
  local use_cursor_lock = state.has_js_extension and state.cursor_lock_works == true
  if use_cursor_lock then
    return state.drag_cumulative_delta_y * sensitivity
  end

  -- ImGui fallback: base delta from absolute position
  local base_delta = ctrl.start_y - mouse_y

  -- Edge auto-scroll: when mouse is stuck at screen edge, keep moving the value.
  local stall_threshold = 0.1  -- low threshold for Retina/HiDPI displays
  if state.drag_imgui_last_y and math.abs(mouse_y - state.drag_imgui_last_y) < stall_threshold then
    -- Mouse hasn't moved this frame
    if state.drag_edge_stall_frames < 255 then
      state.drag_edge_stall_frames = state.drag_edge_stall_frames + 1
    end
    -- Determine direction: prefer per-frame direction, fall back to overall drag direction
    local dir = state.drag_edge_direction
    if dir == 0 and math.abs(base_delta) > 1 then
      dir = base_delta > 0 and 1 or -1
      state.drag_edge_direction = dir
    end
    if state.drag_edge_stall_frames >= 4 and dir ~= 0 then
      local speed = math.min(3, 0.5 + state.drag_edge_stall_frames * 0.05)
      state.drag_edge_bonus = state.drag_edge_bonus + dir * speed
    end
  else
    -- Mouse moved: absorb accumulated bonus into start_y for seamless transition
    if state.drag_edge_bonus ~= 0 then
      ctrl.start_y = ctrl.start_y + state.drag_edge_bonus
      state.drag_edge_bonus = 0
    end
    state.drag_edge_stall_frames = 0
    -- Record last movement direction from per-frame delta
    if state.drag_imgui_last_y then
      local frame_delta = state.drag_imgui_last_y - mouse_y
      if math.abs(frame_delta) > stall_threshold then
        state.drag_edge_direction = frame_delta > 0 and 1 or -1
      end
    end
    -- Recalculate base_delta after potential start_y adjustment
    base_delta = ctrl.start_y - mouse_y
  end
  state.drag_imgui_last_y = mouse_y

  return (base_delta + state.drag_edge_bonus) * sensitivity
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
  state.slope_drag_segment = -1
  state.slope_drag_endpoint = 0
  state.slope_drag_partner_idx = -1
  state.slope_drag_partner_pos = 0
  state.slope_drag_partner_srcpos = 0
  state.slope_drag_slope_idx = -1
  state.slope_drag_start_slope = 0
  state.slope_hovered_segment = -1
  state.slope_hovered_endpoint = 0
  state.wf_zoom_dragging = false
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
      or state.wf_zoom_dragging
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

-- Apply toggle defaults from settings (called at startup and optionally on item switch)
function state.apply_defaults(s)
  local d = s.current.defaults
  state.show_cue_markers = d.show_cue_markers
  state.show_ghost_markers = d.show_ghost_markers
  state.envelope_lock = d.envelope_lock
  state.env_snap_enabled = d.env_snap_enabled
  -- envelopes_visible is handled per-item-switch, not here
end

return state
