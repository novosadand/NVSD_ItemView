-- NVSD_ItemView - Controls Module
-- Buttons, gain slider, pitch knob, semitones/cents boxes

local controls = {}

-- Draw WARP/Reverse/Edit buttons in the left column
function controls.draw_button_panel(ctx, draw_list, mouse_x, mouse_y, left_col_x, left_col_y, item, take, config, state, utils, drawing)
  local btn_height = 24
  local btn_margin = 10
  local btn_padding = 8
  local row_y = left_col_y + 10
  local text_height = 13

  local COLOR_BTN_ON = config.COLOR_BTN_ON
  local COLOR_BTN_OFF = config.COLOR_BTN_OFF
  local COLOR_BTN_HOVER = config.COLOR_BTN_HOVER
  local COLOR_BTN_TEXT = config.COLOR_BTN_TEXT

  -- Detect warp mode from B_PPITCH (preserve pitch when changing rate)
  -- Warp mode (blue): B_PPITCH=1 (matches REAPER's item properties checkbox)
  -- Non-warp mode (gray): B_PPITCH=0
  local current_playrate = 1.0
  local current_pitch = 0

  if take then
    current_playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    current_pitch = reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH")
    local preserve_pitch = reaper.GetMediaItemTakeInfo_Value(take, "B_PPITCH")
    state.warp_mode = preserve_pitch == 1
  end

  -- WARP button
  local warp_btn_width = config.LEFT_COLUMN_WIDTH - (btn_padding * 2)
  local warp_btn_x = left_col_x + btn_padding
  local warp_btn_y = row_y

  local mouse_in_warp = mouse_x >= warp_btn_x and mouse_x <= warp_btn_x + warp_btn_width
                        and mouse_y >= warp_btn_y and mouse_y <= warp_btn_y + btn_height

  local warp_bg_color
  if state.warp_mode then
    warp_bg_color = mouse_in_warp and COLOR_BTN_HOVER or COLOR_BTN_ON
  else
    warp_bg_color = mouse_in_warp and 0x505050FF or COLOR_BTN_OFF
  end
  reaper.ImGui_DrawList_AddRectFilled(draw_list, warp_btn_x, warp_btn_y, warp_btn_x + warp_btn_width, warp_btn_y + btn_height, warp_bg_color, 3)
  local warp_text_w = reaper.ImGui_CalcTextSize(ctx, "WARP")
  local warp_text_x = warp_btn_x + (warp_btn_width - warp_text_w) / 2
  local warp_text_y = warp_btn_y + (btn_height - text_height) / 2
  reaper.ImGui_DrawList_AddText(draw_list, warp_text_x, warp_text_y, COLOR_BTN_TEXT, "WARP")

  if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_warp then
    state.warp_dropdown_open = false
    if take then
      reaper.Undo_BeginBlock()
      local take_item = reaper.GetMediaItemTake_Item(take)

      if not state.warp_mode then
        -- Turning WARP ON: transfer pitch from playrate into D_PITCH
        local pitch_from_playrate = utils.playrate_to_semitones(current_playrate)
        reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", pitch_from_playrate)
        reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 1)
      else
        -- Turning WARP OFF: transfer D_PITCH into playrate, adjust length
        local old_playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
        local old_length = reaper.GetMediaItemInfo_Value(take_item, "D_LENGTH")
        local new_playrate = utils.semitones_to_playrate(current_pitch)

        reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", 0)
        reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", new_playrate)
        reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 0)

        if new_playrate > 0 then
          local new_length = old_length * (old_playrate / new_playrate)
          reaper.SetMediaItemInfo_Value(take_item, "D_LENGTH", new_length)
        end
      end

      reaper.UpdateArrange()
      reaper.Undo_EndBlock("NVSD_ItemView: Toggle WARP", -1)
    end
  end

  -- Warp mode dropdown
  local dropdown_y = warp_btn_y + btn_height + 4
  local dropdown_btn_height = 16
  local dropdown_height = dropdown_btn_height + 6
  local dropdown_x = left_col_x + btn_padding
  local dropdown_width = warp_btn_width

  local current_mode = -1
  local current_mode_name = "Default"
  if take then
    current_mode = reaper.GetMediaItemTakeInfo_Value(take, "I_PITCHMODE")
    for _, mode in ipairs(config.PITCH_MODES) do
      if mode.value == current_mode then
        current_mode_name = mode.name
        break
      elseif current_mode >= 0 then
        local mode_shifter = mode.value >= 0 and (mode.value >> 16) or -1
        local current_shifter = current_mode >= 0 and (current_mode >> 16) or -1
        if mode_shifter == current_shifter and mode_shifter >= 0 then
          current_mode_name = mode.name
          break
        end
      end
    end
  end

  local dropdown_enabled = state.warp_mode  -- Algorithm dropdown only enabled in warp mode
  local mouse_in_dropdown = mouse_x >= dropdown_x and mouse_x <= dropdown_x + dropdown_width
                            and mouse_y >= dropdown_y and mouse_y <= dropdown_y + dropdown_btn_height

  local dropdown_bg, text_color, arrow_color
  if dropdown_enabled then
    dropdown_bg = mouse_in_dropdown and 0x505050FF or 0x353535FF
    text_color = 0xCCCCCCFF
    arrow_color = 0xAAAAAAFF
  else
    dropdown_bg = 0x252525FF
    text_color = 0x666666FF
    arrow_color = 0x555555FF
    state.warp_dropdown_open = false
  end

  reaper.ImGui_DrawList_AddRectFilled(draw_list, dropdown_x, dropdown_y, dropdown_x + dropdown_width, dropdown_y + dropdown_btn_height, dropdown_bg, 2)
  reaper.ImGui_DrawList_AddText(draw_list, dropdown_x + 3, dropdown_y + 1, text_color, current_mode_name)
  reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
    dropdown_x + dropdown_width - 10, dropdown_y + 4,
    dropdown_x + dropdown_width - 4, dropdown_y + 4,
    dropdown_x + dropdown_width - 7, dropdown_y + dropdown_btn_height - 4,
    arrow_color)

  if dropdown_enabled and reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_dropdown then
    state.warp_dropdown_open = not state.warp_dropdown_open
  end

  if state.warp_dropdown_open then
    local menu_y = dropdown_y + dropdown_btn_height + 1
    local menu_item_height = 16
    local menu_height = #config.PITCH_MODES * menu_item_height + 4

    reaper.ImGui_DrawList_AddRectFilled(draw_list, dropdown_x, menu_y, dropdown_x + dropdown_width, menu_y + menu_height, 0x2A2A2AFF, 2)
    reaper.ImGui_DrawList_AddRect(draw_list, dropdown_x, menu_y, dropdown_x + dropdown_width, menu_y + menu_height, 0x555555FF, 2)

    for i, mode in ipairs(config.PITCH_MODES) do
      local item_y = menu_y + 2 + (i - 1) * menu_item_height
      local mouse_in_item = mouse_x >= dropdown_x and mouse_x <= dropdown_x + dropdown_width
                            and mouse_y >= item_y and mouse_y <= item_y + menu_item_height

      if mouse_in_item then
        reaper.ImGui_DrawList_AddRectFilled(draw_list, dropdown_x + 1, item_y, dropdown_x + dropdown_width - 1, item_y + menu_item_height, 0x4A4A4AFF)
      end

      local item_text_color = (mode.value == current_mode or
        (current_mode >= 0 and mode.value >= 0 and (mode.value >> 16) == (current_mode >> 16)))
        and 0x4A90D9FF or 0xCCCCCCFF
      reaper.ImGui_DrawList_AddText(draw_list, dropdown_x + 4, item_y + 2, item_text_color, mode.name)

      if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_item then
        if take then
          reaper.Undo_BeginBlock()
          reaper.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", mode.value)
          reaper.UpdateArrange()
          reaper.Undo_EndBlock("NVSD_ItemView: Set pitch mode", -1)
        end
        state.warp_dropdown_open = false
      end
    end

    if reaper.ImGui_IsMouseClicked(ctx, 0) and not mouse_in_dropdown then
      local menu_bottom = menu_y + menu_height
      local mouse_in_menu = mouse_x >= dropdown_x and mouse_x <= dropdown_x + dropdown_width
                            and mouse_y >= menu_y and mouse_y <= menu_bottom
      if not mouse_in_menu then
        state.warp_dropdown_open = false
      end
    end

    dropdown_height = dropdown_height + menu_height
  end

  -- CLEAR button (reset to default state)
  local clear_btn_y = warp_btn_y + btn_height + 4 + dropdown_height
  local clear_btn_width = warp_btn_width
  local clear_btn_x = left_col_x + btn_padding
  local clear_btn_height = 20

  local mouse_in_clear = mouse_x >= clear_btn_x and mouse_x <= clear_btn_x + clear_btn_width
                         and mouse_y >= clear_btn_y and mouse_y <= clear_btn_y + clear_btn_height

  local clear_bg_color = mouse_in_clear and 0x505050FF or COLOR_BTN_OFF
  reaper.ImGui_DrawList_AddRectFilled(draw_list, clear_btn_x, clear_btn_y, clear_btn_x + clear_btn_width, clear_btn_y + clear_btn_height, clear_bg_color, 3)
  local clear_text_w = reaper.ImGui_CalcTextSize(ctx, "Clear")
  local clear_text_x = clear_btn_x + (clear_btn_width - clear_text_w) / 2
  local clear_text_y = clear_btn_y + (clear_btn_height - text_height) / 2
  reaper.ImGui_DrawList_AddText(draw_list, clear_text_x, clear_text_y, COLOR_BTN_TEXT, "Clear")

  if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_clear then
    if take and item then
      reaper.Undo_BeginBlock()

      -- Get current values to calculate original length
      local current_playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
      local current_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

      -- Calculate what the length should be at playrate 1.0
      local original_length = current_length * current_playrate

      -- Reset to default state
      reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", 0)
      reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", 1.0)
      reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 0)  -- Disable warp
      reaper.SetMediaItemInfo_Value(item, "D_LENGTH", original_length)

      reaper.UpdateArrange()
      reaper.Undo_EndBlock("NVSD_ItemView: Clear pitch/speed", -1)
    end
  end

  -- Second row: Reverse and Edit
  local row2_y = warp_btn_y + btn_height + btn_margin + dropdown_height + clear_btn_height + 4
  local gap = 6
  local rev_btn_width = 60
  local edit_btn_width = config.LEFT_COLUMN_WIDTH - (btn_padding * 2) - rev_btn_width - gap

  -- REVERSE button
  local rev_btn_x = left_col_x + btn_padding

  local mouse_in_rev = mouse_x >= rev_btn_x and mouse_x <= rev_btn_x + rev_btn_width
                       and mouse_y >= row2_y and mouse_y <= row2_y + btn_height

  local rev_bg_color = mouse_in_rev and 0x505050FF or COLOR_BTN_OFF
  reaper.ImGui_DrawList_AddRectFilled(draw_list, rev_btn_x, row2_y, rev_btn_x + rev_btn_width, row2_y + btn_height, rev_bg_color, 3)
  local rev_text_w = reaper.ImGui_CalcTextSize(ctx, "Reverse")
  local rev_text_x = rev_btn_x + (rev_btn_width - rev_text_w) / 2
  local rev_text_y = row2_y + (btn_height - text_height) / 2
  reaper.ImGui_DrawList_AddText(draw_list, rev_text_x, rev_text_y, COLOR_BTN_TEXT, "Reverse")

  if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_rev then
    if item then
      -- Save current selection
      local saved_items = {}
      for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
        saved_items[#saved_items + 1] = reaper.GetSelectedMediaItem(0, i)
      end
      reaper.Undo_BeginBlock()
      reaper.SelectAllMediaItems(0, false)
      reaper.SetMediaItemSelected(item, true)
      reaper.Main_OnCommand(41051, 0)
      reaper.UpdateArrange()
      reaper.Undo_EndBlock("NVSD_ItemView: Reverse", -1)
      -- Restore selection outside undo block
      reaper.SelectAllMediaItems(0, false)
      for _, sel_item in ipairs(saved_items) do
        if reaper.ValidatePtr(sel_item, "MediaItem*") then
          reaper.SetMediaItemSelected(sel_item, true)
        end
      end
      state.pending_cache_invalidation = 3
    end
  end

  -- EDIT button
  local edit_btn_x = rev_btn_x + rev_btn_width + gap

  local mouse_in_edit = mouse_x >= edit_btn_x and mouse_x <= edit_btn_x + edit_btn_width
                        and mouse_y >= row2_y and mouse_y <= row2_y + btn_height

  local edit_bg_color = mouse_in_edit and 0x505050FF or COLOR_BTN_OFF
  reaper.ImGui_DrawList_AddRectFilled(draw_list, edit_btn_x, row2_y, edit_btn_x + edit_btn_width, row2_y + btn_height, edit_bg_color, 3)
  local edit_text_w = reaper.ImGui_CalcTextSize(ctx, "Edit")
  local edit_text_x = edit_btn_x + (edit_btn_width - edit_text_w) / 2
  local edit_text_y = row2_y + (btn_height - text_height) / 2
  reaper.ImGui_DrawList_AddText(draw_list, edit_text_x, edit_text_y, COLOR_BTN_TEXT, "Edit")

  if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_edit then
    if item then
      -- Save current selection
      local saved_items = {}
      for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
        saved_items[#saved_items + 1] = reaper.GetSelectedMediaItem(0, i)
      end
      reaper.Undo_BeginBlock()
      reaper.SelectAllMediaItems(0, false)
      reaper.SetMediaItemSelected(item, true)
      reaper.Main_OnCommand(40109, 0)
      reaper.Undo_EndBlock("NVSD_ItemView: Open in External Editor", -1)
      -- Restore selection outside undo block
      reaper.SelectAllMediaItems(0, false)
      for _, sel_item in ipairs(saved_items) do
        if reaper.ValidatePtr(sel_item, "MediaItem*") then
          reaper.SetMediaItemSelected(sel_item, true)
        end
      end
    end
  end

  return row2_y + btn_height
end

-- Draw gain slider with tick marks
function controls.draw_gain_slider(ctx, draw_list, mouse_x, mouse_y, panel_x, panel_y, panel_split, item, item_vol, config, state, utils)
  local item_db = utils.gain_to_db(item_vol)
  local slider_pos = utils.db_to_slider(item_db)

  local slider_x = panel_x + (config.LEFT_PANEL_WIDTH - config.GAIN_SLIDER_WIDTH) / 2 - 2
  local slider_top = panel_y + 20
  local slider_bottom = panel_split - 20
  local slider_height = slider_bottom - slider_top

  local COLOR_SLIDER_TRACK = 0x404040FF
  local COLOR_SLIDER_FILL = 0x4A90D9FF
  local COLOR_SLIDER_HANDLE = 0xAAAAAAFF
  local COLOR_SLIDER_HANDLE_HOVER = 0xFFFFFFFF
  local COLOR_ZERO_LINE = 0x666666FF
  local COLOR_TICK = 0x555555FF
  local COLOR_TICK_MAJOR = 0x666666FF
  local COLOR_LABEL = 0x888888FF

  reaper.ImGui_DrawList_AddRectFilled(draw_list, slider_x, slider_top, slider_x + config.GAIN_SLIDER_WIDTH, slider_bottom, COLOR_SLIDER_TRACK, 3)

  local tick_left = slider_x - 3
  local tick_right = slider_x + config.GAIN_SLIDER_WIDTH + 3
  local tick_marks = {
    {db = 24, major = true}, {db = 18, major = false}, {db = 12, major = true},
    {db = 6, major = false}, {db = 0, major = true}, {db = -6, major = false},
    {db = -12, major = true}, {db = -18, major = false}, {db = -24, major = true},
    {db = -36, major = false}, {db = -48, major = true},
  }

  for _, tick in ipairs(tick_marks) do
    local tick_pos = utils.db_to_slider(tick.db)
    local tick_y = slider_bottom - tick_pos * slider_height
    if tick_y >= slider_top and tick_y <= slider_bottom then
      local color = tick.major and COLOR_TICK_MAJOR or COLOR_TICK
      local left = tick.major and tick_left or (slider_x - 1)
      local right = tick.major and tick_right or (slider_x + config.GAIN_SLIDER_WIDTH + 1)
      reaper.ImGui_DrawList_AddLine(draw_list, left, tick_y, right, tick_y, color, 1)
    end
  end

  local zero_y = slider_bottom - 0.5 * slider_height
  reaper.ImGui_DrawList_AddLine(draw_list, tick_left, zero_y, tick_right, zero_y, COLOR_ZERO_LINE, 1)

  reaper.ImGui_DrawList_AddText(draw_list, slider_x + config.GAIN_SLIDER_WIDTH + 5, slider_top - 4, COLOR_LABEL, "24")
  reaper.ImGui_DrawList_AddText(draw_list, slider_x + config.GAIN_SLIDER_WIDTH + 5, slider_bottom - 10, COLOR_LABEL, "-∞")

  local handle_y = slider_bottom - slider_pos * slider_height
  if slider_pos > 0.5 then
    reaper.ImGui_DrawList_AddRectFilled(draw_list, slider_x + 2, handle_y, slider_x + config.GAIN_SLIDER_WIDTH - 2, zero_y, COLOR_SLIDER_FILL, 2)
  elseif slider_pos < 0.5 then
    reaper.ImGui_DrawList_AddRectFilled(draw_list, slider_x + 2, zero_y, slider_x + config.GAIN_SLIDER_WIDTH - 2, handle_y, COLOR_SLIDER_FILL, 2)
  end

  local handle_height = 8
  local mouse_in_slider = mouse_x >= slider_x - 5 and mouse_x <= slider_x + config.GAIN_SLIDER_WIDTH + 5
                          and mouse_y >= slider_top - handle_height and mouse_y <= slider_bottom + handle_height
  local handle_color = (mouse_in_slider or state.is_dragging("gain")) and COLOR_SLIDER_HANDLE_HOVER or COLOR_SLIDER_HANDLE
  reaper.ImGui_DrawList_AddRectFilled(draw_list, slider_x - 2, handle_y - handle_height/2, slider_x + config.GAIN_SLIDER_WIDTH + 2, handle_y + handle_height/2, handle_color, 3)

  local double_clicked = reaper.ImGui_IsMouseDoubleClicked(ctx, 0) and mouse_in_slider
  if double_clicked then
    reaper.Undo_BeginBlock()
    reaper.SetMediaItemInfo_Value(item, "D_VOL", 1.0)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("NVSD_ItemView: Reset item volume to 0dB", -1)
    state.end_drag("gain")
  elseif reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_slider then
    state.start_drag("gain", mouse_y, slider_pos, true)
  end

  if reaper.ImGui_IsMouseReleased(ctx, 0) and state.is_dragging("gain") then
    reaper.UpdateArrange()
    state.end_drag("gain")
  end

  if state.is_dragging("gain") and reaper.ImGui_IsMouseDown(ctx, 0) then
    local delta_y = state.get_drag_delta(ctx, "gain", mouse_y, slider_pos, 0.15)
    local delta_pos = delta_y / slider_height
    local new_pos = state.drag_controls.gain.start_value + delta_pos

    -- Clamp and rebase at bounds to prevent dead zones
    if new_pos > 1 then
      new_pos = 1
      state.drag_controls.gain.start_value = 1
      if state.has_js_extension then
        state.drag_cumulative_delta_y = 0
      else
        state.drag_controls.gain.start_y = mouse_y
      end
    elseif new_pos < 0 then
      new_pos = 0
      state.drag_controls.gain.start_value = 0
      if state.has_js_extension then
        state.drag_cumulative_delta_y = 0
      else
        state.drag_controls.gain.start_y = mouse_y
      end
    end

    local new_db = utils.slider_to_db(new_pos)
    local new_gain = utils.db_to_gain(new_db)
    reaper.SetMediaItemInfo_Value(item, "D_VOL", new_gain)
  end

  local slider_center_x = slider_x + config.GAIN_SLIDER_WIDTH / 2
  reaper.ImGui_DrawList_AddText(draw_list, slider_center_x - 14, panel_y + 2, 0xAAAAAAFF, "Gain")
  local db_text = utils.format_db(item_db)
  local db_text_w = reaper.ImGui_CalcTextSize(ctx, db_text)
  reaper.ImGui_DrawList_AddText(draw_list, slider_center_x - db_text_w / 2, slider_bottom + 6, 0xAAAAAAFF, db_text)

end

-- Set pitch on take based on warp mode
local function set_take_pitch(take, semitones, state, utils)
  if not take then return end
  if state.warp_mode then
    -- In warp mode, use tiny marker if pitch would be exactly 0 to stay in warp mode
    local pitch_value = semitones
    if math.abs(pitch_value) < 0.0001 then
      pitch_value = 0.0001
    end
    reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", pitch_value)
  else
    local take_item = reaper.GetMediaItemTake_Item(take)
    local old_playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    local old_length = reaper.GetMediaItemInfo_Value(take_item, "D_LENGTH")

    local new_playrate = utils.semitones_to_playrate(semitones)
    reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", new_playrate)

    if new_playrate > 0 then
      local new_length = old_length * (old_playrate / new_playrate)
      reaper.SetMediaItemInfo_Value(take_item, "D_LENGTH", new_length)
    end
  end
end

-- Draw pitch knob
function controls.draw_pitch_knob(ctx, draw_list, mouse_x, mouse_y, panel_x, panel_split, panel_bottom, take, config, state, utils, drawing)
  local take_pitch = 0
  if take then
    if state.warp_mode then
      take_pitch = reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH")
      -- Round tiny marker value to 0 for display
      if math.abs(take_pitch) < 0.001 then
        take_pitch = 0
      end
    else
      local take_playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
      take_pitch = utils.playrate_to_semitones(take_playrate)
    end
  end

  local knob_cx = panel_x + config.LEFT_PANEL_WIDTH / 2 - 2
  local knob_cy = panel_split + (panel_bottom - panel_split) / 2
  local knob_angle = utils.pitch_to_angle(take_pitch, config.PITCH_MAX)

  local knob_dx = mouse_x - knob_cx
  local knob_dy = mouse_y - knob_cy
  local knob_dist = math.sqrt(knob_dx * knob_dx + knob_dy * knob_dy)
  local mouse_in_knob = knob_dist <= config.PITCH_KNOB_RADIUS + 8

  drawing.draw_knob(draw_list, knob_cx, knob_cy, config.PITCH_KNOB_RADIUS, knob_angle, mouse_in_knob, state.is_dragging("pitch"))

  local pitch_double_clicked = reaper.ImGui_IsMouseDoubleClicked(ctx, 0) and mouse_in_knob
  if pitch_double_clicked then
    if take then
      reaper.Undo_BeginBlock()
      set_take_pitch(take, 0, state, utils)
      reaper.UpdateArrange()
      reaper.Undo_EndBlock("NVSD_ItemView: Reset pitch to 0", -1)
    end
    state.end_drag("pitch")
  elseif reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_knob then
    state.start_drag("pitch", mouse_y, take_pitch, true)
  end

  if reaper.ImGui_IsMouseReleased(ctx, 0) and state.is_dragging("pitch") then
    state.end_drag("pitch")
  end

  if state.is_dragging("pitch") and reaper.ImGui_IsMouseDown(ctx, 0) then
    local delta_y = state.get_drag_delta(ctx, "pitch", mouse_y, take_pitch, 0.2)
    local delta_semitones = math.floor(delta_y / 10 + 0.5)
    local start_semitones = math.floor(state.drag_controls.pitch.start_value + 0.5)
    local new_pitch = math.max(config.PITCH_MIN, math.min(config.PITCH_MAX, start_semitones + delta_semitones))
    if take then
      set_take_pitch(take, new_pitch, state, utils)
      reaper.UpdateArrange()
    end
  end

  return take_pitch, knob_cx, knob_cy
end

-- Draw semitones/cents boxes
function controls.draw_semitones_cents_boxes(ctx, draw_list, mouse_x, mouse_y, panel_x, knob_cy, take, take_pitch, config, state, utils)
  local display_semitones, display_cents = utils.pitch_to_semitones_cents(take_pitch)

  local box_width = 22
  local box_height = 16
  local box_y = knob_cy + config.PITCH_KNOB_RADIUS + 18
  local box_gap = 1
  local boxes_total_width = box_width * 2 + box_gap
  local box_left_x = panel_x + (config.LEFT_PANEL_WIDTH - boxes_total_width) / 2 - 2
  local box_right_x = box_left_x + box_width + box_gap

  local COLOR_BOX_BG = 0x252525FF
  local COLOR_BOX_BORDER = 0x444444FF
  local COLOR_BOX_HOVER = 0x555555FF
  local COLOR_BOX_TEXT = 0xCCCCCCFF

  local mouse_in_semitones_box = mouse_x >= box_left_x and mouse_x <= box_left_x + box_width
                                 and mouse_y >= box_y and mouse_y <= box_y + box_height
  local mouse_in_cents_box = mouse_x >= box_right_x and mouse_x <= box_right_x + box_width
                             and mouse_y >= box_y and mouse_y <= box_y + box_height

  local semitones_border = (mouse_in_semitones_box or state.is_dragging("semitones")) and COLOR_BOX_HOVER or COLOR_BOX_BORDER
  reaper.ImGui_DrawList_AddRectFilled(draw_list, box_left_x, box_y, box_left_x + box_width, box_y + box_height, COLOR_BOX_BG)
  reaper.ImGui_DrawList_AddRect(draw_list, box_left_x, box_y, box_left_x + box_width, box_y + box_height, semitones_border)
  local semitones_text = tostring(display_semitones)
  reaper.ImGui_DrawList_AddText(draw_list, box_left_x + box_width / 2 - (#semitones_text * 3), box_y + 2, COLOR_BOX_TEXT, semitones_text)

  local cents_border = (mouse_in_cents_box or state.is_dragging("cents")) and COLOR_BOX_HOVER or COLOR_BOX_BORDER
  reaper.ImGui_DrawList_AddRectFilled(draw_list, box_right_x, box_y, box_right_x + box_width, box_y + box_height, COLOR_BOX_BG)
  reaper.ImGui_DrawList_AddRect(draw_list, box_right_x, box_y, box_right_x + box_width, box_y + box_height, cents_border)
  local cents_text = tostring(display_cents)
  reaper.ImGui_DrawList_AddText(draw_list, box_right_x + box_width / 2 - (#cents_text * 3), box_y + 2, COLOR_BOX_TEXT, cents_text)

  local semitones_double_clicked = reaper.ImGui_IsMouseDoubleClicked(ctx, 0) and mouse_in_semitones_box
  if semitones_double_clicked then
    if take then
      reaper.Undo_BeginBlock()
      local new_pitch = math.max(config.PITCH_MIN, math.min(config.PITCH_MAX, utils.semitones_cents_to_pitch(0, display_cents)))
      set_take_pitch(take, new_pitch, state, utils)
      reaper.UpdateArrange()
      reaper.Undo_EndBlock("NVSD_ItemView: Reset semitones to 0", -1)
    end
    state.end_drag("semitones")
  elseif reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_semitones_box then
    state.start_drag("semitones", mouse_y, display_semitones, false)
    state.drag_controls.semitones.start_cents = display_cents  -- Capture cents at drag start
  end

  if reaper.ImGui_IsMouseReleased(ctx, 0) and state.is_dragging("semitones") then
    state.end_drag("semitones")
  end

  if state.is_dragging("semitones") and reaper.ImGui_IsMouseDown(ctx, 0) then
    local delta_y = state.get_drag_delta(ctx, "semitones", mouse_y, display_semitones, nil)
    local delta_semitones = math.floor(delta_y / 10 + 0.5)
    local frozen_cents = state.drag_controls.semitones.start_cents or display_cents
    local new_pitch = math.max(config.PITCH_MIN, math.min(config.PITCH_MAX, utils.semitones_cents_to_pitch(state.drag_controls.semitones.start_value + delta_semitones, frozen_cents)))
    if take then
      set_take_pitch(take, new_pitch, state, utils)
      reaper.UpdateArrange()
    end
  end

  local cents_double_clicked = reaper.ImGui_IsMouseDoubleClicked(ctx, 0) and mouse_in_cents_box
  if cents_double_clicked then
    if take then
      reaper.Undo_BeginBlock()
      local new_pitch = math.max(config.PITCH_MIN, math.min(config.PITCH_MAX, utils.semitones_cents_to_pitch(display_semitones, 0)))
      set_take_pitch(take, new_pitch, state, utils)
      reaper.UpdateArrange()
      reaper.Undo_EndBlock("NVSD_ItemView: Reset cents to 0", -1)
    end
    state.end_drag("cents")
  elseif reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_cents_box then
    state.start_drag("cents", mouse_y, display_cents, false)
    state.drag_controls.cents.start_semitones = display_semitones
  end

  if reaper.ImGui_IsMouseReleased(ctx, 0) and state.is_dragging("cents") then
    state.end_drag("cents")
  end

  if state.is_dragging("cents") and reaper.ImGui_IsMouseDown(ctx, 0) then
    local delta_y = state.get_drag_delta(ctx, "cents", mouse_y, display_cents, nil)
    local delta_cents = math.floor(delta_y / 2 + 0.5)
    local total_cents = state.drag_controls.cents.start_value + delta_cents
    local frozen_semitones = state.drag_controls.cents.start_semitones or display_semitones

    -- Rollover: when total_cents exceeds ±50, shift into semitones
    local extra_semitones = math.floor((total_cents + 50) / 100)
    local final_cents = total_cents - extra_semitones * 100
    local final_semitones = frozen_semitones + extra_semitones

    local new_pitch = math.max(config.PITCH_MIN, math.min(config.PITCH_MAX,
      utils.semitones_cents_to_pitch(final_semitones, final_cents)))
    if take then
      set_take_pitch(take, new_pitch, state, utils)
      reaper.UpdateArrange()
    end
  end
end

-- Draw FX toolbar: +/Power button and FX button above the FX beveled box
-- Returns the bottom Y coordinate so the FX box can start below it
function controls.draw_fx_toolbar(ctx, draw_list, mouse_x, mouse_y,
                                   toolbar_x, toolbar_y, toolbar_width,
                                   take, config, state, drawing)
  local btn_height = 20
  local left_btn_width = 24
  local gap = 4
  local right_btn_width = toolbar_width - left_btn_width - gap
  local rounding = 3
  local text_height = 13

  local COLOR_BTN_ON = config.COLOR_BTN_ON
  local COLOR_BTN_OFF = config.COLOR_BTN_OFF
  local COLOR_BTN_HOVER = config.COLOR_BTN_HOVER
  local COLOR_BTN_TEXT = config.COLOR_BTN_TEXT

  local fx_count = take and reaper.TakeFX_GetCount(take) or 0
  local has_fx = fx_count > 0

  -- Left button: + (no FX) or Power icon (has FX)
  local left_x = toolbar_x
  local left_y = toolbar_y

  local mouse_in_left = mouse_x >= left_x and mouse_x <= left_x + left_btn_width
                        and mouse_y >= left_y and mouse_y <= left_y + btn_height

  local left_bg = mouse_in_left and 0x505050FF or COLOR_BTN_OFF
  reaper.ImGui_DrawList_AddRectFilled(draw_list, left_x, left_y, left_x + left_btn_width, left_y + btn_height, left_bg, rounding)

  if has_fx then
    -- Draw power icon centered, colored with accent
    local icon_cx = left_x + left_btn_width / 2
    local icon_cy = left_y + btn_height / 2
    drawing.draw_power_icon(draw_list, icon_cx, icon_cy, 5, COLOR_BTN_ON)
  else
    -- Draw "+" text centered
    local plus_w = reaper.ImGui_CalcTextSize(ctx, "+")
    local plus_x = left_x + (left_btn_width - plus_w) / 2
    local plus_y = left_y + (btn_height - text_height) / 2
    reaper.ImGui_DrawList_AddText(draw_list, plus_x, plus_y, COLOR_BTN_TEXT, "+")
  end

  -- Left button click
  if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_left then
    if take then
      if not has_fx then
        -- No FX: open/focus FX Browser (only open if closed, never close)
        if reaper.GetToggleCommandState(40271) ~= 1 then
          reaper.Main_OnCommand(40271, 0)
        end
      else
        -- Has FX: toggle bypass on all
        local any_enabled = false
        for i = 0, fx_count - 1 do
          if reaper.TakeFX_GetEnabled(take, i) then
            any_enabled = true
            break
          end
        end
        reaper.Undo_BeginBlock()
        for i = 0, fx_count - 1 do
          reaper.TakeFX_SetEnabled(take, i, not any_enabled)
        end
        reaper.Undo_EndBlock("NVSD_ItemView: Toggle all FX bypass", -1)
      end
    end
  end

  -- Right button: FX
  local right_x = left_x + left_btn_width + gap
  local right_y = toolbar_y

  local mouse_in_right = mouse_x >= right_x and mouse_x <= right_x + right_btn_width
                         and mouse_y >= right_y and mouse_y <= right_y + btn_height

  local right_bg
  if has_fx then
    right_bg = mouse_in_right and COLOR_BTN_HOVER or COLOR_BTN_ON
  else
    right_bg = mouse_in_right and 0x505050FF or COLOR_BTN_OFF
  end
  reaper.ImGui_DrawList_AddRectFilled(draw_list, right_x, right_y, right_x + right_btn_width, right_y + btn_height, right_bg, rounding)

  local fx_text = "FX"
  local fx_text_w = reaper.ImGui_CalcTextSize(ctx, fx_text)
  local fx_text_x = right_x + (right_btn_width - fx_text_w) / 2
  local fx_text_y = right_y + (btn_height - text_height) / 2
  local fx_text_color = has_fx and 0x404040FF or COLOR_BTN_TEXT
  reaper.ImGui_DrawList_AddText(draw_list, fx_text_x, fx_text_y, fx_text_color, fx_text)

  -- Right button click
  if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_right then
    if take then
      local alt_held = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Alt())
      if alt_held and has_fx then
        -- Alt+click: remove ALL FX
        reaper.Undo_BeginBlock()
        for i = fx_count - 1, 0, -1 do
          reaper.TakeFX_Delete(take, i)
        end
        reaper.Undo_EndBlock("NVSD_ItemView: Remove all FX", -1)
      elseif has_fx then
        -- Has FX: toggle FX chain window
        local chain_visible = reaper.TakeFX_GetChainVisible(take)
        if chain_visible >= 0 then
          reaper.TakeFX_Show(take, 0, 0)  -- hide chain
        else
          reaper.TakeFX_Show(take, 0, 1)  -- show chain
        end
      else
        -- No FX: open/focus FX Browser (only open if closed, never close)
        if reaper.GetToggleCommandState(40271) ~= 1 then
          reaper.Main_OnCommand(40271, 0)
        end
      end
    end
  end

  return toolbar_y + btn_height
end

-- FX cache (module-level, shared across frames)
local fx_cache = { take = nil, count = 0, state_count = 0, entries = {} }

-- Strip format prefix from FX name ("VST:", "JS:", "VSTi:", etc.)
local function strip_fx_prefix(name)
  return name:match(": (.+) %(") or name:match(": (.+)") or name
end

-- Build/refresh FX cache for a take
local function refresh_fx_cache(take)
  if not take then
    fx_cache.take = nil
    fx_cache.count = 0
    fx_cache.state_count = 0
    fx_cache.entries = {}
    return
  end

  local fx_count = reaper.TakeFX_GetCount(take)
  local proj_state = reaper.GetProjectStateChangeCount(0)

  if fx_cache.take == take and fx_cache.count == fx_count and fx_cache.state_count == proj_state then
    return -- cache is still valid
  end

  fx_cache.take = take
  fx_cache.count = fx_count
  fx_cache.state_count = proj_state
  fx_cache.entries = {}

  for i = 0, fx_count - 1 do
    local retval, name = reaper.TakeFX_GetFXName(take, i, "")
    local display_name = strip_fx_prefix(name)
    fx_cache.entries[i + 1] = {
      name = display_name,
      full_name = name,
      index = i,
    }
  end
end

-- Draw the FX list in a given rectangular area with beveled box, drag-and-drop, and scroll
-- Returns the number of FX rows actually drawn
function controls.draw_fx_list(ctx, draw_list, mouse_x, mouse_y,
                                fx_x, fx_y, fx_width, fx_height,
                                take, config, state, drawing)
  -- Always draw the beveled box background
  local BOX_FILL = 0x151515FF
  local BOX_BORDER = 0x333333FF
  local BOX_BEVEL = 4
  drawing.draw_beveled_rect(draw_list, fx_x, fx_y, fx_x + fx_width, fx_y + fx_height, BOX_FILL, BOX_BORDER, BOX_BEVEL)

  if not take then return 0 end

  refresh_fx_cache(take)
  local entries = fx_cache.entries
  if #entries == 0 then return 0 end

  local row_height = 20
  local bypass_size = 14
  local bypass_margin = 4
  local text_x_offset = bypass_size + bypass_margin * 2
  local rows_drawn = 0
  local inner_pad = 2  -- small padding inside beveled box

  -- Scrolling: compute content height and whether scrollbar is needed
  local content_height = #entries * row_height
  local visible_height = fx_height - inner_pad * 2
  local needs_scroll = content_height > visible_height
  local scrollbar_width = needs_scroll and 6 or 0
  local content_width = fx_width - scrollbar_width  -- available width for FX rows

  -- Clamp scroll offset
  local max_scroll = math.max(0, content_height - visible_height)
  if state.fx_scroll_offset > max_scroll then state.fx_scroll_offset = max_scroll end
  if state.fx_scroll_offset < 0 then state.fx_scroll_offset = 0 end

  -- Mouse wheel scrolling (when mouse is inside the FX box)
  local mouse_in_box = mouse_x >= fx_x and mouse_x <= fx_x + fx_width
                       and mouse_y >= fx_y and mouse_y <= fx_y + fx_height
  if mouse_in_box and needs_scroll then
    local wheel = reaper.ImGui_GetMouseWheel(ctx)
    if wheel ~= 0 then
      state.fx_scroll_offset = state.fx_scroll_offset - wheel * row_height
      if state.fx_scroll_offset < 0 then state.fx_scroll_offset = 0 end
      if state.fx_scroll_offset > max_scroll then state.fx_scroll_offset = max_scroll end
    end
  end

  -- Visible bounds for row clipping
  local clip_top = fx_y + inner_pad
  local clip_bottom = fx_y + fx_height - inner_pad

  -- Clip drawing to the beveled box interior (prevents text bleed on scroll)
  local has_clip_rect = reaper.ImGui_DrawList_PushClipRect ~= nil
  if has_clip_rect then
    reaper.ImGui_DrawList_PushClipRect(draw_list, fx_x, clip_top, fx_x + fx_width, clip_bottom, true)
  end

  -- Collect row Y positions for drag target calculation
  local row_positions = {}  -- [i] = { y = top_y, entry = entry }
  local scroll = state.fx_scroll_offset

  for i = 1, #entries do
    local entry = entries[i]
    if not entry then break end

    local row_y = fx_y + inner_pad + (i - 1) * row_height - scroll

    -- Skip rows entirely above/below visible area (but still track for drag targets)
    local row_visible = (row_y + row_height > clip_top) and (row_y < clip_bottom)

    row_positions[#row_positions + 1] = { y = row_y, entry = entry, list_idx = i }

    local fx_idx = entry.index
    local is_enabled = reaper.TakeFX_GetEnabled(take, fx_idx)
    local is_offline = reaper.TakeFX_GetOffline(take, fx_idx)
    local is_open = reaper.TakeFX_GetOpen(take, fx_idx)

    -- Hit detection for the whole row (only if visible and within clip bounds)
    local mouse_in_row = row_visible
                         and mouse_x >= fx_x and mouse_x <= fx_x + content_width
                         and mouse_y >= math.max(row_y, clip_top) and mouse_y <= math.min(row_y + row_height, clip_bottom)

    -- Skip drawing source row normally if it's being dragged (draw ghosted)
    local is_drag_source = state.fx_drag_activated and state.fx_drag_src_idx == fx_idx

    if row_visible then
      -- Row background
      if is_drag_source then
        reaper.ImGui_DrawList_AddRectFilled(draw_list, fx_x + inner_pad, row_y, fx_x + content_width - inner_pad, row_y + row_height, 0x2A2A2AFF)
      elseif mouse_in_row and not state.fx_drag_activated then
        reaper.ImGui_DrawList_AddRectFilled(draw_list, fx_x + inner_pad, row_y, fx_x + content_width - inner_pad, row_y + row_height, 0x3A3A3AFF)
      end

      -- Bypass toggle indicator [B]
      local bp_x = fx_x + bypass_margin + inner_pad
      local bp_y = row_y + (row_height - bypass_size) / 2
      local mouse_in_bypass = mouse_x >= bp_x and mouse_x <= bp_x + bypass_size
                              and mouse_y >= bp_y and mouse_y <= bp_y + bypass_size
                              and row_visible

      if is_enabled then
        local bp_color = is_drag_source and 0x4A90D960 or 0x4A90D9FF
        reaper.ImGui_DrawList_AddRectFilled(draw_list, bp_x, bp_y, bp_x + bypass_size, bp_y + bypass_size, bp_color, 2)
      else
        local bp_border = is_drag_source and 0x55555560 or 0x555555FF
        reaper.ImGui_DrawList_AddRect(draw_list, bp_x, bp_y, bp_x + bypass_size, bp_y + bypass_size, bp_border, 2)
      end

      -- FX name text
      local text_color
      if is_drag_source then
        text_color = 0x66666660
      elseif is_offline then
        text_color = 0x994444FF
      elseif not is_enabled then
        text_color = 0x777777FF
      elseif is_open then
        text_color = 0xFFFFFFFF
      else
        text_color = 0xCCCCCCFF
      end

      local text_x = fx_x + text_x_offset + inner_pad
      local text_y = row_y + (row_height - 13) / 2
      local max_text_w = content_width - text_x_offset - inner_pad * 2 - 4

      -- Truncate text to fit
      local display_text = entry.name
      local text_w = reaper.ImGui_CalcTextSize(ctx, display_text)
      if text_w > max_text_w then
        while #display_text > 3 and reaper.ImGui_CalcTextSize(ctx, display_text .. "...") > max_text_w do
          display_text = display_text:sub(1, -2)
        end
        display_text = display_text .. "..."
      end

      reaper.ImGui_DrawList_AddText(draw_list, text_x, text_y, text_color, display_text)


      -- Click/drag handling (only when not mid-drag, row must be visible)
      if not state.fx_drag_activated then
        if reaper.ImGui_IsMouseClicked(ctx, 0) then
          if mouse_in_bypass then
            reaper.Undo_BeginBlock()
            reaper.TakeFX_SetEnabled(take, fx_idx, not is_enabled)
            reaper.Undo_EndBlock("NVSD_ItemView: Toggle FX bypass", -1)
          elseif mouse_in_row then
            local shift_held = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift())
            local alt_held = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Alt())
            if alt_held then
              reaper.Undo_BeginBlock()
              reaper.TakeFX_Delete(take, fx_idx)
              reaper.Undo_EndBlock("NVSD_ItemView: Delete FX", -1)
              fx_cache.state_count = 0
            elseif shift_held then
              reaper.Undo_BeginBlock()
              reaper.TakeFX_SetEnabled(take, fx_idx, not is_enabled)
              reaper.Undo_EndBlock("NVSD_ItemView: Toggle FX bypass", -1)
            elseif not mouse_in_bypass then
              state.fx_dragging = true
              state.fx_drag_src_idx = fx_idx
              state.fx_drag_start_y = mouse_y
              state.fx_drag_activated = false
              state.fx_drag_mouse_y = mouse_y
            end
          end
        end
      end

      -- Right-click: store FX index for context menu
      if reaper.ImGui_IsMouseClicked(ctx, 1) and mouse_in_row then
        state.fx_context_menu_idx = fx_idx
        state.fx_context_menu_take = take
        reaper.ImGui_OpenPopup(ctx, "fx_context_menu")
      end
    end

    rows_drawn = rows_drawn + 1
  end

  -- Drag-and-drop processing
  if state.fx_dragging then
    state.fx_drag_mouse_y = mouse_y

    -- Check threshold
    if not state.fx_drag_activated then
      if math.abs(mouse_y - state.fx_drag_start_y) > state.fx_drag_threshold then
        state.fx_drag_activated = true
      end
    end

    -- Draw drag visuals when activated
    if state.fx_drag_activated and #row_positions > 0 then
      reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeNS())

      -- Find the dragged entry
      local drag_entry = nil
      for _, rp in ipairs(row_positions) do
        if rp.entry.index == state.fx_drag_src_idx then
          drag_entry = rp.entry
          break
        end
      end

      -- Determine drop target position
      local drop_before_idx = nil
      for ri, rp in ipairs(row_positions) do
        local row_mid = rp.y + row_height / 2
        if mouse_y < row_mid then
          drop_before_idx = rp.entry.index
          local line_y = rp.y
          reaper.ImGui_DrawList_AddLine(draw_list, fx_x + 2, line_y, fx_x + content_width - 2, line_y, 0x4A90D9FF, 2)
          break
        end
      end
      if not drop_before_idx and #row_positions > 0 then
        local last_rp = row_positions[#row_positions]
        drop_before_idx = last_rp.entry.index + 1
        local line_y = last_rp.y + row_height
        reaper.ImGui_DrawList_AddLine(draw_list, fx_x + 2, line_y, fx_x + content_width - 2, line_y, 0x4A90D9FF, 2)
      end

      -- Draw floating dragged row at mouse position
      if drag_entry then
        local float_y = mouse_y - row_height / 2
        reaper.ImGui_DrawList_AddRectFilled(draw_list, fx_x + inner_pad, float_y, fx_x + content_width - inner_pad, float_y + row_height, 0x4A90D9AA)

        local is_enabled = reaper.TakeFX_GetEnabled(take, drag_entry.index)
        local float_bp_x = fx_x + bypass_margin + inner_pad
        local float_bp_y = float_y + (row_height - bypass_size) / 2
        if is_enabled then
          reaper.ImGui_DrawList_AddRectFilled(draw_list, float_bp_x, float_bp_y, float_bp_x + bypass_size, float_bp_y + bypass_size, 0x4A90D9FF, 2)
        else
          reaper.ImGui_DrawList_AddRect(draw_list, float_bp_x, float_bp_y, float_bp_x + bypass_size, float_bp_y + bypass_size, 0x555555FF, 2)
        end

        local float_text_x = fx_x + text_x_offset + inner_pad
        local float_text_y = float_y + (row_height - 13) / 2
        reaper.ImGui_DrawList_AddText(draw_list, float_text_x, float_text_y, 0xFFFFFFFF, drag_entry.name)
      end

      state.fx_drag_drop_target = drop_before_idx
    end

    -- Handle mouse release
    if reaper.ImGui_IsMouseReleased(ctx, 0) then
      if state.fx_drag_activated and state.fx_drag_drop_target then
        local src = state.fx_drag_src_idx
        local dst = state.fx_drag_drop_target

        if dst ~= src and dst ~= src + 1 then
          reaper.Undo_BeginBlock()
          local move_dst = dst
          if src < dst then
            move_dst = dst - 1
          end
          reaper.TakeFX_CopyToTake(take, src, take, move_dst, true)
          reaper.Undo_EndBlock("NVSD_ItemView: Reorder FX", -1)
          fx_cache.state_count = 0
        end
      elseif not state.fx_drag_activated then
        local is_open = reaper.TakeFX_GetOpen(take, state.fx_drag_src_idx)
        if is_open then
          reaper.TakeFX_Show(take, state.fx_drag_src_idx, 2)
        else
          reaper.TakeFX_Show(take, state.fx_drag_src_idx, 3)
        end
      end

      state.fx_dragging = false
      state.fx_drag_src_idx = -1
      state.fx_drag_activated = false
      state.fx_drag_drop_target = nil
    end
  end

  -- Pop clip rect before drawing scrollbar (which sits outside the clipped area)
  if has_clip_rect then
    reaper.ImGui_DrawList_PopClipRect(draw_list)
  end

  -- Draw scrollbar when needed
  if needs_scroll then
    local sb_x = fx_x + fx_width - scrollbar_width - 1
    local sb_top = fx_y + inner_pad
    local sb_height = visible_height

    -- Track background
    reaper.ImGui_DrawList_AddRectFilled(draw_list, sb_x, sb_top, sb_x + scrollbar_width, sb_top + sb_height, 0x1A1A1AFF)

    -- Thumb
    local thumb_ratio = visible_height / content_height
    local thumb_height = math.max(12, sb_height * thumb_ratio)
    local scroll_ratio = state.fx_scroll_offset / max_scroll
    local thumb_y = sb_top + scroll_ratio * (sb_height - thumb_height)

    local mouse_in_scrollbar = mouse_x >= sb_x and mouse_x <= sb_x + scrollbar_width
                               and mouse_y >= sb_top and mouse_y <= sb_top + sb_height
    local thumb_color = mouse_in_scrollbar and 0x666666FF or 0x444444FF
    reaper.ImGui_DrawList_AddRectFilled(draw_list, sb_x, thumb_y, sb_x + scrollbar_width, thumb_y + thumb_height, thumb_color, 2)
  end

  return rows_drawn
end

-- Draw the FX right-click context menu (call once per frame, after draw_fx_list)
function controls.draw_fx_context_menu(ctx, state)
  if reaper.ImGui_BeginPopup(ctx, "fx_context_menu") then
    local take = state.fx_context_menu_take
    local fx_idx = state.fx_context_menu_idx
    if take and fx_idx then
      local is_enabled = reaper.TakeFX_GetEnabled(take, fx_idx)
      local is_offline = reaper.TakeFX_GetOffline(take, fx_idx)

      if reaper.ImGui_MenuItem(ctx, is_enabled and "Bypass" or "Enable") then
        reaper.Undo_BeginBlock()
        reaper.TakeFX_SetEnabled(take, fx_idx, not is_enabled)
        reaper.Undo_EndBlock("NVSD_ItemView: Toggle FX bypass", -1)
      end
      if reaper.ImGui_MenuItem(ctx, is_offline and "Set Online" or "Set Offline") then
        reaper.Undo_BeginBlock()
        reaper.TakeFX_SetOffline(take, fx_idx, not is_offline)
        reaper.Undo_EndBlock("NVSD_ItemView: Toggle FX offline", -1)
      end
      if reaper.ImGui_MenuItem(ctx, "Open FX Chain Window") then
        reaper.TakeFX_Show(take, fx_idx, 1)  -- show chain window
      end
      reaper.ImGui_Separator(ctx)
      if reaper.ImGui_MenuItem(ctx, "Delete FX") then
        reaper.Undo_BeginBlock()
        reaper.TakeFX_Delete(take, fx_idx)
        reaper.Undo_EndBlock("NVSD_ItemView: Delete FX", -1)
        fx_cache.state_count = 0  -- force cache refresh
      end
    end
    reaper.ImGui_EndPopup(ctx)
  end
end

-- Get cached FX count for a take (used by main layout to compute columns)
function controls.get_fx_count(take)
  if not take then return 0 end
  refresh_fx_cache(take)
  return fx_cache.count
end

return controls
