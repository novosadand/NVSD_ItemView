-- NVSD_ItemView - Settings UI Module
-- Settings popup window with native ImGui widgets

local settings_ui = {}

-- Flag: set to true when preferences tab checkboxes change (main loop applies to live state)
settings_ui.defaults_changed = false

-- Drawing module reference (set via set_drawing, needed for shared icon picker)
local drawing = nil

function settings_ui.set_drawing(drawing_module)
  drawing = drawing_module
end

-- Editable keyboard shortcuts (order matches display)
local EDITABLE_SHORTCUTS = {
  {name = "toggle_warp",  label = "Toggle WARP mode"},
  {name = "toggle_mute",  label = "Toggle mute"},
  {name = "reverse",      label = "Reverse item"},
  {name = "crop_to_selection", label = "Crop markers to selection"},
  {name = "open_editor",  label = "Open in external editor"},
  {name = "reset_zoom",   label = "Reset zoom to fit"},
  {name = "zoom_in",      label = "Zoom in"},
  {name = "zoom_out",     label = "Zoom out"},
  {name = "toggle_snap",  label = "Toggle envelope snap"},
  {name = "audio_preview", label = "Audio preview"},
  {name = "envelope_lock", label = "Lock envelopes"},
  {name = "show_volume_env", label = "Show Volume envelope"},
  {name = "show_pitch_env", label = "Show Pitch envelope"},
  {name = "show_pan_env", label = "Show Pan envelope"},
  {name = "hide_envelopes", label = "Hide envelopes"},
  {name = "open_settings", label = "Open settings"},
  {name = "set_start_marker", label = "Set start marker at cursor"},
  {name = "set_end_marker", label = "Set end marker at cursor"},
  {name = "set_fade_in", label = "Set fade-in at cursor"},
  {name = "set_fade_out", label = "Set fade-out at cursor"},
  {name = "zoom_to_markers", label = "Zoom to region / markers"},
  {name = "unzoom_all", label = "Zoom out to full source"},
  {name = "toggle_cue_markers", label = "Toggle WAV cue markers"},
  {name = "toggle_ghost_markers", label = "Toggle ghost markers"},
  {name = "show_in_explorer", label = "Show in Media Explorer"},
  {name = "quantize_transients", label = "Add markers at all transients"},
  {name = "preview_from_start", label = "Preview from start marker"},
  {name = "clear", label = "Clear pitch/speed/WARP"},
  {name = "insert_warp_marker", label = "Insert warp marker at cursor"},
  {name = "add_transient", label = "Insert transient at cursor"},
}

-- Reference shortcuts (not editable)
local REFERENCE_SHORTCUTS = {
  -- Keyboard (hardcoded, not rebindable)
  {"Space",          "Play / Stop transport"},
  {"Ctrl+Z",         "Undo"},
  {"Ctrl+Y",         "Redo"},
  {"Escape",         "Clear selection / Close"},
  {"Delete",         "Delete selected nodes"},
  {"Ctrl+C",         "Copy region to clipboard"},
  -- Mouse (not rebindable)
  {"Ctrl + Scroll",  "Zoom in/out"},
  {"Middle Drag",    "Pan waveform"},
  {"Ruler Drag",     "Zoom + Pan"},
  {"Left Drag",      "Select time region"},
  {"Drag Marker",    "Move start/end point"},
  {"Alt + Drag",     "Slide both markers"},
  {"Double-click",   "Reset knob/slider to default"},
  {"Double-click waveform", "Slide markers to cursor"},
  {"Ctrl + Drag",    "Fine control on knobs/sliders"},
  {"Ctrl+Alt + Drag", "Pan waveform (alt. to middle)"},
  {"Ctrl+Shift+Scroll", "Vertical amplitude zoom"},
  {"Right-click fade", "Pick fade shape"},
  {"Alt+click fade body", "Adjust fade curve bias"},
  {"Right Drag",     "Select envelope nodes"},
}

-- Core colors: 4 essential pickers that derive all other colors
local CORE_COLORS = {
  {key = "waveform_bg", label = "Background"},
  {key = "waveform",    label = "Waveform"},
  {key = "markers",     label = "Accent"},
  {key = "info_bar_text", label = "Text"},
}

-- UI State
local ui_state = {
  open = false,
  pending_theme_id = nil,
  listening_for = nil,       -- Shortcut name being captured, or nil
  custom_init_from = 0,      -- Index for "Initialize from" combo
  custom_colors_dirty = false, -- True when custom colors changed but not yet saved to ExtState
  custom_save_time = 0,      -- Debounce: time of last deferred save request
  save_theme_name = "",      -- Text input buffer for "Save as theme" name
  show_save_input = false,   -- Show the name input field
  delete_confirm_id = nil,   -- Theme ID pending deletion confirmation
  hovered_theme_id = nil,    -- Theme ID currently hovered (for delete button)
  -- Shortcut conflict modal state
  conflict_pending = nil,    -- {target = name, binding = {}, conflict_name = name} or nil
  -- Toolbar tab state
  tb_edit_idx = -1,          -- index being edited (nil = adding new, >0 = editing, -1 = none)
  tb_edit_label = "",        -- label input
  tb_edit_cmd = "",          -- command input
  tb_edit_icon = nil,        -- icon filename
  tb_edit_auto_label = nil,  -- tracks auto-filled label
  tb_search_text = "",       -- action search input
  tb_search_results = {},    -- filtered results
  tb_search_sel_idx = 0,     -- keyboard nav index
  tb_search_confirmed = "",  -- confirmed selection name
  tb_search_refocus = false,  -- re-focus InputText after Enter confirmation
  tb_drag_idx = nil,         -- button index being dragged
  tb_drag_start_y = nil,     -- mouse Y when drag started
  tb_drag_active = false,    -- true after drag threshold exceeded
  tb_drag_target = nil,      -- drop target position
  -- Icon picker state
  icon_picker_for = nil,     -- index of button whose icon is being picked (nil = closed)
  icon_picker_open = false,  -- true when popup should open this frame
  icon_list = nil,           -- cached list of icon filenames from scan
  icon_images = {},          -- {filename -> ImGui_Image or false}
}

-- Colors matching modal dark theme
local COLORS = {
  window_bg = 0x2A2A2AFF,
  child_bg = 0x252525FF,
  text = 0xDDDDDDFF,
  text_dim = 0x888888FF,
  accent = 0x4A90D9FF,
  accent_hover = 0x5AA0E9FF,
  accent_active = 0x3A80C9FF,
  btn_default = 0x404040FF,
  btn_hover = 0x505050FF,
  btn_active = 0x606060FF,
  separator = 0x444444FF,
  warning = 0xFF4444FF,
  unbound = 0x666666FF,
  border = 0x555555FF,
  tab_bg = 0x333333FF,
  tab_hover = 0x4A4A4AFF,
  tab_selected = 0x4A90D9FF,
  header_text = 0xFFFFFFFF,
}

-- Apply a shortcut change: update settings.current and persist to ExtState
local function apply_shortcut(settings, name, binding)
  settings.current.shortcuts[name] = {
    ctrl = binding.ctrl, shift = binding.shift,
    alt = binding.alt, key = binding.key,
  }
  settings.save()
end

-- Initialize pending values from current settings
local function init_pending(settings)
  ui_state.pending_theme_id = settings.current.theme_id
  ui_state.listening_for = nil
  ui_state.conflict_pending = nil
  ui_state.conflict_just_cleared = nil
  settings.listening = false
end

-- Stop listening mode
local function stop_listening(settings)
  ui_state.listening_for = nil
  settings.listening = false
end

function settings_ui.open(settings)
  ui_state.open = true
  init_pending(settings)
end

function settings_ui.close(settings)
  -- Flush any pending custom color changes to ExtState
  if ui_state.custom_colors_dirty and settings then
    local custom_theme = settings.get_theme("custom")
    if custom_theme then
      settings.save_custom_colors(custom_theme.colors)
    end
    ui_state.custom_colors_dirty = false
  end
  ui_state.open = false
  ui_state.listening_for = nil
  ui_state.conflict_pending = nil
  ui_state.conflict_just_cleared = nil
  settings.listening = false
end

function settings_ui.is_open()
  return ui_state.open
end

-- Draw a color palette bar (bg | waveform | accent) for theme preview
local function draw_color_bar(ctx, colors, width, height)
  local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  local seg = math.floor(width / 3)
  -- Three color segments
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + seg, y + height, colors.waveform_bg)
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x + seg, y, x + seg * 2, y + height, colors.waveform)
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x + seg * 2, y, x + width, y + height, colors.markers)
  -- Rounded border on top
  reaper.ImGui_DrawList_AddRect(draw_list, x, y, x + width, y + height, 0x00000044, 2)
  reaper.ImGui_Dummy(ctx, width, height)
end

-- Convert 0xRRGGBBAA to 0xRRGGBB (strip alpha) for ColorEdit3
local function color_rgba_to_rgb(c)
  return (c >> 8) & 0xFFFFFF
end

-- Convert 0xRRGGBB back to 0xRRGGBBAA (add full alpha)
local function color_rgb_to_rgba(c)
  return (c << 8) | 0xFF
end

-- Derive a secondary color from a primary by adjusting brightness
-- factor < 1.0 darkens (multiply), factor > 1.0 lightens (blend toward white)
local function derive_color(base, factor)
  local r = (base >> 24) & 0xFF
  local g = (base >> 16) & 0xFF
  local b = (base >> 8) & 0xFF
  if factor >= 1.0 then
    local t = factor - 1.0
    r = math.min(255, math.floor(r + (255 - r) * t))
    g = math.min(255, math.floor(g + (255 - g) * t))
    b = math.min(255, math.floor(b + (255 - b) * t))
  else
    r = math.max(0, math.floor(r * factor))
    g = math.max(0, math.floor(g * factor))
    b = math.max(0, math.floor(b * factor))
  end
  return (r << 24) | (g << 16) | (b << 8) | 0xFF
end

-- Add a fixed brightness offset to each RGB channel (preserves color tint)
local function offset_color(base, offset)
  local r = math.max(0, math.min(255, ((base >> 24) & 0xFF) + offset))
  local g = math.max(0, math.min(255, ((base >> 16) & 0xFF) + offset))
  local b = math.max(0, math.min(255, ((base >> 8) & 0xFF) + offset))
  return (r << 24) | (g << 16) | (b << 8) | 0xFF
end

-- Auto-derive: each core color cascades to its related colors
-- "add" entries use fixed offset (matching how preset themes space bg colors)
-- numeric entries use multiplicative factor
local AUTO_DERIVE = {
  waveform_bg   = {
    {"centerline", 16, "add"}, {"ruler_bg", 10, "add"}, {"info_bar_bg", 3, "add"},
    {"grid_bar", 28, "add"}, {"grid_beat", 12, "add"}, {"btn_off", 38, "add"},
  },
  waveform      = {{"waveform_inactive", 0.65}, {"border", 0.85}},
  markers       = {
    {"markers_hover", 1.12}, {"playhead", 1.0}, {"btn_on", 1.0},
    {"btn_hover", 1.08}, {"info_bar_icon", 1.0},
  },
  info_bar_text = {{"ruler_text", 0.79}, {"ruler_tick", 0.55}, {"btn_text", 1.57}},
}

-- Apply all derivations for a changed color key
local function apply_auto_derive(colors, key)
  local derived_list = AUTO_DERIVE[key]
  if derived_list then
    for _, d in ipairs(derived_list) do
      if d[3] == "add" then
        colors[d[1]] = offset_color(colors[key], d[2])
      else
        colors[d[1]] = derive_color(colors[key], d[2])
      end
    end
  end
end

-- Draw custom theme color editor (4 core colors in 2x2 grid + initialize from)
local function draw_custom_color_editor(ctx, settings)
  local custom_theme = settings.get_theme("custom")
  if not custom_theme then return end

  reaper.ImGui_Dummy(ctx, 0, 4)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local lx, ly = reaper.ImGui_GetCursorScreenPos(ctx)
  local lw = reaper.ImGui_GetContentRegionAvail(ctx)
  reaper.ImGui_DrawList_AddLine(dl, lx, ly, lx + lw, ly, COLORS.separator, 1)
  reaper.ImGui_Dummy(ctx, 0, 6)

  -- "Initialize from" combo
  reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Start from:")
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 140)
  if reaper.ImGui_BeginCombo(ctx, "##init_from", settings.THEMES[ui_state.custom_init_from + 1] and settings.THEMES[ui_state.custom_init_from + 1].name or "Select...") then
    for i, theme in ipairs(settings.THEMES) do
      if theme.id ~= "custom" then
        if reaper.ImGui_Selectable(ctx, theme.name, ui_state.custom_init_from == i - 1) then
          ui_state.custom_init_from = i - 1
          for _, key in ipairs(settings.COLOR_KEYS) do
            custom_theme.colors[key] = theme.colors[key]
          end
          settings.save_custom_colors(custom_theme.colors)
          settings.colors_dirty = true
        end
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end

  reaper.ImGui_Spacing(ctx)

  -- 4 core color pickers in 2x2 grid
  local edit_flags = reaper.ImGui_ColorEditFlags_NoInputs()
  if reaper.ImGui_BeginTable(ctx, "core_colors", 2, reaper.ImGui_TableFlags_None()) then
    for i, entry in ipairs(CORE_COLORS) do
      if (i - 1) % 2 == 0 then reaper.ImGui_TableNextRow(ctx) end
      reaper.ImGui_TableNextColumn(ctx)
      local c = custom_theme.colors[entry.key] or 0xFFFFFFFF
      local rgb = color_rgba_to_rgb(c)
      local rv, new_rgb = reaper.ImGui_ColorEdit3(ctx, entry.label .. "##core_" .. entry.key, rgb, edit_flags)
      if rv then
        custom_theme.colors[entry.key] = color_rgb_to_rgba(new_rgb)
        apply_auto_derive(custom_theme.colors, entry.key)
        ui_state.custom_colors_dirty = true
        settings.colors_dirty = true
      end
    end
    reaper.ImGui_EndTable(ctx)
  end
end

-- Draw a single theme row inside a table (3 columns: radio+name, color bar, delete)
local function draw_theme_row(ctx, theme, settings, bar_w, bar_h)
  local is_selected = ui_state.pending_theme_id == theme.id

  reaper.ImGui_TableNextRow(ctx)

  -- Col 1: Radio + name
  reaper.ImGui_TableNextColumn(ctx)
  if reaper.ImGui_RadioButton(ctx, theme.name .. "##" .. theme.id, is_selected) then
    -- When switching to Custom, copy colors from the previously selected theme
    if theme.id == "custom" and ui_state.pending_theme_id ~= "custom" then
      local prev_theme = settings.get_theme(ui_state.pending_theme_id)
      local custom_theme = settings.get_theme("custom")
      if prev_theme and custom_theme then
        for _, key in ipairs(settings.COLOR_KEYS) do
          custom_theme.colors[key] = prev_theme.colors[key]
        end
        settings.save_custom_colors(custom_theme.colors)
      end
    end
    ui_state.pending_theme_id = theme.id
    settings.current.theme_id = theme.id
    settings.colors_dirty = true
    settings.save()
  end
  -- Description as tooltip
  if reaper.ImGui_IsItemHovered(ctx) and theme.description ~= "" then
    reaper.ImGui_SetTooltip(ctx, theme.description)
  end

  -- Col 2: Color bar (vertically centered)
  reaper.ImGui_TableNextColumn(ctx)
  local cy = reaper.ImGui_GetCursorPosY(ctx)
  reaper.ImGui_SetCursorPosY(ctx, cy + 2)
  draw_color_bar(ctx, theme.colors, bar_w, bar_h)

  -- Col 3: Delete button (user themes only)
  reaper.ImGui_TableNextColumn(ctx)
  if theme.user_theme then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x00000000)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x66333399)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0xCC444499)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x666666FF)
    if reaper.ImGui_SmallButton(ctx, "x##del_" .. theme.id) then
      ui_state.delete_confirm_id = theme.id
    end
    reaper.ImGui_PopStyleColor(ctx, 4)
  end
end

-- Setup theme table columns (reused for both saved and preset tables)
local function setup_theme_columns(ctx, bar_w)
  reaper.ImGui_TableSetupColumn(ctx, "name", reaper.ImGui_TableColumnFlags_WidthStretch())
  reaper.ImGui_TableSetupColumn(ctx, "preview", reaper.ImGui_TableColumnFlags_WidthFixed(), bar_w + 8)
  reaper.ImGui_TableSetupColumn(ctx, "del", reaper.ImGui_TableColumnFlags_WidthFixed(), 22)
end

-- Draw Appearance tab content
local function draw_appearance_tab(ctx, settings)
  if ui_state.listening_for then
    stop_listening(settings)
  end

  local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  if not reaper.ImGui_BeginChild(ctx, "appearance_scroll", avail_w, avail_h) then return end

  local bar_w = 84
  local bar_h = 14
  local tbl_flags = reaper.ImGui_TableFlags_None()
  local open_delete_popup = false

  -- Check if user themes exist
  local has_user_themes = false
  for _, theme in ipairs(settings.THEMES) do
    if theme.user_theme then has_user_themes = true; break end
  end

  -- User-saved themes section
  if has_user_themes then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLORS.header_text)
    reaper.ImGui_Text(ctx, "Saved Themes")
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_Dummy(ctx, 0, 2)
    if reaper.ImGui_BeginTable(ctx, "user_themes", 3, tbl_flags) then
      setup_theme_columns(ctx, bar_w)
      for _, theme in ipairs(settings.THEMES) do
        if theme.user_theme then
          draw_theme_row(ctx, theme, settings, bar_w, bar_h)
          if ui_state.delete_confirm_id == theme.id then open_delete_popup = true end
        end
      end
      reaper.ImGui_EndTable(ctx)
    end
    reaper.ImGui_Dummy(ctx, 0, 4)
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    local lx, ly = reaper.ImGui_GetCursorScreenPos(ctx)
    local lw = reaper.ImGui_GetContentRegionAvail(ctx)
    reaper.ImGui_DrawList_AddLine(dl, lx, ly, lx + lw, ly, COLORS.separator, 1)
    reaper.ImGui_Dummy(ctx, 0, 6)
  end

  -- Built-in themes
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLORS.header_text)
  reaper.ImGui_Text(ctx, "Built-in Themes")
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_Dummy(ctx, 0, 2)
  if reaper.ImGui_BeginTable(ctx, "preset_themes", 3, tbl_flags) then
    setup_theme_columns(ctx, bar_w)
    for _, theme in ipairs(settings.THEMES) do
      if not theme.user_theme then
        draw_theme_row(ctx, theme, settings, bar_w, bar_h)
      end
    end
    reaper.ImGui_EndTable(ctx)
  end

  -- Delete confirmation modal (styled like warp restore modal)
  if open_delete_popup then
    reaper.ImGui_OpenPopup(ctx, "##delete_theme_confirm")
  end
  -- Center modal on screen
  local del_vp = reaper.ImGui_GetMainViewport(ctx)
  local del_cx, del_cy = reaper.ImGui_Viewport_GetCenter(del_vp)
  reaper.ImGui_SetNextWindowPos(ctx, del_cx, del_cy, reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
  reaper.ImGui_SetNextWindowSize(ctx, 300, 0, reaper.ImGui_Cond_Appearing())
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 20, 16)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 8)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(), 0x2A2A2AFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), COLORS.border)
  local del_flags = reaper.ImGui_WindowFlags_NoTitleBar()
                  + reaper.ImGui_WindowFlags_AlwaysAutoResize()
                  + reaper.ImGui_WindowFlags_NoMove()
  if reaper.ImGui_BeginPopupModal(ctx, "##delete_theme_confirm", nil, del_flags) then

    local del_theme = ui_state.delete_confirm_id and settings.get_theme(ui_state.delete_confirm_id)
    local del_name = del_theme and del_theme.name or "this theme"

    -- Centered title
    local dtitle = "Delete Theme"
    local dtitle_w = reaper.ImGui_CalcTextSize(ctx, dtitle)
    local dcontent_w = reaper.ImGui_GetContentRegionAvail(ctx)
    reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + (dcontent_w - dtitle_w) / 2)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLORS.header_text)
    reaper.ImGui_Text(ctx, dtitle)
    reaper.ImGui_PopStyleColor(ctx)

    reaper.ImGui_Spacing(ctx)
    local ddl = reaper.ImGui_GetWindowDrawList(ctx)
    local dsx, dsy = reaper.ImGui_GetCursorScreenPos(ctx)
    reaper.ImGui_DrawList_AddLine(ddl, dsx, dsy, dsx + dcontent_w, dsy, COLORS.separator, 1)
    reaper.ImGui_Dummy(ctx, 0, 4)

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xBBBBBBFF)
    reaper.ImGui_TextWrapped(ctx, "Delete \"" .. del_name .. "\"? This cannot be undone.")
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_Dummy(ctx, 0, 4)

    local dbtn_w = (dcontent_w - 8) / 2

    -- "Cancel" button (subtle)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), COLORS.btn_default)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COLORS.btn_hover)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), COLORS.btn_active)
    if reaper.ImGui_Button(ctx, "Cancel##del_cancel", dbtn_w, 30) then
      ui_state.delete_confirm_id = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_PopStyleColor(ctx, 3)

    reaper.ImGui_SameLine(ctx)

    -- "Delete" button (warning red)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xCC3333FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xDD4444FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0xBB2222FF)
    if reaper.ImGui_Button(ctx, "Delete##del_confirm", dbtn_w, 30) then
      if ui_state.delete_confirm_id then
        if ui_state.pending_theme_id == ui_state.delete_confirm_id then
          ui_state.pending_theme_id = "default"
          settings.current.theme_id = "default"
          settings.colors_dirty = true
          settings.save()
        end
        settings.delete_user_theme(ui_state.delete_confirm_id)
      end
      ui_state.delete_confirm_id = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_PopStyleColor(ctx, 3)

    reaper.ImGui_EndPopup(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 2)
  reaper.ImGui_PopStyleVar(ctx, 2)

  -- Custom theme editor + save (only when Custom is selected)
  if ui_state.pending_theme_id == "custom" then
    draw_custom_color_editor(ctx, settings)

    -- Save as new theme
    reaper.ImGui_Dummy(ctx, 0, 4)
    local dl2 = reaper.ImGui_GetWindowDrawList(ctx)
    local lx2, ly2 = reaper.ImGui_GetCursorScreenPos(ctx)
    local lw2 = reaper.ImGui_GetContentRegionAvail(ctx)
    reaper.ImGui_DrawList_AddLine(dl2, lx2, ly2, lx2 + lw2, ly2, COLORS.separator, 1)
    reaper.ImGui_Dummy(ctx, 0, 6)

    if ui_state.show_save_input then
      reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Name:")
      reaper.ImGui_SameLine(ctx)
      if not ui_state.save_input_focused then
        reaper.ImGui_SetKeyboardFocusHere(ctx, 0)
        ui_state.save_input_focused = true
      end
      reaper.ImGui_SetNextItemWidth(ctx, 160)
      local _, new_name = reaper.ImGui_InputText(ctx, "##save_theme_name", ui_state.save_theme_name)
      ui_state.save_theme_name = new_name
      reaper.ImGui_SameLine(ctx)
      local name_ok = ui_state.save_theme_name ~= ""
      -- Save button (accent)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), COLORS.accent)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COLORS.accent_hover)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), COLORS.accent_active)
      if reaper.ImGui_Button(ctx, "Save##save_confirm") and name_ok then
        local source_theme = settings.get_theme("custom")
        if source_theme then
          local new_id = settings.save_user_theme(ui_state.save_theme_name, source_theme.colors)
          ui_state.pending_theme_id = new_id
          settings.current.theme_id = new_id
          settings.colors_dirty = true
          settings.save()
        end
        ui_state.show_save_input = false
        ui_state.save_theme_name = ""
        ui_state.save_input_focused = nil
      end
      reaper.ImGui_PopStyleColor(ctx, 3)
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Cancel##save_cancel") then
        ui_state.show_save_input = false
        ui_state.save_theme_name = ""
        ui_state.save_input_focused = nil
      end
    else
      -- "Save current as new theme" button (accent)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), COLORS.accent)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COLORS.accent_hover)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), COLORS.accent_active)
      if reaper.ImGui_Button(ctx, "Save current as new theme") then
        ui_state.show_save_input = true
        ui_state.save_theme_name = ""
        ui_state.save_input_focused = nil
      end
      reaper.ImGui_PopStyleColor(ctx, 3)
    end
  end

  reaper.ImGui_EndChild(ctx)
end

-- Look up human-readable label for a shortcut name
local function get_shortcut_label(name)
  for _, entry in ipairs(EDITABLE_SHORTCUTS) do
    if entry.name == name then return entry.label end
  end
  return name
end

-- Draw Shortcuts tab content
local function draw_shortcuts_tab(ctx, settings)
  -- Key capture logic (runs every frame while listening)
  if ui_state.listening_for then
    settings.listening = true

    -- Escape: cancel capture
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
      stop_listening(settings)

    -- Backspace/Delete: clear binding
    elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Backspace())
        or reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Delete()) then
      apply_shortcut(settings, ui_state.listening_for,
        {ctrl = false, shift = false, alt = false, key = ""})
      stop_listening(settings)

    else
      -- Check for a bindable key press
      local pressed = settings.capture_pressed_key(ctx)
      if pressed then
        local binding = {
          ctrl = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl()),
          shift = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift()),
          alt = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Alt()),
          key = pressed,
        }

        -- Check for conflict
        local conflict = settings.find_conflict(
          settings.current.shortcuts, ui_state.listening_for, binding)
        if conflict then
          -- Store pending conflict for modal confirmation
          ui_state.conflict_pending = {
            target = ui_state.listening_for,
            binding = binding,
            conflict_name = conflict,
          }
          stop_listening(settings)
        else
          -- No conflict, apply directly
          apply_shortcut(settings, ui_state.listening_for, binding)
          stop_listening(settings)
        end
      end
    end
  end

  -- Open conflict modal if pending
  if ui_state.conflict_pending then
    reaper.ImGui_OpenPopup(ctx, "Shortcut Conflict##confirm")
  end

  -- Editable shortcuts header
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLORS.header_text)
  reaper.ImGui_Text(ctx, "Keyboard Shortcuts")
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_Dummy(ctx, 0, 2)

  -- Track which shortcut was just cleared by conflict resolution (highlight it)
  local just_cleared_name = ui_state.conflict_just_cleared

  local flags = reaper.ImGui_TableFlags_None()
  if not ui_state.shortcut_hover then ui_state.shortcut_hover = {} end

  if reaper.ImGui_BeginTable(ctx, "editable_shortcuts", 4, flags) then
    reaper.ImGui_TableSetupColumn(ctx, "Action", reaper.ImGui_TableColumnFlags_WidthStretch())
    reaper.ImGui_TableSetupColumn(ctx, "Binding", reaper.ImGui_TableColumnFlags_WidthFixed(), 120)
    reaper.ImGui_TableSetupColumn(ctx, "Clear", reaper.ImGui_TableColumnFlags_WidthFixed(), 24)
    reaper.ImGui_TableSetupColumn(ctx, "Reset", reaper.ImGui_TableColumnFlags_WidthFixed(), 30)

    for _, entry in ipairs(EDITABLE_SHORTCUTS) do
      local name = entry.name
      local shortcut = settings.current.shortcuts[name]
      if not shortcut then
        shortcut = {ctrl = false, shift = false, alt = false, key = ""}
      end

      local is_listening = ui_state.listening_for == name
      local is_unbound = shortcut.key == ""
      local default = settings.DEFAULT_SHORTCUTS[name]
      local is_default = default
        and shortcut.key == default.key
        and shortcut.ctrl == default.ctrl
        and shortcut.shift == default.shift
        and shortcut.alt == default.alt

      reaper.ImGui_TableNextRow(ctx)

      -- Column 1: Action label
      reaper.ImGui_TableNextColumn(ctx)

      -- Highlight label if this shortcut was just cleared by conflict overwrite
      if just_cleared_name == name then
        reaper.ImGui_TextColored(ctx, COLORS.warning, entry.label)
      else
        reaper.ImGui_Text(ctx, entry.label)
      end

      -- Column 2: Binding button
      reaper.ImGui_TableNextColumn(ctx)

      local btn_label
      local btn_color
      if is_listening then
        btn_label = "Press a key..."
        btn_color = COLORS.accent
      elseif is_unbound then
        btn_label = "---"
        btn_color = just_cleared_name == name and COLORS.warning or COLORS.unbound
      else
        btn_label = settings.format_shortcut(shortcut)
        btn_color = nil
      end

      -- Push button color if needed
      local color_pushed = 0
      if btn_color then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), btn_color)
        if btn_color == COLORS.accent then
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COLORS.accent_hover)
          color_pushed = 2
        else
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COLORS.btn_hover)
          color_pushed = 2
        end
      end

      if reaper.ImGui_Button(ctx, btn_label .. "##bind_" .. name, 120) then
        if not is_listening then
          ui_state.listening_for = name
          settings.listening = true
          -- Clear the "just cleared" highlight when user starts rebinding
          if ui_state.conflict_just_cleared then
            ui_state.conflict_just_cleared = nil
          end
        end
      end

      local btn_hovered = reaper.ImGui_IsItemHovered(ctx)

      if color_pushed > 0 then
        reaper.ImGui_PopStyleColor(ctx, color_pushed)
      end

      -- Column 3: Clear button (visible on hover, like toolbar X)
      reaper.ImGui_TableNextColumn(ctx)
      local prev_hover = ui_state.shortcut_hover[name] or false
      local show_clear = (btn_hovered or prev_hover) and not is_unbound and not is_listening
      local x_hovered = false

      if show_clear then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x00000000)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x66333399)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0xCC444499)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          0x666666FF)
        if reaper.ImGui_SmallButton(ctx, "x##clear_" .. name) then
          apply_shortcut(settings, name, {ctrl = false, shift = false, alt = false, key = ""})
        end
        x_hovered = reaper.ImGui_IsItemHovered(ctx)
        reaper.ImGui_PopStyleColor(ctx, 4)
      else
        -- Invisible but still interactive (preserves hover detection for transitions)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x00000000)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x00000000)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0x00000000)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          0x00000000)
        reaper.ImGui_SmallButton(ctx, "x##clear_" .. name)
        x_hovered = reaper.ImGui_IsItemHovered(ctx)
        reaper.ImGui_PopStyleColor(ctx, 4)
      end

      ui_state.shortcut_hover[name] = btn_hovered or x_hovered

      -- Column 4: Reset button (only if non-default)
      reaper.ImGui_TableNextColumn(ctx)
      if not is_default then
        if reaper.ImGui_SmallButton(ctx, "R##reset_" .. name) then
          if default and default.key ~= "" then
            -- Check if the default binding conflicts with another shortcut
            local conflict = settings.find_conflict(
              settings.current.shortcuts, name, default)
            if conflict then
              -- Reuse the conflict modal
              ui_state.conflict_pending = {
                target = name,
                binding = {ctrl = default.ctrl, shift = default.shift,
                           alt = default.alt, key = default.key},
                conflict_name = conflict,
              }
            else
              apply_shortcut(settings, name, default)
            end
          elseif default then
            -- Default is unbound, no conflict possible
            apply_shortcut(settings, name,
              {ctrl = false, shift = false, alt = false, key = ""})
          end
          if ui_state.conflict_just_cleared == name then
            ui_state.conflict_just_cleared = nil
          end
        end
        if reaper.ImGui_IsItemHovered(ctx) then
          local default_text = default and default.key ~= ""
            and settings.format_shortcut(default) or "unbound"
          reaper.ImGui_SetTooltip(ctx, "Reset to default: " .. default_text)
        end
      end
    end

    reaper.ImGui_EndTable(ctx)
  end

  -- Shortcut conflict confirmation modal (styled)
  local sc_vp = reaper.ImGui_GetMainViewport(ctx)
  local sc_cx, sc_cy = reaper.ImGui_Viewport_GetCenter(sc_vp)
  reaper.ImGui_SetNextWindowPos(ctx, sc_cx, sc_cy, reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
  reaper.ImGui_SetNextWindowSize(ctx, 320, 0, reaper.ImGui_Cond_Appearing())
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 20, 16)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 8)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(), 0x2A2A2AFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), COLORS.border)
  local sc_flags = reaper.ImGui_WindowFlags_NoTitleBar()
                 + reaper.ImGui_WindowFlags_AlwaysAutoResize()
                 + reaper.ImGui_WindowFlags_NoMove()
  if reaper.ImGui_BeginPopupModal(ctx, "Shortcut Conflict##confirm", nil, sc_flags) then

    local cp = ui_state.conflict_pending
    if cp then
      -- Centered title
      local sc_title = "Shortcut Conflict"
      local sc_title_w = reaper.ImGui_CalcTextSize(ctx, sc_title)
      local sc_content_w = reaper.ImGui_GetContentRegionAvail(ctx)
      reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + (sc_content_w - sc_title_w) / 2)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLORS.header_text)
      reaper.ImGui_Text(ctx, sc_title)
      reaper.ImGui_PopStyleColor(ctx)

      reaper.ImGui_Spacing(ctx)
      local sc_dl = reaper.ImGui_GetWindowDrawList(ctx)
      local sc_sx, sc_sy = reaper.ImGui_GetCursorScreenPos(ctx)
      reaper.ImGui_DrawList_AddLine(sc_dl, sc_sx, sc_sy, sc_sx + sc_content_w, sc_sy, COLORS.separator, 1)
      reaper.ImGui_Dummy(ctx, 0, 4)

      local key_text = settings.format_shortcut(cp.binding)
      local conflict_label = get_shortcut_label(cp.conflict_name)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xBBBBBBFF)
      reaper.ImGui_TextWrapped(ctx, key_text .. " is already used for:")
      reaper.ImGui_PopStyleColor(ctx)
      reaper.ImGui_Dummy(ctx, 0, 2)
      reaper.ImGui_TextColored(ctx, COLORS.accent, "  " .. conflict_label)
      reaper.ImGui_Dummy(ctx, 0, 4)

      local sc_btn_w = (sc_content_w - 8) / 2

      -- "Cancel" button (subtle)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), COLORS.btn_default)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COLORS.btn_hover)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), COLORS.btn_active)
      if reaper.ImGui_Button(ctx, "Cancel##sc_cancel", sc_btn_w, 30) then
        ui_state.conflict_pending = nil
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
      reaper.ImGui_PopStyleColor(ctx, 3)

      reaper.ImGui_SameLine(ctx)

      -- "Reassign" button (accent)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), COLORS.accent)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COLORS.accent_hover)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), COLORS.accent_active)
      if reaper.ImGui_Button(ctx, "Reassign##sc_confirm", sc_btn_w, 30) then
        -- Clear the conflicting shortcut first, then apply the new binding
        apply_shortcut(settings, cp.conflict_name,
          {ctrl = false, shift = false, alt = false, key = ""})
        apply_shortcut(settings, cp.target, cp.binding)
        -- Mark the cleared shortcut for visual highlight
        ui_state.conflict_just_cleared = cp.conflict_name
        ui_state.conflict_pending = nil
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
      reaper.ImGui_PopStyleColor(ctx, 3)
    else
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 2)
  reaper.ImGui_PopStyleVar(ctx, 2)

  -- Helper text
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Escape to cancel  /  Backspace to clear")

  -- Mouse reference section
  reaper.ImGui_Dummy(ctx, 0, 4)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local lx, ly = reaper.ImGui_GetCursorScreenPos(ctx)
  local lw = reaper.ImGui_GetContentRegionAvail(ctx)
  reaper.ImGui_DrawList_AddLine(dl, lx, ly, lx + lw, ly, COLORS.separator, 1)
  reaper.ImGui_Dummy(ctx, 0, 6)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLORS.header_text)
  reaper.ImGui_Text(ctx, "Reference")
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_TextColored(ctx, COLORS.text_dim, "(not rebindable)")
  reaper.ImGui_Dummy(ctx, 0, 2)

  if reaper.ImGui_BeginTable(ctx, "reference_shortcuts", 2, reaper.ImGui_TableFlags_None()) then
    reaper.ImGui_TableSetupColumn(ctx, "Key", reaper.ImGui_TableColumnFlags_WidthFixed(), 120)
    reaper.ImGui_TableSetupColumn(ctx, "Action", reaper.ImGui_TableColumnFlags_WidthStretch())

    for _, entry in ipairs(REFERENCE_SHORTCUTS) do
      reaper.ImGui_TableNextRow(ctx)
      reaper.ImGui_TableNextColumn(ctx)
      reaper.ImGui_TextColored(ctx, COLORS.accent, "  " .. entry[1])
      reaper.ImGui_TableNextColumn(ctx)
      reaper.ImGui_Text(ctx, entry[2])
    end

    reaper.ImGui_EndTable(ctx)
  end
end

-- Draw Toolbar tab content
-- Load an icon image for the settings UI icon picker (separate cache from drawing.lua)
local settings_icon_cache = {}  -- {filename -> {img=ImGui_Image, uv_u1=number} or false}
local settings_icons_dir = nil

function settings_ui.clear_icon_cache()
  settings_icon_cache = {}
  settings_icons_dir = nil
end

-- Returns img, uv_u1 (first sprite state UV, horizontal strip) or nil, nil
local function get_settings_icon(ctx, filename)
  if not filename or filename == "" then return nil, nil end
  local cached = settings_icon_cache[filename]
  if cached == false then return nil, nil end
  if cached then return cached.img, cached.uv_u1 end
  if not settings_icons_dir then
    settings_icons_dir = reaper.GetResourcePath() .. "/Data/toolbar_icons/"
  end
  local ok, img = pcall(reaper.ImGui_CreateImage, settings_icons_dir .. filename)
  if ok and img then
    pcall(reaper.ImGui_Attach, ctx, img)
    local ok2, w, h = pcall(reaper.ImGui_Image_GetSize, img)
    if not ok2 or not w or not h or w <= 0 or h <= 0 then
      settings_icon_cache[filename] = false
      return nil, nil
    end
    local states = math.max(1, math.floor(w / h))
    local uv_u1 = 1 / states
    settings_icon_cache[filename] = {img = img, uv_u1 = uv_u1}
    return img, uv_u1
  end
  settings_icon_cache[filename] = false
  return nil, nil
end

-- Local action cache for toolbar tab (same pattern as drawing.lua, avoids coupling)
local tb_action_cache = nil

local function get_tb_action_cache()
  if tb_action_cache then return tb_action_cache end
  tb_action_cache = {}
  local has_shortcuts = reaper.GetActionShortcutDesc ~= nil
  local idx = 0
  while true do
    local retval, name = reaper.kbd_enumerateActions(0, idx)
    if retval == 0 then break end
    local cmd_str
    local named = reaper.ReverseNamedCommandLookup and reaper.ReverseNamedCommandLookup(retval) or ""
    if named and named ~= "" then
      cmd_str = "_" .. named
    else
      cmd_str = tostring(retval)
    end
    if name and name ~= "" then
      local shortcut = ""
      if has_shortcuts then
        local ok, rv, desc = pcall(reaper.GetActionShortcutDesc, 0, retval, 0, "")
        if ok and rv and desc and desc ~= "" then shortcut = desc end
      end
      tb_action_cache[#tb_action_cache + 1] = {name = name, cmd = cmd_str, shortcut = shortcut}
    end
    idx = idx + 1
  end
  table.sort(tb_action_cache, function(a, b) return a.name:lower() < b.name:lower() end)
  return tb_action_cache
end

-- Look up resolved action name from a command ID string
local function resolve_action_name(cmd)
  if not cmd or cmd == "" then return nil end
  local cache = get_tb_action_cache()
  for _, entry in ipairs(cache) do
    if entry.cmd == cmd then return entry.name end
  end
  return nil
end

-- Clear edit form state
local function clear_tb_edit()
  ui_state.tb_edit_idx = -1
  ui_state.tb_edit_label = ""
  ui_state.tb_edit_cmd = ""
  ui_state.tb_edit_icon = nil
  ui_state.tb_edit_auto_label = nil
  ui_state.tb_search_text = ""
  ui_state.tb_search_results = {}
  ui_state.tb_search_sel_idx = 0
  ui_state.tb_search_confirmed = ""
end

-- Open edit form for an existing button
local function open_tb_edit(idx, btn)
  ui_state.tb_edit_idx = idx
  ui_state.tb_edit_label = btn.label
  ui_state.tb_edit_cmd = btn.cmd
  ui_state.tb_edit_icon = btn.icon
  ui_state.tb_edit_auto_label = nil
  local action_name = resolve_action_name(btn.cmd) or ""
  ui_state.tb_search_text = action_name
  ui_state.tb_search_results = {}
  ui_state.tb_search_sel_idx = 0
  ui_state.tb_search_confirmed = action_name
end

-- Open edit form for adding a new button
local function open_tb_add()
  ui_state.tb_edit_idx = nil
  ui_state.tb_edit_label = ""
  ui_state.tb_edit_cmd = ""
  ui_state.tb_edit_icon = nil
  ui_state.tb_edit_auto_label = nil
  ui_state.tb_search_text = ""
  ui_state.tb_search_results = {}
  ui_state.tb_search_sel_idx = 0
  ui_state.tb_search_confirmed = ""
  ui_state.tb_edit_focus_label = true
end

-- Draw the inline edit/add form (below button list)
local function draw_tb_edit_form(ctx, settings)
  -- Capture keyboard so REAPER doesn't intercept Ctrl+V etc.
  reaper.ImGui_SetNextFrameWantCaptureKeyboard(ctx, true)

  local is_editing = ui_state.tb_edit_idx ~= nil
  local header = is_editing
    and ("Editing: " .. ui_state.tb_edit_label)
    or "Add Toolbar Button"
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLORS.header_text)
  reaper.ImGui_Text(ctx, header)
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_Dummy(ctx, 0, 2)

  -- Label input
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xBBBBBBFF)
  reaper.ImGui_Text(ctx, "Label")
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  if ui_state.tb_edit_focus_label then
    reaper.ImGui_SetKeyboardFocusHere(ctx)
    ui_state.tb_edit_focus_label = false
  end
  local _, new_label = reaper.ImGui_InputText(ctx, "##tb_ed_label", ui_state.tb_edit_label)
  ui_state.tb_edit_label = new_label

  -- Action search autocomplete
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xBBBBBBFF)
  reaper.ImGui_Text(ctx, "Search Actions")
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  local search_flags = reaper.ImGui_InputTextFlags_AutoSelectAll()
  -- Re-focus InputText after Enter confirmation (one-shot)
  if ui_state.tb_search_refocus then
    reaper.ImGui_SetKeyboardFocusHere(ctx)
    ui_state.tb_search_refocus = false
  end
  local _, new_search = reaper.ImGui_InputText(ctx, "##tb_ed_search", ui_state.tb_search_text, search_flags)
  -- Detect Enter on the search field: InputText deactivates on Enter, so check both
  local search_deactivated = reaper.ImGui_IsItemDeactivated(ctx)
  local enter_pressed = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter())
      or reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_KeypadEnter())
  local search_enter = search_deactivated and enter_pressed

  -- Filter results on text change
  if new_search ~= ui_state.tb_search_text then
    ui_state.tb_search_text = new_search
    ui_state.tb_search_sel_idx = 0
    ui_state.tb_search_results = {}
    if ui_state.tb_search_confirmed ~= "" and new_search ~= ui_state.tb_search_confirmed then
      ui_state.tb_search_confirmed = ""
    end
    if new_search ~= "" then
      local words = {}
      for w in new_search:lower():gmatch("%S+") do
        words[#words + 1] = w
      end
      local cache = get_tb_action_cache()
      local count = 0
      for _, entry in ipairs(cache) do
        local lower_name = entry.name:lower()
        local match = true
        for _, w in ipairs(words) do
          if not lower_name:find(w, 1, true) then
            match = false
            break
          end
        end
        if match then
          count = count + 1
          ui_state.tb_search_results[count] = entry
          if count >= 50 then break end
        end
      end
    end
  end

  -- Keyboard navigation
  local confirmed_entry = nil
  local kb_navigated = false
  local dropdown_active = #ui_state.tb_search_results > 0 and ui_state.tb_search_confirmed == ""
  if dropdown_active then
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_DownArrow()) then
      ui_state.tb_search_sel_idx = math.min(ui_state.tb_search_sel_idx + 1, #ui_state.tb_search_results)
      kb_navigated = true
    elseif reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_UpArrow()) then
      ui_state.tb_search_sel_idx = math.max(ui_state.tb_search_sel_idx - 1, 0)
      kb_navigated = true
    end
  end
  if search_enter and ui_state.tb_search_sel_idx > 0
      and ui_state.tb_search_sel_idx <= #ui_state.tb_search_results then
    confirmed_entry = ui_state.tb_search_results[ui_state.tb_search_sel_idx]
  end

  -- Dropdown results
  local show_dropdown = #ui_state.tb_search_results > 0 and ui_state.tb_search_text ~= ""
      and ui_state.tb_search_confirmed == ""
  if show_dropdown then
    local dropdown_h = math.min(math.max(#ui_state.tb_search_results * 22 + 30, 120), 300)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0x1E1E1EFF)
    if reaper.ImGui_BeginChild(ctx, "##tb_action_results", -1, dropdown_h,
        reaper.ImGui_ChildFlags_Borders()) then
      local tbl_flags = reaper.ImGui_TableFlags_RowBg()
                      + reaper.ImGui_TableFlags_ScrollY()
                      + reaper.ImGui_TableFlags_BordersInnerV()
      if reaper.ImGui_BeginTable(ctx, "##tb_action_tbl", 3, tbl_flags) then
        reaper.ImGui_TableSetupColumn(ctx, "Shortcut",
          reaper.ImGui_TableColumnFlags_WidthFixed(), 130)
        reaper.ImGui_TableSetupColumn(ctx, "Description",
          reaper.ImGui_TableColumnFlags_WidthStretch())
        reaper.ImGui_TableSetupColumn(ctx, "Command ID",
          reaper.ImGui_TableColumnFlags_WidthFixed(), 120)
        reaper.ImGui_TableSetupScrollFreeze(ctx, 0, 1)
        reaper.ImGui_TableHeadersRow(ctx)
        for i, entry in ipairs(ui_state.tb_search_results) do
          reaper.ImGui_TableNextRow(ctx)
          local is_sel = (i == ui_state.tb_search_sel_idx)
          reaper.ImGui_TableNextColumn(ctx)
          if reaper.ImGui_Selectable(ctx, (entry.shortcut or "") .. "##asr" .. i, is_sel,
              reaper.ImGui_SelectableFlags_SpanAllColumns()) then
            confirmed_entry = entry
          end
          if is_sel and kb_navigated then
            reaper.ImGui_SetScrollHereY(ctx, 0.5)
          end
          reaper.ImGui_TableNextColumn(ctx)
          reaper.ImGui_Text(ctx, entry.name)
          reaper.ImGui_TableNextColumn(ctx)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x999999FF)
          reaper.ImGui_Text(ctx, entry.cmd)
          reaper.ImGui_PopStyleColor(ctx)
        end
        reaper.ImGui_EndTable(ctx)
      end
      reaper.ImGui_EndChild(ctx)
    end
    reaper.ImGui_PopStyleColor(ctx)
  end

  -- Apply confirmed selection
  if confirmed_entry then
    ui_state.tb_edit_cmd = confirmed_entry.cmd
    if ui_state.tb_edit_label == "" or ui_state.tb_edit_label == (ui_state.tb_edit_auto_label or "") then
      ui_state.tb_edit_label = confirmed_entry.name
      ui_state.tb_edit_auto_label = confirmed_entry.name
    end
    ui_state.tb_search_text = confirmed_entry.name
    ui_state.tb_search_confirmed = confirmed_entry.name
    ui_state.tb_search_results = {}
    ui_state.tb_search_sel_idx = 0
    -- Re-focus the search InputText next frame so Enter doesn't propagate to Nav
    ui_state.tb_search_refocus = true
  end

  -- Action Command ID input
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xBBBBBBFF)
  reaper.ImGui_Text(ctx, "Action Command ID")
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, -1)
  local _, new_cmd = reaper.ImGui_InputText(ctx, "##tb_ed_cmd", ui_state.tb_edit_cmd)
  -- Auto-fill label when command ID changes
  if new_cmd ~= ui_state.tb_edit_cmd and new_cmd ~= "" then
    local cmd_id = tonumber(new_cmd) or reaper.NamedCommandLookup(new_cmd)
    if cmd_id and cmd_id > 0 then
      local name
      if reaper.kbd_getTextFromCmd then
        name = reaper.kbd_getTextFromCmd(cmd_id, 0)
      elseif reaper.CF_GetCommandText then
        name = reaper.CF_GetCommandText(0, cmd_id)
      end
      if name and name ~= "" then
        if ui_state.tb_edit_label == "" or ui_state.tb_edit_label == (ui_state.tb_edit_auto_label or "") then
          ui_state.tb_edit_label = name
          ui_state.tb_edit_auto_label = name
        end
      end
    end
  end
  ui_state.tb_edit_cmd = new_cmd

  reaper.ImGui_Dummy(ctx, 0, 2)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x888888FF)
  reaper.ImGui_TextWrapped(ctx, "Paste ID directly, or use Search Actions above.")
  reaper.ImGui_PopStyleColor(ctx)

  -- Icon row
  reaper.ImGui_Dummy(ctx, 0, 6)

  local icon_row_h = 30
  local text_h = reaper.ImGui_GetTextLineHeight(ctx)
  local icon_label_y = reaper.ImGui_GetCursorPosY(ctx)
  local label_offset = math.floor((icon_row_h - text_h) / 2)
  reaper.ImGui_SetCursorPosY(ctx, icon_label_y + label_offset)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xBBBBBBFF)
  reaper.ImGui_Text(ctx, "Icon")
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetCursorPosY(ctx, icon_label_y)

  local icon_clicked = false
  local icon_dl = reaper.ImGui_GetWindowDrawList(ctx)
  if ui_state.tb_edit_icon and ui_state.tb_edit_icon ~= "" then
    local icon_img, icon_uv = get_settings_icon(ctx, ui_state.tb_edit_icon)
    if icon_img then
      local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
      reaper.ImGui_InvisibleButton(ctx, "##tb_ed_icon_btn", icon_row_h, icon_row_h)
      local icon_hovered = reaper.ImGui_IsItemHovered(ctx)
      icon_clicked = reaper.ImGui_IsItemClicked(ctx, 0)
      if icon_hovered then
        reaper.ImGui_DrawList_AddRectFilled(icon_dl, cx - 2, cy - 2, cx + 32, cy + 32, 0xFFFFFF25, 4)
      end
      local img_ok = pcall(reaper.ImGui_DrawList_AddImage, icon_dl, icon_img, cx, cy, cx + icon_row_h, cy + icon_row_h, 0, 0, icon_uv or 1, 1, 0xFFFFFFFF)
      if not img_ok then settings_icon_cache[ui_state.tb_edit_icon] = false end
      if icon_hovered then
        reaper.ImGui_SetTooltip(ctx, "Click to change icon")
      end
    else
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), COLORS.btn_default)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COLORS.btn_hover)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), COLORS.btn_active)
      if reaper.ImGui_SmallButton(ctx, "Change...##tb_ed_icon_change") then
        icon_clicked = true
      end
      reaper.ImGui_PopStyleColor(ctx, 3)
    end
  else
    -- "Set icon" placeholder button: 30x30 dashed outline + label
    local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
    local hit_w = icon_row_h + 6 + reaper.ImGui_CalcTextSize(ctx, "Set icon...")
    reaper.ImGui_InvisibleButton(ctx, "##tb_ed_icon_none", hit_w, icon_row_h)
    local none_hovered = reaper.ImGui_IsItemHovered(ctx)
    icon_clicked = reaper.ImGui_IsItemClicked(ctx, 0)
    -- Dashed-style outline box
    local box_col = none_hovered and 0xAAAAAAFF or 0x666666FF
    reaper.ImGui_DrawList_AddRect(icon_dl, cx, cy, cx + icon_row_h, cy + icon_row_h, box_col, 4)
    -- "+" inside the box
    local plus_col = none_hovered and 0xCCCCCCFF or 0x888888FF
    local plus_cx = cx + icon_row_h / 2
    local plus_cy = cy + icon_row_h / 2
    reaper.ImGui_DrawList_AddLine(icon_dl, plus_cx - 5, plus_cy, plus_cx + 5, plus_cy, plus_col, 1.5)
    reaper.ImGui_DrawList_AddLine(icon_dl, plus_cx, plus_cy - 5, plus_cx, plus_cy + 5, plus_col, 1.5)
    -- Label next to box
    local lbl_y = cy + math.floor((icon_row_h - text_h) / 2)
    local lbl_col = none_hovered and 0xCCCCCCFF or 0x999999FF
    reaper.ImGui_DrawList_AddText(icon_dl, cx + icon_row_h + 6, lbl_y, lbl_col, "Set icon...")
    if none_hovered then
      reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
    end
  end
  if icon_clicked then
    ui_state.icon_picker_for = "edit"
    ui_state.icon_picker_open = true
    if not ui_state.icon_list then
      ui_state.icon_list = settings.scan_toolbar_icons()
    end
  end

  -- Auto-save for editing existing buttons
  local btns = settings.current.toolbar_buttons
  if ui_state.tb_edit_idx and ui_state.tb_edit_idx >= 1 and ui_state.tb_edit_idx <= #btns then
    local btn = btns[ui_state.tb_edit_idx]
    if btn and (btn.label ~= ui_state.tb_edit_label
        or btn.cmd ~= ui_state.tb_edit_cmd
        or btn.icon ~= ui_state.tb_edit_icon) then
      if ui_state.tb_edit_label ~= "" then
        btn.label = ui_state.tb_edit_label
        btn.cmd = ui_state.tb_edit_cmd
        btn.icon = ui_state.tb_edit_icon
        settings.save_toolbar()
      end
    end
  end

  -- Cancel / Add Button (right-aligned) for adding new button
  if ui_state.tb_edit_idx == nil then
    reaper.ImGui_Dummy(ctx, 0, 4)
    local can_confirm = ui_state.tb_edit_label ~= "" and ui_state.tb_edit_cmd ~= ""
    local cancel_w = 70
    local add_w = 100
    local btn_gap = 8
    local btn_h = 26
    local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)

    reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + avail_w - cancel_w - btn_gap - add_w)

    -- Cancel (grey, left of the pair)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), COLORS.btn_default)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COLORS.btn_hover)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), COLORS.btn_active)
    if reaper.ImGui_Button(ctx, "Cancel##tb_add_cancel", cancel_w, btn_h) then
      clear_tb_edit()
    end
    reaper.ImGui_PopStyleColor(ctx, 3)

    reaper.ImGui_SameLine(ctx, 0, btn_gap)

    -- Add Button (accent, right of the pair)
    if not can_confirm then
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), 0.4)
    end
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), COLORS.accent)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), can_confirm and COLORS.accent_hover or COLORS.accent)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), can_confirm and COLORS.accent_active or COLORS.accent)
    if reaper.ImGui_Button(ctx, "Add Button", add_w, btn_h) and can_confirm then
      settings.add_toolbar_button(ui_state.tb_edit_label, ui_state.tb_edit_cmd, ui_state.tb_edit_icon)
      clear_tb_edit()
    end
    reaper.ImGui_PopStyleColor(ctx, 3)
    if not can_confirm then
      reaper.ImGui_PopStyleVar(ctx)
    end
  end
end

local function draw_toolbar_tab(ctx, settings)
  -- Cancel shortcut listening when switching to Toolbar tab
  if ui_state.listening_for then
    stop_listening(settings)
  end

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLORS.header_text)
  reaper.ImGui_Text(ctx, "Toolbar")
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_Dummy(ctx, 0, 2)
  reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Custom buttons and separators in the info bar. Drag and drop to reorder.")
  reaper.ImGui_Dummy(ctx, 0, 4)

  local btns = settings.current.toolbar_buttons or {}
  local remove_idx = nil
  local row_metrics = {}
  local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
  local win_hovered = reaper.ImGui_IsWindowHovered(ctx)

  if #btns > 0 then
    local tbl_flags = reaper.ImGui_TableFlags_None()
    if reaper.ImGui_BeginTable(ctx, "toolbar_btns", 3, tbl_flags) then
      reaper.ImGui_TableSetupColumn(ctx, "Icon", reaper.ImGui_TableColumnFlags_WidthFixed(), 50)
      reaper.ImGui_TableSetupColumn(ctx, "LabelAction", reaper.ImGui_TableColumnFlags_WidthStretch())
      reaper.ImGui_TableSetupColumn(ctx, "Del", reaper.ImGui_TableColumnFlags_WidthFixed(), 32)

      local icon_size = 30  -- match info bar icon size
      -- Fixed row height for all rows so delete button stays in same position
      local row_h_est = math.max(reaper.ImGui_GetTextLineHeightWithSpacing(ctx) * 2 + 2, icon_size + 8)

      for i, btn in ipairs(btns) do
        local is_sep = btn.type == "separator"
        reaper.ImGui_TableNextRow(ctx)
        reaper.ImGui_PushID(ctx, i)

        -- Column 1: Grip + icon preview
        reaper.ImGui_TableNextColumn(ctx)
        local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
        row_metrics[i] = {y = cy}

        -- Row hover detection
        local is_row_hovered = win_hovered
            and mouse_y >= cy and mouse_y < cy + row_h_est
            and not ui_state.tb_drag_active
        local is_editing = (ui_state.tb_edit_idx == i)

        if is_row_hovered and not ui_state.tb_drag_idx then
          reaper.ImGui_TableSetBgColor(ctx, reaper.ImGui_TableBgTarget_RowBg1(), 0xFFFFFF12)
          reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
        elseif is_editing then
          reaper.ImGui_TableSetBgColor(ctx, reaper.ImGui_TableBgTarget_RowBg1(), (COLORS.accent & 0xFFFFFF00) | 0x18)
        end

        -- InvisibleButton captures click to prevent window drag
        reaper.ImGui_InvisibleButton(ctx, "##tb_grip", 50, row_h_est)

        local row_dl = reaper.ImGui_GetWindowDrawList(ctx)

        -- Draw drag grip lines (3 horizontal lines)
        local grip_x = cx + 8
        local grip_cy = cy + row_h_est / 2
        local is_being_dragged = ui_state.tb_drag_active and ui_state.tb_drag_idx == i
        local grip_col = is_being_dragged and COLORS.accent
            or (is_row_hovered and COLORS.text or COLORS.text_dim)
        for li = -1, 1 do
          local ly = grip_cy + li * 4
          reaper.ImGui_DrawList_AddLine(row_dl, grip_x, ly, grip_x + 8, ly, grip_col, 1)
        end

        if is_sep then
          -- Separator: draw vertical line matching real toolbar size (20px, centered)
          local sep_icon_x = cx + 20 + math.floor(icon_size / 2)
          local sep_line_h = 20
          local sep_top = cy + math.floor((row_h_est - sep_line_h) / 2)
          reaper.ImGui_DrawList_AddLine(row_dl, sep_icon_x, sep_top, sep_icon_x, sep_top + sep_line_h, 0x888888FF, 1.5)
        else
          -- Icon preview next to grip (30x30 to match info bar, vertically centered)
          local icon_img, icon_uv_u1
          if btn.icon then icon_img, icon_uv_u1 = get_settings_icon(ctx, btn.icon) end
          local icon_x = cx + 20
          local icon_y = cy + math.floor((row_h_est - icon_size) / 2)
          if icon_img then
            local img_ok = pcall(reaper.ImGui_DrawList_AddImage, row_dl, icon_img,
              icon_x, icon_y, icon_x + icon_size, icon_y + icon_size, 0, 0, icon_uv_u1, 1, 0xFFFFFFFF)
            if not img_ok then settings_icon_cache[btn.icon] = false end
          else
            local ph_size = 18
            local ph_x = icon_x + math.floor((icon_size - ph_size) / 2)
            local ph_y = cy + math.floor((row_h_est - ph_size) / 2)
            reaper.ImGui_DrawList_AddRect(row_dl, ph_x, ph_y, ph_x + ph_size, ph_y + ph_size, COLORS.text_dim, 2)
          end
        end

        -- Column 2: Label + resolved action name (or "Separator" for separators)
        reaper.ImGui_TableNextColumn(ctx)
        local c2x, c2y = reaper.ImGui_GetCursorScreenPos(ctx)
        local c2_avail = reaper.ImGui_GetContentRegionAvail(ctx)
        reaper.ImGui_InvisibleButton(ctx, "##tb_row_hit", c2_avail, row_h_est)
        reaper.ImGui_SetCursorScreenPos(ctx, c2x, c2y)

        if is_sep then
          local sep_text_y = c2y + math.floor((row_h_est - reaper.ImGui_GetTextLineHeight(ctx)) / 2)
          reaper.ImGui_SetCursorScreenPos(ctx, c2x, sep_text_y)
          reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Separator")
        else
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLORS.header_text)
          reaper.ImGui_Text(ctx, btn.label)
          reaper.ImGui_PopStyleColor(ctx)
          local action_name = resolve_action_name(btn.cmd)
          if action_name then
            reaper.ImGui_TextColored(ctx, COLORS.text_dim, action_name)
          else
            reaper.ImGui_TextColored(ctx, 0x666666FF, btn.cmd)
          end
        end

        -- Column 3: Delete button (vertically centered, breathing room from edge)
        reaper.ImGui_TableNextColumn(ctx)
        local del_cx, del_cy = reaper.ImGui_GetCursorScreenPos(ctx)
        local del_btn_h = reaper.ImGui_GetTextLineHeightWithSpacing(ctx)
        local del_offset_y = math.floor((row_h_est - del_btn_h) / 2)
        reaper.ImGui_SetCursorScreenPos(ctx, del_cx + 4, del_cy + del_offset_y)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x00000000)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x66333399)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0xCC444499)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x666666FF)
        if reaper.ImGui_SmallButton(ctx, "x##tb_del") then
          remove_idx = i
        end
        reaper.ImGui_PopStyleColor(ctx, 4)

        reaper.ImGui_PopID(ctx)
      end

      reaper.ImGui_EndTable(ctx)
    end
  else
    reaper.ImGui_TextColored(ctx, COLORS.text_dim, "No toolbar items configured.")
    reaper.ImGui_Dummy(ctx, 0, 4)
  end

  -- Compute actual row heights from consecutive Y positions
  for i = 1, #row_metrics do
    if i < #row_metrics then
      row_metrics[i].h = row_metrics[i + 1].y - row_metrics[i].y
    else
      row_metrics[i].h = reaper.ImGui_GetTextLineHeightWithSpacing(ctx) * 2 + 2
    end
  end

  -- Process delete first (before click/drag to avoid conflicts)
  if remove_idx then
    if ui_state.tb_drag_idx == remove_idx then
      ui_state.tb_drag_idx = nil
      ui_state.tb_drag_active = false
    end
    settings.remove_toolbar_button(remove_idx)
    if ui_state.tb_edit_idx == remove_idx then
      clear_tb_edit()
    elseif ui_state.tb_edit_idx and ui_state.tb_edit_idx > remove_idx then
      ui_state.tb_edit_idx = ui_state.tb_edit_idx - 1
    end
  end

  -- Click/drag initiation: mouse clicked on a row (but not on delete button)
  if not remove_idx and not ui_state.tb_drag_idx
      and reaper.ImGui_IsMouseClicked(ctx, 0) and win_hovered then
    for i, rm in ipairs(row_metrics) do
      if mouse_y >= rm.y and mouse_y < rm.y + rm.h then
        ui_state.tb_drag_idx = i
        ui_state.tb_drag_start_y = mouse_y
        ui_state.tb_drag_active = false
        ui_state.tb_drag_target = nil
        break
      end
    end
  end

  -- Drag processing (mouse held after click on a row)
  local drag_threshold = 4
  if ui_state.tb_drag_idx and reaper.ImGui_IsMouseDown(ctx, 0) then
    local dy = math.abs(mouse_y - (ui_state.tb_drag_start_y or mouse_y))
    if not ui_state.tb_drag_active and dy >= drag_threshold then
      ui_state.tb_drag_active = true
    end
    if ui_state.tb_drag_active and #row_metrics > 0 then
      reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeNS())
      -- Find drop target based on mouse Y vs row midpoints
      local drop_idx = nil
      for ri = 1, #row_metrics do
        local rm = row_metrics[ri]
        local mid = rm.y + rm.h / 2
        if mouse_y < mid then
          drop_idx = ri
          break
        end
      end
      if not drop_idx then drop_idx = #btns + 1 end
      ui_state.tb_drag_target = drop_idx

      -- Draw insertion line
      local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
      local line_y
      if drop_idx <= #row_metrics then
        line_y = row_metrics[drop_idx].y - 1
      else
        local last = row_metrics[#row_metrics]
        line_y = last.y + last.h + 1
      end
      local win_x, _ = reaper.ImGui_GetWindowPos(ctx)
      local win_w = reaper.ImGui_GetWindowWidth(ctx)
      reaper.ImGui_DrawList_AddLine(draw_list, win_x + 20, line_y, win_x + win_w - 20, line_y, COLORS.accent, 2)
    end
  elseif ui_state.tb_drag_idx then
    -- Mouse released
    if ui_state.tb_drag_active and ui_state.tb_drag_target then
      -- Drag completed: reorder
      local from = ui_state.tb_drag_idx
      local to = ui_state.tb_drag_target
      if to > from then to = to - 1 end
      if to ~= from and to >= 1 and to <= #btns then
        settings.move_toolbar_button(from, to)
        if ui_state.tb_edit_idx and ui_state.tb_edit_idx > 0 then
          if ui_state.tb_edit_idx == from then
            ui_state.tb_edit_idx = to
          elseif from < to and ui_state.tb_edit_idx > from and ui_state.tb_edit_idx <= to then
            ui_state.tb_edit_idx = ui_state.tb_edit_idx - 1
          elseif from > to and ui_state.tb_edit_idx >= to and ui_state.tb_edit_idx < from then
            ui_state.tb_edit_idx = ui_state.tb_edit_idx + 1
          end
        end
      end
    elseif not ui_state.tb_drag_active then
      -- Click (no drag): toggle edit form (skip separators)
      local idx = ui_state.tb_drag_idx
      if idx >= 1 and idx <= #btns and btns[idx].type ~= "separator" then
        if ui_state.tb_edit_idx == idx then
          clear_tb_edit()
        else
          open_tb_edit(idx, btns[idx])
        end
      end
    end
    ui_state.tb_drag_idx = nil
    ui_state.tb_drag_start_y = nil
    ui_state.tb_drag_active = false
    ui_state.tb_drag_target = nil
  end

  -- "+ Add Button" and "+ Add Separator" in one row
  reaper.ImGui_Dummy(ctx, 0, 2)
  local add_form_open = ui_state.tb_edit_idx == nil
  local avail_w = reaper.ImGui_GetContentRegionAvail(ctx)
  local btn_gap = 6
  local add_btn_w = math.floor((avail_w - btn_gap) * 0.65)
  local add_sep_w = avail_w - add_btn_w - btn_gap

  -- "+ Add Button" (disabled while add form is open)
  if add_form_open then
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), 0.35)
  end
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), COLORS.accent)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), add_form_open and COLORS.accent or COLORS.accent_hover)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), add_form_open and COLORS.accent or COLORS.accent_active)
  if reaper.ImGui_Button(ctx, "+ Add Button", add_btn_w, 28) and not add_form_open then
    open_tb_add()
  end
  reaper.ImGui_PopStyleColor(ctx, 3)
  if add_form_open then
    reaper.ImGui_PopStyleVar(ctx)
  end

  reaper.ImGui_SameLine(ctx, 0, btn_gap)

  -- "+ Add Separator"
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), COLORS.btn_default)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COLORS.btn_hover)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), COLORS.btn_active)
  if reaper.ImGui_Button(ctx, "+ Add Separator", add_sep_w, 28) then
    settings.add_toolbar_separator()
  end
  reaper.ImGui_PopStyleColor(ctx, 3)

  -- Edit form (inline, below button list, NoNav prevents arrow/Enter from moving widget focus)
  if ui_state.tb_edit_idx ~= -1 then
    reaper.ImGui_Dummy(ctx, 0, 4)
    local form_dl = reaper.ImGui_GetWindowDrawList(ctx)
    local form_x, form_y = reaper.ImGui_GetCursorScreenPos(ctx)
    local form_w = reaper.ImGui_GetContentRegionAvail(ctx)
    reaper.ImGui_DrawList_AddLine(form_dl, form_x, form_y, form_x + form_w, form_y, COLORS.separator, 1)
    reaper.ImGui_Dummy(ctx, 0, 6)

    local child_flags = reaper.ImGui_ChildFlags_AutoResizeY()
    -- Only block Nav (arrows/Enter) while the action dropdown is visible
    local dropdown_showing = #ui_state.tb_search_results > 0
        and ui_state.tb_search_text ~= ""
        and ui_state.tb_search_confirmed == ""
    local win_flags = dropdown_showing and reaper.ImGui_WindowFlags_NoNav() or reaper.ImGui_WindowFlags_None()
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0x00000000)
    if reaper.ImGui_BeginChild(ctx, "##tb_edit_form", -1, 0, child_flags, win_flags) then
      draw_tb_edit_form(ctx, settings)
      reaper.ImGui_EndChild(ctx)
    end
    reaper.ImGui_PopStyleColor(ctx)
  end

  -- Icon picker popup (shared between edit form and any future use)
  if ui_state.icon_picker_open then
    reaper.ImGui_OpenPopup(ctx, "Choose Icon##tb_icon_picker")
    ui_state.icon_picker_open = false
    drawing.reset_icon_picker_state()
  end

  reaper.ImGui_SetNextWindowSize(ctx, 900, 800, reaper.ImGui_Cond_Appearing())
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 16, 14)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 8)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(), 0x2A2A2AFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), COLORS.border)
  local settings_icon_flags = reaper.ImGui_WindowFlags_NoTitleBar()
                            + reaper.ImGui_WindowFlags_NoScrollbar()
  if reaper.ImGui_BeginPopup(ctx, "Choose Icon##tb_icon_picker", settings_icon_flags) then
    reaper.ImGui_SetNextFrameWantCaptureKeyboard(ctx, true)
    local icons = ui_state.icon_list or {}
    if #icons == 0 then
      reaper.ImGui_TextColored(ctx, COLORS.text_dim, "No toolbar icons found.")
      reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Install icon packs in REAPER's")
      reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Data/toolbar_icons/ directory.")
    else
      local picked = drawing.draw_icon_picker_content(ctx, icons, "icon_grid", get_settings_icon)
      if picked == false then
        reaper.ImGui_CloseCurrentPopup(ctx)
      elseif picked == "" then
        ui_state.tb_edit_icon = nil
        ui_state.icon_picker_for = nil
        reaper.ImGui_CloseCurrentPopup(ctx)
      elseif picked then
        ui_state.tb_edit_icon = picked
        ui_state.icon_picker_for = nil
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
    end
    reaper.ImGui_EndPopup(ctx)
  else
    if ui_state.icon_picker_for then
      ui_state.icon_picker_for = nil
    end
  end
  reaper.ImGui_PopStyleColor(ctx, 2)
  reaper.ImGui_PopStyleVar(ctx, 2)
end

-- Help content sections (header + body pairs)
-- Help content with lightweight markup:
--   Lines with "KEY: description" render as shortcut entries (key highlighted)
--   Lines starting with "## " render as sub-headers
--   Lines starting with "- " render as bullet items
--   Lines starting with "  - " render as indented bullet items
--   Lines starting with "1. " (etc.) render as numbered steps
--   Empty lines add paragraph spacing
--   Other lines render as normal wrapped text
local HELP_SECTIONS = {
  {
    header = "NVSD ItemView",
    lines = {
      "Ableton-style clip view for REAPER audio items.",
      "Non-destructive editing of start/end points, gain, pitch,",
      "envelopes, warp markers, fades, and FX. All changes create undo points.",
    },
  },
  {
    header = "Quick Start",
    lines = {
      "1. Select an audio item in REAPER",
      "2. Run the script (Actions > NVSD_ItemView)",
      "3. Drag the colored markers to adjust start/end points",
      "4. Use the left panel for gain, pitch, reverse, WARP, and FX",
      "5. Press Alt+S for settings, Esc to close",
    },
  },
  {
    header = "Waveform & Navigation",
    lines = {
      {key = "Ctrl+Scroll", desc = "Zoom in/out"},
      {key = "Ctrl+Shift+Scroll", desc = "Vertical amplitude zoom"},
      {key = "Middle-drag", desc = "Pan waveform"},
      {key = "Ctrl+Alt+drag", desc = "Pan waveform (alt. to middle)"},
      {key = "Ruler drag", desc = "Vertical zooms, horizontal pans"},
      {key = "F", desc = "Fit zoom to source"},
      {key = "Z", desc = "Zoom to selection/markers (toggle)"},
      {key = "Alt+Z", desc = "Zoom out to full source"},
      "",
      {key = "Click", desc = "Place preview cursor"},
      {key = "Double-click", desc = "Slide both markers to cursor"},
      {key = "Drag", desc = "Select a time region"},
      {key = "Ctrl+click", desc = "Set start marker"},
      {key = "Ctrl+Shift+click", desc = "Set end marker"},
      {key = "Ctrl+Space", desc = "Audio preview (requires SWS)"},
      {key = "Enter", desc = "Preview from start marker"},
      {key = "Right-click", desc = "Context menu (warp actions, settings)"},
      "- Click during preview moves playhead without stopping",
      "- Ctrl+Z undoes zoom changes before reaching REAPER undo",
    },
  },
  {
    header = "Markers & Regions",
    lines = {
      "- Drag start/end markers to adjust playback region",
      {key = "Ctrl+drag marker", desc = "Fine-tune (4x slower movement)"},
      {key = "Double-click", desc = "Slide both markers to cursor"},
      {key = "Alt+drag marker", desc = "Slide both markers (preserve length)"},
      {key = "Mouse4 / Mouse5", desc = "Jump start/end to cursor"},
      {key = "Shift+Mouse4/5", desc = "Set fade-in/out at cursor"},
      "- Snap to grid when enabled (Ctrl+4)",
      "",
      "## Selection",
      {key = "C", desc = "Crop to selection"},
      {key = "Ctrl+C", desc = "Copy selection as new item"},
      {key = "Escape", desc = "Clear selection"},
      "",
      "## Cue Markers",
      {key = "M", desc = "Toggle WAV cue markers"},
      "- Click a cue label to select the region between cues",
      "",
      "## Ghost Markers",
      {key = "G", desc = "Toggle ghost markers"},
      "When multiple items from the same source file are selected,",
      "shows bracket overlays where the other items' regions fall.",
      "Useful for seeing which takes are already used when making variations.",
    },
  },
  {
    header = "Left Panel",
    lines = {
      "## Controls",
      {key = "Gain slider", desc = "Volume (+24 dB to -inf)"},
      {key = "Pitch knob", desc = "Pitch (+/-48 semitones)"},
      {key = "Pan knob", desc = "Stereo pan (L100 to R100)"},
      {key = "Semitones/Cents", desc = "Fine-tune pitch (drag)"},
      "- Double-click to reset, Ctrl+drag for fine control",
      "",
      "## Buttons",
      {key = "WARP", desc = "Pitch-preserving stretch mode"},
      {key = "Algorithm", desc = "Pitch shift algorithm (scroll to cycle)"},
      {key = "x2 / /2", desc = "Double or halve speed"},
      {key = "Clear (Shift+C)", desc = "Reset pitch, playrate, WARP, markers"},
      {key = "Reverse", desc = "Reverse the audio"},
      {key = "Edit", desc = "External editor or Item Properties"},
      {key = "Loop", desc = "Toggle loop source"},
      {key = "Mute", desc = "Toggle item mute"},
    },
  },
  {
    header = "WARP Mode",
    lines = {
      {key = "W", desc = "Toggle WARP (preserves pitch when stretching)"},
      "Shows stretch markers, slope handles, and transients above waveform.",
      "",
      "## Warp Bar",
      {key = "Double-click empty", desc = "Create warp marker"},
      {key = "Double-click marker", desc = "Delete warp marker"},
      {key = "Delete (hover)", desc = "Delete hovered warp marker"},
      {key = "Drag marker", desc = "Move warp marker"},
      {key = "Shift+drag marker", desc = "Slide source audio under marker"},
      {key = "Drag transient ghost", desc = "Promote to warp marker and drag"},
      {key = "Ctrl+hover transient", desc = "Preview 3 nearest transients"},
      "",
      "## Slope Handles",
      {key = "Drag", desc = "Adjust stretch rate distribution"},
      {key = "Shift+drag", desc = "Pure slope (both handles move opposite)"},
      {key = "Double-click", desc = "Reset slope to 0"},
      "",
      "## Shortcuts",
      {key = "Ctrl+I", desc = "Insert warp marker at cursor/selection"},
      {key = "Ctrl+Shift+I", desc = "Insert manual transient"},
      {key = "Ctrl+U", desc = "Add markers at transients and quantize"},
      "",
      "## Right-Click Menu",
      "- Delete / Insert warp marker",
      "- Add warp markers at transients (in selection)",
      "- Quantize warp markers (Ctrl+U)",
      "- Clear all warp markers",
      "- Insert / Reset transients",
      "",
      "Markers persist when toggling WARP off/on.",
    },
  },
  {
    header = "Envelopes",
    lines = {
      {key = "Shift+V / H / P", desc = "Show Volume / Pitch / Pan"},
      {key = "H", desc = "Hide all envelopes"},
      {key = "L", desc = "Lock (prevent edits)"},
      {key = "Ctrl+4", desc = "Snap to grid"},
      "",
      "## Editing",
      {key = "Drag node", desc = "Move point"},
      {key = "Drag segment", desc = "Move both endpoints vertically"},
      {key = "Shift+click", desc = "Insert node and start dragging"},
      {key = "Alt+click node", desc = "Delete node"},
      {key = "Alt+drag segment", desc = "Adjust curve tension"},
      {key = "Alt+double-click", desc = "Reset curve to linear"},
      {key = "Ctrl+drag", desc = "Freehand drawing"},
      {key = "Right-drag", desc = "Rectangle-select multiple nodes"},
      "- Drag a selected node to move all selected together",
      {key = "Delete", desc = "Remove selected nodes"},
      "",
      "## Pitch Envelope",
      "- Scroll to shift pitch view range",
      "- Drag pitch label gutter to pan vertically",
    },
  },
  {
    header = "Fades",
    lines = {
      "- Drag fade handles at item edges to adjust length",
      {key = "Alt+drag handle", desc = "Adjust curve tension"},
      {key = "Alt+click fade body", desc = "Drag fade curve bias"},
      "- Right-click fade handle to pick shape (7 options)",
      {key = "Shift+Mouse4", desc = "Set fade-in at cursor"},
      {key = "Shift+Mouse5", desc = "Set fade-out at cursor"},
      "- Fades auto-clamp so they never overlap",
    },
  },
  {
    header = "FX & Info Bar",
    lines = {
      "## Info Bar",
      "- Click filename to open Media Explorer (Ctrl+F)",
      "- Click mute indicator to toggle mute",
      "- CUE button for embedded WAV cue markers (M to toggle)",
      "- Ghost markers button in bottom bar (G to toggle)",
      "- Amplitude zoom widget: drag, double-click reset, right-click undo",
      "- Track/item color strip above the bar",
      "",
      "## Envelope Bar",
      "- Lock, Snap, Ghost markers, Shaped waveform toggles",
      {key = "Shaped waveform", desc = "Waveform shape follows fades, volume and pan envelopes"},
      "",
      "## FX (appears when take has FX)",
      {key = "Left FX button", desc = "Toggle bypass / Add FX"},
      {key = "Right FX button", desc = "Open chain, Alt+click to remove all"},
      {key = "Click / Shift / Alt", desc = "Open / Bypass / Delete individual FX"},
      "- Drag to reorder",
      "- Right-click FX for menu (bypass, offline, delete, reorder)",
    },
  },
  {
    header = "Custom Toolbar",
    lines = {
      "Add action buttons via the Toolbar tab in settings.",
      "- Search REAPER actions or paste a command ID",
      "- Drag to reorder, add separators, pick icons",
      "- Right-click buttons for edit/delete/insert menu",
      "- Right-click empty info bar area to add buttons inline",
      "- Drag buttons in the info bar to reorder",
    },
  },
  {
    header = "All Shortcuts",
    lines = {
      "Rebindable in the Shortcuts tab.",
      "",
      "## Rebindable",
      {key = "W", desc = "Toggle WARP"},
      {key = "Num0", desc = "Toggle mute"},
      {key = "R", desc = "Reverse"},
      {key = "C", desc = "Crop to selection"},
      {key = "Shift+C", desc = "Clear pitch/speed/WARP"},
      {key = "Ctrl+Alt+E", desc = "External editor"},
      {key = "F", desc = "Fit zoom"},
      {key = "Z", desc = "Zoom to selection/markers"},
      {key = "Alt+Z", desc = "Zoom out to full source"},
      {key = "Ctrl+4", desc = "Snap to grid"},
      {key = "L", desc = "Lock envelopes"},
      {key = "Shift+V / H / P", desc = "Volume / Pitch / Pan envelope"},
      {key = "H", desc = "Hide envelopes"},
      {key = "M", desc = "Cue markers"},
      {key = "G", desc = "Ghost markers"},
      {key = "Ctrl+Space", desc = "Audio preview"},
      {key = "Enter", desc = "Preview from start marker"},
      {key = "Ctrl+F", desc = "Show in Media Explorer"},
      {key = "S", desc = "Settings"},
      {key = "Mouse4 / Mouse5", desc = "Set start/end marker"},
      {key = "Shift+Mouse4/5", desc = "Set fade-in/out"},
      {key = "Ctrl+I", desc = "Insert warp marker"},
      {key = "Ctrl+Shift+I", desc = "Insert transient"},
      {key = "Ctrl+U", desc = "Quantize to transients"},
      "",
      "## Fixed",
      {key = "Space", desc = "Play/Stop (or stop preview)"},
      {key = "Ctrl+Z / Ctrl+Y", desc = "Undo / Redo (zoom history first)"},
      {key = "Ctrl+C", desc = "Copy selected region as new item"},
      {key = "Escape", desc = "Clear nodes, then selection, then close"},
      {key = "Delete", desc = "Delete selected nodes / hovered warp marker"},
      {key = "Ctrl+Scroll", desc = "Zoom"},
      {key = "Ctrl+Shift+Scroll", desc = "Vertical amplitude zoom"},
      {key = "Middle-drag", desc = "Pan"},
      {key = "Ctrl+Alt+drag", desc = "Pan (alt. to middle)"},
      {key = "Ctrl+drag marker", desc = "Fine-tune drag (4x slower)"},
      {key = "Ctrl+drag knob/slider", desc = "Fine-tune adjustment"},
      {key = "Double-click", desc = "Slide markers to cursor / reset knob"},
    },
  },
  {
    header = "Tips",
    lines = {
      "- Map the script to a toolbar button for quick toggle",
      "- Running it again while open closes it",
      "- Right-click title bar to dock",
      "- WARP markers persist per-item across sessions",
      "- Scroll over dropdowns (Algorithm, Mode, Options) to cycle values",
      "- JS_ReaScriptAPI improves knob/slider drag range",
      "- Hover any element for a tooltip",
      "- Use the Preferences tab to control initial toggle states and hide UI panels",
    },
  },
}

-- Help rendering colors (extend base COLORS)
local HELP_COLORS = {
  key = 0x7BBDF7FF,        -- bright blue for shortcut keys
  sub_header = 0xAAAAAAFF,  -- lighter gray for sub-headers
  bullet = 0x666666FF,     -- dim bullet marker
  step_num = 0x4A90D9FF,   -- accent for numbered steps
}

-- Render a single help line with smart formatting
local function draw_help_line(ctx, line, content_w)
  if type(line) == "table" then
    -- Shortcut entry: {key = "...", desc = "..."}
    reaper.ImGui_TextColored(ctx, HELP_COLORS.key, "  " .. line.key)
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextColored(ctx, COLORS.text_dim, " -")
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_PushTextWrapPos(ctx, content_w)
    reaper.ImGui_TextWrapped(ctx, " " .. line.desc)
    reaper.ImGui_PopTextWrapPos(ctx)
  elseif line == "" then
    -- Blank line: paragraph spacing
    reaper.ImGui_Dummy(ctx, 0, 3)
  elseif line:sub(1, 3) == "## " then
    -- Sub-header
    reaper.ImGui_Dummy(ctx, 0, 2)
    reaper.ImGui_TextColored(ctx, HELP_COLORS.sub_header, "  " .. line:sub(4))
    reaper.ImGui_Dummy(ctx, 0, 1)
  elseif line:sub(1, 4) == "  - " then
    -- Indented bullet
    reaper.ImGui_TextColored(ctx, HELP_COLORS.bullet, "        -")
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_PushTextWrapPos(ctx, content_w)
    reaper.ImGui_TextWrapped(ctx, " " .. line:sub(5))
    reaper.ImGui_PopTextWrapPos(ctx)
  elseif line:sub(1, 2) == "- " then
    -- Bullet item
    reaper.ImGui_TextColored(ctx, HELP_COLORS.bullet, "      -")
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_PushTextWrapPos(ctx, content_w)
    reaper.ImGui_TextWrapped(ctx, " " .. line:sub(3))
    reaper.ImGui_PopTextWrapPos(ctx)
  elseif line:match("^%d+%. ") then
    -- Numbered step
    local num, rest = line:match("^(%d+%.) (.+)")
    reaper.ImGui_TextColored(ctx, HELP_COLORS.step_num, "  " .. num)
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_PushTextWrapPos(ctx, content_w)
    reaper.ImGui_TextWrapped(ctx, " " .. rest)
    reaper.ImGui_PopTextWrapPos(ctx)
  else
    -- Normal text, indented
    reaper.ImGui_PushTextWrapPos(ctx, content_w)
    reaper.ImGui_TextWrapped(ctx, "    " .. line)
    reaper.ImGui_PopTextWrapPos(ctx)
  end
end

-- Toggle defaults: display labels for each setting
local DEFAULTS_ITEMS = {
  {key = "show_cue_markers",    label = "Show CUE markers",      tip = "Show embedded WAV cue markers when an item has them"},
  {key = "show_ghost_markers",  label = "Show ghost markers",    tip = "Show regions of other selected items sharing the same source file"},
  {key = "auto_show_envelopes", label = "Auto-show envelopes",   tip = "Show envelope overlay when an item has volume, pitch, or pan envelopes"},
  {key = "envelope_lock",       label = "Lock envelopes",        tip = "Prevent envelope points from moving when dragging item markers"},
  {key = "env_snap_enabled",    label = "Snap envelope to grid", tip = "Snap pitch envelope points to semitone values"},
}

-- Layout items: which UI panels can be hidden
local LAYOUT_ITEMS = {
  {key = "show_warp",     label = "Warp section",    tip = "WARP button, algorithm dropdowns, Clear"},
  {key = "show_buttons",  label = "Utility buttons",  tip = "x2, /2, Reverse, Edit, Loop buttons"},
  {key = "show_fx",       label = "FX section",      tip = "FX chain toolbar and bypass list"},
  {key = "show_controls", label = "Controls panel",  tip = "Gain slider, pan knob, pitch knob"},
  {key = "shaped_waveform", label = "Shaped waveform", tip = "Waveform shape follows fades, volume and pan envelopes"},
}

-- Draw Preferences tab content (formerly Defaults)
local function draw_preferences_tab(ctx, settings)
  -- Cancel listening when switching tabs
  if ui_state.listening_for then
    stop_listening(settings)
  end

  reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Toggle Defaults")
  reaper.ImGui_Dummy(ctx, 0, 4)

  for _, item in ipairs(DEFAULTS_ITEMS) do
    local val = settings.current.defaults[item.key]
    local rv, new_val = reaper.ImGui_Checkbox(ctx, item.label, val)
    if rv then
      settings.current.defaults[item.key] = new_val
      settings.save_default(item.key)
      settings_ui.defaults_changed = true
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, item.tip)
    end
  end

  reaper.ImGui_Dummy(ctx, 0, 10)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Dummy(ctx, 0, 6)
  reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Layout")
  reaper.ImGui_Dummy(ctx, 0, 4)

  for _, item in ipairs(LAYOUT_ITEMS) do
    local val = settings.current.layout[item.key]
    local rv, new_val = reaper.ImGui_Checkbox(ctx, item.label, val)
    if rv then
      settings.current.layout[item.key] = new_val
      settings.save_layout(item.key)
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_SetTooltip(ctx, item.tip)
    end
  end
end

-- Draw Help tab content
local function draw_help_tab(ctx, settings)
  -- Cancel listening when switching to Help tab
  if ui_state.listening_for then
    stop_listening(settings)
  end

  local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  if reaper.ImGui_BeginChild(ctx, "help_scroll", avail_w, avail_h) then
    local content_w = avail_w - 16  -- margin for scrollbar
    for i, section in ipairs(HELP_SECTIONS) do
      if i == 1 then
        -- Title: white, prominent, with extra spacing
        reaper.ImGui_Dummy(ctx, 0, 2)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLORS.header_text)
        reaper.ImGui_Text(ctx, "  " .. section.header)
        reaper.ImGui_PopStyleColor(ctx)
        reaper.ImGui_Dummy(ctx, 0, 1)
      else
        -- Section header: accent color, uppercase
        reaper.ImGui_Dummy(ctx, 0, 2)
        local dl = reaper.ImGui_GetWindowDrawList(ctx)
        local lx, ly = reaper.ImGui_GetCursorScreenPos(ctx)
        reaper.ImGui_DrawList_AddLine(dl, lx + 4, ly, lx + content_w - 4, ly, COLORS.separator, 1)
        reaper.ImGui_Dummy(ctx, 0, 6)
        reaper.ImGui_TextColored(ctx, COLORS.accent, "  " .. section.header:upper())
        reaper.ImGui_Dummy(ctx, 0, 3)
      end

      -- Render body lines
      for _, line in ipairs(section.lines) do
        draw_help_line(ctx, line, content_w)
      end
    end
    reaper.ImGui_Dummy(ctx, 0, 8)
    reaper.ImGui_EndChild(ctx)
  end
end

-- Main draw function
function settings_ui.draw(ctx, settings)
  if not ui_state.open then return end

  -- Periodic flush of dirty custom colors (every 0.5s) to avoid data loss on crash
  if ui_state.custom_colors_dirty then
    local now = reaper.time_precise()
    if now - ui_state.custom_save_time > 0.5 then
      local custom_theme = settings.get_theme("custom")
      if custom_theme then
        settings.save_custom_colors(custom_theme.colors)
      end
      ui_state.custom_colors_dirty = false
      ui_state.custom_save_time = now
    end
  end

  -- Center on screen (like modal)
  local viewport = reaper.ImGui_GetMainViewport(ctx)
  local vp_cx, vp_cy = reaper.ImGui_Viewport_GetCenter(viewport)
  reaper.ImGui_SetNextWindowPos(ctx, vp_cx, vp_cy, reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
  reaper.ImGui_SetNextWindowSize(ctx, 500, 680, reaper.ImGui_Cond_FirstUseEver())

  -- Style: dark theme matching modal aesthetic
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), COLORS.window_bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), COLORS.window_bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), COLORS.border)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), COLORS.btn_default)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COLORS.btn_hover)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), COLORS.btn_active)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Tab(), COLORS.tab_bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TabHovered(), COLORS.tab_hover)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TabSelected(), COLORS.tab_selected)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Separator(), COLORS.separator)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0x333333FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), 0x3D3D3DFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBg(), 0x222222FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBgActive(), 0x2A2A2AFF)
  local style_color_count = 14
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 20, 16)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 8)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 8, 8)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_TabRounding(), 4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 8, 6)
  local style_var_count = 6

  local flags = reaper.ImGui_WindowFlags_NoCollapse()
  local visible, open = reaper.ImGui_Begin(ctx, "NVSD ItemView Settings", true, flags)

  if not open then
    settings_ui.close(settings)
    reaper.ImGui_End(ctx)
    reaper.ImGui_PopStyleVar(ctx, style_var_count)
    reaper.ImGui_PopStyleColor(ctx, style_color_count)
    return
  end

  if visible then
    -- Tab bar
    if reaper.ImGui_BeginTabBar(ctx, "settings_tabs") then
      if reaper.ImGui_BeginTabItem(ctx, "Appearance") then
        reaper.ImGui_Spacing(ctx)
        draw_appearance_tab(ctx, settings)
        reaper.ImGui_EndTabItem(ctx)
      end
      if reaper.ImGui_BeginTabItem(ctx, "Shortcuts") then
        reaper.ImGui_Spacing(ctx)
        draw_shortcuts_tab(ctx, settings)
        reaper.ImGui_EndTabItem(ctx)
      end
      if reaper.ImGui_BeginTabItem(ctx, "Toolbar") then
        reaper.ImGui_Spacing(ctx)
        draw_toolbar_tab(ctx, settings)
        reaper.ImGui_EndTabItem(ctx)
      end
      if reaper.ImGui_BeginTabItem(ctx, "Preferences") then
        reaper.ImGui_Spacing(ctx)
        draw_preferences_tab(ctx, settings)
        reaper.ImGui_EndTabItem(ctx)
      end
      if reaper.ImGui_BeginTabItem(ctx, "Help") then
        reaper.ImGui_Spacing(ctx)
        draw_help_tab(ctx, settings)
        reaper.ImGui_EndTabItem(ctx)
      end
      reaper.ImGui_EndTabBar(ctx)
    end
  end

  reaper.ImGui_End(ctx)
  reaper.ImGui_PopStyleVar(ctx, style_var_count)
  reaper.ImGui_PopStyleColor(ctx, style_color_count)
end

return settings_ui
