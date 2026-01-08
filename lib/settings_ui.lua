-- NVSD_ItemView - Settings UI Module
-- Settings popup window

local settings_ui = {}

-- UI State
local ui_state = {
  open = false,
  pending_theme_id = nil,
  pending_shortcuts = nil,
  capturing_shortcut = nil, -- Which shortcut is being captured (nil, "undo", "redo")
  has_changes = false,
  original_theme_id = nil, -- Theme when settings opened (for Cancel)
}

-- Colors for the settings UI
local UI_COLORS = {
  bg = 0x252525FF,
  header = 0x353535FF,
  text = 0xCCCCCCFF,
  text_dim = 0x888888FF,
  border = 0x454545FF,
  selected = 0x4A90D9FF,
  hover = 0x3A3A3AFF,
  btn_bg = 0x404040FF,
  btn_hover = 0x505050FF,
  btn_apply = 0x4A90D9FF,
  btn_cancel = 0x606060FF,
  input_bg = 0x1A1A1AFF,
}

-- Initialize pending values from current settings
local function init_pending(settings)
  ui_state.pending_theme_id = settings.current.theme_id
  ui_state.original_theme_id = settings.current.theme_id -- Store for Cancel
  ui_state.pending_shortcuts = {}
  for name, shortcut in pairs(settings.current.shortcuts) do
    ui_state.pending_shortcuts[name] = {
      ctrl = shortcut.ctrl,
      shift = shortcut.shift,
      alt = shortcut.alt,
      key = shortcut.key
    }
  end
  ui_state.has_changes = false
  ui_state.capturing_shortcut = nil
end

-- Check if there are unsaved changes (compared to original state when opened)
local function check_changes(settings)
  -- Compare theme against original (not current, since current is used for preview)
  if ui_state.pending_theme_id ~= ui_state.original_theme_id then
    return true
  end
  for name, pending in pairs(ui_state.pending_shortcuts) do
    local current = settings.current.shortcuts[name]
    if current then
      if pending.ctrl ~= current.ctrl or
         pending.shift ~= current.shift or
         pending.alt ~= current.alt or
         pending.key ~= current.key then
        return true
      end
    end
  end
  return false
end

-- Open the settings window
function settings_ui.open(settings)
  ui_state.open = true
  init_pending(settings)
end

-- Close the settings window
-- restore_original: if true, restore theme to original (Cancel/X button)
function settings_ui.close(settings, restore_original)
  if restore_original and settings and ui_state.original_theme_id then
    -- Restore the original theme (preview was not saved)
    settings.current.theme_id = ui_state.original_theme_id
  end
  ui_state.open = false
  ui_state.capturing_shortcut = nil
  ui_state.original_theme_id = nil
end

-- Check if settings window is open
function settings_ui.is_open()
  return ui_state.open
end

-- Draw radio button
local function draw_radio(draw_list, x, y, selected, hover)
  local radius = 6
  local outer_color = selected and UI_COLORS.selected or (hover and 0x666666FF or UI_COLORS.border)
  reaper.ImGui_DrawList_AddCircle(draw_list, x + radius, y + radius, radius, outer_color, 12, 2)
  if selected then
    reaper.ImGui_DrawList_AddCircleFilled(draw_list, x + radius, y + radius, radius - 3, UI_COLORS.selected, 12)
  end
  return radius * 2
end

-- Draw button and return if clicked
local function draw_button(ctx, draw_list, x, y, w, h, text, color, hover_color, text_color)
  local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
  local is_hover = mouse_x >= x and mouse_x <= x + w and mouse_y >= y and mouse_y <= y + h

  local bg = is_hover and hover_color or color
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + w, y + h, bg, 3)

  local text_w = #text * 7
  local text_x = x + (w - text_w) / 2
  local text_y = y + (h - 13) / 2
  reaper.ImGui_DrawList_AddText(draw_list, text_x, text_y, text_color or UI_COLORS.text, text)

  return is_hover and reaper.ImGui_IsMouseClicked(ctx, 0)
end

-- Draw the settings window
function settings_ui.draw(ctx, settings)
  if not ui_state.open then return end

  local win_w, win_h = 380, 420
  local vp_w, vp_h = reaper.ImGui_Viewport_GetSize(reaper.ImGui_GetMainViewport(ctx))
  local win_x = (vp_w - win_w) / 2
  local win_y = (vp_h - win_h) / 2

  reaper.ImGui_SetNextWindowPos(ctx, win_x, win_y, reaper.ImGui_Cond_FirstUseEver())
  reaper.ImGui_SetNextWindowSize(ctx, win_w, win_h, reaper.ImGui_Cond_FirstUseEver())

  local flags = reaper.ImGui_WindowFlags_NoCollapse()
  local visible, open = reaper.ImGui_Begin(ctx, "NVSD ItemView Settings", true, flags)

  if not open then
    settings_ui.close(settings, true) -- Restore original on X button
    reaper.ImGui_End(ctx)
    return
  end

  if visible then
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    local win_pos_x, win_pos_y = reaper.ImGui_GetWindowPos(ctx)
    local cursor_x, cursor_y = reaper.ImGui_GetCursorScreenPos(ctx)
    local content_w = reaper.ImGui_GetContentRegionAvail(ctx)
    local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)

    local y = cursor_y

    -- THEME section
    reaper.ImGui_DrawList_AddText(draw_list, cursor_x, y, UI_COLORS.text, "THEME")
    y = y + 20

    -- Theme list
    local theme_list_h = #settings.THEMES * 24 + 8
    reaper.ImGui_DrawList_AddRectFilled(draw_list, cursor_x, y, cursor_x + content_w, y + theme_list_h, UI_COLORS.input_bg, 3)
    reaper.ImGui_DrawList_AddRect(draw_list, cursor_x, y, cursor_x + content_w, y + theme_list_h, UI_COLORS.border, 3)

    local list_y = y + 4
    for _, theme in ipairs(settings.THEMES) do
      local item_y = list_y
      local is_selected = ui_state.pending_theme_id == theme.id
      local is_hover = mouse_x >= cursor_x and mouse_x <= cursor_x + content_w and
                       mouse_y >= item_y and mouse_y <= item_y + 22

      if is_hover then
        reaper.ImGui_DrawList_AddRectFilled(draw_list, cursor_x + 2, item_y, cursor_x + content_w - 2, item_y + 22, UI_COLORS.hover, 2)
      end

      -- Radio button
      draw_radio(draw_list, cursor_x + 8, item_y + 4, is_selected, is_hover)

      -- Theme name
      reaper.ImGui_DrawList_AddText(draw_list, cursor_x + 28, item_y + 4, UI_COLORS.text, theme.name)

      -- Theme description
      reaper.ImGui_DrawList_AddText(draw_list, cursor_x + 130, item_y + 4, UI_COLORS.text_dim, theme.description)

      -- Handle click - apply immediately for live preview
      if is_hover and reaper.ImGui_IsMouseClicked(ctx, 0) then
        ui_state.pending_theme_id = theme.id
        settings.current.theme_id = theme.id -- Live preview
        ui_state.has_changes = check_changes(settings)
      end

      list_y = list_y + 24
    end

    y = y + theme_list_h + 20

    -- SHORTCUTS section
    reaper.ImGui_DrawList_AddText(draw_list, cursor_x, y, UI_COLORS.text, "SHORTCUTS")
    y = y + 20

    local shortcut_names = {
      {id = "undo", label = "Undo"},
      {id = "redo", label = "Redo"},
    }

    for _, sc in ipairs(shortcut_names) do
      -- Label
      reaper.ImGui_DrawList_AddText(draw_list, cursor_x, y + 4, UI_COLORS.text, sc.label)

      -- Shortcut input box
      local box_x = cursor_x + 80
      local box_w = 150
      local box_h = 22

      local is_capturing = ui_state.capturing_shortcut == sc.id
      local box_hover = mouse_x >= box_x and mouse_x <= box_x + box_w and
                        mouse_y >= y and mouse_y <= y + box_h

      local box_color = is_capturing and UI_COLORS.selected or UI_COLORS.input_bg
      local box_border = is_capturing and UI_COLORS.selected or (box_hover and 0x666666FF or UI_COLORS.border)

      reaper.ImGui_DrawList_AddRectFilled(draw_list, box_x, y, box_x + box_w, y + box_h, box_color, 2)
      reaper.ImGui_DrawList_AddRect(draw_list, box_x, y, box_x + box_w, y + box_h, box_border, 2)

      -- Shortcut text or prompt
      local shortcut_text
      if is_capturing then
        shortcut_text = "Press key..."
      else
        local shortcut = ui_state.pending_shortcuts[sc.id]
        shortcut_text = shortcut and settings.format_shortcut(shortcut) or "Not set"
      end
      reaper.ImGui_DrawList_AddText(draw_list, box_x + 8, y + 4, is_capturing and 0x1A1A1AFF or UI_COLORS.text, shortcut_text)

      -- Click to start capturing
      if box_hover and reaper.ImGui_IsMouseClicked(ctx, 0) and not is_capturing then
        ui_state.capturing_shortcut = sc.id
      end

      -- Capture key press
      if is_capturing then
        -- Key mappings: ImGui function name -> display name
        local key_checks = {
          {func = "ImGui_Key_A", name = "A"}, {func = "ImGui_Key_B", name = "B"},
          {func = "ImGui_Key_C", name = "C"}, {func = "ImGui_Key_D", name = "D"},
          {func = "ImGui_Key_E", name = "E"}, {func = "ImGui_Key_F", name = "F"},
          {func = "ImGui_Key_G", name = "G"}, {func = "ImGui_Key_H", name = "H"},
          {func = "ImGui_Key_I", name = "I"}, {func = "ImGui_Key_J", name = "J"},
          {func = "ImGui_Key_K", name = "K"}, {func = "ImGui_Key_L", name = "L"},
          {func = "ImGui_Key_M", name = "M"}, {func = "ImGui_Key_N", name = "N"},
          {func = "ImGui_Key_O", name = "O"}, {func = "ImGui_Key_P", name = "P"},
          {func = "ImGui_Key_Q", name = "Q"}, {func = "ImGui_Key_R", name = "R"},
          {func = "ImGui_Key_S", name = "S"}, {func = "ImGui_Key_T", name = "T"},
          {func = "ImGui_Key_U", name = "U"}, {func = "ImGui_Key_V", name = "V"},
          {func = "ImGui_Key_W", name = "W"}, {func = "ImGui_Key_X", name = "X"},
          {func = "ImGui_Key_Y", name = "Y"}, {func = "ImGui_Key_Z", name = "Z"},
          {func = "ImGui_Key_0", name = "0"}, {func = "ImGui_Key_1", name = "1"},
          {func = "ImGui_Key_2", name = "2"}, {func = "ImGui_Key_3", name = "3"},
          {func = "ImGui_Key_4", name = "4"}, {func = "ImGui_Key_5", name = "5"},
          {func = "ImGui_Key_6", name = "6"}, {func = "ImGui_Key_7", name = "7"},
          {func = "ImGui_Key_8", name = "8"}, {func = "ImGui_Key_9", name = "9"},
          {func = "ImGui_Key_F1", name = "F1"}, {func = "ImGui_Key_F2", name = "F2"},
          {func = "ImGui_Key_F3", name = "F3"}, {func = "ImGui_Key_F4", name = "F4"},
          {func = "ImGui_Key_F5", name = "F5"}, {func = "ImGui_Key_F6", name = "F6"},
          {func = "ImGui_Key_F7", name = "F7"}, {func = "ImGui_Key_F8", name = "F8"},
          {func = "ImGui_Key_F9", name = "F9"}, {func = "ImGui_Key_F10", name = "F10"},
          {func = "ImGui_Key_F11", name = "F11"}, {func = "ImGui_Key_F12", name = "F12"},
        }

        local captured = false
        for _, kc in ipairs(key_checks) do
          if reaper[kc.func] and reaper.ImGui_IsKeyPressed(ctx, reaper[kc.func]()) then
            ui_state.pending_shortcuts[sc.id] = {
              ctrl = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl()),
              shift = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift()),
              alt = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Alt()),
              key = kc.name
            }
            ui_state.capturing_shortcut = nil
            ui_state.has_changes = check_changes(settings)
            captured = true
            break
          end
        end

        -- Escape to cancel
        if not captured and reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape()) then
          ui_state.capturing_shortcut = nil
        end
      end

      -- Reset button
      local reset_x = box_x + box_w + 10
      local reset_w = 50
      if draw_button(ctx, draw_list, reset_x, y, reset_w, box_h, "Reset", UI_COLORS.btn_bg, UI_COLORS.btn_hover, UI_COLORS.text) then
        local default = settings.DEFAULT_SHORTCUTS[sc.id]
        if default then
          ui_state.pending_shortcuts[sc.id] = {
            ctrl = default.ctrl,
            shift = default.shift,
            alt = default.alt,
            key = default.key
          }
          ui_state.has_changes = check_changes(settings)
        end
      end

      y = y + 32
    end

    y = y + 10

    -- Bottom buttons
    local btn_h = 28
    local btn_y = win_pos_y + win_h - btn_h - 40

    -- Reset All button (left side)
    local reset_all_w = 80
    if draw_button(ctx, draw_list, cursor_x, btn_y, reset_all_w, btn_h, "Reset All", UI_COLORS.btn_bg, UI_COLORS.btn_hover, UI_COLORS.text) then
      ui_state.pending_theme_id = "default"
      settings.current.theme_id = "default" -- Live preview
      for name, default in pairs(settings.DEFAULT_SHORTCUTS) do
        ui_state.pending_shortcuts[name] = {
          ctrl = default.ctrl,
          shift = default.shift,
          alt = default.alt,
          key = default.key
        }
      end
      ui_state.has_changes = check_changes(settings)
    end

    -- Right side buttons
    local btn_gap = 8
    local cancel_w = 60
    local apply_w = 60
    local apply_close_w = 100

    local total_right_w = cancel_w + apply_w + apply_close_w + btn_gap * 2
    local right_start = cursor_x + content_w - total_right_w

    -- Cancel
    if draw_button(ctx, draw_list, right_start, btn_y, cancel_w, btn_h, "Cancel", UI_COLORS.btn_cancel, UI_COLORS.btn_hover, UI_COLORS.text) then
      settings_ui.close(settings, true) -- Restore original theme
    end

    -- Apply
    local apply_x = right_start + cancel_w + btn_gap
    if draw_button(ctx, draw_list, apply_x, btn_y, apply_w, btn_h, "Apply", UI_COLORS.btn_apply, 0x5AA0E9FF, 0xFFFFFFFF) then
      settings.apply({
        theme_id = ui_state.pending_theme_id,
        shortcuts = ui_state.pending_shortcuts
      })
      ui_state.original_theme_id = ui_state.pending_theme_id -- Update original after save
      ui_state.has_changes = false
    end

    -- Apply & Close
    local apply_close_x = apply_x + apply_w + btn_gap
    if draw_button(ctx, draw_list, apply_close_x, btn_y, apply_close_w, btn_h, "Apply & Close", UI_COLORS.btn_apply, 0x5AA0E9FF, 0xFFFFFFFF) then
      settings.apply({
        theme_id = ui_state.pending_theme_id,
        shortcuts = ui_state.pending_shortcuts
      })
      settings_ui.close(settings, false) -- Don't restore, changes were saved
    end

    -- Click outside capturing area cancels capture
    if ui_state.capturing_shortcut and reaper.ImGui_IsMouseClicked(ctx, 0) then
      -- Check if click was not on a shortcut box (handled above)
      local any_box_clicked = false
      local check_y = cursor_y + 20 + #settings.THEMES * 24 + 8 + 20
      for i, _ in ipairs(shortcut_names) do
        local box_x = cursor_x + 80
        local box_w = 150
        local box_h = 22
        local item_y = check_y + (i - 1) * 32
        if mouse_x >= box_x and mouse_x <= box_x + box_w and
           mouse_y >= item_y and mouse_y <= item_y + box_h then
          any_box_clicked = true
          break
        end
      end
      if not any_box_clicked then
        ui_state.capturing_shortcut = nil
      end
    end
  end

  reaper.ImGui_End(ctx)
end

return settings_ui
