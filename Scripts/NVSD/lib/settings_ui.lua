-- NVSD_ItemView - Settings UI Module
-- Settings popup window with native ImGui widgets

local settings_ui = {}

-- Editable keyboard shortcuts (order matches display)
local EDITABLE_SHORTCUTS = {
  {name = "toggle_warp",  label = "Toggle WARP mode"},
  {name = "toggle_mute",  label = "Toggle mute"},
  {name = "reverse",      label = "Reverse item"},
  {name = "clear",        label = "Clear pitch/speed"},
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
  {"Drag Marker",    "Move start/end point"},
  {"Alt + Drag",     "Slide both markers"},
  {"Mouse 4",        "Set start at cursor"},
  {"Mouse 5",        "Set end at cursor"},
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
  pending_shortcuts = nil,   -- Deep copy of shortcuts, applied only on Save
  listening_for = nil,       -- Shortcut name being captured, or nil
  conflict_warning = nil,    -- {shortcut = name, text = "..."} or nil
  conflict_clear_time = 0,   -- Frame counter for auto-clearing warning
  custom_init_from = 0,      -- Index for "Initialize from" combo
  custom_colors_dirty = false, -- True when custom colors changed but not yet saved to ExtState
  custom_save_time = 0,      -- Debounce: time of last deferred save request
  save_theme_name = "",      -- Text input buffer for "Save as theme" name
  show_save_input = false,   -- Show the name input field
  delete_confirm_id = nil,   -- Theme ID pending deletion confirmation
  hovered_theme_id = nil,    -- Theme ID currently hovered (for delete button)
}

-- Colors matching main window dark theme
local COLORS = {
  window_bg = 0x1E1E1EFF,
  child_bg = 0x252525FF,
  text = 0xDDDDDDFF,
  text_dim = 0x888888FF,
  accent = 0x4A90D9FF,
  accent_hover = 0x5AA0E9FF,
  btn_default = 0x404040FF,
  btn_hover = 0x505050FF,
  separator = 0x404040FF,
  warning = 0xFF4444FF,
  unbound = 0x666666FF,
}

-- Deep-copy a shortcuts table
local function deep_copy_shortcuts(shortcuts)
  local copy = {}
  for name, s in pairs(shortcuts) do
    copy[name] = {ctrl = s.ctrl, shift = s.shift, alt = s.alt, key = s.key}
  end
  return copy
end

-- Initialize pending values from current settings
local function init_pending(settings)
  ui_state.pending_theme_id = settings.current.theme_id
  ui_state.original_theme_id = settings.current.theme_id
  ui_state.pending_shortcuts = deep_copy_shortcuts(settings.current.shortcuts)
  ui_state.listening_for = nil
  ui_state.conflict_warning = nil
  ui_state.conflict_clear_time = 0
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
  if restore_original and settings and ui_state.original_theme_id then
    settings.current.theme_id = ui_state.original_theme_id
    settings.colors_dirty = true
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
  ui_state.pending_shortcuts = nil
  ui_state.listening_for = nil
  ui_state.conflict_warning = nil
  settings.listening = false
end

function settings_ui.is_open()
  return ui_state.open
end

-- Draw a small color swatch using DrawList
local function draw_swatch(ctx, color, size)
  local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
  local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + size, y + size, color, 2)
  reaper.ImGui_DrawList_AddRect(draw_list, x, y, x + size, y + size, 0x00000044, 2)
  reaper.ImGui_Dummy(ctx, size, size)
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

-- Auto-derive: each core color cascades to its related colors
-- Factor < 1.0 = darken (multiply), > 1.0 = lighten (blend toward white), 1.0 = same
local AUTO_DERIVE = {
  waveform_bg   = {
    {"centerline", 1.55}, {"ruler_bg", 1.33}, {"info_bar_bg", 1.1},
    {"grid_bar", 1.93}, {"grid_beat", 1.41},
  },
  waveform      = {{"waveform_inactive", 0.65}, {"border", 0.85}},
  markers       = {
    {"markers_hover", 1.12}, {"playhead", 1.0}, {"btn_on", 1.0},
    {"btn_hover", 1.08}, {"info_bar_icon", 1.0},
  },
  info_bar_text = {{"ruler_text", 0.79}, {"ruler_tick", 0.55}, {"btn_off", 0.37}},
}

-- Apply all derivations for a changed color key
local function apply_auto_derive(colors, key)
  local derived_list = AUTO_DERIVE[key]
  if derived_list then
    for _, d in ipairs(derived_list) do
      colors[d[1]] = derive_color(colors[key], d[2])
    end
  end
end

-- Draw custom theme color editor (4 core colors + initialize from)
local function draw_custom_color_editor(ctx, settings)
  local custom_theme = settings.get_theme("custom")
  if not custom_theme then return end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)

  -- "Initialize from" combo: copy all colors from a preset theme
  reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Initialize from:")
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, 150)
  if reaper.ImGui_BeginCombo(ctx, "##init_from", settings.THEMES[ui_state.custom_init_from + 1] and settings.THEMES[ui_state.custom_init_from + 1].name or "Select...") then
    for i, theme in ipairs(settings.THEMES) do
      if theme.id ~= "custom" then
        if reaper.ImGui_Selectable(ctx, theme.name, ui_state.custom_init_from == i - 1) then
          ui_state.custom_init_from = i - 1
          -- Copy all colors from selected theme
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

  -- 4 core color pickers (all derived colors update automatically)
  local edit_flags = reaper.ImGui_ColorEditFlags_NoInputs()

  for _, entry in ipairs(CORE_COLORS) do
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
end

-- Draw Appearance tab content
local function draw_appearance_tab(ctx, settings)
  -- Cancel listening when switching to Appearance tab
  if ui_state.listening_for then
    stop_listening(settings)
  end

  local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  if not reaper.ImGui_BeginChild(ctx, "appearance_scroll", avail_w, avail_h - 40) then return end

  reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Theme")
  reaper.ImGui_Spacing(ctx)

  local prev_was_user = false
  for _, theme in ipairs(settings.THEMES) do
    if prev_was_user and not theme.user_theme then
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_Spacing(ctx)
      prev_was_user = false
    end
    if theme.user_theme then prev_was_user = true end
    local is_selected = ui_state.pending_theme_id == theme.id

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
      settings.current.theme_id = theme.id  -- Live preview
      settings.colors_dirty = true
    end

    -- Color swatches on the same line
    reaper.ImGui_SameLine(ctx, 160)
    draw_swatch(ctx, theme.colors.waveform, 12)
    reaper.ImGui_SameLine(ctx, 0, 4)
    draw_swatch(ctx, theme.colors.markers, 12)
    reaper.ImGui_SameLine(ctx, 0, 4)
    draw_swatch(ctx, theme.colors.playhead, 12)

    -- Description + delete button for user themes
    reaper.ImGui_SameLine(ctx, 220)
    if theme.user_theme then
      reaper.ImGui_TextColored(ctx, COLORS.text_dim, theme.description)
      -- Delete button (small X) on the same line
      reaper.ImGui_SameLine(ctx, 0, 8)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x00000000)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x66333399)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0xCC444499)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x999999FF)
      if reaper.ImGui_SmallButton(ctx, "x##del_" .. theme.id) then
        ui_state.delete_confirm_id = theme.id
        reaper.ImGui_OpenPopup(ctx, "Delete Theme?##confirm")
      end
      reaper.ImGui_PopStyleColor(ctx, 4)
    else
      reaper.ImGui_TextColored(ctx, COLORS.text_dim, theme.description)
    end
  end

  -- Delete confirmation modal
  if reaper.ImGui_BeginPopupModal(ctx, "Delete Theme?##confirm", nil, reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
    local del_theme = ui_state.delete_confirm_id and settings.get_theme(ui_state.delete_confirm_id)
    local del_name = del_theme and del_theme.name or "this theme"
    reaper.ImGui_Text(ctx, "Delete \"" .. del_name .. "\"?")
    reaper.ImGui_Spacing(ctx)
    if reaper.ImGui_Button(ctx, "Delete", 80, 0) then
      if ui_state.delete_confirm_id then
        -- If we're deleting the active theme, switch to default
        if ui_state.pending_theme_id == ui_state.delete_confirm_id then
          ui_state.pending_theme_id = "default"
          settings.current.theme_id = "default"
          settings.colors_dirty = true
        end
        settings.delete_user_theme(ui_state.delete_confirm_id)
        ui_state.delete_confirm_id = nil
      end
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Cancel", 80, 0) then
      ui_state.delete_confirm_id = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  end

  -- Custom theme color editor + save (only shown when Custom is selected)
  if ui_state.pending_theme_id == "custom" then
    draw_custom_color_editor(ctx, settings)

    -- Save as new theme
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    if ui_state.show_save_input then
      reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Name:")
      reaper.ImGui_SameLine(ctx)
      -- Auto-focus the input on first frame (must be before the widget)
      if not ui_state.save_input_focused then
        reaper.ImGui_SetKeyboardFocusHere(ctx, 0)
        ui_state.save_input_focused = true
      end
      reaper.ImGui_SetNextItemWidth(ctx, 150)
      local _, new_name = reaper.ImGui_InputText(ctx, "##save_theme_name", ui_state.save_theme_name)
      ui_state.save_theme_name = new_name
      reaper.ImGui_SameLine(ctx)
      local name_ok = ui_state.save_theme_name ~= ""
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
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Cancel##save_cancel") then
        ui_state.show_save_input = false
        ui_state.save_theme_name = ""
        ui_state.save_input_focused = nil
      end
    else
      if reaper.ImGui_Button(ctx, "Save current as new theme") then
        ui_state.show_save_input = true
        ui_state.save_theme_name = ""
        ui_state.save_input_focused = nil
      end
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
      ui_state.pending_shortcuts[ui_state.listening_for] = {
        ctrl = false, shift = false, alt = false, key = ""
      }
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
          ui_state.pending_shortcuts, ui_state.listening_for, binding)
        if conflict then
          ui_state.conflict_warning = {
            shortcut = ui_state.listening_for,
            text = "Conflicts with " .. get_shortcut_label(conflict),
          }
          ui_state.conflict_clear_time = 180  -- ~3 seconds at 60fps
        end

        -- Apply binding regardless of conflict
        ui_state.pending_shortcuts[ui_state.listening_for] = binding
        stop_listening(settings)
      end
    end
  end

  -- Auto-clear conflict warning
  if ui_state.conflict_warning then
    ui_state.conflict_clear_time = ui_state.conflict_clear_time - 1
    if ui_state.conflict_clear_time <= 0 then
      ui_state.conflict_warning = nil
    end
  end

  -- Editable shortcuts header
  reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Keyboard Shortcuts")
  reaper.ImGui_Spacing(ctx)

  local flags = reaper.ImGui_TableFlags_None()
  if reaper.ImGui_BeginTable(ctx, "editable_shortcuts", 3, flags) then
    reaper.ImGui_TableSetupColumn(ctx, "Action", reaper.ImGui_TableColumnFlags_WidthStretch())
    reaper.ImGui_TableSetupColumn(ctx, "Binding", reaper.ImGui_TableColumnFlags_WidthFixed(), 120)
    reaper.ImGui_TableSetupColumn(ctx, "Reset", reaper.ImGui_TableColumnFlags_WidthFixed(), 30)

    for _, entry in ipairs(EDITABLE_SHORTCUTS) do
      local name = entry.name
      local shortcut = ui_state.pending_shortcuts[name]
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

      -- Conflict indicator
      if ui_state.conflict_warning and ui_state.conflict_warning.shortcut == name then
        reaper.ImGui_TextColored(ctx, COLORS.warning, "!")
        if reaper.ImGui_IsItemHovered(ctx) then
          reaper.ImGui_SetTooltip(ctx, ui_state.conflict_warning.text)
        end
        reaper.ImGui_SameLine(ctx)
      end

      reaper.ImGui_Text(ctx, entry.label)

      -- Column 2: Binding button
      reaper.ImGui_TableNextColumn(ctx)

      local btn_label
      local btn_color
      if is_listening then
        btn_label = "Press a key..."
        btn_color = COLORS.accent
      elseif is_unbound then
        btn_label = "---"
        btn_color = COLORS.unbound
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
        end
      end

      if color_pushed > 0 then
        reaper.ImGui_PopStyleColor(ctx, color_pushed)
      end

      -- Column 3: Reset button (only if non-default)
      reaper.ImGui_TableNextColumn(ctx)
      if not is_default then
        if reaper.ImGui_SmallButton(ctx, "R##reset_" .. name) then
          if default then
            ui_state.pending_shortcuts[name] = {
              ctrl = default.ctrl, shift = default.shift,
              alt = default.alt, key = default.key,
            }
          end
          -- Clear conflict if it was on this shortcut
          if ui_state.conflict_warning and ui_state.conflict_warning.shortcut == name then
            ui_state.conflict_warning = nil
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

  -- Helper text
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Escape to cancel  /  Backspace to clear")

  -- Mouse reference section
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Reference (not rebindable)")
  reaper.ImGui_Spacing(ctx)

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
    body = "Ctrl+Scroll: Zoom in/out\nMiddle-drag: Pan waveform\nRuler drag vertical: Zoom\nRuler drag horizontal: Pan\nMouse 4: Set start at cursor\nMouse 5: Set end at cursor\nShift+Mouse4: Set fade-in end at cursor\nShift+Mouse5: Set fade-out start at cursor\nLeft-click+drag: Select time region\nCtrl+C: Copy selected region to clipboard\nDrag markers past source boundaries to create loops.",
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
    body = "Drag fade handles at item edges to adjust fade in/out length.\nShift+Mouse4: Set fade-in end at cursor position.\nShift+Mouse5: Set fade-out start at cursor position.\nAlt+drag fade curve to adjust curve tension.\nRight-click fade handle to pick fade shape.\nFade shapes: Linear, Fast Start, Fast End, Fast Start Steep, Fast End Steep, Slow Start/End, Slow Start/End Steep.",
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
    body = "Click: Open/close individual FX window\nShift+click: Toggle individual FX bypass\nAlt+click: Delete individual FX\nCheckbox: Toggle individual FX bypass\nDrag up/down: Reorder FX chain\nRight-click: Context menu (Bypass/Enable, Set Offline/Online, Open Chain, Delete)\nScroll: Mouse wheel to scroll long FX lists",
  },
  {
    header = "KEYBOARD SHORTCUTS",
    body = "All keyboard shortcuts can be rebound in the Shortcuts tab.\nDefault shortcuts:\n  W: Toggle WARP mode\n  M: Toggle mute\n  R: Reverse item\n  C: Clear pitch/speed\n  E: Open in external editor\n  F: Reset zoom to fit\n  +/-: Zoom in/out\n  Ctrl+4: Toggle envelope snap\n  L: Lock envelopes\n  Shift+V/H/P: Show Volume/Pitch/Pan envelope\n  H: Hide envelopes\n  Ctrl+Space: Audio preview\n  S: Open settings\n  Space: Play/Stop\n  Ctrl+Z/Y: Undo/Redo\n  Ctrl+C: Copy region",
  },
  {
    header = "TIPS",
    body = "Map the script to a REAPER action shortcut (Actions > Show action list > search NVSD) for quick toggle on/off.\nRight-click the title bar to dock the window anywhere.\nGain changes are non-destructive and can be undone.\nWARP mode stretches audio to fit markers without pitch change.\nClick the filename in the info bar to show the file in Explorer/Finder.\nHover over any element for a tooltip with available actions.\nAll settings persist between sessions via ExtState.",
  },
}

-- Draw Help tab content
local function draw_help_tab(ctx, settings)
  -- Cancel listening when switching to Help tab
  if ui_state.listening_for then
    stop_listening(settings)
  end

  local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
  if reaper.ImGui_BeginChild(ctx, "help_scroll", avail_w, avail_h - 40) then
    for i, section in ipairs(HELP_SECTIONS) do
      if i == 1 then
        -- Title section: use accent color
        reaper.ImGui_TextColored(ctx, COLORS.accent, section.header)
      else
        -- Section header: dim color
        reaper.ImGui_TextColored(ctx, COLORS.text_dim, section.header)
      end
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_TextWrapped(ctx, section.body)
      reaper.ImGui_Spacing(ctx)
      if i < #HELP_SECTIONS then
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Spacing(ctx)
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

  reaper.ImGui_SetNextWindowSize(ctx, 420, 600, reaper.ImGui_Cond_FirstUseEver())

  -- Style: dark background matching main window
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), COLORS.window_bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), COLORS.child_bg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), COLORS.btn_default)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COLORS.btn_hover)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Tab(), COLORS.btn_default)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TabHovered(), COLORS.accent_hover)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TabSelected(), COLORS.accent)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 12, 12)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 4)

  local flags = reaper.ImGui_WindowFlags_NoCollapse()
  local visible, open = reaper.ImGui_Begin(ctx, "NVSD ItemView Settings", true, flags)

  if not open then
    settings_ui.close(settings, true)
    reaper.ImGui_End(ctx)
    reaper.ImGui_PopStyleVar(ctx, 2)
    reaper.ImGui_PopStyleColor(ctx, 7)
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
      if reaper.ImGui_BeginTabItem(ctx, "Help") then
        reaper.ImGui_Spacing(ctx)
        draw_help_tab(ctx, settings)
        reaper.ImGui_EndTabItem(ctx)
      end
      reaper.ImGui_EndTabBar(ctx)
    end

    -- Bottom buttons
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Spacing(ctx)

    -- Reset Defaults (left)
    if reaper.ImGui_Button(ctx, "Reset Defaults") then
      settings.reset_all()
      ui_state.pending_theme_id = settings.current.theme_id
      ui_state.pending_shortcuts = deep_copy_shortcuts(settings.current.shortcuts)
      stop_listening(settings)
      ui_state.conflict_warning = nil
    end

    -- Right-aligned Cancel + Save & Close
    local cancel_w = 70
    local save_w = 110
    local btn_gap = 8
    local win_w = reaper.ImGui_GetWindowWidth(ctx)
    local padding = 12
    local buttons_width = cancel_w + btn_gap + save_w

    reaper.ImGui_SameLine(ctx, win_w - padding - buttons_width)

    -- Cancel
    if reaper.ImGui_Button(ctx, "Cancel", cancel_w) then
      settings_ui.close(settings, true)
    end

    reaper.ImGui_SameLine(ctx, 0, btn_gap)

    -- Save & Close (accent colored)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), COLORS.accent)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COLORS.accent_hover)
    if reaper.ImGui_Button(ctx, "Save & Close", save_w) then
      settings.apply({
        theme_id = ui_state.pending_theme_id,
        shortcuts = ui_state.pending_shortcuts,
      })
      settings_ui.close(settings, false)
    end
    reaper.ImGui_PopStyleColor(ctx, 2)
  end

  reaper.ImGui_End(ctx)
  reaper.ImGui_PopStyleVar(ctx, 2)
  reaper.ImGui_PopStyleColor(ctx, 7)
end

return settings_ui
