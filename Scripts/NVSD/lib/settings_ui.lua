-- NVSD_ItemView - Settings UI Module
-- Settings popup window with tabbed interface

local settings_ui = {}

-- UI State
local ui_state = {
  open = false,
  pending_theme_id = nil,
  original_theme_id = nil,
  active_tab = 1, -- 1 = Appearance, 2 = Controls
}

-- Colors
local UI_COLORS = {
  bg = 0x1E1E1EFF,
  panel = 0x252525FF,
  header = 0x2A2A2AFF,
  text = 0xDDDDDDFF,
  text_dim = 0x888888FF,
  text_dark = 0x1A1A1AFF,
  border = 0x3A3A3AFF,
  selected = 0x4A90D9FF,
  hover = 0x353535FF,
  tab_active = 0x353535FF,
  tab_inactive = 0x252525FF,
  input_bg = 0x1A1A1AFF,
  btn_default = 0x404040FF,
  btn_hover = 0x505050FF,
  btn_primary = 0x4A90D9FF,
  btn_primary_hover = 0x5AA0E9FF,
  btn_danger = 0x904040FF,
  btn_danger_hover = 0xA05050FF,
  separator = 0x404040FF,
}

-- Initialize pending values from current settings
local function init_pending(settings)
  ui_state.pending_theme_id = settings.current.theme_id
  ui_state.original_theme_id = settings.current.theme_id
  ui_state.active_tab = 1
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

-- Draw a button, returns true if clicked
local function draw_button(ctx, draw_list, x, y, w, h, text, bg_color, hover_color, text_color)
  local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
  local is_hover = mouse_x >= x and mouse_x <= x + w and mouse_y >= y and mouse_y <= y + h
  local bg = is_hover and hover_color or bg_color
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + w, y + h, bg, 4)
  local text_w = #text * 7
  reaper.ImGui_DrawList_AddText(draw_list, x + (w - text_w) / 2, y + (h - 13) / 2, text_color or UI_COLORS.text, text)
  return is_hover and reaper.ImGui_IsMouseClicked(ctx, 0)
end

-- Draw a tab button
local function draw_tab(ctx, draw_list, x, y, w, h, text, is_active)
  local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
  local is_hover = mouse_x >= x and mouse_x <= x + w and mouse_y >= y and mouse_y <= y + h
  local bg = is_active and UI_COLORS.tab_active or (is_hover and UI_COLORS.hover or UI_COLORS.tab_inactive)
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + w, y + h, bg, 4)
  if is_active then
    reaper.ImGui_DrawList_AddLine(draw_list, x + 4, y + h - 2, x + w - 4, y + h - 2, UI_COLORS.selected, 2)
  end
  local text_w = #text * 7
  local text_color = is_active and UI_COLORS.text or UI_COLORS.text_dim
  reaper.ImGui_DrawList_AddText(draw_list, x + (w - text_w) / 2, y + (h - 13) / 2, text_color, text)
  return is_hover and reaper.ImGui_IsMouseClicked(ctx, 0)
end

-- Draw radio button
local function draw_radio(draw_list, x, y, selected, hover)
  local radius = 7
  local cx, cy = x + radius, y + radius
  local outer_color = selected and UI_COLORS.selected or (hover and 0x666666FF or UI_COLORS.border)
  reaper.ImGui_DrawList_AddCircle(draw_list, cx, cy, radius, outer_color, 12, 2)
  if selected then
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, cx, cy, 4, UI_COLORS.selected, 12)
  end
  return radius * 2
end

-- Draw Appearance tab content
local function draw_appearance_tab(ctx, draw_list, settings, x, y, width, height)
  local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
  local content_y = y + 16

  -- Section header
  reaper.ImGui_DrawList_AddText(draw_list, x, content_y, UI_COLORS.text_dim, "Color Theme")
  content_y = content_y + 28

  -- Theme list
  local item_h = 36
  for i, theme in ipairs(settings.THEMES) do
    local item_y = content_y + (i - 1) * item_h
    local is_selected = ui_state.pending_theme_id == theme.id
    local is_hover = mouse_x >= x and mouse_x <= x + width and
                     mouse_y >= item_y and mouse_y <= item_y + item_h

    -- Background on hover
    if is_hover or is_selected then
      local bg_color = is_selected and 0x2A3A4AFF or UI_COLORS.hover
      reaper.ImGui_DrawList_AddRectFilled(draw_list, x, item_y, x + width, item_y + item_h, bg_color, 4)
    end

    -- Radio button
    draw_radio(draw_list, x + 12, item_y + 10, is_selected, is_hover)

    -- Theme name
    local name_color = is_selected and UI_COLORS.text or (is_hover and UI_COLORS.text or UI_COLORS.text_dim)
    reaper.ImGui_DrawList_AddText(draw_list, x + 40, item_y + 11, name_color, theme.name)

    -- Theme description (right side, dimmed)
    local desc_x = x + 130
    reaper.ImGui_DrawList_AddText(draw_list, desc_x, item_y + 11, UI_COLORS.text_dim, theme.description)

    -- Handle click
    if is_hover and reaper.ImGui_IsMouseClicked(ctx, 0) then
      ui_state.pending_theme_id = theme.id
      settings.current.theme_id = theme.id -- Live preview
      settings.colors_dirty = true
      ui_state.has_changes = ui_state.pending_theme_id ~= ui_state.original_theme_id
    end
  end
end

-- Draw Controls tab content (reference, not editable)
local function draw_controls_tab(ctx, draw_list, settings, x, y, width, height)
  local content_y = y + 16

  local control_groups = {
    {
      name = "Navigation",
      items = {
        {key = "Ctrl + Scroll", desc = "Zoom in/out"},
        {key = "Drag Ruler", desc = "Zoom (up/down) + Pan (left/right)"},
        {key = "Middle Drag", desc = "Pan waveform"},
        {key = "F", desc = "Reset zoom to fit"},
      }
    },
    {
      name = "Markers",
      items = {
        {key = "Drag Marker", desc = "Move start/end point"},
        {key = "Alt + Drag", desc = "Slide both markers together"},
        {key = "Mouse 4", desc = "Set start at cursor"},
        {key = "Mouse 5", desc = "Set end at cursor"},
      }
    },
    {
      name = "Item Actions",
      items = {
        {key = "W", desc = "Toggle WARP mode"},
        {key = "M", desc = "Toggle mute"},
        {key = "R", desc = "Reverse item"},
        {key = "C", desc = "Clear pitch/speed"},
        {key = "E", desc = "Open in editor"},
      }
    },
    {
      name = "General",
      items = {
        {key = "Ctrl + Z", desc = "Undo"},
        {key = "Ctrl + Y", desc = "Redo"},
      }
    },
  }

  local row_h = 28
  local key_w = 120

  for _, group in ipairs(control_groups) do
    -- Group header
    reaper.ImGui_DrawList_AddText(draw_list, x, content_y, UI_COLORS.text_dim, group.name)
    content_y = content_y + 24

    for _, item in ipairs(group.items) do
      local row_y = content_y

      -- Key/shortcut (highlighted)
      reaper.ImGui_DrawList_AddText(draw_list, x + 12, row_y + 5, UI_COLORS.selected, item.key)

      -- Description
      reaper.ImGui_DrawList_AddText(draw_list, x + key_w, row_y + 5, UI_COLORS.text, item.desc)

      content_y = content_y + row_h
    end

    content_y = content_y + 12 -- Gap between groups
  end
end

-- Main draw function
function settings_ui.draw(ctx, settings)
  if not ui_state.open then return end

  local win_w, win_h = 400, 810
  local vp_w, vp_h = reaper.ImGui_Viewport_GetSize(reaper.ImGui_GetMainViewport(ctx))
  local win_x = (vp_w - win_w) / 2
  local win_y = (vp_h - win_h) / 2

  reaper.ImGui_SetNextWindowPos(ctx, win_x, win_y, reaper.ImGui_Cond_FirstUseEver())
  reaper.ImGui_SetNextWindowSize(ctx, win_w, win_h, reaper.ImGui_Cond_Always())

  local flags = reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_NoResize()
  local visible, open = reaper.ImGui_Begin(ctx, "NVSD ItemView Settings", true, flags)

  if not open then
    settings_ui.close(settings, true)
    reaper.ImGui_End(ctx)
    return
  end

  if visible then
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    local win_pos_x, win_pos_y = reaper.ImGui_GetWindowPos(ctx)
    local cursor_x, cursor_y = reaper.ImGui_GetCursorScreenPos(ctx)
    local content_w = reaper.ImGui_GetContentRegionAvail(ctx)
    local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)

    local padding = 16
    local x = cursor_x
    local y = cursor_y

    -- Tabs
    local tab_w = (content_w - 8) / 2
    local tab_h = 36

    if draw_tab(ctx, draw_list, x, y, tab_w, tab_h, "Appearance", ui_state.active_tab == 1) then
      ui_state.active_tab = 1
    end
    if draw_tab(ctx, draw_list, x + tab_w + 8, y, tab_w, tab_h, "Controls", ui_state.active_tab == 2) then
      ui_state.active_tab = 2
    end

    y = y + tab_h + 12

    -- Tab content area
    local content_h = win_h - tab_h - 110
    reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + content_w, y + content_h, UI_COLORS.panel, 6)

    if ui_state.active_tab == 1 then
      draw_appearance_tab(ctx, draw_list, settings, x + padding, y, content_w - padding * 2, content_h)
    else
      draw_controls_tab(ctx, draw_list, settings, x + padding, y, content_w - padding * 2, content_h)
    end

    -- Bottom buttons
    local btn_h = 34
    local btn_y = win_pos_y + win_h - btn_h - 28

    -- Right side buttons
    local btn_gap = 10
    local cancel_w = 80
    local apply_w = 130

    local cancel_x = x + content_w - cancel_w - apply_w - btn_gap
    local apply_x = x + content_w - apply_w

    -- Cancel
    if draw_button(ctx, draw_list, cancel_x, btn_y, cancel_w, btn_h, "Cancel", UI_COLORS.btn_default, UI_COLORS.btn_hover, UI_COLORS.text) then
      settings_ui.close(settings, true)
    end

    -- Save & Close
    if draw_button(ctx, draw_list, apply_x, btn_y, apply_w, btn_h, "Save & Close", UI_COLORS.btn_primary, UI_COLORS.btn_primary_hover, 0xFFFFFFFF) then
      settings.apply({
        theme_id = ui_state.pending_theme_id,
        shortcuts = settings.current.shortcuts -- Keep existing shortcuts
      })
      settings_ui.close(settings, false)
    end
  end

  reaper.ImGui_End(ctx)
end

return settings_ui
