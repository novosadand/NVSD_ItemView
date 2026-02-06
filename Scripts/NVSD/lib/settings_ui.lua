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
}

-- Static mouse actions (not editable, reference only)
local MOUSE_SHORTCUTS = {
  {"Ctrl + Scroll",  "Zoom in/out"},
  {"Middle Drag",    "Pan waveform"},
  {"Ruler Drag",     "Zoom + Pan"},
  {"Drag Marker",    "Move start/end point"},
  {"Alt + Drag",     "Slide both markers"},
  {"Mouse 4",        "Set start at cursor"},
  {"Mouse 5",        "Set end at cursor"},
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

-- Draw Appearance tab content
local function draw_appearance_tab(ctx, settings)
  -- Cancel listening when switching to Appearance tab
  if ui_state.listening_for then
    stop_listening(settings)
  end

  reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Theme")
  reaper.ImGui_Spacing(ctx)

  for _, theme in ipairs(settings.THEMES) do
    local is_selected = ui_state.pending_theme_id == theme.id

    if reaper.ImGui_RadioButton(ctx, theme.name, is_selected) then
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

    -- Description
    reaper.ImGui_SameLine(ctx, 220)
    reaper.ImGui_TextColored(ctx, COLORS.text_dim, theme.description)
  end
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
  reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Mouse Actions (not editable)")
  reaper.ImGui_Spacing(ctx)

  if reaper.ImGui_BeginTable(ctx, "mouse_shortcuts", 2, reaper.ImGui_TableFlags_None()) then
    reaper.ImGui_TableSetupColumn(ctx, "Key", reaper.ImGui_TableColumnFlags_WidthFixed(), 120)
    reaper.ImGui_TableSetupColumn(ctx, "Action", reaper.ImGui_TableColumnFlags_WidthStretch())

    for _, entry in ipairs(MOUSE_SHORTCUTS) do
      reaper.ImGui_TableNextRow(ctx)
      reaper.ImGui_TableNextColumn(ctx)
      reaper.ImGui_TextColored(ctx, COLORS.accent, "  " .. entry[1])
      reaper.ImGui_TableNextColumn(ctx)
      reaper.ImGui_Text(ctx, entry[2])
    end

    reaper.ImGui_EndTable(ctx)
  end
end

-- Main draw function
function settings_ui.draw(ctx, settings)
  if not ui_state.open then return end

  reaper.ImGui_SetNextWindowSize(ctx, 380, 560, reaper.ImGui_Cond_FirstUseEver())

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
