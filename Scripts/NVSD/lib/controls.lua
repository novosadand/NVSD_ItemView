-- NVSD_ItemView - Controls Module
-- Buttons, gain slider, pitch knob, semitones/cents boxes

local controls = {}

-- Check if an external editor is configured in REAPER preferences ([extedit] section)
local function has_external_editor()
  local ini = reaper.get_ini_file()
  if not ini then return false end
  local f = io.open(ini, "r")
  if not f then return false end
  local in_extedit = false
  for line in f:lines() do
    if line:match("^%[extedit%]") then
      in_extedit = true
    elseif in_extedit then
      if line:match("^%[") then break end  -- next section, no entries found
      if line:match("=.+") then
        f:close()
        return true
      end
    end
  end
  f:close()
  return false
end
controls.has_external_editor = has_external_editor

-- Format a tooltip string with optional shortcut key
local function tip_with_key(text, settings, shortcut_name)
  if not settings then return text end
  local sc = settings.current.shortcuts[shortcut_name]
  if sc and sc.key ~= "" then
    return text .. " (" .. settings.format_shortcut(sc) .. ")"
  end
  return text
end

-- Known algorithm sub-mode UI structure (matches REAPER's native Item Properties)
-- structural: names use "Prefix: Core [Suffix]" format
-- defaults: sub-mode names that represent "all off" state (skipped during atom extraction)
-- flags: ordered list of flag groups as shown in REAPER's native dialog
--        atoms not in any flag group become the Mode dropdown entries
local ALGO_UI = {
  [0] = {  -- SoundTouch
    defaults = {["Default settings"] = true},
    flags = {{"multi-stereo", "multi-mono"}},
  },
  [6] = {  -- Elastique 2 Pro
    structural = true,
    defaults = {Normal = true},
    flags = {{"Synchronized"}, {"Mid/Side"}, {"Multi-Stereo", "Multi-Mono"}},
  },
  [7] = {  -- Elastique 2 Efficient
    structural = true,
    defaults = {Normal = true},
    flags = {{"Synchronized"}, {"Mid/Side"}, {"Multi-Stereo", "Multi-Mono"}},
  },
  [8] = {  -- Elastique 2 Soloist
    structural = true,
    defaults = {},
    flags = {{"Mid/Side"}, {"Multi-Stereo", "Multi-Mono"}},
  },
  [9] = {  -- Elastique 3 Pro
    structural = true,
    defaults = {Normal = true},
    flags = {{"Synchronized"}, {"Mid/Side"}, {"Multi-Stereo", "Multi-Mono"}},
  },
  [10] = {  -- Elastique 3 Efficient
    structural = true,
    defaults = {Normal = true},
    flags = {{"Synchronized"}, {"Mid/Side"}, {"Multi-Stereo", "Multi-Mono"}},
  },
  [11] = {  -- Elastique 3 Soloist
    structural = true,
    defaults = {},
    flags = {{"Mid/Side"}, {"Multi-Stereo", "Multi-Mono"}},
  },
  [13] = {  -- Rubber Band Library
    defaults = {Default = true, Normal = true},
    flags = {
      {"Preserve Formants"},
      {"Mid/Side"},
      {"Independent Phase"},
      {"Time Domain Smoothing"},
      {"Transients: Mixed", "Transients: Smooth"},
      {"Detector: Percussive", "Detector: Soft"},
      {"Pitch Mode: HighQ", "Pitch Mode: Consistent"},
      {"Window: Short", "Window: Long"},
      {"Channel Mode: Multi-stereo", "Channel Mode: Multi-mono"},
    },
    -- Mode presets: named shortcuts for mutex flag combinations
    -- (toggle flags like Preserve Formants are independent and preserved across presets)
    presets = {
      {name = "Balanced", atoms = {}},
      {name = "Tonal-optimized", atoms = {"Transients: Smooth", "Detector: Soft", "Pitch Mode: HighQ", "Window: Long"}},
      {name = "Transient-optimized", atoms = {"Detector: Percussive", "Window: Short"}},
      {name = "No pre-echo reduction", atoms = {"Transients: Smooth"}},
    },
  },
}

-- Parse a single sub-mode name into atoms.
-- structural: extract "Prefix: " and " [Suffix]" before comma-splitting core
-- skip_names: set of core names to skip (e.g. {Normal=true, Default=true})
local function parse_name_atoms(name, structural, skip_names)
  local atoms = {}

  if structural then
    -- Extract "Prefix: " (first colon-space separator)
    local pf, rest = name:match("^([^:]+):%s(.+)$")
    if pf then
      atoms[#atoms + 1] = pf
      name = rest
    end

    -- Extract " [Suffix]" from end (loop for multiple brackets like "[Mid/Side] [Multi-Stereo]")
    while true do
      local before, sf = name:match("^(.-)%s+%[(.-)%]%s*$")
      if before and sf then
        atoms[#atoms + 1] = sf
        name = before
      else
        break
      end
    end
  end

  -- Core: comma-split, skip default names
  local core = name:match("^%s*(.-)%s*$") or ""
  if core ~= "" and not (skip_names and skip_names[core]) then
    for part in core:gmatch("[^,]+") do
      local atom = part:match("^%s*(.-)%s*$")
      if atom and atom ~= "" and not (skip_names and skip_names[atom]) then
        atoms[#atoms + 1] = atom
      end
    end
  end

  return atoms
end

-- Build sub-mode flag cache for a given algorithm.
-- Uses ALGO_UI definitions for known algorithms, falls back to auto-detection.
local function parse_submode_flags(sub_modes, algo_id)
  local def = ALGO_UI[algo_id]

  -- Determine format and default names
  local use_structural = false
  local skip_names = {Normal = true, Default = true}

  if def then
    use_structural = def.structural or false
    if def.defaults then skip_names = def.defaults end
  else
    -- Unknown algo: detect structural from bracket suffixes
    for _, sm in ipairs(sub_modes) do
      if (sm.name or ""):match("%[.-%]%s*$") then
        use_structural = true
        break
      end
    end
  end

  -- Enumerate atoms and build flagkey_to_id
  local all_atoms = {}
  local atom_set = {}
  local submode_atoms = {}
  local flagkey_to_id = {}

  for i, sm in ipairs(sub_modes) do
    local name = sm.name or ""
    local atoms = {}

    if name ~= "" and not skip_names[name] then
      atoms = parse_name_atoms(name, use_structural, skip_names)
    end

    for _, atom in ipairs(atoms) do
      if not atom_set[atom] then
        atom_set[atom] = true
        all_atoms[#all_atoms + 1] = atom
      end
    end
    submode_atoms[i] = atoms

    local sorted = {}
    for _, a in ipairs(atoms) do sorted[#sorted + 1] = a end
    table.sort(sorted)
    flagkey_to_id[table.concat(sorted, ",")] = sm.id
  end

  -- Build groups
  local groups = {}
  local mode_group_idx = nil

  if def and def.flags then
    -- Known algorithm: hardcoded flag groups, remaining atoms become mode group
    local flag_atom_set = {}
    for _, fg in ipairs(def.flags) do
      for _, atom in ipairs(fg) do flag_atom_set[atom] = true end
    end

    -- Mode group = discovered atoms not in any hardcoded flag group
    local mode_candidates = {}
    for _, atom in ipairs(all_atoms) do
      if not flag_atom_set[atom] then
        mode_candidates[#mode_candidates + 1] = atom
      end
    end
    if #mode_candidates > 0 then
      groups[1] = mode_candidates
      mode_group_idx = 1
    end

    -- Flag groups (only atoms that actually exist in the enumeration)
    for _, fg in ipairs(def.flags) do
      local existing = {}
      for _, atom in ipairs(fg) do
        if atom_set[atom] then existing[#existing + 1] = atom end
      end
      if #existing > 0 then
        groups[#groups + 1] = existing
      end
    end
  else
    -- Unknown algorithm: auto-detect with co-occurrence analysis + union-find
    local cooccurs = {}
    for _, atoms in ipairs(submode_atoms) do
      for j = 1, #atoms do
        for k = j + 1, #atoms do
          cooccurs[atoms[j]] = cooccurs[atoms[j]] or {}
          cooccurs[atoms[j]][atoms[k]] = true
          cooccurs[atoms[k]] = cooccurs[atoms[k]] or {}
          cooccurs[atoms[k]][atoms[j]] = true
        end
      end
    end

    local parent = {}
    for _, atom in ipairs(all_atoms) do parent[atom] = atom end
    local function find(x)
      while parent[x] ~= x do x = parent[x] end
      return x
    end
    local function union(a, b)
      local ra, rb = find(a), find(b)
      if ra ~= rb then parent[ra] = rb end
    end

    for i = 1, #all_atoms do
      for j = i + 1, #all_atoms do
        local a, b = all_atoms[i], all_atoms[j]
        if not (cooccurs[a] and cooccurs[a][b]) then
          union(a, b)
        end
      end
    end

    local group_map = {}
    for _, atom in ipairs(all_atoms) do
      local root = find(atom)
      if not group_map[root] then group_map[root] = {} end
      group_map[root][#group_map[root] + 1] = atom
    end

    local seen_roots = {}
    for _, atom in ipairs(all_atoms) do
      local root = find(atom)
      if not seen_roots[root] then
        seen_roots[root] = true
        groups[#groups + 1] = group_map[root]
      end
    end

    -- Mode group: the mutex group with most diverse names (lowest LCP fraction)
    local min_lcp_fraction = 1.0
    for gi, group in ipairs(groups) do
      if #group > 1 then
        local lcp_len = #group[1]
        for ii = 2, #group do
          local a, b = group[1], group[ii]
          local match_len = 0
          for c = 1, math.min(#a, #b) do
            if a:sub(c, c) == b:sub(c, c) then match_len = match_len + 1
            else break end
          end
          lcp_len = math.min(lcp_len, match_len)
        end
        local min_name_len = #group[1]
        for ii = 2, #group do
          if #group[ii] < min_name_len then min_name_len = #group[ii] end
        end
        local fraction = min_name_len > 0 and (lcp_len / min_name_len) or 1.0
        if fraction < min_lcp_fraction then
          min_lcp_fraction = fraction
          mode_group_idx = gi
        end
      end
    end
    if min_lcp_fraction > 0.3 then mode_group_idx = nil end
  end

  -- Check if sub-mode 0 has a default/empty name
  local has_default = flagkey_to_id[""] ~= nil
  if not has_default then
    for _, sm in ipairs(sub_modes) do
      if sm.id == 0 and (skip_names[sm.name or ""] or sm.name == "") then
        has_default = true
        flagkey_to_id[""] = 0
        break
      end
    end
  end

  -- Presets and mutex atom set (for preset application)
  local presets = def and def.presets or nil
  local mutex_atoms = nil
  if presets then
    mutex_atoms = {}
    for _, fg in ipairs(def.flags) do
      if #fg > 1 then
        for _, atom in ipairs(fg) do mutex_atoms[atom] = true end
      end
    end
  end

  return {
    groups = groups,
    flagkey_to_id = flagkey_to_id,
    all_atoms = all_atoms,
    mode_group_idx = mode_group_idx,
    has_default = has_default,
    use_structural = use_structural,
    skip_names = skip_names,
    presets = presets,
    mutex_atoms = mutex_atoms,
  }
end

-- Draw WARP/Reverse/Edit buttons in the left column
function controls.draw_button_panel(ctx, draw_list, mouse_x, mouse_y, left_col_x, left_col_y, item, take, config, state, utils, drawing, settings, panel_height, col2_x)
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
    -- Auto-enable warp mode when item has stretch markers
    local sm_count = reaper.GetTakeNumStretchMarkers(take)
    if sm_count > 0 and preserve_pitch == 0 then
      reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 1)
      preserve_pitch = 1
      reaper.UpdateArrange()
    end
    state.warp_mode = preserve_pitch == 1
    -- Per-item saved warp markers (keyed by take GUID)
    if not state.warp_saved_markers_map then
      state.warp_saved_markers_map = {}
    end
  end

  -- Layout visibility flags
  local show_warp = settings.current.layout.show_warp
  local show_buttons = settings.current.layout.show_buttons
  local warp_btn_width = config.LEFT_COLUMN_WIDTH - (btn_padding * 2)
  local any_dropdown_menu_open = false
  local warp_end_y = row_y
  local last_bottom = row_y
  state._dropdown_menu_open = false

  if show_warp then

  -- WARP button
  local warp_btn_x = left_col_x + btn_padding
  local warp_btn_y = row_y

  local mouse_in_warp = mouse_x >= warp_btn_x and mouse_x <= warp_btn_x + warp_btn_width
                        and mouse_y >= warp_btn_y and mouse_y <= warp_btn_y + btn_height

  local warp_bg_color
  if state.warp_mode then
    warp_bg_color = mouse_in_warp and COLOR_BTN_HOVER or COLOR_BTN_ON
  else
    warp_bg_color = mouse_in_warp and COLOR_BTN_HOVER or COLOR_BTN_OFF
  end
  reaper.ImGui_DrawList_AddRectFilled(draw_list, warp_btn_x, warp_btn_y, warp_btn_x + warp_btn_width, warp_btn_y + btn_height, warp_bg_color, 3)
  local warp_text_w = reaper.ImGui_CalcTextSize(ctx, "WARP")
  local warp_text_x = warp_btn_x + (warp_btn_width - warp_text_w) / 2
  local warp_text_y = warp_btn_y + (btn_height - text_height) / 2
  reaper.ImGui_DrawList_AddText(draw_list, warp_text_x, warp_text_y, COLOR_BTN_TEXT, "WARP")

  if mouse_in_warp then
    drawing.tooltip(ctx, "warp_btn", tip_with_key("Preserve pitch when stretching", settings, "toggle_warp"))
  end

  if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_warp then
    state.warp_dropdown_open = false
    if take then
      if not state.warp_mode then
        -- Turning WARP ON
        local take_guid = reaper.BR_GetMediaItemTakeGUID(take)
        local saved = take_guid and state.warp_saved_markers_map[take_guid]
        if saved and #saved > 0 then
          -- Saved markers exist from previous unwarp: show restore modal
          state.warp_restore_popup_open = true
          state.warp_restore_take = take
          state.warp_restore_guid = take_guid
        else
          reaper.Undo_BeginBlock()
          utils.enable_warp(take)
          reaper.UpdateArrange()
          reaper.Undo_EndBlock("NVSD_ItemView: Toggle WARP", -1)
        end
      else
        -- Turning WARP OFF
        reaper.Undo_BeginBlock()
        utils.disable_warp(take, state)
        reaper.UpdateArrange()
        reaper.Undo_EndBlock("NVSD_ItemView: Toggle WARP", -1)
      end
    end
  end

  -- Warp restore modal (centered, styled)
  if state.warp_restore_popup_open then
    reaper.ImGui_OpenPopup(ctx, "##warp_restore")
    state.warp_restore_popup_open = false
  end

  -- Center modal on screen
  local viewport = reaper.ImGui_GetMainViewport(ctx)
  local vp_cx, vp_cy = reaper.ImGui_Viewport_GetCenter(viewport)
  reaper.ImGui_SetNextWindowPos(ctx, vp_cx, vp_cy, reaper.ImGui_Cond_Appearing(), 0.5, 0.5)
  reaper.ImGui_SetNextWindowSize(ctx, 340, 0, reaper.ImGui_Cond_Appearing())

  -- Push modal styling
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 20, 16)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 8)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 8, 8)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(), 0x2A2A2AFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), 0x555555FF)

  local modal_flags = reaper.ImGui_WindowFlags_NoTitleBar()
                    + reaper.ImGui_WindowFlags_AlwaysAutoResize()
                    + reaper.ImGui_WindowFlags_NoMove()

  if reaper.ImGui_BeginPopupModal(ctx, "##warp_restore", nil, modal_flags) then
    -- Title
    local title = "Restore Warp Markers"
    local title_w = reaper.ImGui_CalcTextSize(ctx, title)
    local content_w = reaper.ImGui_GetContentRegionAvail(ctx)
    reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + (content_w - title_w) / 2)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFFFFFFFF)
    reaper.ImGui_Text(ctx, title)
    reaper.ImGui_PopStyleColor(ctx)

    -- Separator
    reaper.ImGui_Spacing(ctx)
    local draw_list = reaper.ImGui_GetWindowDrawList(ctx)
    local sx, sy = reaper.ImGui_GetCursorScreenPos(ctx)
    reaper.ImGui_DrawList_AddLine(draw_list, sx, sy, sx + content_w, sy, 0x444444FF, 1)
    reaper.ImGui_Dummy(ctx, 0, 4)

    -- Description
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xBBBBBBFF)
    reaper.ImGui_TextWrapped(ctx, "This item had warp markers that were saved when WARP was turned off.")
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_Dummy(ctx, 0, 4)

    -- Action buttons
    local guid = state.warp_restore_guid
    local btn_w = (content_w - 8) / 2

    -- "Keep Current" button (subtle)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x404040FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x555555FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x666666FF)
    if reaper.ImGui_Button(ctx, "Keep Current", btn_w, 30) then
      local t = state.warp_restore_take
      if t and reaper.ValidatePtr(t, "MediaItem_Take*") then
        reaper.Undo_BeginBlock()
        utils.enable_warp(t)
        reaper.UpdateArrange()
        reaper.Undo_EndBlock("NVSD_ItemView: Toggle WARP", -1)
      end
      if guid then state.warp_saved_markers_map[guid] = nil end
      state.warp_restore_take = nil
      state.warp_restore_guid = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_PopStyleColor(ctx, 3)

    reaper.ImGui_SameLine(ctx)

    -- "Restore Saved" button (primary/accent)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x4A90D9FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x5AA0E9FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x3A80C9FF)
    if reaper.ImGui_Button(ctx, "Restore Saved", btn_w, 30) then
      local t = state.warp_restore_take
      local saved = guid and state.warp_saved_markers_map[guid]
      if t and reaper.ValidatePtr(t, "MediaItem_Take*") and saved then
        reaper.Undo_BeginBlock()
        utils.enable_warp(t)
        for _, sm in ipairs(saved) do
          reaper.SetTakeStretchMarker(t, -1, sm.pos, sm.srcpos)
        end
        reaper.UpdateArrange()
        reaper.UpdateItemInProject(reaper.GetMediaItemTake_Item(t))
        reaper.Undo_EndBlock("NVSD_ItemView: Restore WARP markers", -1)
      end
      if guid then state.warp_saved_markers_map[guid] = nil end
      state.warp_restore_take = nil
      state.warp_restore_guid = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_PopStyleColor(ctx, 3)

    -- Cancel link (subtle, centered)
    reaper.ImGui_Dummy(ctx, 0, 2)
    local cancel_text = "Cancel"
    local cancel_w = reaper.ImGui_CalcTextSize(ctx, cancel_text)
    reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + (content_w - cancel_w) / 2)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x00000000)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x00000000)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x00000000)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x888888FF)
    if reaper.ImGui_SmallButton(ctx, cancel_text) then
      state.warp_restore_take = nil
      state.warp_restore_guid = nil
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_PopStyleColor(ctx, 4)
    -- Underline on hover
    if reaper.ImGui_IsItemHovered(ctx) then
      local ix, iy = reaper.ImGui_GetItemRectMin(ctx)
      local ix2, iy2 = reaper.ImGui_GetItemRectMax(ctx)
      reaper.ImGui_DrawList_AddLine(draw_list, ix, iy2, ix2, iy2, 0x888888FF, 1)
    end

    reaper.ImGui_EndPopup(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 2)
  reaper.ImGui_PopStyleVar(ctx, 4)

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
    dropdown_bg = mouse_in_dropdown and 0x4A4A4AFF or config.COLOR_GRID_BAR
    text_color = mouse_in_dropdown and 0xFFFFFFFF or config.COLOR_INFO_BAR_TEXT
    arrow_color = mouse_in_dropdown and 0xFFFFFFFF or config.COLOR_RULER_TEXT
  else
    dropdown_bg = config.COLOR_RULER_BG
    text_color = config.COLOR_RULER_TICK
    arrow_color = config.COLOR_RULER_TICK
    state.warp_dropdown_open = false
  end

  -- Truncate algo name if it exceeds available space (before arrow)
  local algo_text_w = reaper.ImGui_CalcTextSize(ctx, current_mode_name)
  local algo_max_text_w = dropdown_width - 15  -- 3px left pad + 12px arrow area
  local algo_display_name = current_mode_name
  local algo_truncated = algo_text_w > algo_max_text_w

  if algo_truncated and not mouse_in_dropdown then
    algo_display_name = current_mode_name
    while #algo_display_name > 1 and reaper.ImGui_CalcTextSize(ctx, algo_display_name .. "...") > algo_max_text_w do
      algo_display_name = algo_display_name:sub(1, -2)
    end
    algo_display_name = algo_display_name .. "..."
  end

  if algo_truncated and mouse_in_dropdown then
    -- Hover expansion: draw wider button on foreground to show full name
    local expanded_w = math.max(dropdown_width, algo_text_w + 15)
    local fg_dl = reaper.ImGui_GetForegroundDrawList(ctx)
    reaper.ImGui_DrawList_AddRectFilled(fg_dl, dropdown_x, dropdown_y, dropdown_x + expanded_w, dropdown_y + dropdown_btn_height, dropdown_bg, 2)
    reaper.ImGui_DrawList_AddRect(fg_dl, dropdown_x, dropdown_y, dropdown_x + expanded_w, dropdown_y + dropdown_btn_height, 0x666666FF, 2)
    reaper.ImGui_DrawList_AddText(fg_dl, dropdown_x + 3, dropdown_y + 1, text_color, current_mode_name)
    reaper.ImGui_DrawList_AddTriangleFilled(fg_dl,
      dropdown_x + expanded_w - 10, dropdown_y + 4,
      dropdown_x + expanded_w - 4, dropdown_y + 4,
      dropdown_x + expanded_w - 7, dropdown_y + dropdown_btn_height - 4,
      arrow_color)
  else
    reaper.ImGui_DrawList_AddRectFilled(draw_list, dropdown_x, dropdown_y, dropdown_x + dropdown_width, dropdown_y + dropdown_btn_height, dropdown_bg, 2)
    reaper.ImGui_DrawList_AddRect(draw_list, dropdown_x, dropdown_y, dropdown_x + dropdown_width, dropdown_y + dropdown_btn_height, mouse_in_dropdown and 0x666666FF or 0x00000000, 2)
    reaper.ImGui_DrawList_AddText(draw_list, dropdown_x + 3, dropdown_y + 1, text_color, algo_display_name)
    reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
      dropdown_x + dropdown_width - 10, dropdown_y + 4,
      dropdown_x + dropdown_width - 4, dropdown_y + 4,
      dropdown_x + dropdown_width - 7, dropdown_y + dropdown_btn_height - 4,
      arrow_color)
  end

  -- Capture before any close handlers run (used to block clicks on buttons underneath)
  -- Must be before any dropdown button handler so the snapshot is available
  any_dropdown_menu_open = state.warp_dropdown_open or state.warp_submode_dropdown_open or state.warp_mode_dropdown_open
  state._dropdown_menu_open = any_dropdown_menu_open

  if mouse_in_dropdown and dropdown_enabled and not state.warp_dropdown_open then
    drawing.tooltip(ctx, "pitch_mode", "Pitch shift algorithm (scroll to cycle)")
  end

  if dropdown_enabled and reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_dropdown
     and (not any_dropdown_menu_open or state.warp_dropdown_open) then
    state.warp_dropdown_open = not state.warp_dropdown_open
    if state.warp_dropdown_open then
      state.warp_submode_dropdown_open = false
      state.warp_mode_dropdown_open = false
    end
  end

  -- Mouse wheel on dropdown: cycle through algorithms
  if dropdown_enabled and mouse_in_dropdown and take then
    local wheel = reaper.ImGui_GetMouseWheel(ctx)
    if wheel ~= 0 then
      local current_idx = 1
      for i, mode in ipairs(config.PITCH_MODES) do
        if mode.value == current_mode or
            (current_mode >= 0 and mode.value >= 0 and (mode.value >> 16) == (current_mode >> 16)) then
          current_idx = i
          break
        end
      end
      local new_idx = current_idx + (wheel > 0 and -1 or 1)
      new_idx = math.max(1, math.min(#config.PITCH_MODES, new_idx))
      if new_idx ~= current_idx then
        reaper.Undo_BeginBlock()
        reaper.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", config.PITCH_MODES[new_idx].value)
        reaper.UpdateArrange()
        reaper.Undo_EndBlock("NVSD_ItemView: Set pitch mode", -1)
        state.warp_submode_dropdown_open = false
        state.warp_mode_dropdown_open = false
        state.warp_submode_scroll_offset = 0  -- Reset scroll on algo change
        state.warp_mode_scroll_offset = 0
        state.warp_submode_flag_cache_algo = -1  -- Invalidate flag cache
      end
    end
  end

  if state.warp_dropdown_open then
    local menu_dl = reaper.ImGui_GetForegroundDrawList(ctx)
    local menu_y = dropdown_y + dropdown_btn_height + 1
    local menu_item_height = 16
    local menu_height = #config.PITCH_MODES * menu_item_height + 4

    reaper.ImGui_DrawList_AddRectFilled(menu_dl, dropdown_x, menu_y, dropdown_x + dropdown_width, menu_y + menu_height, config.COLOR_INFO_BAR_BG, 2)
    reaper.ImGui_DrawList_AddRect(menu_dl, dropdown_x, menu_y, dropdown_x + dropdown_width, menu_y + menu_height, config.COLOR_RULER_TICK, 2)

    for i, mode in ipairs(config.PITCH_MODES) do
      local item_y = menu_y + 2 + (i - 1) * menu_item_height
      local mouse_in_item = mouse_x >= dropdown_x and mouse_x <= dropdown_x + dropdown_width
                            and mouse_y >= item_y and mouse_y <= item_y + menu_item_height

      if mouse_in_item then
        reaper.ImGui_DrawList_AddRectFilled(menu_dl, dropdown_x + 1, item_y, dropdown_x + dropdown_width - 1, item_y + menu_item_height, COLOR_BTN_OFF)
      end

      local item_text_color = (mode.value == current_mode or
        (current_mode >= 0 and mode.value >= 0 and (mode.value >> 16) == (current_mode >> 16)))
        and config.COLOR_MARKER or config.COLOR_INFO_BAR_TEXT
      reaper.ImGui_DrawList_AddText(menu_dl, dropdown_x + 4, item_y + 2, item_text_color, mode.name)

      if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_item then
        if take then
          reaper.Undo_BeginBlock()
          reaper.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", mode.value)
          reaper.UpdateArrange()
          reaper.Undo_EndBlock("NVSD_ItemView: Set pitch mode", -1)
        end
        state.warp_dropdown_open = false
        state.warp_submode_dropdown_open = false
        state.warp_mode_dropdown_open = false
        state.warp_submode_scroll_offset = 0  -- Reset scroll on algo change
        state.warp_mode_scroll_offset = 0
        state.warp_submode_flag_cache_algo = -1  -- Invalidate flag cache
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

  end

  -- Sub-mode dropdown (enumerate sub-modes for current algorithm)
  local sub_modes = {}
  local current_algo_id = current_mode >= 0 and (current_mode >> 16) or -1
  local current_sub_idx = current_mode >= 0 and (current_mode & 0xFFFF) or 0
  local current_sub_name = nil
  local is_project_default = (current_mode < 0)

  -- Resolve "Project default" (-1): pick the algorithm with the most sub-modes
  if take and current_algo_id == -1 and reaper.EnumPitchShiftSubModes then
    if not state._resolved_default_algo then
      local best_id, best_count = -1, 0
      for _, mode in ipairs(config.PITCH_MODES) do
        if mode.value >= 0 then
          local test_id = mode.value >> 16
          local count = 0
          while reaper.EnumPitchShiftSubModes(test_id, count) do count = count + 1 end
          if count > best_count then best_count = count; best_id = test_id end
        end
      end
      state._resolved_default_algo = best_id
    end
    current_algo_id = state._resolved_default_algo
  end

  if take and current_algo_id >= 0 and reaper.EnumPitchShiftSubModes then
    local idx = 0
    while true do
      local sub_name = reaper.EnumPitchShiftSubModes(current_algo_id, idx)
      if not sub_name or sub_name == "" then break end
      sub_modes[#sub_modes + 1] = { id = idx, name = sub_name }
      if idx == current_sub_idx then
        current_sub_name = sub_name
      end
      idx = idx + 1
    end
  end

  if #sub_modes > 0 then
    if not current_sub_name then current_sub_name = sub_modes[1].name end

    -- Build/refresh flag cache
    if current_algo_id ~= state.warp_submode_flag_cache_algo then
      state.warp_submode_flag_cache = parse_submode_flags(sub_modes, current_algo_id)
      state.warp_submode_flag_cache_algo = current_algo_id
    end
    local cache = state.warp_submode_flag_cache

    -- Determine mode group and flag groups
    local mode_group = cache and cache.mode_group_idx and cache.groups[cache.mode_group_idx] or nil
    local flag_groups = {}
    local flag_atoms = {}
    if cache then
      for gi, g in ipairs(cache.groups) do
        if gi ~= cache.mode_group_idx then
          flag_groups[#flag_groups + 1] = g
          for _, atom in ipairs(g) do
            flag_atoms[#flag_atoms + 1] = atom
          end
        end
      end
    end

    -- Parse currently active atoms from sub-mode name
    local active_atoms = {}
    local sn = cache and cache.skip_names
    if current_sub_name and current_sub_name ~= "" and not (sn and sn[current_sub_name]) then
      local atoms = parse_name_atoms(current_sub_name, cache.use_structural, sn)
      for _, atom in ipairs(atoms) do active_atoms[atom] = true end
    end

    -- Helper: apply sub-mode from active atoms set
    local function apply_submode(atoms_set)
      if not cache or not take then return end
      local sorted = {}
      for a, _ in pairs(atoms_set) do sorted[#sorted + 1] = a end
      table.sort(sorted)
      local key = table.concat(sorted, ",")
      local new_sub_id = cache.flagkey_to_id[key]
      if new_sub_id then
        reaper.Undo_BeginBlock()
        local new_pitchmode = (current_algo_id << 16) | new_sub_id
        reaper.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", new_pitchmode)
        reaper.UpdateArrange()
        reaper.Undo_EndBlock("NVSD_ItemView: Set pitch sub-mode", -1)
      end
    end

    -- Disabled state handling
    if not dropdown_enabled then
      state.warp_submode_dropdown_open = false
      state.warp_mode_dropdown_open = false
    end

    -- ===== MODE DROPDOWN (mutually exclusive mode selection OR preset selection) =====
    local has_mode_dropdown = (mode_group and #mode_group > 0) or (cache and cache.presets)
    if has_mode_dropdown then
      local use_presets = cache.presets and not (mode_group and #mode_group > 0)
      local mode_dd_y = warp_btn_y + btn_height + 4 + dropdown_height
      local mode_dd_height = dropdown_btn_height + 6

      -- Current mode name
      local default_label = is_project_default and "Project default" or "Default"
      local current_mode_atom

      if use_presets then
        -- Detect current preset from active mutex atoms
        local active_mutex = {}
        for atom, _ in pairs(active_atoms) do
          if cache.mutex_atoms and cache.mutex_atoms[atom] then
            active_mutex[atom] = true
          end
        end

        current_mode_atom = nil
        for _, preset in ipairs(cache.presets) do
          -- Check if all preset atoms are active and no extra mutex atoms are active
          local match = true
          for _, pa in ipairs(preset.atoms) do
            if not active_mutex[pa] then match = false; break end
          end
          if match then
            -- Also check no extra mutex atoms beyond preset
            local preset_set = {}
            for _, pa in ipairs(preset.atoms) do preset_set[pa] = true end
            for a, _ in pairs(active_mutex) do
              if not preset_set[a] then match = false; break end
            end
          end
          if match then
            current_mode_atom = preset.name
            break
          end
        end
        -- Fallback: first preset if has_default, else show "Custom"
        if not current_mode_atom then
          current_mode_atom = "Custom"
        end
        -- Map "Balanced" (first preset with empty atoms) to default label
        if current_mode_atom == cache.presets[1].name and #cache.presets[1].atoms == 0 and cache.has_default then
          current_mode_atom = default_label
        end
      else
        -- Original mode_group path
        current_mode_atom = cache.has_default and default_label or mode_group[1]
        for _, atom in ipairs(mode_group) do
          if active_atoms[atom] then
            current_mode_atom = atom
            break
          end
        end
      end

      local mouse_in_mode_dd = mouse_x >= dropdown_x and mouse_x <= dropdown_x + dropdown_width
                               and mouse_y >= mode_dd_y and mouse_y <= mode_dd_y + dropdown_btn_height

      local mode_bg, mode_tc, mode_ac
      if dropdown_enabled then
        mode_bg = mouse_in_mode_dd and 0x4A4A4AFF or config.COLOR_GRID_BAR
        mode_tc = mouse_in_mode_dd and 0xFFFFFFFF or config.COLOR_INFO_BAR_TEXT
        mode_ac = mouse_in_mode_dd and 0xFFFFFFFF or config.COLOR_RULER_TEXT
      else
        mode_bg = config.COLOR_RULER_BG
        mode_tc = config.COLOR_RULER_TICK
        mode_ac = config.COLOR_RULER_TICK
      end

      -- Truncation + hover expansion
      local mode_tw = reaper.ImGui_CalcTextSize(ctx, current_mode_atom)
      local mode_max_tw = dropdown_width - 15
      local mode_dn = current_mode_atom
      local mode_trunc = mode_tw > mode_max_tw

      if mode_trunc and not mouse_in_mode_dd then
        mode_dn = current_mode_atom
        while #mode_dn > 1 and reaper.ImGui_CalcTextSize(ctx, mode_dn .. "...") > mode_max_tw do
          mode_dn = mode_dn:sub(1, -2)
        end
        mode_dn = mode_dn .. "..."
      end

      if mode_trunc and mouse_in_mode_dd then
        local ew = math.max(dropdown_width, mode_tw + 15)
        local fg_dl = reaper.ImGui_GetForegroundDrawList(ctx)
        reaper.ImGui_DrawList_AddRectFilled(fg_dl, dropdown_x, mode_dd_y, dropdown_x + ew, mode_dd_y + dropdown_btn_height, mode_bg, 2)
        reaper.ImGui_DrawList_AddRect(fg_dl, dropdown_x, mode_dd_y, dropdown_x + ew, mode_dd_y + dropdown_btn_height, 0x666666FF, 2)
        reaper.ImGui_DrawList_AddText(fg_dl, dropdown_x + 3, mode_dd_y + 1, mode_tc, current_mode_atom)
        reaper.ImGui_DrawList_AddTriangleFilled(fg_dl,
          dropdown_x + ew - 10, mode_dd_y + 4,
          dropdown_x + ew - 4, mode_dd_y + 4,
          dropdown_x + ew - 7, mode_dd_y + dropdown_btn_height - 4, mode_ac)
      else
        reaper.ImGui_DrawList_AddRectFilled(draw_list, dropdown_x, mode_dd_y, dropdown_x + dropdown_width, mode_dd_y + dropdown_btn_height, mode_bg, 2)
        reaper.ImGui_DrawList_AddRect(draw_list, dropdown_x, mode_dd_y, dropdown_x + dropdown_width, mode_dd_y + dropdown_btn_height, mouse_in_mode_dd and 0x666666FF or 0x00000000, 2)
        reaper.ImGui_DrawList_AddText(draw_list, dropdown_x + 3, mode_dd_y + 1, mode_tc, mode_dn)
        reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
          dropdown_x + dropdown_width - 10, mode_dd_y + 4,
          dropdown_x + dropdown_width - 4, mode_dd_y + 4,
          dropdown_x + dropdown_width - 7, mode_dd_y + dropdown_btn_height - 4, mode_ac)
      end

      if mouse_in_mode_dd and dropdown_enabled and not state.warp_mode_dropdown_open
         and not state.warp_dropdown_open and not state.warp_submode_dropdown_open then
        drawing.tooltip(ctx, "pitch_mode_sel", use_presets and "Pitch shift preset" or "Pitch shift mode")
      end

      if dropdown_enabled and reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_mode_dd
         and (not any_dropdown_menu_open or state.warp_mode_dropdown_open) then
        state.warp_mode_dropdown_open = not state.warp_mode_dropdown_open
        if state.warp_mode_dropdown_open then
          state.warp_dropdown_open = false
          state.warp_submode_dropdown_open = false
          state.warp_mode_scroll_offset = 0
        end
      end

      -- Mouse wheel on mode button: cycle through modes/presets
      if dropdown_enabled and mouse_in_mode_dd and take
         and not state.warp_dropdown_open and not state.warp_submode_dropdown_open then
        local wheel = reaper.ImGui_GetMouseWheel(ctx)
        if wheel ~= 0 then
          if use_presets then
            -- Cycle through presets
            local cur_pi = 1  -- default to first preset (Balanced)
            for pi, preset in ipairs(cache.presets) do
              if preset.name == current_mode_atom or
                 (current_mode_atom == default_label and pi == 1 and #preset.atoms == 0) then
                cur_pi = pi
                break
              end
            end
            local new_pi = cur_pi + (wheel > 0 and -1 or 1)
            new_pi = math.max(1, math.min(#cache.presets, new_pi))
            if new_pi ~= cur_pi then
              local new_atoms = {}
              for a, v in pairs(active_atoms) do new_atoms[a] = v end
              -- Clear all mutex atoms
              for a, _ in pairs(cache.mutex_atoms) do new_atoms[a] = nil end
              -- Set preset atoms
              for _, pa in ipairs(cache.presets[new_pi].atoms) do new_atoms[pa] = true end
              apply_submode(new_atoms)
            end
          else
            -- Original mode_group cycling
            local min_mi = cache.has_default and 0 or 1
            local cur_mi = min_mi
            for mi, atom in ipairs(mode_group) do
              if active_atoms[atom] then cur_mi = mi; break end
            end
            local new_mi = cur_mi + (wheel > 0 and -1 or 1)
            new_mi = math.max(min_mi, math.min(#mode_group, new_mi))
            if new_mi ~= cur_mi then
              local new_atoms = {}
              for a, v in pairs(active_atoms) do new_atoms[a] = v end
              for _, g_atom in ipairs(mode_group) do new_atoms[g_atom] = nil end
              if new_mi > 0 then new_atoms[mode_group[new_mi]] = true end
              apply_submode(new_atoms)
            end
          end
        end
      end

      -- Mode dropdown menu
      if state.warp_mode_dropdown_open then
        local menu_dl = reaper.ImGui_GetForegroundDrawList(ctx)
        local mode_menu_y = mode_dd_y + dropdown_btn_height + 1
        local menu_item_height = 16
        local mode_items = {}

        if use_presets then
          -- Build items from presets
          for pi, preset in ipairs(cache.presets) do
            local label = preset.name
            -- First preset with empty atoms uses default label
            if pi == 1 and #preset.atoms == 0 and cache.has_default then
              label = default_label
            end
            mode_items[#mode_items + 1] = {name = label, preset_idx = pi}
          end
        else
          -- Original mode_group items
          if cache.has_default then
            mode_items[#mode_items + 1] = {name = default_label, is_default = true}
          end
          for _, atom in ipairs(mode_group) do
            mode_items[#mode_items + 1] = {name = atom}
          end
        end

        local natural_height = #mode_items * menu_item_height + 4

        local mode_max_menu_tw = 0
        for _, item in ipairs(mode_items) do
          local tw = reaper.ImGui_CalcTextSize(ctx, item.name)
          if tw > mode_max_menu_tw then mode_max_menu_tw = tw end
        end

        -- Cap height to available window space
        local win_x, win_y = reaper.ImGui_GetWindowPos(ctx)
        local _, win_h = reaper.ImGui_GetWindowSize(ctx)
        local available_height = (win_y + win_h) - mode_menu_y - 4
        local visible_height = math.min(natural_height, available_height)
        local needs_scroll = visible_height < natural_height

        local scrollbar_width = needs_scroll and 8 or 0
        local mode_menu_width = math.max(dropdown_width, mode_max_menu_tw + 12) + scrollbar_width

        if not state.warp_mode_scroll_offset then state.warp_mode_scroll_offset = 0 end
        local max_scroll = math.max(0, natural_height - visible_height)
        if state.warp_mode_scroll_offset > max_scroll then state.warp_mode_scroll_offset = max_scroll end
        if state.warp_mode_scroll_offset < 0 then state.warp_mode_scroll_offset = 0 end

        reaper.ImGui_DrawList_AddRectFilled(menu_dl, dropdown_x, mode_menu_y, dropdown_x + mode_menu_width, mode_menu_y + visible_height, config.COLOR_INFO_BAR_BG, 2)
        reaper.ImGui_DrawList_AddRect(menu_dl, dropdown_x, mode_menu_y, dropdown_x + mode_menu_width, mode_menu_y + visible_height, config.COLOR_RULER_TICK, 2)

        local clip_top = mode_menu_y
        local clip_bottom = mode_menu_y + visible_height
        reaper.ImGui_DrawList_PushClipRect(menu_dl, dropdown_x, clip_top, dropdown_x + mode_menu_width, clip_bottom, true)

        local content_width = mode_menu_width - scrollbar_width
        for i, item in ipairs(mode_items) do
          local iy = mode_menu_y + 2 + (i - 1) * menu_item_height - state.warp_mode_scroll_offset

          if iy + menu_item_height > clip_top and iy < clip_bottom then
            local mouse_in_item = mouse_x >= dropdown_x and mouse_x <= dropdown_x + content_width
                                  and mouse_y >= math.max(iy, clip_top)
                                  and mouse_y <= math.min(iy + menu_item_height, clip_bottom)

            if mouse_in_item then
              reaper.ImGui_DrawList_AddRectFilled(menu_dl, dropdown_x + 1, iy, dropdown_x + content_width - 1, iy + menu_item_height, COLOR_BTN_OFF)
            end

            local is_current = item.name == current_mode_atom
            local item_tc = is_current and config.COLOR_MARKER or config.COLOR_INFO_BAR_TEXT
            reaper.ImGui_DrawList_AddText(menu_dl, dropdown_x + 4, iy + 2, item_tc, item.name)

            if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_item and take then
              if use_presets then
                -- Apply preset: keep toggle flags, clear mutex, set preset atoms
                local new_atoms = {}
                for a, v in pairs(active_atoms) do new_atoms[a] = v end
                for a, _ in pairs(cache.mutex_atoms) do new_atoms[a] = nil end
                local preset = cache.presets[item.preset_idx]
                for _, pa in ipairs(preset.atoms) do new_atoms[pa] = true end
                apply_submode(new_atoms)
              else
                -- Original mode_group selection
                local new_atoms = {}
                for a, v in pairs(active_atoms) do new_atoms[a] = v end
                for _, g_atom in ipairs(mode_group) do new_atoms[g_atom] = nil end
                if not item.is_default then new_atoms[item.name] = true end
                apply_submode(new_atoms)
              end
              state.warp_mode_dropdown_open = false
            end
          end
        end

        reaper.ImGui_DrawList_PopClipRect(menu_dl)

        -- Mouse wheel scrolling
        local mouse_in_mode_menu = mouse_x >= dropdown_x and mouse_x <= dropdown_x + mode_menu_width
                                   and mouse_y >= mode_menu_y and mouse_y <= mode_menu_y + visible_height
        if mouse_in_mode_menu and needs_scroll then
          local wheel = reaper.ImGui_GetMouseWheel(ctx)
          if wheel ~= 0 then
            state.warp_mode_scroll_offset = math.max(0, math.min(max_scroll, state.warp_mode_scroll_offset - wheel * menu_item_height))
          end
        end

        -- Scrollbar
        if needs_scroll then
          local sb_w = 6
          local sb_x = dropdown_x + mode_menu_width - sb_w - 1
          local sb_top = mode_menu_y
          local sb_height = visible_height

          reaper.ImGui_DrawList_AddRectFilled(menu_dl, sb_x, sb_top, sb_x + sb_w, sb_top + sb_height, config.COLOR_INFO_BAR_BG)

          local thumb_ratio = visible_height / natural_height
          local thumb_height = math.max(12, sb_height * thumb_ratio)
          local scroll_ratio = state.warp_mode_scroll_offset / max_scroll
          local thumb_y = sb_top + scroll_ratio * (sb_height - thumb_height)

          local mouse_in_sb = mouse_x >= sb_x and mouse_x <= sb_x + sb_w
                              and mouse_y >= sb_top and mouse_y <= sb_top + sb_height
          local mouse_in_thumb = mouse_x >= sb_x and mouse_x <= sb_x + sb_w
                                 and mouse_y >= thumb_y and mouse_y <= thumb_y + thumb_height

          if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_thumb then
            state.warp_mode_sb_dragging = true
            state.warp_mode_sb_drag_start_y = mouse_y
            state.warp_mode_sb_drag_start_scroll = state.warp_mode_scroll_offset
          elseif reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_sb and not mouse_in_thumb then
            local click_ratio = (mouse_y - sb_top) / sb_height
            state.warp_mode_scroll_offset = click_ratio * max_scroll
            state.warp_mode_sb_dragging = true
            state.warp_mode_sb_drag_start_y = mouse_y
            state.warp_mode_sb_drag_start_scroll = state.warp_mode_scroll_offset
          end

          if state.warp_mode_sb_dragging then
            if reaper.ImGui_IsMouseDown(ctx, 0) then
              local delta_y = mouse_y - state.warp_mode_sb_drag_start_y
              local scroll_range = sb_height - thumb_height
              if scroll_range > 0 then
                local delta_scroll = (delta_y / scroll_range) * max_scroll
                state.warp_mode_scroll_offset = math.max(0, math.min(max_scroll,
                  state.warp_mode_sb_drag_start_scroll + delta_scroll))
              end
            else
              state.warp_mode_sb_dragging = false
            end
          end

          local thumb_color = (state.warp_mode_sb_dragging or mouse_in_sb) and config.COLOR_RULER_TEXT or config.COLOR_BTN_OFF
          reaper.ImGui_DrawList_AddRectFilled(menu_dl, sb_x, thumb_y, sb_x + sb_w, thumb_y + thumb_height, thumb_color, 2)
        end

        -- Close on click outside
        if reaper.ImGui_IsMouseClicked(ctx, 0) and not mouse_in_mode_dd and not mouse_in_mode_menu then
          state.warp_mode_dropdown_open = false
        end
      end

      dropdown_height = dropdown_height + mode_dd_height
    end

    -- ===== FLAGS DROPDOWN (checkable options) =====
    if #flag_groups > 0 then
      local flags_dd_y = warp_btn_y + btn_height + 4 + dropdown_height
      local flags_dd_height = dropdown_btn_height + 6

      -- Build flags label from active flag atoms
      local active_flag_names = {}
      for _, g in ipairs(flag_groups) do
        for _, atom in ipairs(g) do
          if active_atoms[atom] then active_flag_names[#active_flag_names + 1] = atom end
        end
      end
      local flags_label = #active_flag_names > 0 and table.concat(active_flag_names, ", ") or "Options"

      local mouse_in_flags_dd = mouse_x >= dropdown_x and mouse_x <= dropdown_x + dropdown_width
                                and mouse_y >= flags_dd_y and mouse_y <= flags_dd_y + dropdown_btn_height

      local fl_bg, fl_tc, fl_ac
      if dropdown_enabled then
        fl_bg = mouse_in_flags_dd and 0x4A4A4AFF or config.COLOR_GRID_BAR
        fl_tc = mouse_in_flags_dd and 0xFFFFFFFF or config.COLOR_INFO_BAR_TEXT
        fl_ac = mouse_in_flags_dd and 0xFFFFFFFF or config.COLOR_RULER_TEXT
      else
        fl_bg = config.COLOR_RULER_BG
        fl_tc = config.COLOR_RULER_TICK
        fl_ac = config.COLOR_RULER_TICK
      end

      -- Truncation + hover expansion
      local fl_tw = reaper.ImGui_CalcTextSize(ctx, flags_label)
      local fl_max_tw = dropdown_width - 15
      local fl_dn = flags_label
      local fl_trunc = fl_tw > fl_max_tw

      if fl_trunc and not mouse_in_flags_dd then
        fl_dn = flags_label
        while #fl_dn > 1 and reaper.ImGui_CalcTextSize(ctx, fl_dn .. "...") > fl_max_tw do
          fl_dn = fl_dn:sub(1, -2)
        end
        fl_dn = fl_dn .. "..."
      end

      if fl_trunc and mouse_in_flags_dd then
        local ew = math.max(dropdown_width, fl_tw + 15)
        local fg_dl = reaper.ImGui_GetForegroundDrawList(ctx)
        reaper.ImGui_DrawList_AddRectFilled(fg_dl, dropdown_x, flags_dd_y, dropdown_x + ew, flags_dd_y + dropdown_btn_height, fl_bg, 2)
        reaper.ImGui_DrawList_AddRect(fg_dl, dropdown_x, flags_dd_y, dropdown_x + ew, flags_dd_y + dropdown_btn_height, 0x666666FF, 2)
        reaper.ImGui_DrawList_AddText(fg_dl, dropdown_x + 3, flags_dd_y + 1, fl_tc, flags_label)
        reaper.ImGui_DrawList_AddTriangleFilled(fg_dl,
          dropdown_x + ew - 10, flags_dd_y + 4,
          dropdown_x + ew - 4, flags_dd_y + 4,
          dropdown_x + ew - 7, flags_dd_y + dropdown_btn_height - 4, fl_ac)
      else
        reaper.ImGui_DrawList_AddRectFilled(draw_list, dropdown_x, flags_dd_y, dropdown_x + dropdown_width, flags_dd_y + dropdown_btn_height, fl_bg, 2)
        reaper.ImGui_DrawList_AddRect(draw_list, dropdown_x, flags_dd_y, dropdown_x + dropdown_width, flags_dd_y + dropdown_btn_height, mouse_in_flags_dd and 0x666666FF or 0x00000000, 2)
        reaper.ImGui_DrawList_AddText(draw_list, dropdown_x + 3, flags_dd_y + 1, fl_tc, fl_dn)
        reaper.ImGui_DrawList_AddTriangleFilled(draw_list,
          dropdown_x + dropdown_width - 10, flags_dd_y + 4,
          dropdown_x + dropdown_width - 4, flags_dd_y + 4,
          dropdown_x + dropdown_width - 7, flags_dd_y + dropdown_btn_height - 4, fl_ac)
      end

      if mouse_in_flags_dd and dropdown_enabled and not state.warp_submode_dropdown_open
         and not state.warp_dropdown_open and not state.warp_mode_dropdown_open then
        drawing.tooltip(ctx, "pitch_flags", "Pitch shift options")
      end

      if dropdown_enabled and reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_flags_dd
         and (not any_dropdown_menu_open or state.warp_submode_dropdown_open) then
        state.warp_submode_dropdown_open = not state.warp_submode_dropdown_open
        if state.warp_submode_dropdown_open then
          state.warp_dropdown_open = false
          state.warp_mode_dropdown_open = false
          state.warp_submode_scroll_offset = 0
        end
      end

      -- Mouse wheel on flags button: cycle through raw sub-modes
      if dropdown_enabled and mouse_in_flags_dd and take
         and not state.warp_dropdown_open and not state.warp_mode_dropdown_open then
        local wheel = reaper.ImGui_GetMouseWheel(ctx)
        if wheel ~= 0 then
          local cur_sub_list_idx = 1
          for i, sm in ipairs(sub_modes) do
            if sm.id == current_sub_idx then cur_sub_list_idx = i; break end
          end
          local new_sub_list_idx = cur_sub_list_idx + (wheel > 0 and -1 or 1)
          new_sub_list_idx = math.max(1, math.min(#sub_modes, new_sub_list_idx))
          if new_sub_list_idx ~= cur_sub_list_idx then
            reaper.Undo_BeginBlock()
            local new_pitchmode = (current_algo_id << 16) | sub_modes[new_sub_list_idx].id
            reaper.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", new_pitchmode)
            reaper.UpdateArrange()
            reaper.Undo_EndBlock("NVSD_ItemView: Set pitch sub-mode", -1)
          end
        end
      end

      -- Flags checkbox menu
      if state.warp_submode_dropdown_open then
        local menu_dl = reaper.ImGui_GetForegroundDrawList(ctx)
        local flags_menu_y = flags_dd_y + dropdown_btn_height + 1
        local item_h = 18
        local sep_h = 8
        local check_pad = 20

        -- Compute menu dimensions (no separator between consecutive singletons)
        local total_items_h = 0
        for gi, group in ipairs(flag_groups) do
          if gi > 1 then
            local prev = flag_groups[gi - 1]
            local both_single = (#prev == 1 and #group == 1)
            if not both_single then total_items_h = total_items_h + sep_h end
          end
          total_items_h = total_items_h + #group * item_h
        end
        total_items_h = total_items_h + 4

        local max_text_w = 0
        for _, atom in ipairs(flag_atoms) do
          local tw = reaper.ImGui_CalcTextSize(ctx, atom)
          if tw > max_text_w then max_text_w = tw end
        end
        local menu_width = math.max(dropdown_width, max_text_w + check_pad + 8)

        -- Cap height
        local win_x, win_y = reaper.ImGui_GetWindowPos(ctx)
        local _, win_h = reaper.ImGui_GetWindowSize(ctx)
        local window_bottom = win_y + win_h
        local natural_height = total_items_h
        local available_height = window_bottom - flags_menu_y - 4
        local visible_height = math.min(natural_height, available_height)
        local needs_scroll = visible_height < natural_height

        local scrollbar_width = needs_scroll and 8 or 0
        local total_menu_width = menu_width + scrollbar_width

        local max_scroll = math.max(0, natural_height - visible_height)
        if state.warp_submode_scroll_offset > max_scroll then state.warp_submode_scroll_offset = max_scroll end
        if state.warp_submode_scroll_offset < 0 then state.warp_submode_scroll_offset = 0 end

        reaper.ImGui_DrawList_AddRectFilled(menu_dl, dropdown_x, flags_menu_y, dropdown_x + total_menu_width, flags_menu_y + visible_height, config.COLOR_INFO_BAR_BG, 2)
        reaper.ImGui_DrawList_AddRect(menu_dl, dropdown_x, flags_menu_y, dropdown_x + total_menu_width, flags_menu_y + visible_height, config.COLOR_RULER_TICK, 2)

        local clip_top = flags_menu_y
        local clip_bottom = flags_menu_y + visible_height
        reaper.ImGui_DrawList_PushClipRect(menu_dl, dropdown_x, clip_top, dropdown_x + total_menu_width, clip_bottom, true)

        local draw_y = flags_menu_y + 2 - state.warp_submode_scroll_offset
        for gi, group in ipairs(flag_groups) do
          -- Separator between groups (skip between consecutive singletons)
          if gi > 1 then
            local prev = flag_groups[gi - 1]
            local both_single = (#prev == 1 and #group == 1)
            if not both_single then
              local sep_y = draw_y + sep_h / 2
              if sep_y > clip_top and sep_y < clip_bottom then
                reaper.ImGui_DrawList_AddLine(menu_dl,
                  dropdown_x + 4, sep_y, dropdown_x + menu_width - 4, sep_y,
                  config.COLOR_RULER_TICK, 1)
              end
              draw_y = draw_y + sep_h
            end
          end

          local is_mutex = #group > 1

          for fi, atom in ipairs(group) do
            local iy = draw_y
            draw_y = draw_y + item_h

            if iy + item_h > clip_top and iy < clip_bottom then
              local mouse_in_item = mouse_x >= dropdown_x and mouse_x <= dropdown_x + menu_width
                and mouse_y >= math.max(iy, clip_top)
                and mouse_y <= math.min(iy + item_h, clip_bottom)

              if mouse_in_item then
                reaper.ImGui_DrawList_AddRectFilled(menu_dl,
                  dropdown_x + 1, iy, dropdown_x + menu_width - 1, iy + item_h,
                  COLOR_BTN_OFF)
              end

              local is_active = active_atoms[atom]
              local check_text = is_active and "v" or "  "
              local flag_text_color = is_active and config.COLOR_MARKER or config.COLOR_INFO_BAR_TEXT

              reaper.ImGui_DrawList_AddText(menu_dl,
                dropdown_x + 4, iy + 2, flag_text_color, check_text)
              reaper.ImGui_DrawList_AddText(menu_dl,
                dropdown_x + check_pad, iy + 2, flag_text_color, atom)

              if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_item and take then
                local new_atoms = {}
                for a, v in pairs(active_atoms) do new_atoms[a] = v end

                if is_mutex then
                  for _, g_atom in ipairs(group) do new_atoms[g_atom] = nil end
                  if not is_active then new_atoms[atom] = true end
                else
                  new_atoms[atom] = not is_active or nil
                end

                apply_submode(new_atoms)
              end
            end
          end
        end

        reaper.ImGui_DrawList_PopClipRect(menu_dl)

        -- Scroll + scrollbar + close-outside
        local mouse_in_menu_area = mouse_x >= dropdown_x and mouse_x <= dropdown_x + total_menu_width
                                   and mouse_y >= flags_menu_y and mouse_y <= flags_menu_y + visible_height
        if mouse_in_menu_area and needs_scroll then
          local wheel = reaper.ImGui_GetMouseWheel(ctx)
          if wheel ~= 0 then
            state.warp_submode_scroll_offset = math.max(0, math.min(max_scroll, state.warp_submode_scroll_offset - wheel * item_h))
          end
        end

        if needs_scroll then
          local sb_w = 6
          local sb_x = dropdown_x + total_menu_width - sb_w - 1
          local sb_top = flags_menu_y
          local sb_height = visible_height

          reaper.ImGui_DrawList_AddRectFilled(menu_dl, sb_x, sb_top, sb_x + sb_w, sb_top + sb_height, config.COLOR_INFO_BAR_BG)

          local thumb_ratio = visible_height / natural_height
          local thumb_height = math.max(12, sb_height * thumb_ratio)
          local scroll_ratio = state.warp_submode_scroll_offset / max_scroll
          local thumb_y = sb_top + scroll_ratio * (sb_height - thumb_height)

          local mouse_in_sb = mouse_x >= sb_x and mouse_x <= sb_x + sb_w
                              and mouse_y >= sb_top and mouse_y <= sb_top + sb_height
          local mouse_in_thumb = mouse_x >= sb_x and mouse_x <= sb_x + sb_w
                                 and mouse_y >= thumb_y and mouse_y <= thumb_y + thumb_height

          if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_thumb then
            state.warp_submode_sb_dragging = true
            state.warp_submode_sb_drag_start_y = mouse_y
            state.warp_submode_sb_drag_start_scroll = state.warp_submode_scroll_offset
          end

          if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_sb and not mouse_in_thumb then
            local click_ratio = (mouse_y - sb_top - thumb_height / 2) / (sb_height - thumb_height)
            click_ratio = math.max(0, math.min(1, click_ratio))
            state.warp_submode_scroll_offset = click_ratio * max_scroll
            state.warp_submode_sb_dragging = true
            state.warp_submode_sb_drag_start_y = mouse_y
            state.warp_submode_sb_drag_start_scroll = state.warp_submode_scroll_offset
          end

          if state.warp_submode_sb_dragging then
            if reaper.ImGui_IsMouseDown(ctx, 0) then
              local delta_y = mouse_y - state.warp_submode_sb_drag_start_y
              local scroll_range = sb_height - thumb_height
              if scroll_range > 0 then
                local delta_scroll = (delta_y / scroll_range) * max_scroll
                state.warp_submode_scroll_offset = math.max(0, math.min(max_scroll,
                  state.warp_submode_sb_drag_start_scroll + delta_scroll))
              end
            else
              state.warp_submode_sb_dragging = false
            end
          end

          local thumb_color = (state.warp_submode_sb_dragging or mouse_in_sb) and config.COLOR_RULER_TEXT or config.COLOR_BTN_OFF
          reaper.ImGui_DrawList_AddRectFilled(menu_dl, sb_x, thumb_y, sb_x + sb_w, thumb_y + thumb_height, thumb_color, 2)
        else
          state.warp_submode_sb_dragging = false
        end

        if reaper.ImGui_IsMouseClicked(ctx, 0) and not mouse_in_flags_dd and not mouse_in_menu_area
           and not state.warp_submode_sb_dragging then
          state.warp_submode_dropdown_open = false
        end
      end

      dropdown_height = dropdown_height + flags_dd_height
    end
  end

  warp_end_y = warp_btn_y + btn_height + 4 + dropdown_height
  else
    -- When warp hidden, ensure dropdown state is clean
    state.warp_dropdown_open = false
    state.warp_submode_dropdown_open = false
    state.warp_mode_dropdown_open = false
  end -- if show_warp

  -- Progressive overflow: buttons that don't fit in col 1 move to col 2
  local panel_bottom = left_col_y + panel_height
  local cursor_x = left_col_x
  local cursor_y = warp_end_y
  local col1_end, overflowed
  local gap = 6

  local function try_overflow(h)
    if not overflowed and col2_x and cursor_y + h > panel_bottom then
      overflowed = true
      col1_end = cursor_y
      cursor_x = col2_x
      cursor_y = left_col_y + 10
    end
  end

  -- CLEAR button (reset to default state)
  if show_warp then
  try_overflow(20)
  local clear_btn_y = cursor_y
  local clear_btn_x = cursor_x + btn_padding
  local clear_btn_width = warp_btn_width
  local clear_btn_height = 20

  local mouse_in_clear = mouse_x >= clear_btn_x and mouse_x <= clear_btn_x + clear_btn_width
                         and mouse_y >= clear_btn_y and mouse_y <= clear_btn_y + clear_btn_height
                         and not any_dropdown_menu_open

  local clear_bg_color = mouse_in_clear and COLOR_BTN_HOVER or COLOR_BTN_OFF
  reaper.ImGui_DrawList_AddRectFilled(draw_list, clear_btn_x, clear_btn_y, clear_btn_x + clear_btn_width, clear_btn_y + clear_btn_height, clear_bg_color, 3)
  local clear_text_w = reaper.ImGui_CalcTextSize(ctx, "Clear")
  local clear_text_x = clear_btn_x + (clear_btn_width - clear_text_w) / 2
  local clear_text_y = clear_btn_y + (clear_btn_height - text_height) / 2
  reaper.ImGui_DrawList_AddText(draw_list, clear_text_x, clear_text_y, COLOR_BTN_TEXT, "Clear")

  if mouse_in_clear then
    drawing.tooltip(ctx, "clear_btn", tip_with_key("Reset pitch and playrate", settings, "clear"))
  end

  if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_clear then
    if take and item then
      reaper.Undo_BeginBlock()
      local current_playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
      local current_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local original_length = current_length * current_playrate
      reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", 0)
      reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", 1.0)
      reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 0)
      reaper.SetMediaItemInfo_Value(item, "D_LENGTH", original_length)
      utils.clamp_fades_to_length(item, original_length)
      reaper.UpdateArrange()
      reaper.Undo_EndBlock("NVSD_ItemView: Clear pitch/speed", -1)
    end
  end

  last_bottom = clear_btn_y + clear_btn_height
  cursor_y = last_bottom + 4
  end -- if show_warp (clear button)

  if show_buttons then
  -- Stretch x2 / /2 buttons (Ableton-style double/half speed)
  try_overflow(20)
  local stretch_row_y = cursor_y
  local stretch_btn_width = math.floor((warp_btn_width - gap) / 2)
  local x2_btn_x = cursor_x + btn_padding
  local half_btn_x = x2_btn_x + stretch_btn_width + gap
  local stretch_btn_height = 20

  local mouse_in_x2 = mouse_x >= x2_btn_x and mouse_x <= x2_btn_x + stretch_btn_width
                       and mouse_y >= stretch_row_y and mouse_y <= stretch_row_y + stretch_btn_height
  local mouse_in_half = mouse_x >= half_btn_x and mouse_x <= half_btn_x + stretch_btn_width
                        and mouse_y >= stretch_row_y and mouse_y <= stretch_row_y + stretch_btn_height

  local x2_bg = mouse_in_x2 and COLOR_BTN_HOVER or COLOR_BTN_OFF
  local half_bg = mouse_in_half and COLOR_BTN_HOVER or COLOR_BTN_OFF
  reaper.ImGui_DrawList_AddRectFilled(draw_list, x2_btn_x, stretch_row_y, x2_btn_x + stretch_btn_width, stretch_row_y + stretch_btn_height, x2_bg, 3)
  reaper.ImGui_DrawList_AddRectFilled(draw_list, half_btn_x, stretch_row_y, half_btn_x + stretch_btn_width, stretch_row_y + stretch_btn_height, half_bg, 3)

  local x2_text_w = reaper.ImGui_CalcTextSize(ctx, "x2")
  reaper.ImGui_DrawList_AddText(draw_list, x2_btn_x + (stretch_btn_width - x2_text_w) / 2, stretch_row_y + (stretch_btn_height - text_height) / 2, COLOR_BTN_TEXT, "x2")
  local half_text_w = reaper.ImGui_CalcTextSize(ctx, "/2")
  reaper.ImGui_DrawList_AddText(draw_list, half_btn_x + (stretch_btn_width - half_text_w) / 2, stretch_row_y + (stretch_btn_height - text_height) / 2, COLOR_BTN_TEXT, "/2")

  if mouse_in_x2 and not any_dropdown_menu_open then
    drawing.tooltip(ctx, "x2_btn", "Double speed (halve length)")
  end
  if mouse_in_half and not any_dropdown_menu_open then
    drawing.tooltip(ctx, "half_btn", "Half speed (double length)")
  end

  -- x2 click: double speed
  if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_x2 and not any_dropdown_menu_open then
    if take and item then
      reaper.Undo_BeginBlock()
      local cur_playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
      local cur_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      -- Double playrate, halve length
      reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", cur_playrate * 2)
      reaper.SetMediaItemInfo_Value(item, "D_LENGTH", cur_length * 0.5)
      -- Scale stretch marker positions to maintain relative timing
      local sm_count = reaper.GetTakeNumStretchMarkers(take)
      for i = 0, sm_count - 1 do
        local _, pos, srcpos = reaper.GetTakeStretchMarker(take, i)
        reaper.SetTakeStretchMarker(take, i, pos * 0.5, srcpos)
      end
      reaper.UpdateItemInProject(item)
      reaper.UpdateArrange()
      state.warp_markers = utils.get_stretch_markers(take)
      state.pending_cache_invalidation = 3
      reaper.Undo_EndBlock("NVSD_ItemView: Stretch x2", -1)
    end
  end

  -- /2 click: half speed
  if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_half and not any_dropdown_menu_open then
    if take and item then
      reaper.Undo_BeginBlock()
      local cur_playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
      local cur_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      -- Halve playrate, double length
      reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", cur_playrate * 0.5)
      reaper.SetMediaItemInfo_Value(item, "D_LENGTH", cur_length * 2)
      -- Scale stretch marker positions to maintain relative timing
      local sm_count = reaper.GetTakeNumStretchMarkers(take)
      for i = 0, sm_count - 1 do
        local _, pos, srcpos = reaper.GetTakeStretchMarker(take, i)
        reaper.SetTakeStretchMarker(take, i, pos * 2, srcpos)
      end
      reaper.UpdateItemInProject(item)
      reaper.UpdateArrange()
      state.warp_markers = utils.get_stretch_markers(take)
      state.pending_cache_invalidation = 3
      reaper.Undo_EndBlock("NVSD_ItemView: Stretch /2", -1)
    end
  end

  -- Second row: Reverse and Edit
  cursor_y = stretch_row_y + stretch_btn_height + 4
  try_overflow(btn_height)
  local row2_y = cursor_y
  local rev_btn_width = 60
  local edit_btn_width = config.LEFT_COLUMN_WIDTH - (btn_padding * 2) - rev_btn_width - gap

  -- REVERSE button
  local rev_btn_x = cursor_x + btn_padding

  local mouse_in_rev = mouse_x >= rev_btn_x and mouse_x <= rev_btn_x + rev_btn_width
                       and mouse_y >= row2_y and mouse_y <= row2_y + btn_height

  local rev_bg_color = mouse_in_rev and COLOR_BTN_HOVER or COLOR_BTN_OFF
  reaper.ImGui_DrawList_AddRectFilled(draw_list, rev_btn_x, row2_y, rev_btn_x + rev_btn_width, row2_y + btn_height, rev_bg_color, 3)
  local rev_text_w = reaper.ImGui_CalcTextSize(ctx, "Reverse")
  local rev_text_x = rev_btn_x + (rev_btn_width - rev_text_w) / 2
  local rev_text_y = row2_y + (btn_height - text_height) / 2
  reaper.ImGui_DrawList_AddText(draw_list, rev_text_x, rev_text_y, COLOR_BTN_TEXT, "Reverse")

  if mouse_in_rev and not any_dropdown_menu_open then
    drawing.tooltip(ctx, "reverse_btn", tip_with_key("Reverse audio", settings, "reverse"))
  end

  if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_rev and not any_dropdown_menu_open then
    if item then
      utils.reverse_item(item, state)
    end
  end

  -- EDIT button
  local edit_btn_x = rev_btn_x + rev_btn_width + gap

  local mouse_in_edit = mouse_x >= edit_btn_x and mouse_x <= edit_btn_x + edit_btn_width
                        and mouse_y >= row2_y and mouse_y <= row2_y + btn_height

  local edit_bg_color = mouse_in_edit and COLOR_BTN_HOVER or COLOR_BTN_OFF
  reaper.ImGui_DrawList_AddRectFilled(draw_list, edit_btn_x, row2_y, edit_btn_x + edit_btn_width, row2_y + btn_height, edit_bg_color, 3)
  local edit_text_w = reaper.ImGui_CalcTextSize(ctx, "Edit")
  local edit_text_x = edit_btn_x + (edit_btn_width - edit_text_w) / 2
  local edit_text_y = row2_y + (btn_height - text_height) / 2
  reaper.ImGui_DrawList_AddText(draw_list, edit_text_x, edit_text_y, COLOR_BTN_TEXT, "Edit")

  if mouse_in_edit and not any_dropdown_menu_open then
    drawing.tooltip(ctx, "edit_btn", tip_with_key("Open in editor", settings, "open_editor"))
  end

  if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_edit and not any_dropdown_menu_open then
    if item then
      utils.open_editor(item, has_external_editor)
    end
  end

  -- Third row: Loop toggle
  cursor_y = row2_y + btn_height + 4
  try_overflow(btn_height)
  local row3_y = cursor_y
  local loop_btn_width = config.LEFT_COLUMN_WIDTH - (btn_padding * 2)
  local loop_btn_x = cursor_x + btn_padding

  local is_looped = item and reaper.GetMediaItemInfo_Value(item, "B_LOOPSRC") == 1

  local mouse_in_loop = mouse_x >= loop_btn_x and mouse_x <= loop_btn_x + loop_btn_width
                        and mouse_y >= row3_y and mouse_y <= row3_y + btn_height

  local loop_bg_color = is_looped and 0x3A5A3AFF
    or mouse_in_loop and COLOR_BTN_HOVER
    or COLOR_BTN_OFF
  reaper.ImGui_DrawList_AddRectFilled(draw_list, loop_btn_x, row3_y, loop_btn_x + loop_btn_width, row3_y + btn_height, loop_bg_color, 3)
  local loop_label = is_looped and "Loop ON" or "Loop"
  local loop_text_w = reaper.ImGui_CalcTextSize(ctx, loop_label)
  local loop_text_x = loop_btn_x + (loop_btn_width - loop_text_w) / 2
  local loop_text_y = row3_y + (btn_height - text_height) / 2
  local loop_text_color = is_looped and 0x88DD88FF or COLOR_BTN_TEXT
  reaper.ImGui_DrawList_AddText(draw_list, loop_text_x, loop_text_y, loop_text_color, loop_label)

  if mouse_in_loop and not any_dropdown_menu_open then
    drawing.tooltip(ctx, "loop_btn", "Toggle loop source")
  end

  if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_loop and not any_dropdown_menu_open then
    if item then
      reaper.Undo_BeginBlock()
      local new_val = is_looped and 0 or 1
      reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", new_val)
      reaper.UpdateItemInProject(item)
      reaper.UpdateArrange()
      reaper.Undo_EndBlock("NVSD_ItemView: Toggle loop source", -1)
    end
  end

  last_bottom = row3_y + btn_height
  end -- if show_buttons

  return col1_end or last_bottom, overflowed and last_bottom or nil
end

-- Draw gain slider with tick marks
function controls.draw_gain_slider(ctx, draw_list, mouse_x, mouse_y, panel_x, panel_y, panel_split, item, item_vol, config, state, utils, drawing)
  local item_db = utils.gain_to_db(item_vol)
  local slider_pos = utils.db_to_slider(item_db)

  local slider_x = panel_x + (config.LEFT_PANEL_WIDTH - config.GAIN_SLIDER_WIDTH) / 2 - 2
  local available = panel_split - panel_y
  local pad = math.max(2, math.min(20, (available - 40) * 0.25))
  local label_h = (available < 100) and 10 or 14
  local slider_top = panel_y + pad + label_h
  local slider_bottom = panel_split - pad - label_h
  local slider_height = slider_bottom - slider_top
  if slider_height < 20 then return end

  local COLOR_SLIDER_TRACK = config.COLOR_BTN_OFF
  local COLOR_SLIDER_FILL = config.COLOR_MARKER
  local COLOR_SLIDER_HANDLE = config.COLOR_INFO_BAR_TEXT
  local COLOR_SLIDER_HANDLE_HOVER = config.COLOR_BTN_TEXT
  local COLOR_ZERO_LINE = config.COLOR_RULER_TEXT
  local COLOR_TICK = config.COLOR_RULER_TICK
  local COLOR_TICK_MAJOR = config.COLOR_RULER_TEXT
  local COLOR_LABEL = config.COLOR_RULER_TEXT

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
                          and not (state.is_any_control_dragging() and not state.is_dragging("gain"))
  local handle_color = (mouse_in_slider or state.is_dragging("gain")) and COLOR_SLIDER_HANDLE_HOVER or COLOR_SLIDER_HANDLE
  reaper.ImGui_DrawList_AddRectFilled(draw_list, slider_x - 2, handle_y - handle_height/2, slider_x + config.GAIN_SLIDER_WIDTH + 2, handle_y + handle_height/2, handle_color, 3)

  if mouse_in_slider and not state.is_dragging("gain") and drawing then
    drawing.tooltip(ctx, "gain_slider", "Item volume\nCtrl+drag for fine control\nDouble-click to reset")
  end

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
      state.drag_cumulative_delta_y = 0
      state.drag_controls.gain.start_y = mouse_y  -- rebase for ImGui fallback path
    elseif new_pos < 0 then
      new_pos = 0
      state.drag_controls.gain.start_value = 0
      state.drag_cumulative_delta_y = 0
      state.drag_controls.gain.start_y = mouse_y
    end

    local new_db = utils.slider_to_db(new_pos)
    local new_gain = utils.db_to_gain(new_db)
    reaper.SetMediaItemInfo_Value(item, "D_VOL", new_gain)
    reaper.UpdateItemInProject(item)
  end

  local slider_center_x = slider_x + config.GAIN_SLIDER_WIDTH / 2
  reaper.ImGui_DrawList_AddText(draw_list, slider_center_x - 14, panel_y + math.max(1, pad - 4), config.COLOR_INFO_BAR_TEXT, "Gain")
  local db_text = utils.format_db(item_db)
  local db_text_w = reaper.ImGui_CalcTextSize(ctx, db_text)
  local db_gap = math.max(4, math.min(8, pad - 1))
  reaper.ImGui_DrawList_AddText(draw_list, slider_center_x - db_text_w / 2, slider_bottom + db_gap, config.COLOR_INFO_BAR_TEXT, db_text)

end

-- Draw pan knob
function controls.draw_pan_knob(ctx, draw_list, mouse_x, mouse_y, panel_x, panel_top, panel_bottom, item, take, config, state, utils, drawing, settings)
  local take_pan = 0
  if take then
    take_pan = reaper.GetMediaItemTakeInfo_Value(take, "D_PAN")
    if math.abs(take_pan) < 0.005 then take_pan = 0 end
  end

  local knob_cx = panel_x + config.LEFT_PANEL_WIDTH / 2 - 2
  local knob_cy = panel_top + (panel_bottom - panel_top) / 2
  local knob_angle = utils.pan_to_angle(take_pan)

  local knob_dx = mouse_x - knob_cx
  local knob_dy = mouse_y - knob_cy
  local knob_dist = math.sqrt(knob_dx * knob_dx + knob_dy * knob_dy)
  local mouse_in_knob = knob_dist <= config.PITCH_KNOB_RADIUS + 8
                        and not (state.is_any_control_dragging() and not state.is_dragging("pan"))

  drawing.draw_knob(draw_list, knob_cx, knob_cy, config.PITCH_KNOB_RADIUS, knob_angle,
    mouse_in_knob, state.is_dragging("pan"), "Pan", nil, config)

  if mouse_in_knob and not state.is_dragging("pan") then
    drawing.tooltip(ctx, "pan_knob", "Pan\nDouble-click to reset\nCtrl+drag for fine control")
  end

  -- Pan value label below knob
  local pan_text = utils.format_pan(take_pan)
  local pan_text_w = #pan_text * 6
  reaper.ImGui_DrawList_AddText(draw_list, knob_cx - pan_text_w / 2,
    knob_cy + config.PITCH_KNOB_RADIUS + 2, config.COLOR_RULER_TEXT, pan_text)

  -- Double-click reset to center
  if reaper.ImGui_IsMouseDoubleClicked(ctx, 0) and mouse_in_knob then
    if take then
      reaper.Undo_BeginBlock()
      reaper.SetMediaItemTakeInfo_Value(take, "D_PAN", 0)
      reaper.UpdateArrange()
      reaper.Undo_EndBlock("NVSD_ItemView: Reset pan to center", -1)
    end
    state.end_drag("pan")
  elseif reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_knob then
    state.start_drag("pan", mouse_y, take_pan, true)
  end

  if reaper.ImGui_IsMouseReleased(ctx, 0) and state.is_dragging("pan") then
    state.end_drag("pan")
  end

  if state.is_dragging("pan") and reaper.ImGui_IsMouseDown(ctx, 0) then
    local delta_y = state.get_drag_delta(ctx, "pan", mouse_y, take_pan, 0.2)
    local new_pan = state.drag_controls.pan.start_value + delta_y / 200
    new_pan = math.max(-1, math.min(1, new_pan))
    if take then
      reaper.SetMediaItemTakeInfo_Value(take, "D_PAN", new_pan)
      reaper.UpdateArrange()
    end
  end

  return take_pan
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
      utils.clamp_fades_to_length(take_item, new_length)
    end
  end
end

-- Draw pitch knob
function controls.draw_pitch_knob(ctx, draw_list, mouse_x, mouse_y, panel_x, panel_split, panel_bottom, take, config, state, utils, drawing, settings)
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
  local region_h = panel_bottom - panel_split
  local centered_cy = panel_split + region_h / 2
  local max_cy = panel_bottom - 61  -- boxes need 50px below center + 11px breathing room
  local min_cy = panel_split + 34   -- label needs 34px above center
  local knob_cy = math.max(min_cy, math.min(centered_cy, max_cy))
  local knob_angle = utils.pitch_to_angle(take_pitch, config.PITCH_MAX)

  local knob_dx = mouse_x - knob_cx
  local knob_dy = mouse_y - knob_cy
  local knob_dist = math.sqrt(knob_dx * knob_dx + knob_dy * knob_dy)
  local mouse_in_knob = knob_dist <= config.PITCH_KNOB_RADIUS + 8
                        and not (state.is_any_control_dragging() and not state.is_dragging("pitch"))

  drawing.draw_knob(draw_list, knob_cx, knob_cy, config.PITCH_KNOB_RADIUS, knob_angle, mouse_in_knob, state.is_dragging("pitch"), "Pitch", "st", config)

  if mouse_in_knob and not state.is_dragging("pitch") then
    drawing.tooltip(ctx, "pitch_knob", "Pitch\nDouble-click to reset\nCtrl+drag for fine control")
  end

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
      reaper.UpdateItemInProject(reaper.GetMediaItemTake_Item(take))
    end
  end

  return take_pitch, knob_cx, knob_cy
end

-- Draw semitones/cents boxes
function controls.draw_semitones_cents_boxes(ctx, draw_list, mouse_x, mouse_y, panel_x, knob_cy, take, take_pitch, config, state, utils, drawing)
  local display_semitones, display_cents = utils.pitch_to_semitones_cents(take_pitch)

  local box_width = 22
  local box_height = 16
  local box_y = knob_cy + config.PITCH_KNOB_RADIUS + 18
  local box_gap = 1
  local boxes_total_width = box_width * 2 + box_gap
  local box_left_x = panel_x + (config.LEFT_PANEL_WIDTH - boxes_total_width) / 2 - 2
  local box_right_x = box_left_x + box_width + box_gap

  local COLOR_BOX_BG = config.COLOR_RULER_BG
  local COLOR_BOX_BORDER = config.COLOR_BTN_OFF
  local COLOR_BOX_HOVER = config.COLOR_RULER_TICK
  local COLOR_BOX_TEXT = config.COLOR_INFO_BAR_TEXT

  local mouse_in_semitones_box = mouse_x >= box_left_x and mouse_x <= box_left_x + box_width
                                 and mouse_y >= box_y and mouse_y <= box_y + box_height
                                 and not (state.is_any_control_dragging() and not state.is_dragging("semitones"))
  local mouse_in_cents_box = mouse_x >= box_right_x and mouse_x <= box_right_x + box_width
                             and mouse_y >= box_y and mouse_y <= box_y + box_height
                             and not (state.is_any_control_dragging() and not state.is_dragging("cents"))

  if mouse_in_semitones_box and not state.is_dragging("semitones") and drawing then
    drawing.tooltip(ctx, "semitones_box", "Pitch semitones")
  end
  if mouse_in_cents_box and not state.is_dragging("cents") and drawing then
    drawing.tooltip(ctx, "cents_box", "Pitch cents")
  end

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
      reaper.UpdateItemInProject(reaper.GetMediaItemTake_Item(take))
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
      reaper.UpdateItemInProject(reaper.GetMediaItemTake_Item(take))
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

  local left_bg = mouse_in_left and COLOR_BTN_HOVER or COLOR_BTN_OFF
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

  if mouse_in_left and not state._dropdown_menu_open then
    local left_tip = has_fx and "Toggle all FX bypass" or "Add FX to take"
    drawing.tooltip(ctx, "fx_add_btn", left_tip)
  end

  -- Left button click
  if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_left and not state._dropdown_menu_open then
    if take then
      if not has_fx then
        -- No FX: open take FX chain (same as clicking item's FX button)
        local fx_item = reaper.GetMediaItemTake_Item(take)
        if fx_item then
          reaper.SetMediaItemSelected(fx_item, true)
          reaper.SetActiveTake(take)
          reaper.Main_OnCommand(40638, 0)  -- Item: Show FX chain for item take
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
    right_bg = mouse_in_right and COLOR_BTN_HOVER or COLOR_BTN_OFF
  end
  reaper.ImGui_DrawList_AddRectFilled(draw_list, right_x, right_y, right_x + right_btn_width, right_y + btn_height, right_bg, rounding)

  local fx_text = "FX"
  local fx_text_w = reaper.ImGui_CalcTextSize(ctx, fx_text)
  local fx_text_x = right_x + (right_btn_width - fx_text_w) / 2
  local fx_text_y = right_y + (btn_height - text_height) / 2
  local fx_text_color = has_fx and config.COLOR_WAVEFORM_BG or COLOR_BTN_TEXT
  reaper.ImGui_DrawList_AddText(draw_list, fx_text_x, fx_text_y, fx_text_color, fx_text)

  if mouse_in_right and not state._dropdown_menu_open then
    drawing.tooltip(ctx, "fx_chain_btn", has_fx and "Open FX chain\nAlt+click: remove all FX" or "Add FX to take")
  end

  -- Right button click
  if reaper.ImGui_IsMouseClicked(ctx, 0) and mouse_in_right and not state._dropdown_menu_open then
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
        -- No FX: open take FX chain (same as clicking item's FX button)
        local fx_item = reaper.GetMediaItemTake_Item(take)
        if fx_item then
          reaper.SetMediaItemSelected(fx_item, true)
          reaper.SetActiveTake(take)
          reaper.Main_OnCommand(40638, 0)  -- Item: Show FX chain for item take
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
  local BOX_FILL = config.COLOR_WAVEFORM_BG
  local BOX_BORDER = config.COLOR_CENTERLINE
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
        reaper.ImGui_DrawList_AddRectFilled(draw_list, fx_x + inner_pad, row_y, fx_x + content_width - inner_pad, row_y + row_height, config.COLOR_INFO_BAR_BG)
      elseif mouse_in_row and not state.fx_drag_activated then
        reaper.ImGui_DrawList_AddRectFilled(draw_list, fx_x + inner_pad, row_y, fx_x + content_width - inner_pad, row_y + row_height, config.COLOR_GRID_BAR)
      end

      -- Bypass toggle indicator [B]
      local bp_x = fx_x + bypass_margin + inner_pad
      local bp_y = row_y + (row_height - bypass_size) / 2
      local mouse_in_bypass = mouse_x >= bp_x and mouse_x <= bp_x + bypass_size
                              and mouse_y >= bp_y and mouse_y <= bp_y + bypass_size
                              and row_visible

      if is_enabled then
        local bp_color = is_drag_source and ((config.COLOR_MARKER & 0xFFFFFF00) | 0x60) or config.COLOR_MARKER
        reaper.ImGui_DrawList_AddRectFilled(draw_list, bp_x, bp_y, bp_x + bypass_size, bp_y + bypass_size, bp_color, 2)
      else
        local bp_border = is_drag_source and ((config.COLOR_RULER_TICK & 0xFFFFFF00) | 0x60) or config.COLOR_RULER_TICK
        reaper.ImGui_DrawList_AddRect(draw_list, bp_x, bp_y, bp_x + bypass_size, bp_y + bypass_size, bp_border, 2)
      end

      -- FX name text
      local text_color
      if is_drag_source then
        text_color = (config.COLOR_RULER_TICK & 0xFFFFFF00) | 0x60
      elseif is_offline then
        text_color = 0x994444FF
      elseif not is_enabled then
        text_color = config.COLOR_RULER_TEXT
      elseif is_open then
        text_color = config.COLOR_BTN_TEXT
      else
        text_color = config.COLOR_INFO_BAR_TEXT
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
      if not state.fx_drag_activated and not state._dropdown_menu_open then
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
          reaper.ImGui_DrawList_AddLine(draw_list, fx_x + 2, line_y, fx_x + content_width - 2, line_y, config.COLOR_MARKER, 2)
          break
        end
      end
      if not drop_before_idx and #row_positions > 0 then
        local last_rp = row_positions[#row_positions]
        drop_before_idx = last_rp.entry.index + 1
        local line_y = last_rp.y + row_height
        reaper.ImGui_DrawList_AddLine(draw_list, fx_x + 2, line_y, fx_x + content_width - 2, line_y, config.COLOR_MARKER, 2)
      end

      -- Draw floating dragged row at mouse position
      if drag_entry then
        local float_y = mouse_y - row_height / 2
        reaper.ImGui_DrawList_AddRectFilled(draw_list, fx_x + inner_pad, float_y, fx_x + content_width - inner_pad, float_y + row_height, (config.COLOR_MARKER & 0xFFFFFF00) | 0xAA)

        local is_enabled = reaper.TakeFX_GetEnabled(take, drag_entry.index)
        local float_bp_x = fx_x + bypass_margin + inner_pad
        local float_bp_y = float_y + (row_height - bypass_size) / 2
        if is_enabled then
          reaper.ImGui_DrawList_AddRectFilled(draw_list, float_bp_x, float_bp_y, float_bp_x + bypass_size, float_bp_y + bypass_size, config.COLOR_MARKER, 2)
        else
          reaper.ImGui_DrawList_AddRect(draw_list, float_bp_x, float_bp_y, float_bp_x + bypass_size, float_bp_y + bypass_size, config.COLOR_RULER_TICK, 2)
        end

        local float_text_x = fx_x + text_x_offset + inner_pad
        local float_text_y = float_y + (row_height - 13) / 2
        reaper.ImGui_DrawList_AddText(draw_list, float_text_x, float_text_y, config.COLOR_BTN_TEXT, drag_entry.name)
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
    reaper.ImGui_DrawList_AddRectFilled(draw_list, sb_x, sb_top, sb_x + scrollbar_width, sb_top + sb_height, config.COLOR_WAVEFORM_BG)

    -- Thumb
    local thumb_ratio = visible_height / content_height
    local thumb_height = math.max(12, sb_height * thumb_ratio)
    local scroll_ratio = state.fx_scroll_offset / max_scroll
    local thumb_y = sb_top + scroll_ratio * (sb_height - thumb_height)

    local mouse_in_scrollbar = mouse_x >= sb_x and mouse_x <= sb_x + scrollbar_width
                               and mouse_y >= sb_top and mouse_y <= sb_top + sb_height
    local thumb_color = mouse_in_scrollbar and config.COLOR_RULER_TEXT or config.COLOR_BTN_OFF
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
