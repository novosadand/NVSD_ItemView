-- NVSD_ItemView - Settings UI Module
-- Settings popup window with native ImGui widgets

local settings_ui = {}

-- UI State
local ui_state = {
  open = false,
  pending_theme_id = nil,
  original_theme_id = nil,
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
}

-- Initialize pending values from current settings
local function init_pending(settings)
  ui_state.pending_theme_id = settings.current.theme_id
  ui_state.original_theme_id = settings.current.theme_id
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

-- Draw Shortcuts tab content
local function draw_shortcuts_tab(ctx)
  local flags = reaper.ImGui_TableFlags_None()
  if reaper.ImGui_BeginTable(ctx, "shortcuts", 2, flags) then
    reaper.ImGui_TableSetupColumn(ctx, "Key", reaper.ImGui_TableColumnFlags_WidthFixed(), 120)
    reaper.ImGui_TableSetupColumn(ctx, "Action", reaper.ImGui_TableColumnFlags_WidthStretch())

    -- Item Actions section
    reaper.ImGui_TableNextRow(ctx)
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Item Actions")
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_Spacing(ctx)

    local item_actions = {
      {"W", "Toggle WARP mode"},
      {"M", "Toggle mute"},
      {"R", "Reverse item"},
      {"C", "Clear pitch/speed"},
      {"E", "Open in external editor"},
    }
    for _, entry in ipairs(item_actions) do
      reaper.ImGui_TableNextRow(ctx)
      reaper.ImGui_TableNextColumn(ctx)
      reaper.ImGui_TextColored(ctx, COLORS.accent, "  " .. entry[1])
      reaper.ImGui_TableNextColumn(ctx)
      reaper.ImGui_Text(ctx, entry[2])
    end

    -- Spacing between sections
    reaper.ImGui_TableNextRow(ctx)
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_TableNextColumn(ctx)

    -- Navigation section
    reaper.ImGui_TableNextRow(ctx)
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Navigation")
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_Spacing(ctx)

    local nav_items = {
      {"F", "Reset zoom to fit"},
      {"Ctrl + Scroll", "Zoom in/out"},
      {"Middle Drag", "Pan waveform"},
      {"Ruler Drag", "Zoom + Pan"},
    }
    for _, entry in ipairs(nav_items) do
      reaper.ImGui_TableNextRow(ctx)
      reaper.ImGui_TableNextColumn(ctx)
      reaper.ImGui_TextColored(ctx, COLORS.accent, "  " .. entry[1])
      reaper.ImGui_TableNextColumn(ctx)
      reaper.ImGui_Text(ctx, entry[2])
    end

    -- Spacing between sections
    reaper.ImGui_TableNextRow(ctx)
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_TableNextColumn(ctx)

    -- Markers section
    reaper.ImGui_TableNextRow(ctx)
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_TextColored(ctx, COLORS.text_dim, "Markers")
    reaper.ImGui_TableNextColumn(ctx)
    reaper.ImGui_Spacing(ctx)

    local marker_items = {
      {"Drag Marker", "Move start/end point"},
      {"Alt + Drag", "Slide both markers"},
      {"Mouse 4", "Set start at cursor"},
      {"Mouse 5", "Set end at cursor"},
    }
    for _, entry in ipairs(marker_items) do
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

  reaper.ImGui_SetNextWindowSize(ctx, 380, 500, reaper.ImGui_Cond_FirstUseEver())

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
        draw_shortcuts_tab(ctx)
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
        shortcuts = settings.current.shortcuts
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
