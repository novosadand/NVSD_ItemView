-- NVSD_ItemView - Settings UI Module
-- Settings popup window with native ImGui widgets

local settings_ui = {}

-- Editable keyboard shortcuts (order matches display)
local EDITABLE_SHORTCUTS = {
  {name = "toggle_warp",  label = "Toggle WARP mode"},
  {name = "toggle_mute",  label = "Toggle mute"},
  {name = "reverse",      label = "Reverse item"},
  {name = "clear",        label = "Clear pitch/speed"},
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
  {name = "unzoom_all", label = "Unzoom completely"},
  {name = "toggle_cue_markers", label = "Toggle WAV cue markers"},
  {name = "show_in_explorer", label = "Show in Media Explorer"},
  {name = "quantize_transients", label = "Add markers at all transients"},
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
  {"Ctrl + Drag",    "Fine control on knobs/sliders"},
  {"Right-click fade", "Pick fade shape"},
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
  original_theme_id = nil,
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
  toolbar_label_buf = "",    -- text input buffer for new button label
  toolbar_cmd_buf = "",      -- text input buffer for new button command ID
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

-- Deep-copy a shortcuts table
local function deep_copy_shortcuts(shortcuts)
  local copy = {}
  for name, s in pairs(shortcuts) do
    copy[name] = {ctrl = s.ctrl, shift = s.shift, alt = s.alt, key = s.key}
  end
  return copy
end

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
  ui_state.original_theme_id = settings.current.theme_id
  ui_state.original_shortcuts = deep_copy_shortcuts(settings.current.shortcuts)
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

function settings_ui.close(settings, restore_original)
  if restore_original and settings then
    -- Restore theme
    if ui_state.original_theme_id then
      settings.current.theme_id = ui_state.original_theme_id
      settings.colors_dirty = true
    end
    -- Restore shortcuts
    if ui_state.original_shortcuts then
      settings.current.shortcuts = deep_copy_shortcuts(ui_state.original_shortcuts)
      settings.save()
    end
  end
  -- Flush any pending custom color changes to ExtState
  if ui_state.custom_colors_dirty and settings then
    local custom_theme = settings.get_theme("custom")
    if custom_theme then
      settings.save_custom_colors(custom_theme.colors)
    end
    ui_state.custom_colors_dirty = false
  end
  ui_state.open = false
  ui_state.original_theme_id = nil
  ui_state.original_shortcuts = nil
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
  if not reaper.ImGui_BeginChild(ctx, "appearance_scroll", avail_w, avail_h - 54) then return end

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
    reaper.ImGui_SetWindowFontScale(ctx, 1.15)
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
  if reaper.ImGui_BeginTable(ctx, "editable_shortcuts", 3, flags) then
    reaper.ImGui_TableSetupColumn(ctx, "Action", reaper.ImGui_TableColumnFlags_WidthStretch())
    reaper.ImGui_TableSetupColumn(ctx, "Binding", reaper.ImGui_TableColumnFlags_WidthFixed(), 120)
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

      if color_pushed > 0 then
        reaper.ImGui_PopStyleColor(ctx, color_pushed)
      end

      -- Column 3: Reset button (only if non-default)
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
    reaper.ImGui_SetWindowFontScale(ctx, 1.15)
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
    reaper.ImGui_Attach(ctx, img)
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

local function draw_toolbar_tab(ctx, settings)
  -- Cancel shortcut listening when switching to Toolbar tab
  if ui_state.listening_for then
    stop_listening(settings)
  end

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLORS.header_text)
  reaper.ImGui_Text(ctx, "Toolbar Buttons")
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_Dummy(ctx, 0, 2)
  reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Custom buttons in the info bar that trigger REAPER actions.")
  reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Click the icon cell to pick a REAPER toolbar icon.")
  reaper.ImGui_Dummy(ctx, 0, 4)

  local btns = settings.current.toolbar_buttons or {}
  local remove_idx = nil
  local move_from, move_to = nil, nil

  if #btns > 0 then
    -- Draw separator
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    local lx, ly = reaper.ImGui_GetCursorScreenPos(ctx)
    local lw = reaper.ImGui_GetContentRegionAvail(ctx)
    reaper.ImGui_DrawList_AddLine(dl, lx, ly, lx + lw, ly, COLORS.separator, 1)
    reaper.ImGui_Dummy(ctx, 0, 4)

    local tbl_flags = reaper.ImGui_TableFlags_None()
    if reaper.ImGui_BeginTable(ctx, "toolbar_btns", 6, tbl_flags) then
      reaper.ImGui_TableSetupColumn(ctx, "#", reaper.ImGui_TableColumnFlags_WidthFixed(), 20)
      reaper.ImGui_TableSetupColumn(ctx, "Icon", reaper.ImGui_TableColumnFlags_WidthFixed(), 26)
      reaper.ImGui_TableSetupColumn(ctx, "Label", reaper.ImGui_TableColumnFlags_WidthStretch())
      reaper.ImGui_TableSetupColumn(ctx, "Command", reaper.ImGui_TableColumnFlags_WidthStretch())
      reaper.ImGui_TableSetupColumn(ctx, "Move", reaper.ImGui_TableColumnFlags_WidthFixed(), 44)
      reaper.ImGui_TableSetupColumn(ctx, "Del", reaper.ImGui_TableColumnFlags_WidthFixed(), 22)

      for i, btn in ipairs(btns) do
        reaper.ImGui_TableNextRow(ctx)

        -- # column
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_TextColored(ctx, COLORS.text_dim, tostring(i) .. ".")

        -- Icon column (clickable preview)
        reaper.ImGui_TableNextColumn(ctx)
        local icon_img, icon_uv_u1
        if btn.icon then icon_img, icon_uv_u1 = get_settings_icon(ctx, btn.icon) end
        local cx, cy = reaper.ImGui_GetCursorScreenPos(ctx)
        reaper.ImGui_InvisibleButton(ctx, "##tb_icon_" .. i, 20, 20)
        local icon_dl = reaper.ImGui_GetWindowDrawList(ctx)
        local icon_hovered = reaper.ImGui_IsItemHovered(ctx)
        -- Background
        local icon_bg = icon_hovered and COLORS.btn_hover or COLORS.btn_default
        reaper.ImGui_DrawList_AddRectFilled(icon_dl, cx, cy, cx + 20, cy + 20, icon_bg, 3)
        if icon_img then
          pcall(reaper.ImGui_DrawList_AddImage, icon_dl, icon_img, cx + 2, cy + 2, cx + 18, cy + 18, 0, 0, icon_uv_u1, 1, 0xFFFFFFFF)
        else
          -- Placeholder: dotted border
          reaper.ImGui_DrawList_AddRect(icon_dl, cx + 3, cy + 3, cx + 17, cy + 17, COLORS.text_dim, 2)
        end
        if reaper.ImGui_IsItemClicked(ctx, 0) then
          ui_state.icon_picker_for = i
          ui_state.icon_picker_open = true
          if not ui_state.icon_list then
            ui_state.icon_list = settings.scan_toolbar_icons()
          end
        end
        if icon_hovered then
          reaper.ImGui_SetTooltip(ctx, btn.icon and btn.icon ~= "" and btn.icon or "Click to choose icon")
        end

        -- Label column
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_Text(ctx, btn.label)

        -- Command column
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_TextColored(ctx, COLORS.text_dim, btn.cmd)

        -- Move up/down column
        reaper.ImGui_TableNextColumn(ctx)
        if i > 1 then
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x00000000)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COLORS.btn_hover)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), COLORS.btn_active)
          if reaper.ImGui_SmallButton(ctx, "^##tb_up_" .. i) then
            move_from = i
            move_to = i - 1
          end
          reaper.ImGui_PopStyleColor(ctx, 3)
        else
          reaper.ImGui_Dummy(ctx, 12, 1)
        end
        reaper.ImGui_SameLine(ctx, 0, 2)
        if i < #btns then
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x00000000)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COLORS.btn_hover)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), COLORS.btn_active)
          if reaper.ImGui_SmallButton(ctx, "v##tb_dn_" .. i) then
            move_from = i
            move_to = i + 1
          end
          reaper.ImGui_PopStyleColor(ctx, 3)
        else
          reaper.ImGui_Dummy(ctx, 12, 1)
        end

        -- Delete column
        reaper.ImGui_TableNextColumn(ctx)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x00000000)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x66333399)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0xCC444499)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x666666FF)
        if reaper.ImGui_SmallButton(ctx, "x##tb_del_" .. i) then
          remove_idx = i
        end
        reaper.ImGui_PopStyleColor(ctx, 4)
      end

      reaper.ImGui_EndTable(ctx)
    end

    reaper.ImGui_Dummy(ctx, 0, 4)
  end

  -- Apply deferred actions
  if remove_idx then
    settings.remove_toolbar_button(remove_idx)
    if ui_state.icon_picker_for == remove_idx then
      ui_state.icon_picker_for = nil
    end
  end
  if move_from and move_to then
    settings.move_toolbar_button(move_from, move_to)
  end

  -- Icon picker popup
  if ui_state.icon_picker_open then
    reaper.ImGui_OpenPopup(ctx, "Choose Icon##icon_picker")
    ui_state.icon_picker_open = false
  end

  reaper.ImGui_SetNextWindowSize(ctx, 620, 640, reaper.ImGui_Cond_Appearing())
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(), 0x2A2A2AFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), COLORS.border)
  if reaper.ImGui_BeginPopup(ctx, "Choose Icon##icon_picker") then
    local picker_idx = ui_state.icon_picker_for
    if picker_idx and btns[picker_idx] then
      reaper.ImGui_TextColored(ctx, COLORS.header_text, "Choose icon for: " .. btns[picker_idx].label)
      reaper.ImGui_Spacing(ctx)

      -- "None" button to remove icon
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), COLORS.btn_default)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COLORS.btn_hover)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), COLORS.btn_active)
      if reaper.ImGui_Button(ctx, "None (text only)", -1, 22) then
        btns[picker_idx].icon = nil
        settings.save_toolbar()
        ui_state.icon_picker_for = nil
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
      reaper.ImGui_PopStyleColor(ctx, 3)

      reaper.ImGui_Spacing(ctx)
      local sep_dl = reaper.ImGui_GetWindowDrawList(ctx)
      local sep_x, sep_y = reaper.ImGui_GetCursorScreenPos(ctx)
      local sep_w = reaper.ImGui_GetContentRegionAvail(ctx)
      reaper.ImGui_DrawList_AddLine(sep_dl, sep_x, sep_y, sep_x + sep_w, sep_y, COLORS.separator, 1)
      reaper.ImGui_Dummy(ctx, 0, 4)

      local icons = ui_state.icon_list or {}
      if #icons == 0 then
        reaper.ImGui_TextColored(ctx, COLORS.text_dim, "No toolbar icons found.")
        reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Install icon packs in REAPER's")
        reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Data/toolbar_icons/ directory.")
      else
        local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
        local scrollbar_w = 14
        local grid_w = avail_w - scrollbar_w
        local cell_size = 42
        local cell_gap = 3
        local cols = math.max(1, math.floor((grid_w + cell_gap) / (cell_size + cell_gap)))

        if reaper.ImGui_BeginChild(ctx, "icon_grid", avail_w, avail_h) then
          local grid_dl = reaper.ImGui_GetWindowDrawList(ctx)
          for idx, filename in ipairs(icons) do
            if (idx - 1) % cols ~= 0 then
              reaper.ImGui_SameLine(ctx, 0, cell_gap)
            end

            local img, grid_uv_u1 = get_settings_icon(ctx, filename)
            local gx, gy = reaper.ImGui_GetCursorScreenPos(ctx)
            reaper.ImGui_PushID(ctx, idx)
            reaper.ImGui_InvisibleButton(ctx, "##icon", cell_size, cell_size)
            local hovered = reaper.ImGui_IsItemHovered(ctx)
            local clicked = reaper.ImGui_IsItemClicked(ctx, 0)

            -- Background (subtle so icons stand out)
            local bg = hovered and COLORS.btn_hover or 0x333333FF
            reaper.ImGui_DrawList_AddRectFilled(grid_dl, gx, gy, gx + cell_size, gy + cell_size, bg, 4)
            -- Draw icon (first sprite state only)
            if img then
              local pad = 4
              pcall(reaper.ImGui_DrawList_AddImage, grid_dl, img, gx + pad, gy + pad, gx + cell_size - pad, gy + cell_size - pad, 0, 0, grid_uv_u1 or 1, 1, 0xFFFFFFFF)
            end

            if hovered then
              reaper.ImGui_SetTooltip(ctx, filename)
            end
            if clicked then
              btns[picker_idx].icon = filename
              settings.save_toolbar()
              ui_state.icon_picker_for = nil
              reaper.ImGui_PopID(ctx)
              reaper.ImGui_CloseCurrentPopup(ctx)
              break
            end
            reaper.ImGui_PopID(ctx)
          end
          reaper.ImGui_EndChild(ctx)
        end
      end
    else
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  else
    -- Popup was closed externally
    if ui_state.icon_picker_for then
      ui_state.icon_picker_for = nil
    end
  end
  reaper.ImGui_PopStyleColor(ctx, 2)

  -- Add section separator
  local dl2 = reaper.ImGui_GetWindowDrawList(ctx)
  local lx2, ly2 = reaper.ImGui_GetCursorScreenPos(ctx)
  local lw2 = reaper.ImGui_GetContentRegionAvail(ctx)
  reaper.ImGui_DrawList_AddLine(dl2, lx2, ly2, lx2 + lw2, ly2, COLORS.separator, 1)
  reaper.ImGui_Dummy(ctx, 0, 6)

  -- Add new button inputs
  reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Label:")
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 100)
  local _, new_label = reaper.ImGui_InputText(ctx, "##tb_label", ui_state.toolbar_label_buf)
  ui_state.toolbar_label_buf = new_label

  reaper.ImGui_SameLine(ctx, 0, 8)
  reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Action ID:")
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 100)
  local _, new_cmd = reaper.ImGui_InputText(ctx, "##tb_cmd", ui_state.toolbar_cmd_buf)
  ui_state.toolbar_cmd_buf = new_cmd

  reaper.ImGui_SameLine(ctx, 0, 8)
  local can_add = ui_state.toolbar_label_buf ~= "" and ui_state.toolbar_cmd_buf ~= ""
  if not can_add then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), COLORS.btn_default)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COLORS.btn_default)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), COLORS.btn_default)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLORS.text_dim)
  else
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), COLORS.accent)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COLORS.accent_hover)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), COLORS.accent_active)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLORS.header_text)
  end
  if reaper.ImGui_Button(ctx, "+ Add") and can_add then
    settings.add_toolbar_button(ui_state.toolbar_label_buf, ui_state.toolbar_cmd_buf)
    ui_state.toolbar_label_buf = ""
    ui_state.toolbar_cmd_buf = ""
  end
  reaper.ImGui_PopStyleColor(ctx, 4)

  reaper.ImGui_Dummy(ctx, 0, 4)
  reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Paste a REAPER action Command ID or Named Command.")
  reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Find them in REAPER: Actions > Show action list.")
end

-- Help content sections (header + body pairs)
local HELP_SECTIONS = {
  {
    header = "NVSD ItemView",
    body = "Ableton-style clip view for REAPER audio items.\nSelect an audio item, run the script, and edit start/end points, gain, pitch, envelopes, and more.",
  },
  {
    header = "QUICK START",
    body = "1. Select an audio item in REAPER\n2. Run the script (Actions > NVSD_ItemView)\n3. Drag the colored markers to adjust start/end points\n4. Use the left panel for gain, pitch, reverse, WARP, and FX\n5. Press Esc to close the script",
  },
  {
    header = "WAVEFORM CONTROLS",
    body = "Ctrl+Scroll: Zoom in/out\nMiddle-drag: Pan waveform\nRuler drag vertical: Zoom\nRuler drag horizontal: Pan\nSet start/end markers and fade positions via configurable shortcuts (see Shortcuts tab, default: Mouse 4/5)\nLeft-click+drag: Select time region\nC: Crop item to selected region (moves markers to selection bounds)\nZ: Zoom to selection or markers (press again to restore previous zoom)\nAlt+Z: Unzoom completely\nCtrl+C: Copy selected region to clipboard\nDrag markers past source boundaries to create loops.",
  },
  {
    header = "MARKERS",
    body = "Drag the start/end markers to adjust playback region.\nAlt+drag either marker to slide both together.\nMarkers snap to grid when snap is enabled.\nDrag past source boundaries to extend into looped playback.",
  },
  {
    header = "LEFT PANEL",
    body = "Gain slider: Drag to adjust volume (+24dB to -inf). Ctrl+drag for fine control. Double-click to reset.\nPitch knob: Drag to adjust pitch (±48 semitones). Double-click to reset.\nPan knob: Drag to adjust pan. Double-click to reset.\nSemitones/Cents boxes: Click+drag to adjust. Double-click to reset.\nShift+drag any control for fine adjustment.\nWARP button: Toggle pitch preservation when stretching.\nAlgorithm dropdown: Select pitch shift algorithm (when WARP is on).\nReverse button: Reverse the audio.\nClear button: Reset pitch, rate, WARP to defaults.\nEdit button: Open in external editor (or Item Properties if none configured).\nMute checkbox: Toggle item mute.",
  },
  {
    header = "ENVELOPES",
    body = "Shift+V: Show Volume envelope\nShift+H: Show Pitch envelope\nShift+P: Show Pan envelope\nH: Hide envelopes\nL: Lock envelopes in place\n\nDrag nodes to move them. Alt+click to delete.\nDrag segments to move them vertically.\nAlt+drag segments to adjust curve tension.\nShift+click segment to add a node.\nCtrl+drag on empty area for freehand drawing.\nRight-drag to rectangle-select nodes.\nDelete key removes selected nodes.",
  },
  {
    header = "FADES",
    body = "Drag fade handles at item edges to adjust fade in/out length.\nSet fade positions via configurable shortcuts (see Shortcuts tab, default: Shift+Mouse 4/5).\nAlt+drag fade curve to adjust curve tension.\nRight-click fade handle to pick fade shape.\nFade shapes: Linear, Fast Start, Fast End, Fast Start Steep, Fast End Steep, Slow Start/End, Slow Start/End Steep.",
  },
  {
    header = "AUDIO PREVIEW",
    body = "Ctrl+Space: Preview audio from cursor position.\nRequires SWS extension installed.",
  },
  {
    header = "FX TOOLBAR",
    body = "Left button: Toggle all FX bypass (when FX exist) / Add FX (when empty)\nRight button: Open FX chain window / Alt+click to remove all FX",
  },
  {
    header = "FX LIST",
    body = "Click: Open/close individual FX window\nShift+click: Toggle individual FX bypass\nAlt+click: Delete individual FX\nAlt+click FX button: Remove all FX\nCheckbox: Toggle individual FX bypass\nDrag up/down: Reorder FX chain\nRight-click: Context menu (Bypass/Enable, Set Offline/Online, Open Chain, Delete)\nScroll: Mouse wheel to scroll long FX lists",
  },
  {
    header = "KEYBOARD SHORTCUTS",
    body = "All keyboard shortcuts can be rebound in the Shortcuts tab.\nDefault shortcuts:\n  W: Toggle WARP mode\n  Num0: Toggle mute\n  M: Toggle WAV cue markers\n  R: Reverse item\n  C: Crop markers to selection\n  Shift+C: Clear pitch/speed\n  Ctrl+Alt+E: Open in external editor\n  F: Reset zoom to fit\n  Z: Zoom to selection / markers (toggle)\n  Alt+Z: Unzoom completely\n  +/-: Zoom in/out\n  Ctrl+4: Toggle envelope snap\n  L: Lock envelopes\n  Shift+V/H/P: Show Volume/Pitch/Pan envelope\n  H: Hide envelopes\n  Ctrl+Space: Audio preview\n  S: Open settings\n  Space: Play/Stop\n  Ctrl+Z/Y: Undo/Redo\n  Ctrl+C: Copy region",
  },
  {
    header = "WAV CUE MARKERS",
    body = "M: Toggle display of embedded WAV cue markers\n\nSome WAV files contain embedded cue points (markers with labels). These appear as vertical dashed lines with text labels on the waveform.\nThe CUE button in the info bar appears when the current file has cue markers.\nRequires SWS extension.",
  },
  {
    header = "TIPS",
    body = "Map the script to a REAPER action shortcut (Actions > Show action list > search NVSD) for quick toggle on/off.\nRight-click the title bar to dock the window anywhere.\nGain changes are non-destructive and can be undone.\nWARP mode stretches audio to fit markers without pitch change.\nClick the filename in the info bar to show it in REAPER's Media Explorer.\nHover over any element for a tooltip with available actions.\nAll settings persist between sessions via ExtState.",
  },
}

-- Draw Help tab content
local function draw_help_tab(ctx, settings)
  -- Cancel listening when switching to Help tab
  if ui_state.listening_for then
    stop_listening(settings)
  end

  local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  if reaper.ImGui_BeginChild(ctx, "help_scroll", avail_w, avail_h - 54) then
    for i, section in ipairs(HELP_SECTIONS) do
      if i == 1 then
        -- Title section: white, prominent
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLORS.header_text)
        reaper.ImGui_Text(ctx, section.header)
        reaper.ImGui_PopStyleColor(ctx)
      else
        -- Section header: accent color
        reaper.ImGui_TextColored(ctx, COLORS.accent, section.header)
      end
      reaper.ImGui_Dummy(ctx, 0, 2)
      reaper.ImGui_TextWrapped(ctx, section.body)
      if i < #HELP_SECTIONS then
        reaper.ImGui_Dummy(ctx, 0, 4)
        local dl = reaper.ImGui_GetWindowDrawList(ctx)
        local lx, ly = reaper.ImGui_GetCursorScreenPos(ctx)
        local lw = reaper.ImGui_GetContentRegionAvail(ctx)
        reaper.ImGui_DrawList_AddLine(dl, lx, ly, lx + lw, ly, COLORS.separator, 1)
        reaper.ImGui_Dummy(ctx, 0, 6)
      end
    end
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
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), COLORS.child_bg)
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
    settings_ui.close(settings, true)
    reaper.ImGui_End(ctx)
    reaper.ImGui_PopStyleVar(ctx, style_var_count)
    reaper.ImGui_PopStyleColor(ctx, style_color_count)
    return
  end

  reaper.ImGui_SetWindowFontScale(ctx, 1.15)

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
      if reaper.ImGui_BeginTabItem(ctx, "Help") then
        reaper.ImGui_Spacing(ctx)
        draw_help_tab(ctx, settings)
        reaper.ImGui_EndTabItem(ctx)
      end
      reaper.ImGui_EndTabBar(ctx)
    end

    -- Bottom buttons
    reaper.ImGui_Spacing(ctx)
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    local sx, sy = reaper.ImGui_GetCursorScreenPos(ctx)
    local content_w = reaper.ImGui_GetContentRegionAvail(ctx)
    reaper.ImGui_DrawList_AddLine(draw_list, sx, sy, sx + content_w, sy, COLORS.separator, 1)
    reaper.ImGui_Dummy(ctx, 0, 6)

    -- Reset Defaults (subtle, left)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x00000000)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x00000000)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x00000000)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COLORS.text_dim)
    if reaper.ImGui_SmallButton(ctx, "Reset Defaults") then
      settings.reset_all()
      ui_state.pending_theme_id = settings.current.theme_id
      stop_listening(settings)
      ui_state.conflict_pending = nil
      ui_state.conflict_just_cleared = nil
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      local ix, iy = reaper.ImGui_GetItemRectMin(ctx)
      local ix2, iy2 = reaper.ImGui_GetItemRectMax(ctx)
      reaper.ImGui_DrawList_AddLine(draw_list, ix, iy2, ix2, iy2, COLORS.text_dim, 1)
    end
    reaper.ImGui_PopStyleColor(ctx, 4)

    -- Right-aligned Cancel + Save & Close
    local cancel_w = 80
    local save_w = 120
    local btn_gap = 8
    local btn_h = 30
    local win_w = reaper.ImGui_GetWindowWidth(ctx)
    local padding = 20
    local buttons_width = cancel_w + btn_gap + save_w

    reaper.ImGui_SameLine(ctx, win_w - padding - buttons_width)

    -- Cancel (grey, subtle)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), COLORS.btn_default)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COLORS.btn_hover)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), COLORS.btn_active)
    if reaper.ImGui_Button(ctx, "Cancel", cancel_w, btn_h) then
      settings_ui.close(settings, true)
    end
    reaper.ImGui_PopStyleColor(ctx, 3)

    reaper.ImGui_SameLine(ctx, 0, btn_gap)

    -- Save & Close (accent, primary)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), COLORS.accent)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COLORS.accent_hover)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), COLORS.accent_active)
    if reaper.ImGui_Button(ctx, "Save & Close", save_w, btn_h) then
      -- Theme still uses pending (live preview), shortcuts already applied
      settings.current.theme_id = ui_state.pending_theme_id
      settings.colors_dirty = true
      settings.save()
      settings_ui.close(settings, false)
    end
    reaper.ImGui_PopStyleColor(ctx, 3)
  end

  reaper.ImGui_End(ctx)
  reaper.ImGui_PopStyleVar(ctx, style_var_count)
  reaper.ImGui_PopStyleColor(ctx, style_color_count)
end

return settings_ui
